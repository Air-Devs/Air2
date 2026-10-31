//
//  A2PluginRegistry.m
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
//  见头文件。这里只有三件事：把表读出来、把表整份原子写回去、按 id 取放条目。
//  「什么情况下该写」（授权、启停、卸载）属于上层，本文件不做业务判断。
//

#import "A2PluginRegistry.h"
#import "A2PluginManifest.h"

#import <TargetConditionals.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <unistd.h>

const NSUInteger A2PluginRegistryMaxApprovedHashes = 5;
const NSInteger A2PluginRegistryFormatVersion = 3;
NSString *const A2PluginRegistryErrorDomain = @"dev.airdevs.air2.plugin.registry";

#pragma mark - 错误

static BOOL A2RegistryFail(NSError **error, A2PluginRegistryError code, NSString *_Nullable field,
                           NSString *format, ...) NS_FORMAT_FUNCTION(4, 5);

static BOOL A2RegistryFail(NSError **error, A2PluginRegistryError code, NSString *_Nullable field,
                           NSString *format, ...) {
    if (!error) return NO;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message ?: @"注册表操作失败";
    if (field.length) userInfo[A2PluginErrorFieldKey] = field;
    *error = [NSError errorWithDomain:A2PluginRegistryErrorDomain code:code userInfo:userInfo];
    return NO;
}

#pragma mark - 小工具

/// 来源种类枚举（PLUGIN-SYSTEM 6.1：四种，不做信任判断）。
static NSSet<NSString *> *A2SourceKinds(void) {
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"local-import", @"url", @"share-sheet", @"dev-dir"]];
    });
    return set;
}

/// `sha256:` 前缀可选，主体 64 位小写 hex。
static BOOL A2IsValidHashString(NSString *hash) {
    if (![hash isKindOfClass:NSString.class]) return NO;
    NSString *digest = hash;
    if ([hash hasPrefix:@"sha256:"]) digest = [hash substringFromIndex:7];
    if (digest.length != 64) return NO;
    for (NSUInteger i = 0; i < digest.length; i++) {
        unichar c = [digest characterAtIndex:i];
        BOOL ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!ok) return NO;
    }
    return YES;
}

/// 去前缀 + 小写，用于「同一个哈希的两种写法」判重。
static NSString *A2NormalizedHash(NSString *hash) {
    NSString *digest = [hash hasPrefix:@"sha256:"] ? [hash substringFromIndex:7] : hash;
    return digest.lowercaseString ?: @"";
}

/// 原子写：建目录 → 写临时文件 → fsync → rename → fsync 目录。
/// 崩溃后读到的永远是完整的一版，不存在「半截 JSON」。
static BOOL A2AtomicWriteData(NSString *path, NSData *data, NSError **error) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *directory = [path stringByDeletingLastPathComponent];
    NSError *directoryError = nil;
    if (![fileManager createDirectoryAtPath:directory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&directoryError]) {
        return A2RegistryFail(error, A2PluginRegistryErrorWrite, nil,
                              @"创建目录 %@ 失败：%@", directory,
                              directoryError.localizedDescription ?: @"未知原因");
    }

    NSString *tempPath = [directory stringByAppendingPathComponent:
                          [NSString stringWithFormat:@".%@.%@.tmp",
                           path.lastPathComponent, NSUUID.UUID.UUIDString]];
    const char *tempCString = [tempPath fileSystemRepresentation];
    int fd = open(tempCString, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        return A2RegistryFail(error, A2PluginRegistryErrorWrite, nil,
                              @"创建临时文件失败：%s", strerror(errno));
    }

    BOOL ok = YES;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t written = write(fd, bytes + offset, data.length - offset);
        if (written <= 0) {
            ok = NO;
            break;
        }
        offset += (NSUInteger)written;
    }
    if (ok && fsync(fd) != 0) ok = NO;
    if (close(fd) != 0) ok = NO;

    if (!ok) {
        int savedErrno = errno;
        unlink(tempCString);
        return A2RegistryFail(error, A2PluginRegistryErrorWrite, nil,
                              @"写临时文件失败：%s", strerror(savedErrno));
    }

    if (rename(tempCString, [path fileSystemRepresentation]) != 0) {
        int savedErrno = errno;
        unlink(tempCString);
        return A2RegistryFail(error, A2PluginRegistryErrorWrite, nil,
                              @"替换 registry.json 失败：%s", strerror(savedErrno));
    }

    // rename 只保证「名字换掉了」，目录项本身还要 fsync 才能保证掉电后仍在。
    int dirFD = open([directory fileSystemRepresentation], O_RDONLY);
    if (dirFD >= 0) {
        fsync(dirFD);
        close(dirFD);
    }

