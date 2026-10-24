//
//  A2LaunchSession.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  编排实现。★所有取值都在本层解析完，交给 Natives 的只有「已解析参数」★。
//

#import "A2LaunchSession.h"
#import <UIKit/UIKit.h>   // 启动失败界面（UIAlertController / UIWindowScene）
#import "A2LaunchPlan.h"
#import "A2LaunchOverlay.h"
#import "A2LaunchRunner.h"
#import "A2LaunchChain.h"            // ①→②→③ 的顺序与状态（★单一真相源★）
#import "A2LaunchFailure.h"          // 失败分类 / 判据行 / 用户文案（Player 纯逻辑）
#import "A2JITEnvironmentProbe.h"    // ② 真调判据（Bridge → Natives/A2JITEnvironment）
#import "A2JITScriptDelivery.h"      // ① 下发脚本（Bridge → Natives 的下发原语）
#import "A2LaunchContract.h"
#import "A2LaunchMemory.h"          // Utils 叶子层 —— ★内存预算★（安全堆顶 / 档位 / GC 档判据）
#import "A2VersionManager.h"
#import "A2AccountManager.h"
#import "A2Account.h"
#import "A2Settings.h"
#import "A2RendererCatalog.h"       // Core/Renderer —— 渲染后端候选表 + 包内存在性（[RENDER-SEL]）
#import "A2RenderScaleCatalog.h"    // Core/Renderer —— 渲染分辨率倍率候选表 + 归一化（[FRAME-PERF]）
#import "A2JavaRuntimeCatalog.h"    // Core/Version —— Java 运行时候选表 + 可用性（[JRE-SEL]）
#import "A2VersionIsolation.h"      // Core/Path —— A2GamePath：实例路径的唯一计算处（[A2-INSTANCE]）
#import "A2RuntimeStrings.h"        // Player 同层 —— 四语文案（阻断文案 + 判据行的「源」）
#import "A2LegacyProfile.h"         // Core/Version —— 远古版本画像（[A2-LEGACY] 闸门与 VM 参数）
#import "A2LegacyAssetsMapper.h"    // Core/Version —— 远古资源映射（virtual / map_to_resources）
#import "A2Log.h"

// ② 有界探测预算（本函数在后台队列跑；对齐 A2JITEnvironment 的建议量级）。
static const NSTimeInterval A2LaunchJITVerifyBudget = 3.0;

@interface A2LaunchSessionResult ()

@property (nonatomic, assign, readwrite) BOOL started;
@property (nonatomic, assign, readwrite) NSInteger returnCode;
@property (nonatomic, copy, readwrite) NSString *message;

@end

@implementation A2LaunchSessionResult

+ (instancetype)resultWithStarted:(BOOL)started
                       returnCode:(NSInteger)returnCode
                          message:(NSString *)message {
    A2LaunchSessionResult *r = [[A2LaunchSessionResult alloc] init];
    r.started = started;
    r.returnCode = returnCode;
    r.message = message ?: @"";
    return r;
}

@end

// 包内首个 name 以 prefix 开头的子目录（用于 libs/lwjgl-<ver>、java_runtimes/<ver> 的版本无关解析）。
static NSString *A2LaunchFirstSubdirectory(NSString *parent, NSString *prefix) {
    NSArray<NSString *> *entries =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:parent error:nil];
    NSArray<NSString *> *sorted = [entries sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in sorted) {
        if ([name hasPrefix:prefix]) {
            BOOL isDir = NO;
            NSString *full = [parent stringByAppendingPathComponent:name];
            if ([NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir] && isDir) {
                return full;
            }
        }
    }
    return nil;
}

/// ★默认渲染器按版本推导★（用户/实例显式选择永远优先）
///   26.2 / 26.3 → metallum（当前唯一验证过的 Metal 面）
///   26.1 及其它 1.13+ → MobileGlues（GL3.2+ 需要它）
///   1.12 及更早 → gl4es（GL1.x/2.x 固定管线）
static NSString *A2DefaultRendererForVersion(NSInteger major, NSInteger minor) {
    if (major >= 26) {
        if (major == 26 && (minor == 2 || minor == 3)) return @"libmetallum.dylib";
        return @"libmobileglues.dylib";
    }
    if (major == 1 && minor >= 13) return @"libmobileglues.dylib";
    return @"libgl4es_114.dylib";
}

/// 从目录名取 LWJGL 版本号：lwjgl-341 → 341，lwjgl-2 → 200（便于比较大小）
static NSInteger A2LwjglVersionNumber(NSString *dirName) {
    NSString *s = [dirName stringByReplacingOccurrencesOfString:@"lwjgl-" withString:@""];
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
        else break;
    }
    if (digits.length == 0) return 0;
    NSInteger v = digits.integerValue;
    return (digits.length <= 2) ? v * 100 : v;   // "2"/"29" → 200/2900 量级修正
}

