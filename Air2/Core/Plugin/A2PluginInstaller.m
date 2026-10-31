//
//  A2PluginInstaller.m
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
//  流程与崩溃窗口见头文件。这里只强调一条实现纪律：
//  **注册表在每一步之后都必须指向一个真实存在的目录**。
//  所以顺序是「新目录就位 → 写注册表 → 旧目录收走」，
//  而不是「旧目录先搬走 → 新目录就位 → 写注册表」。
//

#import "A2PluginInstaller.h"

#import <errno.h>
#import <stdio.h>
#import <string.h>

#import "A2Log.h"
#import "A2PluginPackageExtractor.h"
#import "A2PluginRegistry.h"

/// 解压暂存目录（4.4：启动时整个删掉，里面的东西没有一次是被需要的）。
static NSString *const kStagingDirectoryName = @".staging";
/// 保留下来的上一版（回退的来源）。
static NSString *const kPackagesDirectoryName = @"packages";
/// 保留版目录名的分隔符：`<pluginId>@<hash>`
static NSString *const kRetainedSeparator = @"@";

/// 用户能看到的来源种类（PLUGIN-SYSTEM 4.1 / registry 的 source.kind）。
static NSSet<NSString *> *A2InstallSourceKinds(void) {
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"local-import", @"url", @"share-sheet", @"dev-dir"]];
    });
    return set;
}

/// 注册表里的哈希可能是 `sha256:<hex>` 也可能是裸 hex，比较前统一成裸小写 hex。
static NSString *A2DigestOfHashString(NSString *hash) {
    if (![hash isKindOfClass:NSString.class]) return @"";
    NSString *digest = [hash hasPrefix:@"sha256:"] ? [hash substringFromIndex:7] : hash;
    return digest.lowercaseString ?: @"";
}

static NSString *A2HashStringForDigest(NSString *digest) {
    return [@"sha256:" stringByAppendingString:digest];
}

/// ISO-8601（UTC，秒精度）：注册表里所有时间字段的格式，与 ① 的用例素材一致。
static NSString *A2ISO8601Now(void) {
    static NSISO8601DateFormatter *formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    });
    return [formatter stringFromDate:NSDate.date] ?: @"1970-01-01T00:00:00Z";
}

/// 规范化权限集（`id:risk` 每行一条）里出现过的权限 id。
/// 升级/回退时用它区分「用户关掉的旧权限」与「这次新申请的权限」——
/// 前者要沿用「关」，后者低/中默认开（4.2 ⑤）。
static NSSet<NSString *> *A2PermissionIdsOfCanonicalSet(NSString *canonicalSet) {
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    for (NSString *line in [canonicalSet componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        NSRange colon = [line rangeOfString:@":"];
        NSString *permissionId = colon.location == NSNotFound
            ? line : [line substringToIndex:colon.location];
        if (permissionId.length) [ids addObject:permissionId];
    }
    return ids;
}

static BOOL A2RenamePath(NSString *from, NSString *to) {
    return rename(from.fileSystemRepresentation, to.fileSystemRepresentation) == 0;
}

#pragma mark - 来源

@interface A2PluginInstallSource ()
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy, nullable) NSString *detail;
@property (nonatomic, copy) NSString *installedAt;
@end

@implementation A2PluginInstallSource

+ (nullable instancetype)sourceWithKind:(NSString *)kind
                                 detail:(nullable NSString *)detail
                                  error:(NSError **)error {
    if (![A2InstallSourceKinds() containsObject:kind ?: @""]) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorField, @"source.kind",
                                       @"source.kind「%@」不在枚举内"
                                       @"（local-import / url / share-sheet / dev-dir）",
                                       kind ?: @"(空)");
        }
        return nil;
    }
    return [self sourceWithKind:kind detail:detail installedAt:A2ISO8601Now()];
}

