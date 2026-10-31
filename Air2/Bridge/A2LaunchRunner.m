//
//  A2LaunchRunner.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  实现：把已解析好的取值组成 margv ⇒ Natives R4 拼 classpath ⇒ a2_launch_jvm_with_argv。
//  ★不新建任何启动语义★：主类名 / classpath 形态 / 资源注入全部沿用既有实现。
//

#import "A2LaunchRunner.h"
#import "A2LaunchContract.h"
#import "A2Log.h"

#import <UIKit/UIKit.h>        // ★只有本文件（Bridge 的启动链入口）读 UIKit★ —— 见 +currentRuntimeFacts 的注解
#import <math.h>              // lround（与 Natives/Input 的取整口径一致）
#import <os/proc.h>           // os_proc_available_memory() —— ★[MEM] 内存探测的唯一系统调用点★

#import "a2_launch.h"          // Natives/Context —— facade 与开关（Bridge → Natives 是允许方向）
#import "a2_resourcepaths.h"   // Natives/Context —— R4 classpath 唯一拼装点
#import "a2_renderer.h"        // Natives/Renderer —— 渲染后端「选 + 加载」入口（见 docs/ARCHITECTURE.md [RENDER-WIRE]）
#import "a2_gl_bridge.h"       // Natives/Renderer —— ★GL 桥★：让选中后端真的拿到 surface 并建出 GL 上下文（[GL-BRIDGE]）
#import "a2_frame_perf.h"      // Natives/Renderer —— ★[FRAME-PERF] 与渲染器无关的帧性能判据★

// ============================================================================
//  ★[GL-BRIDGE] 宿主表面采集 + 帧回调★（本文件的私有件；调用点见 +launchWithPlanPath:）
// ----------------------------------------------------------------------------
//  为什么在 Bridge：宿主表面来自 UIKit（承载游戏的宿主窗口），而 Core 明文不得 import
//  UIKit、Player 也不感知 UIKit；Bridge 是启动链唯一与 Natives 相邻的层（同 [LAUNCH-PLAN] 决策 2）。
//  ★唯一取面点★：将来专用游戏 surface 落地后，只把这里换成
//   Input 层的中立表面查询面（见 Natives/Input/a2_glfw_window.h）即可（同 [LAUNCH-PLAN-FACTS] 的口径）。
// ============================================================================

// ★取窗口的口径按用途分开，各只有一份实现（都在 Natives/Input/a2_controls_overlay.m）★：
//   · 控件覆盖层 → `a2_top_visible_window()`：要「最顶层」，否则被后建的画面窗压住；
//   · GL 宿主表面 → `a2_main_window()`：要「主窗口 / keyWindow」，drawable 必须挂在
//     真正被合成到屏幕上的窗口上。真机（1.20.1 + MobileGlues）用「最顶层」选中了 level=0
//     的辅助窗 ⇒ 上下文全绿、帧回调连发、屏幕纯黑。
extern UIWindow *a2_top_visible_window(void);
extern UIWindow *a2_main_window(void);      // ★GL 宿主表面专用★（控件覆盖层不要用它）

/// 帧回调计数（★静态★：改绑发生在本次调用返回之后，栈变量会变成悬垂指针）
static int gA2RunnerFrameCounter = 0;

