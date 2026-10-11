//
//  A2ModPackExporter.m
//  Air2
//

#import "A2ModPackExporter.h"
#import "A2ZipWriter.h"
#import "A2Logger.h"
#import <CommonCrypto/CommonDigest.h>

/// 导出时跳过这些目录 —— 它们不进整合包
static NSArray<NSString *> *SkippedDirs(void) {
    static NSArray *dirs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dirs = @[
            @"logs",              // 运行日志，与内容无关
            @"crash-reports",     // 崩溃报告
            @".air_version",      // 启动器私有数据（含机器相关信息，不该外传）
            @".mixin.out",
            @"screenshots",       // 截图是个人内容
        ];
    });
    return dirs;
}

@implementation A2PackExportOptions

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _version = @"1.0.0";
    _minimumMemoryMB = 2048;
    return self;
}

@end

@interface A2ModPackExporter ()
@property (nonatomic, strong) A2ZipWriter *writer;
@end

@implementation A2ModPackExporter

#pragma mark - 扫描

- (void)scanVersionAtPath:(NSString *)versionPath
               completion:(void (^)(NSArray<NSString *> *))completion {

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *out = [NSMutableArray array];
        NSFileManager *fm = NSFileManager.defaultManager;

        NSDirectoryEnumerator *en = [fm enumeratorAtPath:versionPath];
        for (NSString *rel in en) {
            // 跳过屏蔽目录
            BOOL skip = NO;
            for (NSString *skipDir in SkippedDirs()) {
                if ([rel hasPrefix:skipDir] || [rel containsString:[NSString stringWithFormat:@"/%@/", skipDir]]) {
                    skip = YES;
                    break;
                }
            }
            if (skip) {
                [en skipDescendants];
                continue;
            }

            BOOL isDir = NO;
            [fm fileExistsAtPath:[versionPath stringByAppendingPathComponent:rel] isDirectory:&isDir];
            if (!isDir) [out addObject:rel];
        }

        [out sortUsingSelector:@selector(compare:)];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(out);
        });
    });
}

#pragma mark - 导出

- (void)exportVersionAtPath:(NSString *)versionPath
                     format:(A2PackExportFormat)format
                    options:(A2PackExportOptions *)options
                 outputPath:(NSString *)outputPath
                   progress:(void (^)(double, NSString *))progress
                 completion:(void (^)(BOOL, NSError *))completion {

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{

        void (^report)(double, NSString *) = ^(double p, NSString *msg) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (progress) progress(p, msg);
            });
        };

        report(0.05, @"正在收集文件…");

        // 1. 收集要打包的文件（相对路径）
        NSArray<NSString *> *selected = options.selectedPaths;
        if (!selected) {
            __block NSArray<NSString *> *scanResult = nil;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [self scanVersionAtPath:versionPath completion:^(NSArray<NSString *> *paths) {
                scanResult = paths;
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            selected = scanResult ?: @[];
        }

        report(0.2, [NSString stringWithFormat:@"共 %lu 个文件", (unsigned long)selected.count]);

        // 2. 建 zip
        A2ZipWriter *writer = [[A2ZipWriter alloc] initWithPath:outputPath];
        if (!writer) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, [self err:@"无法创建输出文件"]);
            });
            return;
        }

        // 3. 生成清单
        NSDictionary *manifest = (format == A2PackExportFormatModrinth)
            ? [self modrinthIndexForPaths:selected versionPath:versionPath options:options]
            : [self curseForgeManifestForPaths:selected versionPath:versionPath options:options];

        NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest
                                                              options:NSJSONWritingPrettyPrinted
                                                                error:nil];

        NSString *manifestName = (format == A2PackExportFormatModrinth)
            ? @"modrinth.index.json"
            : @"manifest.json";
        [writer addData:manifestData entryName:manifestName];

        report(0.3, @"正在打包文件…");

        // 4. 打包文件
        //    平台文件只记在清单里不打包 —— 整合包规范就是这样，
        //    接收方自己下载。这里把所有选中文件都打进 overrides/
        //    （因为无法可靠判断哪些来自平台，宁可多打也不丢内容）。
        NSUInteger total = selected.count;
        NSUInteger done = 0;

        for (NSString *rel in selected) {
            NSString *full = [versionPath stringByAppendingPathComponent:rel];
            NSString *entry = [NSString stringWithFormat:@"overrides/%@", rel];
            [writer addFileAtPath:full entryName:entry];

            done++;
            if (done % 20 == 0 || done == total) {
                report(0.3 + 0.6 * ((double)done / (double)MAX(1, total)),
                       [NSString stringWithFormat:@"打包中 (%lu/%lu)",
                        (unsigned long)done, (unsigned long)total]);
            }
        }

        // 5. 收尾
        BOOL ok = [writer finish];
        report(1.0, ok ? @"导出完成" : @"导出失败");

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(ok, ok ? nil : [self err:@"写入 zip 失败"]);
            }
        });
    });
}

