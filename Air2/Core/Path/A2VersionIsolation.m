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
#import "A2Log.h"

NSString *A2IsolationModeToString(A2IsolationMode mode) {
    switch (mode) {
        case A2IsolationModeMod:  return @"mod";
        case A2IsolationModeFull: return @"full";
        default:                  return @"none";
    }
}

NSString *A2IsolationModeDisplayName(A2IsolationMode mode) {
    switch (mode) {
        case A2IsolationModeMod:  return @"仅 Mod";
        case A2IsolationModeFull: return @"全部";
        default:                  return @"关闭";
    }
}

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

- (BOOL)shouldSkipIntegrityCheckWithGlobal:(BOOL)globalSkip {
    return [A2VersionIsolation resolveState:self.skipGameIntegrityCheck globalValue:globalSkip];
}

- (id)copyWithZone:(NSZone *)zone {
    A2VersionIsolation *c = [[A2VersionIsolation allocWithZone:zone] init];
    c.skipGameIntegrityCheck = self.skipGameIntegrityCheck;
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

    iso.skipGameIntegrityCheck = A2SettingStateFromString(dict[@"skipGameIntegrityCheck"]);
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
    d[@"skipGameIntegrityCheck"] = A2SettingStateToString(self.skipGameIntegrityCheck);
    d[@"pinned"] = @(self.pinned);
    d[@"ramAllocation"] = @(self.ramAllocation);
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
    return [NSString stringWithFormat:@"<A2VersionIsolation pinned=%@ jvmArgs=%@>",
            self.pinned ? @"Y" : @"N", self.jvmArgs ?: @"(default)"];
}

@end

#pragma mark - A2GamePath

/// 「全部」档在版本目录里建的标准结构（对齐 PCL2 / HMCL）。
static NSArray<NSString *> *A2IsolationStandardSubdirectories(void) {
    static NSArray<NSString *> *dirs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dirs = @[@"mods", @"saves", @"config", @"resourcepacks", @"shaderpacks",
                 @"logs", @"crash-reports", @"datapacks", @"screenshots"];
    });
    return dirs;
}

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

+ (NSString *)defaultGameHome {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@".minecraft"];
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

- (NSString *)downloadDestinationInSubdir:(NSString *)subdir
                                 fileName:(NSString *)fileName
                                    error:(NSError **)error {
    if (!subdir.length || !fileName.length) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                                code:NSFileNoSuchFileError
                                            userInfo:@{NSLocalizedDescriptionKey: @"目标路径不完整"}];
        return nil;
    }
    NSString *dir = [[self.gameHome stringByAppendingPathComponent:subdir] copy];
    NSError *ioErr = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&ioErr]) {
        if (error) *error = ioErr;
        return nil;
    }
    return [dir stringByAppendingPathComponent:fileName];
}

#pragma mark - 隔离路径

- (NSString *)gameDirectoryForVersion:(NSString *)versionName
                                 mode:(A2IsolationMode)mode {
    // 只有「全部」档才把游戏目录搬进版本文件夹；关闭与仅 Mod 都在根目录。
    if (mode == A2IsolationModeFull) {
        return [self versionPath:versionName];
    }
    return self.gameHome;
}

- (NSString *)modsDirectoryForVersion:(NSString *)versionName
                                 mode:(A2IsolationMode)mode {
    // 仅 Mod / 全部：mods 固定落在版本目录下。关闭档才用根目录的共享 mods。
    if (mode == A2IsolationModeMod || mode == A2IsolationModeFull) {
        return [[self versionPath:versionName] stringByAppendingPathComponent:@"mods"];
    }
    return [[self gameDirectoryForVersion:versionName mode:mode]
            stringByAppendingPathComponent:@"mods"];
}

- (NSString *)directoryForFolder:(A2VersionFolder)folder
                     versionName:(NSString *)versionName
                            mode:(A2IsolationMode)mode {
    if (folder == A2VersionFolderMods) {
        return [self modsDirectoryForVersion:versionName mode:mode];
    }
    return [[self gameDirectoryForVersion:versionName mode:mode]
            stringByAppendingPathComponent:A2VersionFolderName(folder)];
}

