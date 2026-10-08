//
//  A2VersionManager.m
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

#import "A2VersionManager.h"
#import "A2Settings.h"
#import "A2Log.h"

NSNotificationName const A2VersionsDidChangeNotification = @"A2VersionsDidChangeNotification";

/// 启动器私有数据目录名
static NSString *const kLauncherDataDir = @".air_version";
/// 版本配置文件名
static NSString *const kConfigFileName = @"config.json";
// 当前版本 key 收敛到 A2Settings，不再本地定义。

/// 校验新版本名：去首尾空白，空名或非法名返回 nil 并填 error。
/// 重名不在这里判 —— 改名遇到重名是失败，复制遇到重名也是失败，
/// 但改名遇到同名是成功（无操作），语义不同，各自处理。
static NSString *A2TrimmedVersionName(NSString *name, NSError **error) {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2Version" code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"版本名不能为空"}];
        }
        return nil;
    }
    if ([trimmed containsString:@"/"] || [trimmed containsString:@"\\"] ||
        [trimmed isEqualToString:@"."] || [trimmed isEqualToString:@".."] ||
        [trimmed hasPrefix:@"."]) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2Version" code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"版本名包含非法字符"}];
        }
        return nil;
    }
    return trimmed;
}

/// 把目录里的 {old}.json / {old}.jar 改名为 {new}（不存在则跳过）。
static void A2RenameVersionPayload(NSString *dir, NSString *oldName, NSString *newName) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *oldJson = [dir stringByAppendingPathComponent:
                         [oldName stringByAppendingPathExtension:@"json"]];
    NSString *newJson = [dir stringByAppendingPathComponent:
                         [newName stringByAppendingPathExtension:@"json"]];
    if ([fm fileExistsAtPath:oldJson]) [fm moveItemAtPath:oldJson toPath:newJson error:nil];
    NSString *oldJar = [dir stringByAppendingPathComponent:
                        [oldName stringByAppendingPathExtension:@"jar"]];
    NSString *newJar = [dir stringByAppendingPathComponent:
                        [newName stringByAppendingPathExtension:@"jar"]];
    if ([fm fileExistsAtPath:oldJar]) [fm moveItemAtPath:oldJar toPath:newJar error:nil];
}

#pragma mark - A2Version

@interface A2Version ()
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *gameHome;
@property (nonatomic, strong) A2VersionIsolation *isolation;
@property (nonatomic, assign) A2VersionType type;
@property (nonatomic, assign, getter=isValid) BOOL valid;
@property (nonatomic, strong) A2GamePath *gamePath;
@end

@implementation A2Version

- (instancetype)initWithName:(NSString *)name gameHome:(NSString *)gameHome {
    self = [super init];
    if (!self) return nil;
    _name = [name copy];
    _gameHome = [gameHome copy];
    _gamePath = [A2GamePath pathWithGameHome:gameHome];
    _isolation = [A2VersionIsolation new];
    _type = A2VersionTypeUnknown;
    [self loadConfig];
    [self validate];
    return self;
}

- (NSString *)versionPath {
    return [_gamePath versionPath:_name];
}

- (NSString *)jsonPath {
    return [_gamePath versionJSONPath:_name];
}

- (NSString *)launcherDataPath {
    return [_gamePath launcherDataPath:_name];
}

- (NSString *)gameDirectory {
    return [_gamePath gameDirectoryForVersion:_name mode:self.isolationMode];
}

/// 模组目录
- (NSString *)modsDirectory {
    return [_gamePath modsDirectoryForVersion:_name mode:self.isolationMode];
}

/// 某个可隔离模块的实际目录
- (NSString *)directoryForFolder:(A2VersionFolder)folder {
    return [_gamePath directoryForFolder:folder
                             versionName:_name
                                    mode:self.isolationMode];
}

/// 当前全局隔离档位。所有版本统一，取自设置。
- (A2IsolationMode)isolationMode {
    return (A2IsolationMode)A2Settings.shared.versionIsolationMode;
}