/// 按**指定窗口**采集宿主表面（★主线程★：UIKit 查询契约要求）。
/// 口径（★尺寸口径唯一来源★）：点 = 窗口 bounds；像素 = 点 × screen.scale。
/// 这个像素值同时是 GL 桥向实现请求的 drawable 尺寸，也是它要设进宿主图层
/// （contentsScale / drawableSize）的值 —— 三处同源，见 a2_gl_bridge.m 的 ⑥0b。
static A2GlfwSurface A2RunnerSurfaceForWindow(UIWindow *host) {
    A2GlfwSurface out = {0};
    if (host == nil) return out;

    UIScreen *screen = host.windowScene.screen ?: UIScreen.mainScreen;
    CGFloat scale = screen.scale;                              // ★与 +currentRuntimeFacts 同口径★
    CGRect b = host.bounds;
    UIView *view = host.rootViewController.view ?: (UIView *)host;

    out.nativeView    = (__bridge void *)view;                  // 承载视图（GL 桥会取其 layer）
    out.nativeWindow  = (__bridge void *)host;
    out.widthPoints   = (int)lround(b.size.width);
    out.heightPoints  = (int)lround(b.size.height);
    out.widthPixels   = (int)lround(b.size.width  * scale);
    out.heightPixels  = (int)lround(b.size.height * scale);
    out.contentScaleX = (float)scale;
    out.contentScaleY = (float)scale;
    out.pixelFormat   = A2_GLFW_PIXEL_FORMAT_HOST_DEFAULT;

    // ★判据行★：窗口类别 / 层级 / 点尺寸 / scale / 像素尺寸全打出来（真机逐项对得上才算选对了）
    [A2Log criterion:@"[A2-COMPAT] 宿主表面取窗口=%@ level=%.0f bounds=%.0fx%.0f scale=%.2f"
     @" ⇒ 点=%dx%d 像素=%dx%d（口径=主窗口 keyWindow）",
     NSStringFromClass(host.class), (double)host.windowLevel,
     (double)b.size.width, (double)b.size.height, (double)scale,
     out.widthPoints, out.heightPoints, out.widthPixels, out.heightPixels];
    return out;
}

/// 采集宿主表面（★主线程★：UIKit 查询契约要求）。字段类型复用 Natives 的中立描述 `A2GlfwSurface`。
/// ★口径=主窗口（keyWindow）★：drawable 必须挂在真被合成到屏幕上的窗口上；
///   「最顶层可见窗口」会选到层级更高但不在画面栈里的辅助窗（真机 1.20.1 ⇒ 纯黑）。
static A2GlfwSurface A2RunnerHostSurface(void) {
    __block A2GlfwSurface out = {0};
    void (^grab)(void) = ^{
        UIWindow *host = a2_main_window();
        if (host == nil) {                                     // 取不到就如实留空，不伪造
            [A2Log log:@"[A2-COMPAT] ★取不到主窗口★（无前台活跃 scene 的 keyWindow，也没有 isKeyWindow 的窗口）"
                          @"⇒ 宿主表面为空"];
            return;
        }
        out = A2RunnerSurfaceForWindow(host);
    };
    if (NSThread.isMainThread) {
        grab();
    } else {
        dispatch_sync(dispatch_get_main_queue(), grab);
    }
    return out;
}

// ---------------------------------------------------------------------------
//  ★[FRAME-PERF] 判据节拍★（与渲染器无关：这里只数帧、打行；数值由桥记进 a2_frame_perf）
// ---------------------------------------------------------------------------
// 基线帧数：附着后由启动链驱动这么多帧（**预览态**）。★为什么必须有★：
//   本包内游戏帧源尚未接入（渲染器只到「选 + dlopen」）⇒ 若不主动驱动，就一帧样本都没有，
//   「每 N 帧一行」也就无从谈起。基线帧只验「上下文在按当前渲染倍率清屏/呈现」，不代表游戏负载。
static const int A2RunnerPreviewFrameCount = 10;
/// 每 N 帧打一行 [FRAME]（避免每帧刷日志）；★首帧必打★（保证至少一行样本，或一行「无样本」说明）。
static const int A2RunnerFrameLogEveryNFrames = 5;

/// ★帧回调★：GL 桥每帧先做完自己的帧动作（按缩放尺寸清屏/呈现）再回调本函数。
/// 本函数只负责**判据节拍**（每 N 帧一行）——不碰任何 GL 类型（帧回调是交给桥的中立接口，
/// 不是 GL 接口）；本帧的数值由桥在回调之前记进 `a2_frame_perf`。
static void A2RunnerFrameCallback(void *user) {
    int *counter = (int *)user;
    if (counter == NULL) return;
    (*counter)++;
    if (*counter == 1 || (*counter % A2RunnerFrameLogEveryNFrames) == 0) {
        a2_frame_perf_log_line();
    }
}

