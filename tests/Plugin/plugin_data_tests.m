//
//  plugin_data_tests.m
//  Air2 —— tests/Plugin：★插件数据层（manifest 校验 + registry 原子读写）单测★
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（直接链接真实实现，不是文本镜像）：
//    Air2/Core/Plugin/A2PluginManifest.m  ← manifest 解析 / 校验 / 权限集规范串
//    Air2/Core/Plugin/A2PluginRegistry.m  ← registry.json 原子读写 / approvedHashes 淘汰
//
//  为什么要有它：
//    安装器「拒装」的每一个理由都必须是可执行的绿或红，而不是文档里的一句话。
//    下面每条反例都对应 `docs/plugin.schema.json` 的一条约束或
//    `docs/PLUGIN-SECURITY.md` 的一条硬边界 —— 少测一条，就等于少一道门。
//
//  运行：python3 tests/Plugin/run_plugin_tests.py   （需 macOS + clang；Windows 无 clang 属预期）
//

#import <Foundation/Foundation.h>

#import "A2PluginManifest.h"
#import "A2PluginRegistry.h"

static int gPass = 0;
static int gFail = 0;

static void ok(BOOL condition, NSString *what) {
    if (condition) {
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

static NSData *JSONData(NSString *json) {
    return [json dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - manifest 用例素材

/// 一份刚好过校验的最小 manifest（type: json，无权限、无文件）。
/// 反例都在它上面改一个字段 —— 这样「为什么被拒」只可能来自那一处改动。
static NSMutableDictionary *MinimalManifest(void) {
    return [@{
        @"formatVersion": @2,
        @"id": @"top.example.hello",
        @"name": @"Hello",
        @"version": @"1.0.0",
        @"type": @"json",
        @"air2": @{@"host": @{@"apiVersion": @1}},
        @"platforms": @[@"ios"],
        @"files": @[],
    } mutableCopy];
}

/// 一份覆盖尽可能多字段的 manifest（formatVersion 3 + js + 依赖 + 文件 + 语言）。
static NSMutableDictionary *FullManifest(void) {
    NSMutableDictionary *manifest = [@{
        @"formatVersion": @3,
        @"id": @"top.example.downloader",
        @"name": @"示例下载器",
        @"version": @"1.2.0",
        @"type": @"js",
        @"description": @"给下载器加镜像源",
        @"author": @{@"name": @"示例作者", @"url": @"https://example.com/me"},
        @"homepage": @"https://example.com",
        @"license": @"MIT",
        @"air2": @{@"host": @{@"apiVersion": @1, @"minHostVersion": @"0.1.0"}},
        @"platforms": @[@"ios", @"android"],
        @"permissions": @[@"download.source", @"network.http", @"launch.args"],
        @"depends": @[@{@"id": @"top.example.core", @"version": @">=1.0.0"}],
        @"entry": @"entry.js",
        @"ui": @{@"priority": @10, @"slots": @[@{@"slot": @"home.toolbar.action"}]},
        @"contributes": @{@"downloadSources": @[]},
        @"locales": @{@"zh-Hans": @"locales/zh-Hans.json", @"en": @"locales/en.json"},
        @"files": @[
            @{@"path": @"entry.js", @"sha256": @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", @"size": @42},
            @{@"path": @"locales/zh-Hans.json", @"sha256": @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", @"size": @7},
        ],
    } mutableCopy];
    return manifest;
}

static NSError *ValidateDictionary(NSDictionary *dictionary) {
    NSError *error = nil;
    A2PluginManifest *manifest = [A2PluginManifest manifestWithDictionary:dictionary
                                                                   limits:A2PluginDefaultLimits()
                                                                    error:&error];
    return manifest ? nil : error;
}

static NSString *ErrorCode(NSError *error) {
    return error.userInfo[A2PluginErrorCodeKey];
}

/// 反例：期望被拒，且错误码对得上。
static void expectReject(NSString *what, NSDictionary *dictionary, NSString *expectedCode) {
    NSError *error = ValidateDictionary(dictionary);
    if (!error) {
        ok(NO, [NSString stringWithFormat:@"%@（应当拒装，但解析成功了）", what]);
        return;
    }
    NSString *code = ErrorCode(error);
    ok([code isEqualToString:expectedCode],
       [NSString stringWithFormat:@"%@（得到 %@，期望 %@；原因：%@）",
        what, code, expectedCode, error.localizedDescription]);
}

static void expectRejectData(NSString *what, NSData *data, NSString *expectedCode) {
    NSError *error = nil;
    A2PluginManifest *manifest = [A2PluginManifest manifestWithData:data
                                                             limits:A2PluginDefaultLimits()
                                                              error:&error];
    if (manifest) {
        ok(NO, [NSString stringWithFormat:@"%@（应当拒装，但解析成功了）", what]);
        return;
    }
    NSString *code = ErrorCode(error);
    ok([code isEqualToString:expectedCode],
       [NSString stringWithFormat:@"%@（得到 %@，期望 %@；原因：%@）",
        what, code, expectedCode, error.localizedDescription]);
}

#pragma mark - manifest 正例

static void testManifestAccepts(void) {
    // 1) 最小 manifest
    NSError *error = nil;
    A2PluginManifest *minimal = [A2PluginManifest manifestWithDictionary:MinimalManifest()
                                                                  limits:A2PluginDefaultLimits()
                                                                   error:&error];
    ok(minimal != nil, @"最小 manifest 能过校验");
    eqStr(minimal.pluginId, @"top.example.hello", @"最小 manifest 的 id");
    eqInt(minimal.formatVersion, 2, @"最小 manifest 的 formatVersion");
    eqInt(minimal.type, A2PluginTypeJSON, @"最小 manifest 的 type 是 json");
    eqInt(minimal.apiVersion, 1, @"最小 manifest 的 apiVersion");
    eqInt((NSInteger)minimal.platforms.count, 1, @"最小 manifest 的平台数");
    eqInt((NSInteger)minimal.permissions.count, 0, @"最小 manifest 没有申请权限");
    eqStr([minimal canonicalPermissionSet], @"", @"无权限时权限集为空串");

    // 2) 完整 manifest
    NSError *fullError = nil;
    A2PluginManifest *full = [A2PluginManifest manifestWithDictionary:FullManifest()
                                                               limits:A2PluginDefaultLimits()
                                                                error:&fullError];
    ok(full != nil, @"完整 manifest 能过校验");
    eqInt(full.formatVersion, 3, @"完整 manifest 的 formatVersion");
    eqInt(full.type, A2PluginTypeJS, @"完整 manifest 的 type 是 js");
    eqStr(full.name, @"示例下载器", @"完整 manifest 的 name");
    eqStr(full.version, @"1.2.0", @"完整 manifest 的 version");
    eqStr(full.summary, @"给下载器加镜像源", @"完整 manifest 的 description");
    eqStr(full.authorName, @"示例作者", @"完整 manifest 的 author.name");
    eqStr(full.authorURL, @"https://example.com/me", @"完整 manifest 的 author.url");
    eqStr(full.homepage, @"https://example.com", @"完整 manifest 的 homepage");
    eqStr(full.license, @"MIT", @"完整 manifest 的 license");
    eqStr(full.minHostVersion, @"0.1.0", @"完整 manifest 的 air2.host.minHostVersion");
    ok(full.maxHostVersion == nil, @"没声明 maxHostVersion 时为 nil");
    eqStr(full.entry, @"entry.js", @"完整 manifest 的 entry");
    eqInt((NSInteger)full.platforms.count, 2, @"完整 manifest 的平台数");
    eqInt((NSInteger)full.permissions.count, 3, @"完整 manifest 的权限数");
    eqInt((NSInteger)full.dependencies.count, 1, @"完整 manifest 的依赖数");
    eqStr(full.dependencies.firstObject.pluginId, @"top.example.core",
          @"完整 manifest 的依赖 id");
    eqStr(full.dependencies.firstObject.versionConstraint, @">=1.0.0",
          @"完整 manifest 的依赖版本约束");
    eqInt((NSInteger)full.files.count, 2, @"完整 manifest 的文件数");
    eqStr(full.files.lastObject.path, @"locales/zh-Hans.json", @"文件清单的顺序保持");
    eqInt((NSInteger)full.files.firstObject.size, 42, @"文件条目的大小");
    eqStr(full.locales[@"zh-Hans"], @"locales/zh-Hans.json", @"locales 的映射");

    // 3) 权限集规范串：按 id 排序 + id:risk
    NSString *want = @"download.source:medium\nlaunch.args:critical\nnetwork.http:medium";
    eqStr([full canonicalPermissionSet], want, @"权限集规范串按 id 排序并带风险级");

    // 4) 权限集与顺序无关（同一集合不同书写顺序 → 同一串）
    NSArray *shuffled = @[@"network.http", @"launch.args", @"download.source"];
    eqStr([A2PluginManifest canonicalPermissionSetForPermissions:shuffled], want,
          @"权限集规范串不受申请顺序影响");

    // 5) 风险级映射
    eqInt(A2PluginRiskForPermission(@"java.agent"), A2PluginRiskCritical,
          @"java.agent 是 critical");
    eqInt(A2PluginRiskForPermission(@"version.decorate"), A2PluginRiskLow,
          @"version.decorate 是 low");
    eqInt(A2PluginRiskForPermission(@"instance.guard"), A2PluginRiskMedium,
          @"instance.guard 是 medium");
    eqInt(A2PluginRiskForPermission(@"top.not.exists"), A2PluginRiskUnknown,
          @"目录外的权限 id 判 unknown");
    eqStr(A2PluginRiskName(A2PluginRiskCritical), @"critical", @"风险级字符串 critical");
    eqStr(A2PluginRiskName(A2PluginRiskUnknown), @"unknown", @"风险级字符串 unknown");

    // 6) hasPermission
    ok([full hasPermission:@"launch.args"], @"hasPermission 命中");
    ok(![full hasPermission:@"files.export"], @"hasPermission 未申请时为 NO");

    // 7) 标识 / 版本的边界
    ok(A2PluginIsValidIdentifier(@"top.example.hello"), @"id 合法：top.example.hello");
    ok(A2PluginIsValidIdentifier(@"a.b"), @"id 合法：两段最短形式");
    ok(!A2PluginIsValidIdentifier(@"hello"), @"id 非法：只有一段");
    ok(!A2PluginIsValidIdentifier(@"Top.Example"), @"id 非法：大写字母");
    ok(!A2PluginIsValidIdentifier(@"top..example"), @"id 非法：空段");
    ok(A2PluginIsValidVersion(@"1.0.0"), @"版本合法：1.0.0");
    ok(A2PluginIsValidVersion(@"1.0.0-beta.1"), @"版本合法：带预发布");
    ok(!A2PluginIsValidVersion(@"1.0"), @"版本非法：两段");
    ok(!A2PluginIsValidVersion(@"01.0.0"), @"版本非法：前导零");

    // 8) 包体量判定
    ok([minimal validatePackageEnvelopeWithBytes:1024 fileCount:0
                                          limits:A2PluginDefaultLimits() error:NULL],
       @"包体量与条目数在上限内时通过");
    NSError *sizeError = nil;
    BOOL tooBig = [minimal validatePackageEnvelopeWithBytes:(64ULL * 1024ULL * 1024ULL + 1)
                                                  fileCount:0
                                                     limits:A2PluginDefaultLimits()
                                                      error:&sizeError];
    ok(!tooBig, @"包体超过 64 MB 被拒");
    eqStr(ErrorCode(sizeError), @"E_SIZE", @"超包体给 E_SIZE");
    NSError *countError = nil;
    BOOL tooMany = [minimal validatePackageEnvelopeWithBytes:1024
                                                   fileCount:4097
                                                      limits:A2PluginDefaultLimits()
                                                       error:&countError];
    ok(!tooMany, @"文件数超过 4096 被拒");
    eqStr(ErrorCode(countError), @"E_SIZE", @"超文件数给 E_SIZE");

    // 默认上限必须就是 PLUGIN-SYSTEM 3.3 对外承诺的那三个数字（改这里=改承诺）
    A2PluginLimits docLimits = A2PluginDefaultLimits();
    ok(docLimits.maxPackageBytes == 64ULL * 1024ULL * 1024ULL,
       @"默认包体上限对齐 PLUGIN-SYSTEM 3.3：64 MB");
    eqInt((NSInteger)docLimits.maxFileCount, 4096,
          @"默认文件数上限对齐 PLUGIN-SYSTEM 3.3：4096");
    eqInt((NSInteger)docLimits.maxPathLength, 255,
          @"默认路径长度上限对齐 PLUGIN-SYSTEM 3.3：255 字节");
}

#pragma mark - manifest 反例

static void testManifestRejects(void) {
    // formatVersion
    NSMutableDictionary *m1 = MinimalManifest();
    m1[@"formatVersion"] = @1;
    expectReject(@"formatVersion 1 被拒", m1, @"E_FORMAT_VERSION");

    NSMutableDictionary *m2 = MinimalManifest();
    m2[@"formatVersion"] = @"2";
    expectReject(@"formatVersion 是字符串被拒", m2, @"E_FIELD");

    NSMutableDictionary *m3 = MinimalManifest();
    m3[@"formatVersion"] = @4;
    expectReject(@"formatVersion 4（更高版本）被拒", m3, @"E_FORMAT_VERSION");

    // 未知字段（additionalProperties: false）
    NSMutableDictionary *m4 = MinimalManifest();
    m4[@"permissons"] = @[@"launch.args"];   // 故意拼错
    expectReject(@"未知顶层字段被拒", m4, @"E_FIELD");

    // id / version / type
    NSMutableDictionary *m5 = MinimalManifest();
    m5[@"id"] = @"hello";
    expectReject(@"id 只有一段被拒", m5, @"E_FIELD");

    NSMutableDictionary *m6 = MinimalManifest();
    m6[@"version"] = @"1.0";
    expectReject(@"版本串 1.0 被拒", m6, @"E_FIELD");

    NSMutableDictionary *m7 = MinimalManifest();
    m7[@"type"] = @"native";
    expectReject(@"type native 被拒", m7, @"E_TYPE_UNSUPPORTED");

    // 未知权限 / 重复权限 / json 申请运行时权限
    NSMutableDictionary *m8 = MinimalManifest();
    m8[@"permissions"] = @[@"ui.something"];
    expectReject(@"未知权限 id 被拒", m8, @"E_PERM_UNKNOWN");

    NSMutableDictionary *m9 = MinimalManifest();
    m9[@"permissions"] = @[@"ui.contribute", @"ui.contribute"];
    expectReject(@"权限重复被拒", m9, @"E_FIELD");

    NSMutableDictionary *m10 = MinimalManifest();
    m10[@"permissions"] = @[@"launch.args"];   // json 型不许申请
    expectReject(@"json 插件申请 launch.args 被拒", m10, @"E_JSON_PERM");

    // 数组类型错
    NSMutableDictionary *m11 = MinimalManifest();
    m11[@"permissions"] = @"ui.contribute";
    expectReject(@"permissions 是字符串被拒", m11, @"E_FIELD");

    // 缺必填
    NSMutableDictionary *m12 = MinimalManifest();
    [m12 removeObjectForKey:@"name"];
    expectReject(@"缺 name 被拒", m12, @"E_FIELD");

    NSMutableDictionary *m13 = MinimalManifest();
    [m13 removeObjectForKey:@"platforms"];
    expectReject(@"缺 platforms 被拒", m13, @"E_FIELD");

    // 平台
    NSMutableDictionary *m14 = MinimalManifest();
    m14[@"platforms"] = @[@"android"];
    expectReject(@"platforms 不含 ios 被拒", m14, @"E_PLATFORM");

    NSMutableDictionary *m15 = MinimalManifest();
    m15[@"platforms"] = @[@"common"];
    expectReject(@"platforms 出现非法值 common 被拒", m15, @"E_FIELD");

    // 路径穿越
    NSMutableDictionary *m16 = MinimalManifest();
    m16[@"files"] = @[@{@"path": @"../escape.js",
                        @"sha256": @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                        @"size": @1}];
    expectReject(@"files 路径含 .. 被拒", m16, @"E_PATH");

    NSMutableDictionary *m17 = MinimalManifest();
    m17[@"type"] = @"js";
    m17[@"entry"] = @"/etc/passwd";
    expectReject(@"entry 是绝对路径被拒", m17, @"E_PATH");

    NSMutableDictionary *m18 = MinimalManifest();
    m18[@"type"] = @"js";
    m18[@"entry"] = @"sub\\entry.js";
    expectReject(@"entry 含反斜杠被拒", m18, @"E_PATH");

    // 尺寸
    A2PluginLimits tight = A2PluginDefaultLimits();
    tight.maxFileCount = 2;
    NSMutableDictionary *threeFiles = MinimalManifest();
    threeFiles[@"files"] = @[
        @{@"path": @"a.js", @"sha256": @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", @"size": @1},
        @{@"path": @"b.js", @"sha256": @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", @"size": @1},
        @{@"path": @"c.js", @"sha256": @"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", @"size": @1},
    ];
    NSError *filesError = nil;
    A2PluginManifest *tightResult = [A2PluginManifest manifestWithDictionary:threeFiles
                                                                      limits:tight
                                                                       error:&filesError];
    ok(tightResult == nil, @"文件数超过传入上限被拒");
    eqStr(ErrorCode(filesError), @"E_SIZE", @"超文件数给 E_SIZE");

    A2PluginLimits shortPath = A2PluginDefaultLimits();
    shortPath.maxPathLength = 5;
    NSMutableDictionary *longPath = MinimalManifest();
    longPath[@"files"] = @[@{@"path": @"assets/long-name.js",
                             @"sha256": @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                             @"size": @1}];
    NSError *pathError = nil;
    A2PluginManifest *pathResult = [A2PluginManifest manifestWithDictionary:longPath
                                                                     limits:shortPath
                                                                      error:&pathError];
    ok(pathResult == nil, @"路径长度超过传入上限被拒");
    eqStr(ErrorCode(pathError), @"E_SIZE", @"超路径长度给 E_SIZE");

    NSMutableDictionary *m20 = MinimalManifest();
    m20[@"files"] = @[@{@"path": @"big.bin",
                        @"sha256": @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                        @"size": @(33ULL * 1024ULL * 1024ULL)}];
    expectReject(@"单文件声明超过 32 MB 被拒", m20, @"E_SIZE");

    // 语言键
    NSMutableDictionary *m21 = MinimalManifest();
    m21[@"locales"] = @{@"zh_Hans": @"locales/zh_Hans.json"};
    expectReject(@"语言键用下划线被拒", m21, @"E_FIELD");

    // entry 与 type 的配套规则
    NSMutableDictionary *m22 = MinimalManifest();
    m22[@"type"] = @"js";
    expectReject(@"type 为 js 但没有 entry 被拒", m22, @"E_FIELD");

    NSMutableDictionary *m23 = MinimalManifest();
    m23[@"entry"] = @"entry.js";
    expectReject(@"type 为 json 却带 entry 被拒", m23, @"E_FIELD");

    // v2 不许用 v3 字段
    NSMutableDictionary *m24 = MinimalManifest();
    m24[@"ui"] = @{@"pages": @[]};
    expectReject(@"v2 包出现 ui.pages 被拒", m24, @"E_FORMAT_VERSION");

    NSMutableDictionary *m25 = MinimalManifest();
    m25[@"native"] = @{@"ios": @"native/ios/hello.dylib"};
    expectReject(@"v2 包出现 native 被拒", m25, @"E_FORMAT_VERSION");

    // 依赖
    NSMutableDictionary *m26 = MinimalManifest();
    m26[@"depends"] = @[@{@"id": @"top.example.core", @"version": @"1.0"}];
    expectReject(@"依赖版本约束 1.0 被拒", m26, @"E_FIELD");

    // 已移除的签名格式
    NSMutableDictionary *m27 = MinimalManifest();
    m27[@"files"] = @[@{@"path": @"AIR2SIG.json",
                        @"sha256": @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                        @"size": @1}];
    expectReject(@"包内出现 AIR2SIG.json 被拒", m27, @"E_LEGACY_SIGNATURE");

    // API 版本
    NSMutableDictionary *m28 = MinimalManifest();
    m28[@"air2"] = @{@"host": @{@"apiVersion": @2}};
    expectReject(@"apiVersion 2 被拒", m28, @"E_FIELD");

    // JSON 层
    expectRejectData(@"非法 JSON 文本被拒", JSONData(@"{ not json ]"), @"E_FORMAT");
    expectRejectData(@"根节点是数组被拒", JSONData(@"[]"), @"E_FORMAT");

    NSMutableData *bom = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
    [bom appendData:JSONData(@"{\"formatVersion\":2}")];
    expectRejectData(@"带 UTF-8 BOM 的 manifest 被拒", bom, @"E_FORMAT");
}

#pragma mark - registry 用例素材

static NSString *HashChar(char c) {
    NSMutableString *digest = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < 64; i++) {
        [digest appendFormat:@"%c", c];
    }
    return digest;
}

static NSString *TempDirectory(void) {
    NSString *directory = [NSTemporaryDirectory()
                           stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"a2plugin_%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return directory;
}

static A2PluginRegistryEntry *MakeEntry(NSString *pluginId, NSString *version) {
    A2PluginRegistryEntry *entry = [[A2PluginRegistryEntry alloc] init];
    entry.pluginId = pluginId;
    entry.version = version;
    entry.packageHash = [@"sha256:" stringByAppendingString:HashChar('a')];
    entry.sourceKind = @"local-import";
    entry.sourceDetail = @"hello.air2plugin";
    entry.sourceInstalledAt = @"2026-10-31T10:00:00Z";
    entry.permissionsGranted = @[@"version.decorate"];
    entry.permissionSet = @"launch.args:critical\nversion.decorate:low";
    entry.grantRevision = 2;
    entry.enabled = YES;
    entry.installedAt = @"2026-10-31T10:00:00Z";
    entry.updatedAt = @"2026-10-31T10:00:00Z";
    return entry;
}

static A2PluginCriticalGrant *MakeGrant(void) {
    A2PluginCriticalGrant *grant =
        [A2PluginCriticalGrant grantWithDictionary:@{
            @"permissionId": @"launch.args",
            @"grantedAt": @"2026-10-31T10:02:00Z",
            @"method": @"three-step",
            @"hostVersion": @"0.1.0",
            @"majorVersion": @1,
        }];
    return grant;
}

#pragma mark - registry 用例

static void testRegistry(void) {
    // 1) 首次加载：返回 YES、空表、且不建文件
    NSString *directory = TempDirectory();
    A2PluginRegistry *registry =
        [[A2PluginRegistry alloc] initWithPluginsDirectory:directory];
    eqStr(registry.pluginsDirectory, directory, @"注册表目录就是实例化时传入的目录");
    eqStr(registry.registryPath,
          [directory stringByAppendingPathComponent:@"registry.json"],
          @"registry.json 落在 Plugins 目录下");
    NSError *loadError = nil;
    ok([registry loadWithError:&loadError], @"第一次加载（没有文件）返回成功");
    eqInt((NSInteger)[registry allEntries].count, 0, @"空注册表没有条目");
    ok(![[NSFileManager defaultManager] fileExistsAtPath:registry.registryPath],
       @"空表加载不会凭空建出 registry.json");

    // 2) upsert → 落盘 → 重读一致
    A2PluginRegistryEntry *entry = MakeEntry(@"top.example.hello", @"1.0.0");
    [entry noteApprovedHash:HashChar('a')];
    entry.criticalGrants = @[MakeGrant()];
    NSError *upsertError = nil;
    ok([registry upsertEntry:entry error:&upsertError], @"upsert 一条成功");
    ok([[NSFileManager defaultManager] fileExistsAtPath:registry.registryPath],
       @"upsert 之后 registry.json 存在");
    eqInt(registry.seq, 1, @"第一次写之后 seq 为 1");

    A2PluginRegistry *reloaded =
        [[A2PluginRegistry alloc] initWithPluginsDirectory:directory];
    NSError *reloadError = nil;
    ok([reloaded loadWithError:&reloadError], @"重读成功");
    A2PluginRegistryEntry *restored = [reloaded entryForPluginId:@"top.example.hello"];
    ok(restored != nil, @"重读后能按 id 查到条目");
    eqStr(restored.version, @"1.0.0", @"重读后 version 一致");
    eqStr(restored.packageHash, [@"sha256:" stringByAppendingString:HashChar('a')],
          @"重读后 packageHash 一致");
    eqStr(restored.sourceKind, @"local-import", @"重读后 source.kind 一致");
    eqStr(restored.sourceDetail, @"hello.air2plugin", @"重读后 source.sourceDetail 一致");
    eqStr(restored.permissionsGranted.firstObject, @"version.decorate",
          @"重读后 permissionsGranted 一致");
    eqInt(restored.grantRevision, 2, @"重读后 grantRevision 一致");
    ok(restored.isEnabled, @"重读后 enabled 一致");
    eqStr(restored.permissionSet, @"launch.args:critical\nversion.decorate:low",
          @"重读后 permissionSet 里的换行与内容一致");
    eqStr(restored.criticalGrants.firstObject.permissionId, @"launch.args",
          @"重读后 criticalGrants 的 permissionId 一致");
    eqStr(restored.criticalGrants.firstObject.method, @"three-step",
          @"重读后 criticalGrants 的 method 一致");
    eqInt(restored.criticalGrants.firstObject.majorVersion, 1,
          @"重读后 criticalGrants 的 majorVersion 一致");
    // approvedHashes 存的是**规范化后**的主体（去 `sha256:` 前缀、小写），
    // 与 noteApprovedHash: 的判重口径一致；packageHash 才带前缀。
    eqStr(restored.approvedHashes.firstObject,
          HashChar('a'),
          @"重读后 approvedHashes 一致");

    // 3) 再写一次 seq 继续递增
    NSError *secondError = nil;
    ok([registry upsertEntry:MakeEntry(@"top.example.other", @"0.1.0") error:&secondError],
       @"upsert 第二条成功");
    eqInt(registry.seq, 2, @"第二次写之后 seq 为 2");
    eqInt((NSInteger)[registry allEntries].count, 2, @"两条条目");
    eqStr([registry allEntries].firstObject.pluginId, @"top.example.hello",
          @"allEntries 按 pluginId 升序");

    // 4) approvedHashes：最多 5 个、新值在前、最旧淘汰
    A2PluginRegistryEntry *trim = MakeEntry(@"top.example.trim", @"1.0.0");
    ok([trim noteApprovedHash:HashChar('a')], @"记第 1 个哈希成功");
    ok([trim noteApprovedHash:HashChar('b')], @"记第 2 个哈希成功");
    ok([trim noteApprovedHash:HashChar('c')], @"记第 3 个哈希成功");
    ok([trim noteApprovedHash:HashChar('d')], @"记第 4 个哈希成功");
    ok([trim noteApprovedHash:HashChar('e')], @"记第 5 个哈希成功");
    eqInt((NSInteger)trim.approvedHashes.count, 5, @"5 个哈希都留着");
    ok([trim noteApprovedHash:HashChar('f')], @"记第 6 个哈希成功");
    eqInt((NSInteger)trim.approvedHashes.count, 5, @"第 6 个哈希到来时总数仍是 5");
    ok([trim.approvedHashes.firstObject hasSuffix:HashChar('f')], @"最新的哈希排在第一位");
    BOOL oldestGone = YES;
    for (NSString *hash in trim.approvedHashes) {
        if ([hash hasSuffix:HashChar('a')]) oldestGone = NO;
    }
    ok(oldestGone, @"最旧的哈希确实被丢掉了");

    // 5) approvedHashes 去重：同一个哈希再记一次，只挪到最前、不重复
    ok([trim noteApprovedHash:HashChar('c')], @"重复记同一个哈希成功");
    eqInt((NSInteger)trim.approvedHashes.count, 5, @"重复记不增加条目");
    ok([trim.approvedHashes.firstObject hasSuffix:HashChar('c')], @"重复记会把该哈希挪到最前");
    NSUInteger cCount = 0;
    for (NSString *hash in trim.approvedHashes) {
        if ([hash hasSuffix:HashChar('c')]) cCount++;
    }
    eqInt((NSInteger)cCount, 1, @"同一个哈希只出现一次");

    // 6) 非法哈希被拒
    ok(![trim noteApprovedHash:@"not-a-hash"], @"非法哈希不被接受");
    ok(![trim noteApprovedHash:HashChar('A')], @"大写 hex 不被接受（要求小写）");

    // 7) 条目校验：source.kind 不在枚举内 → 拒写且不落盘
    NSString *invalidDirectory = TempDirectory();
    A2PluginRegistry *invalidRegistry =
        [[A2PluginRegistry alloc] initWithPluginsDirectory:invalidDirectory];
    (void)[invalidRegistry loadWithError:NULL];
    A2PluginRegistryEntry *badEntry = MakeEntry(@"top.example.bad", @"1.0.0");
    badEntry.sourceKind = @"unknown-kind";
    NSError *badError = nil;
    ok(![invalidRegistry upsertEntry:badEntry error:&badError],
       @"source.kind 不在枚举内时拒写");
    eqInt(badError.code, A2PluginRegistryErrorInvalidEntry, @"拒写的错误码是 InvalidEntry");
    ok(![[NSFileManager defaultManager] fileExistsAtPath:invalidRegistry.registryPath],
       @"拒写之后没有落盘（不存在半成品文件）");

    // 8) 损坏的 registry.json：load 失败且**原文件一个字节都不动**
    NSString *corruptDirectory = TempDirectory();
    A2PluginRegistry *corruptRegistry =
        [[A2PluginRegistry alloc] initWithPluginsDirectory:corruptDirectory];
    NSData *garbage = JSONData(@"{ \"plugins\": [ /* 半截 */ ");
    [garbage writeToFile:corruptRegistry.registryPath atomically:YES];
    NSError *corruptError = nil;
    ok(![corruptRegistry loadWithError:&corruptError], @"损坏的 registry.json 读取失败");
    eqInt(corruptError.code, A2PluginRegistryErrorFormat, @"损坏文件的错误码是 Format");
    NSData *afterCorrupt = [NSData dataWithContentsOfFile:corruptRegistry.registryPath];
    ok([afterCorrupt isEqualToData:garbage], @"读失败不会覆写原文件");

    // 9) 删除条目并落盘
    NSError *removeError = nil;
    ok([registry removeEntryForPluginId:@"top.example.other" error:&removeError],
       @"删除条目成功");
    A2PluginRegistry *afterRemove =
        [[A2PluginRegistry alloc] initWithPluginsDirectory:directory];
    ok([afterRemove loadWithError:NULL], @"删除后重读成功");
    eqInt((NSInteger)[afterRemove allEntries].count, 1, @"删除后只剩一条");
    ok([afterRemove entryForPluginId:@"top.example.other"] == nil,
       @"被删除的条目查不到");

    // 10) 原子写不留临时文件
    NSArray<NSString *> *leftovers =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL];
    BOOL hasTemp = NO;
    for (NSString *name in leftovers) {
        if ([name hasSuffix:@".tmp"]) hasTemp = YES;
    }
    ok(!hasTemp, @"原子写完成后目录里没有 .tmp 残留");

    // 11) 读回时保留 userSeq（宿主自动禁用不动 userSeq，崩溃归因靠它）
    NSString *seqDirectory = TempDirectory();
    A2PluginRegistry *seqRegistry =
        [[A2PluginRegistry alloc] initWithPluginsDirectory:seqDirectory];
    NSData *seqJSON = JSONData(@"{\"formatVersion\":3,\"seq\":128,\"userSeq\":41,\"plugins\":[]}");
    [seqJSON writeToFile:seqRegistry.registryPath atomically:YES];
    ok([seqRegistry loadWithError:NULL], @"带 seq/userSeq 的注册表能读");
    eqInt(seqRegistry.seq, 128, @"seq 读回来了");
    eqInt(seqRegistry.userSeq, 41, @"userSeq 读回来了");

    // 12) 结构版本不符 → 拒绝（迁移不在本层做）
    NSString *versionDirectory = TempDirectory();
    A2PluginRegistry *versionRegistry =
        [[A2PluginRegistry alloc] initWithPluginsDirectory:versionDirectory];
    NSData *v2JSON = JSONData(@"{\"formatVersion\":2,\"seq\":1,\"plugins\":[]}");
    [v2JSON writeToFile:versionRegistry.registryPath atomically:YES];
    NSError *versionError = nil;
    ok(![versionRegistry loadWithError:&versionError], @"旧结构版本的注册表被拒");
    eqInt(versionError.code, A2PluginRegistryErrorFormat, @"版本不符给 Format");
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        testManifestAccepts();
        testManifestRejects();
        testRegistry();

        printf("\n---- %d passed, %d failed ----\n", gPass, gFail);
    }
    return gFail == 0 ? 0 : 1;
}