+ (instancetype)sourceWithKind:(NSString *)kind
                        detail:(nullable NSString *)detail
                   installedAt:(NSString *)installedAt {
    A2PluginInstallSource *source = [A2PluginInstallSource new];
    source.kind = kind ?: @"local-import";
    source.detail = detail;
    source.installedAt = installedAt.length ? installedAt : A2ISO8601Now();
    return source;
}

@end

#pragma mark - 结果

@interface A2PluginInstallResult ()
@property (nonatomic, strong) A2PluginRegistryEntry *entry;
@property (nonatomic, copy) NSString *contentHash;
@property (nonatomic, assign) BOOL reusedExisting;
@end

@implementation A2PluginInstallResult
@end

#pragma mark - 安装器

@interface A2PluginInstaller ()
@property (nonatomic, strong) A2PluginRegistry *registry;
@end

@implementation A2PluginInstaller

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：没有注册表的安装器是非法状态。
    // 声明/实现一致性检查要求每个声明都有实现；正常代码走不到这里。
    return nil;
}

- (instancetype)initWithRegistry:(A2PluginRegistry *)registry {
    self = [super init];
    if (self) {
        _registry = registry;
        _limits = A2PluginDefaultLimits();
        _allowsDowngrade = NO;
        _allowsJSPlugins = NO;
        _builtinPluginIds = [NSSet set];
    }
    return self;
}

#pragma mark 日志

- (void)logLine:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [@"[A2-PLUGIN] " stringByAppendingString:message ?: @""];
    if (self.logSink) {
        self.logSink(line);
        return;
    }
    [A2Log log:@"%@", line];
}

#pragma mark 路径

- (NSString *)pluginsDirectory {
    return self.registry.pluginsDirectory;
}

- (NSString *)stagingDirectoryForNewInstall {
    NSString *staging = [self.pluginsDirectory stringByAppendingPathComponent:kStagingDirectoryName];
    NSString *unique = [staging stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:unique
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:NULL]) {
        return nil;
    }
    return unique;
}

- (NSString *)packagesDirectory {
    return [self.pluginsDirectory stringByAppendingPathComponent:kPackagesDirectoryName];
}

- (NSString *)retainedDirectoryForPluginId:(NSString *)pluginId digest:(NSString *)digest {
    NSString *name = [NSString stringWithFormat:@"%@%@%@", pluginId, kRetainedSeparator, digest];
    return [self.packagesDirectory stringByAppendingPathComponent:name];
}

/// 该插件保留下来的上一版目录（按修改时间新的在前）。正常情况下最多一个。
- (NSArray<NSString *> *)retainedDirectoriesForPluginId:(NSString *)pluginId {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSArray<NSString *> *names =
        [fileManager contentsOfDirectoryAtPath:self.packagesDirectory error:NULL];
    NSString *prefix = [pluginId stringByAppendingString:kRetainedSeparator];

    NSMutableArray<NSDictionary<NSString *, id> *> *found = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name hasPrefix:prefix]) continue;
        NSString *path = [self.packagesDirectory stringByAppendingPathComponent:name];
        NSDictionary<NSFileAttributeKey, id> *attributes =
            [fileManager attributesOfItemAtPath:path error:NULL];
        if (![attributes[NSFileType] isEqualToString:NSFileTypeDirectory]) continue;
        [found addObject:@{@"path": path,
                           @"date": attributes[NSFileModificationDate] ?: NSDate.distantPast}];
    }
    [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [(NSDate *)b[@"date"] compare:(NSDate *)a[@"date"]];
    }];

    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:found.count];
    for (NSDictionary *item in found) {
        [paths addObject:item[@"path"]];
    }
    return paths;
}

#pragma mark 注册表条目

