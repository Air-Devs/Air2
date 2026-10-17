//
//  mirror_tests.m
//  Air2 —— tests/Mirror：★国内镜像链（URL 重写表 / 国内判定 / 开关 / 判据行接线）★
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（★直接编译并运行真实实现，不是 Python / 文本镜像★）：
//    Air2/Core/Addons/A2MirrorResolver.m  ← 域名映射与候选链的唯一实现处
//    Air2/Core/Settings/A2Settings.m      ← 开关 / 优先级的落盘语义
//
//  为什么必须真跑：
//    「官方 URL 有没有被改写成对的镜像 URL」是**字符串变换 + 顺序**的行为问题。
//    源码扫描只能证明「文字在文件里」；只有把改写函数真的喂进每条官方路径、
//    再看输出，才能证明「库走 /maven、资源走 /assets、同前缀异主机不被误改写」。
//
//  时区用例（②）为什么拆到 runner 里跑多轮：
//    isChinaMainland 读的是**系统时区**，同一进程内改不了。
//    故 runner 用 TZ 环境变量把同一个二进制跑多次，
//    本文件按 A2_MIRROR_TZ_EXPECT=cn|noncn 断言结论 —— 真实行为，不是复刻逻辑。
//
//  运行：python3 tests/Mirror/run_mirror_tests.py   （需 macOS + clang）
//

#import <Foundation/Foundation.h>

#import "A2MirrorResolver.h"

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

static void eqArr(NSArray<NSString *> *got, NSArray<NSString *> *want, NSString *what) {
    ok([got isEqualToArray:want],
       [NSString stringWithFormat:@"%@（得到 %@，期望 %@）", what, got, want]);
}