#if TARGET_OS_IOS
    // 与插件目录同一保护等级：设备首次解锁后可读（后台加载需要），
    // 不做 Complete 级别的强保护（那会让后台启动读不到表）。
    [fileManager setAttributes:@{NSFileProtectionKey:
                                     NSFileProtectionCompleteUntilFirstUserAuthentication}
                   ofItemAtPath:path
                          error:NULL];
#endif
    return YES;
}

#pragma mark - critical 授权记录

@interface A2PluginCriticalGrant ()
@property (nonatomic, copy) NSString *permissionId;
@property (nonatomic, copy) NSString *grantedAt;
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *hostVersion;
@property (nonatomic, assign) NSInteger majorVersion;
@end

@implementation A2PluginCriticalGrant

+ (nullable instancetype)grantWithDictionary:(NSDictionary<NSString *, id> *)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    id permissionId = dictionary[@"permissionId"];
    id grantedAt = dictionary[@"grantedAt"];
    if (![permissionId isKindOfClass:NSString.class] ||
        ![grantedAt isKindOfClass:NSString.class]) {
        return nil;
    }
    if ([(NSString *)permissionId length] == 0 || [(NSString *)grantedAt length] == 0) return nil;

    A2PluginCriticalGrant *grant = [[A2PluginCriticalGrant alloc] init];
    grant.permissionId = permissionId;
    grant.grantedAt = grantedAt;

    id method = dictionary[@"method"];
    grant.method = [method isKindOfClass:NSString.class] ? method : @"three-step";
    id hostVersion = dictionary[@"hostVersion"];
    grant.hostVersion = [hostVersion isKindOfClass:NSString.class] ? hostVersion : @"";
    id majorVersion = dictionary[@"majorVersion"];
    if ([majorVersion isKindOfClass:NSNumber.class]) {
        NSNumber *number = (NSNumber *)majorVersion;
        grant.majorVersion = number.integerValue;
    }
    return grant;
}

- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    return @{
        @"permissionId": self.permissionId ?: @"",
        @"grantedAt": self.grantedAt ?: @"",
        @"method": self.method ?: @"three-step",
        @"hostVersion": self.hostVersion ?: @"",
        @"majorVersion": @(self.majorVersion),
    };
}

@end

#pragma mark - 条目

@interface A2PluginRegistryEntry ()
@property (nonatomic, copy) NSArray<NSString *> *approvedHashes;
@end

@implementation A2PluginRegistryEntry

- (instancetype)init {
    self = [super init];
    if (self) {
        _pluginId = @"";
        _version = @"";
        _packageHash = @"";
        _sourceKind = @"local-import";
        _sourceInstalledAt = @"";
        _permissionsGranted = @[];
        _criticalGrants = @[];
        _permissionSet = @"";
        _approvedHashes = @[];
        _grantRevision = 0;
        _enabled = YES;
        _installedAt = @"";
        _updatedAt = @"";
    }
    return self;
}

- (BOOL)noteApprovedHash:(NSString *)packageHash {
    if (!A2IsValidHashString(packageHash)) return NO;
    NSString *key = A2NormalizedHash(packageHash);
    NSMutableArray<NSString *> *updated = [NSMutableArray arrayWithCapacity:
                                           A2PluginRegistryMaxApprovedHashes];
    [updated addObject:packageHash];
    for (NSString *existing in self.approvedHashes) {
        if (updated.count >= A2PluginRegistryMaxApprovedHashes) break;
        if (![existing isKindOfClass:NSString.class]) continue;
        if ([A2NormalizedHash(existing) isEqualToString:key]) continue;
        [updated addObject:existing];
    }
    self.approvedHashes = updated;
    return YES;
}