- (void)ensureIsolationDirectories {
    [_gamePath ensureIsolationDirectoriesForVersion:_name mode:self.isolationMode];
}

/// 读取版本私有配置
- (void)loadConfig {
    NSString *path = [[self launcherDataPath] stringByAppendingPathComponent:kConfigFileName];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:NSDictionary.class]) return;
    _isolation = [A2VersionIsolation fromDictionary:dict];
}

- (void)saveConfig {
    (void)[self writeConfig];
}

/// 落盘版本配置，返回是否写成功（供 applyPinnedAndSave 判断回滚）。
- (BOOL)writeConfig {
    NSString *dir = [self launcherDataPath];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];

    NSData *data = [NSJSONSerialization dataWithJSONObject:[_isolation toDictionary]
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (!data) return NO;
    NSString *path = [dir stringByAppendingPathComponent:kConfigFileName];
    return [data writeToFile:path atomically:YES];
}

/// 置顶并落盘。落盘失败时恢复旧值，由调用方回滚 UI。
- (BOOL)applyPinnedAndSave:(BOOL)pinned {
    BOOL old = self.isolation.isPinned;
    if (old == pinned) return YES;
    self.isolation.pinned = pinned;
    if ([self writeConfig]) return YES;
    self.isolation.pinned = old;
    [A2Log log:@"version: 置顶保存失败 %@，已回滚", self.name];
    return NO;
}

/// 检查版本是否可用：必须有 jar 与 json，且 json 可解析出版本身份。
- (void)validate {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL hasJson = [fm fileExistsAtPath:[self jsonPath]];
    NSString *jar = [_gamePath versionJarPath:_name];
    BOOL hasJar = [fm fileExistsAtPath:jar];

    _versionInfo = nil;
    _loaderInfo = nil;
    _invalidReason = nil;

    NSDictionary *json = nil;
    if (hasJson) {
        NSData *d = [NSData dataWithContentsOfFile:[self jsonPath]];
        id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([obj isKindOfClass:NSDictionary.class]) json = obj;
    }

    if (json) {
        _versionInfo = [A2VersionInfo infoFromJSONDictionary:json versionID:_name];
        _loaderInfo = _versionInfo.loaderDisplayString;
        // type 可能是坏文件里的数字，先判类型再比（直接调 isEqualToString 会崩）。
        id rawType = json[@"type"];
        NSString *type = [rawType isKindOfClass:NSString.class] ? rawType : nil;
        if ([type isEqualToString:@"release"]) {
            _type = A2VersionTypeRelease;
        } else if ([type isEqualToString:@"snapshot"]) {
            _type = A2VersionTypeSnapshot;
        } else if ([type isEqualToString:@"old_beta"]) {
            _type = A2VersionTypeOldBeta;
        } else if ([type isEqualToString:@"old_alpha"]) {
            _type = A2VersionTypeOldAlpha;
        }
    }

    if (!hasJson) {
        _valid = NO;
        _invalidReason = @"缺少版本 json";
    } else if (!hasJar) {
        _valid = NO;
        _invalidReason = @"缺少客户端 jar";
    } else if (!_versionInfo) {
        _valid = NO;
        _invalidReason = @"版本 json 解析失败";
    } else {
        _valid = YES;
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<A2Version %@ valid=%d isolation=%@>",
            self.name, self.isValid, self.isolation];
}

@end

#pragma mark - A2VersionManager

@interface A2VersionManager ()
@property (nonatomic, copy) NSArray<A2Version *> *versions;
@property (nonatomic, strong, nullable) A2Version *currentVersion;
@end

@implementation A2VersionManager

+ (instancetype)shared {
    static A2VersionManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2VersionManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    // 默认游戏目录：沙盒 Documents/.minecraft
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    _gameHome = [docs stringByAppendingPathComponent:@".minecraft"];
    _versions = @[];

    // 构造期只扫描、不发通知：此刻 shared 的 dispatch_once 还没返回，
    // 观察者在回调里再取一次 shared 会重入同一个 dispatch_once 而死锁（SIGTRAP）。
    [self loadVersionsFromDisk];
    return self;
}

