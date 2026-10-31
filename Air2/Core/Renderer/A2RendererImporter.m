//
//  A2RendererImporter.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
//
//  A2RendererImporter.m
//  Air2
//

#import "A2RendererImporter.h"
#import "A2ZipReader.h"
#import "A2Log.h"

#import <CommonCrypto/CommonDigest.h>
#include <string.h>

NSNotificationName const A2RendererPluginsDidChangeNotification = @"A2RendererPluginsDidChangeNotification";

/// 安装记录文件名。放在插件目录里（跟着插件一起被原子搬走），
/// 不另建一份全局索引 —— 索引与目录会漂移，而「记录就在被记录的目录里」不会。
static NSString *const A2RendererInstallRecordName = @"install.json";

/// 临时区目录名（都在插件目录下 ⇒ 与正式目录同一卷 ⇒ rename 才是原子的）
static NSString *const A2RendererStagingDirName = @".staging";
static NSString *const A2RendererIncomingDirName = @".incoming";
static NSString *const A2RendererTrashDirName = @".trash";

static NSString *const A2RendererImportErrorDomain = @"A2RendererImporter";

typedef NS_ENUM(NSInteger, A2RendererImportErrorCode) {
    A2RendererImportErrorUnreadable = 1,          ///< 文件读不到
    A2RendererImportErrorBadZip,                  ///< 不是 zip / 解压失败
    A2RendererImportErrorUnsafeEntry,             ///< 包里有不安全路径 / 符号链接 / 特殊文件
    A2RendererImportErrorManifestMissing,         ///< 包根缺少 manifest.json
    A2RendererImportErrorManifestDuplicate,       ///< 多份 manifest.json（夹带）
    A2RendererImportErrorManifestInvalid,         ///< 字段不合法 / 不是 JSON
    A2RendererImportErrorContentConflict,         ///< 同 id 同版本、内容不同
    A2RendererImportErrorUnsupportedSystem,       ///< 插件要求更高的系统版本
    A2RendererImportErrorInstallFailed,           ///< 换目录失败
    A2RendererImportErrorBuiltinNotRemovable,     ///< 内置渲染器不可卸载
};