/// 安装/回退后的条目。**不原地改旧条目**：写盘失败时注册表会回滚到旧对象，
/// 原对象被改过的话，「回滚」之后内存和磁盘就不一致了。
- (A2PluginRegistryEntry *)entryForManifest:(A2PluginManifest *)manifest
                                   existing:(nullable A2PluginRegistryEntry *)existing
                                     source:(A2PluginInstallSource *)source
                                packageHash:(NSString *)packageHash {
    A2PluginRegistryEntry *entry = existing
        ? [A2PluginRegistryEntry entryWithDictionary:[existing dictionaryRepresentation] error:NULL]
        : [A2PluginRegistryEntry new];
    if (!entry) entry = [A2PluginRegistryEntry new];

    NSSet<NSString *> *previouslyOffered = existing
        ? A2PermissionIdsOfCanonicalSet(existing.permissionSet)
        : [NSSet set];
    NSSet<NSString *> *previouslyGranted = existing
        ? [NSSet setWithArray:existing.permissionsGranted ?: @[]]
        : [NSSet set];

    // 低/中权限：已经授予过的沿用；这次新申请的默认开；曾申请过却没授予的算用户关掉的，保持关。
    NSMutableArray<NSString *> *granted = [NSMutableArray array];
    NSMutableArray<A2PluginCriticalGrant *> *criticalGrants = [NSMutableArray array];
    for (NSString *permissionId in manifest.permissions) {
        A2PluginRisk risk = A2PluginRiskForPermission(permissionId);
        if (risk == A2PluginRiskCritical) continue;      // critical 只能靠三次确认授予
        if ([previouslyGranted containsObject:permissionId]
            || ![previouslyOffered containsObject:permissionId]) {
            [granted addObject:permissionId];
        }
    }
    // critical 授权：权限还在就继续有效（不因升级重确认），权限没了就自动撤销（4.5）
    for (A2PluginCriticalGrant *grant in existing.criticalGrants ?: @[]) {
        if ([manifest hasPermission:grant.permissionId]) [criticalGrants addObject:grant];
    }

    BOOL grantsChanged = existing
        && (![[NSSet setWithArray:granted] isEqualToSet:previouslyGranted]
            || criticalGrants.count != existing.criticalGrants.count);

    entry.pluginId = manifest.pluginId;
    entry.version = manifest.version;
    entry.packageHash = packageHash;
    entry.sourceKind = source.kind;
    entry.sourceDetail = source.detail;
    entry.sourceInstalledAt = source.installedAt;
    entry.permissionsGranted = granted;
    entry.criticalGrants = criticalGrants;
    entry.permissionSet = [manifest canonicalPermissionSet];
    entry.grantRevision = existing ? existing.grantRevision + (grantsChanged ? 1 : 0) : 0;
    entry.enabled = existing ? existing.isEnabled : YES;
    entry.installedAt = existing.installedAt.length ? existing.installedAt : A2ISO8601Now();
    entry.updatedAt = A2ISO8601Now();
    [entry noteApprovedHash:packageHash];
    return entry;
}

#pragma mark 安装

