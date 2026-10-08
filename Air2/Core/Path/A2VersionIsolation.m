//
//  A2VersionIsolation.m
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

#import "A2VersionIsolation.h"
#import "A2Settings.h"

NSString *A2VersionFolderName(A2VersionFolder folder) {
    switch (folder) {
        case A2VersionFolderMods:          return @"mods";
        case A2VersionFolderResourcePacks: return @"resourcepacks";
        case A2VersionFolderSaves:         return @"saves";
        case A2VersionFolderShaderPacks:   return @"shaderpacks";
        case A2VersionFolderScreenshots:   return @"screenshots";
        default:                           return @"";
    }
}

NSString *A2VersionFolderDisplayName(A2VersionFolder folder) {
    switch (folder) {
        case A2VersionFolderMods:          return @"模组";
        case A2VersionFolderResourcePacks: return @"资源包";
        case A2VersionFolderSaves:         return @"存档";
        case A2VersionFolderShaderPacks:   return @"光影包";
        case A2VersionFolderScreenshots:   return @"截图";
        default:                           return @"";
    }
}

/// 解析 SettingState 的字符串（与 ZL2 的 SerializedName 一致，便于互操作）
static A2SettingState A2SettingStateFromString(NSString *s) {
    if ([s isEqualToString:@"ENABLE"])  return A2SettingStateEnable;
    if ([s isEqualToString:@"DISABLE"]) return A2SettingStateDisable;
    return A2SettingStateFollowGlobal;
}

static NSString *A2SettingStateToString(A2SettingState state) {
    switch (state) {
        case A2SettingStateEnable:  return @"ENABLE";
        case A2SettingStateDisable: return @"DISABLE";
        default:                    return @"FOLLOW_GLOBAL";
    }
}

#pragma mark - A2VersionIsolation

@implementation A2VersionIsolation

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _isolationType = A2SettingStateFollowGlobal;
    _skipGameIntegrityCheck = A2SettingStateFollowGlobal;
    _pinned = NO;
    _ramAllocation = -1;
    return self;
}

/// 把 SettingState 解析为布尔值。
///
/// 对应 ZL2 的 SettingState.toBoolean(global)：
///   FOLLOW_GLOBAL → 用全局设置的值
///   ENABLE        → true
///   DISABLE       → false
+ (BOOL)resolveState:(A2SettingState)state globalValue:(BOOL)global {
    switch (state) {
        case A2SettingStateEnable:  return YES;
        case A2SettingStateDisable: return NO;
        case A2SettingStateFollowGlobal:
        default:                    return global;
    }
}

/// 该版本是否开启隔离。
///
/// 注意 FOLLOW_GLOBAL 要落到全局设置上 ——
/// 这是之前漏掉的：我只把 FOLLOW_GLOBAL 当成「不隔离」，
/// 导致全局开了隔离但版本没设置时，实际没有隔离。
- (BOOL)isIsolationEnabledWithGlobal:(BOOL)globalIsolation {
    return [A2VersionIsolation resolveState:self.isolationType globalValue:globalIsolation];
}

- (BOOL)shouldSkipIntegrityCheckWithGlobal:(BOOL)globalSkip {
    return [A2VersionIsolation resolveState:self.skipGameIntegrityCheck globalValue:globalSkip];
}

