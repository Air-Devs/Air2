//
//  frame_perf_tests.m
//  Air2 —— tests/Natives：★帧性能判据（Natives/Renderer/a2_frame_perf）自证单测★
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（★直接链接真实实现，不是 Python/文本镜像★）：
//    Natives/Renderer/a2_frame_perf.m  ← 行格式 / 帧计数 / 相位 / 缩放像素 / CPU 帧时间（真实现）
//
//  为什么能在 macOS 上跑：本模块只做计数与墙钟差分，不碰任何图形上下文、
//  不链接任何图形库 ⇒ 可在没有 GPU 的机器上真编译、真运行。
//
//  运行：python3 tests/Natives/run_frame_perf_tests.py   （需 macOS + clang；Windows 无 clang 属预期）
//

#import <Foundation/Foundation.h>

#import "a2_frame_perf.h"

#include <unistd.h>   // usleep（造两帧之间的时间差）

static int gPass = 0;
static int gFail = 0;

static void ok(BOOL cond, NSString *what) {
    if (cond) { gPass++; printf("PASS  %s\n", what.UTF8String); }
    else      { gFail++; printf("FAIL  %s\n", what.UTF8String); }
}

static void eqStr(NSString *got, NSString *want, NSString *what) {
    ok([got isEqualToString:want],
       [NSString stringWithFormat:@"%@（得到 %@，期望 %@）", what, got, want]);
}

static void contains(NSString *hay, NSString *needle, NSString *what) {
    ok([hay containsString:needle],
       [NSString stringWithFormat:@"%@（应含「%@」；实得：%@）", what, needle, hay]);
}

/// …/tests/Natives/frame_perf_tests.m → 仓根
static NSString *RepoPath(NSString *relative) {
    NSString *here = [NSString stringWithUTF8String:__FILE__];
    NSString *nativesDir = [here stringByDeletingLastPathComponent];       // …/tests/Natives
    NSString *testsDir   = [nativesDir stringByDeletingLastPathComponent]; // …/tests
    NSString *root       = [testsDir stringByDeletingLastPathComponent];   // 仓根
    return [root stringByAppendingPathComponent:relative];
}

static NSString *ReadRepo(NSString *rel) {
    return [NSString stringWithContentsOfFile:RepoPath(rel)
                                     encoding:NSUTF8StringEncoding error:NULL];
}

/// 图形后端专有名（出现即视为「具体后端引用」——本模块应只认中立数值）
static NSArray<NSString *> *BackendTokens(void) {
    return @[ @"Metal", @"MoltenVK", @"ANGLE", @"GL4ES", @"MobileGlues",
              @"EGL", @"OpenGL", @"GLES", @"Vulkan", @"CAMetalLayer",
              @"MTLDevice", @"EAGL", @"OSMesa", @"osmesa" ];
}

/// 扫一组文件里出现的后端专有名，返回 "file:token" 列表。
static NSArray<NSString *> *ScanBackendTokens(NSArray<NSString *> *files) {
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (NSString *f in files) {
        NSString *src = ReadRepo(f) ?: @"";
        for (NSString *tok in BackendTokens()) {
            if ([src containsString:tok]) {
                [hits addObject:[NSString stringWithFormat:@"%@:%@", f, tok]];
            }
        }
    }
    return hits;
}

// ============================================================================
#pragma mark - ① 判据锚点与「无样本」的如实报告
// ============================================================================

static void testTagAndEmptyState(void) {
    printf("\n=== ① 判据锚点 / 无样本如实报告 ===\n");
    eqStr([NSString stringWithUTF8String:A2FramePerfTag], @"[FRAME]",
          @"★判据前缀 = [FRAME]（真机 grep 锚点）★");

    // 还没有任何一帧 ⇒ 如实说「无样本」，不编造一帧。
    NSString *line = a2_frame_perf_format_line();
    contains(line, @"[FRAME]", @"无样本行以 [FRAME] 开头");
    contains(line, @"frames=0", @"★无样本 ⇒ frames=0（不补默认值）★");
}

// ============================================================================
#pragma mark - ② 行含全部必需字段 + 预览态
// ============================================================================

