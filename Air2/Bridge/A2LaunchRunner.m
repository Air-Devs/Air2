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
            rendererDylib:(nullable NSString *)rendererDylib {
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

    // ---- front 项：启动核心 jar + LWJGL 补丁 jar（补丁必须最先，才能盖住 libs/lwjgl-<ver>）----
    NSMutableArray<NSString *> *frontItems = [NSMutableArray array];
    if (entryJarPath.length > 0) [frontItems addObject:entryJarPath];
    if (patchJarPath.length > 0) [frontItems addObject:patchJarPath];
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

    int rc = a2_launch_jvm_with_argv((int)count, cargv, input);

    free(cargv);
    [A2Log log:@"[A2-LAUNCH] a2_launch_jvm_with_argv 返回 rc=%d", rc];
    return rc;
}

@end