- (id)copyWithZone:(NSZone *)zone {
    A2VersionIsolation *c = [[A2VersionIsolation allocWithZone:zone] init];
    c.isolationType = self.isolationType;
    c.skipGameIntegrityCheck = self.skipGameIntegrityCheck;
    c.customPath = self.customPath;
    c.pinned = self.pinned;
    c.ramAllocation = self.ramAllocation;
    c.renderer = self.renderer;
    c.driver = self.driver;
    c.javaRuntime = self.javaRuntime;
    c.jvmArgs = self.jvmArgs;
    c.gameArgs = self.gameArgs;
    c.controlLayout = self.controlLayout;
    c.serverIp = self.serverIp;
    c.versionSummary = self.versionSummary;
    return c;
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    A2VersionIsolation *iso = [A2VersionIsolation new];
    if (![dict isKindOfClass:NSDictionary.class]) return iso;

    iso.isolationType = A2SettingStateFromString(dict[@"isolationType"]);
    iso.skipGameIntegrityCheck = A2SettingStateFromString(dict[@"skipGameIntegrityCheck"]);
    iso.customPath = [dict[@"customPath"] isKindOfClass:NSString.class] ? dict[@"customPath"] : nil;
    iso.pinned = [dict[@"pinned"] boolValue];
    iso.ramAllocation = [dict[@"ramAllocation"] integerValue] ?: -1;
    iso.renderer = [dict[@"renderer"] isKindOfClass:NSString.class] ? dict[@"renderer"] : nil;
    iso.driver = [dict[@"driver"] isKindOfClass:NSString.class] ? dict[@"driver"] : nil;
    iso.javaRuntime = [dict[@"javaRuntime"] isKindOfClass:NSString.class] ? dict[@"javaRuntime"] : nil;
    iso.jvmArgs = [dict[@"jvmArgs"] isKindOfClass:NSString.class] ? dict[@"jvmArgs"] : nil;
    iso.gameArgs = [dict[@"gameArgs"] isKindOfClass:NSString.class] ? dict[@"gameArgs"] : nil;
    iso.controlLayout = [dict[@"control"] isKindOfClass:NSString.class] ? dict[@"control"] : nil;
    iso.serverIp = [dict[@"serverIp"] isKindOfClass:NSString.class] ? dict[@"serverIp"] : nil;
    iso.versionSummary = [dict[@"versionSummary"] isKindOfClass:NSString.class] ? dict[@"versionSummary"] : nil;
    return iso;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"isolationType"] = A2SettingStateToString(self.isolationType);
    d[@"skipGameIntegrityCheck"] = A2SettingStateToString(self.skipGameIntegrityCheck);
    d[@"pinned"] = @(self.pinned);
    d[@"ramAllocation"] = @(self.ramAllocation);
    if (self.customPath)      d[@"customPath"]      = self.customPath;
    if (self.renderer)        d[@"renderer"]        = self.renderer;
    if (self.driver)          d[@"driver"]          = self.driver;
    if (self.javaRuntime)     d[@"javaRuntime"]     = self.javaRuntime;
    if (self.jvmArgs)         d[@"jvmArgs"]         = self.jvmArgs;
    if (self.gameArgs)        d[@"gameArgs"]        = self.gameArgs;
    if (self.controlLayout)   d[@"control"]         = self.controlLayout;
    if (self.serverIp)        d[@"serverIp"]        = self.serverIp;
    if (self.versionSummary)  d[@"versionSummary"]  = self.versionSummary;
    return d;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<A2VersionIsolation isolation=%@ pinned=%@ customPath=%@>",
            A2SettingStateToString(self.isolationType),
            self.pinned ? @"Y" : @"N",
            self.customPath ?: @"(default)"];
}

@end

#pragma mark - 全局设置

/// 全局的版本隔离设置。
///
/// ZL2 里这是 AllSettings.versionIsolation，
/// 版本配置的 FOLLOW_GLOBAL 会读它。
@implementation A2GlobalGameSettings

+ (instancetype)shared {
    static A2GlobalGameSettings *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2GlobalGameSettings alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    // 薄转发：真实存储已收敛到 A2Settings，这里只做兼容，避免改调用方行为。
    A2Settings *s = A2Settings.shared;
    _defaultVersionIsolation = s.versionIsolation;
    _defaultSkipIntegrityCheck = s.skipIntegrityCheck;
    _defaultRAMAllocation = s.ramAllocationMB;
    _defaultRenderer = s.renderer;
    return self;
}

- (void)setDefaultVersionIsolation:(BOOL)v {
    _defaultVersionIsolation = v;
    A2Settings.shared.versionIsolation = v;
}

- (void)setDefaultSkipIntegrityCheck:(BOOL)v {
    _defaultSkipIntegrityCheck = v;
    A2Settings.shared.skipIntegrityCheck = v;
}

- (void)setDefaultRAMAllocation:(NSInteger)v {
    // 钳制逻辑收敛到 A2Settings 一处，这里同步钳后值，避免两处不一致。
    A2Settings.shared.ramAllocationMB = v;
    _defaultRAMAllocation = A2Settings.shared.ramAllocationMB;
}