- (void)setGameHome:(NSString *)gameHome {
    if ([_gameHome isEqualToString:gameHome]) return;
    _gameHome = [gameHome copy];
    [self reload];
}

#pragma mark 扫描

- (void)reload {
    [self loadVersionsFromDisk];
    [self notify];
}

/// 扫描版本目录并恢复当前版本。与 reload 分开是因为 init 必须在
/// dispatch_once 内完成，期间不能发通知（见 init 处说明）。
- (void)loadVersionsFromDisk {
    [A2Log log:@"version: 开始扫描 %@", _gameHome];
    A2GamePath *path = [A2GamePath pathWithGameHome:_gameHome];
    NSString *versionsDir = [path versionsHome];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:versionsDir error:nil];
    if (!entries) entries = @[];

    NSMutableArray<A2Version *> *found = [NSMutableArray array];
    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"."]) continue;

        // 只认「目录里同时有 {name}.json」的条目
        NSString *jsonPath = [[versionsDir stringByAppendingPathComponent:entry]
                              stringByAppendingPathComponent:[entry stringByAppendingPathExtension:@"json"]];
        BOOL isDir = NO;
        [fm fileExistsAtPath:[versionsDir stringByAppendingPathComponent:entry] isDirectory:&isDir];
        if (!isDir) continue;
        if (![fm fileExistsAtPath:jsonPath]) continue;

        A2Version *v = [[A2Version alloc] initWithName:entry gameHome:_gameHome];
        [found addObject:v];
        // 识别一行记一行：名 + 路径 + 展示串（无效的记原因），闪退时看这份日志定位。
        [A2Log log:@"version: 识别 %@（%@，%@）", v.name, [v versionPath],
                 v.isValid ? [v.versionInfo infoString] : (v.invalidReason ?: @"文件不完整")];
    }

    // 排序：有效在前；置顶在前；MC 版本语义倒序；
    // 同版本按名称自然序（数字段按数值比，避免 1.10 排到 1.9 前面）。
    [found sortUsingComparator:^NSComparisonResult(A2Version *a, A2Version *b) {
        if (a.isValid != b.isValid) return a.isValid ? NSOrderedAscending : NSOrderedDescending;
        BOOL pinnedA = a.isolation.isPinned;
        BOOL pinnedB = b.isolation.isPinned;
        if (pinnedA != pinnedB) return pinnedA ? NSOrderedAscending : NSOrderedDescending;
        NSString *mcA = a.versionInfo.minecraftVersion ?: a.name;
        NSString *mcB = b.versionInfo.minecraftVersion ?: b.name;
        NSComparisonResult mc = [mcB compare:mcA options:NSNumericSearch];
        if (mc != NSOrderedSame) return mc;
        return [a.name compare:b.name options:NSNumericSearch];
    }];

    _versions = [found copy];

    // 恢复上次选择的版本
    NSString *savedName = A2Settings.shared.currentVersionName;
    A2Version *restored = nil;
    if (savedName) {
        for (A2Version *v in _versions) {
            if ([v.name isEqualToString:savedName]) { restored = v; break; }
        }
    }
    // 找不到就选第一个有效版本
    if (!restored) {
        for (A2Version *v in _versions) {
            if (v.isValid) { restored = v; break; }
        }
    }
    _currentVersion = restored;
    // 扫描完就把隔离目录落好，避免首次游玩时目录还没建。
    [self applyIsolation];
    [A2Log log:@"version: 扫描完成 %lu 个（当前 %@）",
             (unsigned long)_versions.count, _currentVersion.name ?: @"(无)"];
}

- (void)notify {
    [NSNotificationCenter.defaultCenter postNotificationName:A2VersionsDidChangeNotification
                                                      object:self];
}