// ---------------------------------------------------------------------------
//  ★⑦ SDL 窗口相位：晚出现的画面窗 ⇒ 改绑 GL 桥★
// ---------------------------------------------------------------------------
//  26.3 的 SDL 画面窗是 MC 启动后才建的，而本链在**建 VM 之前**就取宿主表面 ⇒ 那一刻
//  只能拿到启动器窗口。这里做一次有界等待（每秒一探、最多 6 秒）：若出现了**不同的游戏宿主窗口**，
//  就把 GL 桥改绑到它上面（attach 本身可重入：先彻底清掉上一次）。
//  ★只在「游戏宿主窗口确实换了」时动作★ —— 26.2 的 GLFW 宿主路径不会出现新窗口，零行为差异。
//
//  ★真机 iOS 16.7 的崩因（本函数的唯一判据就是为此立的）★
//    `[A2-COMPAT] 宿主表面取窗口=UITextEffectsWindow level=10`（键盘/文本效果辅助窗）
//      ⇒ 旧实现拿 `a2_top_visible_window()`（按 windowLevel 取高）当「新画面窗」
//      ⇒ 在 GCD 回调里对系统辅助窗再跑一次 `a2_gl_bridge_attach` ⇒ SIGSEGV。
//    ⇒ 变更判定改成「**只比较游戏宿主窗口**」：`A2RunnerIsGameHostWindow()` 认可的两个来源
//       ① GLFW 宿主视图所在的窗口（`a2_glfw_window_game_view()` 的 `view.window`，最强判据）；
//       ② 没有 GLFW 宿主视图时（26.3 SDL 路径 / 视图还没建出）只认 keyWindow。
//       系统辅助窗（`UITextEffectsWindow` / `UIRemoteKeyboardWindow` / `UIKeyboardWindow`）
//       与「windowLevel > 0 但不是游戏窗口」的窗口**一律不算变更**，一帧都不碰 GL。
//  ★失败不破坏现状★：任何一步失败 / attach 返回非 0 ⇒ 只记一行，**保留旧表面继续用**
//   （本函数自己不销毁任何表面；attach 的失败路径见 [A2-GLBRIDGE] 的 `★attach 中止★` 行）。
//  ★帧回调计数器必须是静态的★：本函数在 launchWithPlanPath 返回之后才可能跑，
//  栈上变量的地址会悬垂。

/// 系统辅助窗口（键盘 / 输入法 / 文本效果）—— ★永远不是游戏宿主窗口★。
/// 判据用**类名**（这几个类都是私有类，没有公开 API 可判）；iOS 16 真机上键盘弹出即出现。
static BOOL A2RunnerIsSystemAuxiliaryWindow(UIWindow *w) {
    if (w == nil) return NO;
    NSString *cls = NSStringFromClass(w.class);
    return [cls isEqualToString:@"UITextEffectsWindow"] ||
           [cls isEqualToString:@"UIRemoteKeyboardWindow"] ||
           [cls isEqualToString:@"UIKeyboardWindow"];
}

/// 被忽略过的辅助窗类名（★每种只记一行日志★：相位等待每秒一探，否则会刷屏）。
static NSMutableSet<NSString *> *gA2RunnerIgnoredAuxWindowClasses = nil;

/// 该窗口是不是「游戏宿主窗口」（★相位改绑的唯一判据★；见上面 ①② 两条来源）。
static BOOL A2RunnerIsGameHostWindow(UIWindow *w) {
    if (w == nil) return NO;
    if (A2RunnerIsSystemAuxiliaryWindow(w)) return NO;      // 键盘 / 文本效果：连判据都不参与

    // ① ★最强判据：GLFW 宿主视图所在窗口★（游戏画面真的挂在这个窗口上）
    void *gameViewRaw = a2_glfw_window_game_view();
    if (gameViewRaw != NULL) {
        UIView *gameView = (__bridge UIView *)gameViewRaw;
        UIWindow *gameWindow = gameView.window;
        if (gameWindow != nil) return (gameWindow == w);
    }

    // ② 没有 GLFW 宿主视图（26.3 SDL 路径 / 视图还没建出来）⇒ 只认 keyWindow。
    //    ★这里不按 windowLevel 取高★：MC 的画面窗本身就由 a2_glfw_window.m 复用成 keyWindow
    //    （层级抬到 StatusBar+1），而层级更高的一律是系统辅助窗 —— 那正是旧口径选错的那一类。
    //    ★已知取舍★：若某个 MC 版本的画面窗既不是 keyWindow、也没有 GLFW 宿主视图，本判据会让
    //    相位改绑不触发（保持初始表面）。这是**故意**的：宁可少改绑，也不拿辅助窗去建面
    //    （真机 iOS 16.7 的 SIGSEGV 就是后者）。真出现这种版本，修法是让该路径也走 GLFW 宿主视图。
    return w.isKeyWindow;
}