- (BOOL)validateWithError:(NSError **)error {
    if (!A2PluginIsValidIdentifier(self.pluginId ?: @"")) {
        return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, @"id",
                              @"插件 id「%@」不合法", self.pluginId ?: @"(空)");
    }
    if (!A2PluginIsValidVersion(self.version ?: @"")) {
        return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, @"version",
                              @"版本「%@」不是语义化版本", self.version ?: @"(空)");
    }
    if (!A2IsValidHashString(self.packageHash ?: @"")) {
        return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, @"packageHash",
                              @"packageHash 必须是 sha256:<64 位小写 hex>");
    }
    if (![A2SourceKinds() containsObject:self.sourceKind ?: @""]) {
        return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, @"source.kind",
                              @"source.kind「%@」不在枚举内（local-import / url / share-sheet / dev-dir）",
                              self.sourceKind ?: @"(空)");
    }
    if (!self.sourceInstalledAt.length) {
        return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, @"source.installedAt",
                              @"source.installedAt 不能为空");
    }
    if (!self.installedAt.length) {
        return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, @"installedAt",
                              @"installedAt 不能为空");
    }
    if (!self.updatedAt.length) {
        return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, @"updatedAt",
                              @"updatedAt 不能为空");
    }
    if (self.grantRevision < 0) {
        return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, @"grantRevision",
                              @"grantRevision 不能为负");
    }
    if (self.approvedHashes.count > A2PluginRegistryMaxApprovedHashes) {
        return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, @"approvedHashes",
                              @"approvedHashes 最多 %lu 项",
                              (unsigned long)A2PluginRegistryMaxApprovedHashes);
    }
    for (NSString *hash in self.approvedHashes) {
        if (!A2IsValidHashString(hash)) {
            return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, @"approvedHashes",
                                  @"approvedHashes 里有非法哈希「%@」", hash);
        }
    }
    for (A2PluginCriticalGrant *grant in self.criticalGrants) {
        if (![grant isKindOfClass:A2PluginCriticalGrant.class]) {
            return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, @"criticalGrants",
                                  @"criticalGrants 里有非 grant 对象");
        }
        if (!grant.permissionId.length || !grant.grantedAt.length) {
            return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, @"criticalGrants",
                                  @"criticalGrants 的每一项都需要 permissionId 与 grantedAt");
        }
    }
    return YES;
}

