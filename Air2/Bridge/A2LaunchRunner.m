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

#import "a2_launch.h"          // Natives/Context —— facade 与开关（Bridge → Natives 是允许方向）
#import "a2_resourcepaths.h"   // Natives/Context —— R4 classpath 唯一拼装点
#import "a2_renderer.h"        // Natives/Renderer —— 渲染后端「选 + 加载」入口（见 docs/ARCHITECTURE.md [RENDER-WIRE]）

@implementation A2LaunchRunner

+ (BOOL)runtimeChainEnabled {
    return a2_launch_runtime_enabled() ? YES : NO;
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
           frameworksPath:(nullable NSString *)frameworksPath {
    if (planPath.length == 0 || javaHome.length == 0) {
        [A2Log log:@"[A2-LAUNCH] 组命令行失败：planPath/javaHome 为空"];
        return -8;
    }

    // ---- ★[RENDER-WIRE] 显式选择 + 加载渲染后端★ ----
    // 为什么在这里：Bridge 是唯一与 Natives 相邻的层（同 [LAUNCH-PLAN] 决策 2）；
    // 且本函数只在自研链里被调用 ⇒ 开关（debug.rt_p1_runtime，默认关）关时零副作用。
    // 判据：主二进制可扫到 A2RendererMetalDylibName（"libmetallum.dylib"）。
    int renderRC = a2_renderer_load_metal(frameworksPath);
    [A2Log log:@"[A2-RENDERER] 渲染后端选择完成 rc=%d（0=已加载；-1=未找到/失败，见上一行）", renderRC];

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