- (nullable A2PluginInstallResult *)installPackageAtURL:(NSURL *)url
                                                 source:(A2PluginInstallSource *)source
                                                  error:(NSError **)error {
    if (![source isKindOfClass:A2PluginInstallSource.class]) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorField, @"source",
                                       @"安装需要来源记录（source.kind / detail / installedAt）");
        }
        return nil;
    }

    [self logLine:@"安装开始：%@（来源 %@，细节 %@）",
     url.lastPathComponent ?: @"(未知文件)", source.kind, source.detail ?: @"-"];

    NSError *loadError = nil;
    if (![self.registry loadWithError:&loadError]) {
        [self logLine:@"安装失败：注册表读不出来 —— %@", loadError.localizedDescription];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"注册表读不出来：%@",
                                       loadError.localizedDescription ?: @"未知原因");
        }
        return nil;
    }

    NSString *staging = [self stagingDirectoryForNewInstall];
    if (!staging) {
        [self logLine:@"安装失败：建不出暂存目录（%@）", self.pluginsDirectory];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"建不出暂存目录：%@",
                                       self.pluginsDirectory);
        }
        return nil;
    }
    NSString *root = [staging stringByAppendingPathComponent:@"root"];

    // ① 校验 + 解压 + manifest + 完整性 + 摘要
    A2PluginPackageExtractor *extractor =
        [[A2PluginPackageExtractor alloc] initWithLimits:self.limits];
    NSError *extractError = nil;
    A2PluginPackage *package = [extractor extractPackageAtURL:url
                                                intoDirectory:root
                                                        error:&extractError];
    if (!package) {
        [NSFileManager.defaultManager removeItemAtPath:staging error:NULL];
        [self logLine:@"安装失败：%@（%@）",
         extractError.localizedDescription ?: @"包校验未通过",
         extractError.userInfo[A2PluginErrorCodeKey] ?: @"E_UNKNOWN"];
        if (error) *error = extractError;
        return nil;
    }

    A2PluginManifest *manifest = package.manifest;

    // ② 宿主能力门（4.2 ③）
    if (manifest.type == A2PluginTypeJS && !self.allowsJSPlugins) {
        [NSFileManager.defaultManager removeItemAtPath:staging error:NULL];
        [self logLine:@"安装失败：本版本宿主不支持 JS 插件（%@ %@）",
         manifest.pluginId, manifest.version];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorTypeUnsupported, nil,
                                       @"本版本的 Air2 还不支持 JS 插件（P3a 起支持）");
        }
        return nil;
    }

    [self logLine:@"校验通过：%@ %@，%lu 个文件，内容 %@",
     manifest.pluginId, manifest.version, (unsigned long)manifest.files.count,
     [package.contentHash substringToIndex:MIN((NSUInteger)12, package.contentHash.length)]];

    // ③ 版本规则（4.5）
    A2PluginRegistryEntry *existing = [self.registry entryForPluginId:manifest.pluginId];
    NSString *packageHash = A2HashStringForDigest(package.contentHash);

    if (existing) {
        NSString *existingDigest = A2DigestOfHashString(existing.packageHash);
        if ([existingDigest isEqualToString:package.contentHash]) {
            [NSFileManager.defaultManager removeItemAtPath:staging error:NULL];
            [self logLine:@"同一份内容已装过（%@ %@），本次只做校验，不动磁盘",
             manifest.pluginId, manifest.version];

            A2PluginInstallResult *reused = [A2PluginInstallResult new];
            reused.entry = existing;
            reused.contentHash = package.contentHash;
            reused.reusedExisting = YES;
            return reused;
        }

        if ([existing.version isEqualToString:manifest.version]) {
            [NSFileManager.defaultManager removeItemAtPath:staging error:NULL];
            [self logLine:@"安装失败：同版本内容不同（%@ %@），可能是被替换的包",
             manifest.pluginId, manifest.version];
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorSameVersionDifferentContent, @"version",
                                           @"%@ 的 %@ 已装过另一份内容：同版本内容不同，"
                                           @"可能是被替换的包", manifest.pluginId, manifest.version);
            }
            return nil;
        }

        if (A2PluginCompareVersions(manifest.version, existing.version) < 0 && !self.allowsDowngrade) {
            [NSFileManager.defaultManager removeItemAtPath:staging error:NULL];
            [self logLine:@"安装失败：降级被拒（已装 %@，本次 %@；未开开发者模式）",
             existing.version, manifest.version];
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorDowngrade, @"version",
                                           @"默认不允许降级安装：已装 %@，本次 %@",
                                           existing.version, manifest.version);
            }
            return nil;
        }
        if (A2PluginCompareVersions(manifest.version, existing.version) < 0) {
            [self logLine:@"开发者模式放行降级：%@ → %@", existing.version, manifest.version];
        }
    }

    // ④ 换目录（同卷 rename，原子）
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *pluginDirectory =
        [self.pluginsDirectory stringByAppendingPathComponent:manifest.pluginId];
    NSString *target = [pluginDirectory stringByAppendingPathComponent:manifest.version];

    if (![fileManager createDirectoryAtPath:pluginDirectory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:NULL]) {
        [fileManager removeItemAtPath:staging error:NULL];
        [self logLine:@"安装失败：建不出插件目录（%@）", pluginDirectory];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"建不出插件目录：%@", pluginDirectory);
        }
        return nil;
    }

    // 目标已存在而注册表没指向它 = 上次「目录就位、注册表没写成」的孤儿（4.2 ⑥ 之后失败）
    if ([fileManager fileExistsAtPath:target]) {
        [self logLine:@"目标目录是上次留下的孤儿，先清掉：%@", target];
        if (![fileManager removeItemAtPath:target error:NULL]) {
            [fileManager removeItemAtPath:staging error:NULL];
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorIO, nil,
                                           @"清不掉上次留下的目录：%@", target);
            }
            return nil;
        }
    }

    if (!A2RenamePath(root, target)) {
        int renameErrno = errno;      // 先抓住：后面的清理会改写 errno
        [fileManager removeItemAtPath:staging error:NULL];
        [self logLine:@"安装失败：换目录失败（%s）", strerror(renameErrno)];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"换目录失败：%s",
                                       strerror(renameErrno));
        }
        return nil;
    }
    [self logLine:@"换目录完成：%@", target];

    // ⑤ 写注册表
    A2PluginRegistryEntry *entry = [self entryForManifest:manifest
                                                 existing:existing
                                                   source:source
                                              packageHash:packageHash];
    NSError *upsertError = nil;
    if (![self.registry upsertEntry:entry error:&upsertError]) {
        [fileManager removeItemAtPath:staging error:NULL];
        [self logLine:@"安装失败：注册表写不下去 —— %@（目录已就位，下次启动按孤儿清理）",
         upsertError.localizedDescription ?: @"未知原因"];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil,
                                       @"注册表写不下去：%@",
                                       upsertError.localizedDescription ?: @"未知原因");
        }
        return nil;
    }
    [self logLine:@"写 registry 完成：%@ %@，seq=%ld",
     manifest.pluginId, manifest.version, (long)self.registry.seq];

    // ⑥ 保留上一版：先清掉更早的保留版（4.5：每个插件最多留 1 个旧版本目录），再把旧目录收进来
    if (existing && existing.version.length) {
        NSString *oldDirectory = [pluginDirectory stringByAppendingPathComponent:existing.version];
        BOOL oldDirectoryIsSeparate = ![existing.version isEqualToString:manifest.version];
        if (oldDirectoryIsSeparate && [fileManager fileExistsAtPath:oldDirectory]) {
            if (![fileManager createDirectoryAtPath:self.packagesDirectory
                        withIntermediateDirectories:YES
                                         attributes:nil
                                              error:NULL]) {
                [self logLine:@"上一版没能保留：建不出 %@", self.packagesDirectory];
            } else {
                for (NSString *stale in [self retainedDirectoriesForPluginId:manifest.pluginId]) {
                    [fileManager removeItemAtPath:stale error:NULL];
                }
                NSString *retained = [self retainedDirectoryForPluginId:manifest.pluginId
                                                                digest:A2DigestOfHashString(existing.packageHash)];
                [fileManager removeItemAtPath:retained error:NULL];
                if (A2RenamePath(oldDirectory, retained)) {
                    [self logLine:@"上一版已保留：%@", retained];
                } else {
                    // 不阻断安装：新版本已经装好并注册，旧目录留着下次启动按孤儿清理
                    [self logLine:@"上一版没能保留（%s）：%@", strerror(errno), oldDirectory];
                }
            }
        }
    }

    [fileManager removeItemAtPath:staging error:NULL];
    [self logLine:@"安装完成：%@ %@", manifest.pluginId, manifest.version];

    A2PluginInstallResult *result = [A2PluginInstallResult new];
    result.entry = entry;
    result.contentHash = package.contentHash;
    result.reusedExisting = NO;
    return result;
}