/// ★按 MC 版本挑 LWJGL★ 1.12.2 及更早用 LWJGL 2.x，1.13+ 用 3.x 里最高的那套。
/// 只有一套时直接用它（现状），将来多套并pack 时不会错配。
static NSString *A2LaunchPickLWJGLDir(NSString *libsRoot, NSInteger mcMajor, NSInteger mcMinor) {
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:libsRoot error:nil];
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    for (NSString *name in entries) {
        if (![name hasPrefix:@"lwjgl-"]) continue;
        BOOL isDir = NO;
        NSString *full = [libsRoot stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir] && isDir) {
            [dirs addObject:name];
        }
    }
    if (dirs.count == 0) return nil;

    BOOL wantsLWJGL2 = (mcMajor == 1 && mcMinor > 0 && mcMinor <= 12);
    NSMutableArray<NSString *> *preferred = [NSMutableArray array];
    for (NSString *name in dirs) {
        NSInteger v = A2LwjglVersionNumber(name);
        BOOL is2 = (v < 300);
        if (is2 == wantsLWJGL2) [preferred addObject:name];
    }
    if (preferred.count == 0) preferred = dirs;   // 没有对口档位 ⇒ 用现有的（并如实提示）

    [preferred sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [@(A2LwjglVersionNumber(a)) compare:@(A2LwjglVersionNumber(b))];
    }];
    NSString *chosen = preferred.lastObject;

    [A2Log criterion:@"[A2-LWJGL] 选择 %@（MC %ld.%ld ⇒ 需要 LWJGL %@；可选：%@）",
     chosen, (long)mcMajor, (long)mcMinor, wantsLWJGL2 ? @"2.x" : @"3.x",
     [dirs componentsJoinedByString:@","]];
    if (preferred.count != dirs.count && preferred.count > 0) {
        // 有对口档位就行；下面的兜底提示只在完全没对上时出现
    }
    return [libsRoot stringByAppendingPathComponent:chosen];
}

@interface A2LaunchSession ()
/// 启动失败页（finish() 在定义之前调用 ⇒ 需要前置声明）
+ (void)a2_presentLaunchFailureWithMessage:(NSString *)message returnCode:(NSInteger)rc;
@end

@implementation A2LaunchSession

+ (BOOL)runtimeChainEnabled {
    return [A2LaunchRunner runtimeChainEnabled];
}