- (void)applyIsolation {
    A2IsolationMode mode = (A2IsolationMode)A2Settings.shared.versionIsolationMode;

    // 每个版本各自的隔离目录都要建好（关闭档不建）。
    for (A2Version *v in _versions) {
        [v ensureIsolationDirectories];
    }

    // 共享 mods 只和「当前版本」相关：仅 Mod 档指向当前版本，其余档恢复成真实目录。
    A2GamePath *path = [A2GamePath pathWithGameHome:_gameHome];
    NSString *currentName = _currentVersion ? _currentVersion.name : nil;
    [path alignSharedModsDirectoryForVersion:currentName mode:mode];
    [A2Log log:@"isolation: 应用档位 %@（当前版本 %@）",
          A2IsolationModeToString(mode), currentName ?: @"(无)"];
}

#pragma mark 操作

- (BOOL)selectCurrentVersion:(A2Version *)version {
    if (!version || !version.isValid) return NO;
    _currentVersion = version;
    A2Settings.shared.currentVersionName = version.name;
    [A2Log log:@"version: 切换当前版本 → %@", version.name];
    // 切换版本要重新对齐共享 mods（仅 Mod 档下它指向当前版本）。
    [self applyIsolation];
    [self notify];
    return YES;
}

- (BOOL)deleteVersion:(A2Version *)version error:(NSError **)error {
    if (!version) return NO;
    NSString *path = [version versionPath];

    // 隔离开启时，版本文件夹里有用户的 mods/saves，删除是不可逆的。
    // 这里只删版本本体，用户内容（如果需要保留）应由上层先迁移。
    [A2Log log:@"version: 删除 %@", version.name];
    NSError *opErr = nil;
    BOOL ok = [NSFileManager.defaultManager removeItemAtPath:path error:&opErr];
    if (ok) {
        if ([_currentVersion.name isEqualToString:version.name]) {
            _currentVersion = nil;
            A2Settings.shared.currentVersionName = nil;
        }
        [self reload];
        [A2Log log:@"version: 删除完成 %@", version.name];
    } else {
        if (error) *error = opErr;
        [A2Log log:@"version: 删除失败 %@（%@）",
                 version.name, opErr.localizedDescription ?: @"未知错误"];
    }
    return ok;
}

- (BOOL)renameVersion:(A2Version *)version to:(NSString *)newName error:(NSError **)error {
    if (!version) return NO;

    NSString *trimmed = A2TrimmedVersionName(newName, error);
    if (!trimmed) {
        NSString *reason = (error && *error) ? (*error).localizedDescription : @"非法名";
        [A2Log log:@"version: 改名拒绝 %@ → %@（%@）", version.name, newName, reason];
        return NO;
    }
    if ([trimmed isEqualToString:version.name]) return YES;

    A2GamePath *path = [A2GamePath pathWithGameHome:_gameHome];
    NSString *oldPath = [version versionPath];
    NSString *newPath = [path versionPath:trimmed];

    if ([NSFileManager.defaultManager fileExistsAtPath:newPath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2Version" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: @"同名版本已存在"}];
        }
        [A2Log log:@"version: 改名拒绝 %@ → %@（目标已存在）", version.name, trimmed];
        return NO;
    }

    BOOL wasCurrent = [_currentVersion.name isEqualToString:version.name];
    [A2Log log:@"version: 改名 %@ → %@", version.name, trimmed];
    NSError *opErr = nil;
    BOOL ok = [NSFileManager.defaultManager moveItemAtPath:oldPath toPath:newPath error:&opErr];
    if (!ok) {
        if (error) *error = opErr;
        [A2Log log:@"version: 改名失败 %@ → %@（%@）",
                 version.name, trimmed, opErr.localizedDescription ?: @"未知错误"];
        return NO;
    }

    // 版本文件夹里的 json 与 jar 需要同步改名
    A2RenameVersionPayload(newPath, version.name, trimmed);

    if (wasCurrent) {
        A2Settings.shared.currentVersionName = trimmed;
    }
    [self reload];
    [A2Log log:@"version: 改名完成 %@ → %@", version.name, trimmed];
    return YES;
}