/// 记一行「这个窗口不是游戏宿主窗口 ⇒ 不改绑」（每种类名只记一次）。
static void A2RunnerLogIgnoredRebindTarget(UIWindow *w, UIWindow *attachedWindow) {
    if (w == nil) return;
    NSString *cls = NSStringFromClass(w.class);
    if (gA2RunnerIgnoredAuxWindowClasses == nil) gA2RunnerIgnoredAuxWindowClasses = [NSMutableSet set];
    if ([gA2RunnerIgnoredAuxWindowClasses containsObject:cls]) return;
    [gA2RunnerIgnoredAuxWindowClasses addObject:cls];
    [A2Log criterion:@"[A2-COMPAT] ⚠️ 相位改绑跳过：%@ level=%.0f 不是游戏宿主窗口"
     @"（系统辅助窗 / 非 keyWindow）⇒ 不改绑，当前表面保持 %@",
     cls, (double)w.windowLevel, NSStringFromClass(attachedWindow.class)];
}

static void A2RunnerRebindSurfaceIfTopWindowChanged(UIWindow *attachedWindow,
                                                    NSString *rendererDylib,
                                                    NSString *frameworksPath,
                                                    int attemptsLeft) {
    if (attemptsLeft <= 0 || attachedWindow == nil) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *top = a2_top_visible_window();
        // ★变更判定：只比游戏宿主窗口★（键盘/文本效果等辅助窗在这里就被挡掉，绝不进 attach）
        if (top == nil || top == attachedWindow || !A2RunnerIsGameHostWindow(top)) {
            if (top != nil && top != attachedWindow) A2RunnerLogIgnoredRebindTarget(top, attachedWindow);
            A2RunnerRebindSurfaceIfTopWindowChanged(attachedWindow, rendererDylib, frameworksPath,
                                                    attemptsLeft - 1);
            return;
        }
        // ★改绑目标 = 这一轮探到的那个游戏宿主窗口本身（不是重新按主窗口口径挑一遍）★：
        //   晚出现的画面窗（26.3 SDL）本来就不是「主窗口口径」下的那一个，按主窗口重挑会挑回原窗口，
        //   这条相位改绑就白等了。主窗口口径只管初始表面。
        A2GlfwSurface s = A2RunnerSurfaceForWindow(top);
        if (s.nativeWindow == NULL || s.nativeView == NULL) {
            [A2Log log:@"[A2-COMPAT] ⚠️ 相位改绑跳过：%@ 给不出宿主视图/句柄 ⇒ 保留旧表面，下一轮再试",
             NSStringFromClass(top.class)];
            A2RunnerRebindSurfaceIfTopWindowChanged(attachedWindow, rendererDylib, frameworksPath,
                                                    attemptsLeft - 1);
            return;
        }
        A2GlHostSurface host = {0};
        host.surface       = s;
        host.rendererName  = rendererDylib.UTF8String;
        host.frameCallback = A2RunnerFrameCallback;
        host.frameUser     = &gA2RunnerFrameCounter;
        int rc = a2_gl_bridge_attach(&host, frameworksPath);
        [A2Log criterion:@"[A2-COMPAT] %@ SDL 窗口相位：宿主表面改绑 %@ → %@ level=%.0f（attach rc=%d）",
         (rc == 0) ? @"✅" : @"⚠️",
         NSStringFromClass(attachedWindow.class), NSStringFromClass(top.class),
         (double)top.windowLevel, rc];
        if (rc != 0) {
            // ★失败不推翻已在跑的启动★：本函数不销毁任何表面，只如实记一行并留待下一轮；
            //   「为什么没建成」看紧邻的 [A2-GLBRIDGE] 阻断/中止行（缺库？缺 egl 入口？）。
            [A2Log log:@"[A2-COMPAT] ⚠️ 相位改绑失败（rc=%d）⇒ 保留旧表面继续用，不释放、不阻断启动；"
             @"原因见上一行 [A2-GLBRIDGE]", rc];
            A2RunnerRebindSurfaceIfTopWindowChanged(attachedWindow, rendererDylib, frameworksPath,
                                                    attemptsLeft - 1);
            return;
        }
        // 成功 ⇒ 之后以新窗口为基准继续等下一次相位变化（不重复拿旧窗口比较）
        A2RunnerRebindSurfaceIfTopWindowChanged(top, rendererDylib, frameworksPath,
                                                attemptsLeft - 1);
    });
}

