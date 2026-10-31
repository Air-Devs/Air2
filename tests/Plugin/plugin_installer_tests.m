//
//  plugin_installer_tests.m
//  Air2 —— tests/Plugin：★插件安装器单测（原子安装 / 卸载 / 回退 / zip 安全）★
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（直接链接真实实现，不是文本镜像）：
//    Air2/Core/Plugin/A2PluginInstaller.m          ← 安装 / 卸载 / 回退 / 版本规则
//    Air2/Core/Plugin/A2PluginPackageExtractor.m   ← 中央目录预检 / 解压 / 完整性 / 摘要
//    Air2/Core/Addons/A2ZipReader.m                ← 条目元数据 / 流式解压 / 本地头核对
//
//  为什么要有它：
//    「拒装」的每一条理由都必须是可执行的绿或红。zip 炸弹、穿越条目、符号链接、
//    同版本换包、降级，这些不是文档里的修辞 —— 下面每一条都用真实 zip 字节喂一遍。
//    能构造出来的攻击包必须真的被拒，且磁盘上不留痕迹。
//
//  运行：python3 tests/Plugin/run_plugin_tests.py   （需 macOS + clang；Windows 无 clang 属预期）
//

#import <Foundation/Foundation.h>

#import <CommonCrypto/CommonDigest.h>
#import <zlib.h>

#import "A2PluginInstaller.h"
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

static NSString *ErrorCode(NSError *error) {
    return error.userInfo[A2PluginErrorCodeKey] ?: @"(无码)";
}

/// 反例：期望被拒，且错误码对得上。
static void expectReject(NSString *what, NSError *error, NSString *expectedCode) {
    if (!error) {
        ok(NO, [NSString stringWithFormat:@"%@（应当拒装，但安装成功了）", what]);
        return;
    }
    ok([ErrorCode(error) isEqualToString:expectedCode],
       [NSString stringWithFormat:@"%@（得到 %@，期望 %@；原因：%@）",
        what, ErrorCode(error), expectedCode, error.localizedDescription]);
}

#pragma mark - 摘要工具