/// 主线程跳到主线程就别再 dispatch（避免一次多跑一轮 runloop）
static void A2Main(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

static NSError *A2ImportError(A2RendererImportErrorCode code, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
static NSError *A2ImportError(A2RendererImportErrorCode code, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return [NSError errorWithDomain:A2RendererImportErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation A2RendererImportResult
@end

@interface A2RendererImporter ()
@property (nonatomic, strong) NSMutableArray<A2RendererPlugin *> *plugins;
@property (nonatomic, strong) NSLock *lock;
/// 导入/卸载串行化：两个导入同时换同一个目录名会互相踩
@property (nonatomic, strong) NSLock *installLock;
@end

@implementation A2RendererImporter

+ (instancetype)shared {
    static A2RendererImporter *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2RendererImporter alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _plugins = [NSMutableArray array];
    _lock = [[NSLock alloc] init];
    _installLock = [[NSLock alloc] init];
    return self;
}

#pragma mark - 目录

/// 插件正式目录。
///
/// 放在 Documents 而不是 Library/Caches —— 用户导入的插件不该被系统清理。
/// （Caches 随时可能被清空，渲染器是用户主动装的，删了会很困惑）
- (NSString *)pluginsDirectory {
    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"Air2/Renderers"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

/// 在指定父目录下建一个唯一子目录（uuid），返回 nil 表示建不出来。
- (nullable NSString *)makeScratchDirectoryIn:(NSString *)parent {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dir = [parent stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError *createError = nil;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&createError]) {
        [A2Log log:@"renderer-import: 建临时目录失败 %@（%@) ", dir,
              createError.localizedDescription ?: @"未知原因"];
        return nil;
    }
    return dir;
}

#pragma mark - 读取已安装

- (NSArray<A2RendererPlugin *> *)installedPlugins {
    [self.lock lock];
    NSArray<A2RendererPlugin *> *copy = [self.plugins sortedArrayUsingComparator:^NSComparisonResult(
        A2RendererPlugin *a, A2RendererPlugin *b) {
        return [a.displayName compare:b.displayName options:NSCaseInsensitiveSearch];
    }];
    [self.lock unlock];
    return copy;
}

- (void)reloadAll {
    NSString *root = self.pluginsDirectory;
    NSArray<NSString *> *entries = [NSFileManager.defaultManager
                                    contentsOfDirectoryAtPath:root error:nil];

    NSMutableArray<A2RendererPlugin *> *found = [NSMutableArray array];
    NSUInteger skipped = 0;

    for (NSString *name in entries) {
        // `.staging` / `.incoming` / `.trash` 与用户手放的隐藏目录一律不扫
        if ([name hasPrefix:@"."]) continue;

        NSString *pluginDir = [root stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        [NSFileManager.defaultManager fileExistsAtPath:pluginDir isDirectory:&isDir];
        if (!isDir) continue;

        NSString *manifestPath = [pluginDir stringByAppendingPathComponent:@"manifest.json"];
        NSData *data = [NSData dataWithContentsOfFile:manifestPath];
        NSDictionary *json = data
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *manifestError = nil;
        A2RendererPlugin *plugin = [A2RendererPlugin pluginWithManifest:json
                                                            installPath:pluginDir
                                                                  error:&manifestError];
        if (plugin == nil) {
            // 目录名与 rendererId 不一致的（手抄进来的）也走这里 —— 如实记一行，不静默吞
            skipped++;
            [A2Log log:@"renderer-import: 跳过 %@：%@", name, manifestError ?: @"manifest 无法解析"];
            continue;
        }

        // 安装记录里的来源文件名（没有记录 = 手抄进来的，不编一个）
        NSDictionary *record = [A2RendererImporter installRecordAtPath:pluginDir];
        NSString *source = [record[@"sourceFileName"] isKindOfClass:NSString.class]
            ? record[@"sourceFileName"] : nil;
        [plugin attachSourceFileName:source];

        [plugin validate];
        [found addObject:plugin];
    }

    [self.lock lock];
    self.plugins = found;
    [self.lock unlock];

    [A2Log log:@"renderer-import: 扫描到 %lu 个导入渲染器（跳过 %lu 个坏目录）",
          (unsigned long)found.count, (unsigned long)skipped];

    A2Main(^{
        [NSNotificationCenter.defaultCenter postNotificationName:A2RendererPluginsDidChangeNotification
                                                          object:nil];
    });
}

#pragma mark - 导入

- (void)importPluginAtPath:(NSString *)zipPath
                  progress:(void (^)(double, NSString *))progress
                completion:(void (^)(A2RendererImportResult *))completion {

    if (zipPath.length == 0) {
        A2RendererImportResult *result = [A2RendererImportResult new];
        result.errorMessage = @"没有给出插件文件";
        A2Main(^{ if (completion) completion(result); });
        return;
    }

    A2Main(^{ if (progress) progress(0.05, @"正在读取插件包…"); });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{

        A2RendererImportResult *result = [A2RendererImportResult new];

        void (^fail)(NSError *) = ^(NSError *error) {
            result.errorMessage = error.localizedDescription ?: @"导入失败";
            [A2Log log:@"renderer-import: ★拒装★ %@ ⇒ %@",
                  zipPath.lastPathComponent, result.errorMessage];
            A2Main(^{
                if (progress) progress(1.0, result.errorMessage);
                if (completion) completion(result);
            });
        };

        // 串行化：同一次导入从头到尾持有，两个导入不会互相覆盖同一个目录名
        [self.installLock lock];

        NSString *staging = [self makeScratchDirectoryIn:
                             [self.pluginsDirectory stringByAppendingPathComponent:A2RendererStagingDirName]];
        if (staging == nil) {
            [self.installLock unlock];
            fail(A2ImportError(A2RendererImportErrorInstallFailed, @"无法创建临时目录"));
            return;
        }

        // ---- 1. 解压（逐条校验路径）----
        NSError *unzipError = nil;
        BOOL unzipped = [self unzip:zipPath to:staging error:&unzipError];
        if (!unzipped) {
            [self cleanup:staging];
            [self.installLock unlock];
            fail(unzipError ?: A2ImportError(A2RendererImportErrorBadZip, @"解压失败"));
            return;
        }

        A2Main(^{ if (progress) progress(0.3, @"正在校验插件…"); });

        // ---- 2. 落盘复核：符号链接 / 特殊文件 / manifest 数量 ----
        NSArray<NSString *> *manifestRelPaths = nil;
        NSError *scanError = nil;
        if (![self scanExtractedTree:staging manifests:&manifestRelPaths error:&scanError]) {
            [self cleanup:staging];
            [self.installLock unlock];
            fail(scanError);
            return;
        }

        if (manifestRelPaths.count == 0) {
            [self cleanup:staging];
            [self.installLock unlock];
            fail(A2ImportError(A2RendererImportErrorManifestMissing, @"包根缺少 manifest.json"));
            return;
        }
        if (manifestRelPaths.count > 1) {
            [self cleanup:staging];
            [self.installLock unlock];
            fail(A2ImportError(A2RendererImportErrorManifestDuplicate,
                               @"包里有多份 manifest.json（%@ 等 %lu 份）—— 一个包只允许一个插件",
                               manifestRelPaths.firstObject,
                               (unsigned long)manifestRelPaths.count));
            return;
        }

        // ---- 3. 定位包根 ----
        // 只容忍「根目录没有、唯一一层子目录里有」（Finder / 压缩工具常见形态）；
        // 多份 manifest 已在上面拒掉，所以这里不会撞到「两个插件一个包」。
        NSString *manifestRel = manifestRelPaths.firstObject;
        NSString *packageRoot = staging;
        if (![manifestRel isEqualToString:@"manifest.json"]) {
            NSString *sub = [manifestRel stringByDeletingLastPathComponent];
            NSArray<NSString *> *segments = [sub componentsSeparatedByString:@"/"];
            if (segments.count != 1) {
                [self cleanup:staging];
                [self.installLock unlock];
                fail(A2ImportError(A2RendererImportErrorManifestMissing,
                                   @"包根缺少 manifest.json（找到的是 %@，层级太深）", manifestRel));
                return;
            }
            packageRoot = [staging stringByAppendingPathComponent:sub];
            [A2Log log:@"renderer-import: 包根没有 manifest.json，按单层目录 %@ 兼容", sub];
        }

        // ---- 4. 解析 + 静态校验 manifest ----
        NSData *manifestData = [NSData dataWithContentsOfFile:
                                [packageRoot stringByAppendingPathComponent:@"manifest.json"]];
        if (manifestData == nil) {
            [self cleanup:staging];
            [self.installLock unlock];
            fail(A2ImportError(A2RendererImportErrorManifestMissing, @"manifest.json 读不出来"));
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class]) {
            [self cleanup:staging];
            [self.installLock unlock];
            fail(A2ImportError(A2RendererImportErrorManifestInvalid,
                               @"manifest.json 不是合法的 JSON 对象（UTF-8 无 BOM）"));
            return;
        }
        NSString *manifestError = nil;
        A2RendererPlugin *plugin = [A2RendererPlugin pluginWithManifest:json
                                                            installPath:packageRoot
                                                                  error:&manifestError];
        if (plugin == nil) {
            [self cleanup:staging];
            [self.installLock unlock];
            fail(A2ImportError(A2RendererImportErrorManifestInvalid,
                               @"manifest.json 不合法：%@", manifestError ?: @"字段缺失"));
            return;
        }

        // ---- 5. 库文件静态校验（文件 / 普通文件 / 包内 / Mach-O arm64 / 导出符号）----
        A2Main(^{ if (progress) progress(0.5, @"正在校验库文件…"); });
        [plugin validate];
        if (plugin.availability != A2RendererAvailabilityAvailable) {
            [self cleanup:staging];
            [self.installLock unlock];
            fail(A2ImportError(A2RendererImportErrorUnsafeEntry,
                               @"库文件没通过静态校验：%@",
                               plugin.unavailableReason ?: @"原因未知"));
            return;
        }

        // ---- 5b. 系统版本闸门（插件自述的 ios.minSystemVersion）----
        NSString *requiredSystem = nil;
        if (![A2RendererImporter currentSystemSatisfiesMinimum:plugin.minSystemVersion
                                                  requiredText:&requiredSystem]) {
            [self cleanup:staging];
            [self.installLock unlock];
            fail(A2ImportError(A2RendererImportErrorUnsupportedSystem, @"%@", requiredSystem));
            return;
        }

        // ---- 6. 包摘要 ----
        NSString *digest = [A2RendererImporter payloadDigestOfDirectory:packageRoot];
        if (digest.length == 0) {
            [self cleanup:staging];
            [self.installLock unlock];
            fail(A2ImportError(A2RendererImportErrorBadZip, @"无法计算包内容摘要（文件读不了）"));
            return;
        }

        // ---- 7. 同 id 同版本、内容不同 ⇒ 拒装 ----
        NSString *destDir = [self.pluginsDirectory stringByAppendingPathComponent:plugin.rendererID];
        BOOL destExists = [NSFileManager.defaultManager fileExistsAtPath:destDir];
        NSDictionary *oldRecord = destExists ? [A2RendererImporter installRecordAtPath:destDir] : nil;
        NSString *oldVersion = [oldRecord[@"version"] isKindOfClass:NSString.class]
            ? oldRecord[@"version"] : nil;
        NSString *oldDigest = [oldRecord[@"packageHash"] isKindOfClass:NSString.class]
            ? oldRecord[@"packageHash"] : nil;

        if (destExists && [oldVersion isEqual:plugin.version ?: @""] && oldDigest.length > 0) {
            if (![oldDigest isEqualToString:digest]) {
                [self cleanup:staging];
                [self.installLock unlock];
                fail(A2ImportError(A2RendererImportErrorContentConflict,
                                   @"同一个版本号「%@」的内容和已装的不一样（已装 …%@ / 本次 …%@）—— "
                                   @"请改 manifest 的 version 后再导入",
                                   plugin.version ?: @"(未声明)",
                                   [A2RendererImporter shortDigest:oldDigest],
                                   [A2RendererImporter shortDigest:digest]));
                return;
            }

            // 同 id 同版本同内容：幂等命中，不动磁盘
            // ★返回的对象必须指向已装目录★（staging 马上就要被删，
            // 把 staging 的路径交出去 = 交出一个指向不存在目录的插件）
            [self cleanup:staging];
            [self.installLock unlock];
            A2RendererPlugin *existing = [A2RendererPlugin pluginWithManifest:json
                                                                  installPath:destDir
                                                                        error:NULL];
            if (existing == nil) existing = plugin;
            [existing attachSourceFileName:zipPath.lastPathComponent];
            [existing validate];
            result.success = YES;
            result.plugin = existing;
            result.alreadyInstalled = YES;
            result.replacedExisting = YES;
            [A2Log log:@"renderer-import: 「%@」同版本同内容，已装过 ⇒ 幂等命中（磁盘未改）",
                  plugin.displayName];
            A2Main(^{
                if (progress) progress(1.0, @"已安装过同样的内容");
                if (completion) completion(result);
            });
            return;
        }

        // ---- 8. 写安装记录（在 staging 里先写好，跟着目录一起搬）----
        // 部署目标 iOS 14 ⇒ NSISO8601DateFormatter 一定可用（不必 @available）
        NSString *installedAt = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
        NSMutableDictionary *record = [@{
            @"formatVersion": @(1),
            @"rendererId": plugin.rendererID,
            @"displayName": plugin.displayName,
            @"packageHash": digest,
            @"sourceFileName": zipPath.lastPathComponent ?: @"",
            @"installedAt": installedAt,
        } mutableCopy];
        if (plugin.version.length) record[@"version"] = plugin.version;
        if (plugin.author.length) record[@"author"] = plugin.author;

        NSError *recordError = nil;
        if (![A2RendererImporter writeInstallRecord:record
                                        toDirectory:packageRoot
                                              error:&recordError]) {
            [self cleanup:staging];
            [self.installLock unlock];
            fail(A2ImportError(A2RendererImportErrorInstallFailed,
                               @"写安装记录失败：%@",
                               recordError.localizedDescription ?: @"未知原因"));
            return;
        }

        // ---- 9. 原子换目录 ----
        A2Main(^{ if (progress) progress(0.8, @"正在安装…"); });

        NSString *incomingRoot = [self.pluginsDirectory
                                  stringByAppendingPathComponent:A2RendererIncomingDirName];
        NSString *incomingDir = [self makeScratchDirectoryIn:incomingRoot];
        if (incomingDir == nil) {
            [self cleanup:staging];
            [self.installLock unlock];
            fail(A2ImportError(A2RendererImportErrorInstallFailed, @"无法创建安装临时目录"));
            return;
        }

        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *moveError = nil;
        if (![fm moveItemAtPath:packageRoot toPath:incomingDir error:&moveError]) {
            [self cleanup:staging];
            [self cleanup:incomingDir];
            [self.installLock unlock];
            fail(A2ImportError(A2RendererImportErrorInstallFailed,
                               @"挪到安装临时目录失败：%@",
                               moveError.localizedDescription ?: @"未知原因"));
            return;
        }

        // 旧目录先挪到 trash（rename），新目录顶上；任何一步失败都把旧目录挪回来
        NSString *trashDir = nil;
        if (destExists) {
            trashDir = [self makeScratchDirectoryIn:
                        [self.pluginsDirectory stringByAppendingPathComponent:A2RendererTrashDirName]];
            NSString *backup = [trashDir stringByAppendingPathComponent:plugin.rendererID];
            NSError *backupError = nil;
            if (trashDir == nil || ![fm moveItemAtPath:destDir toPath:backup error:&backupError]) {
                [self cleanup:staging];
                [self cleanup:incomingDir];
                if (trashDir) [self cleanup:trashDir];
                [self.installLock unlock];
                fail(A2ImportError(A2RendererImportErrorInstallFailed,
                                   @"无法备份旧版本（%@），未做任何改动",
                                   backupError.localizedDescription ?: @"未知原因"));
                return;
            }
        }

        NSError *swapError = nil;
        if (![fm moveItemAtPath:incomingDir toPath:destDir error:&swapError]) {
            // ★回滚★：把旧目录挪回原位，然后把 staging / incoming 清掉
            if (trashDir) {
                NSString *backup = [trashDir stringByAppendingPathComponent:plugin.rendererID];
                NSError *restoreError = nil;
                if ([fm moveItemAtPath:backup toPath:destDir error:&restoreError]) {
                    [A2Log log:@"renderer-import: ★已回滚★旧版本回到 %@", destDir];
                } else {
                    [A2Log log:@"renderer-import: ★回滚失败★旧版本留在 %@（%@）—— 需要人工处理",
                          backup, restoreError.localizedDescription ?: @"未知原因"];
                }
            }
            [self cleanup:staging];
            [self cleanup:incomingDir];
            if (trashDir) [self cleanup:trashDir];
            [self.installLock unlock];
            fail(A2ImportError(A2RendererImportErrorInstallFailed,
                               @"换目录失败：%@", swapError.localizedDescription ?: @"未知原因"));
            return;
        }

        // 成功：旧版本目录删除（trash 里的东西已经没人指向它了）
        if (trashDir) [self cleanup:trashDir];
        [self cleanup:staging];

        // ---- 10. 注册（内存表）----
        A2RendererPlugin *installed = [A2RendererPlugin pluginWithManifest:json
                                                               installPath:destDir
                                                                     error:NULL];
        if (installed) {
            [installed attachSourceFileName:zipPath.lastPathComponent];
            [installed validate];
        } else {
            // 不该发生：同一份 JSON 刚解析过。真发生了也把落盘事实说清楚。
            [A2Log log:@"renderer-import: ★异常★装好后重新解析 manifest 失败（%@）", destDir];
        }

        [self.lock lock];
        NSMutableArray<A2RendererPlugin *> *list = [self.plugins mutableCopy] ?: [NSMutableArray array];
        for (NSUInteger i = 0; i < list.count; i++) {
            if ([list[i].rendererID isEqualToString:plugin.rendererID]) {
                [list removeObjectAtIndex:i];
                break;
            }
        }
        if (installed) [list addObject:installed];
        self.plugins = list;
        [self.lock unlock];

        [self.installLock unlock];

        [A2Log log:@"renderer-import: 插件「%@」(id=%@ ver=%@) 导入成功（%@），状态=%ld，env 声明 %lu 项（启动链不消费）",
              plugin.displayName, plugin.rendererID, plugin.version ?: @"(未声明)",
              destExists ? @"已覆盖旧版本" : @"首次安装", (long)installed.availability,
              (unsigned long)plugin.envSpecs.count];

        result.success = YES;
        result.plugin = installed;
        result.replacedExisting = destExists;

        A2Main(^{
            if (progress) progress(1.0, @"导入完成");
            [NSNotificationCenter.defaultCenter postNotificationName:A2RendererPluginsDidChangeNotification
                                                              object:nil];
            if (completion) completion(result);
        });
    });
}

- (void)cleanup:(NSString *)dir {
    if (dir.length == 0) return;
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
}

#pragma mark - 解压

/// 用 A2ZipReader 解压全部条目。
///
/// 为什么自己解压而不是用系统 API：iOS 没有公开的 zip 解压 API。
/// A2ZipReader 是为读 installer jar 写的，这里复用 —— 支持 stored 与 deflate。
///
/// ★逐条校验路径★：任何一条不安全就**整包拒装**（不是「跳过这条继续」）——
/// 跳过会让「包里有 20 个文件、只装了 19 个」变成沉默的事实，
/// 而 manifest 里声明的库很可能正好是被跳掉的那个。
- (BOOL)unzip:(NSString *)zipPath to:(NSString *)destDir error:(NSError **)error {
    if (![NSFileManager.defaultManager fileExistsAtPath:zipPath]) {
        if (error) *error = A2ImportError(A2RendererImportErrorUnreadable, @"文件不存在：%@",
                                          zipPath.lastPathComponent);
        return NO;
    }

    A2ZipReader *zip = [[A2ZipReader alloc] initWithPath:zipPath];
    if (zip == nil) {
        if (error) *error = A2ImportError(A2RendererImportErrorBadZip, @"不是有效的 zip 文件");
        return NO;
    }

    NSUInteger extracted = 0;
    for (NSString *entry in zip.entryNames) {
        if (![A2RendererPlugin isSafePackageRelativePath:entry]) {
            [A2Log log:@"renderer-import: ★拒装★不安全的条目路径：%@", entry];
            if (error) {
                *error = A2ImportError(A2RendererImportErrorUnsafeEntry,
                                       @"包里有一条不安全的路径（含 .. / 绝对路径 / 反斜杠）：%@",
                                       entry);
            }
            return NO;
        }
        // macOS 压缩出来的资源分支残留（不是插件内容）
        if ([entry hasPrefix:@"__MACOSX/"] || [entry.lastPathComponent hasPrefix:@"._"]) {
            continue;
        }

        NSString *dest = [destDir stringByAppendingPathComponent:entry];
        if (![zip extractEntry:entry toPath:dest]) {
            if (error) {
                *error = A2ImportError(A2RendererImportErrorBadZip,
                                       @"zip 条目解压失败：%@", entry);
            }
            return NO;
        }
        extracted++;
    }

    if (extracted == 0) {
        if (error) *error = A2ImportError(A2RendererImportErrorBadZip, @"包内没有可解压的文件");
        return NO;
    }
    return YES;
}

/// 解压后的落盘复核：不许有符号链接 / 特殊文件，并数出 manifest.json 的份数。
///
/// A2ZipReader 只写普通文件，理论上不会产出链接；这一遍是**防御**：
///   · 万一将来换解压实现（UnZipKit）把外部属性里的 symlink 落下来；
///   · 万一用户把一个已经存在的链接塞进来。
/// 判据只看落盘事实，不猜 zip 元数据。
- (BOOL)scanExtractedTree:(NSString *)root
                manifests:(NSArray<NSString *> **)manifests
                    error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *found = [NSMutableArray array];

    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:root];
    for (NSString *rel in enumerator) {
        NSString *full = [root stringByAppendingPathComponent:rel];
        NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:full error:nil];
        if (attrs == nil) continue;

        NSString *type = attrs[NSFileType];
        if ([type isEqualToString:NSFileTypeSymbolicLink]) {
            if (error) {
                *error = A2ImportError(A2RendererImportErrorUnsafeEntry,
                                       @"包里含符号链接：%@", rel);
            }
            return NO;
        }
        if ([type isEqualToString:NSFileTypeDirectory]) continue;
        if (![type isEqualToString:NSFileTypeRegular]) {
            if (error) {
                *error = A2ImportError(A2RendererImportErrorUnsafeEntry,
                                       @"包里含非普通文件（设备/管道等）：%@", rel);
            }
            return NO;
        }
        if ([rel.lastPathComponent isEqualToString:@"manifest.json"]) {
            [found addObject:rel];
        }
    }

    if (manifests) *manifests = found;
    return YES;
}

