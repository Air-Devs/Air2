//
//  runtime_selection_tests.m
//  Air2 —— tests/Runtime：★渲染器 + Java 运行时的「两张列表」纯逻辑单测★
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（★直接链接真实实现，不是 Python/文本镜像★）：
//    Air2/Core/Renderer/A2Renderer.m          ← 渲染后端值对象 + 注册表（既有）
//    Air2/Core/Renderer/A2RendererCatalog.m   ← 渲器候选表 + 包内存在性（[RENDER-SEL]）
//    Air2/Core/Version/A2JavaRuntimeCatalog.m ← Java 运行时候选表 + 可用性（[JRE-SEL]）
//    Air2/Player/A2RuntimeStrings.m           ← 四语文案表
//
//  为什么要有它：用户口径是「设置里各能看到哪几项、选每项分别会发生什么」——
//  下面这些断言把「表里有什么 / 哪一项算内置 / 四语齐不齐 / 谁把它接上启动链」变成
//  可执行的绿或红，而不是只靠源码扫描（扫描只能证明「像」，执行才能证明「是」）。
//
//  运行：python3 tests/Runtime/run_runtime_tests.py   （需 macOS + clang；Windows 无 clang 属预期）
//

#import <Foundation/Foundation.h>

#import "A2Renderer.h"
#import "A2RendererCatalog.h"
#import "A2RenderScaleCatalog.h"   // ★[FRAME-PERF] 渲染分辨率倍率候选表★
#import "A2JavaRuntimeCatalog.h"
#import "A2RuntimeStrings.h"

static int gPass = 0;
static int gFail = 0;

static void ok(BOOL cond, NSString *what) {
    if (cond) {
        gPass++;
        printf("PASS  %s\n", what.UTF8String);
    } else {
        gFail++;
        printf("FAIL  %s\n", what.UTF8String);
    }
}

static void eqStr(NSString *got, NSString *want, NSString *what) {
    ok([got isEqualToString:want],
       [NSString stringWithFormat:@"%@（得到 %@，期望 %@）", what, got, want]);
}

static void eqInt(NSInteger got, NSInteger want, NSString *what) {
    ok(got == want, [NSString stringWithFormat:@"%@（得到 %ld，期望 %ld）",
                     what, (long)got, (long)want]);
}

/// …/tests/Runtime/runtime_selection_tests.m → …/tests → 仓根
static NSString *RepoPath(NSString *relative) {
    NSString *here = [NSString stringWithUTF8String:__FILE__];
    NSString *testsDir = [[here stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSString *root = [testsDir stringByDeletingLastPathComponent];
    return [root stringByAppendingPathComponent:relative];
}

static NSString *TempDir(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"a2rt_%@", NSUUID.UUID.UUIDString]];
}

static BOOL WriteFile(NSString *path, NSData *data) {
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    return [data writeToFile:path atomically:YES];
}