+ (void)startCurrentVersionWithCompletion:(void (^)(A2LaunchSessionResult *))completion {
    if (completion == nil) return;
    void (^finish)(BOOL, NSInteger, NSString *) = ^(BOOL started, NSInteger rc, NSString *message) {
        A2LaunchSessionResult *r = [A2LaunchSessionResult resultWithStarted:started
                                                                 returnCode:rc
                                                                    message:message];
        dispatch_async(dispatch_get_main_queue(), ^{
            // ★崩溃界面（用户要求 2026-10-18）★ 启动失败时不要只是闪退：
            //   弹一个可读的失败页，写清「停在哪一步 / 失败码 / 怎么下一步」，
            //   并提供「打开日志」直接看 lastlog。成功路径完全不受影响。
            if (!started) {
                [A2LaunchOverlay hide];   // 遮罩先收，失败页才看得见
                [A2LaunchSession a2_presentLaunchFailureWithMessage:message returnCode:rc];
            }
            completion(r);
        });
    };

    if (![self runtimeChainEnabled]) {
        // ★开关=关的判据行★（默认关 ⇒ 与旧版零行为差异）
        [A2Log log:@"[A2-CHAIN] 开关=关（debug.rt_p1_runtime / RT_P1_RUNTIME / 标志文件）⇒ 零副作用返回，行为与旧版一致"];
        // ★[A2-JITVM] 判据行（gate 步）★：属于「未就绪路径」—— 还没走到判据
        //   （verdict=Unknown）且 enable=0，与「失败路径」（判据跑过、不合格）在 verdict/reason 两处分得开。
        [A2Log log:@"%@", [A2LaunchFailure jitvmLineWithStep:@"gate"
                                                      verdict:A2JITReadinessVerdictUnknown
                                                    enableJIT:NO
                                                   reasonText:@"自研启动链未启用（开关=关）"
                                                     evidence:nil]];
        finish(NO, 0, @"自研启动链未启用（设置 → 诊断 → 运行环境 · 启动链）");
        return;
    }
    // ★开关=开的判据行★
    [A2Log log:@"[A2-CHAIN] 开关=开 ⇒ 走自研链（① 下发 JIT 脚本 → ② 探测 JIT → ③ 建 VM）"];

    A2Version *version = A2VersionManager.shared.currentVersion;
    if (version == nil) {
        finish(NO, 0, @"还没有选中版本");
        return;
    }

    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSString *gameHome = A2VersionManager.shared.gameHome ?: @"";
    NSString *gameDir = version.gameDirectory ?: gameHome;
    // ★实例路径的唯一计算处（[A2-INSTANCE]）★
    //   libraries/ 与 assets/ 也由 A2GamePath 给出 —— 安装侧的落点（同一对象的
    //   librariesHome/assetsHome）就是这么算的；此前这里手拼了同一对字符串，
    //   虽与本处取值相同，但那是「同一知识的两份拷贝」⇒ 收敛到一处。
    A2GamePath *canonicalPath = [A2GamePath pathWithGameHome:gameHome];
    NSString *librariesDir = [canonicalPath librariesHome];
    NSString *assetsDir = [canonicalPath assetsHome];
    NSString *versionJar = [version.versionPath stringByAppendingPathComponent:
                            [version.name stringByAppendingPathExtension:@"jar"]];
    NSString *javaJarDir = [bundle stringByAppendingPathComponent:@"Java"];
    NSString *entryJar = [javaJarDir stringByAppendingPathComponent:A2LaunchJavaEntryJarName];
    NSString *patchJar = [javaJarDir stringByAppendingPathComponent:A2LaunchJavaPatchJarName];
    NSString *frameworks = [bundle stringByAppendingPathComponent:@"Frameworks"];
    // ★按版本挑 LWJGL 目录★（原来恒定取第一个，多套并pack 时会错配）
    NSInteger a2McMajor = 0, a2McMinor = 0;
    [A2LegacyProfile parseNumericVersionID:version.name major:&a2McMajor minor:&a2McMinor];
    NSString *libsRoot = [bundle stringByAppendingPathComponent:@"libs"];
    NSString *lwjglDir = A2LaunchPickLWJGLDir(libsRoot, a2McMajor, a2McMinor);
    if (lwjglDir.length == 0) {
        lwjglDir = A2LaunchFirstSubdirectory(libsRoot, @"lwjgl-");
    }

    // ========================================================================
    // ★[RENDER-SEL] 渲染后端：用户选择 → 已解析的 dylib 名★
    // ------------------------------------------------------------------------
    // 取值来源：Air2 自己的 NSUserDefaults（键 A2SelectedRendererPrefKey，写点唯一 =
    // A2RuntimeSettings 的渲染器行）。缺省 ⇒ 主推（自研 Metal）。
    // ★判据行★ `[A2-RENDERER] chosen=…(源: 用户选择; source=user)` ——
    //   中文与稳定 tag 并存：真机换语言也能 grep 到（source=user / source=default）。
    // ★选到未内置的 ⇒ 如实阻断★（不给 VM，不静默换一个渲染器）。
    // ========================================================================
    // ★实例级覆盖优先★：实例设置 → 启动配置 → 渲染器（写点 = A2VersionSettingsViewController）。
    //   实例没选（空）⇒ 落回全局设置 → 缺省值；source 字段区分三种来源。
    NSString *instanceRenderer = version.isolation.renderer;
    NSString *selRenderer = instanceRenderer.length
        ? instanceRenderer
        : [NSUserDefaults.standardUserDefaults stringForKey:A2SelectedRendererPrefKey];
    BOOL rendererFromUser = (selRenderer.length > 0);
    NSString *autoRendererID = A2DefaultRendererForVersion(a2McMajor, a2McMinor);
    A2Renderer *renderer = [A2RendererCatalog candidateForIdentifier:selRenderer ?: @""]
        ?: [A2RendererCatalog candidateForIdentifier:autoRendererID]
        ?: [A2RendererCatalog defaultCandidate];
    NSString *rendererSource = instanceRenderer.length
        ? @"instance" : (rendererFromUser ? @"user" : @"default");
    NSString *rendererSourceWord = instanceRenderer.length
        ? @"实例设置"
        : [A2RuntimeStrings stringForKey:(rendererFromUser ? @"runtime.source.user"
                                                           : @"runtime.source.default")];
    if (!rendererFromUser) {
        [A2Log criterion:@"[A2-RENDERER] 默认按版本推导：MC %ld.%ld ⇒ %@",
         (long)a2McMajor, (long)a2McMinor, renderer.identifier];
    }
    [A2Log log:@"[A2-RENDERER] chosen=%@(源: %@; source=%@)",
                 renderer.identifier, rendererSourceWord, rendererSource];

    if (![A2RendererCatalog isBundled:renderer frameworksPath:frameworks]) {
        NSString *nameKey = [A2RendererCatalog nameLocalizationKeyForIdentifier:renderer.identifier];
        NSString *name = [A2RuntimeStrings stringForKey:nameKey];
        if ([name isEqualToString:nameKey]) name = renderer.identifier;   // 缺 key ⇒ 技术名兜底
        [A2Log log:@"[A2-RENDERER] ★阻断启动★：所选渲染器未内置（%s）—— 包内缺 Frameworks/%s",
         renderer.identifier.UTF8String, renderer.identifier.UTF8String];
        finish(NO, 0, [NSString stringWithFormat:
                       [A2RuntimeStrings stringForKey:@"runtime.blocked.renderer"],
                       name, renderer.identifier]);
        return;
    }

    // ========================================================================
    // ★[JRE-SEL] Java 运行时：用户选择 → 启动计划的 javaHome★
    // ------------------------------------------------------------------------
    // 取值来源：同一个 NSUserDefaults（键 A2SelectedJavaRuntimePrefKey，写点唯一 =
    // A2RuntimeSettings 的 Java 运行时行）。缺省 ⇒ 主推档（java-25-openjdk）。
    // ★判据行★ `[A2-JRE] chosen=…(源: 用户选择; source=user)`。
    // ★选到未内置/不完整的 ⇒ 如实阻断★（不自动换档）。
    // ========================================================================
    NSString *runtimesDir = [bundle stringByAppendingPathComponent:
                             [A2JavaRuntimeCatalog javaRuntimesDirectoryName]];
    // ★实例级覆盖优先★：实例设置 → 启动配置 → Java 运行时；空 ⇒ 全局 → 主推档。
    NSString *instanceJRE = version.isolation.javaRuntime;
    BOOL jreFromInstance = (instanceJRE.length > 0 &&
                            [[A2JavaRuntimeCatalog allDirectoryNames] containsObject:instanceJRE]);
    NSString *selJRE = jreFromInstance
        ? instanceJRE
        : [NSUserDefaults.standardUserDefaults stringForKey:A2SelectedJavaRuntimePrefKey];
    BOOL jreFromUser = (selJRE.length > 0 &&
                        [[A2JavaRuntimeCatalog allDirectoryNames] containsObject:selJRE]);
    NSString *jreDir = jreFromUser ? selJRE : [A2JavaRuntimeCatalog defaultDirectoryName];
    NSString *javaHome = [runtimesDir stringByAppendingPathComponent:jreDir];
    NSString *jreSource = jreFromInstance ? @"instance" : (jreFromUser ? @"user" : @"default");
    NSString *jreSourceWord = jreFromInstance
        ? @"实例设置"
        : [A2RuntimeStrings stringForKey:(jreFromUser ? @"runtime.source.user"
                                                      : @"runtime.source.default")];
    [A2Log log:@"[A2-JRE] chosen=%@(源: %@; source=%@)",
                 jreDir, jreSourceWord, jreSource];

    // ========================================================================
    // ★[FRAME-PERF] 渲染分辨率倍率：用户选择 → 启动链的表面尺寸★
    // ------------------------------------------------------------------------
    // 取值来源：同一个 NSUserDefaults（键 A2SelectedRenderScalePrefKey，写点唯一 =
    // A2RuntimeSettings 的渲染分辨率行）。缺省/非法 ⇒ 默认档（1.0，原生像素）。
    // ★判据行★ `[A2-RENDER] chosen=…(源: 用户选择; source=user)` —— 与
    //   [A2-RENDERER]/[A2-JRE] 同形；实际落到帧上的值另由 `[FRAME] scale=… px=…x…` 证明。
    // 语义：drawable 像素 = 表面像素 × 倍率（★逻辑尺寸/点不变★）。
    // ========================================================================
    NSString *selScale = [NSUserDefaults.standardUserDefaults stringForKey:A2SelectedRenderScalePrefKey];
    double renderScale = [A2RenderScaleCatalog normalizedScaleForStoredString:selScale];
    BOOL scaleFromUser = (selScale.length > 0 &&
                          [A2RenderScaleCatalog isSupportedScale:selScale.doubleValue]);
    NSString *scaleSourceWord = [A2RuntimeStrings stringForKey:(scaleFromUser
                                                                 ? @"runtime.source.user"
                                                                 : @"runtime.source.default")];
    [A2Log log:@"[A2-RENDER] chosen=%.2f(源: %@; source=%@)",
     renderScale, scaleSourceWord, scaleFromUser ? @"user" : @"default"];

    NSString *userHome = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                             NSUserDomainMask, YES) firstObject];
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *planPath = [gameDir stringByAppendingPathComponent:@"air2-launch-plan.json"];

    if (![NSFileManager.defaultManager fileExistsAtPath:entryJar]) {
        finish(NO, 0, [NSString stringWithFormat:@"包内缺启动核心 %@", A2LaunchJavaEntryJarName]);
        return;
    }
    if (![A2JavaRuntimeCatalog isUsableJavaHome:javaHome]) {
        // ★两种形态分开报，不混为一谈★：
        //   ① 一整份 java_runtimes 都没随包 ⇒ 构建问题（提示跑 stage_runtime.sh）；
        //   ② 只是**用户选的那一档**没内置 ⇒ 选项问题（如实报并让用户改选）。
        BOOL anyBundled = NO;
        for (NSString *d in [A2JavaRuntimeCatalog allDirectoryNames]) {
            if ([A2JavaRuntimeCatalog isUsableJavaHome:
                 [runtimesDir stringByAppendingPathComponent:d]]) {
                anyBundled = YES;
                break;
            }
        }
        if (!anyBundled) {
            finish(NO, 0, @"包内没有 JVM 运行时（java_runtimes/）—— 请先跑 scripts/stage_runtime.sh 再出包");
            return;
        }
        [A2Log log:@"[A2-JRE] ★阻断启动★：所选档未内置/不完整（%s）—— 期望 %s/lib/server/libjvm.dylib",
         jreDir.UTF8String, javaHome.UTF8String];
        finish(NO, 0, [NSString stringWithFormat:
                       [A2RuntimeStrings stringForKey:@"runtime.blocked.jre"], jreDir]);
        return;
    }
    if (lwjglDir.length == 0) {
        finish(NO, 0, @"包内没有 libs/lwjgl-<ver>/");
        return;
    }

    // ========================================================================
    // ★[A2-INSTANCE] 实例落位判据行（启动侧）★
    // ------------------------------------------------------------------------
    // 判据 = 安装收尾判的同一对文件，且**同一处计算**：A2GamePath 的
    //        versionJSONPath: / versionJarPath: ⇒ 写（安装落点）读（启动）
    //        两处逐字一致，不在这里另拼一份路径。
    // · pathMatch=1 ⇒ 真正交给启动计划的那条 jar（上面的 versionJar，
    //   由 version.versionPath 拼出）与落盘那条是同一字符串。
    // · ★判据为假 ⇒ 如实阻断★（不给计划、不建 VM），并说清缺的是哪一份。
    // ========================================================================
    NSString *instanceJSON = [canonicalPath versionJSONPath:version.name];
    NSString *instanceJar = [canonicalPath versionJarPath:version.name];
    BOOL instanceJSONExists = [NSFileManager.defaultManager fileExistsAtPath:instanceJSON];
    BOOL instanceJarExists = [NSFileManager.defaultManager fileExistsAtPath:instanceJar];
    BOOL instanceOK = instanceJSONExists && instanceJarExists;

    // ★可 grep 的判据行（默认可见）★
    [A2Log log:@"[A2-INSTANCE] id=%@ jar=%@ json=%@ exists=%d stage=launch pathMatch=%d assets=%@ libraries=%@",
     version.name, instanceJar, instanceJSON, instanceOK ? 1 : 0,
     [versionJar isEqualToString:instanceJar] ? 1 : 0, assetsDir, librariesDir];

    if (!instanceOK) {
        NSMutableArray<NSString *> *missing = [NSMutableArray array];
        if (!instanceJSONExists) [missing addObject:[version.name stringByAppendingPathExtension:@"json"]];
        if (!instanceJarExists) [missing addObject:[version.name stringByAppendingPathExtension:@"jar"]];
        [A2Log log:@"[A2-INSTANCE] ★阻断启动★：versions/%@ 缺 %@",
         version.name, [missing componentsJoinedByString:@"、"]];
        finish(NO, 0, [NSString stringWithFormat:
                       @"实例不完整：versions/%@ 缺 %@（请重新安装该版本）",
                       version.name, [missing componentsJoinedByString:@"、"]]);
        return;
    }

    // 账号取值（Core/Account）⇒ 纯值字典，交给 Core/Version
    A2Account *account = A2AccountManager.shared.currentAccount;
    NSMutableDictionary<NSString *, NSString *> *accountDict = [NSMutableDictionary dictionary];
    accountDict[@"username"] = account.username ?: @"Player";
    accountDict[@"accessToken"] = account.accessToken ?: @"0";
    accountDict[@"uuid"] = account.profileID ?: @"";
    switch (account.type) {
        case A2AccountTypeMicrosoft: accountDict[@"userType"] = @"msa"; break;
        case A2AccountTypeThirdParty: accountDict[@"userType"] = @"mojang"; break;
        default: accountDict[@"userType"] = @"legacy"; break;
    }

    // ★启动时的运行时事实（屏幕像素尺寸 / 系统最大帧率）★
    //   ★为什么在产出计划之前★：它要进计划（plan.runtimeFacts）⇒ 由计划落成 VM 级 -D。
    //     顺序不能反 —— 复用线覆盖层 GLFW 的静态块在「装载 GLFW 类」时就读这两个属性，
    //     晚于 VM 启动的注入（如 A2Entry 落属性）赶不上。
    //   ★为什么取在 Bridge★：Core 明文不 import UIKit（docs/ARCHITECTURE.md §Core），
    //     Player 也不感知 UIKit（同层 A2JITLocalFactsSource 把 UIKit 探测留给更上层），
    //     而 Bridge 是启动链唯一与 Natives 相邻的跨层入口 ⇒ 由它采集、本层递进计划。
    //   ★不写猜的值★：取不到就是 0/nil ⇒ 计划那步一条 -D 都不下发，让 Java 侧如实报错。
    A2LaunchRuntimeFacts *runtimeFacts = [A2LaunchRunner currentRuntimeFacts];

    // 计划产出（Core/Version）
    NSError *planError = nil;
    A2LaunchPlan *plan = [A2LaunchPlan planForVersionDirectory:version.versionPath
                                                     versionID:version.name
                                                   accountDict:accountDict
                                                       gameDir:gameDir
                                                     assetsDir:assetsDir
                                                  librariesDir:librariesDir
                                                versionJarPath:versionJar
                                                  runtimeFacts:runtimeFacts
                                                         error:&planError];
    if (plan == nil) {
        finish(NO, 0, [NSString stringWithFormat:@"启动计划产出失败：%@",
                       planError.localizedDescription ?: @"(无详情)"]);
        return;
    }
    if (![plan writeToFile:planPath error:&planError]) {
        finish(NO, 0, [NSString stringWithFormat:@"启动计划写盘失败：%@",
                       planError.localizedDescription ?: @"(无详情)"]);
        return;
    }

    // ========================================================================
    // ★[MEM] 启动内存预算：设备可用内存 → 安全堆顶 → `-Xmx`★
    // ------------------------------------------------------------------------
    // ① 探测：Bridge 的 `currentMemoryProbe`（启动链唯一与系统接口相邻的层；
    //    与上面 runtimeFacts 同一落点）→ 进程可安全申请内存 + 物理内存。
    // ② 安全顶：`A2LaunchMemory.safeHeapCeilingMBForProbe:`（纯函数，见该头文件的取值口径）。
    // ③ 档位：设置里的「自动/手动」（A2Settings.memoryMode）。★手动值仍受安全顶钳制★ ——
    //    堆超顶的后果是被 iOS jetsam 直接杀（无 Java 异常、日志凭空断），不是慢。
    // ④ 参数集：Java 档位（jreMajor）决定 GC 那一组（Java 17+ 才启用 G1 调优）。
    // ★不写猜的值★：探不到就按 A2LaunchMemory 的 default 回退，并在判据行如实标 source。
    // ========================================================================
    A2MemoryProbe *memProbe = [A2LaunchRunner currentMemoryProbe];
    NSInteger ceilingMB = [A2LaunchMemory safeHeapCeilingMBForProbe:memProbe];
    NSInteger jreMajor = [A2JavaRuntimeCatalog majorVersionForDirectoryName:jreDir];
    A2LaunchMemoryMode memMode = A2Settings.shared.memoryMode;
    NSInteger xmxMB = [A2LaunchMemory xmxMBWithCeilingMB:ceilingMB
                                                    mode:memMode
                                             requestedMB:A2Settings.shared.ramAllocationMB];
    // ★[MEM] 判据行（默认可见）★：真机一眼判「堆上限从哪来、走了哪个档、GC 是谁」。
    [A2Log criterion:@"[MEM] ceiling=%ldMB -> -Xmx%ldMB (source=%@) mode=%@ jre=%ld gc=%@",
     (long)ceilingMB, (long)xmxMB, memProbe.source,
     (memMode == A2LaunchMemoryModeManual ? @"manual" : @"auto"),
     (long)jreMajor, [A2LaunchMemory gcNameForJavaMajorVersion:jreMajor]];

    // ========================================================================
    // ★[A2-LEGACY] 远古版本（1.0–1.6.4 / Alpha / Beta）兼容轨★
    // ------------------------------------------------------------------------
    // 三个闸门，任一不过就**如实阻断**（不静默换 JRE、不静默换渲染器）：
    //   ① JRE 档位：1.12.2 及更早只认 Java 8（版本 JSON 声明的库与字节码都按 8 编译）；
    //   ② LWJGL2 API 兼容层：1.12.2 及更早的客户端 import org.lwjgl.opengl.Display /
    //      org.lwjgl.input.* / org.lwjgl.util.glu.*，这些类只有 lwjgl-lwjglx.jar 提供
    //      （LWJGL3 的 jar 里根本没有）；缺了就必然走到 NoClassDefFoundError，
    //      与其让用户看一句裸异常，不如在这里说清缺什么；
    //   ③ 渲染器语义：1.0–1.6 是 GL 1.x 固定管线，只有 gl4es 家族能接。
    // 通过后：堆上限钳到画像给的帽值，并追加远古 VM 参数（见下方 jvmOptions）。
    // ★判定只在 A2LegacyProfile 一处★，本段只消费结果。
    // ========================================================================
    A2LegacyProfile *legacyProfile = [A2LegacyProfile profileForVersionDirectory:version.versionPath
                                                                       versionID:version.name];
    if (legacyProfile != nil && legacyProfile.isClassicGeneration) {
        [A2Log criterion:@"%@", [legacyProfile diagnosticLine]];
    }
    if (legacyProfile != nil && ![legacyProfile acceptsJavaMajorVersion:jreMajor]) {
        [A2Log criterion:@"[A2-LEGACY] ★阻断启动★：JRE=%ld 超出该版本上限 %ld（jre=%@）",
         (long)jreMajor, (long)legacyProfile.maxJavaMajor, jreDir];
        finish(NO, 0, [NSString stringWithFormat:
                       @"该版本只能用 Java %ld 启动（当前选的是 Java %ld）。"
                       @"请在「设置 → 运行环境 → Java 运行时」改选 java-8-openjdk 后重试。",
                       (long)legacyProfile.maxJavaMajor, (long)jreMajor]);
        return;
    }
    if (legacyProfile != nil && legacyProfile.requiresLWJGL2Compat) {
        NSString *compatJar = [lwjglDir stringByAppendingPathComponent:@"lwjgl-lwjglx.jar"];
        if (![NSFileManager.defaultManager fileExistsAtPath:compatJar]) {
            [A2Log criterion:@"[A2-LEGACY] ★阻断启动★：缺 LWJGL2 API 兼容层 %@", compatJar];
            finish(NO, 0, [NSString stringWithFormat:
                           @"这个版本需要 LWJGL 2 的 API（org.lwjgl.opengl.Display 等），"
                           @"但包内缺少兼容层：libs/%@/lwjgl-lwjglx.jar。"
                           @"请先把它随包内置（构建脚本见 docs/LEGACY.md）后再启动。",
                           lwjglDir.lastPathComponent]);
            return;
        }
    }
    // ★渲染器 × 版本兼容矩阵(只告警)★
    //   metallum 的类集只覆盖 1.21.5+ / 26.x；其它版本选它不拦，但如实提示“未验证”，
    //   用户仍可尝试（这就是「扩大可启动面」的口径：不静默选，也不硬堵）。
    {
        NSString *rid = renderer.identifier.lowercaseString ?: @"";
        if ([rid containsString:@"metallum"]) {
            BOOL agentSupports = (a2McMajor == 26 && (a2McMinor == 2 || a2McMinor == 3));
            if (!agentSupports) {
                [A2Log criterion:@"[A2-COMPAT] 提示：metallum 官方类集覆盖 1.21.5+/26.x，"
                 @"本版本 %@ 属未验证组合（仍会尝试注入）", version.name];
            }
        }
    }

    if (legacyProfile != nil && legacyProfile.isClassicGeneration &&
        ![A2LegacyProfile rendererSupportsFixedPipeline:renderer.identifier]) {
        [A2Log criterion:@"[A2-LEGACY] ★阻断启动★：渲染器 %@ 不支持 GL 1.x 固定管线", renderer.identifier];
        finish(NO, 0, [NSString stringWithFormat:
                       @"这个版本（%@）用的是 OpenGL 1.x 固定管线，"
                       @"当前渲染器 %@ 接不了。请在「设置 → 运行环境 → 渲染器」改选 gl4es 后重试。",
                       version.name, renderer.identifier]);
        return;
    }
    if (legacyProfile != nil && legacyProfile.heapCapMB > 0 && xmxMB > legacyProfile.heapCapMB) {
        [A2Log criterion:@"[A2-LEGACY] 堆上限钳制：%ldMB -> %ldMB（远古版本无需大堆）",
         (long)xmxMB, (long)legacyProfile.heapCapMB];
        xmxMB = legacyProfile.heapCapMB;
    }

    NSMutableArray<NSString *> *jvmOptions = [[plan jvmOptionsWithMemoryMB:xmxMB
                                                           javaMajorVersion:jreMajor] mutableCopy];
    // 远古轨道额外参数（Xms / CodeCache 预算）：紧跟在计划的 VM 选项之后，
    // 不覆盖、不重排 —— 计划那组仍是唯一产处。
    if (legacyProfile != nil) {
        [jvmOptions addObjectsFromArray:[legacyProfile jvmCompatOptions]];
    }

    // ★2026-10-18 真机证据★ 两个决定性事实：
    //   ① 崩溃栈是 `Minecraft.<init> → new GlDevice() → GL.createCapabilities()` ⇒ MC 走的是
    //      ★原版 GL 设备★，说明 metallum 的 GpuBackend 根本没生效 —— 它没被注入。
    //   ② 老 Air 的同一件事由 `b12/JavaLauncher.m:2319` 做完：
    //        -javaagent:<libs>/metallum_agent.jar=     （+ patchjna_agent.jar）
    //      metallum 是 `GpuBackend` 替换型后端（MetalBackend.createDevice → MetalDevice），
    //      ★不走 GL、也不建 EGL 面★；只有 agent 注入成功，MC 才不会实例化 GlDevice。
    //   ⇒ 选 Metal 时按老线原样注入；其它渲染器照旧走 LWJGL 的 GL 库名。
    {
        NSString *rendererID = renderer.identifier ?: @"";
        BOOL wantsMetalAgent = [rendererID.lowercaseString containsString:@"metallum"];
        if (wantsMetalAgent) {
            NSString *libs = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"libs"];
            [jvmOptions addObject:[NSString stringWithFormat:@"-javaagent:%@/patchjna_agent.jar=", libs]];
            [jvmOptions addObject:[NSString stringWithFormat:@"-javaagent:%@/metallum_agent.jar=", libs]];
            [jvmOptions addObject:[NSString stringWithFormat:@"-Dmetallum.mc.version=%@", version.name]];
            // ★2026-10-18 真机证据★ 光注入 jar 不够：metallum agent 只认环境变量
            //   AMETHYST_METAL=1 来打开渲染 patch（MetallumAgent.IS_METAL_RENDERER）。
            //   不设 ⇒ 日志 "non-Metal renderer: … render patches disabled" ⇒ MC 回落
            //   GlBackend/GlDevice ⇒ 又变成 "no OpenGL context current" 崩溃。
            //   出处：老线 JavaLauncher.m:1623-1629（同一行注释写的就是这条）。
            setenv("AMETHYST_METAL", "1", 1);
            [A2Log criterion:@"[A2-AGENT] Metal 后端注入：-javaagent metallum_agent.jar（mcVersion=%@，AMETHYST_METAL=1）",
             version.name];
        } else {
            unsetenv("AMETHYST_METAL");   // 非 Metal ⇒ 确保 agent 不会误开渲染 patch
            // LWJGL 的 GL 库名跟渲染器走（lib 前缀与 .dylib 后缀都要去掉）：
            //   libgl4es_114.dylib → gl4es_114；libnggl4es.dylib → nggl4es …
            NSString *bare = rendererID;
            if ([bare hasPrefix:@"lib"]) bare = [bare substringFromIndex:3];
            if ([bare hasSuffix:@".dylib"]) bare = [bare substringToIndex:bare.length - 6];
            if (bare.length > 0) {
                [jvmOptions addObject:[NSString stringWithFormat:@"-Dorg.lwjgl.opengl.libname=%@", bare]];
                [A2Log criterion:@"[A2-AGENT] GL 后端：opengl.libname=%@", bare];
            }
        }
    }

    // 建 VM 会阻塞 ⇒ 放后台队列；结果回主线程。
    // ★启动遮罩★ 从这里开始用户看不到任何进展 ⇒ 立刻盖上，阶段播报会驱动它。
    [A2LaunchOverlay show];
    // ★26.3+（SDL 窗口栈）★ 我们自己那条「GLFW 建窗时顺带加控件」不会执行
    //   ⇒ 这里主动建一层控件覆盖层；事件由 a2_sdl_input 镜像进 SDL。
    //   26.2 及更早不受影响（它们走 GLFW 宿主视图那条老路）。
    if ((a2McMajor == 26 && a2McMinor >= 3) || a2McMajor > 26) {
        extern void a2_controls_overlay_start_for_sdl(void);
        a2_controls_overlay_start_for_sdl();
        [A2Log criterion:@"[A2-CONTROLS] 26.3+ 走 SDL 控件覆盖层（a2_controls_overlay）"];
    }

    [A2Log log:@"[A2-LAUNCH] 进入后台链：plan=%@ renderer=%@ jre=%@",
                 planPath.lastPathComponent ?: @"(nil)", renderer.identifier, jreDir];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // ====================================================================
        // ★[A2-LEGACY] 远古资源映射（virtual / map_to_resources）★
        // --------------------------------------------------------------------
        // 为什么放在这里（而不是安装阶段）：映射目标是 `<gameDir>/resources/`，
        // 而 instance 的 gameDir 只有到这里才最终确定（实例隔离 / 自愈都会改它）。
        // 幂等 + 硬链接 ⇒ 第二次启动几乎没有成本；放在建 VM 之前即可。
        // 失败不拦路：映射不全会表现为「无音效 / 英文界面」，不该让整个启动失败。
        // ====================================================================
        if (legacyProfile != nil && legacyProfile.isClassicGeneration) {
            NSError *mapError = nil;
            A2LegacyAssetsMapResult *mapResult =
                [A2LegacyAssetsMapper mapAssetsForVersionDirectory:version.versionPath
                                                         versionID:version.name
                                                        assetsRoot:assetsDir
                                                           gameDir:gameDir
                                                             error:&mapError];
            if (mapResult != nil) {
                [A2Log criterion:@"%@", [mapResult summaryLine]];
                if (mapResult.missingObjects > 0) {
                    [A2Log log:@"[A2-LEGACY] 有 %lu 个资源对象缺失（重装该版本可补齐）",
                     (unsigned long)mapResult.missingObjects];
                }
            } else {
                [A2Log log:@"[A2-LEGACY] 资源映射跳过：%@", mapError.localizedDescription ?: @"(无详情)"];
            }
        }

        // ★[JIT↔VM] 启动链：① 下发脚本 → ② 探测 JIT → ③ 建 VM★
        //   ★「走到哪一步 / 为什么停」只由 chain.stage + chain.failureReason 一处持有★；
        //   JIT 是否可用只由 A2JITEnvironment.lastRegionVerdict（经 probe）一处给出。
        //   ★禁止用局部 BOOL 记 JIT 状态★（历史缺陷：早期下发路径用局部变量记「已就绪」，
        //   与探测结果不一致 ⇒ 误判；本单改用单一真相源，见 tests/JIT §⑱ 的回归断言）。
        A2JITEnvironmentProbe *probe = [[A2JITEnvironmentProbe alloc] init];
        __block int vmRC = 0;

        A2LaunchChain *chain = [A2LaunchChain
            chainWithDeliverScript:^BOOL(NSError **deliverError) {
                // ① 实现 = Bridge 的 A2JITScriptDelivery（Natives 下发原语只在 Bridge 里调）；失败【不拦路】。
                BOOL ok = [A2JITScriptDelivery deliverSelfContainedScriptWithError:deliverError];
                [A2Log log:@"%@", [A2LaunchFailure jitvmLineWithStep:@"script"
                                                             verdict:A2JITReadinessVerdictUnknown
                                                           enableJIT:NO
                                                          reasonText:(ok ? @"JIT 脚本已下发"
                                                                        : @"JIT 脚本未下发（不拦路；② 会兜底）")
                                                            evidence:nil]];
                return ok;
            }
            verify:^BOOL(NSString **reason) {
                // ② Bridge 真调 Natives/A2JITEnvironment（brk #0x69 区域取证）。
                BOOL ok = [probe ensureJITUsableWithinBudget:A2LaunchJITVerifyBudget reason:reason];
                // ★这一行就是「JIT 就绪结论」★：verdict / enable（是否放行建 VM）/ reason / 取证 齐备，
                //   供真机一眼判成败（未就绪=verdict Unknown；失败=其余 6 档）。
                [A2Log log:@"%@", [A2LaunchFailure jitvmLineWithStep:@"verify"
                                                             verdict:probe.lastVerdict
                                                           enableJIT:ok
                                                          reasonText:nil
                                                            evidence:probe.lastEvidence]];
                return ok;
            }
            createJVM:^BOOL(NSError **vmError) {
                // ③ Bridge 唯一调 a2_launch_jvm_with_argv 的地方（★只有 ② 放行才会走到这里★）。
                [A2Log log:@"%@", [A2LaunchFailure jitvmLineWithStep:@"vm"
                                                             verdict:probe.lastVerdict
                                                           enableJIT:YES
                                                          reasonText:@"JIT 已就绪 ⇒ 走带 JIT 的启动参数路径"
                                                            evidence:probe.lastEvidence]];
                [A2Log log:@"[A2-LAUNCH] ③ 建 VM 开始（可能要 10~60 秒；若之后没有“建 VM 返回”行 ⇒ 卡在建 VM）"];
                vmRC = [A2LaunchRunner launchWithPlanPath:planPath
                                             entryJarPath:entryJar
                                           patchJarPath:patchJar
                                               jvmOptions:jvmOptions
                                                 javaHome:javaHome
                                                  gameDir:gameDir
                                                 userHome:userHome
                                                   tmpDir:tmpDir
                                            librariesPath:librariesDir
                                                 lwjglDir:lwjglDir
                                           frameworksPath:frameworks
                                            rendererDylib:renderer.identifier
                                              renderScale:renderScale];
                [A2Log log:@"[A2-LAUNCH] ③ 建 VM 返回 rc=%d", vmRC];
                if (vmRC == 0) {
                    return YES;
                }
                if (vmError) {
                    *vmError = [NSError errorWithDomain:@"A2LaunchChainCreateVM"
                                                   code:vmRC
                                               userInfo:@{ NSLocalizedDescriptionKey:
                        [A2LaunchFailure userMessageForVMFailureCode:vmRC] }];
                }
                return NO;
            }];

        NSError *chainError = nil;
        if ([chain runWithError:&chainError]) {
            finish(YES, 0, @"自研链：主类 main 正常返回");
            return;
        }

        // 如实分类（按【停在哪一步】），不把推测当结论。
        A2LaunchFailureClass cls = [A2LaunchFailure classForChainStage:chain.stage];
        if (cls == A2LaunchFailureClassJITBlocked) {
            // ★JIT 不可用 ⇒ 如实阻断：打判据行 + 给「怎么开」（按 verdict 分流的四语文案）★
            A2JITReadinessVerdict verdict = probe.lastVerdict;
            [A2Log log:@"%@", [A2LaunchFailure diagnosticForJITVerdict:verdict
                                                              evidence:probe.lastEvidence]];
            finish(NO, 0, [A2LaunchFailure userMessageForJITVerdict:verdict]);
            return;
        }
        if (cls == A2LaunchFailureClassVMFailed) {
            [A2Log log:@"[A2-CHAIN] ③ 建 VM 失败 rc=%d", vmRC];
            finish(NO, vmRC, [A2LaunchFailure userMessageForVMFailureCode:vmRC]);
            return;
        }
        finish(NO, 0, chainError.localizedDescription ?: @"启动链未完成");
    });
}


#pragma mark - 启动失败界面

/// 启动失败时呈现一个可读的失败页（替代“直接闪退”）。
///   入口：A2LaunchSession.finish()（started == NO）。
+ (void)a2_presentLaunchFailureWithMessage:(NSString *)message returnCode:(NSInteger)rc {
    UIWindow *keyWin = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { keyWin = w; break; }
        }
    }
    UIViewController *top = keyWin.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (top == nil) return;

    NSString *title = [NSString stringWithFormat:@"启动失败（rc=%ld）", (long)rc];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:message ?: @"启动链未完成"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"日志在哪" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        // ★不做死钩子★：这里直接给出日志文件的真实路径（A2Log 的唯一真相源），
        //   并把它复制到剪贴板，用户可直接去「文件」App 打开。
        NSString *path = [A2Log currentLogPath] ?: @"(未知)";
        UIPasteboard.generalPasteboard.string = path;
        UIAlertController *p2 = [UIAlertController alertControllerWithTitle:@"日志路径（已复制）"
                                                                    message:path
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [p2 addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *t2 = top;
        while (t2.presentedViewController) t2 = t2.presentedViewController;
        [t2 presentViewController:p2 animated:YES completion:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

@end