@implementation A2LaunchRunner

+ (BOOL)runtimeChainEnabled {
    return a2_launch_runtime_enabled() ? YES : NO;
}

+ (A2LaunchRuntimeFacts *)currentRuntimeFacts {
    // UIKit 查询契约要求主线程。调用点（A2LaunchSession 的计划产出段）由 UI 主线程进入；
    // 万一将来有人从后台线程调，如实记一行 —— 不静默（值可能不准，但不伪造）。
    if (!NSThread.isMainThread) {
        [A2Log log:@"[A2-LAUNCH] ★运行时事实采集不在主线程★（UIKit 查询契约要求主线程；取值可能不准）"];
    }

    // ---- 真来源 1/2：★渲染宿主表面的实际像素尺寸★ ----
    // 口径与老树 `runtime_native/Natives/SurfaceViewController.m:1455-1456` 一致：
    //     physicalWidth = round(表面宽 × 屏幕 scale)
    // 那份值同时也是 CAMetalLayer.drawableSize 与 launchJVM 告知 MC 的尺寸
    // （三处同源，见同文件 1474-1475 的定案注释）。
    // ★Air2 现状★：游戏 surface 还没落地（渲染器只到「选 + dlopen」，见 [RENDER-WIRE]）
    // ⇒ 启动时可得的真实表面就是「承载游戏的宿主窗口」（全屏）。
    // 待专用 surface 视图落地后，本函数换成读它的尺寸即可（唯一改点，见 _AIR2_PLANPROPS.md §⑦-4）。
    UIWindowScene *activeScene = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            activeScene = (UIWindowScene *)scene;
            break;
        }
    }
    UIWindow *host = nil;
    for (UIWindow *w in activeScene.windows) {
        if (w.isKeyWindow) { host = w; break; }
    }
    if (host == nil) {
        host = activeScene.windows.firstObject;   // 无 key window 时的兜底（同一 scene 内的首个窗口）
    }

    NSInteger wpx = 0;
    NSInteger hpx = 0;
    CGFloat   scale = 0.0;
    if (host != nil) {
        UIScreen *screen = (activeScene.screen != nil) ? activeScene.screen : UIScreen.mainScreen;
        scale = screen.scale;                     // ★老树同口径★（screen.scale，不是 nativeScale）
        CGRect b = host.bounds;
        wpx = (NSInteger)lround(b.size.width  * scale);
        hpx = (NSInteger)lround(b.size.height * scale);
    }

    // ---- 真来源 2/2：★系统最大帧率★（与老树 JavaLauncher.m:1988 的表达式逐字同源）----
    NSInteger fps = (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond;

    // ★判据行★（真机 grep 锚点）：缺哪一项就在这里如实写出来，不掩盖、不补默认值。
    [A2Log log:@"[A2-LAUNCH] 运行时事实采集：窗口=%p 表面像素=%ldx%ld scale=%.2f 最大帧率=%ld ⇒ %@",
     host, (long)wpx, (long)hpx, (double)scale, (long)fps,
     ((wpx > 0 && hpx > 0 && fps > 0)
      ? @"两项齐备，将由启动计划落成 -D"
      : @"★有缺项：缺的那一项不下发 -D（不写猜的值）★")];

    return [A2LaunchRuntimeFacts factsWithSurfaceWidthPixels:wpx
                                                heightPixels:hpx
                                       maximumFramesPerSecond:fps];
}

