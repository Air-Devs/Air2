//
//  gl_bridge_tests.m
//  Air2 —— tests/Natives：★GL 桥（Natives/Renderer/a2_gl_bridge）纯逻辑 + 接线自证单测★
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（★直接链接真实实现，不是 Python/文本镜像★）：
//    Natives/Renderer/a2_gl_bridge.m  ← 后端判定 / 返回码契约 / 缺库与加载失败分支（真实现）
//    Natives/Renderer/a2_renderer.m   ← 渲染器名常量（证明本桥复用既有常量、不重复字面量）
//
//  为什么能在 macOS 上跑：本桥**不链接** EGL/GLES（只在运行期 dlopen），也不 import 任何
//  图形后端头 —— 因此可以在没有 EGL 的机器上真编译、真运行，把「该判 EGL 系 / 该判不归本桥 /
//  缺库 / 加载失败」这些**决策**跑到绿或红。真建面（EGL 成功）需要 iOS 设备，属真机判定表项。
//
//  运行：python3 tests/Natives/run_gl_bridge_tests.py   （需 macOS + clang；Windows 无 clang 属预期）
//

#import <Foundation/Foundation.h>

#import "a2_gl_bridge.h"
#import "a2_renderer.h"

static int gPass = 0;
static int gFail = 0;

static void ok(BOOL cond, NSString *what) {
    if (cond) { gPass++; printf("PASS  %s\n", what.UTF8String); }
    else      { gFail++; printf("FAIL  %s\n", what.UTF8String); }
}

static void eqInt(long got, long want, NSString *what) {
    ok(got == want, [NSString stringWithFormat:@"%@（得到 %ld，期望 %ld）", what, got, want]);
}

static void eqStr(NSString *got, NSString *want, NSString *what) {
    ok([got isEqualToString:want],
       [NSString stringWithFormat:@"%@（得到 %@，期望 %@）", what, got, want]);
}

/// …/tests/Natives/gl_bridge_tests.m → …/tests → 仓根
static NSString *RepoPath(NSString *relative) {
    NSString *here = [NSString stringWithUTF8String:__FILE__];
    NSString *testsDir = [here stringByDeletingLastPathComponent];
    NSString *root = [testsDir stringByDeletingLastPathComponent];
    return [root stringByAppendingPathComponent:relative];
}

static NSString *ReadRepo(NSString *rel) {
    return [NSString stringWithContentsOfFile:RepoPath(rel)
                                     encoding:NSUTF8StringEncoding error:NULL];
}

static NSString *TempDir(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"a2glb_%@", NSUUID.UUID.UUIDString]];
}