- (void)ensureIsolationDirectoriesForVersion:(NSString *)versionName
                                        mode:(A2IsolationMode)mode {
    // 关闭档不预建目录：游戏会自己在根目录创建，建了反而留下空目录。
    if (mode == A2IsolationModeNone) return;

    NSFileManager *fm = NSFileManager.defaultManager;
    if (mode == A2IsolationModeMod) {
        [fm createDirectoryAtPath:[self modsDirectoryForVersion:versionName mode:mode]
      withIntermediateDirectories:YES attributes:nil error:nil];
        return;
    }

    NSString *root = [self gameDirectoryForVersion:versionName mode:mode];
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *sub in A2IsolationStandardSubdirectories()) {
        [fm createDirectoryAtPath:[root stringByAppendingPathComponent:sub]
      withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

- (void)alignSharedModsDirectoryForVersion:(NSString *)versionName
                                      mode:(A2IsolationMode)mode {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *sharedMods = [self.gameHome stringByAppendingPathComponent:@"mods"];
    NSDictionary *attrs = [fm attributesOfItemAtPath:sharedMods error:nil];
    BOOL isLink = [attrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink];

    // 非「仅 Mod」档：共享 mods 必须是真实目录（此前可能被换成过符号链接）。
    if (mode != A2IsolationModeMod) {
        if (isLink) {
            [fm removeItemAtPath:sharedMods error:nil];
            [fm createDirectoryAtPath:sharedMods
          withIntermediateDirectories:YES attributes:nil error:nil];
            [A2Log log:@"isolation: 共享 mods 恢复为真实目录 (%@)", sharedMods];
        }
        return;
    }

    // 没有当前版本可指（比如版本被删光）：把可能悬空的链接恢复成真实目录。
    if (versionName.length == 0) {
        if (isLink) {
            [fm removeItemAtPath:sharedMods error:nil];
            [fm createDirectoryAtPath:sharedMods
          withIntermediateDirectories:YES attributes:nil error:nil];
            [A2Log log:@"isolation: 无当前版本，共享 mods 恢复为真实目录"];
        }
        return;
    }
    NSString *isolatedMods = [self modsDirectoryForVersion:versionName mode:mode];
    [fm createDirectoryAtPath:isolatedMods
  withIntermediateDirectories:YES attributes:nil error:nil];

    if (attrs) {
        if (isLink) {
            NSString *dest = [fm destinationOfSymbolicLinkAtPath:sharedMods error:nil];
            if ([dest isEqualToString:isolatedMods]) return;  // 已指向本版本
            [fm removeItemAtPath:sharedMods error:nil];        // 只删链接，不动目标
        } else {
            // 真实目录：把已有 mod 迁进版本目录，避免「开启仅 Mod 隔离后 mod 消失」。
            NSError *err = nil;
            NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:sharedMods error:&err];
            if (err) {
                [A2Log log:@"isolation: 读取共享 mods 失败，保持原状：%@", err.localizedDescription];
                return;
            }
            for (NSString *item in items) {
                NSString *from = [sharedMods stringByAppendingPathComponent:item];
                NSString *to = [isolatedMods stringByAppendingPathComponent:item];
                if ([fm fileExistsAtPath:to]) continue;  // 版本目录已有同名文件，保留版本目录的
                if (![fm moveItemAtPath:from toPath:to error:&err]) {
                    [A2Log log:@"isolation: 迁移 %@ 失败，取消符号链接以免丢文件：%@",
                           item, err.localizedDescription];
                    return;
                }
            }
            if ([fm contentsOfDirectoryAtPath:sharedMods error:nil].count > 0) {
                [A2Log log:@"isolation: 共享 mods 未清空，取消符号链接以免丢文件"];
                return;
            }
            [fm removeItemAtPath:sharedMods error:nil];
        }
    }

    NSError *linkErr = nil;
    if ([fm createSymbolicLinkAtPath:sharedMods
                 withDestinationPath:isolatedMods error:&linkErr]) {
        [A2Log log:@"isolation: 仅 Mod —— 共享 mods → %@", isolatedMods];
    } else {
        [A2Log log:@"isolation: 创建 mods 符号链接失败：%@", linkErr.localizedDescription];
    }
}

@end