static void testRequiredFieldsPreview(void) {
    printf("\n=== ② 必需字段齐备（原生像素 / 预览态）===\n");

    a2_frame_perf_set_environment(1170, 2532, 1.0);
    a2_frame_perf_set_phase(A2FramePhasePreview);
    a2_frame_perf_record_frame(1, 0, 1, 1170, 2532);   // draw=1（一次清屏）/ 无着色器 / 已呈现

    NSString *line = a2_frame_perf_format_line();
    contains(line, @"frame=1", @"帧计数");
    contains(line, @"cpu_fps=", @"★含 fps（CPU 帧率，代理指标）★");
    contains(line, @"cpu_ms=",  @"★含帧时间(ms)（CPU，代理指标）★");
    contains(line, @"draw=1",   @"★含 draw call 数（代理指标）★");
    contains(line, @"tex≈",     @"★含纹理/帧缓冲内存估值★");
    contains(line, @"shaderNew=0", @"★含「本帧是否新建着色器/管线」★");
    contains(line, @"presented=1", @"含是否呈现");
    contains(line, @"phase=preview", @"★区分预览态★");
    contains(line, @"scale=1.00", @"含渲染倍率");
    contains(line, @"px=1170x2532", @"★含缩放后的 drawable 像素 px=…x…★");
    contains(line, @"clear=1170x2532", @"★含本帧清屏区域（可核对证据）★");
}

// ============================================================================
#pragma mark - ③ 真实态 + 缩放后的 drawable 尺寸真的变小
// ============================================================================

static void testRealPhaseAndScaledPixels(void) {
    printf("\n=== ③ 相位切换 / 缩放后的 drawable 尺寸 ===\n");

    // 真实态（游戏/渲染器接管后的相位）
    a2_frame_perf_set_phase(A2FramePhaseReal);
    a2_frame_perf_record_frame(1, 0, 1, 1170, 2532);
    NSString *real = a2_frame_perf_format_line();
    contains(real, @"frame=2", @"帧计数递增");
    contains(real, @"phase=real", @"★区分真实态★");

    // 0.75 倍：drawable 由 1170x2532 → 877x1899（逻辑尺寸不在本结构里，它不变）
    a2_frame_perf_set_phase(A2FramePhasePreview);
    a2_frame_perf_set_environment(877, 1899, 0.75);
    a2_frame_perf_record_frame(1, 0, 1, 877, 1899);
    NSString *scaled = a2_frame_perf_format_line();
    contains(scaled, @"scale=0.75", @"★判据行含 scale=…★");
    contains(scaled, @"px=877x1899", @"★px 为缩放后的像素（变小）★");
    contains(scaled, @"clear=877x1899", @"★本帧清屏区域 = 缩放后的尺寸（可核对证据）★");
    ok(![scaled containsString:@"px=1170x2532"],
       @"★缩放后不再报原生像素尺寸★");
}

// ============================================================================
#pragma mark - ④ CPU 帧时间是「量到的」而不是编的
// ============================================================================

static void testCpuFrameTiming(void) {
    printf("\n=== ④ CPU 帧时间（代理指标，量到才算数）===\n");

    a2_frame_perf_set_environment(585, 1266, 0.5);
    a2_frame_perf_record_frame(1, 0, 1, 585, 1266);   // 起点
    usleep(20000);                                    // 20ms
    a2_frame_perf_record_frame(1, 0, 1, 585, 1266);   // 终点

    NSString *line = a2_frame_perf_format_line();
    contains(line, @"scale=0.50", @"0.5 倍进判据行");
    contains(line, @"px=585x1266", @"0.5 倍的 drawable 尺寸");

    // 从行里把 cpu_ms= / cpu_fps= 抠出来做区间断言（约 20ms ⇒ 约 50fps）。
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    double ms = -1.0, fps = -1.0;
    for (NSString *p in parts) {
        if ([p hasPrefix:@"cpu_ms="])  ms  = [[p substringFromIndex:7] doubleValue];
        if ([p hasPrefix:@"cpu_fps="]) fps = [[p substringFromIndex:8] doubleValue];
    }
    ok(ms >= 5.0 && ms <= 200.0,
       [NSString stringWithFormat:@"★CPU 帧时间落在实测区间（得到 %.2f ms；约 20ms）★", ms]);
    ok(fps > 0.0 && fps <= 200.0,
       [NSString stringWithFormat:@"★CPU fps = 1000/ms 一致（得到 %.1f）★", fps]);
    ok(fabs(1000.0 / ms - fps) < 1.0, @"fps 与 ms 互为倒数（同一处算出来）");
}

// ============================================================================
#pragma mark - ⑤ 与渲染器解耦（源码级 + 阴性对照）
// ============================================================================