+ (nullable instancetype)entryWithDictionary:(NSDictionary<NSString *, id> *)dictionary
                                       error:(NSError **)error {
    if (![dictionary isKindOfClass:NSDictionary.class]) {
        A2RegistryFail(error, A2PluginRegistryErrorFormat, nil, @"条目必须是对象");
        return nil;
    }
    id pluginId = dictionary[@"id"];
    if (![pluginId isKindOfClass:NSString.class]) {
        A2RegistryFail(error, A2PluginRegistryErrorFormat, @"id", @"条目缺少 id");
        return nil;
    }

    A2PluginRegistryEntry *entry = [[A2PluginRegistryEntry alloc] init];
    entry.pluginId = pluginId;

    id version = dictionary[@"version"];
    entry.version = [version isKindOfClass:NSString.class] ? version : @"";
    id packageHash = dictionary[@"packageHash"];
    entry.packageHash = [packageHash isKindOfClass:NSString.class] ? packageHash : @"";

    id source = dictionary[@"source"];
    if ([source isKindOfClass:NSDictionary.class]) {
        NSDictionary *sourceDict = (NSDictionary *)source;
        id kind = sourceDict[@"kind"];
        if ([kind isKindOfClass:NSString.class]) entry.sourceKind = kind;
        id detail = sourceDict[@"sourceDetail"];
        entry.sourceDetail = [detail isKindOfClass:NSString.class] ? detail : nil;
        id installedAt = sourceDict[@"installedAt"];
        entry.sourceInstalledAt = [installedAt isKindOfClass:NSString.class] ? installedAt : @"";
    }

    NSMutableArray<NSString *> *granted = [NSMutableArray array];
    id permissionsGranted = dictionary[@"permissionsGranted"];
    if ([permissionsGranted isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)permissionsGranted) {
            if ([item isKindOfClass:NSString.class]) [granted addObject:item];
        }
    }
    entry.permissionsGranted = granted;

    NSMutableArray<A2PluginCriticalGrant *> *grants = [NSMutableArray array];
    id criticalGrants = dictionary[@"criticalGrants"];
    if ([criticalGrants isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)criticalGrants) {
            A2PluginCriticalGrant *grant = [A2PluginCriticalGrant grantWithDictionary:item];
            if (!grant) {
                A2RegistryFail(error, A2PluginRegistryErrorFormat, @"criticalGrants",
                               @"criticalGrants 里有损坏的条目");
                return nil;
            }
            [grants addObject:grant];
        }
    }
    entry.criticalGrants = grants;

    id permissionSet = dictionary[@"permissionSet"];
    entry.permissionSet = [permissionSet isKindOfClass:NSString.class] ? permissionSet : @"";

    // 白名单只取证、不授权：读的时候顺手截掉超出 5 个的尾部（写回去时自然收敛），
    // 损坏的哈希直接丢弃而不是让整张表读不出来。
    NSMutableArray<NSString *> *hashes = [NSMutableArray array];
    id approvedHashes = dictionary[@"approvedHashes"];
    if ([approvedHashes isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)approvedHashes) {
            if (hashes.count >= A2PluginRegistryMaxApprovedHashes) break;
            if (![item isKindOfClass:NSString.class]) continue;
            if (!A2IsValidHashString(item)) continue;
            [hashes addObject:item];
        }
    }
    entry.approvedHashes = hashes;

    id grantRevision = dictionary[@"grantRevision"];
    if ([grantRevision isKindOfClass:NSNumber.class]) {
        entry.grantRevision = [(NSNumber *)grantRevision integerValue];
    }
    id enabled = dictionary[@"enabled"];
    if ([enabled isKindOfClass:NSNumber.class]) {
        entry.enabled = [(NSNumber *)enabled boolValue];
    }

    id installedAt = dictionary[@"installedAt"];
    entry.installedAt = [installedAt isKindOfClass:NSString.class] ? installedAt : @"";
    id updatedAt = dictionary[@"updatedAt"];
    entry.updatedAt = [updatedAt isKindOfClass:NSString.class] ? updatedAt : entry.installedAt;

    if (!entry.sourceInstalledAt.length) entry.sourceInstalledAt = entry.installedAt;
    return entry;
}

- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    NSMutableArray<NSDictionary<NSString *, id> *> *grants =
        [NSMutableArray arrayWithCapacity:self.criticalGrants.count];
    for (A2PluginCriticalGrant *grant in self.criticalGrants) {
        [grants addObject:[grant dictionaryRepresentation]];
    }

    NSMutableDictionary<NSString *, id> *source = [NSMutableDictionary dictionary];
    source[@"kind"] = self.sourceKind ?: @"local-import";
    if (self.sourceDetail.length) source[@"sourceDetail"] = self.sourceDetail;
    source[@"installedAt"] = self.sourceInstalledAt.length ? self.sourceInstalledAt
                                                           : (self.installedAt ?: @"");

    return @{
        @"id": self.pluginId ?: @"",
        @"version": self.version ?: @"",
        @"packageHash": self.packageHash ?: @"",
        @"source": source,
        @"permissionsGranted": self.permissionsGranted ?: @[],
        @"criticalGrants": grants,
        @"permissionSet": self.permissionSet ?: @"",
        @"approvedHashes": self.approvedHashes ?: @[],
        @"grantRevision": @(self.grantRevision),
        @"enabled": @(self.enabled),
        @"installedAt": self.installedAt ?: @"",
        @"updatedAt": self.updatedAt ?: @"",
    };
}

@end

#pragma mark - 注册表

@interface A2PluginRegistry () {
    NSMutableDictionary<NSString *, A2PluginRegistryEntry *> *_entriesById;
}
@property (nonatomic, assign) NSInteger seq;
@property (nonatomic, assign) NSInteger userSeq;
@end

@implementation A2PluginRegistry

