//
//  A2LaunchSession.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  编排实现。★所有取值都在本层解析完，交给 Natives 的只有「已解析参数」★。
//

#import "A2LaunchSession.h"
#import "A2LaunchPlan.h"
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
    NSString *lwjglDir = A2LaunchFirstSubdirectory([bundle stringByAppendingPathComponent:@"libs"],
                                                   @"lwjgl-");

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
    A2Renderer *renderer = [A2RendererCatalog candidateForIdentifier:selRenderer ?: @""]
        ?: [A2RendererCatalog defaultCandidate];
    BOOL rendererFromUser = (selRenderer.length > 0);
    NSString *rendererSource = instanceRenderer.length
        ? @"instance" : (rendererFromUser ? @"user" : @"default");
    NSString *rendererSourceWord = instanceRenderer.length
        ? @"实例设置"
        : [A2RuntimeStrings stringForKey:(rendererFromUser ? @"runtime.source.user"
                                                           : @"runtime.source.default")];
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
    NSArray<NSString *> *jvmOptions = [plan jvmOptionsWithMemoryMB:xmxMB
                                                  javaMajorVersion:jreMajor];

    // 建 VM 会阻塞 ⇒ 放后台队列；结果回主线程。
    [A2Log log:@"[A2-LAUNCH] 进入后台链：plan=%@ renderer=%@ jre=%@",
                 planPath.lastPathComponent ?: @"(nil)", renderer.identifier, jreDir];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
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