- (void)setDefaultRenderer:(NSString *)v {
    // 历史实现漏了持久化（只写 ivar 不落盘），这里补上并收敛到注册表。
    _defaultRenderer = [v copy];
    A2Settings.shared.renderer = v;
}

@end

#pragma mark - A2GamePath

@interface A2GamePath ()
@property (nonatomic, copy) NSString *gameHome;
@end

@implementation A2GamePath

+ (instancetype)pathWithGameHome:(NSString *)gameHome {
    A2GamePath *p = [A2GamePath new];
    // 去掉尾部斜杠，避免拼出 "//versions"
    NSString *trimmed = gameHome;
    while (trimmed.length > 1 && [trimmed hasSuffix:@"/"]) {
        trimmed = [trimmed substringToIndex:trimmed.length - 1];
    }
    p.gameHome = trimmed;
    return p;
}

- (NSString *)versionsHome   { return [self.gameHome stringByAppendingPathComponent:@"versions"]; }
- (NSString *)librariesHome  { return [self.gameHome stringByAppendingPathComponent:@"libraries"]; }
- (NSString *)assetsHome     { return [self.gameHome stringByAppendingPathComponent:@"assets"]; }

- (NSString *)versionPath:(NSString *)versionName {
    return [[self versionsHome] stringByAppendingPathComponent:versionName];
}

- (NSString *)versionJSONPath:(NSString *)versionName {
    return [[self versionPath:versionName] stringByAppendingPathComponent:
            [versionName stringByAppendingPathExtension:@"json"]];
}

- (NSString *)versionJarPath:(NSString *)versionName {
    return [[self versionPath:versionName] stringByAppendingPathComponent:
            [versionName stringByAppendingPathExtension:@"jar"]];
}

/// 启动器私有数据目录名。前面加点避免和游戏自身的目录混淆。
static NSString *const kLauncherDataDirName = @".air_version";

- (NSString *)launcherDataPath:(NSString *)versionName {
    return [[self versionPath:versionName] stringByAppendingPathComponent:kLauncherDataDirName];
}

- (NSString *)versionIconPath:(NSString *)versionName {
    return [[self launcherDataPath:versionName] stringByAppendingPathComponent:@"VersionIcon.png"];
}

- (NSString *)gameDirectoryForVersion:(NSString *)versionName
                            isolation:(A2VersionIsolation *)isolation {
    return [self gameDirectoryForVersion:versionName
                               isolation:isolation
                        globalIsolation:A2GlobalGameSettings.shared.defaultVersionIsolation];
}

/// 该版本实际使用的游戏目录 —— 隔离逻辑的核心。
///
/// 完全对应 ZL2 的 Version.getGameDir()：
///   if (versionConfig.isIsolation()) getVersionPath()
///   else if (customPath.isNotEmpty()) File(customPath)
///   else File(gameHome)
///
/// 其中 isIsolation() 会把 FOLLOW_GLOBAL 解析为全局设置的值。
- (NSString *)gameDirectoryForVersion:(NSString *)versionName
                            isolation:(A2VersionIsolation *)isolation
                      globalIsolation:(BOOL)globalIsolation {
    BOOL enabled = [isolation isIsolationEnabledWithGlobal:globalIsolation];

    // 隔离开启 → 版本文件夹独立成家
    if (enabled) {
        return [self versionPath:versionName];
    }

    // 未开启隔离 → 可用自定义路径，否则回落到默认游戏根目录
    if (isolation.customPath.length > 0) {
        return isolation.customPath;
    }
    return self.gameHome;
}

- (NSString *)directoryForFolder:(A2VersionFolder)folder
                     versionName:(NSString *)versionName
                       isolation:(A2VersionIsolation *)isolation {
    return [self directoryForFolder:folder
                        versionName:versionName
                          isolation:isolation
                    globalIsolation:A2GlobalGameSettings.shared.defaultVersionIsolation];
}

- (NSString *)directoryForFolder:(A2VersionFolder)folder
                     versionName:(NSString *)versionName
                       isolation:(A2VersionIsolation *)isolation
                 globalIsolation:(BOOL)globalIsolation {
    NSString *gameDir = [self gameDirectoryForVersion:versionName
                                            isolation:isolation
                                      globalIsolation:globalIsolation];
    return [gameDir stringByAppendingPathComponent:A2VersionFolderName(folder)];
}

@end