+ (A2MemoryProbe *)currentMemoryProbe {
    // ---- 真来源 1/2：★进程可安全申请内存★（iOS 13+）----
    // 口径：os_proc_available_memory() 返回「本进程在被 jetsam 干掉之前还能申请多少字节」，
    // 比物理内存比例更贴近 iOS 的真实约束。出处：老线 Natives/LauncherPreferences.m:56
    // （老线实测 iPhone X：available=1807MB ⇒ 安全堆顶 607MB）。
    // ★取不到就是 0★（老系统/模拟器）⇒ 底层走 default 回退，不伪造读数。
    NSInteger availMB = 0;
    if (@available(iOS 13.0, *)) {
        uint64_t avail = os_proc_available_memory();
        if (avail > 0) availMB = (NSInteger)(avail >> 20);
    }

    // ---- 真来源 2/2：★物理内存★（fallback 用；永远取得到，但比 available 粗糙）----
    NSInteger physMB = (NSInteger)(NSProcessInfo.processInfo.physicalMemory >> 20);

    A2MemoryProbe *probe = [A2MemoryProbe probeWithAvailableMB:availMB physicalMB:physMB];

    // ★判据行（第 1 行）★：这一次探测到手的量级 —— 真机 grep `[MEM] probe` 即可对上。
    //   第 2 行（ceiling → -Xmx 的决策行）在 Player 的 A2LaunchSession（那里才知道档位）。
    [A2Log criterion:@"[MEM] probe available=%ldMB physical=%ldMB source=%@",
     (long)availMB, (long)physMB, probe.source];

    return probe;
}

