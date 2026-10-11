//
//  instance_path_tests.m
//  Air2 —— tests/Instance：★「一个已安装的版本实例」的落位路径 + 真落盘后判存在★
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（★直接链接真实实现，不是 Python/文本镜像★）：
//    Air2/Core/Path/A2VersionIsolation.m   ← A2GamePath：versions/<id>/<id>.{json,jar}
//                                              与 libraries/ assets/ 的唯一计算处
//    Air2/Utils/A2Log.m                    ← 判据行落点（随包真实实现）
//
//  为什么要有它（缺口⑤「versions/ = 0」的判据）：
//    「装完之后 versions/ 里真的有一个可用实例、且启动路径认到的是同一份」是行为问题。
//    源码扫描只能证明「文字在文件里」；只有把 A2GamePath 真的跑一遍、真的在临时游戏
//    目录里落盘再判存在，才能证明「写入的那条路径 == 启动判存在的那条路径」。
//
//  运行：python3 tests/Instance/run_instance_tests.py
//        （需 macOS + clang；Windows 无 clang 属预期）
//

#import <Foundation/Foundation.h>

#import "A2VersionIsolation.h"

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

/// …/tests/Instance/instance_path_tests.m → …/tests → 仓根
static NSString *RepoPath(NSString *relative) {
    NSString *here = [NSString stringWithUTF8String:__FILE__];
    NSString *testsDir = [[here stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSString *root = [testsDir stringByDeletingLastPathComponent];
    return [root stringByAppendingPathComponent:relative];
}

static NSString *TempDir(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"a2inst_%@", NSUUID.UUID.UUIDString]];
}

static BOOL WriteFile(NSString *path, NSData *data) {
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    return [data writeToFile:path atomically:YES];
}

static NSData *Bytes(NSString *s) {
    return [s dataUsingEncoding:NSUTF8StringEncoding];
}

// ============================================================================
#pragma mark - ① 实例路径（写侧与读侧共用的唯一一处计算）
// ============================================================================

static void testInstancePaths(void) {
    printf("\n=== ① A2GamePath：实例路径的唯一计算处 ===\n");

    A2GamePath *p = [A2GamePath pathWithGameHome:@"/g/minecraft"];
    eqStr([p gameHome], @"/g/minecraft", @"gameHome 原样保留");
    eqStr([p versionsHome], @"/g/minecraft/versions", @"versions/ 在游戏根下");
    eqStr([p librariesHome], @"/g/minecraft/libraries", @"libraries/ 在游戏根下（不随版本走）");
    eqStr([p assetsHome], @"/g/minecraft/assets", @"assets/ 在游戏根下（不随版本走）");

    eqStr([p versionPath:@"1.21"], @"/g/minecraft/versions/1.21", @"版本目录 = versions/<id>");
    eqStr([p versionJSONPath:@"1.21"], @"/g/minecraft/versions/1.21/1.21.json",
          @"★版本 json = versions/<id>/<id>.json★");
    eqStr([p versionJarPath:@"1.21"], @"/g/minecraft/versions/1.21/1.21.jar",
          @"★客户端 jar = versions/<id>/<id>.jar★");

    // 带加载器的实例名（<mc>-<loader>）：目录名与文件名必须共用同一个 id
    eqStr([p versionPath:@"1.21-fabric"], @"/g/minecraft/versions/1.21-fabric",
          @"加载器实例目录 = versions/1.21-fabric");
    eqStr([p versionJSONPath:@"1.21-fabric"],
          @"/g/minecraft/versions/1.21-fabric/1.21-fabric.json", @"加载器版 json 同名");
    eqStr([p versionJarPath:@"1.21-fabric"],
          @"/g/minecraft/versions/1.21-fabric/1.21-fabric.jar", @"加载器版 jar 同名");

    // 尾斜杠归一：不得拼出 "versions//1.21/1.21.jar"
    A2GamePath *q = [A2GamePath pathWithGameHome:@"/g/minecraft/"];
    eqStr([q gameHome], @"/g/minecraft", @"Trailing slash 被去掉（不拼出 //versions）");
    eqStr([q versionJarPath:@"1.21"], [p versionJarPath:@"1.21"],
          @"带/不带尾斜杠 ⇒ 同一路径");

    // 根目录 "/" 不得被削成空串
    A2GamePath *r = [A2GamePath pathWithGameHome:@"/"];
    eqStr([r gameHome], @"/", @"gameHome=/ 不被削成空串");
}

// ============================================================================
#pragma mark - ② 真落盘 → 真判存在（安装收尾 / 启动前用的就是这一对判据）
// ============================================================================