#pragma mark 读取已安装 manifest

- (nullable A2PluginManifest *)installedManifestForPluginId:(NSString *)pluginId
                                                     error:(NSError **)error {
    if (pluginId.length == 0) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorField, @"id", @"读取 manifest 需要插件 id");
        }
        return nil;
    }

    // 先重读注册表：目录名来自 registry.version，用内存里的旧版本号会读到已删的目录。
    NSError *loadError = nil;
    if (![self.registry loadWithError:&loadError]) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"注册表读不出来：%@",
                                       loadError.localizedDescription ?: @"未知原因");
        }
        return nil;
    }
    A2PluginRegistryEntry *entry = [self.registry entryForPluginId:pluginId];
    if (!entry) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, @"id", @"注册表里没有 %@", pluginId);
        }
        return nil;
    }

    NSString *versionDirectory =
        [self.pluginsDirectory stringByAppendingPathComponent:pluginId];
    NSString *manifestPath =
        [[versionDirectory stringByAppendingPathComponent:entry.version]
            stringByAppendingPathComponent:@"manifest.json"];
    NSError *fileError = nil;
    NSData *data = [NSData dataWithContentsOfFile:manifestPath
                                          options:0
                                            error:&fileError];
    if (!data) {
        [self logLine:@"读不到已安装的 manifest：%@（%@）", manifestPath,
         fileError.localizedDescription ?: @"未知原因"];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil,
                                       @"安装目录里没有可读的 manifest.json：%@",
                                       fileError.localizedDescription ?: @"未知原因");
        }
        return nil;
    }

    NSError *manifestError = nil;
    A2PluginManifest *manifest = [A2PluginManifest manifestWithData:data
                                                             limits:self.limits
                                                              error:&manifestError];
    if (!manifest) {
        // 校验不过 = 装好的包被改过或损坏 —— 不降级放行，交给上层判「不可用」。
        [self logLine:@"已安装的 manifest 校验不过：%@（%@）",
         pluginId, manifestError.localizedDescription ?: @"未知原因"];
        if (error) *error = manifestError;
        return nil;
    }
    return manifest;
}