/// 造一个「假包内 Frameworks 目录」：把给定相对路径建成非空文件。
static NSString *FakeFrameworks(NSArray<NSString *> *rels) {
    NSString *dir = [TempDir() stringByAppendingPathComponent:@"Frameworks"];
    for (NSString *rel in rels) {
        NSString *full = [dir stringByAppendingPathComponent:rel];
        [[NSFileManager defaultManager] createDirectoryAtPath:[full stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        [@"dummy" writeToFile:full atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    return dir;
}

/// 造一个「空的」包内 Frameworks 目录（一个文件都没有）。
static NSString *EmptyFrameworks(void) {
    NSString *dir = [TempDir() stringByAppendingPathComponent:@"Frameworks"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

// ============================================================================
#pragma mark - ① 判据锚点与常量
// ============================================================================

static void testConstants(void) {
    printf("\n=== ① 判据锚点 / 兼容底库名 ===\n");
    eqStr([NSString stringWithUTF8String:A2GlBridgeJudgementTag], @"[A2-GLBRIDGE]",
          @"★判据前缀 = [A2-GLBRIDGE]（真机 grep 锚点）★");
    eqStr([NSString stringWithUTF8String:A2GlBridgeEglLibraryRelPath], @"libEGL.framework/libEGL",
          @"EGL 兼容底相对路径");
    eqStr([NSString stringWithUTF8String:A2GlBridgeGlesLibraryRelPath], @"libGLESv2.framework/libGLESv2",
          @"GLESv2 兼容底相对路径");

    // ★本桥的后端词汇表复用既有常量（不重复字面量）★
    eqStr([NSString stringWithUTF8String:A2RendererCompatDylibName], @"libgl4es_114.dylib",
          @"兼容底渲染器名 = 既有 a2_renderer 常量（同一份血统）");
}

// ============================================================================
#pragma mark - ② 后端判定（哪些后端归本桥管）
// ============================================================================

static void testBackendDecision(void) {
    printf("\n=== ② 后端判定（EGL/GL 系？）===\n");
    eqInt(a2_gl_bridge_backend_is_egl("libgl4es_114.dylib"), 1, @"GL4ES（兼容底）⇒ EGL/GL 系");
    eqInt(a2_gl_bridge_backend_is_egl("libmetallum.dylib"), 0, @"★主推 Metal ⇒ 非 EGL/GL 系（不归本桥）★");
    eqInt(a2_gl_bridge_backend_is_egl("libmobileglues.dylib"), 0, @"未内置的实验后端 ⇒ 非 EGL/GL 系");
    eqInt(a2_gl_bridge_backend_is_egl(NULL), 0, @"NULL ⇒ 非 EGL/GL 系（不猜）");
    eqInt(a2_gl_bridge_backend_is_egl(""), 0, @"空串 ⇒ 非 EGL/GL 系（不猜）");
    eqInt(a2_gl_bridge_backend_is_egl("libgl4es_114.dylib "), 0, @"★末尾多空格不算同一后端（不模糊匹配）★");
}

// ============================================================================
#pragma mark - ③ 返回码契约（不归本桥 vs 该管没管成）
// ============================================================================

static void testReturnCodes(void) {
    printf("\n=== ③ 返回码契约 ===\n");
    eqInt(A2GlBridgeOK, 0, @"OK = 0");
    eqInt(A2GlBridgeSkipped, 1, @"Skipped = 1（不阻断）");
    eqInt(A2GlBridgeErrMissingLib, -1, @"缺库 = -1");
    eqInt(A2GlBridgeErrLoadFailed, -2, @"加载失败 = -2");
    eqInt(A2GlBridgeErrNoSurface, -3, @"无表面 = -3");
    eqInt(A2GlBridgeErrEgl, -4, @"EGL 建面失败 = -4");
    ok(A2GlBridgeSkipped > 0, @"★「不归本桥」为正数 ⇒ 与「该管没管成」(负值) 天然可分★");
}

// ============================================================================
#pragma mark - ④ attach 分支（真跑：不归本桥 / 无表面 / 缺库 / 加载失败）
// ============================================================================

static void testAttachBranches(void) {
    printf("\n=== ④ attach 分支（真跑）===\n");

    A2GlfwSurface surf = {0};
    surf.nativeView   = (__bridge void *)[NSObject new];   // 有效句柄（非 NULL）
    surf.widthPixels  = 1170; surf.heightPixels = 2532;
    surf.pixelFormat  = A2_GLFW_PIXEL_FORMAT_HOST_DEFAULT;

    // (a) 非 EGL/GL 系后端 ⇒ 不归本桥（不阻断）
    A2GlHostSurface metal = {0};
    metal.surface = surf;
    metal.rendererName = "libmetallum.dylib";
    eqInt(a2_gl_bridge_attach(&metal, @"/no/such/dir"), A2GlBridgeSkipped,
          @"★主推 Metal ⇒ Skipped（1）：非 EGL/GL 系不归本桥，不阻断★");

    // (b) NULL host ⇒ 无表面
    eqInt(a2_gl_bridge_attach(NULL, @"/no/such/dir"), A2GlBridgeErrNoSurface,
          @"host=NULL ⇒ 无表面（-3）");

    // (c) EGL 系但没有原生窗口句柄 ⇒ 无表面（★先判表面、再碰库★）
    A2GlHostSurface noWin = {0};
    noWin.surface = (A2GlfwSurface){0};                    // nativeView = NULL
    noWin.rendererName = "libgl4es_114.dylib";
    eqInt(a2_gl_bridge_attach(&noWin, @"/no/such/dir"), A2GlBridgeErrNoSurface,
          @"GL4ES + nativeView=NULL ⇒ 无表面（-3）");

    // (d) EGL 系 + 有效表面 + 包内缺库 ⇒ 缺库
    A2GlHostSurface gles = {0};
    gles.surface = surf;
    gles.rendererName = "libgl4es_114.dylib";
    NSString *emptyFW = EmptyFrameworks();
    eqInt(a2_gl_bridge_attach(&gles, emptyFW), A2GlBridgeErrMissingLib,
          @"GL4ES + 空 Frameworks ⇒ 缺库（-1；缺 EGL 兼容底）");

    // (e) 库文件在但不可加载（假文件）⇒ 加载失败
    NSString *fakeFW = FakeFrameworks(@[ @"libEGL.framework/libEGL",
                                         @"libGLESv2.framework/libGLESv2",
                                         @"libgl4es_114.dylib" ]);
    eqInt(a2_gl_bridge_attach(&gles, fakeFW), A2GlBridgeErrLoadFailed,
          @"GL4ES + 假库文件 ⇒ 加载失败（-2；dlopen 拒了）");

    // (f) frameworksPath 为空 ⇒ 缺库（不猜路径）
    eqInt(a2_gl_bridge_attach(&gles, @""), A2GlBridgeErrMissingLib,
          @"GL4ES + frameworksPath 为空 ⇒ 缺库（-1；不猜 <App>/Frameworks）");

    [[NSFileManager defaultManager] removeItemAtPath:[emptyFW stringByDeletingLastPathComponent] error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:[fakeFW stringByDeletingLastPathComponent] error:NULL];
}

// ============================================================================
#pragma mark - ⑤ 接线自证 + 解耦自证（源码级 + 阴性对照）
// ============================================================================

static void testWiringAndDecoupling(void) {
    printf("\n=== ⑤ 接线自证（谁调它）/ 解耦自证 ===\n");

    // ★调用点唯一★：Bridge 的 A2LaunchRunner 真的调了本桥，且把负值翻成 -12 阻断
    NSString *runner = ReadRepo(@"Air2/Bridge/A2LaunchRunner.m");
    ok(runner.length > 0, @"读得到 A2LaunchRunner.m");
    ok([runner containsString:@"a2_gl_bridge_attach"], @"★Bridge 真的调了 a2_gl_bridge_attach（谁调它）★");
    ok([runner containsString:@"A2GlHostSurface"], @"★Bridge 用中立宿主结构填表面（原生句柄/像素格式/尺寸/帧回调/渲染器名）★");
    ok([runner containsString:@"glHost.frameCallback"], @"★帧回调真的被交给桥（不是留空）★");
    ok([runner containsString:@"rendererDylib.UTF8String"], @"★已选渲染器名真的被传给桥（与 a2_renderer 同一份取值）★");
    ok([runner containsString:@"return -12"], @"★GL 桥失败 ⇒ 阻断（-12），不静默回退★");

    // 失败码翻译成用户文案（Player 侧）
    NSString *failure = ReadRepo(@"Air2/Player/A2LaunchFailure.m");
    ok([failure containsString:@"case -12"], @"★-12 在 Player 有用户文案翻译★");

    // ★本桥的硬约束：不含任何 Metal 专有 API / 不 import 图形后端头★（机器判据 = 命中 0）
    NSArray<NSString *> *bridgeFiles = @[ @"Natives/Renderer/a2_gl_bridge.h",
                                          @"Natives/Renderer/a2_gl_bridge.m" ];
    NSArray<NSString *> *metalTokens = @[ @"CAMetalLayer", @"MTLDevice", @"MTLCommandQueue",
                                          @"MTLRenderPipeline", @"MTLTexture", @"#import <Metal",
                                          @"#include <Metal", @"MTLCreateSystemDefaultDevice" ];
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (NSString *f in bridgeFiles) {
        NSString *src = ReadRepo(f) ?: @"";
        for (NSString *tok in metalTokens) {
            if ([src containsString:tok]) [hits addObject:[NSString stringWithFormat:@"%@:%@", f, tok]];
        }
    }
    ok(hits.count == 0,
       hits.count == 0 ? @"★GL 桥两个源文件里 Metal 专有 API 命中 = 0（与渲染器解耦）★"
                        : [NSString stringWithFormat:@"★命中 Metal 专有符号：%@★", [hits componentsJoinedByString:@", "]]);

    // ★不越层★：渲染器解耦的窗口/输入层不得反向 import 本桥
    NSString *win = ReadRepo(@"Natives/Input/a2_glfw_window.m") ?: @"";
    ok([win rangeOfString:@"a2_gl_bridge"].location == NSNotFound,
       @"★Input 窗口层不认识 GL 桥（解耦未被破坏）★");

    // ★随仓件在不在（本桥运行期要从 Frameworks/ 加载的三件）★
    NSArray<NSString *> *staged = @[
        @"Libraries/Renderers/libgl4es_114.dylib",
        @"Libraries/Frameworks/libEGL.framework/libEGL",
        @"Libraries/Frameworks/libGLESv2.framework/libGLESv2",
    ];
    for (NSString *rel in staged) {
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:RepoPath(rel) error:NULL];
        ok(at != nil && [at[NSFileSize] longLongValue] > 1024,
           [NSString stringWithFormat:@"随仓兼容底三件套存在且非空：%@", rel]);
    }

    // ★阴性对照★：必然不存在的路径 —— 上方「存在性」检查不是无条件通过
    NSDictionary *nope = [[NSFileManager defaultManager]
                          attributesOfItemAtPath:RepoPath(@"Libraries/Frameworks/lib-不存在.framework/x") error:NULL];
    ok(nope == nil, @"阴性对照：不存在的库读不到（证明上面的断言不是恒真）");
}

// ============================================================================

int main(void) {
    @autoreleasepool {
        printf("=== Air2 tests/Natives：GL 桥（a2_gl_bridge）单测 ===\n");
        testConstants();
        testBackendDecision();
        testReturnCodes();
        testAttachBranches();
        testWiringAndDecoupling();
        printf("\n================ 汇总 ================\n");
        printf("PASS=%d  FAIL=%d\n", gPass, gFail);
        if (gFail == 0) printf("全部通过\n"); else printf("有失败项\n");
        return gFail == 0 ? 0 : 1;
    }
}
