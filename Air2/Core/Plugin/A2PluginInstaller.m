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
//  ## 贡献点（P2 第一步）的三条接线
//
//  安装成功 ⇒ `applyContributionSet:`；卸载 / 停用 ⇒ `removeContributionsForPlugin:`（幂等）。
//  接入点在**换目录之前**：贡献点在安装期唯一的失败原因是设置项键被别的插件占用
//  （`E_SLOT_CONFLICT`），文档要求「冲突在安装期拒装」（PLUGIN-SYSTEM 5.2 / DECISIONS 决策 6），
//  所以要赶在任何落盘之前 —— 装完再发现冲突，目录与 registry 都得回滚。
//  接入之后到安装成功之间的每条失败分支都会撤回（`withdrawContributionsForPluginId:`）：
//  贡献点注册表是运行时缓存，下次启动 Phase A 按磁盘重建，不会留下永久错位。
//

#import "A2PluginInstaller.h"

#import <errno.h>
#import <stdio.h>
#import <string.h>

#import "A2Log.h"
#import "A2PluginLaunchChainRisk.h"   // 启动链判据集合（10 次免责确认的触发条件）
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

/// 当前宿主里程碑 —— 唯一判据是 `allowsJSPlugins`。
/// 写两处（能力门一个答案、贡献点校验另一个答案）会让同一个 js 包一层放行一层拒装。
- (A2PluginHostMilestone)contributionHostMilestone;

/// 把一份已验证的贡献集接进注册表，并记一行判据日志（成功写条数、冲突写原因码）。
/// @return 成功 YES；冲突 NO 并给出 `E_SLOT_CONFLICT`（注册表未被改动）。
- (BOOL)attachContributionSet:(A2PluginContributionSet *)set error:(NSError **)error;

/// 把一个插件的贡献从注册表摘掉并记一行判据日志。幂等：不在册也记「0 条」。
- (void)withdrawContributionsForPluginId:(NSString *)pluginId;

/// 读**已装版本**的 manifest 字节重做一次贡献点校验（停用 → 重新启用时用它把贡献接回）。
- (nullable A2PluginContributionSet *)contributionSetForInstalledPluginId:(NSString *)pluginId
                                                                   error:(NSError **)error;
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
        // 贡献点注册表默认自建：装配处换成共享实例之前，「停用 / 卸载 ⇒ 贡献点消失」
        // 也已经成立（见头文件）。
        _contributionRegistry = [A2PluginContributionRegistry new];
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

#pragma mark 贡献点（P2 第一步）

/// 当前宿主里程碑：`allowsJSPlugins` 就是「本宿主阶段有没有 JSCore」。
/// P1 的能力门（`manifest.type == js && !allowsJSPlugins`）与贡献点校验共用这一个判据，
/// 两处各写一份的话，同一个 js 包会被一层放行、一层拒装。
- (A2PluginHostMilestone)contributionHostMilestone {
    return self.allowsJSPlugins ? A2PluginHostMilestoneP3a : A2PluginHostMilestoneP2;
}

- (BOOL)attachContributionSet:(A2PluginContributionSet *)set error:(NSError **)error {
    A2PluginContributionRegistry *contributions = self.contributionRegistry;
    if (!contributions) {
        // 装配处显式置 nil = 明确不接贡献点（离线迁移 / 单测）。不伪造一行「已接入」。
        return YES;
    }

    NSError *applyError = nil;
    if (![contributions applyContributionSet:set error:&applyError]) {
        [self logLine:@"贡献点没能接入注册表：%@（%@）—— %@",
         set.pluginId,
         applyError.userInfo[A2PluginErrorCodeKey] ?: @"E_UNKNOWN",
         applyError.localizedDescription ?: @"未知原因"];
        if (error) *error = applyError;
        return NO;
    }

    NSUInteger count = [contributions contributionCountForPlugin:set.pluginId];
    [self logLine:@"贡献点已接入注册表：%@ %@ 共 %lu 条（slot %lu / 主题 token %lu / 版本装饰 %@）",
     set.pluginId, set.pluginVersion, (unsigned long)count,
     (unsigned long)set.slotContributions.count,
     (unsigned long)set.themeTokens.count,
     set.versionDecoration ? @"有" : @"无"];
    return YES;
}

