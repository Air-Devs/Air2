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

/// 采集宿主表面（★主线程★：UIKit 查询契约要求）。口径与 +currentRuntimeFacts 一致
/// （宿主窗口 bounds × screen.scale = 像素），字段类型复用 Natives 的中立描述 `A2GlfwSurface`。
static A2GlfwSurface A2RunnerHostSurface(void) {
    A2GlfwSurface out = {0};
    A2GlfwSurface *s = &out;                       // 用指针进块：块捕获的是 const 副本
    void (^grab)(void) = ^{
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
        if (host == nil) host = activeScene.windows.firstObject;   // 无 key window 时的兜底
        if (host == nil) return;

        UIScreen *screen = (activeScene.screen != nil) ? activeScene.screen : UIScreen.mainScreen;
        CGFloat scale = screen.scale;                              // ★与 +currentRuntimeFacts 同口径★
        CGRect b = host.bounds;
        UIView *view = host.rootViewController.view ?: (UIView *)host;

        s->nativeView    = (__bridge void *)view;                  // 承载视图（GL 桥会取其 layer）
        s->nativeWindow  = (__bridge void *)host;
        s->widthPoints   = (int)lround(b.size.width);
        s->heightPoints  = (int)lround(b.size.height);
        s->widthPixels   = (int)lround(b.size.width  * scale);
        s->heightPixels  = (int)lround(b.size.height * scale);
        s->contentScaleX = (float)scale;
        s->contentScaleY = (float)scale;
        s->pixelFormat   = A2_GLFW_PIXEL_FORMAT_HOST_DEFAULT;
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
    int glFrameCounter = 0;
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
    glHost.frameUser     = &glFrameCounter;

    int glRC = a2_gl_bridge_attach(&glHost, frameworksPath);
    [A2Log log:@"[A2-GLBRIDGE] GL 桥附着完成 rc=%d（0=已建出上下文；1=非 EGL/GL 系不归本桥；-1=缺库；-2=加载失败；-3=无表面；-4=EGL 建面失败）",
     glRC];
    if (glRC < 0) {
        [A2Log log:@"[A2-GLBRIDGE] ★阻断启动★：所选渲染器是 EGL/GL 系，但未能建出 GL 上下文（rc=%d）—— 缺什么/为何失败见上一行，改选已内置的渲染器后重试",
         glRC];
        return -12;
    }

    // ---- ★[FRAME-PERF] 预览态基线帧★ ----
    // 附着之后由启动链驱动一小段帧（≤ A2RunnerPreviewFrameCount）：① 给「每 N 帧一行」凑出样本；
    // ② 让「本帧确实按缩放尺寸清屏/呈现」有据可查（每帧的 drawable/scissor 读回进 [FRAME]）。
    // 非 EGL/GL 系后端（rc=1，桥未附着）时本循环不产帧 ⇒ 下面如实补一行「无帧样本」。
    // 相位说明：这些帧是**预览态**；游戏/渲染器接管帧生产后才是真实态（见 [FRAME] 的 phase 字段）。
    for (int i = 0; i < A2RunnerPreviewFrameCount; i++) {
        a2_gl_bridge_present_frame();
    }
    if (glFrameCounter == 0) {
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
