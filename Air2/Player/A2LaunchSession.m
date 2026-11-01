//
//  A2LaunchSession.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  编排实现。★所有取值都在本层解析完，交给 Natives 的只有「已解析参数」★。
//

#import "A2LaunchSession.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>   // 启动失败界面（UIAlertController / UIWindowScene）
#import "A2LaunchPlan.h"
#import "A2LaunchOverlay.h"
#import "A2LaunchRunner.h"
#import "A2LaunchChain.h"            // ①→②→③ 的顺序与状态（★单一真相源★）
#import "A2LaunchFailure.h"          // 失败分类 / 判据行 / 用户文案（Player 纯逻辑）
#import "A2LaunchAlertPresenter.h"   // 顶层宿主查找（失败页用；10 次免责确认已迁到插件安装）
#import "A2JITReadinessProbe.h"       // ② 的结论枚举（verdict；判据实现见 A2JITEnabler）
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
#import "A2LegacyProfile.h"
#import "A2IntegrityChecker.h"
#import "A2JITEnabler.h"
#import "A2LegacyJITGate.h"            // Natives/Support —— JIT 闸门的唯一实现（判据→申请→等待）
#import "A2LegacyAssetsMapper.h"    // Core/Version —— 远古资源映射（virtual / map_to_resources）
#import "A2Log.h"