- (void)withdrawContributionsForPluginId:(NSString *)pluginId {
    A2PluginContributionRegistry *contributions = self.contributionRegistry;
    if (!contributions) return;

    // 先取条数再摘：摘完就查不到了，而日志要的是「移除了多少」。
    NSUInteger count = [contributions contributionCountForPlugin:pluginId];
    if (![contributions removeContributionsForPlugin:pluginId]) {
        [self logLine:@"贡献点无需移除：%@（本来就不在册，0 条）", pluginId];
        return;
    }
    [self logLine:@"贡献点已移出注册表：%@ 共 %lu 条", pluginId, (unsigned long)count];
}

- (nullable A2PluginContributionSet *)contributionSetForInstalledPluginId:(NSString *)pluginId
                                                                   error:(NSError **)error {
    A2PluginRegistryEntry *entry = [self.registry entryForPluginId:pluginId];
    if (!entry) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorField, @"id", @"注册表里没有 %@", pluginId);
        }
        return nil;
    }

    // 路径知识只留在安装器里（ARCHITECTURE：View 不拼路径），与 installedManifestForPluginId: 同一套目录布局。
    NSString *manifestPath =
        [[[self.pluginsDirectory stringByAppendingPathComponent:pluginId]
          stringByAppendingPathComponent:entry.version]
         stringByAppendingPathComponent:@"manifest.json"];
    NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath];
    if (!manifestData) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorManifestMissing, nil,
                                       @"已装版本里没有 manifest.json：%@", manifestPath);
        }
        return nil;
    }

    // 宿主版本只有解包器一处从 Info.plist 取（同一个回落口径），这里借它建一次校验，
    // 不另抄一份「宿主版本怎么来」。
    A2PluginPackageExtractor *extractor = [[A2PluginPackageExtractor alloc] initWithLimits:self.limits];
    extractor.hostMilestone = [self contributionHostMilestone];
    return [A2PluginContributionSet setWithManifestData:manifestData
                                           hostVersion:extractor.hostVersion
                                             milestone:extractor.hostMilestone
                                                 error:error];
}

#pragma mark 安装

- (NSUInteger)attachContributionsForEnabledPlugins {
    if (!self.contributionRegistry) {
        // 装配处显式置 nil = 不接贡献点（与 attachContributionSet: 同一口径，不伪造一行）。
        return 0;
    }

    NSError *loadError = nil;
    if (![self.registry loadWithError:&loadError]) {
        // 读不出来就一条都不接：注册表是唯一事实来源，读不出来时「谁启用着」没有答案。
        [self logLine:@"启动装配跳过：注册表读不出来 —— %@",
         loadError.localizedDescription ?: @"未知原因"];
        return 0;
    }

    NSUInteger enabledCount = 0;
    NSUInteger attachedCount = 0;
    NSUInteger skippedCount = 0;
    for (A2PluginRegistryEntry *entry in [self.registry allEntries]) {
        if (!entry.isEnabled) continue;      // 停用的插件本来就不该在册
        enabledCount++;

        NSError *setError = nil;
        A2PluginContributionSet *set = [self contributionSetForInstalledPluginId:entry.pluginId
                                                                          error:&setError];
        if (!set) {
            skippedCount++;
            [self logLine:@"启动装配跳过 %@：贡献点校验不过（%@）—— %@",
             entry.pluginId,
             setError.userInfo[A2PluginErrorCodeKey] ?: @"E_UNKNOWN",
             setError.localizedDescription ?: @"未知原因"];
            continue;
        }
        if (![self attachContributionSet:set error:NULL]) {
            skippedCount++;                  // 具体原因已由 attachContributionSet: 记过一行
            continue;
        }
        attachedCount++;
    }

    [self logLine:@"启动装配：已启用插件 %lu 个，贡献点接入 %lu 个（跳过 %lu 个）",
     (unsigned long)enabledCount, (unsigned long)attachedCount, (unsigned long)skippedCount];
    return attachedCount;
}

/// 无闸门入口：转发而已（见头文件：会改启动链的包在这里必被拒，不静默放行）。
- (nullable A2PluginInstallResult *)installPackageAtURL:(NSURL *)url
                                                 source:(A2PluginInstallSource *)source
                                                  error:(NSError **)error {
    return [self installPackageAtURL:url
                             source:source
                    launchChainGate:nil
                              error:error];
}