+ (int)launchWithPlanPath:(NSString *)planPath
             entryJarPath:(NSString *)entryJarPath
           patchJarPath:(nullable NSString *)patchJarPath
               jvmOptions:(NSArray<NSString *> *)jvmOptions
                 javaHome:(NSString *)javaHome
                  gameDir:(NSString *)gameDir
                 userHome:(NSString *)userHome
                   tmpDir:(NSString *)tmpDir
            librariesPath:(NSString *)librariesPath
                 lwjglDir:(NSString *)lwjglDir
           frameworksPath:(nullable NSString *)frameworksPath
            rendererDylib:(nullable NSString *)rendererDylib
              renderScale:(double)renderScale {
    if (planPath.length == 0 || javaHome.length == 0) {
        [A2Log log:@"[A2-LAUNCH] 组命令行失败：planPath/javaHome 为空"];
        return -8;
    }

    // ---- ★[RENDER-WIRE]/[RENDER-SEL] 显式选择 + 加载用户选中的渲染后端★ ----
    // 为什么在这里：Bridge 是唯一与 Natives 相邻的层（同 [LAUNCH-PLAN] 决策 2）；
    // 且本函数只在自研链里被调用 ⇒ 开关（debug.rt_p1_runtime，默认关）关时零副作用。
    // 谁选的：Player（`A2LaunchSession` 读 NSUserDefaults 的 A2SelectedRendererPrefKey）；
    // 判据：主二进制可扫到渲染器名（A2RendererMetalDylibName / A2RendererCompatDylibName）。
    int renderRC = a2_renderer_load_named(rendererDylib, frameworksPath);
    [A2Log log:@"[A2-RENDERER] 渲染后端加载完成 rc=%d（0=已加载；-1=未内置；-2=路径未解析；-3=dlopen 失败）",
     renderRC];
    if (renderRC != 0) {
        // ★选到未内置/不合格的 ⇒ 如实阻断★：不静默换一个渲染器继续建 VM。
        [A2Log log:@"[A2-RENDERER] ★阻断启动★：所选渲染器不可用（rc=%d）—— 缺什么/为何失败见上一行，改选已内置的渲染器后重试",
         renderRC];
        return -10;
    }

    // ---- ★[GL-BRIDGE] 让选中的后端真的拿到 surface 并建出可用的 GL 上下文★ ----
    // 缺口（接线前）：只做到「选 + dlopen」⇒ 后端拿不到表面、也建不出上下文（出不了画面）。
    // 本步补上：宿主表面（Bridge 采集）+ 据已选后端名加载 EGL/GLES 兼容底 + 建 EGL 上下文
    //   + 帧回调里 glClear（可判据的可用性证据）。
    // ★阻断口径（不静默回退）★：非 EGL/GL 系后端（如主推 Metal）本桥不负责 ⇒ rc=1，**不阻断**；
    //   是 EGL/GL 系但缺库/无表面/建面失败 ⇒ 负值，**如实阻断**（-12），绝不换成别的渲染器。
    gA2RunnerFrameCounter = 0;                        // 每次启动重新计数（静态计数器的唯一重置点）
    A2GlHostSurface glHost = {0};

    // ---- ★[FRAME-PERF] 分辨率缩放：只改**表面像素**（drawable），逻辑尺寸（点）不动★ ----
    // 缩放口径：drawable 像素 = 表面像素 × 渲染倍率。倍率由 Player 归一化后传入；
    // 这里只做「合法区间」兜底（<=0 或 >1 ⇒ 按 1.0，不猜中间值），不在 Bridge 里读偏好。
    A2GlfwSurface hostSurface = A2RunnerHostSurface();   // 原生窗口句柄 + 像素格式 + 尺寸（主线程采集）
    double appliedScale = (renderScale > 0.0 && renderScale <= 1.0) ? renderScale : 1.0;
    if (appliedScale < 1.0) {
        hostSurface.widthPixels  = (int)lround(hostSurface.widthPixels  * appliedScale);
        hostSurface.heightPixels = (int)lround(hostSurface.heightPixels * appliedScale);
        // ★widthPoints/heightPoints/contentScale 原样不动★ —— 逻辑尺寸不变。
    }
    [A2Log log:@"[A2-RENDER] 表面缩放：points=%dx%d（不变） px=%dx%d（= 表面像素 × %.2f）scale=%.2f source=%@",
     hostSurface.widthPoints, hostSurface.heightPoints,
     hostSurface.widthPixels, hostSurface.heightPixels, appliedScale, appliedScale,
     (renderScale > 0.0 && renderScale <= 1.0) ? @"player" : @"clamped-to-1.0"];

    // 帧判据的环境（drawable 尺寸 + 渲染倍率）；相位从「预览态」起。
    a2_frame_perf_set_environment(hostSurface.widthPixels, hostSurface.heightPixels, appliedScale);
    a2_frame_perf_set_phase(A2FramePhasePreview);

    glHost.surface       = hostSurface;               // 原生窗口句柄 + 像素格式 + 尺寸（已按倍率缩放）
    glHost.rendererName  = rendererDylib.UTF8String;  // 与上面同一份已解析的 dylib 名（Bridge 不读偏好）
    glHost.frameCallback = A2RunnerFrameCallback;     // 帧回调（每 N 帧一行 [FRAME]；桥每帧末尾回调）
    glHost.frameUser     = &gA2RunnerFrameCounter;

    int glRC = a2_gl_bridge_attach(&glHost, frameworksPath);
    [A2Log log:@"[A2-GLBRIDGE] GL 桥附着完成 rc=%d（0=已建出上下文；1=非 EGL/GL 系不归本桥；-1=缺库；-2=加载失败；-3=无表面；-4=EGL 建面失败）",
     glRC];
    if (glRC < 0) {
        [A2Log log:@"[A2-GLBRIDGE] ★阻断启动★：所选渲染器是 EGL/GL 系，但未能建出 GL 上下文（rc=%d）—— 缺什么/为何失败见上一行，改选已内置的渲染器后重试",
         glRC];
        return -12;
    }
    // ★⑦ 建面用到的窗口可能不是最终画面窗★（26.3 的 SDL 窗口在 MC 启动后才出现）⇒
    //   起一个有界等待：若之后出现「不同的最顶层可见窗口」，把桥改绑过去。
    //   非 EGL 系（rc=1，本桥未附着）不参与（它的建面归后端自己）。
    if (glRC == 0) {
        A2RunnerRebindSurfaceIfTopWindowChanged((__bridge UIWindow *)glHost.surface.nativeWindow,
                                                rendererDylib, frameworksPath, 6);
    }

    // ---- ★[FRAME-PERF] 预览态基线帧★ ----
    // 附着之后由启动链驱动一小段帧（≤ A2RunnerPreviewFrameCount）：① 给「每 N 帧一行」凑出样本；
    // ② 让「本帧确实按缩放尺寸清屏/呈现」有据可查（每帧的 drawable/scissor 读回进 [FRAME]）。
    // 非 EGL/GL 系后端（rc=1，桥未附着）时本循环不产帧 ⇒ 下面如实补一行「无帧样本」。
    // 相位说明：这些帧是**预览态**；游戏/渲染器接管帧生产后才是真实态（见 [FRAME] 的 phase 字段）。
    for (int i = 0; i < A2RunnerPreviewFrameCount; i++) {
        a2_gl_bridge_present_frame();
    }
    if (gA2RunnerFrameCounter == 0) {
        // 桥没附着（后端不归本桥）⇒ 如实说「没有帧样本」，不编造。
        a2_frame_perf_log_line();
    }

    // ---- front 项：启动核心 jar + LWJGL 补丁 jar + 自研 GLFW jar ----
    // 三类都必须最先，才能盖住 libs/lwjgl-<ver>/* 里的官方同名类
    // （自研 GLFW jar 覆盖 org.lwjgl.glfw.GLFW / Callbacks / GLFWNativeCocoa）。
    // 自研 GLFW jar 与补丁 jar 同目录（<App>/Java/）⇒ 由 entryJarPath 所在目录推出；
    // 文件不存在则跳过（回退官方实现，不阻断启动）。
    NSMutableArray<NSString *> *frontItems = [NSMutableArray array];
    if (entryJarPath.length > 0) [frontItems addObject:entryJarPath];
    if (patchJarPath.length > 0) [frontItems addObject:patchJarPath];
    if (entryJarPath.length > 0) {
        NSString *ownGlfwJar = [[entryJarPath stringByDeletingLastPathComponent]
                                stringByAppendingPathComponent:A2LaunchJavaOwnGlfwJarName];
        if ([NSFileManager.defaultManager fileExistsAtPath:ownGlfwJar]) {
            [frontItems addObject:ownGlfwJar];
        } else {
            [A2Log log:@"[A2-LAUNCH] 自研 GLFW jar 不在包内：%@（回退官方 org.lwjgl.glfw.*）", ownGlfwJar];
        }
    }
    NSString *frontJar = [frontItems componentsJoinedByString:@":"];

    // ---- R4 唯一拼装点：argv 里的 classpath 与传给 a2_launch 的输入必须是同一份 ----
    NSString *classpath = a2_paths_build_classpath(librariesPath, lwjglDir, frontJar);

    A2LaunchInput input = { nil, nil, nil, nil, nil, nil, nil, nil };
    input.javaHome       = javaHome;
    input.gameDir        = gameDir;
    input.userHome       = userHome;
    input.tmpDir         = tmpDir;
    input.frameworksPath = frameworksPath;
    input.librariesPath  = librariesPath;
    input.lwjglDir       = lwjglDir;
    input.frontJar       = frontJar;

    // ---- 组 margv：<java> [VM 选项…] -cp <classpath> <A2Entry> --plan <plan> ----
    NSMutableArray<NSString *> *argv = [NSMutableArray array];
    [argv addObject:[javaHome stringByAppendingPathComponent:@"bin/java"]];
    [argv addObjectsFromArray:jvmOptions];
    [argv addObject:@"-cp"];
    [argv addObject:(classpath.length > 0 ? classpath : @"")];
    [argv addObject:A2LaunchEntryMainClass];
    [argv addObject:A2LaunchPlanFlag];
    [argv addObject:planPath];

    // C 数组（指针存活到调用返回）
    NSUInteger count = argv.count;
    const char **cargv = (const char **)calloc(count, sizeof(char *));
    if (cargv == NULL) {
        [A2Log log:@"[A2-LAUNCH] calloc argv 失败（%lu 条）", (unsigned long)count];
        return -8;
    }
    for (NSUInteger i = 0; i < count; i++) {
        cargv[i] = argv[i].UTF8String;
    }

    // ★默认可见的一行「链/入口」判据★（真机 grep 锚点）
    [A2Log log:@"[A2-LAUNCH] 自研链启动：entry=%@ plan=%@ argv=%lu 条（classpath %lu 字符）",
     A2LaunchEntryMainClass, planPath.lastPathComponent,
     (unsigned long)count, (unsigned long)classpath.length];

    // ★[FRAME-PERF] 相位切到「真实态」★：从这里起帧生产归游戏/渲染器（本包内未接入帧源
    //   ⇒ 不会有真实态样本；若将来渲染器经桥产帧，其 [FRAME] 行即 phase=real）。
    a2_frame_perf_set_phase(A2FramePhaseReal);

    int rc = a2_launch_jvm_with_argv((int)count, cargv, input);

    free(cargv);
    [A2Log log:@"[A2-LAUNCH] a2_launch_jvm_with_argv 返回 rc=%d", rc];
    return rc;
}

@end