/// …/tests/Mirror/mirror_tests.m → …/tests → 仓根
static NSString *RepoPath(NSString *relative) {
    NSString *here = [NSString stringWithUTF8String:__FILE__];
    NSString *testsDir = [[here stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSString *root = [testsDir stringByDeletingLastPathComponent];
    return [root stringByAppendingPathComponent:relative];
}

static NSString *ReadRepo(NSString *relative) {
    NSString *p = RepoPath(relative);
    NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
    return s ?: @"";
}

static NSString *const kBMCL = @"https://bmclapi2.bangbang93.com";
static NSString *const kMCIM = @"https://mod.mcimirror.top";

// ============================================================================
#pragma mark - ① URL 重写表（逐域名 / 逐路径 + 不改写的反例）
// ============================================================================

static void testRewriteTable(void) {
    printf("\n=== ① URL 重写表 ===\n");

    // --- Mojang 版本清单 / 版本 JSON → BMCLAPI 根（路径原样保留）---
    eqStr([A2MirrorResolver mirroredURLFor:
           @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"],
          [kBMCL stringByAppendingString:@"/mc/game/version_manifest_v2.json"],
          @"★版本清单 URL 走镜像（路径原样保留）★");
    eqStr([A2MirrorResolver mirroredURLFor:
           @"https://piston-meta.mojang.com/v1/packages/abcd/1.21.4.json"],
          [kBMCL stringByAppendingString:@"/v1/packages/abcd/1.21.4.json"],
          @"★版本 JSON（piston-meta）走镜像★");
    eqStr([A2MirrorResolver mirroredURLFor:
           @"https://piston-data.mojang.com/v1/objects/abcd/client.jar"],
          [kBMCL stringByAppendingString:@"/v1/objects/abcd/client.jar"],
          @"★客户端 jar（piston-data）走镜像★");
    eqStr([A2MirrorResolver mirroredURLFor:
           @"https://launchermeta.mojang.com/mc/game/version_manifest.json"],
          [kBMCL stringByAppendingString:@"/mc/game/version_manifest.json"],
          @"老版本清单域名（launchermeta）也走镜像");
    eqStr([A2MirrorResolver mirroredURLFor:
           @"https://launcher.mojang.com/v1/objects/abcd/client.jar"],
          [kBMCL stringByAppendingString:@"/v1/objects/abcd/client.jar"],
          @"老客户端域名（launcher.mojang.com）也走镜像");

    // --- Mojang 依赖库 → /maven ---
    eqStr([A2MirrorResolver mirroredURLFor:
           @"https://libraries.minecraft.net/com/google/guava/guava/21.0/guava-21.0.jar"],
          @"https://bmclapi2.bangbang93.com/maven/com/google/guava/guava/21.0/guava-21.0.jar",
          @"★依赖库走镜像 + /maven 前缀★");
    eqStr([A2MirrorResolver mirroredURLFor:
           @"https://libraries.minecraft.net/net/java/jinput/jinput/2.0.6/jinput-2.0.6.jar"],
          @"https://bmclapi2.bangbang93.com/maven/net/java/jinput/jinput/2.0.6/jinput-2.0.6.jar",
          @"依赖库第二条路径同样加 /maven");

    // --- Mojang 资源对象 → /assets ---
    eqStr([A2MirrorResolver mirroredURLFor:
           @"https://resources.download.minecraft.net/ab/abcdef0123456789"],
          @"https://bmclapi2.bangbang93.com/assets/ab/abcdef0123456789",
          @"★资源对象走镜像 + /assets 前缀★");
    eqStr([A2MirrorResolver mirroredURLFor:
           @"http://resources.download.minecraft.net/ab/abcdef0123456789"],
          @"https://bmclapi2.bangbang93.com/assets/ab/abcdef0123456789",
          @"http 版资源地址也认（老 manifest 里有 http）");
    eqStr([A2MirrorResolver mirroredURLFor:
           @"https://resources.download.minecraft.net/00/00112233445566778899aabbccddeeff00112233"],
          @"https://bmclapi2.bangbang93.com/assets/00/00112233445566778899aabbccddeeff00112233",
          @"资源对象深路径（两位分目录 + 40 位 hash）整体保留");

    // --- Modrinth / CurseForge 文件 CDN → MCIM（既有行为：只换主机）---
    eqStr([A2MirrorResolver mirroredURLFor:@"https://edge.forgecdn.net/files/1/2/x.jar"],
          [kMCIM stringByAppendingString:@"/files/1/2/x.jar"],
          @"★CurseForge CDN 仍是只换主机到 MCIM（既有行为不变）★");
    eqStr([A2MirrorResolver mirroredURLFor:@"https://cdn.modrinth.com/data/abc/versions/1/x.jar"],
          [kMCIM stringByAppendingString:@"/data/abc/versions/1/x.jar"],
          @"★Modrinth CDN 仍是只换主机到 MCIM★");
    eqStr([A2MirrorResolver mirroredURLFor:@"https://media.forgecdn.net/avatars/1/2.png"],
          [kMCIM stringByAppendingString:@"/avatars/1/2.png"],
          @"CurseForge media 域名同样只换主机");

    // --- 可镜像判定（与改写一致）---
    ok([A2MirrorResolver isMirrorableURL:kBMCL] == NO,
       @"已是镜像站地址不判为可镜像（避免二次改写）");
    ok([A2MirrorResolver isMirrorableURL:@"https://libraries.minecraft.net/a/b.jar"] == YES,
       @"libraries 官方地址判为可镜像");
    ok([A2MirrorResolver isMirrorableURL:@"https://resources.download.minecraft.net/ab/cd"] == YES,
       @"resources 官方地址判为可镜像");

    // --- ★不改写的反例★ ---
    eqStr([A2MirrorResolver mirroredURLFor:@"https://cdn.modrinth.com.evil.example/x.jar"] ?: @"(nil)",
          @"(nil)",
          @"★反例：同前缀异主机（cdn.modrinth.com.evil.example）不被误改写★");
    eqStr([A2MirrorResolver mirroredURLFor:@"https://libraries.minecraft.network/a/b.jar"] ?: @"(nil)",
          @"(nil)",
          @"★反例：libraries.minecraft.network 不被误改写（library 域名的经典陷阱）★");
    eqStr([A2MirrorResolver mirroredURLFor:@"https://resources.download.minecraft.net.evil/ab/cd"] ?: @"(nil)",
          @"(nil)",
          @"★反例：resources 同前缀异主机不被误改写★");
    eqStr([A2MirrorResolver mirroredURLFor:@"https://piston-meta.mojang.com"] ?: @"(nil)",
          @"(nil)",
          @"★反例：前缀后没有 / 的裸主机不算命中（要求紧跟 /）★");
    eqStr([A2MirrorResolver mirroredURLFor:@"https://bmclapi2.bangbang93.com/maven/a/b.jar"] ?: @"(nil)",
          @"(nil)",
          @"★反例：已是镜像地址不重复改写（幂等）★");
    eqStr([A2MirrorResolver mirroredURLFor:kMCIM] ?: @"(nil)",
          @"(nil)",
          @"★反例：MCIM 裸根不重复改写★");
    eqStr([A2MirrorResolver mirroredURLFor:@""] ?: @"(nil)",
          @"(nil)",
          @"反例：空串返回 nil");
    eqStr([A2MirrorResolver mirroredURLFor:@"https://files.minecraftforge.net/maven/x.jar"] ?: @"(nil)",
          @"(nil)",
          @"反例：本单未登记的域名（Forge 官方站）不改写 —— 映射表只覆盖原版分发 + 模组 CDN");
    eqStr([A2MirrorResolver mirroredURLFor:@"https://api.modrinth.com/v2/search"] ?: @"(nil)",
          @"(nil)",
          @"反例：Modrinth API 域名不在文件 CDN 表内（本单只管原版分发与文件 CDN）");

    // --- 已有调用方（A2ContentSource 走 instance 方法）仍成立 ---
    ok([A2MirrorResolver isMirrorableURL:@"https://edge.forgecdn.net/files/x"] == YES,
       @"资源站仍可镜像（既有调用方不回归）");
}

// ============================================================================
#pragma mark - ② 国内判定（依据 TZ 环境变量，由 runner 多轮跑）
// ============================================================================

static void testChinaMainland(void) {
    printf("\n=== ② 中国大陆判定（依据系统时区）===\n");

    NSString *tz = NSTimeZone.localTimeZone.name ?: @"";
    NSString *expect = NSProcessInfo.processInfo.environment[@"A2_MIRROR_TZ_EXPECT"] ?: @"";

    printf("       本轮 TZ=%s（期望=%s）\n", tz.UTF8String, expect.UTF8String);

    BOOL mainland = [A2MirrorResolver isChinaMainland];

    if ([expect isEqualToString:@"cn"]) {
        ok(mainland, [NSString stringWithFormat:@"★时区 %@ 判为大陆★", tz]);
    } else if ([expect isEqualToString:@"noncn"]) {
        ok(!mainland, [NSString stringWithFormat:@"★时区 %@ 判为非大陆★", tz]);
    } else {
        // 无期望时不猜结论，只断言「判定与实现列的 5 个时区名一致」
        NSArray<NSString *> *cnNames = @[@"Asia/Shanghai", @"Asia/Chongqing", @"Asia/Harbin",
                                        @"Asia/Urumqi", @"Asia/Kashgar"];
        ok(mainland == [cnNames containsObject:tz],
           [NSString stringWithFormat:@"判定与实现登记的 5 个大陆时区名一致（TZ=%@）", tz]);
    }

    // 判据串必须把「依据（时区名）」打出来，否则真机无法对账。
    // 这几条与 TZ 无关，只在首轮断言一次（runner 用 A2_MIRROR_SOURCE_CHECK=1 标首轮）。
    if (![NSProcessInfo.processInfo.environment[@"A2_MIRROR_SOURCE_CHECK"] isEqualToString:@"1"]) return;

    NSString *src = ReadRepo(@"Air2/Core/Addons/A2MirrorResolver.m");
    for (NSString *name in @[@"Asia/Shanghai", @"Asia/Chongqing", @"Asia/Harbin",
                             @"Asia/Urumqi", @"Asia/Kashgar"]) {
        ok([src containsString:name],
           [NSString stringWithFormat:@"实现里登记了大陆时区 %@", name]);
    }
    ok([src rangeOfString:@"Asia/Tokyo"].location == NSNotFound,
       @"阴性对照：非大陆时区（Asia/Tokyo）不在登记表里");
}

// ============================================================================
#pragma mark - ③ 开关 / 优先级 四组合
// ============================================================================

static void testSwitchAndPriority(void) {
    printf("\n=== ③ 开关与优先级（纯函数，四种组合）===\n");

    NSString *lib = @"https://libraries.minecraft.net/a/b.jar";
    NSString *libMirror = @"https://bmclapi2.bangbang93.com/maven/a/b.jar";
    NSString *manifest = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    NSString *manifestMirror = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";

    // 开 + 镜像优先 + 大陆 ⇒ 镜像在前、官方兜底
    eqArr([A2MirrorResolver candidateURLsForURL:manifest enabled:YES
                                       priority:A2MirrorPriorityMirrorFirst chinaMainland:YES],
          @[manifestMirror, manifest],
          @"★开+镜像优先+大陆 ⇒ [镜像, 官方]（镜像优先、官方兜底）★");
    eqArr([A2MirrorResolver candidateURLsForURL:lib enabled:YES
                                       priority:A2MirrorPriorityMirrorFirst chinaMainland:YES],
          @[libMirror, lib],
          @"★依赖库同链：/maven 镜像在前、官方在后★");

    // 开 + 官方优先 + 大陆 ⇒ 官方在前、镜像兜底
    eqArr([A2MirrorResolver candidateURLsForURL:manifest enabled:YES
                                       priority:A2MirrorPriorityOfficialFirst chinaMainland:YES],
          @[manifest, manifestMirror],
          @"开+官方优先+大陆 ⇒ [官方, 镜像]");

    // 开关关掉 ⇒ 只有官方（一键关闭的语义）
    eqArr([A2MirrorResolver candidateURLsForURL:manifest enabled:NO
                                       priority:A2MirrorPriorityMirrorFirst chinaMainland:YES],
          @[manifest],
          @"★开关关掉 ⇒ 单源官方（一键关闭生效）★");

    // 非大陆 ⇒ 只有官方（默认仅国内启用）
    eqArr([A2MirrorResolver candidateURLsForURL:manifest enabled:YES
                                       priority:A2MirrorPriorityMirrorFirst chinaMainland:NO],
          @[manifest],
          @"★非大陆 ⇒ 单源官方（默认仅国内启用）★");

    // 不可镜像地址 ⇒ 四组合都只有自己
    NSString *unknown = @"https://files.minecraftforge.net/maven/x.jar";
    eqArr([A2MirrorResolver candidateURLsForURL:unknown enabled:YES
                                       priority:A2MirrorPriorityMirrorFirst chinaMainland:YES],
          @[unknown], @"不可镜像地址（镜像优先档）原样单源");
    eqArr([A2MirrorResolver candidateURLsForURL:unknown enabled:YES
                                       priority:A2MirrorPriorityOfficialFirst chinaMainland:YES],
          @[unknown], @"不可镜像地址（官方优先档）原样单源");
    eqArr([A2MirrorResolver candidateURLsForURL:unknown enabled:NO
                                       priority:A2MirrorPriorityMirrorFirst chinaMainland:NO],
          @[unknown], @"不可镜像地址（关掉）原样单源");

    // 已是镜像地址 ⇒ 不再包装（幂等）
    eqArr([A2MirrorResolver candidateURLsForURL:libMirror enabled:YES
                                       priority:A2MirrorPriorityMirrorFirst chinaMainland:YES],
          @[libMirror], @"★已是镜像地址的候选链仍是单条（幂等，不来回包装）★");

    // 空串 ⇒ 空数组（调用方不会拿到 @[@""]）
    eqArr([A2MirrorResolver candidateURLsForURL:@"" enabled:YES
                                       priority:A2MirrorPriorityMirrorFirst chinaMainland:YES],
          @[], @"空串展开为空数组");

    // 资源对象：镜像优先档下也是镜像在前（★与老线的减压例外不同，本单有意为之★）
    NSString *asset = @"https://resources.download.minecraft.net/ab/cdef";
    eqArr([A2MirrorResolver candidateURLsForURL:asset enabled:YES
                                       priority:A2MirrorPriorityMirrorFirst chinaMainland:YES],
          @[@"https://bmclapi2.bangbang93.com/assets/ab/cdef", asset],
          @"★资源对象在镜像优先档下镜像在前（老线的「资源恒官方优先」例外未沿用）★");
}

// ============================================================================
#pragma mark - ④ 源标签（判据行用）
// ============================================================================

static void testSourceLabel(void) {
    printf("\n=== ④ 源标签（判据行字段）===\n");

    eqStr([A2MirrorResolver sourceLabelForURL:@"https://bmclapi2.bangbang93.com/maven/a.jar"],
          @"mirror(bmclapi)", @"BMCLAPI 地址 → mirror(bmclapi)");
    eqStr([A2MirrorResolver sourceLabelForURL:@"https://mod.mcimirror.top/data/x.jar"],
          @"mirror(mcim)", @"MCIM 地址 → mirror(mcim)");
    eqStr([A2MirrorResolver sourceLabelForURL:@"https://libraries.minecraft.net/a.jar"],
          @"official", @"官方域名 → official");
    eqStr([A2MirrorResolver sourceLabelForURL:@"https://piston-meta.mojang.com/x.json"],
          @"official", @"piston-meta → official");
    eqStr([A2MirrorResolver sourceLabelForURL:@""], @"(空)", @"空串有独立标签（不误报 official）");
}

// ============================================================================
#pragma mark - ⑤ 接线判据（源码级：判据行真的接在下载路径上）
// ============================================================================

static void testWiring(void) {
    printf("\n=== ⑤ 接线判据（判据行 / 候选展开真的在下载路径上）===\n");

    NSString *installer = ReadRepo(@"Air2/Core/Version/A2GameInstaller.m");
    NSString *engine = ReadRepo(@"Air2/Core/Download/A2DownloadEngine.m");
    NSString *resolver = ReadRepo(@"Air2/Core/Addons/A2MirrorResolver.m");
    NSString *settings = ReadRepo(@"Air2/Core/Settings/A2Settings.m");
    NSString *ui = ReadRepo(@"Air2/UI/Screens/Settings/A2AppearanceSettings.m");

    // 判据行前缀
    ok([installer containsString:@"[A2-MIRROR] %@"],
       @"★安装器打「开关 + 判定依据」判据行（auditSummary）★");
    ok([resolver containsString:@"[A2-MIRROR]"] == NO,
       @"本类自己不写日志（只出字符串，单测才不需要日志环境）");

    // ★候选展开的唯一入口★
    ok([installer containsString:@"for (NSString *c in [self candidatesForURL:u])"],
       @"★download: 里把传入地址统一展开成候选链（唯一入口）★");
    ok([installer containsString:@"[self candidatesForURL:url]"] &&
       [installer containsString:@"[self candidatesForURL:jarURL]"] &&
       [installer containsString:@"[self candidatesForURL:indexURL]"],
       @"★版本 json / 客户端 jar / 资源索引都走候选链（不再只吃 manifest 原始 URL）★");
    ok([installer containsString:@"[[A2MirrorResolver shared] candidateURLsForURL:kVersionManifestURL]"],
       @"★版本清单候选源 = 镜像优先 → 官方兜底★");

    // 版本清单的逐源尝试
    ok([installer containsString:@"fetchManifestFromCandidate:index + 1"],
       @"★版本清单源失败 ⇒ 换下一个候选源（官方兜底）★");

    // 每阶段判据行（★完整 token 直接在源码里可 grep★）
    for (NSString *stage in @[@"stage=manifest", @"stage=version-json", @"stage=client-jar",
                              @"stage=assets-index", @"stage=libraries", @"stage=assets"]) {
        ok([installer containsString:stage],
           [NSString stringWithFormat:@"有阶段判据 token：%@", stage]);
    }
    ok([installer containsString:@"stage=version-list"] ||
       [ReadRepo(@"Air2/Core/Version/A2RemoteVersions.m") containsString:@"stage=version-list"],
       @"版本列表（A2RemoteVersions）也有阶段判据 token");

    // 换源判据行（引擎侧）
    ok([engine containsString:@"[A2-MIRROR] failover"],
       @"★换源有判据行（镜像 ⇄ 官方切没切，真机可查）★");
    ok([engine containsString:@"self.candidateIndex++"],
       @"换源仍是引擎既有的候选遍历（★不新造第二套换源机制★）");

    // 并发
    ok([installer containsString:@"kA2InstallDefaultConcurrency = 6"],
       @"★安装并发默认值 = 6★");
    ok([installer containsString:@"kA2InstallMaxConcurrency = 8"],
       @"并发上限仍是 8（未放开）");
    ok([installer containsString:@"@\"air2.install.concurrency\""],
       @"override 键 air2.install.concurrency 仍在（真机试参可用）");
    ok([installer containsString:@"if (n > kA2InstallMaxConcurrency) n = kA2InstallMaxConcurrency;"],
       @"并发值仍夹到 [1, 上限]");

    // 开关与默认档位
    ok([settings containsString:@"defaultValue:A2SettingsMirrorFirst"],
       @"★默认档位 = 镜像优先（否则镜像只在官方失败后才用上）★");
    ok([settings containsString:@"A2SettingsKeyMirrorEnabled"],
       @"开关仍落盘到 A2MirrorEnabled（一键关闭的持久化）");
    ok([ui containsString:@"[A2MirrorResolver shared].enabled = isOn"],
       @"★设置页开关是「一键关闭」入口★");
    ok([ui containsString:@"第三方"],
       @"★UI 文案写明镜像为第三方（出处与风险）★");
    ok([ui containsString:@"BMCLAPI"],
       @"UI 文案点名 BMCLAPI 出处");

    // ★唯一实现处★：域名判断不许在别处再写一份
    ok(![installer containsString:@"bmclapi2.bangbang93.com"] &&
       ![engine containsString:@"bmclapi2.bangbang93.com"],
       @"★除 A2MirrorResolver 外没有第二处写 BMCLAPI 主机名（映射表唯一）★");
    ok(![installer containsString:@"libraries.minecraft.net"] &&
       ![engine containsString:@"libraries.minecraft.net"],
       @"★除 A2MirrorResolver 外没有第二处写官方库域名★");
    ok([resolver containsString:@"https://libraries.minecraft.net"] &&
       [resolver containsString:@"https://resources.download.minecraft.net"] &&
       [resolver containsString:@"https://piston-meta.mojang.com"],
       @"★三个 Mojang 域名都在映射表里（本单的核心交付）★");
    ok([resolver containsString:@"@\"/maven\""] && [resolver containsString:@"@\"/assets\""],
       @"★库走 /maven、资源走 /assets 的路径约定在实现里★");

    // 阴性对照：扫描不能恒真
    ok([installer rangeOfString:@"[A2-不存在]"].location == NSNotFound,
       @"阴性对照：不存在的判据串扫不到（证明上面的扫描不是恒真）");
    ok([ReadRepo(@"docs/DECISIONS.md") rangeOfString:@"ADR-011"].location != NSNotFound,
       @"决策记录里有 ADR-011（镜像链：第三方出处与风险、可关）");
}

// ============================================================================

int main(void) {
    @autoreleasepool {
        printf("=== Air2 tests/Mirror：国内镜像链单测 ===\n");
        testRewriteTable();
        testChinaMainland();
        testSwitchAndPriority();
        testSourceLabel();
        testWiring();
        printf("\n================ 汇总 ================\n");
        printf("TOTAL pass=%d fail=%d\n", gPass, gFail);
        if (gFail == 0) printf("[mirror] 全部通过\n"); else printf("[mirror] 有失败项\n");
        return gFail == 0 ? 0 : 1;
    }
}