- (BOOL)applyEnabled:(BOOL)enabled forPluginId:(NSString *)pluginId error:(NSError **)error {
    if (pluginId.length == 0) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorField, @"id", @"启用 / 停用需要插件 id");
        }
        return NO;
    }

    NSError *loadError = nil;
    if (![self.registry loadWithError:&loadError]) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"注册表读不出来：%@",
                                       loadError.localizedDescription ?: @"未知原因");
        }
        return NO;
    }
    A2PluginRegistryEntry *entry = [self.registry entryForPluginId:pluginId];
    if (!entry) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorField, @"id", @"注册表里没有 %@", pluginId);
        }
        return NO;
    }
    if (entry.isEnabled == enabled) return YES;      // 幂等：状态没变就不写盘

    entry.enabled = enabled;
    entry.updatedAt = A2ISO8601Now();
    NSError *writeError = nil;
    if (![self.registry upsertEntry:entry error:&writeError]) {
        entry.enabled = !enabled;                    // 内存回滚，保持「界面 == 磁盘」
        if (error) *error = writeError;
        return NO;
    }
    [self logLine:@"用户%@插件：%@", enabled ? @"启用" : @"停用", pluginId];
    return YES;
}

#pragma mark 卸载

- (BOOL)uninstallPluginId:(NSString *)pluginId error:(NSError **)error {
    if (pluginId.length == 0) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorField, @"id", @"卸载需要插件 id");
        }
        return NO;
    }
    [self logLine:@"卸载开始：%@", pluginId];

    NSError *loadError = nil;
    if (![self.registry loadWithError:&loadError]) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"注册表读不出来：%@",
                                       loadError.localizedDescription ?: @"未知原因");
        }
        return NO;
    }

    A2PluginRegistryEntry *entry = [self.registry entryForPluginId:pluginId];
    if (!entry) {
        [self logLine:@"卸载跳过：%@ 本来就没装", pluginId];
        return YES;      // 幂等：没装过也算卸干净了
    }
    if ([self.builtinPluginIds containsObject:pluginId]) {
        [self logLine:@"卸载被拒：%@ 是随 App 打包的内置插件", pluginId];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorBuiltin, nil,
                                       @"%@ 随 Air2 一起提供，不能卸载", pluginId);
        }
        return NO;
    }

    // 先删条目：注册表是唯一事实来源，条目没了这个插件就不再被加载
    NSError *removeError = nil;
    if (![self.registry removeEntryForPluginId:pluginId error:&removeError]) {
        [self logLine:@"卸载失败：注册表条目删不下去 —— %@",
         removeError.localizedDescription ?: @"未知原因"];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"注册表条目删不下去：%@",
                                       removeError.localizedDescription ?: @"未知原因");
        }
        return NO;
    }

    // 再删目录。删不干净不算失败：下次启动按孤儿目录清理（4.6 第 3 条）
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *pluginDirectory = [self.pluginsDirectory stringByAppendingPathComponent:pluginId];
    NSError *fileError = nil;
    if ([fileManager fileExistsAtPath:pluginDirectory]
        && ![fileManager removeItemAtPath:pluginDirectory error:&fileError]) {
        [self logLine:@"目录没删干净（%@）：下次启动按孤儿目录清理", fileError.localizedDescription];
    }
    for (NSString *retained in [self retainedDirectoriesForPluginId:pluginId]) {
        if (![fileManager removeItemAtPath:retained error:NULL]) {
            [self logLine:@"保留版目录没删干净：%@", retained];
        }
    }

    [self logLine:@"卸载完成：%@", pluginId];
    return YES;
}