static NSString *SHA256Hex(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

#pragma mark - zip 构造器

/// 一条待写入的测试条目。
/// 故意保留「随便什么名字 + 随便什么外部属性」的能力 —— 攻击包就是这么造出来的。
@interface TestZipEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSData *payload;
@property (nonatomic, assign) uint32_t externalAttributes;
@property (nonatomic, assign) uint16_t versionMadeBy;
@end

@implementation TestZipEntry
@end

static void AppendU16(NSMutableData *out, uint16_t value) {
    uint8_t bytes[2] = {(uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF)};
    [out appendBytes:bytes length:2];
}

static void AppendU32(NSMutableData *out, uint32_t value) {
    uint8_t bytes[4] = {(uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF),
                        (uint8_t)((value >> 16) & 0xFF), (uint8_t)((value >> 24) & 0xFF)};
    [out appendBytes:bytes length:4];
}

/// 构造 zip（只用 stored）。
/// 不压缩是刻意的：这些用例要证明的是「校验与路径规则挡住了什么」，
/// 压缩流是否正确由 tests/Core/test_zip_reader.py 另测。
static NSData *BuildZip(NSArray<TestZipEntry *> *entries) {
    NSMutableData *out = [NSMutableData data];
    NSMutableData *central = [NSMutableData data];
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];

    for (TestZipEntry *entry in entries) {
        NSData *name = [entry.name dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t offset = (uint32_t)out.length;
        [offsets addObject:@(offset)];
        uint32_t crc = (uint32_t)crc32(0, entry.payload.bytes, (uInt)entry.payload.length);

        AppendU32(out, 0x04034b50);              // 本地文件头签名
        AppendU16(out, 20);                      // 解压所需版本
        AppendU16(out, 0x0800);                  // 标志位：UTF-8 文件名
        AppendU16(out, 0);                       // 方法：stored
        AppendU16(out, 0);                       // 修改时间
        AppendU16(out, 0);                       // 修改日期
        AppendU32(out, crc);
        AppendU32(out, (uint32_t)entry.payload.length);
        AppendU32(out, (uint32_t)entry.payload.length);
        AppendU16(out, (uint16_t)name.length);
        AppendU16(out, 0);
        [out appendData:name];
        [out appendData:entry.payload];
    }

    uint32_t centralOffset = (uint32_t)out.length;
    for (NSUInteger i = 0; i < entries.count; i++) {
        TestZipEntry *entry = entries[i];
        NSData *name = [entry.name dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t crc = (uint32_t)crc32(0, entry.payload.bytes, (uInt)entry.payload.length);

        AppendU32(central, 0x02014b50);          // 中央目录签名
        AppendU16(central, entry.versionMadeBy); // 生成主机（高字节 3 = Unix）
        AppendU16(central, 20);
        AppendU16(central, 0x0800);
        AppendU16(central, 0);
        AppendU16(central, 0);
        AppendU16(central, 0);
        AppendU32(central, crc);
        AppendU32(central, (uint32_t)entry.payload.length);
        AppendU32(central, (uint32_t)entry.payload.length);
        AppendU16(central, (uint16_t)name.length);
        AppendU16(central, 0);                   // extra
        AppendU16(central, 0);                   // comment
        AppendU16(central, 0);                   // 起始磁盘
        AppendU16(central, 0);                   // 内部属性
        AppendU32(central, entry.externalAttributes);
        AppendU32(central, offsets[i].unsignedIntValue);
        [central appendData:name];
    }

    [out appendData:central];
    AppendU32(out, 0x06054b50);                  // EOCD
    AppendU16(out, 0);
    AppendU16(out, 0);
    AppendU16(out, (uint16_t)entries.count);
    AppendU16(out, (uint16_t)entries.count);
    AppendU32(out, (uint32_t)central.length);
    AppendU32(out, centralOffset);
    AppendU16(out, 0);
    return out;
}

/// Unix 常规文件（0100644）与符号链接（0120777）的外部属性。
static const uint32_t kUnixRegularFileMode = 0100644u << 16;
static const uint32_t kUnixSymlinkMode = 0120777u << 16;
/// versionMadeBy 高字节 3 = Unix
static const uint16_t kMadeByUnix = 3u << 8 | 20u;

static TestZipEntry *ZipEntry(NSString *name, NSData *payload) {
    TestZipEntry *entry = [TestZipEntry new];
    entry.name = name;
    entry.payload = payload ?: [NSData data];
    entry.externalAttributes = kUnixRegularFileMode;
    entry.versionMadeBy = kMadeByUnix;
    return entry;
}

static NSData *UTF8(NSString *string) {
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - manifest / 包 构造器

/// 一份最小 manifest（type: json），files 由正文生成。
static NSMutableDictionary *PluginManifest(NSString *pluginId, NSString *version) {
    return [@{
        @"formatVersion": @2,
        @"id": pluginId,
        @"name": @"测试插件",
        @"version": version,
        @"type": @"json",
        @"air2": @{@"host": @{@"apiVersion": @1}},
        @"platforms": @[@"ios"],
        @"files": @[],
    } mutableCopy];
}

/// 把「包内路径 → 内容」写进 manifest.files（真实哈希与字节数）。
static void DeclareFiles(NSMutableDictionary *manifest, NSDictionary<NSString *, NSData *> *files) {
    NSArray<NSString *> *paths = [[files allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSDictionary *> *declared = [NSMutableArray array];
    for (NSString *path in paths) {
        NSData *data = files[path];
        [declared addObject:@{@"path": path,
                              @"sha256": SHA256Hex(data),
                              @"size": @(data.length)}];
    }
    manifest[@"files"] = declared;
}

static NSData *ManifestData(NSDictionary *manifest) {
    return [NSJSONSerialization dataWithJSONObject:manifest options:0 error:NULL];
}

/// 拼一个完整包：manifest.json + 声明的文件。
static NSData *Package(NSDictionary *manifest, NSDictionary<NSString *, NSData *> *files) {
    NSMutableArray<TestZipEntry *> *entries = [NSMutableArray array];
    [entries addObject:ZipEntry(@"manifest.json", ManifestData(manifest))];
    NSArray<NSString *> *paths = [[files allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *path in paths) {
        [entries addObject:ZipEntry(path, files[path])];
    }
    return BuildZip(entries);
}

#pragma mark - 环境

static NSString *TempDirectory(void) {
    NSString *directory = [NSTemporaryDirectory()
                           stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"a2plugin_install_%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return directory;
}

/// 日志收集器：安装器的每个关键步骤都该有一行，且都带统一前缀。
static NSMutableArray<NSString *> *gLogLines = nil;

static A2PluginInstaller *MakeInstaller(NSString *pluginsDirectory,
                                        A2PluginRegistry **outRegistry) {
    A2PluginRegistry *registry =
        [[A2PluginRegistry alloc] initWithPluginsDirectory:pluginsDirectory];
    [registry loadWithError:NULL];

    A2PluginInstaller *installer = [[A2PluginInstaller alloc] initWithRegistry:registry];
    if (outRegistry) *outRegistry = registry;

    if (!gLogLines) gLogLines = [NSMutableArray array];
    installer.logSink = ^(NSString *line) {
        [gLogLines addObject:line];
    };
    return installer;
}

static A2PluginInstallSource *LocalSource(void) {
    return [A2PluginInstallSource sourceWithKind:@"local-import"
                                         detail:@"hello.air2plugin"
                                    installedAt:@"2026-10-31T10:00:00Z"];
}

/// 把包写成临时文件并返回 file URL。
static NSURL *WritePackage(NSData *packageData, NSString *fileName) {
    NSString *directory = TempDirectory();
    NSString *path = [directory stringByAppendingPathComponent:fileName];
    [packageData writeToFile:path atomically:YES];
    return [NSURL fileURLWithPath:path];
}

static BOOL FileExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

/// 目录里除了给定名字之外还有没有别的东西（用来断言「失败时磁盘无残留」）。
static BOOL DirectoryContainsOnly(NSString *directory, NSSet<NSString *> *allowed) {
    NSArray<NSString *> *names = [[NSFileManager defaultManager]
                                  contentsOfDirectoryAtPath:directory error:NULL];
    for (NSString *name in names) {
        if (![allowed containsObject:name]) return NO;
    }
    return YES;
}

#pragma mark - 用例：安装成功

static void testInstallSuccess(void) {
    NSString *plugins = TempDirectory();
    A2PluginRegistry *registry = nil;
    A2PluginInstaller *installer = MakeInstaller(plugins, &registry);
    [gLogLines removeAllObjects];

    NSDictionary<NSString *, NSData *> *files = @{
        @"ui/home.json": UTF8(@"{\"slot\":\"home.toolbar.action\"}"),
        @"locales/zh-Hans.json": UTF8(@"{\"hello\":\"你好\"}"),
    };
    NSMutableDictionary *manifest = PluginManifest(@"top.example.hello", @"1.0.0");
    DeclareFiles(manifest, files);
    NSURL *url = WritePackage(Package(manifest, files), @"hello.air2plugin");

    NSError *error = nil;
    A2PluginInstallResult *result = [installer installPackageAtURL:url source:LocalSource() error:&error];
    ok(result != nil, [NSString stringWithFormat:@"好包安装成功（错误：%@）",
                       error.localizedDescription ?: @"无"]);
    ok(!result.reusedExisting, @"首次安装不是幂等重装");
    eqInt((NSInteger)result.contentHash.length, 64, @"内容摘要是 64 位 hex");

    NSString *activeDirectory = [[plugins stringByAppendingPathComponent:@"top.example.hello"]
                                 stringByAppendingPathComponent:@"1.0.0"];
    ok(FileExists([activeDirectory stringByAppendingPathComponent:@"manifest.json"]),
       @"插件目录落在 <Plugins>/<id>/<version>/，manifest.json 在里面");
    ok(FileExists([activeDirectory stringByAppendingPathComponent:@"ui/home.json"]),
       @"声明的文件都解压出来了");

    A2PluginRegistryEntry *entry = [registry entryForPluginId:@"top.example.hello"];
    ok(entry != nil, @"注册表里有条目");
    eqStr(entry.version, @"1.0.0", @"注册表版本正确");
    eqStr(entry.sourceKind, @"local-import", @"来源种类落盘");
    eqStr(entry.sourceDetail, @"hello.air2plugin", @"来源细节落盘");
    eqStr(entry.sourceInstalledAt, @"2026-10-31T10:00:00Z", @"来源安装时间落盘");
    eqStr(entry.packageHash,
          [@"sha256:" stringByAppendingString:result.contentHash],
          @"注册表哈希是 sha256:<内容摘要>");
    ok(entry.installedAt.length > 0, @"首次安装时间已写");

    ok(DirectoryContainsOnly([plugins stringByAppendingPathComponent:@".staging"], [NSSet set]),
       @"安装成功后 .staging 里没有残留");

    BOOL sawPrefix = YES;
    BOOL sawInstallStart = NO;
    for (NSString *line in gLogLines) {
        if (![line hasPrefix:@"[A2-PLUGIN] "]) sawPrefix = NO;
        if ([line rangeOfString:@"安装开始"].location != NSNotFound) sawInstallStart = YES;
    }
    ok(gLogLines.count >= 4, @"关键步骤各写了一行日志（开始 / 校验 / 换目录 / 注册表）");
    ok(sawPrefix, @"日志行统一带 [A2-PLUGIN] 前缀");
    ok(sawInstallStart, @"安装开始有一行日志");
}

#pragma mark - 用例：幂等 / 同版本换包 / 降级

static void testVersionRules(void) {
    NSString *plugins = TempDirectory();
    A2PluginRegistry *registry = nil;
    A2PluginInstaller *installer = MakeInstaller(plugins, &registry);

    NSDictionary<NSString *, NSData *> *files = @{@"ui/a.json": UTF8(@"{\"a\":1}")};
    NSMutableDictionary *manifest = PluginManifest(@"top.example.rules", @"1.0.0");
    DeclareFiles(manifest, files);
    NSData *v1Package = Package(manifest, files);
    NSURL *v1 = WritePackage(v1Package, @"v1.air2plugin");

    NSError *error = nil;
    ok([installer installPackageAtURL:v1 source:LocalSource() error:&error] != nil,
       @"1.0.0 安装成功");

    // 同 id 同版本同内容 → 幂等
    A2PluginInstallResult *reused = [installer installPackageAtURL:v1 source:LocalSource() error:&error];
    ok(reused != nil && reused.reusedExisting,
       @"同版本同内容重装视为幂等成功（不重新弹授权、不动磁盘）");

    // 同 id 同版本不同内容 → 拒装
    NSDictionary<NSString *, NSData *> *tampered = @{@"ui/a.json": UTF8(@"{\"a\":2}")};
    NSMutableDictionary *tamperedManifest = PluginManifest(@"top.example.rules", @"1.0.0");
    DeclareFiles(tamperedManifest, tampered);
    NSURL *tamperedURL = WritePackage(Package(tamperedManifest, tampered), @"v1-b.air2plugin");
    error = nil;
    A2PluginInstallResult *tamperedResult =
        [installer installPackageAtURL:tamperedURL source:LocalSource() error:&error];
    ok(tamperedResult == nil, @"同版本不同内容被拒");
    expectReject(@"同版本不同内容给 E_SAME_VERSION_DIFFERENT_CONTENT",
                 error, @"E_SAME_VERSION_DIFFERENT_CONTENT");

    // 升级到 2.0.0
    NSMutableDictionary *manifest2 = PluginManifest(@"top.example.rules", @"2.0.0");
    DeclareFiles(manifest2, files);
    NSURL *v2 = WritePackage(Package(manifest2, files), @"v2.air2plugin");
    error = nil;
    ok([installer installPackageAtURL:v2 source:LocalSource() error:&error] != nil,
       @"2.0.0 升级安装成功");

    // 降级 → 拒装
    NSMutableDictionary *manifest3 = PluginManifest(@"top.example.rules", @"1.5.0");
    DeclareFiles(manifest3, files);
    NSURL *v15 = WritePackage(Package(manifest3, files), @"v15.air2plugin");
    error = nil;
    ok([installer installPackageAtURL:v15 source:LocalSource() error:&error] == nil,
       @"降级安装被拒");
    expectReject(@"降级给 E_DOWNGRADE", error, @"E_DOWNGRADE");

    // 开发者模式放行
    installer.allowsDowngrade = YES;
    error = nil;
    A2PluginInstallResult *downgraded =
        [installer installPackageAtURL:v15 source:LocalSource() error:&error];
    ok(downgraded != nil, [NSString stringWithFormat:@"开发者模式允许降级安装（错误：%@）",
                           error.localizedDescription ?: @"无"]);
    eqStr([registry entryForPluginId:@"top.example.rules"].version, @"1.5.0",
          @"降级后注册表指向 1.5.0");
    installer.allowsDowngrade = NO;

    // 语义化版本比较：1.10.0 > 1.9.0（字符串比大小会判反）
    ok(A2PluginCompareVersions(@"1.10.0", @"1.9.0") > 0, @"1.10.0 比 1.9.0 新（按数值比，不是按字符串）");
    ok(A2PluginCompareVersions(@"1.0.0-beta", @"1.0.0") < 0, @"预发布版小于正式版");
    ok(A2PluginCompareVersions(@"1.0.0", @"1.0.0") == 0, @"同版本比较为 0");
}

#pragma mark - 用例：卸载

static void testUninstall(void) {
    NSString *plugins = TempDirectory();
    A2PluginRegistry *registry = nil;
    A2PluginInstaller *installer = MakeInstaller(plugins, &registry);

    NSDictionary<NSString *, NSData *> *files = @{@"ui/a.json": UTF8(@"{\"a\":1}")};
    NSMutableDictionary *manifest = PluginManifest(@"top.example.bye", @"1.0.0");
    DeclareFiles(manifest, files);
    NSURL *url = WritePackage(Package(manifest, files), @"bye.air2plugin");

    NSError *error = nil;
    ok([installer installPackageAtURL:url source:LocalSource() error:&error] != nil, @"装上去");
    NSString *pluginDirectory = [plugins stringByAppendingPathComponent:@"top.example.bye"];
    ok(FileExists(pluginDirectory), @"插件目录存在");

    ok([installer uninstallPluginId:@"top.example.bye" error:&error], @"卸载成功");
    ok(!FileExists(pluginDirectory), @"卸载后目录不在了");
    ok([registry entryForPluginId:@"top.example.bye"] == nil, @"卸载后注册表条目也没了");

    ok([installer uninstallPluginId:@"top.example.bye" error:&error], @"重复卸载是幂等的");

    // 内置插件不可卸
    ok([installer installPackageAtURL:url source:LocalSource() error:&error] != nil, @"再装一次");
    installer.builtinPluginIds = [NSSet setWithObject:@"top.example.bye"];
    error = nil;
    ok(![installer uninstallPluginId:@"top.example.bye" error:&error], @"内置插件卸载被拒");
    expectReject(@"内置插件给 E_BUILTIN", error, @"E_BUILTIN");
    ok(FileExists(pluginDirectory), @"被拒后目录还在");
    installer.builtinPluginIds = [NSSet set];
}

#pragma mark - 用例：回退

static void testRollback(void) {
    NSString *plugins = TempDirectory();
    A2PluginRegistry *registry = nil;
    A2PluginInstaller *installer = MakeInstaller(plugins, &registry);
    [gLogLines removeAllObjects];

    NSDictionary<NSString *, NSData *> *files = @{@"ui/a.json": UTF8(@"{\"a\":1}")};
    NSMutableDictionary *manifest1 = PluginManifest(@"top.example.roll", @"1.0.0");
    DeclareFiles(manifest1, files);
    NSURL *v1 = WritePackage(Package(manifest1, files), @"roll-v1.air2plugin");

    NSMutableDictionary *manifest2 = PluginManifest(@"top.example.roll", @"2.0.0");
    DeclareFiles(manifest2, files);
    NSURL *v2 = WritePackage(Package(manifest2, files), @"roll-v2.air2plugin");

    NSError *error = nil;
    ok([installer installPackageAtURL:v1 source:LocalSource() error:&error] != nil, @"装 1.0.0");
    ok([installer installPackageAtURL:v2 source:LocalSource() error:&error] != nil, @"升到 2.0.0");

    NSString *packages = [plugins stringByAppendingPathComponent:@"packages"];
    NSArray<NSString *> *retained = [[NSFileManager defaultManager]
                                     contentsOfDirectoryAtPath:packages error:NULL];
    ok(retained.count >= 1, @"升级后上一版被保留到 packages/");
    if (retained.count >= 1) {
        ok([retained.firstObject hasPrefix:@"top.example.roll@"],
           @"保留版目录名是 <id>@<hash>");
    }

    ok([installer rollbackPluginId:@"top.example.roll" error:&error],
       [NSString stringWithFormat:@"回退成功（错误：%@）", error.localizedDescription ?: @"无"]);
    eqStr([registry entryForPluginId:@"top.example.roll"].version, @"1.0.0",
          @"回退后注册表版本变回上一版");
    ok(FileExists([[plugins stringByAppendingPathComponent:@"top.example.roll"]
                   stringByAppendingPathComponent:@"1.0.0"]),
       @"回退后 1.0.0 目录就位");
    ok(!FileExists([[plugins stringByAppendingPathComponent:@"top.example.roll"]
                    stringByAppendingPathComponent:@"2.0.0"]),
       @"回退后 2.0.0 目录已收走（同一时刻只有一个激活版本）");

    // 回退一次之后，保留版里放的是刚被换下来的 2.0.0 —— 再回退就是 2.0.0
    ok([installer rollbackPluginId:@"top.example.roll" error:&error],
       @"可以再回退一次（保留版里是 2.0.0）");
    eqStr([registry entryForPluginId:@"top.example.roll"].version, @"2.0.0",
          @"第二次回退回到 2.0.0");

    // 没装过的插件回退
    error = nil;
    ok(![installer rollbackPluginId:@"top.example.nothing" error:&error], @"未安装的插件回退被拒");
    expectReject(@"没有上一版给 E_NO_PREVIOUS", error, @"E_NO_PREVIOUS");

    BOOL sawRollback = NO;
    for (NSString *line in gLogLines) {
        if ([line rangeOfString:@"回退完成"].location != NSNotFound) sawRollback = YES;
    }
    ok(sawRollback, @"回退完成有一行日志");
}

#pragma mark - 用例：zip 安全

static void testZipSafety(void) {
    NSString *plugins = TempDirectory();
    A2PluginInstaller *installer = MakeInstaller(plugins, NULL);

    NSDictionary<NSString *, NSData *> *files = @{@"ui/a.json": UTF8(@"{\"a\":1}")};
    NSMutableDictionary *manifest = PluginManifest(@"top.example.safe", @"1.0.0");
    DeclareFiles(manifest, files);

    // zip-slip：条目名往上跑
    NSMutableArray<TestZipEntry *> *slipEntries = [NSMutableArray array];
    [slipEntries addObject:ZipEntry(@"manifest.json", ManifestData(manifest))];
    [slipEntries addObject:ZipEntry(@"../evil.txt", UTF8(@"escaped"))];
    NSURL *slipURL = WritePackage(BuildZip(slipEntries), @"slip.air2plugin");

    NSError *error = nil;
    ok([installer installPackageAtURL:slipURL source:LocalSource() error:&error] == nil,
       @"zip-slip 包被拒");
    expectReject(@"zip-slip 给 E_ZIP_SLIP", error, @"E_ZIP_SLIP");
    ok(!FileExists([plugins.stringByDeletingLastPathComponent
                    stringByAppendingPathComponent:@"evil.txt"]),
       @"被拒的包没有在包目录之外写出文件");
    ok(!FileExists([plugins stringByAppendingPathComponent:@"top.example.safe"]),
       @"被拒的包没有留下插件目录");

    // 符号链接：外部属性标成 S_IFLNK
    NSMutableArray<TestZipEntry *> *linkEntries = [NSMutableArray array];
    [linkEntries addObject:ZipEntry(@"manifest.json", ManifestData(manifest))];
    TestZipEntry *link = ZipEntry(@"ui/link", UTF8(@"/etc/passwd"));
    link.externalAttributes = kUnixSymlinkMode;
    [linkEntries addObject:link];
    NSURL *linkURL = WritePackage(BuildZip(linkEntries), @"link.air2plugin");

    error = nil;
    ok([installer installPackageAtURL:linkURL source:LocalSource() error:&error] == nil,
       @"符号链接包被拒");
    expectReject(@"符号链接给 E_LINK", error, @"E_LINK");

    // 文件数超上限（默认 4096）
    NSMutableArray<TestZipEntry *> *manyEntries = [NSMutableArray array];
    [manyEntries addObject:ZipEntry(@"manifest.json", ManifestData(manifest))];
    for (NSUInteger i = 0; i < 4097; i++) {
        [manyEntries addObject:ZipEntry([NSString stringWithFormat:@"assets/f%04lu.txt",
                                         (unsigned long)i], UTF8(@"x"))];
    }
    NSURL *manyURL = WritePackage(BuildZip(manyEntries), @"many.air2plugin");
    error = nil;
    ok([installer installPackageAtURL:manyURL source:LocalSource() error:&error] == nil,
       @"文件数超过 4096 被拒");
    expectReject(@"超文件数给 E_SIZE", error, @"E_SIZE");
    ok(!FileExists([plugins stringByAppendingPathComponent:@"top.example.safe"]),
       @"超文件数的包一个字节都没落地");

    // 包体超上限：把上限调到 1 KB 来跑同一条规则（64 MB 的包没必要真造一个）
    A2PluginInstaller *smallLimitInstaller = MakeInstaller(plugins, NULL);
    A2PluginLimits limits = A2PluginDefaultLimits();
    limits.maxPackageBytes = 1024;
    smallLimitInstaller.limits = limits;
    NSMutableData *bigPayload = [NSMutableData dataWithLength:4096];
    NSDictionary<NSString *, NSData *> *bigFiles = @{@"ui/big.bin": bigPayload};
    NSMutableDictionary *bigManifest = PluginManifest(@"top.example.big", @"1.0.0");
    DeclareFiles(bigManifest, bigFiles);
    NSURL *bigURL = WritePackage(Package(bigManifest, bigFiles), @"big.air2plugin");

    error = nil;
    ok([smallLimitInstaller installPackageAtURL:bigURL source:LocalSource() error:&error] == nil,
       @"包体超过上限被拒");
    expectReject(@"超包体给 E_SIZE", error, @"E_SIZE");

    // 单文件超上限：同样用调小的上限验证规则本身
    A2PluginInstaller *singleLimitInstaller = MakeInstaller(plugins, NULL);
    A2PluginLimits singleLimits = A2PluginDefaultLimits();
    singleLimits.maxSingleFileBytes = 512;
    singleLimitInstaller.limits = singleLimits;
    NSDictionary<NSString *, NSData *> *fatFiles = @{@"ui/fat.bin": [NSMutableData dataWithLength:2048]};
    NSMutableDictionary *fatManifest = PluginManifest(@"top.example.fat", @"1.0.0");
    DeclareFiles(fatManifest, fatFiles);
    NSURL *fatURL = WritePackage(Package(fatManifest, fatFiles), @"fat.air2plugin");

    error = nil;
    ok([singleLimitInstaller installPackageAtURL:fatURL source:LocalSource() error:&error] == nil,
       @"单文件解压后超过上限被拒");
    expectReject(@"超单文件给 E_SIZE", error, @"E_SIZE");
}

#pragma mark - 用例：完整性与宿主能力门

static void testIntegrityAndHostGate(void) {
    NSString *plugins = TempDirectory();
    A2PluginInstaller *installer = MakeInstaller(plugins, NULL);

    // 清单写的哈希与实际内容不符
    NSDictionary<NSString *, NSData *> *files = @{@"ui/a.json": UTF8(@"{\"a\":1}")};
    NSMutableDictionary *manifest = PluginManifest(@"top.example.hash", @"1.0.0");
    manifest[@"files"] = @[@{@"path": @"ui/a.json",
                             @"sha256": SHA256Hex(UTF8(@"{\"a\":2}")),
                             @"size": @(files[@"ui/a.json"].length)}];
    NSURL *tampered = WritePackage(Package(manifest, files), @"tampered.air2plugin");

    NSError *error = nil;
    ok([installer installPackageAtURL:tampered source:LocalSource() error:&error] == nil,
       @"内容与清单哈希不符的包被拒");
    expectReject(@"哈希不符给 E_HASH_MISMATCH", error, @"E_HASH_MISMATCH");

    // 有文件没写进清单
    NSDictionary<NSString *, NSData *> *extraFiles =
        @{@"ui/a.json": UTF8(@"{\"a\":1}"), @"assets/hidden.bin": UTF8(@"payload")};
    NSMutableDictionary *undeclaredManifest = PluginManifest(@"top.example.undeclared", @"1.0.0");
    DeclareFiles(undeclaredManifest, @{@"ui/a.json": UTF8(@"{\"a\":1}")});
    NSURL *undeclared = WritePackage(Package(undeclaredManifest, extraFiles), @"undeclared.air2plugin");

    error = nil;
    ok([installer installPackageAtURL:undeclared source:LocalSource() error:&error] == nil,
       @"assets/ 下有文件没写进 manifest.files 的包被拒");
    expectReject(@"清单缺项给 E_FILE_SET_MISMATCH", error, @"E_FILE_SET_MISMATCH");

    // JS 插件：P1/P2 宿主不支持
    NSDictionary<NSString *, NSData *> *jsFiles = @{@"entry.js": UTF8(@"export default {};")};
    NSMutableDictionary *jsManifest = PluginManifest(@"top.example.js", @"1.0.0");
    jsManifest[@"type"] = @"js";
    jsManifest[@"entry"] = @"entry.js";
    DeclareFiles(jsManifest, jsFiles);
    NSURL *jsURL = WritePackage(Package(jsManifest, jsFiles), @"js.air2plugin");

    error = nil;
    ok([installer installPackageAtURL:jsURL source:LocalSource() error:&error] == nil,
       @"P1 阶段装 JS 插件被拒（宿主能力门）");
    expectReject(@"JS 插件给 E_TYPE_UNSUPPORTED", error, @"E_TYPE_UNSUPPORTED");

    installer.allowsJSPlugins = YES;
    error = nil;
    ok([installer installPackageAtURL:jsURL source:LocalSource() error:&error] != nil,
       @"打开 allowsJSPlugins 后 JS 插件可以装");
}

#pragma mark - 用例：来源校验

static void testSourceValidation(void) {
    NSError *error = nil;
    ok([A2PluginInstallSource sourceWithKind:@"airdrop" detail:nil error:&error] == nil,
       @"未知来源种类被拒");
    expectReject(@"未知来源给 E_FIELD", error, @"E_FIELD");

    A2PluginInstallSource *source =
        [A2PluginInstallSource sourceWithKind:@"url" detail:@"example.com" error:NULL];
    eqStr(source.kind, @"url", @"合法来源种类保留原值");
    eqStr(source.detail, @"example.com", @"来源细节保留");
    ok(source.installedAt.length > 0, @"来源带上了安装时间");
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        testInstallSuccess();
        testVersionRules();
        testUninstall();
        testRollback();
        testZipSafety();
        testIntegrityAndHostGate();
        testSourceValidation();

        printf("\n---- %d passed, %d failed ----\n", gPass, gFail);
    }
    return gFail == 0 ? 0 : 1;
}