/// 复制版本。目标已存在直接失败，不覆盖用户文件；中途失败删掉新建一半的目标。
- (BOOL)copyVersion:(A2Version *)version to:(NSString *)newName copyAllFiles:(BOOL)copyAll error:(NSError **)error {
    if (!version) return NO;

    NSString *trimmed = A2TrimmedVersionName(newName, error);
    if (!trimmed) {
        NSString *reason = (error && *error) ? (*error).localizedDescription : @"非法名";
        [A2Log log:@"version: 复制拒绝 %@ → %@（%@）", version.name, newName, reason];
        return NO;
    }
    if (!version.isValid) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2Version" code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法复制文件不完整的版本"}];
        }
        [A2Log log:@"version: 复制拒绝 %@（%@）", version.name, version.invalidReason ?: @"文件不完整"];
        return NO;
    }

    A2GamePath *path = [A2GamePath pathWithGameHome:_gameHome];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *srcPath = [version versionPath];
    NSString *dstPath = [path versionPath:trimmed];
    if ([fm fileExistsAtPath:dstPath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2Version" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: @"同名版本已存在"}];
        }
        [A2Log log:@"version: 复制拒绝 %@ → %@（目标已存在）", version.name, trimmed];
        return NO;
    }

    [A2Log log:@"version: 复制 %@ → %@（%@）",
             version.name, trimmed, copyAll ? @"全部文件" : @"仅版本文件"];

    if (copyAll) {
        NSError *opErr = nil;
        if (![fm copyItemAtPath:srcPath toPath:dstPath error:&opErr]) {
            if (error) *error = opErr;
            [A2Log log:@"version: 复制失败 %@ → %@（%@）",
                     version.name, trimmed, opErr.localizedDescription ?: @"未知错误"];
            return NO;
        }
        A2RenameVersionPayload(dstPath, version.name, trimmed);
    } else {
        NSError *opErr = nil;
        if (![fm createDirectoryAtPath:dstPath withIntermediateDirectories:YES
                            attributes:nil error:&opErr]) {
            if (error) *error = opErr;
            return NO;
        }
        NSString *srcJson = [srcPath stringByAppendingPathComponent:
                             [version.name stringByAppendingPathExtension:@"json"]];
        NSString *dstJson = [dstPath stringByAppendingPathComponent:
                             [trimmed stringByAppendingPathExtension:@"json"]];
        if ([fm fileExistsAtPath:srcJson] &&
            ![fm copyItemAtPath:srcJson toPath:dstJson error:&opErr]) {
            if (error) *error = opErr;
            [fm removeItemAtPath:dstPath error:nil];
            return NO;
        }
        NSString *srcJar = [srcPath stringByAppendingPathComponent:
                            [version.name stringByAppendingPathExtension:@"jar"]];
        NSString *dstJar = [dstPath stringByAppendingPathComponent:
                            [trimmed stringByAppendingPathExtension:@"jar"]];
        if ([fm fileExistsAtPath:srcJar] &&
            ![fm copyItemAtPath:srcJar toPath:dstJar error:&opErr]) {
            if (error) *error = opErr;
            [fm removeItemAtPath:dstPath error:nil];
            return NO;
        }
    }

    // 新版本不继承置顶，其余配置沿用来源版本。
    A2VersionIsolation *fresh = [version.isolation copy];
    fresh.pinned = NO;
    NSString *dataDir = [path launcherDataPath:trimmed];
    [fm createDirectoryAtPath:dataDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:[fresh toDictionary]
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (data) {
        NSString *configPath = [dataDir stringByAppendingPathComponent:kConfigFileName];
        if (![data writeToFile:configPath atomically:YES]) {
            // 配置丢了不致命：新版本用默认配置进列表，不阻断复制成功。
            [A2Log log:@"version: 复制 %@ → %@ 配置写回失败（用默认配置）", version.name, trimmed];
        }
    }

    [self reload];
    [A2Log log:@"version: 复制完成 %@ → %@", version.name, trimmed];
    return YES;
}

@end