- (nullable A2PluginInstallResult *)installPackageAtURL:(NSURL *)url
                                                 source:(A2PluginInstallSource *)source
                                       launchChainGate:(nullable A2PluginLaunchChainGate)launchChainGate
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

    // ① 校验 + 解压 + manifest + 贡献点 + 完整性 + 摘要
    A2PluginPackageExtractor *extractor =
        [[A2PluginPackageExtractor alloc] initWithLimits:self.limits];
    // 里程碑与 ② 的宿主能力门必须是同一个答案（见 contributionHostMilestone）。
    extractor.hostMilestone = [self contributionHostMilestone];
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

            // 已装过的插件本来就该在贡献点注册表里。重装是修复它的唯一机会（比如上次进程
            // 启动时注册表还没建成），所以这里**顺手接一次**：幂等替换，冲突只记一行、不失败
            // —— 这次安装本身什么都没改，不能因为「别的插件占了同一个设置项键」把重装报错。
            if (package.contributionSet) {
                [self attachContributionSet:package.contributionSet error:NULL];
            }

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

    // ④ ★启动链闸门 = 10 次免责确认★
    // ========================================================================
    // 判据：manifest 申请了会改启动链的权限（唯一判据 = A2PluginLaunchChainRisk）。
    // 时机：★校验 + 版本规则都过了、马上要换目录写 registry 之前★ ——
    //   放到校验之前 ⇒ 用户白点 10 次才被格式/降级规则拦下；
    //   放到写盘之后 ⇒ 已经来不及（注册表里已经有了）。
    // ★不做「已同意」缓存★：每次安装都从头走完 10 次（用户明令）。
    // 取消 / 没有闸门 ⇒ 清暂存、不写 registry、返回 nil（磁盘与注册表都干净）。
    // ========================================================================
    NSArray<NSString *> *launchChainPermissions =
        A2PluginLaunchChainPermissionsForManifest(manifest);
    if (launchChainPermissions.count > 0) {
        [self logLine:@"需要启动链免责确认：%@ 申请了 %lu 项（%@）",
         manifest.pluginId, (unsigned long)launchChainPermissions.count,
         [launchChainPermissions componentsJoinedByString:@","]];
        if (launchChainGate == nil) {
            [NSFileManager.defaultManager removeItemAtPath:staging error:NULL];
            [self logLine:@"安装失败：%@ 会修改启动链，但没有确认闸门 ⇒ 拒装（不把「没问过」当成「已同意」）",
             manifest.pluginId];
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorLaunchChainUnconfirmed, @"permissions",
                                           @"%@ 会修改启动链，安装前需要通过免责确认", manifest.pluginId);
            }
            return nil;
        }
        // ★闸门是同步的、可能在实现里阻塞★（10 次弹窗要等用户点完，见 A2PluginLaunchChainGate）。
        BOOL proceed = launchChainGate(manifest, launchChainPermissions);
        if (!proceed) {
            [NSFileManager.defaultManager removeItemAtPath:staging error:NULL];
            [self logLine:@"用户取消：启动链免责确认未通过 ⇒ 终止安装（暂存已清理，registry 未写）"];
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorUserCancelled, nil,
                                           @"已取消安装：%@ 会修改启动链，免责确认没有通过",
                                           manifest.pluginId);
            }
            return nil;
        }
        [self logLine:@"启动链免责确认通过：%@ —— 继续安装", manifest.pluginId];
    }

    // ④.5 ★把贡献点接进注册表★（P2 第一步）
    // ========================================================================
    // 判据：`A2PluginPackageExtractor` 已把 manifest 的 `ui` / `contributes` 校验成
    //   `package.contributionSet`（校验不过的包在 ① 就拒装了），这里只负责接入。
    // 时机：★换目录 / 写 registry 之前★ —— 这里唯一可能的失败是「设置项键已被别的插件占用」
    //   （`E_SLOT_CONFLICT`），文档要求「冲突在安装期拒装」（PLUGIN-SYSTEM 5.2 / DECISIONS 决策 6）。
    //   放到装完再判，就得回滚目录与 registry 两处状态。
    // 代价：接入成功到安装成功之间有一小段窗口；窗口内失败一律 withdraw（下面每条失败分支都有），
    //   注册表是运行时缓存，下次启动 Phase A 按磁盘重建，不会留下永久错位。
    // ========================================================================
    A2PluginContributionSet *contributionSet = package.contributionSet;
    if (contributionSet) {
        NSError *contributionError = nil;
        if (![self attachContributionSet:contributionSet error:&contributionError]) {
            [NSFileManager.defaultManager removeItemAtPath:staging error:NULL];
            [self logLine:@"安装失败：贡献点与已装插件冲突（%@）—— 暂存已清理，registry 未写",
             contributionError.userInfo[A2PluginErrorCodeKey] ?: @"E_UNKNOWN"];
            if (error) *error = contributionError;
            return nil;
        }
    }

    // ⑤ 换目录（同卷 rename，原子）
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
        [self withdrawContributionsForPluginId:manifest.pluginId];
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
            [self logLine:@"安装失败：清不掉上次留下的目录（%@）", target];
            [self withdrawContributionsForPluginId:manifest.pluginId];
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
        [self withdrawContributionsForPluginId:manifest.pluginId];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"换目录失败：%s",
                                       strerror(renameErrno));
        }
        return nil;
    }
    [self logLine:@"换目录完成：%@", target];

    // ⑥ 写注册表
    A2PluginRegistryEntry *entry = [self entryForManifest:manifest
                                                 existing:existing
                                                   source:source
                                              packageHash:packageHash];
    NSError *upsertError = nil;
    if (![self.registry upsertEntry:entry error:&upsertError]) {
        [fileManager removeItemAtPath:staging error:NULL];
        [self logLine:@"安装失败：注册表写不下去 —— %@（目录已就位，下次启动按孤儿清理）",
         upsertError.localizedDescription ?: @"未知原因"];
        [self withdrawContributionsForPluginId:manifest.pluginId];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil,
                                       @"注册表写不下去：%@",
                                       upsertError.localizedDescription ?: @"未知原因");
        }
        return nil;
    }
    [self logLine:@"写 registry 完成：%@ %@，seq=%ld",
     manifest.pluginId, manifest.version, (long)self.registry.seq];

    // ⑦ 保留上一版：先清掉更早的保留版（4.5：每个插件最多留 1 个旧版本目录），再把旧目录收进来
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

    // 贡献点跟着开关走：停用 ⇒ 立刻摘掉（不等下次启动）；启用 ⇒ 重新校验后接回去。
    // 位置在写盘成功之后：registry 写不进去时内存已经回滚，贡献点也不该先动。
    if (!enabled) {
        [self withdrawContributionsForPluginId:pluginId];
        return YES;
    }

    // 重新启用：从**已装版本**的 manifest 重做一次同样的贡献点校验再接入。
    // 失败不改变「启用成功」这个结果 —— 开关已经写进 registry 了，回滚开关比少几条贡献更糟；
    // 记一行说明，下次启动 Phase A 会重新接入。
    NSError *contributionError = nil;
    A2PluginContributionSet *set = [self contributionSetForInstalledPluginId:pluginId
                                                                       error:&contributionError];
    if (!set) {
        [self logLine:@"启用后贡献点没能接回：%@（%@）—— %@；下次启动 Phase A 会重新接入",
         pluginId, contributionError.userInfo[A2PluginErrorCodeKey] ?: @"E_UNKNOWN",
         contributionError.localizedDescription ?: @"未知原因"];
        return YES;
    }
    [self attachContributionSet:set error:NULL];
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
        [self withdrawContributionsForPluginId:pluginId];   // 幂等：注册表与贡献点都可能已经在
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

    // 条目没了，贡献点也要立刻消失：留着它会让 UI 继续画一个已经不存在的插件的东西。
    [self withdrawContributionsForPluginId:pluginId];

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

    // ④ 贡献点跟着回退后的版本走：换回的是「上一版能贡献什么」，不是当前版的。
    // 回退失败不影响回退结果（目录与 registry 都已就位），失败只记一行，下次启动 Phase A 重建。
    [self withdrawContributionsForPluginId:pluginId];
    A2PluginContributionSet *rolledBackSet =
        [self contributionSetForInstalledPluginId:pluginId error:NULL];
    if (rolledBackSet) {
        [self attachContributionSet:rolledBackSet error:NULL];
    }

    [self logLine:@"回退完成：%@ %@ → %@", pluginId, entry.version, oldManifest.version];
    return YES;
}

@end