#pragma mark - 安装记录

+ (nullable NSDictionary *)installRecordAtPath:(NSString *)pluginDir {
    NSString *path = [pluginDir stringByAppendingPathComponent:A2RendererInstallRecordName];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

+ (BOOL)writeInstallRecord:(NSDictionary *)record
               toDirectory:(NSString *)dir
                     error:(NSError **)error {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:nil];
    if (data == nil) return NO;
    NSString *path = [dir stringByAppendingPathComponent:A2RendererInstallRecordName];
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

#pragma mark - 系统版本闸门

/// manifest 的 `ios.minSystemVersion`（"14.0" / "17.0.1"）与当前系统比较。
///
/// 为什么要拦：插件在自己的 dylib 里用了新系统才有的符号时，装在老系统上
/// 只会得到「装得上、一加载就缺符号」——不如导入时就说清「需要 iOS ≥ x」。
/// 未声明 / 解析不出 ⇒ 视为满足（不替作者猜一个下限）。
+ (BOOL)currentSystemSatisfiesMinimum:(nullable NSString *)minSystemVersion
                          requiredText:(NSString * _Nullable * _Nullable)requiredText {
    if (minSystemVersion.length == 0) return YES;

    NSArray<NSString *> *parts = [minSystemVersion componentsSeparatedByString:@"."];
    NSInteger values[3] = {0, 0, 0};
    for (NSUInteger i = 0; i < parts.count && i < 3; i++) {
        NSInteger v = parts[i].integerValue;
        if (v < 0) v = 0;
        values[i] = v;
    }
    if (values[0] <= 0) return YES;      // "abc" 之类：不当作要求

    NSOperatingSystemVersion need = {values[0], values[1], values[2]};
    NSOperatingSystemVersion have = NSProcessInfo.processInfo.operatingSystemVersion;
    BOOL ok = (have.majorVersion > need.majorVersion) ||
              (have.majorVersion == need.majorVersion && have.minorVersion > need.minorVersion) ||
              (have.majorVersion == need.majorVersion && have.minorVersion == need.minorVersion &&
               have.patchVersion >= need.patchVersion);
    if (!ok && requiredText) {
        *requiredText = [NSString stringWithFormat:@"需要 iOS ≥ %@（本机 %ld.%ld.%ld）",
                         minSystemVersion, (long)have.majorVersion,
                         (long)have.minorVersion, (long)have.patchVersion];
    }
    return ok;
}

#pragma mark - 摘要

/// 包内容摘要：跑一遍「排序后的相对路径 + 每个文件的 sha256」，再整体 sha256。
///
/// 为什么不是「整个 zip 文件的哈希」：同一个包重新打包（压缩率不同、时间戳不同）
/// 会得到不同哈希，那就没法判「同版本同内容」。这里只认**解压后的内容**。
+ (nullable NSString *)payloadDigestOfDirectory:(NSString *)root {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *relPaths = [NSMutableArray array];

    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:root];
    for (NSString *rel in enumerator) {
        NSDictionary<NSFileAttributeKey, id> *attrs =
            [fm attributesOfItemAtPath:[root stringByAppendingPathComponent:rel] error:nil];
        if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
        if ([rel isEqualToString:A2RendererInstallRecordName]) continue;   // 记录自身不参与
        [relPaths addObject:rel];
    }
    if (relPaths.count == 0) return nil;

    [relPaths sortUsingSelector:@selector(compare:)];

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    const uint8_t sep = 0;
    for (NSString *rel in relPaths) {
        NSString *fileHex = [A2RendererImporter sha256HexOfFile:
                             [root stringByAppendingPathComponent:rel]];
        if (fileHex.length == 0) return nil;
        NSData *nameBytes = [rel dataUsingEncoding:NSUTF8StringEncoding];
        CC_SHA256_Update(&ctx, nameBytes.bytes, (CC_LONG)nameBytes.length);
        CC_SHA256_Update(&ctx, &sep, 1);
        CC_SHA256_Update(&ctx, fileHex.UTF8String, (CC_LONG)strlen(fileHex.UTF8String));
        CC_SHA256_Update(&ctx, &sep, 1);
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    return [@"sha256:" stringByAppendingString:[A2RendererImporter hexFromDigest:digest]];
}

+ (nullable NSString *)sha256HexOfFile:(NSString *)path {
    NSInputStream *in = [NSInputStream inputStreamWithFileAtPath:path];
    if (in == nil) return nil;
    [in open];
    if (in.streamStatus == NSStreamStatusError) {
        [in close];
        return nil;
    }
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    const NSUInteger chunk = 256 * 1024;
    uint8_t *buffer = malloc(chunk);
    if (buffer == NULL) {
        [in close];
        return nil;
    }
    NSInteger read = 0;
    while ((read = [in read:buffer maxLength:chunk]) > 0) {
        CC_SHA256_Update(&ctx, buffer, (CC_LONG)read);
    }
    free(buffer);
    [in close];
    if (read < 0) return nil;

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    return [A2RendererImporter hexFromDigest:digest];
}

/// 摘要的短形式（去掉 `sha256:` 前缀、只留前 12 位十六进制）——
/// 给人看的那句话里塞 64 位十六进制没人读得下去，但「不是同一个」要看得见。
+ (NSString *)shortDigest:(nullable NSString *)digest {
    if (digest.length == 0) return @"(无)";
    NSString *body = [digest hasPrefix:@"sha256:"] ? [digest substringFromIndex:7] : digest;
    return body.length > 12 ? [body substringToIndex:12] : body;
}

+ (NSString *)hexFromDigest:(const unsigned char *)digest {
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

#pragma mark - 卸载

- (BOOL)removePlugin:(A2RendererPlugin *)plugin error:(NSError **)error {
    if (plugin == nil) {
        if (error) *error = A2ImportError(A2RendererImportErrorBuiltinNotRemovable, @"没有指定插件");
        return NO;
    }
    // ★内置不可删★：内置渲染器的库在 App 包里，删不掉也不该删 ——
    // 与其让「删了又出现」，不如一次说清。
    if (!plugin.isImported) {
        if (error) {
            *error = A2ImportError(A2RendererImportErrorBuiltinNotRemovable,
                                   @"「%@」是内置渲染器，不能卸载", plugin.displayName);
        }
        return NO;
    }

    NSString *destDir = [self.pluginsDirectory stringByAppendingPathComponent:plugin.rendererID];
    NSFileManager *fm = NSFileManager.defaultManager;

    if ([fm fileExistsAtPath:destDir]) {
        // 先改名到 trash 再删：改名是原子的，用户不会看到「删了一半的插件目录」。
        // 删 trash 失败也只是留下垃圾，不影响正确性（下次扫描跳过 .trash）。
        NSString *trashDir = [self makeScratchDirectoryIn:
                              [self.pluginsDirectory stringByAppendingPathComponent:A2RendererTrashDirName]];
        NSString *moved = nil;
        if (trashDir) {
            moved = [trashDir stringByAppendingPathComponent:plugin.rendererID];
            NSError *moveError = nil;
            if (![fm moveItemAtPath:destDir toPath:moved error:&moveError]) {
                if (error) *error = moveError;
                [self cleanup:trashDir];
                return NO;
            }
            [self cleanup:trashDir];
        } else {
            NSError *removeError = nil;
            if (![fm removeItemAtPath:destDir error:&removeError]) {
                if (error) *error = removeError;
                return NO;
            }
        }
    }

    [self.lock lock];
    NSMutableArray<A2RendererPlugin *> *list = [self.plugins mutableCopy] ?: [NSMutableArray array];
    for (NSUInteger i = 0; i < list.count; i++) {
        if ([list[i].rendererID isEqualToString:plugin.rendererID]) {
            [list removeObjectAtIndex:i];
            break;
        }
    }
    self.plugins = list;
    [self.lock unlock];

    [A2Log log:@"renderer-import: 已卸载「%@」(id=%@)", plugin.displayName, plugin.rendererID];

    A2Main(^{
        [NSNotificationCenter.defaultCenter postNotificationName:A2RendererPluginsDidChangeNotification
                                                          object:nil];
    });
    return YES;
}

@end