#pragma mark 回退

- (BOOL)rollbackPluginId:(NSString *)pluginId error:(NSError **)error {
    if (pluginId.length == 0) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorField, @"id", @"回退需要插件 id");
        }
        return NO;
    }
    [self logLine:@"回退开始：%@", pluginId];

    NSError *loadError = nil;
    if (![self.registry loadWithError:&loadError]) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"注册表读不出来：%@",
                                       loadError.localizedDescription ?: @"未知原因");
        }
        return NO;
    }

    A2PluginRegistryEntry *entry = [self.registry entryForPluginId:pluginId];
    if (!entry) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorNoPreviousVersion, nil,
                                       @"%@ 没有装过，没有可回退的版本", pluginId);
        }
        return NO;
    }

    NSArray<NSString *> *retained = [self retainedDirectoriesForPluginId:pluginId];
    if (retained.count == 0) {
        [self logLine:@"回退失败：%@ 没有保留的上一版", pluginId];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorNoPreviousVersion, nil,
                                       @"%@ 没有保留的上一版（升级后才会保留）", pluginId);
        }
        return NO;
    }
    if (retained.count > 1) {
        // 正常流程只留一版；多出来的是崩溃残渣，取最新的那一版，其余留着让孤儿清理收走
        [self logLine:@"发现 %lu 个保留版目录，取最新的那个", (unsigned long)retained.count];
    }
    NSString *retainedDirectory = retained.firstObject;
    NSString *retainedDigest =
        [retainedDirectory.lastPathComponent componentsSeparatedByString:kRetainedSeparator].lastObject;
    if (retainedDigest.length != 64) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil,
                                       @"保留版目录名里没有内容哈希：%@",
                                       retainedDirectory.lastPathComponent);
        }
        return NO;
    }

    // 保留目录里那份 manifest 才是「上一版」的真身：版本号与权限集都从它来
    NSString *manifestPath = [retainedDirectory stringByAppendingPathComponent:@"manifest.json"];
    NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath];
    if (!manifestData) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"保留版里没有 manifest.json：%@",
                                       retainedDirectory);
        }
        return NO;
    }
    NSError *manifestError = nil;
    A2PluginManifest *oldManifest = [A2PluginManifest manifestWithData:manifestData
                                                               limits:self.limits
                                                                error:&manifestError];
    if (!oldManifest) {
        [self logLine:@"回退失败：保留版的 manifest 校验不过 —— %@",
         manifestError.localizedDescription ?: @"未知原因"];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil,
                                       @"保留版的 manifest 校验不过：%@",
                                       manifestError.localizedDescription ?: @"未知原因");
        }
        return NO;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *pluginDirectory = [self.pluginsDirectory stringByAppendingPathComponent:pluginId];
    NSString *restoreTarget = [pluginDirectory stringByAppendingPathComponent:oldManifest.version];

    // ① 先把保留版换回正式位置（此时注册表还指向当前版本，那个目录也还在 —— 中途中断不产生假状态）
    if ([fileManager fileExistsAtPath:restoreTarget]) {
        [self logLine:@"目标版本目录已存在（残渣），先清掉：%@", restoreTarget];
        if (![fileManager removeItemAtPath:restoreTarget error:NULL]) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorIO, nil,
                                           @"清不掉目标版本目录：%@", restoreTarget);
            }
            return NO;
        }
    }
    if (!A2RenamePath(retainedDirectory, restoreTarget)) {
        int renameErrno = errno;      // 先抓住：后面的清理会改写 errno
        [self logLine:@"回退失败：换目录失败（%s）", strerror(renameErrno)];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"回退换目录失败：%s",
                                       strerror(renameErrno));
        }
        return NO;
    }
    [self logLine:@"换目录完成：%@", restoreTarget];

    // ② 把刚被换下来的当前版本收进 packages/（失败不阻断：注册表指向的目录已经就位）
    NSString *currentDirectory = [pluginDirectory stringByAppendingPathComponent:entry.version];
    if (![entry.version isEqualToString:oldManifest.version]
        && [fileManager fileExistsAtPath:currentDirectory]) {
        if ([fileManager createDirectoryAtPath:self.packagesDirectory
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:NULL]) {
            NSString *retainedNew = [self retainedDirectoryForPluginId:pluginId
                                                               digest:A2DigestOfHashString(entry.packageHash)];
            [fileManager removeItemAtPath:retainedNew error:NULL];
            if (A2RenamePath(currentDirectory, retainedNew)) {
                [self logLine:@"当前版本已收进保留版：%@", retainedNew];
            } else {
                [self logLine:@"当前版本没能收进保留版（%s）", strerror(errno)];
            }
        }
    }

    // ③ 注册表跟着改：版本、哈希、权限集
    A2PluginRegistryEntry *updated =
        [A2PluginRegistryEntry entryWithDictionary:[entry dictionaryRepresentation] error:NULL]
        ?: [A2PluginRegistryEntry new];
    updated.pluginId = pluginId;
    updated.version = oldManifest.version;
    updated.packageHash = A2HashStringForDigest(retainedDigest);
    NSSet<NSString *> *oldPermissions = [NSSet setWithArray:oldManifest.permissions];
    NSMutableArray<NSString *> *granted = [NSMutableArray array];
    for (NSString *permissionId in entry.permissionsGranted ?: @[]) {
        if ([oldPermissions containsObject:permissionId]) [granted addObject:permissionId];
    }
    NSMutableArray<A2PluginCriticalGrant *> *criticalGrants = [NSMutableArray array];
    for (A2PluginCriticalGrant *grant in entry.criticalGrants ?: @[]) {
        if ([oldPermissions containsObject:grant.permissionId]) [criticalGrants addObject:grant];
    }
    updated.permissionsGranted = granted;
    updated.criticalGrants = criticalGrants;
    updated.permissionSet = [oldManifest canonicalPermissionSet];
    updated.grantRevision = entry.grantRevision + 1;
    updated.updatedAt = A2ISO8601Now();
    [updated noteApprovedHash:updated.packageHash];

    NSError *upsertError = nil;
    if (![self.registry upsertEntry:updated error:&upsertError]) {
        [self logLine:@"回退失败：注册表写不下去 —— %@",
         upsertError.localizedDescription ?: @"未知原因"];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"注册表写不下去：%@",
                                       upsertError.localizedDescription ?: @"未知原因");
        }
        return NO;
    }

    [self logLine:@"回退完成：%@ %@ → %@", pluginId, entry.version, oldManifest.version];
    return YES;
}

@end
