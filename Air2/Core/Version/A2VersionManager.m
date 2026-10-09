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
#import "A2VersionIsolation.h"

NSNotificationName const A2VersionsDidChangeNotification = @"A2VersionsDidChangeNotification";

/// 启动器私有数据目录名
static NSString *const kLauncherDataDir = @".air_version";
/// 版本配置文件名
static NSString *const kConfigFileName = @"config.json";
// 当前版本 key 收敛到 A2Settings，不再本地定义。

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
    NSString *dir = [self launcherDataPath];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];

    NSData *data = [NSJSONSerialization dataWithJSONObject:[_isolation toDictionary]
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (!data) return;
    NSString *path = [dir stringByAppendingPathComponent:kConfigFileName];
    [data writeToFile:path atomically:YES];
}

/// 检查版本是否可用：必须有 jar 与 json
- (void)validate {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL hasJson = [fm fileExistsAtPath:[self jsonPath]];
    NSString *jar = [_gamePath versionJarPath:_name];
    BOOL hasJar = [fm fileExistsAtPath:jar];
    _valid = (hasJson && hasJar);

    if (hasJson) {
        NSData *d = [NSData dataWithContentsOfFile:[self jsonPath]];
        NSDictionary *json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([json isKindOfClass:NSDictionary.class]) {
            // 从 version json 推断类型
            NSString *type = json[@"type"];
            if ([type isEqualToString:@"release"]) {
                _type = A2VersionTypeRelease;
            } else if ([type isEqualToString:@"snapshot"]) {
                _type = A2VersionTypeSnapshot;
            } else if ([type isEqualToString:@"old_beta"]) {
                _type = A2VersionTypeOldBeta;
            } else if ([type isEqualToString:@"old_alpha"]) {
                _type = A2VersionTypeOldAlpha;
            }
            // 加载器信息从 id 里推断（Fabric 版本名通常带后缀）
            NSString *vid = json[@"id"];
            if ([vid isKindOfClass:NSString.class]) {
                _loaderInfo = [self loaderInfoFromVersionID:vid];
            }
        }
    }
}

- (NSString *)loaderInfoFromVersionID:(NSString *)vid {
    NSString *lower = vid.lowercaseString;
    if ([lower containsString:@"fabric"]) return @"Fabric";
    if ([lower containsString:@"neoforge"]) return @"NeoForge";
    if ([lower containsString:@"forge"]) return @"Forge";
    if ([lower containsString:@"quilt"]) return @"Quilt";
    if ([lower containsString:@"optifine"]) return @"OptiFine";
    return nil;
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

    // 默认游戏目录：收敛到 A2GamePath，不手写拼接。
    _gameHome = [A2GamePath defaultGameHome];
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
    }

    // 排序：有效的在前，然后按名称倒序（新版本通常在前）
    [found sortUsingComparator:^NSComparisonResult(A2Version *a, A2Version *b) {
        if (a.isValid != b.isValid) return a.isValid ? NSOrderedAscending : NSOrderedDescending;
        return [b.name compare:a.name options:NSNumericSearch];
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
    BOOL ok = [NSFileManager.defaultManager removeItemAtPath:path error:error];
    if (ok) {
        if ([_currentVersion.name isEqualToString:version.name]) {
            _currentVersion = nil;
            A2Settings.shared.currentVersionName = nil;
        }
        [self reload];
    }
    return ok;
}

- (BOOL)renameVersion:(A2Version *)version to:(NSString *)newName error:(NSError **)error {
    if (!version || newName.length == 0) return NO;

    A2GamePath *path = [A2GamePath pathWithGameHome:_gameHome];
    NSString *oldPath = [version versionPath];
    NSString *newPath = [path versionPath:newName];

    if ([NSFileManager.defaultManager fileExistsAtPath:newPath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2Version" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"同名版本已存在"}];
        }
        return NO;
    }

    BOOL ok = [NSFileManager.defaultManager moveItemAtPath:oldPath toPath:newPath error:error];
    if (!ok) return NO;

    // 版本文件夹里的 json 与 jar 需要同步改名
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *oldJson = [newPath stringByAppendingPathComponent:
                         [version.name stringByAppendingPathExtension:@"json"]];
    NSString *newJson = [newPath stringByAppendingPathComponent:
                         [newName stringByAppendingPathExtension:@"json"]];
    if ([fm fileExistsAtPath:oldJson]) [fm moveItemAtPath:oldJson toPath:newJson error:nil];

    NSString *oldJar = [newPath stringByAppendingPathComponent:
                        [version.name stringByAppendingPathExtension:@"jar"]];
    NSString *newJar = [newPath stringByAppendingPathComponent:
                        [newName stringByAppendingPathExtension:@"jar"]];
    if ([fm fileExistsAtPath:oldJar]) [fm moveItemAtPath:oldJar toPath:newJar error:nil];

    [self reload];
    return YES;
}

@end