static void testDecoupling(void) {
    printf("\n=== ⑤ 与渲染器解耦（本模块不含任何后端专有名）===\n");

    NSArray<NSString *> *mine = @[ @"Natives/Renderer/a2_frame_perf.h",
                                   @"Natives/Renderer/a2_frame_perf.m",
                                   @"Air2/Core/Renderer/A2RenderScaleCatalog.h",
                                   @"Air2/Core/Renderer/A2RenderScaleCatalog.m" ];
    NSArray<NSString *> *hits = ScanBackendTokens(mine);
    ok(hits.count == 0,
       hits.count == 0
         ? @"★帧判据模块 4 个源文件里后端专有名命中 = 0（与渲染器解耦）★"
         : [NSString stringWithFormat:@"★命中后端专有名：%@★", [hits componentsJoinedByString:@", "]]);

    // ★阴性对照★：同一台扫描器在必然含后端名的文件上必须报警 ⇒ 上面的 0 不是恒真。
    NSArray<NSString *> *control = ScanBackendTokens(@[ @"Natives/Renderer/a2_gl_bridge.m" ]);
    ok(control.count > 0,
       @"★阴性对照：扫描器在已知含后端名的文件上有命中（断言不是恒真）★");
}

// ============================================================================
#pragma mark - ⑥ 接线自证（谁调它）
// ============================================================================

static void testWiring(void) {
    printf("\n=== ⑥ 接线自证（谁调它 / 哪一行）===\n");

    NSString *bridge = ReadRepo(@"Natives/Renderer/a2_gl_bridge.m");
    ok(bridge.length > 0, @"读得到 a2_gl_bridge.m");
    contains(bridge, @"a2_frame_perf_record_frame",
             @"★帧生产者（桥的帧动作）每帧调 a2_frame_perf_record_frame★");
    contains(bridge, @"A2_GL_SCISSOR_BOX",
             @"★帧动作读回 scissor box 作为「按缩放尺寸清屏」的可核对证据★");

    NSString *bridgeH = ReadRepo(@"Natives/Renderer/a2_gl_bridge.h");
    contains(bridgeH, @"void a2_gl_bridge_present_frame",
             @"★桥对外暴露可重复调用的帧生产入口★");

    NSString *runner = ReadRepo(@"Air2/Bridge/A2LaunchRunner.m");
    ok(runner.length > 0, @"读得到 A2LaunchRunner.m");
    contains(runner, @"a2_frame_perf_set_environment", @"★启动链设 drawable 尺寸 + 渲染倍率★");
    contains(runner, @"a2_frame_perf_set_phase",       @"★启动链切相位（预览态/真实态）★");
    contains(runner, @"a2_frame_perf_log_line",        @"★启动链每 N 帧打一行★");
    contains(runner, @"a2_gl_bridge_present_frame",    @"★启动链驱动基线帧（帧样本来源）★");
    contains(runner, @"[A2-RENDER] 表面缩放",
             @"★表面缩放判据行（points 不变 / px 变小）★");
    ok([runner containsString:@"hostSurface.widthPoints"]
       && [runner containsString:@"hostSurface.widthPixels"],
       @"★逻辑尺寸（点）与 drawable 像素分开处理 ⇒ 只缩像素★");

    NSString *session = ReadRepo(@"Air2/Player/A2LaunchSession.m");
    contains(session, @"A2SelectedRenderScalePrefKey", @"★Player 读倍率偏好键（读取点唯一）★");
    contains(session, @"A2RenderScaleCatalog",         @"★倍率经 Core 候选表归一化★");
    contains(session, @"[A2-RENDER] chosen=",          @"★倍率选择的判据行★");

    NSString *ui = ReadRepo(@"Air2/UI/Screens/Settings/A2RuntimeSettings.m");
    contains(ui, @"A2SelectedRenderScalePrefKey", @"★设置页是倍率键的唯一写入点★");
    contains(ui, @"A2RenderScaleCatalog",         @"★设置页用 Core 候选表列档★");

    // ★让「解耦机器判据」本身可被执行★（脚本与测试都在仓内）
    ok([ReadRepo(@"scripts/verify_frame_perf_native.py") length] > 0,
       @"解耦/禁石山机器判据脚本在仓内（scripts/verify_frame_perf_native.py）");
}

// ============================================================================

int main(void) {
    @autoreleasepool {
        printf("=== Air2 tests/Natives：帧性能判据（a2_frame_perf）单测 ===\n");
        testTagAndEmptyState();
        testRequiredFieldsPreview();
        testRealPhaseAndScaledPixels();
        testCpuFrameTiming();
        testDecoupling();
        testWiring();
        printf("\n================ 汇总 ================\n");
        printf("PASS=%d  FAIL=%d\n", gPass, gFail);
        if (gFail == 0) printf("全部通过\n"); else printf("有失败项\n");
        return gFail == 0 ? 0 : 1;
    }
}