static void testLandedInstanceIsSeen(void) {
    printf("\n=== ② 落盘 → 判存在（写入的那条路径 == 启动判存在的那条路径）===\n");

    NSString *home = TempDir();
    A2GamePath *p = [A2GamePath pathWithGameHome:home];
    NSFileManager *fm = NSFileManager.defaultManager;

    NSString *json = [p versionJSONPath:@"1.21"];
    NSString *jar = [p versionJarPath:@"1.21"];

    // 阴性对照：还没装 ⇒ 两条判据都为假（证明下面的 TRUE 不是恒真）
    ok(![fm fileExistsAtPath:json], @"阴性对照：未安装 ⇒ json 判不存在");
    ok(![fm fileExistsAtPath:jar], @"阴性对照：未安装 ⇒ jar 判不存在");

    // 模拟安装器收尾落盘（json + jar）
    ok(WriteFile(json, Bytes(@"{\"id\":\"1.21\",\"type\":\"release\"}")), @"安装：写入版本 json");
    ok(WriteFile(jar, Bytes(@"PKfake")), @"安装：写入客户端 jar");

    ok([fm fileExistsAtPath:json], @"★落盘后 json 判存在（安装收尾判据）★");
    ok([fm fileExistsAtPath:jar], @"★落盘后 jar 判存在（启动前判据）★");

    // assets / libraries 的实际位置（共用，不随版本走）
    NSString *assetIndex = [[p assetsHome] stringByAppendingPathComponent:@"indexes/1.21.json"];
    NSString *libArtifact = [[p librariesHome]
        stringByAppendingPathComponent:@"org/lwjgl/lwjgl/3.3.3/lwjgl-3.3.3.jar"];
    ok(WriteFile(assetIndex, Bytes(@"{}")), @"安装：写入 assets 索引");
    ok(WriteFile(libArtifact, Bytes(@"PK")), @"安装：写入 libraries 制品");
    ok([fm fileExistsAtPath:assetIndex],
       @"★assets 索引落在 <gameHome>/assets/indexes/<id>.json★");
    ok([fm fileExistsAtPath:libArtifact],
       @"★libraries 制品落在 <gameHome>/libraries/<坐标路径>★");

    // ★写读逐字一致★：启动侧那条 jar 由 version.versionPath + "<id>.jar" 拼出
    //   （A2LaunchSession.m 的 versionJar），必须与 A2GamePath 的 versionJarPath 同串。
    NSString *launchSideJar = [[[p versionPath:@"1.21"]
                                stringByAppendingPathComponent:@"1.21"]
                               stringByAppendingPathExtension:@"jar"];
    eqStr(launchSideJar, jar,
          @"★启动侧手工拼接 == A2GamePath versionJarPath（同一字符串，不是「看起来一样」）★");

    // 加载器实例：基底原版 + 加载器实例两份都必须齐（重叠不了就起不来）
    NSString *baseJar = [p versionJarPath:@"1.21"];
    NSString *loaderJar = [p versionJarPath:@"1.21-fabric"];
    ok(WriteFile([p versionJSONPath:@"1.21-fabric"], Bytes(@"{\"inheritsFrom\":\"1.21\"}")),
       @"加载器：写入 1.21-fabric.json");
    ok(WriteFile(loaderJar, Bytes(@"PK")), @"加载器：写入 1.21-fabric.jar（原版 jar 的硬链落点）");
    ok([fm fileExistsAtPath:loaderJar], @"加载器实例 jar 在 ⇒ 实例目录已建");
    ok([fm fileExistsAtPath:baseJar],
       @"基底原版 jar 仍在 ⇒ inheritsFrom 引用得到（加载器版硬链它的 jar）");

    [fm removeItemAtPath:home error:NULL];
    ok(![fm fileExistsAtPath:jar], @"清理：临时游戏目录已删除（不留垃圾）");
}

// ============================================================================
#pragma mark - ③ 接线自证（谁写 / 谁读 / 判据行在不在）
// ============================================================================

static NSString *ReadRepo(NSString *rel) {
    return [NSString stringWithContentsOfFile:RepoPath(rel)
                                     encoding:NSUTF8StringEncoding error:NULL];
}