+ (nullable NSString *)defaultPluginsDirectory {
    NSArray<NSString *> *directories =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = directories.firstObject;
    if (!base.length) return nil;
    return [[base stringByAppendingPathComponent:@"Air2"] stringByAppendingPathComponent:@"Plugins"];
}

- (instancetype)initWithPluginsDirectory:(nullable NSString *)pluginsDirectory {
    self = [super init];
    if (self) {
        NSString *directory = pluginsDirectory;
        if (!directory.length) directory = [A2PluginRegistry defaultPluginsDirectory];
        _pluginsDirectory = [directory copy] ?: @"";
        _registryPath = [_pluginsDirectory stringByAppendingPathComponent:@"registry.json"];
        _entriesById = [NSMutableDictionary dictionary];
        _seq = 0;
        _userSeq = 0;
    }
    return self;
}

- (NSArray<A2PluginRegistryEntry *> *)allEntries {
    NSArray<NSString *> *keys =
        [[_entriesById allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<A2PluginRegistryEntry *> *entries =
        [NSMutableArray arrayWithCapacity:keys.count];
    for (NSString *key in keys) {
        A2PluginRegistryEntry *entry = _entriesById[key];
        if (entry) [entries addObject:entry];
    }
    return entries;
}

- (nullable A2PluginRegistryEntry *)entryForPluginId:(NSString *)pluginId {
    if (![pluginId isKindOfClass:NSString.class] || !pluginId.length) return nil;
    return _entriesById[pluginId];
}

- (BOOL)loadWithError:(NSError **)error {
    // 读失败时内存清空、磁盘不动：调用方拿到 NO 后自己决定要不要重建
    // （重建是启动流程的事，且必须先把原文件改名留档）。
    [_entriesById removeAllObjects];
    self.seq = 0;
    self.userSeq = 0;

    NSData *data = [NSData dataWithContentsOfFile:self.registryPath];
    if (!data) {
        if ([NSFileManager.defaultManager fileExistsAtPath:self.registryPath]) {
            return A2RegistryFail(error, A2PluginRegistryErrorRead, nil,
                                  @"读取 %@ 失败", self.registryPath);
        }
        return YES;   // 首次安装：空表，且不建文件
    }

    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![root isKindOfClass:NSDictionary.class]) {
        return A2RegistryFail(error, A2PluginRegistryErrorFormat, nil,
                              @"registry.json 不是合法 JSON：%@",
                              jsonError.localizedDescription ?: @"根节点不是对象");
    }
    NSDictionary *rootDict = (NSDictionary *)root;

    id formatVersionValue = rootDict[@"formatVersion"];
    if (![formatVersionValue isKindOfClass:NSNumber.class]) {
        return A2RegistryFail(error, A2PluginRegistryErrorFormat, @"formatVersion",
                              @"registry.json 缺少 formatVersion");
    }
    NSInteger formatVersion = [(NSNumber *)formatVersionValue integerValue];
    if (formatVersion != A2PluginRegistryFormatVersion) {
        return A2RegistryFail(error, A2PluginRegistryErrorFormat, @"formatVersion",
                              @"注册表结构版本 %ld 与本宿主（%ld）不一致，需要迁移",
                              (long)formatVersion, (long)A2PluginRegistryFormatVersion);
    }

    id pluginsValue = rootDict[@"plugins"];
    if (![pluginsValue isKindOfClass:NSArray.class]) {
        return A2RegistryFail(error, A2PluginRegistryErrorFormat, @"plugins",
                              @"registry.json 的 plugins 必须是数组");
    }
    NSMutableDictionary<NSString *, A2PluginRegistryEntry *> *parsed =
        [NSMutableDictionary dictionaryWithCapacity:[(NSArray *)pluginsValue count]];
    for (id item in (NSArray *)pluginsValue) {
        NSError *entryError = nil;
        A2PluginRegistryEntry *entry = [A2PluginRegistryEntry entryWithDictionary:item
                                                                           error:&entryError];
        if (!entry) {
            return A2RegistryFail(error, A2PluginRegistryErrorFormat, nil,
                                  @"registry.json 有条目损坏：%@",
                                  entryError.localizedDescription ?: @"结构不符");
        }
        // 逐条按「写前校验」的同一套规则过一遍：一条结构上不成立的记录若放进来，
        // 之后每次 save 都会失败，用户就再也改不了表了。宁可现在报损坏，
        // 让启动流程按 PLUGIN-SYSTEM 4.4 改名重建。
        if (![entry validateWithError:&entryError]) {
            return A2RegistryFail(error, A2PluginRegistryErrorFormat, nil,
                                  @"registry.json 有条目不合法：%@",
                                  entryError.localizedDescription ?: @"写前校验未通过");
        }
        if (parsed[entry.pluginId]) {
            return A2RegistryFail(error, A2PluginRegistryErrorFormat, @"plugins",
                                  @"registry.json 里重复出现插件 id「%@」", entry.pluginId);
        }
        parsed[entry.pluginId] = entry;
    }

    // 只有整张表都读通了才落到内存：读失败时调用方拿到的仍是空表，
    // 不会出现「一半条目来自坏文件」的中间状态。
    [_entriesById removeAllObjects];
    [_entriesById addEntriesFromDictionary:parsed];

    id seqValue = rootDict[@"seq"];
    if ([seqValue isKindOfClass:NSNumber.class]) {
        self.seq = [(NSNumber *)seqValue integerValue];
    }
    id userSeqValue = rootDict[@"userSeq"];
    if ([userSeqValue isKindOfClass:NSNumber.class]) {
        self.userSeq = [(NSNumber *)userSeqValue integerValue];
    }
    return YES;
}

- (BOOL)saveWithError:(NSError **)error {
    NSArray<A2PluginRegistryEntry *> *entries = [self allEntries];
    for (A2PluginRegistryEntry *entry in entries) {
        if (![entry validateWithError:error]) return NO;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *plugins =
        [NSMutableArray arrayWithCapacity:entries.count];
    for (A2PluginRegistryEntry *entry in entries) {
        [plugins addObject:[entry dictionaryRepresentation]];
    }

    NSInteger newSeq = self.seq + 1;
    NSDictionary<NSString *, id> *root = @{
        @"formatVersion": @(A2PluginRegistryFormatVersion),
        @"seq": @(newSeq),
        @"userSeq": @(self.userSeq),
        @"plugins": plugins,
    };

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:(NSJSONWritingOptions)
                                                           (NSJSONWritingPrettyPrinted |
                                                            NSJSONWritingSortedKeys)
                                                     error:&jsonError];
    if (!data) {
        return A2RegistryFail(error, A2PluginRegistryErrorWrite, nil,
                              @"序列化注册表失败：%@",
                              jsonError.localizedDescription ?: @"未知原因");
    }
    if (!A2AtomicWriteData(self.registryPath, data, error)) return NO;
    self.seq = newSeq;
    return YES;
}

- (BOOL)upsertEntry:(A2PluginRegistryEntry *)entry error:(NSError **)error {
    if (![entry isKindOfClass:A2PluginRegistryEntry.class]) {
        return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, nil,
                              @"upsert 需要 A2PluginRegistryEntry 对象");
    }
    if (![entry validateWithError:error]) return NO;

    A2PluginRegistryEntry *previous = _entriesById[entry.pluginId];
    _entriesById[entry.pluginId] = entry;
    if (![self saveWithError:error]) {
        // 写盘失败 → 内存回滚，保持「内存 == 磁盘」，
        // 否则下次读表会把一个没写进磁盘的条目当成已安装。
        if (previous) {
            _entriesById[entry.pluginId] = previous;
        } else {
            [_entriesById removeObjectForKey:entry.pluginId];
        }
        return NO;
    }
    return YES;
}

- (BOOL)removeEntryForPluginId:(NSString *)pluginId error:(NSError **)error {
    if (![pluginId isKindOfClass:NSString.class] || !pluginId.length) {
        return A2RegistryFail(error, A2PluginRegistryErrorInvalidEntry, @"id",
                              @"remove 需要插件 id");
    }
    A2PluginRegistryEntry *previous = _entriesById[pluginId];
    if (!previous) return YES;   // 幂等：本来就没有

    [_entriesById removeObjectForKey:pluginId];
    if (![self saveWithError:error]) {
        _entriesById[pluginId] = previous;
        return NO;
    }
    return YES;
}

@end