#pragma mark - 清单生成

/// Modrinth 的 modrinth.index.json
/// 规范：https://docs.modrinth.com/docs/modpacks/format_definition/
- (NSDictionary *)modrinthIndexForPaths:(NSArray<NSString *> *)paths
                            versionPath:(NSString *)versionPath
                                options:(A2PackExportOptions *)options {

    NSMutableArray *files = [NSMutableArray array];
    for (NSString *rel in paths) {
        NSString *full = [versionPath stringByAppendingPathComponent:rel];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:full error:nil];
        long long size = [attrs[NSFileSize] longLongValue];

        [files addObject:@{
            @"path": rel,
            @"hashes": @{ @"sha1": [self sha1OfFile:full] ?: @"" },
            @"downloads": @[],          // 本地文件没有下载地址
            @"fileSize": @(size),
        }];
    }

    NSMutableDictionary *deps = [NSMutableDictionary dictionary];
    deps[@"minecraft"] = options.version ?: @"1.20.1";

    return @{
        @"game": @"minecraft",
        @"formatVersion": @1,
        @"versionId": options.version ?: @"1.0.0",
        @"name": options.packName ?: @"Air2 Modpack",
        @"summary": options.summary ?: @"",
        @"files": files,
        @"dependencies": deps,
    };
}

/// CurseForge 的 manifest.json
/// 规范：https://docs.curseforge.com/#tocS_Manifest
- (NSDictionary *)curseForgeManifestForPaths:(NSArray<NSString *> *)paths
                                 versionPath:(NSString *)versionPath
                                     options:(A2PackExportOptions *)options {

    // CurseForge 格式要求 files 里是 projectID/fileID 对。
    // 我们无法从本地文件反查这些 ID（需要 platform 侧支持），
    // 所以按「全部走 overrides」处理 —— 这是合法的：
    // 接收方会直接把 overrides 解开，只是失去了「自动更新」能力。
    return @{
        @"manifestType": @"minecraftModpack",
        @"manifestVersion": @1,
        @"name": options.packName ?: @"Air2 Modpack",
        @"version": options.version ?: @"1.0.0",
        @"author": options.author ?: @"Air2",
        @"minecraft": @{
            @"version": @"1.20.1",
            @"modLoaders": @[],
            @"recommendedRam": @(options.minimumMemoryMB),
        },
        @"files": @[],
        @"overrides": @"overrides",
    };
}

#pragma mark - 工具

/// 计算文件的 SHA1（整合包清单需要）
- (nullable NSString *)sha1OfFile:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    if (!data) return nil;

    unsigned char digest[20];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:40];
    for (int i = 0; i < 20; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

- (NSError *)err:(NSString *)msg {
    return [NSError errorWithDomain:@"A2ModPackExporter" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"导出失败"}];
}

@end