/// 造一个「假包内 Frameworks 目录」：把给定文件名都建成非空文件。
static NSString *FakeFrameworks(NSArray<NSString *> *names) {
    NSString *dir = [TempDir() stringByAppendingPathComponent:@"Frameworks"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    for (NSString *n in names) {
        [@"x" writeToFile:[dir stringByAppendingPathComponent:n]
               atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    return dir;
}

// ============================================================================
#pragma mark - ① 渲染器候选表
// ============================================================================

static void testRendererCatalog(void) {
    printf("\n=== ① 渲染器候选表（A2RendererCatalog）===\n");

    NSArray<A2Renderer *> *all = [A2RendererCatalog allCandidates];
    ok(all.count >= 2, @"候选表至少两项（主推 + 兼容底）");

    // ★主推 / 兼容底 各一个，且顺序稳定★
    eqStr([A2RendererCatalog defaultCandidate].identifier, @"libmetallum.dylib",
          @"默认（主推）＝自研 Metal");
    eqStr(all[1].identifier, @"libgl4es_114.dylib", @"第二项＝兼容底 GL4ES");
    eqInt([A2RendererCatalog tierForIdentifier:@"libmetallum.dylib"],
          A2RendererTierRecommended, @"metallum 档位 = 主推");
    eqInt([A2RendererCatalog tierForIdentifier:@"libgl4es_114.dylib"],
          A2RendererTierCompat, @"gl4es 档位 = 兼容底");
    eqInt([A2RendererCatalog tierForIdentifier:@"libmobileglues.dylib"],
          A2RendererTierExperimental, @"mobileglues 档位 = 实验（未内置）");
    eqInt([A2RendererCatalog tierForIdentifier:@"lib-不存在.dylib"],
          A2RendererTierExperimental, @"★没登记的标识不猜成主推★");

    // 标识就是 dylib 文件名（= 老线 RENDERER_NAME_* 词汇表；也是 NSUserDefaults 存的值）
    NSMutableSet *ids = [NSMutableSet set];
    BOOL allDylib = YES;
    for (A2Renderer *r in all) {
        if (![r.identifier hasSuffix:@".dylib"]) allDylib = NO;
        [ids addObject:r.identifier];
    }
    eqInt((NSInteger)ids.count, (NSInteger)all.count, @"候选标识互不重复");
    ok(allDylib, @"每个候选标识都是以 .dylib 结尾的文件名");

    // 文案 key 与标识一一对应（UI 靠它取四语名）
    eqStr([A2RendererCatalog nameLocalizationKeyForIdentifier:@"libmetallum.dylib"],
          @"runtime.renderer.metallum", @"metallum 文案 key");
    eqStr([A2RendererCatalog nameLocalizationKeyForIdentifier:@"libgl4es_114.dylib"],
          @"runtime.renderer.gl4es_114", @"gl4es 文案 key");
    eqStr([A2RendererCatalog nameLocalizationKeyForIdentifier:@"libOSMesa.8.dylib"],
          @"runtime.renderer.osmesa_8", @"OSMesa.8 文案 key（点号折成下划线）");

    // ★包内有无 = 现算★（不缓存、不猜）
    NSString *fw = FakeFrameworks(@[ @"libmetallum.dylib", @"libgl4es_114.dylib" ]);
    ok([A2RendererCatalog isBundled:[A2RendererCatalog candidateForIdentifier:@"libmetallum.dylib"]
                      frameworksPath:fw], @"metallum 在 ⇒ 已内置");
    ok([A2RendererCatalog isBundled:[A2RendererCatalog candidateForIdentifier:@"libgl4es_114.dylib"]
                      frameworksPath:fw], @"gl4es 在 ⇒ 已内置");
    ok(![A2RendererCatalog isBundled:[A2RendererCatalog candidateForIdentifier:@"libmobileglues.dylib"]
                       frameworksPath:fw], @"★mobileglues 不在 ⇒ 未内置★");
    ok(![A2RendererCatalog isBundled:[A2RendererCatalog candidateForIdentifier:@"libmetallum.dylib"]
                       frameworksPath:nil], @"★frameworksPath 为空 ⇒ 判未内置（不猜）★");

    // 登记进既有注册表（不另起一套解析）：解析结果与选择一致；不允许回落时不瞎给
    A2Renderers *reg = [A2Renderers shared];
    [reg resetForTesting];
    [A2RendererCatalog registerAllCandidatesIntoRegistry:reg];
    eqInt((NSInteger)[reg allIdentifiers].count, (NSInteger)all.count, @"全部候选登记成功");
    eqStr([reg resolveEffectiveIdentifierWithVersionRenderer:nil
                                             globalRenderer:@"libgl4es_114.dylib"
                                              allowFallback:NO],
          @"libgl4es_114.dylib", @"全局选择被解析回来");
    ok([reg resolveEffectiveIdentifierWithVersionRenderer:nil
                                           globalRenderer:@"lib-不存在.dylib"
                                            allowFallback:NO] == nil,
       @"★选了个没登记的标识 ⇒ 解析回 nil（让上层如实报，不悄悄给主推）★");
    eqStr([reg resolveEffectiveIdentifierWithVersionRenderer:nil
                                             globalRenderer:nil
                                              allowFallback:YES],
          @"libmetallum.dylib", @"允许回落时 ⇒ 回落到首个（主推）");

    [[NSFileManager defaultManager] removeItemAtPath:[fw stringByDeletingLastPathComponent] error:NULL];
}

// ============================================================================
#pragma mark - ② Java 运行时候选表
// ============================================================================

static void testJavaRuntimeCatalog(void) {
    printf("\n=== ② Java 运行时候选表（A2JavaRuntimeCatalog）===\n");

    NSArray<NSString *> *dirs = [A2JavaRuntimeCatalog allDirectoryNames];
    eqInt((NSInteger)dirs.count, 4, @"候选四档（25 / 21 / 17 / 8）");
    eqStr(dirs[0], @"java-25-openjdk", @"第一档 = 25（主推，与当前实包内置的一致）");
    eqStr(dirs[1], @"java-21-openjdk", @"第二档 = 21");
    eqStr([A2JavaRuntimeCatalog defaultDirectoryName], @"java-25-openjdk", @"默认档 = 主推档");
    eqStr([A2JavaRuntimeCatalog javaRuntimesDirectoryName], @"java_runtimes",
          @"目录名 = java_runtimes（与 a2_vmloader 口径一致）");

    eqInt([A2JavaRuntimeCatalog majorVersionForDirectoryName:@"java-25-openjdk"], 25, @"25 → 25");
    eqInt([A2JavaRuntimeCatalog majorVersionForDirectoryName:@"java-8-openjdk"], 8, @"8 → 8");
    eqInt([A2JavaRuntimeCatalog majorVersionForDirectoryName:@"java-21-jre"], 0, @"★非本表形态 ⇒ 0（不猜）★");
    eqInt([A2JavaRuntimeCatalog majorVersionForDirectoryName:@"java-xx-openjdk"], 0, @"★非数字 ⇒ 0★");
    eqInt([A2JavaRuntimeCatalog majorVersionForDirectoryName:@""], 0, @"空 ⇒ 0");

    eqStr([A2JavaRuntimeCatalog nameLocalizationKeyForDirectoryName:@"java-21-openjdk"],
          @"runtime.jre.21", @"21 文案 key");
    eqStr([A2JavaRuntimeCatalog mcRangeLocalizationKeyForMajorVersion:8], @"runtime.jre.mc.8",
          @"8 的「适合哪些 MC」key");
    eqStr([A2JavaRuntimeCatalog mcRangeLocalizationKeyForMajorVersion:17], @"runtime.jre.mc.17",
          @"17 的 key");
    eqStr([A2JavaRuntimeCatalog mcRangeLocalizationKeyForMajorVersion:21], @"runtime.jre.mc.21",
          @"21 的 key");
    eqStr([A2JavaRuntimeCatalog mcRangeLocalizationKeyForMajorVersion:25], @"runtime.jre.mc.25",
          @"25 的 key");
    eqStr([A2JavaRuntimeCatalog mcRangeLocalizationKeyForMajorVersion:11], @"runtime.jre.mc.unknown",
          @"未知档 ⇒ unknown（不硬套）");

    // ★「可用」的判据 = 启动链真要 dlopen 的那个文件在不在（不是「目录在」）★
    NSString *home = [TempDir() stringByAppendingPathComponent:@"java_runtimes/java-21-openjdk"];
    ok(![A2JavaRuntimeCatalog isUsableJavaHome:home], @"目录还没建 ⇒ 不可用");
    [[NSFileManager defaultManager] createDirectoryAtPath:home
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    ok(![A2JavaRuntimeCatalog isUsableJavaHome:home], @"★空目录 ⇒ 仍不可用（缺 libjvm.dylib）★");
    WriteFile([home stringByAppendingPathComponent:@"lib/server/libjvm.dylib"],
              [@"x" dataUsingEncoding:NSUTF8StringEncoding]);
    ok([A2JavaRuntimeCatalog isUsableJavaHome:home], @"补上 lib/server/libjvm.dylib ⇒ 可用");
    ok(![A2JavaRuntimeCatalog isUsableJavaHome:nil], @"nil ⇒ 不可用（不猜）");
    ok(![A2JavaRuntimeCatalog isUsableJavaHome:@""], @"空串 ⇒ 不可用（不猜）");

    [[NSFileManager defaultManager] removeItemAtPath:[home stringByDeletingPathExtension]
                                              error:NULL];
}

// ============================================================================
#pragma mark - ③ 四语文案表
// ============================================================================

static void testRuntimeStrings(void) {
    printf("\n=== ③ 四语文案（A2RuntimeStrings）===\n");

    NSArray<NSString *> *langs = [A2RuntimeStrings allLanguageCodes];
    eqInt((NSInteger)langs.count, 4, @"四种语言");
    eqStr(langs[0], @"zh-Hans", @"第一门 = zh-Hans");
    eqStr(langs[1], @"zh-Hant", @"第二门 = zh-Hant");
    eqStr(langs[2], @"en", @"第三门 = en");
    eqStr(langs[3], @"ja", @"第四门 = ja");

    NSArray<NSString *> *keys = [A2RuntimeStrings allKeys];
    ok(keys.count > 0, @"表里有 key");

    // ★四语齐全★：每个 key 在四门语言里都必须有非空文案（漏一门即 FAIL）
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *k in keys) {
        for (NSString *l in langs) {
            A2RuntimeLanguage lang = (A2RuntimeLanguage)[langs indexOfObject:l];
            NSString *v = [A2RuntimeStrings stringForKey:k language:lang];
            if (v.length == 0) [missing addObject:[NSString stringWithFormat:@"%@/%@", k, l]];
        }
    }
    ok(missing.count == 0,
       missing.count == 0 ? @"★每个 key 四语齐全且非空★"
                          : [NSString stringWithFormat:@"★漏配：%@★", [missing componentsJoinedByString:@", "]]);

    // ★每个候选 / 每个档位在表里都有名★（UI 不允许出现裸 key）
    NSMutableArray<NSString *> *holes = [NSMutableArray array];
    for (A2Renderer *r in [A2RendererCatalog allCandidates]) {
        NSString *k = [A2RendererCatalog nameLocalizationKeyForIdentifier:r.identifier];
        if ([A2RuntimeStrings stringForKey:k language:A2RuntimeLanguageZhHans] == nil) {
            [holes addObject:k];
        }
    }
    for (A2RendererTier t = A2RendererTierRecommended; t <= A2RendererTierExperimental; t++) {
        NSString *k = [A2RendererCatalog tierLocalizationKeyForTier:t];
        if ([A2RuntimeStrings stringForKey:k language:A2RuntimeLanguageZhHans] == nil) [holes addObject:k];
    }
    for (NSString *d in [A2JavaRuntimeCatalog allDirectoryNames]) {
        NSString *k = [A2JavaRuntimeCatalog nameLocalizationKeyForDirectoryName:d];
        if ([A2RuntimeStrings stringForKey:k language:A2RuntimeLanguageZhHans] == nil) [holes addObject:k];
        NSInteger major = [A2JavaRuntimeCatalog majorVersionForDirectoryName:d];
        NSString *mk = [A2JavaRuntimeCatalog mcRangeLocalizationKeyForMajorVersion:major];
        if ([A2RuntimeStrings stringForKey:mk language:A2RuntimeLanguageZhHans] == nil) [holes addObject:mk];
    }
    ok(holes.count == 0,
       holes.count == 0 ? @"★每个渲染器候选 / 每个 JRE 档位 / 每个档位名都在四语表里有条目★"
                        : [NSString stringWithFormat:@"★缺条目：%@★", [holes componentsJoinedByString:@", "]]);

    // 行为约定：缺 key 回吐 key（绝不返回 nil/空串）；已知 key 四语各不相同
    eqStr([A2RuntimeStrings stringForKey:@"runtime.不存在的key"], @"runtime.不存在的key",
          @"★缺 key ⇒ 回吐 key（便于一眼看出漏配）★");
    eqStr([A2RuntimeStrings stringForKey:@""], @"", @"空 key ⇒ 空串");
    eqStr([A2RuntimeStrings codeForLanguage:A2RuntimeLanguageJapanese], @"ja", @"语言代码映射");

    NSString *zh = [A2RuntimeStrings stringForKey:@"runtime.source.user" language:A2RuntimeLanguageZhHans];
    NSString *en = [A2RuntimeStrings stringForKey:@"runtime.source.user" language:A2RuntimeLanguageEnglish];
    eqStr(zh, @"用户选择", @"判据行里的「源」= 用户选择（简中，机器判据串的一部分）");
    ok(en.length > 0 && ![en isEqualToString:zh], @"同一 key 英文与简中不同（不是复制粘贴）");
}

// ============================================================================
#pragma mark - ③b 渲染分辨率倍率候选表（[FRAME-PERF]）
// ============================================================================

static void testRenderScaleCatalog(void) {
    printf("\n=== ③b 渲染分辨率倍率（A2RenderScaleCatalog）===\n");

    NSArray<NSNumber *> *scales = [A2RenderScaleCatalog allScales];
    eqInt((NSInteger)scales.count, 3, @"起始三档");
    eqInt((NSInteger)(scales[0].doubleValue * 100), 50,  @"第一档 = 0.5");
    eqInt((NSInteger)(scales[1].doubleValue * 100), 75,  @"第二档 = 0.75");
    eqInt((NSInteger)(scales[2].doubleValue * 100), 100, @"第三档 = 1.0");
    ok(scales[0].doubleValue < scales[1].doubleValue &&
       scales[1].doubleValue < scales[2].doubleValue, @"★候选按升序（UI 顺序稳定）★");

    eqInt((NSInteger)([A2RenderScaleCatalog defaultScale] * 100), 100, @"默认档 = 1.0（原生像素）");
    ok([A2RenderScaleCatalog isSupportedScale:1.0], @"1.0 受支持");
    ok([A2RenderScaleCatalog isSupportedScale:0.75], @"0.75 受支持");
    ok([A2RenderScaleCatalog isSupportedScale:0.5], @"0.5 受支持");
    ok(![A2RenderScaleCatalog isSupportedScale:0.33], @"0.33 不受支持（不在表里）");
    ok(![A2RenderScaleCatalog isSupportedScale:1.5], @"1.5 不受支持（放大不在本单范围）");
    ok(![A2RenderScaleCatalog isSupportedScale:0.0], @"0.0 不受支持");

    // ★归一化「不猜」★：缺值 / 非数值 / 超范围 ⇒ 默认档（1.0）；受支持值原样通过。
    eqInt((NSInteger)([A2RenderScaleCatalog normalizedScaleForStoredString:nil] * 100), 100,
          @"★缺值 ⇒ 默认档（未选择）★");
    eqInt((NSInteger)([A2RenderScaleCatalog normalizedScaleForStoredString:@""] * 100), 100,
          @"★空串 ⇒ 默认档★");
    eqInt((NSInteger)([A2RenderScaleCatalog normalizedScaleForStoredString:@"abc"] * 100), 100,
          @"★非数值 ⇒ 默认档（不解析成 0）★");
    eqInt((NSInteger)([A2RenderScaleCatalog normalizedScaleForStoredString:@"3.0"] * 100), 100,
          @"★超范围 ⇒ 默认档（不夹成 1.0 之外的档）★");
    eqInt((NSInteger)([A2RenderScaleCatalog normalizedScaleForStoredString:@"0.75"] * 100), 75,
          @"受支持值原样通过（0.75）");
    eqInt((NSInteger)([A2RenderScaleCatalog normalizedScaleForStoredString:@"0.50"] * 100), 50,
          @"受支持值原样通过（0.50）");

    eqStr([A2RenderScaleCatalog displayPercentForScale:0.5], @"50%",  @"百分比文案 0.5");
    eqStr([A2RenderScaleCatalog displayPercentForScale:0.75], @"75%", @"百分比文案 0.75");
    eqStr([A2RenderScaleCatalog displayPercentForScale:1.0], @"100%", @"百分比文案 1.0");

    // ★设置页要用的 key 真的在四语表里（不是漏配的裸 key）★
    NSArray<NSString *> *keys = @[ @"runtime.row.scale", @"runtime.row.scale.detail",
                                   @"runtime.scale.native",
                                   @"runtime.pick.scale.title", @"runtime.pick.scale.message" ];
    for (NSString *k in keys) {
        NSString *v = [A2RuntimeStrings stringForKey:k language:A2RuntimeLanguageZhHans];
        ok(v.length > 0 && ![v isEqualToString:k],
           [NSString stringWithFormat:@"★倍率行文案 key 已配置：%@★", k]);
    }
}

// ============================================================================
#pragma mark - ④ 接线自证（源码级 + 随包件存在性）
// ============================================================================

static void testWiring(void) {
    printf("\n=== ④ 接线自证（谁调它 / 随包件在不在）===\n");

    NSString *session = [NSString stringWithContentsOfFile:
                         RepoPath(@"Air2/Player/A2LaunchSession.m")
                                                  encoding:NSUTF8StringEncoding error:NULL];
    ok(session.length > 0, @"读得到 A2LaunchSession.m");
    ok([session containsString:@"A2SelectedRendererPrefKey"], @"★Player 读渲染器偏好键★");
    ok([session containsString:@"A2SelectedJavaRuntimePrefKey"], @"★Player 读 Java 运行时偏好键★");
    ok([session containsString:@"[A2-RENDERER] chosen="], @"★判据行 [A2-RENDERER] chosen=★");
    ok([session containsString:@"[A2-JRE] chosen="], @"★判据行 [A2-JRE] chosen=★");
    ok([session containsString:@"rendererDylib:renderer.identifier"],
       @"★选中的渲染器被传给 Bridge（不是只在 UI 里存着）★");
    ok([session containsString:@"isUsableJavaHome"], @"★选中的 JRE 走可用性判据（未内置即阻断）★");

    NSString *runner = [NSString stringWithContentsOfFile:
                        RepoPath(@"Air2/Bridge/A2LaunchRunner.m")
                                                 encoding:NSUTF8StringEncoding error:NULL];
    ok([runner containsString:@"a2_renderer_load_named"],
       @"★Bridge 把选中的 dylib 交给既有中立面 a2_renderer（不另起一套）★");
    ok([runner containsString:@"return -10"], @"★渲染器不可用 ⇒ 阻断（-10），不静默换一个建 VM★");

    NSString *ui = [NSString stringWithContentsOfFile:
                    RepoPath(@"Air2/UI/Screens/Settings/A2RuntimeSettings.m")
                                             encoding:NSUTF8StringEncoding error:NULL];
    ok(ui.length > 0, @"读得到设置页运行环境分组");
    ok([ui containsString:@"A2SelectedRendererPrefKey"] &&
       [ui containsString:@"A2SelectedJavaRuntimePrefKey"],
       @"★设置页是这两个键的唯一写入点（Air2 自己的 NSUserDefaults）★");
    ok([ui containsString:@"setObject:cand.identifier"], @"渲染器写入的是 dylib 文件名");

    // ★[FRAME-PERF] 渲染分辨率倍率的「写点/读点各一处」★
    ok([session containsString:@"A2SelectedRenderScalePrefKey"],
       @"★Player 读渲染分辨率倍率偏好键（读取点）★");
    ok([session containsString:@"[A2-RENDER] chosen="],
       @"★倍率选择有判据行 [A2-RENDER] chosen=★");
    ok([session containsString:@"renderScale:renderScale"],
       @"★归一化后的倍率被传给 Bridge（不是只在 UI 里存着）★");
    ok([ui containsString:@"A2SelectedRenderScalePrefKey"],
       @"★设置页是倍率键的唯一写入点★");
    ok([ui containsString:@"[NSUserDefaults.standardUserDefaults setObject:stored"],
       @"倍率写入的是受支持档的十进制字符串（0.50/0.75/1.00）★");

    NSString *vc = [NSString stringWithContentsOfFile:
                    RepoPath(@"Air2/UI/Screens/Settings/A2SettingsViewController.m")
                                             encoding:NSUTF8StringEncoding error:NULL];
    ok([vc containsString:@"[A2RuntimeSettings buildWithHost:self]"],
       @"★设置页真的挂上了这个分组（谁能看见）★");

    // ★随包件存在性与非空（新入库的渲染器三件套）★
    NSArray<NSString *> *staged = @[
        @"Libraries/Renderers/libmetallum.dylib",
        @"Libraries/Renderers/libgl4es_114.dylib",
        @"Libraries/Frameworks/libEGL.framework/libEGL",
        @"Libraries/Frameworks/libGLESv2.framework/libGLESv2",
    ];
    for (NSString *rel in staged) {
        NSString *full = RepoPath(rel);
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
        ok(at != nil && [at[NSFileSize] longLongValue] > 1024,
           [NSString stringWithFormat:@"随仓渲染器件存在且非空：%@", rel]);
    }

    // 入库走 gen 脚本（禁手改 pbxproj）：.framework 依赖也要被随包阶段搬走
    NSString *gen = [NSString stringWithContentsOfFile:RepoPath(@"scripts/gen_xcodeproj.py")
                                              encoding:NSUTF8StringEncoding error:NULL];
    ok([gen containsString:@"/Frameworks/*.framework"],
       @"★gen 脚本随包阶段会搬 .framework 依赖（GL4ES→ANGLE）★");
    ok([gen containsString:@"Renderers/*.dylib"], @"gen 脚本随包阶段搬 Libraries/Renderers/*.dylib");

    // ★阴性对照★：一个必然不存在的路径 —— 上面那套「存在性」检查不能是无条件通过
    NSDictionary *nope = [[NSFileManager defaultManager]
                          attributesOfItemAtPath:RepoPath(@"Libraries/Renderers/lib-不存在.dylib") error:NULL];
    ok(nope == nil, @"阴性对照：不存在的渲染器件读不到（证明上面的断言不是恒真）");
}

// ============================================================================

int main(void) {
    @autoreleasepool {
        printf("=== Air2 tests/Runtime：渲染器 / Java 运行时「两张列表」单测 ===\n");
        testRendererCatalog();
        testJavaRuntimeCatalog();
        testRuntimeStrings();
        testRenderScaleCatalog();
        testWiring();
        printf("\n================ 汇总 ================\n");
        printf("PASS=%d  FAIL=%d\n", gPass, gFail);
        if (gFail == 0) printf("全部通过\n"); else printf("有失败项\n");
        return gFail == 0 ? 0 : 1;
    }
}