// ② 的判据 / 闰门全部落在 Natives/Support/A2LegacyJITGate（老 Air 原样移植）：
//   本文件不再持有探测预算常量 —— 判据自己有 2s 限流与缓存，不再由调用方给预算。

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
///   26.1 及其它 26.x → MobileGlues（GL3.2+ 需要它）
///   ★1.17 – 1.21.x → 系统 GLES 3.0（EAGL，`libeagl.dylib`）★ —— 2026-10-31 决定：
///     临时改成宿主自带后端（EGL = 本二进制的假 EGL → CAEAGLLayer 上屏，GL 层 = MobileGlues）；
///     MobileGlues 仍作为可选项保留（设置 → 运行环境 → 渲染器）。
///   1.13 – 1.16 → MobileGlues（该段还没在 EAGL 链路上验过）
///   1.12 及更早 → NG-GL4ES / KW（GL1.x/2.x 固定管线；不可用时由调用点回退 gl4es）
static NSString *A2DefaultRendererForVersion(NSInteger major, NSInteger minor) {
    if (major >= 26) {
        if (major == 26 && (minor == 2 || minor == 3)) return @"libmetallum.dylib";
        return @"libmobileglues.dylib";
    }
    if (major == 1 && minor >= 17) return A2RendererHostEGLDylibName;
    if (major == 1 && minor >= 13) return @"libmobileglues.dylib";
    if (major == 1 && minor <= 12) return A2RendererNGGL4ESKWDylibName;
    return @"libgl4es_114.dylib";   // 远古轨道（classic/Alpha/Beta，major=0）仍走老线兼容底
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

    // ★2026-10-31 26.3 的 LWJGL 档位★
    //   真机证据（iPhone X / 26.3）：启动卡在 org.lwjgl.sdl.SDLKeyboard$Functions 类初始化。
    //   26.3 的版本 JSON 按 LWJGL 3.4.3 声明（含 lwjgl-sdl），而 3.4.1 的 classpath 上
    //   根本没有 org.lwjgl.sdl.*（SDL 模块 3.4.0 才引入）。包内同时带 341/343：
    //     26.2 → 341（GLFW 路径）
    //     26.3+ → 343（SDL3 路径）
    //   其余版本仍沿用「取最大 3.x」的旧口径。
    NSInteger wantedVer = 0;
    if (mcMajor >= 26) {
        wantedVer = (mcMinor >= 3) ? 343 : 341;
    } else if (mcMajor == 1 && mcMinor >= 13) {
        wantedVer = 341;
    }
    if (wantedVer > 0 && !wantsLWJGL2) {
        NSString *exact = nil, *above = nil;
        NSInteger aboveVer = 0;
        for (NSString *name in preferred) {
            NSInteger v = A2LwjglVersionNumber(name);
            if (v == wantedVer) { exact = name; break; }
            if (v > wantedVer && (above == nil || v < aboveVer)) { above = name; aboveVer = v; }
        }
        if (exact) {
            [A2Log criterion:@"[A2-LWJGL] 档位命中：MC %ld.%ld ⇒ 期望 %ld，选 %@",
             (long)mcMajor, (long)mcMinor, (long)wantedVer, exact];
            preferred = [@[exact] mutableCopy];
        } else if (above) {
            [A2Log criterion:@"[A2-LWJGL] ⚠ 无 %ld 档位，退到最近的更高档 %@（MC %ld.%ld）",
             (long)wantedVer, above, (long)mcMajor, (long)mcMinor];
            preferred = [@[above] mutableCopy];
        } else {
            [A2Log criterion:@"[A2-LWJGL] ⚠ 无 %ld 及以上档位 ⇒ 继续用现有最大档（MC %ld.%ld）",
             (long)wantedVer, (long)mcMajor, (long)mcMinor];
        }
    }

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

    // ★2026-11-01 声音★ 真机：画面已出、OpenAL initialized、Sound engine started，但没有任何声音。
    //   原因是没有把 AVAudioSession 设成 playback 并激活 —— OpenAL 能初始化，输出却被系统静音。
    //   这里在启动链最开始显式激活一次（失败只记日志，不阻断启动）。
    {
        NSError *a2AudioErr = nil;
        AVAudioSession *a2Session = AVAudioSession.sharedInstance;
        [a2Session setCategory:AVAudioSessionCategoryPlayback
                          mode:AVAudioSessionModeDefault
                       options:0
                         error:&a2AudioErr];
        [a2Session setActive:YES error:&a2AudioErr];
        [A2Log criterion:@"[A2-AUDIO] 会话激活 category=playback active=YES err=%@",
         a2AudioErr.localizedDescription ?: @"(none)"];
    }

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
    // ========================================================================
    // ★JIT 闸门（启动链的唯一入口）★
    // ------------------------------------------------------------------------
    // 判据 → 申请 → 等待 → 回调，全部在 Natives/Support 的一处（A2JITEnabler；
    // 移植自老 Air 的 invokeAfterJITEnabled: 机制）。本层只做两件事：
    //   · 已就绪 ⇒ 放行（26.2 上「JIT 已就绪」的行为与之前逐字一致，只多一行判据）；
    //   · 未就绪 ⇒ ★本次启动到此为止★（不写计划、不建 VM、不往下走一步），
    //     由模块先弹「正在等待 JIT」再拉起使能器；回调里成功才重新进入启动链。
    // ★为什么必须是「无条件 return」★：无 JIT 建 VM = HotSpot 首帧取指 SIGBUS
    //   （直接闪退，连失败页都没有）—— 这条分支里任何一个能继续往下的缝隙都不允许存在。
    // ========================================================================
    // ★在途护栏★ 等待期间再点一次「启动」不许叠第二条启动请求
    //   （叠了会在回调里跑两次启动 ⇒ 两个 VM）。标记只在主线程读写：本方法的所有调用点
    //   （首页启动按钮 / AppDelegate 的「重挂后自动继续」）都在主线程。
    static BOOL sWaitingForJIT = NO;
    if (sWaitingForJIT) {
        [A2Log criterion:@"[A2-JIT-ENABLER] 仍等待中，本次启动已终止（上一条请求还在等 JIT，不叠第二次启动）"];
        // 这不是失败（有别的启动请求在等）⇒ 不弹失败页，只把「本次没启动」如实带回去。
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([A2LaunchSessionResult resultWithStarted:NO
                                                     returnCode:0
                                                        message:@"正在等待 JIT：本次启动已终止（请先处理「正在等待 JIT」窗口里的提示）"]);
        });
        return;
    }

    // ★老 Air 口径★ isJITEnabled 为真（entitlement / CS_DEBUGGED）就**直接启动**，
    //   不再走自造的握手/尺寸等待；只有它也为假才去拉起使能器并等待。
    if (!A2JITIsEnabled(0) && ![A2JITEnabler isJITReadyNow]) {
        [A2Log criterion:@"[A2-JIT-ENABLER] 未就绪 ⇒ 中止启动（不建 VM）（先弹等待窗 → 再拉起使能器 → 拿到 JIT 才重新启动）"];
        sWaitingForJIT = YES;
        __block BOOL resumed = NO;   // ★重入护栏★：同一次等待只认第一次回调
        [A2JITEnabler ensureJITThen:^(BOOL ok) {
            if (resumed) {
                [A2Log criterion:@"[A2-JIT-ENABLER] 仍等待中，本次启动已终止（重复回调已忽略）"];
                return;
            }
            resumed = YES;
            sWaitingForJIT = NO;
            if (!ok) {
                NSString *why = [A2JITEnabler lastFailureReason] ?: @"原因未知";
                [A2Log criterion:@"[A2-JIT] 没拿到 JIT ⇒ 出失败页（不建 VM）：%@", why];
                finish(NO, 0, [NSString stringWithFormat:
                               @"没有拿到 JIT：%@。\n请按提示为 Air2 开启 JIT 后重试（安装源与所走路径见日志 [A2-JIT-SRC] 行）。", why]);
                return;
            }
            // ★回调说「已就绪」也要现场再问一次判据★：判据只在一处，回调只是信号；
            //   两者不一致时以判据为准（宁可停，也不带着可疑状态进链）。
            if (![A2JITEnabler isJITReadyNow]) {
                NSString *why = [A2JITEnabler lastFailureReason] ?: @"现场判据仍未通过";
                [A2Log criterion:@"[A2-JIT-ENABLER] 仍等待中，本次启动已终止（回调称已就绪，现场判据仍否：%@）", why];
                finish(NO, 0, [NSString stringWithFormat:
                               @"没有拿到 JIT：%@。\n请按提示为 Air2 开启 JIT 后重试（安装源与所走路径见日志 [A2-JIT-SRC] 行）。", why]);
                return;
            }
            [A2Log criterion:@"[A2-JIT] 已拿到 JIT ⇒ 重新进入启动链（第二轮判据即就绪）"];
            // ★把调用方的 completion 一路带下去★：否则外层调用者永远等不到结果
            //   （首页的加载态会一直转，90s 看门狗再补一句「没返回」）。
            [A2LaunchSession startCurrentVersionWithCompletion:completion];
        }];
        return;   // ★回调不在本调用栈里发生★（模块保证异步）；本次启动到此为止
    }
    [A2Log log:@"[A2-JIT] 已就绪 ⇒ 直接启动（判据明细见上一条 [A2-JIT-ENABLER] 行）"];

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

    // ★默认推导的回退（只对「没人显式选过」生效）★
    //   ≤1.12 的默认项是 NG-GL4ES / KW；它不在包内（或文件在但 dlopen 不起来）⇒ 退到同一家族
    //   的老线 gl4es（同一份选择逻辑里回退，不是在下游偷偷换后端）。
    //   用户/实例显式选了它 ⇒ 不走这里：下面 isBundled 闸门会如实阻断并给出原因。
    if (!rendererFromUser && [renderer.identifier isEqualToString:A2RendererNGGL4ESKWDylibName]) {
        NSString *fallbackWhy = [A2RendererCatalog bundleDiagnosisForCandidate:renderer
                                                              frameworksPath:frameworks];
        A2Renderer *compatFallback = [A2RendererCatalog candidateForIdentifier:@"libgl4es_114.dylib"];
        if (fallbackWhy != nil && compatFallback != nil) {
            [A2Log criterion:@"[A2-RENDERER] 回退 gl4es：默认项 %@ 不可用（%@）⇒ %@",
             renderer.identifier, fallbackWhy, compatFallback.identifier];
            renderer = compatFallback;
        }
    }

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
        // ★判据行带原因★：未内置有两种（缺文件 / 文件在但 dlopen 失败），分开写清
        NSString *why = [A2RendererCatalog bundleDiagnosisForCandidate:renderer
                                                      frameworksPath:frameworks] ?: @"原因未知";
        [A2Log criterion:@"[A2-COMPAT] ❌ 渲染器 %@ 未内置（%@）⇒ 阻断", renderer.identifier, why];
        finish(NO, 0, [NSString stringWithFormat:
                       @"%@\n（%@）",
                       [NSString stringWithFormat:[A2RuntimeStrings stringForKey:@"runtime.blocked.renderer"],
                        name, renderer.identifier],
                       why]);
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

    // ★2026-10-31 真机「黑屏 + 无声」根因之一★
    //   日志：`[A2-GLFW] 焦点变化 window=1 focused=0`；options.txt 里 `pauseOnLostFocus:true`。
    //   MC 在窗口失焦时会暂停整个游戏循环 ⇒ 既不出帧（黑屏），也不出声（sound engine 已 started 但 paused）。
    //   我们的 GLFW 宿主窗口本来就没有系统焦点概念（UIWindow 背后是游戏视图），
    //   所以这里在启动前把 MC 自己的选项改成不因失焦暂停。只动这一个键，其余原样保留。
    {
        NSString *optPath = [gameDir stringByAppendingPathComponent:@"options.txt"];
        NSMutableString *txt = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:optPath]) {
            txt = [NSMutableString stringWithContentsOfFile:optPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        }
        if (txt == nil) txt = [NSMutableString string];
        NSString *key = @"pauseOnLostFocus:";
        BOOL touched = NO;
        if ([txt rangeOfString:key].location != NSNotFound) {
            NSRegularExpression *re =
                [NSRegularExpression regularExpressionWithPattern:@"(?m)^pauseOnLostFocus:.*$"
                                                          options:0 error:nil];
            NSRange all = NSMakeRange(0, txt.length);
            if ([re numberOfMatchesInString:txt options:0 range:all] > 0) {
                [re replaceMatchesInString:txt options:0 range:all
                                withTemplate:@"pauseOnLostFocus:false"];
                touched = YES;
            }
        } else {
            if (txt.length > 0 && ![txt hasSuffix:@"\n"]) [txt appendString:@"\n"];
            [txt appendString:@"pauseOnLostFocus:false\n"];
            touched = YES;
        }
        if (touched) {
            NSError *wErr = nil;
            if ([txt writeToFile:optPath atomically:YES encoding:NSUTF8StringEncoding error:&wErr]) {
                [A2Log criterion:@"[A2-OPTIONS] pauseOnLostFocus 已置 false（避免失焦暂停 ⇒ 黑屏/无声）path=%@", optPath];
            } else {
                [A2Log log:@"[A2-OPTIONS] 写 options.txt 失败（不阻断启动）：%@", wErr.localizedDescription];
            }
        }
    }

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
    // ========================================================================
    // ★[A2-COMPAT] 渲染器 × 版本 × JRE 三元闸门（先判后拦）★
    // ------------------------------------------------------------------------
    // 为什么要有这一段：`isBundled` 只答「文件在不在」，答不了「这个后端能不能
    // 在这个版本 + 这个 JRE 上跑」。三条静态失败组合就是从这个缺口漏下去的：
    //   ① MoltenVK 当 GL 后端（Vulkan ICD，无 EGL/gl*）⇒ 100% 闪退；
    //   ④ metallum × JRE<25（类集主版本 69）⇒ 建 VM 失败 / 黑屏；
    //   ⑥ gl4es 家族 × 1.13+（GL 上限 2.1 < 要求的 3.2 core）⇒ Unsupported GL version。
    // 判据全部来自 A2RendererCatalog 的静态元数据（一处定义），本段只消费结果。
    // ★口径★：判据不满足 ⇒ `finish(NO,…)` 出可读失败页（不闪退、不静默换后端）。
    // ========================================================================
    {
        A2RendererGLClass glClass = [A2RendererCatalog glClassForIdentifier:renderer.identifier];
        BOOL wantsModernGL = (a2McMajor >= 26) || (a2McMajor == 1 && a2McMinor >= 13);

        // ① 非 GL 后端：本链只会把它写成 `-Dorg.lwjgl.opengl.libname`，
        //    而它的真实身份是 Vulkan ICD（`-Dorg.lwjgl.vulkan.libname` 已由计划无条件下发）。
        if (glClass == A2RendererGLClassNotGL) {
            [A2Log criterion:@"[A2-COMPAT] ❌ %@ 不是 GL 后端（Vulkan ICD：无 EGL、无 gl* 导出）"
             @"⇒ 阻断。它的 Vulkan 身份由 -Dorg.lwjgl.vulkan.libname 承担，不能当 opengl.libname 用",
             renderer.identifier];
            finish(NO, 0, [NSString stringWithFormat:
                           @"%@ 是 Vulkan 驱动（MoltenVK），不是 OpenGL 后端。\n"
                           @"当前启动链只支持 GL / Metal 后端，把它当作 OpenGL 库加载取不到 gl* 符号，"
                           @"必然闪退 —— 已拦下（没有建 VM）。\n\n"
                           @"请在「设置 → 运行环境 → 渲染器」改选 Metal (metallum) 或 MobileGlues 后重试。",
                           renderer.identifier]);
            return;
        }

        // ④ 渲染器 × JRE 下限（metallum：26.x 需 25、1.21.11 需 21）
        NSInteger needJRE = [A2RendererCatalog requiredJavaMajorForIdentifier:renderer.identifier
                                                                    versionID:version.name
                                                                      mcMajor:a2McMajor
                                                                      mcMinor:a2McMinor];
        if (needJRE > 0 && jreMajor > 0 && jreMajor < needJRE) {
            [A2Log criterion:@"[A2-COMPAT] ❌ %@ 需要 java-%ld（类集按 Java %ld 编译），当前 java-%ld"
             @"（%@）⇒ 阻断", renderer.identifier, (long)needJRE, (long)needJRE, (long)jreMajor, jreDir];
            finish(NO, 0, [NSString stringWithFormat:
                           @"%@ 的注入类集是用 Java %ld 编译的（class 主版本 %ld），"
                           @"当前选的是 Java %ld —— 在低版本 JRE 上它要么 premain 加载失败（建 VM 失败），"
                           @"要么一个类也 define 不上（黑屏）。\n\n"
                           @"两条出路：\n"
                           @"· 改选 Java 运行时 java-%ld-openjdk（设置 → 运行环境 → Java 运行时）；\n"
                           @"· 或改选 MobileGlues 渲染器（不挑 JRE）。",
                           renderer.identifier, (long)needJRE, (long)(needJRE + 44),
                           (long)jreMajor, (long)needJRE]);
            return;
        }

        // ⑥ 版本 × GL 能力下限（gl4es 家族：GL 1.x/2.x 固定管线 ⇒ 只接 1.12.2 及更早）
        if (glClass == A2RendererGLClassFixedOnly && wantsModernGL) {
            [A2Log criterion:@"[A2-COMPAT] ❌ %@ 的 GL 上限是 2.1（固定管线翻译层），"
             @"而 MC %@ 要求 GL 3.2+ core ⇒ 阻断（否则 GL.createCapabilities 抛 Unsupported GL version）",
             renderer.identifier, version.name];
            finish(NO, 0, [NSString stringWithFormat:
                           @"%@ 是 GL 1.x/2.x 的固定管线翻译层（对外最多报 GL 2.1），"
                           @"而 %@ 启动时要 GL 3.2+（core profile）—— 接不上，已拦下（没有建 VM）。\n\n"
                           @"请在「设置 → 运行环境 → 渲染器」改选 MobileGlues（GL 4.5）后重试。",
                           renderer.identifier, version.name]);
            return;
        }

        [A2Log criterion:@"[A2-COMPAT] ✅ %@ × %@ × java-%ld 通过闸门"
         @"（glClass=%ld needJRE=%ld wantsModernGL=%d）",
         renderer.identifier, version.name, (long)jreMajor, (long)glClass, (long)needJRE,
         wantsModernGL ? 1 : 0];

        // ⑦ metallum 类集覆盖（保持「只告警」口径：没有类集 ≠ 一定崩，但会无内容可注入）
        if ([renderer.identifier.lowercaseString containsString:@"metallum"]) {
            BOOL agentSupports = (a2McMajor >= 26) ||
                                 (a2McMajor == 1 && a2McMinor == 21 && [version.name hasPrefix:@"1.21.11"]);
            if (!agentSupports) {
                [A2Log criterion:@"[A2-COMPAT] ⚠️ metallum 官方类集只覆盖 1.21.11 / 26.x，"
                 @"本版本 %@ 属未验证组合（无类集可注入 ⇒ 有声音没画面的形态；仍会尝试注入）", version.name];
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

    // ★实例级自定义 JVM 参数★（`A2VersionIsolation.jvmArgs`：UI 有写、持久化有存，
    //   但此前**启动链从来没读过** —— 死字段）。这里补「读」的一侧：
    //   按空白切分后原样追加到 VM 选项末尾（位置在计划选项之后、主类之前）。
    //   用途之一就是 P0 spike：`-javaagent:<libs>/spike1201_agent.jar=dir=<dir>`，
    //   不必为每个实验再改一次启动器。
    {
        NSString *extra = version.isolation.jvmArgs;
        if (extra.length > 0) {
            NSMutableArray<NSString *> *tokens = [NSMutableArray array];
            for (NSString *t in [extra componentsSeparatedByCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
                if (t.length > 0) {
                    [tokens addObject:t];
                }
            }
            if (tokens.count > 0) {
                [jvmOptions addObjectsFromArray:tokens];
                [A2Log criterion:@"[A2-AGENT] 实例 JVM 参数：%lu 个 token（首项 %@）",
                 (unsigned long)tokens.count, tokens.firstObject];
            }
        }
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

        // ★2026-10-31 真机 crash report 证据（1.20.1 + MG，包 7f91f1d）★
        //   崩在「Initializing game」：
        //     NoClassDefFoundError: com.sun.jna.Native  ← oshi.hardware.platform.mac.MacCentralProcessor
        //     UnsatisfiedLinkError: JNA 解出的 dylib “incompatible platform (have 'macOS', need 'iOS')”
        //   ⇒ MC 用 oshi 探硬件 → oshi 走 JNA → JNA 从 jar 解出 macOS 二进制 → iOS dlopen 失败。
        //   ⇒ **patchjna_agent.jar 必须对所有渲染器无条件注入**，不能只给 Metal 那条路。
        {
            NSString *libs = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"libs"];
            [jvmOptions addObject:[NSString stringWithFormat:@"-javaagent:%@/patchjna_agent.jar=", libs]];
            [A2Log criterion:@"[A2-AGENT] 注入 patchjna_agent.jar（所有渲染器；修 oshi/JNA 在 iOS 上 dlopen macOS 库）"];

            // ★2026-10-31 老 Air 正解（JavaLauncher.m:2027-2090 [JNA-INBUNDLE]）★
            //   真机 lastlog-110 证明 patchjna agent 不足以阻止 JNA 从 jar 解出 macOS 镜像：
            //     NoClassDefFoundError: com.sun.jna.Native
            //     UnsatisfiedLinkError: jnaNNN.tmp ... incompatible platform (have 'macOS', need 'iOS')
            //   老 Air 的做法是：包内自带 iOS 的 libjnidispatch.jnilib（我们包里已有），
            //   并把 JNA 的三条回退全部关掉，强制它只从包内加载。
            NSString *jnaFW = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
            NSString *jnaLib = [jnaFW stringByAppendingPathComponent:@"libjnidispatch.jnilib"];
            BOOL jnaInBundle = [[NSFileManager defaultManager] fileExistsAtPath:jnaLib];
            [jvmOptions addObject:[NSString stringWithFormat:@"-Djna.boot.library.path=%@", jnaFW]];
            [jvmOptions addObject:@"-Djna.nosys=true"];      // 不查系统库路径
            [jvmOptions addObject:@"-Djna.noclasspath=true"];// 真正阻止从 jar 解包
            [jvmOptions addObject:@"-Djna.nounpack=true"];   // 文档同义词
            [jvmOptions addObject:@"-Djna.debug_load.jna=true"];
            [A2Log criterion:@"[JNA-INBUNDLE] libjnidispatch bundle=%@ path=%@（nosys/noclasspath/nounpack 全开）",
             jnaInBundle ? @"present" : @"MISSING", jnaLib];

            // ★2026-10-31 真机 crash report：MC 1.20.1 在「Initializing game」阶段走 macOS AppKit：
            //   ca.weblite.objc.RuntimeUtils.<clinit> → System.load(tmp/libjcocoa*.dylib) → dlopen 失败
            //   ← Client.sendProxy ← ehg.a(44) ← ehn.a(154) ← enn.<init> ← Main.main
            // iOS 没有 AppKit、也没有 iOS 版 libjcocoa ⇒ 这段对我们必然是死代码。
            // patchios_agent 只把 ehg.a(J)V 改成 { return; }，ehg 的另一个 a(InputStream) 不动。
            NSString *iosAgent = [libs stringByAppendingPathComponent:@"patchios_agent.jar"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:iosAgent]) {
                [jvmOptions addObject:[NSString stringWithFormat:@"-javaagent:%@", iosAgent]];
                [A2Log criterion:@"[A2-IOS-AGENT] 注入 patchios_agent.jar（置空 ehg.a(J)V：跳过 macOS AppKit 菜单）"];
            } else {
                [A2Log criterion:@"[A2-IOS-AGENT] 缺 patchios_agent.jar ⇒ 不注入（1.20.1 会在 Initializing game 崩）"];
            }
        }

        if (wantsMetalAgent) {
            NSString *libs = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"libs"];
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
            // ★宿主 EGL 后端（libeagl.dylib）★：EGL 那一半在我们自己的二进制里（假 EGL → EAGL），
            //   所以这里下发的是 **GL 层**的名字（MobileGlues = GL 3.2+ 翻译到宿主 GLES 3.0）；
            //   不把 `eagl` 写成 libname（包内没有、也不该有 libeagl.dylib 这个库）。
            const BOOL hostEGLBackend = [rendererID isEqualToString:A2RendererHostEGLDylibName];
            NSString *bare = hostEGLBackend ? @"mobileglues" : rendererID;
            if ([bare hasPrefix:@"lib"]) bare = [bare substringFromIndex:3];
            if ([bare hasSuffix:@".dylib"]) bare = [bare substringToIndex:bare.length - 6];
            if (bare.length > 0) {
                [jvmOptions addObject:[NSString stringWithFormat:@"-Dorg.lwjgl.opengl.libname=%@", bare]];
                // ★同时设 opengles.libname★（真机 hs_err 证据：MC 1.7.10 的 GL11.glLoadIdentity
                //   经 lwjglx 落到 LWJGL 的 **GLES** 绑定，而 GLES 绑定读的是 opengles.libname，
                //   默认值就是 libGLESv2 → 打到 ANGLE 的 GLES1 状态机 ⇒ SIGBUS）。
                [jvmOptions addObject:[NSString stringWithFormat:@"-Dorg.lwjgl.opengles.libname=%@", bare]];
                [A2Log criterion:@"[A2-AGENT] GL 后端：opengl.libname=%@ opengles.libname=%@", bare, bare];
                if (hostEGLBackend) {
                    // ★判据行★：一眼看出「EGL 是谁、GL 是谁」（真机 grep 这一行）。
                    [A2Log criterion:@"[A2-RENDERER] 宿主 EGL 后端：EGL=本二进制假 EGL（a2_eagl_egl → CAEAGLLayer 上屏）"
                     @" GL 层=%@（渲染器标识 %@）", bare, rendererID];
                }

                // ★2026-10-31 对齐老 Air（tree510 egl_bridge.m:317-324）★
                //   MobileGlues 是「GL on host GLES」那一类 ⇒ 后端类型必须是 DirectGLES；
                //   不设时 MG 会走默认后端（DirectVulkan）并因缺 Vulkan 上下文而崩在 glGetError。
                //   同时把 MG 自己的日志指到可导出路径，出问题能直接看它内部初始化到哪一步。
                if ([bare rangeOfString:@"mobileglues"].location != NSNotFound) {
                    setenv("MOBILEGL_BACKEND_TYPE", "DirectGLES", 1);
                    // ★2026-11-01★ ANGLE(iOS/Metal) 只呈现到视图的 backing layer。
                    //   MG 路径下把游戏视图的 +layerClass 切成 CAMetalLayer（见 a2_glfw_input.m），
                    //   否则我们只能外挂子层 ⇒ swap 返回 EGL_SUCCESS 却上不了屏。
                    setenv("A2_GL_METAL_HOST", "1", 1);
                    NSString *mgDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                    NSString *mgLog = [NSString stringWithFormat:@"%@/mobilegl.log", mgDir ?: NSTemporaryDirectory()];
                    setenv("MOBILEGL_LOG_FILE_PATH", mgLog.UTF8String, 1);

                    // ★2026-10-31 真机 lastlog-106 证据★
                    //   MG 崩溃 `glGetError+0x14 pc=0x0`，根因是它自己的宿主函数表为空：
                    //   `EGL entry point eglGetDisplay is not available in the backend library`。
                    //   MG 二进制里带 `MG_DIRECTORY_PATH` / `MG_DIR_PATH` 两个目录变量 —— 指向
                    //   App 的 Frameworks（内含 libEGL.framework / libGLESv2.framework），
                    //   让 MG 自己按名字加载 ANGLE 当宿主，不再依赖 flat namespace（dyld 共享缓存抢不过）。
                    NSString *fwDir = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
                    if (fwDir.length) {
                        setenv("MG_DIRECTORY_PATH", fwDir.UTF8String, 1);
                        setenv("MG_DIR_PATH", fwDir.UTF8String, 1);
                    }
                    [A2Log criterion:@"[A2-AGENT] MG 后端：MOBILEGL_BACKEND_TYPE=DirectGLES log=%@ dir=%@",
                     mgLog, fwDir ?: @"(nil)"];
                } else {
                    unsetenv("MOBILEGL_BACKEND_TYPE");
                    unsetenv("MOBILEGL_LOG_FILE_PATH");
                    unsetenv("MG_DIRECTORY_PATH");
                    unsetenv("MG_DIR_PATH");
                    unsetenv("A2_GL_METAL_HOST");
                }
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

    // ========================================================================
    // ★启动前完整性核对★（口径对齐 PCL：对着版本清单逐项核，不是只看目录在不在）
    //   目的：缺库/坏 jar 时立刻给可读结论，而不是白花 20 秒建 VM 再崩。
    //   开关：设置→「跳过完整性检查」(A2GlobalSkipIntegrityCheck) 或版本级覆盖。
    // ========================================================================
    {
        BOOL globalSkip = A2Settings.shared.skipIntegrityCheck;
        BOOL skip = [version.isolation shouldSkipIntegrityCheckWithGlobal:globalSkip] || globalSkip;
        if (skip) {
            [A2Log criterion:@"[A2-INTEGRITY] 已按设置跳过完整性检查"];
        } else {
            A2IntegrityReport *rep = [A2IntegrityChecker checkVersionAtPath:version.versionPath
                                                                  versionID:version.name
                                                                   gameHome:gameHome];
            [A2Log criterion:@"[A2-INTEGRITY] %@", rep.summary];
            if (rep.level == A2IntegrityLevelFatal) {
                [A2Log criterion:@"[A2-INTEGRITY] ★阻断启动★ %@", rep.fatalReason ?: @"完整性检查未通过"];
                finish(NO, 0, [NSString stringWithFormat:@"版本不完整：%@",
                               rep.fatalReason ?: @"请重新下载该版本"]);
                return;
            }
            if (rep.level == A2IntegrityLevelWarning) {
                [A2Log criterion:@"[A2-INTEGRITY] 告警（不拦路）：%@", rep.summary];
            }
        }
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
        //   ★JIT 是否可用只由老 Air 那套判据给出（A2LegacyJITGate，经 A2JITEnabler）★ ——
        //   A2JITEnvironment 的自创口径（entitlement / CS_DEBUGGED / verifiedRegion 放行）
        //   已停用：两套判据同时参与会互相打架（真机症状：先死后放 / 放行后闪退）。
        //   ★禁止用局部 BOOL 记 JIT 状态★（历史缺陷：早期下发路径用局部变量记「已就绪」，
        //   与判据结果不一致 ⇒ 误判；本单改用单一真相源，见 tests/JIT §⑱ 的回归断言）。
        __block int vmRC = 0;
        // ② 的结论 / 取证（只作日志与失败页文案；判定本身在 A2LegacyJITGate 里）。
        __block A2JITReadinessVerdict lastVerdict = A2JITReadinessVerdictUnknown;
        __block NSString *lastEvidence = nil;

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
                // ② ★唯一判据 = 老 Air（tree510）那套★：A2JITEnabler → A2LegacyJITGate 的
                //   `A2LegacyJITGateReadyNow`（= AMEJITWaitReadyVerified）。这里**不再**调
                //   A2JITEnvironment 的自创口径，避免两套判据打架。
                NSString *gateWhy = nil;
                BOOL ok = [A2JITEnabler isJITReadyNowWithReason:&gateWhy];
                lastVerdict = ok ? A2JITReadinessVerdictUsable : A2JITReadinessVerdictNotServiced;
                lastEvidence = gateWhy;
                // ★这一行就是「JIT 就绪结论」★：verdict / enable（是否放行建 VM）/ reason 齐备，
                //   供真机一眼判成败（未就绪=NotServiced；老 Air 判据只有这两档）。
                [A2Log log:@"%@", [A2LaunchFailure jitvmLineWithStep:@"verify"
                                                             verdict:lastVerdict
                                                           enableJIT:ok
                                                          reasonText:gateWhy
                                                            evidence:nil]];
                if (!ok && reason) *reason = gateWhy;
                return ok;
            }
            createJVM:^BOOL(NSError **vmError) {
                // ============================================================
                // ★★建 VM 之前的唯一闰门（老 Air `JavaLauncher.m` 原样移植）★★
                //   老 Air 在这一步做的是：发一发 `brk #0x69` 确认调试器在服务、拿到
                //   Universal 脚本的哨兵后下发 UniversalJIT26Extension.js（把
                //   legacyCommands[0x69] 换成真建区）+ 设 detachAfterFirstBr + 清
                //   EXC_MASK_BAD_ACCESS 异常端口。**这些动作缺一不可**：跳过它直接建 VM
                //   就是「没真的开 JIT 却建 VM」⇒ 首帧取指 SIGBUS（真机闪退的根因）。
                //   ★本块是全工程唯一建 VM 的地方★（launchWithPlanPath 的唯一调用点），
                //   所以闰门也只能挂在这里。
                // ============================================================
                NSString *gateWhy = nil;
                if (![A2JITEnabler openLegacyGateBeforeVMBuild:&gateWhy]) {
                    [A2Log criterion:@"[A2-JIT-GATE] 未就绪 ⇒ 中止启动（不建 VM）（老 Air 闰门拦下）"];
                    if (vmError) {
                        *vmError = [NSError errorWithDomain:A2LaunchChainJITGateErrorDomain
                                                       code:-1
                                                   userInfo:@{ NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:
                                @"建 VM 前的 JIT 闰门未通过 —— ★没有创建 VM★（不会闪退）。\n%@\n"
                                @"请按本次安装源对应的方式为 Air2 开启 JIT 后重试（SideStore/StikDebug 需指派 UniversalJIT26 脚本；"
                                @"TrollStore 机见日志 [A2-JIT-SRC] 行）；"
                                @"判据明细见日志 [A2-JIT-GATE] / [JIT-FLOW] 行。",
                                gateWhy ?: @"原因未知"] }];
                    }
                    return NO;
                }
                // ③ Bridge 唯一调 a2_launch_jvm_with_argv 的地方（★只有闰门放行才会走到这里★）。
                [A2Log log:@"%@", [A2LaunchFailure jitvmLineWithStep:@"vm"
                                                             verdict:lastVerdict
                                                           enableJIT:YES
                                                          reasonText:gateWhy ?: @"JIT 已就绪 ⇒ 走带 JIT 的启动参数路径"
                                                            evidence:lastEvidence]];
                [A2Log log:@"[A2-LAUNCH] ③ 建 VM 开始（可能要 10~60 秒；若之后没有“建 VM 返回”行 ⇒ 卡在建 VM）"];
                // ★区域验收快照（建 VM 前）★：拿到的是 64MB 还是一页/没有，一眼可见。
                //   拿不到不是错误（iOS 26+ 的区由 libjvm 建 VM 时自己发 brk #0x69 取）。
                [A2JITEnabler logRegionSnapshot:@"before-vm"];
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
                // ★区域验收快照（建 VM 之后）★：此刻 libjvm 已经发过它自己那发 brk #0x69，
                //   这一行如实报本模块视角拿到的区（拿不到不追责：libjvm 的 rc 才是结论）。
                [A2JITEnabler logRegionSnapshot:@"after-vm"];
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
        // ★建 VM 前的 JIT 自检拦下★：VM 一次都没创建 ⇒ 不是「建 VM 失败 rc=…」，
        //   按 JIT 阻断如实报（错误域由链原样带回，见 A2LaunchChainJITGateErrorDomain）。
        if ([chainError.domain isEqualToString:A2LaunchChainJITGateErrorDomain]) {
            [A2Log criterion:@"[A2-CHAIN] ③ 未进入：JIT 就绪校验在建 VM 前拦下 —— %@",
             chainError.localizedDescription ?: @"(无详情)"];
            finish(NO, 0, chainError.localizedDescription ?: @"JIT 未就绪：没有创建 VM");
            return;
        }
        A2LaunchFailureClass cls = [A2LaunchFailure classForChainStage:chain.stage];
        if (cls == A2LaunchFailureClassJITBlocked) {
            // ★JIT 不可用 ⇒ 如实阻断：打判据行 + 给「怎么开」（按 verdict 分流的四语文案）★
            A2JITReadinessVerdict verdict = lastVerdict;
            [A2Log log:@"%@", [A2LaunchFailure diagnosticForJITVerdict:verdict
                                                              evidence:lastEvidence]];
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
    // ★宿主查找只有一处★：`A2LaunchAlertPresenter +topViewController`（同一段
    //   「key window → 沿 presentedViewController 下钻」不留第二份拷贝）。
    // ★本类不再承载任何确认门★：10 次免责确认已迁到「安装会改启动链的插件」
    //   （插件 tree 的 `A2PluginLaunchChainConfirm`）。
    UIViewController *top = [A2LaunchAlertPresenter topViewController];
    if (top == nil) return;

    NSString *title = [NSString stringWithFormat:@"启动失败（rc=%ld）", (long)rc];
    // ★正文不许为空串★：`?:` 只挡 nil，传进来空串时这里会变成一个「只有标题、正文空白」的半壳。
    NSString *detail = message.length ? message : @"启动链未完成（详见日志）";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:detail
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