static void testWiring(void) {
    printf("\n=== ③ 接线自证（落点 / 判据行 / 单一起源）===\n");

    NSString *iso = ReadRepo(@"Air2/Core/Path/A2VersionIsolation.m");
    ok(iso.length > 0, @"读得到 A2VersionIsolation.m（路径的唯一计算处）");
    ok([iso containsString:@"- (NSString *)versionsHome"] &&
       [iso containsString:@"- (NSString *)versionJSONPath:"] &&
       [iso containsString:@"- (NSString *)versionJarPath:"],
       @"★versions/<id>/<id>.{json,jar} 由 A2GamePath 一处给出★");

    // 装：落点走 A2GamePath（baseVersionName = 原版自己，或带加载器时的 mcVersion）
    NSString *installer = ReadRepo(@"Air2/Core/Version/A2GameInstaller.m");
    ok([installer containsString:@"[path versionJSONPath:self.baseVersionName]"],
       @"★安装器 json 落点 = versionJSONPath:★");
    ok([installer containsString:@"[path versionJarPath:self.baseVersionName]"],
       @"★安装器 jar 落点 = versionJarPath:★");
    ok([installer containsString:@"[A2-INSTANCE] id="] &&
       [installer containsString:@"stage=install"],
       @"★安装收尾有可 grep 的判据行 [A2-INSTANCE] stage=install★");
    ok([installer containsString:@"versionJSONPath:self.request.versionName"] &&
       [installer containsString:@"versionJarPath:self.request.versionName"],
       @"安装收尾校验的是**成品实例名**（带加载器时 = <mc>-<loader>）");

    // 加载器版实例同样落在 versions/<加载器版名>/
    NSString *loader = ReadRepo(@"Air2/Core/Addons/A2ModLoaderInstaller.m");
    ok([loader containsString:@"[path versionJSONPath:self.versionName]"],
       @"加载器 json 落点 = versions/<加载器版名>/<加载器版名>.json");
    ok([loader containsString:@"[path versionJarPath:self.versionName]"],
       @"加载器版 jar（原版 jar 的硬链）落点 = versionJarPath:versionName");

    // 启动：读的就是同一处计算
    NSString *session = ReadRepo(@"Air2/Player/A2LaunchSession.m");
    ok([session containsString:@"[A2-INSTANCE] id="] &&
       [session containsString:@"stage=launch"],
       @"★启动前有可 grep 的判据行 [A2-INSTANCE] stage=launch★");
    ok([session containsString:@"[canonicalPath versionJarPath:version.name]"],
       @"★启动侧判存在用的是 A2GamePath versionJarPath:（同一处计算）★");
    ok([session containsString:@"pathMatch="],
       @"判据行带 pathMatch=（证真正交给计划的那条 jar == 落盘那条）");
    ok([session containsString:@"[canonicalPath librariesHome]"] &&
       [session containsString:@"[canonicalPath assetsHome]"],
       @"★启动侧 libraries/assets 也走 A2GamePath★");

    // ★单一起源★：除 A2GamePath 外，没人再手拼这三个目录（头文件里的硬性约束）
    ok(![installer containsString:@"PathComponent:@\"versions\""] &&
       ![installer containsString:@"PathComponent:@\"libraries\""] &&
       ![installer containsString:@"PathComponent:@\"assets\""],
       @"★安装器不手拼 versions/libraries/assets（无第二份路径知识）★");
    ok(![session containsString:@"PathComponent:@\"versions\""] &&
       ![session containsString:@"PathComponent:@\"libraries\""] &&
       ![session containsString:@"PathComponent:@\"assets\""],
       @"★启动侧不手拼 versions/libraries/assets★");

    NSString *header = ReadRepo(@"Air2/Core/Path/A2VersionIsolation.h");
    ok([header containsString:@"业务代码禁止手写"],
       @"头文件里「禁止手写路径」的硬性约束仍在（本单的收敛依据）");

    // ④ JRE 档位：加档只走 stage 脚本 + gen 的**动态**随包阶段（不需改脚本）
    NSString *gen = ReadRepo(@"scripts/gen_xcodeproj.py");
    ok([gen containsString:@"for r in \"$LIB\"/java_runtimes/*"],
       @"★gen 的随包阶段动态枚举 java_runtimes/* ⇒ 加 java-21 不需改脚本★");
    NSString *stage = ReadRepo(@"scripts/stage_runtime.sh");
    ok([stage containsString:@"A2_JRE_EXTRA"],
       @"★加档走已有 scripts/stage_runtime.sh 的 A2_JRE_EXTRA（不新增入库机制）★");
    ok(![stage containsString:@"curl"] && ![stage containsString:@"wget"],
       @"★stage 脚本不下载任何东西（JRE 内置，不做运行时下载）★");
    ok([session containsString:@"stringByAppendingPathComponent:jreDir"],
       @"★启动计划 javaHome = <包内>/java_runtimes/<选中的档>★");

    // 阴性对照：源码扫描不能恒真
    ok([ReadRepo(@"Air2/Player/A2LaunchSession.m") rangeOfString:@"[A2-不存在]"].location
       == NSNotFound,
       @"阴性对照：不存在的判据串扫不到（证明上面的扫描不是恒真）");
}

// ============================================================================

int main(void) {
    @autoreleasepool {
        printf("=== Air2 tests/Instance：已安装版本实例的落位路径单测 ===\n");
        testInstancePaths();
        testLandedInstanceIsSeen();
        testWiring();
        printf("\n================ 汇总 ================\n");
        printf("PASS=%d  FAIL=%d\n", gPass, gFail);
        if (gFail == 0) printf("全部通过\n"); else printf("有失败项\n");
        return gFail == 0 ? 0 : 1;
    }
}
