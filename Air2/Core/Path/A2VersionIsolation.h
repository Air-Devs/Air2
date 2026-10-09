//
//  A2VersionIsolation.h
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
//  版本隔离 —— 全局三档，语义对齐 PCL2 / HMCL 的三档模型。
//
//  三档（设置页选一个，所有版本统一）：
//
//    关闭   gameDir = 游戏根目录          mods = {根}/mods
//    仅 Mod gameDir = 游戏根目录          mods = versions/{版本名}/mods
//          根目录的 mods 会被换成指向版本 mods 的符号链接，
//          这样游戏读 {根}/mods 时实际读到的是该版本的模组。
//    全部   gameDir = versions/{版本名}   mods = versions/{版本名}/mods
//          存档、资源包、光影、截图等一并搬进版本目录。
//
//  libraries 与 assets 始终共用，不随档位变化。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 全局版本隔离档位。字符串取值与 PCL2 / HMCL 的 none / mod / full 一致。
typedef NS_ENUM(NSInteger, A2IsolationMode) {
    A2IsolationModeNone = 0,  ///< 关闭：所有数据都在游戏根目录，各版本共用
    A2IsolationModeMod,       ///< 仅 Mod：游戏数据共用，只把 mods 隔离到版本目录
    A2IsolationModeFull,      ///< 全部：整个游戏目录隔离到版本目录
};

/// 档位标识字符串（none / mod / full），用于日志与落盘。
FOUNDATION_EXPORT NSString *A2IsolationModeToString(A2IsolationMode mode);
/// 档位的中文显示名（关闭 / 仅 Mod / 全部）。
FOUNDATION_EXPORT NSString *A2IsolationModeDisplayName(A2IsolationMode mode);

/// 单个模块的覆盖开关状态（用于「跳过完整性检查」这类版本级覆盖项）。
typedef NS_ENUM(NSInteger, A2SettingState) {
    A2SettingStateFollowGlobal = 0,  ///< 跟随全局设置
    A2SettingStateEnable,            ///< 强制开启
    A2SettingStateDisable,           ///< 强制关闭
};

/// 可隔离的模块。
typedef NS_ENUM(NSInteger, A2VersionFolder) {
    A2VersionFolderMods = 0,
    A2VersionFolderResourcePacks,
    A2VersionFolderSaves,
    A2VersionFolderShaderPacks,
    A2VersionFolderScreenshots,
    A2VersionFolderCount
};

FOUNDATION_EXPORT NSString *A2VersionFolderName(A2VersionFolder folder);
FOUNDATION_EXPORT NSString *A2VersionFolderDisplayName(A2VersionFolder folder);

#pragma mark - 版本配置

/**
 * 版本级配置。挂在每个版本上，存在 {版本目录}/.air_version/config.json。
 *
 * 注意：版本隔离档位是全局的（见 A2Settings.versionIsolationMode），
 * 这里只放「这个版本自己的」覆盖项。
 */
@interface A2VersionIsolation : NSObject <NSCopying>

/// 是否跳过游戏完整性检查
@property (nonatomic, assign) A2SettingState skipGameIntegrityCheck;
/// 是否置顶
@property (nonatomic, assign, getter=isPinned) BOOL pinned;
/// 内存分配（MB），-1 表示跟随全局
@property (nonatomic, assign) NSInteger ramAllocation;

// ---- 版本级覆盖项 ----
@property (nonatomic, copy, nullable) NSString *renderer;
@property (nonatomic, copy, nullable) NSString *driver;
@property (nonatomic, copy, nullable) NSString *javaRuntime;
@property (nonatomic, copy, nullable) NSString *jvmArgs;
@property (nonatomic, copy, nullable) NSString *gameArgs;
@property (nonatomic, copy, nullable) NSString *controlLayout;
@property (nonatomic, copy, nullable) NSString *serverIp;
@property (nonatomic, copy, nullable) NSString *versionSummary;

/// 把 SettingState 解析为布尔值（FOLLOW_GLOBAL 时取 global）
+ (BOOL)resolveState:(A2SettingState)state globalValue:(BOOL)global;

/// 是否跳过完整性检查
- (BOOL)shouldSkipIntegrityCheckWithGlobal:(BOOL)globalSkip;

+ (instancetype)fromDictionary:(NSDictionary *)dict;
- (NSDictionary *)toDictionary;

@end

#pragma mark - 路径解析

/**
 * 路径解析器 —— 所有游戏路径的唯一出口。
 *
 * 硬性约束：业务代码禁止手写 [NSString stringWithFormat:@"%@/versions/..."]。
 */
@interface A2GamePath : NSObject

@property (nonatomic, copy, readonly) NSString *gameHome;

+ (instancetype)pathWithGameHome:(NSString *)gameHome;

/// 默认游戏根目录（Documents/minecraft），与 A2VersionManager 一致。
+ (NSString *)defaultGameHome;

- (NSString *)versionsHome;
- (NSString *)librariesHome;
- (NSString *)assetsHome;
- (NSString *)versionPath:(NSString *)versionName;
- (NSString *)versionJSONPath:(NSString *)versionName;
- (NSString *)versionJarPath:(NSString *)versionName;
- (NSString *)launcherDataPath:(NSString *)versionName;
- (NSString *)versionIconPath:(NSString *)versionName;

/// 下载落盘目标：gameHome/<subdir>/<fileName>，按需建好子目录。
/// 失败返回 nil（目录建不出，后续写必失败，早报比晚报好）。
- (nullable NSString *)downloadDestinationInSubdir:(NSString *)subdir
                                          fileName:(NSString *)fileName
                                             error:(NSError **)error;

/// 该版本实际使用的游戏目录。
///   关闭 / 仅 Mod → 游戏根目录（各版本共用同一份数据）
///   全部          → versions/{版本名}
- (NSString *)gameDirectoryForVersion:(NSString *)versionName
                                 mode:(A2IsolationMode)mode;

/// 模组目录。
///   仅 Mod / 全部 → versions/{版本名}/mods
///   关闭          → {游戏目录}/mods
- (NSString *)modsDirectoryForVersion:(NSString *)versionName
                                 mode:(A2IsolationMode)mode;

/// 某个可隔离模块的实际目录（mods 走模组目录，其余走游戏目录）
- (NSString *)directoryForFolder:(A2VersionFolder)folder
                     versionName:(NSString *)versionName
                            mode:(A2IsolationMode)mode;

/// 按档位建好该版本需要的目录。关闭档不建任何东西。
- (void)ensureIsolationDirectoriesForVersion:(NSString *)versionName
                                        mode:(A2IsolationMode)mode;

/// 对齐共享 mods 目录（{gameHome}/mods）。
///
/// 仅 Mod 档：让 {gameHome}/mods 指向该版本的 mods 目录，建链前先把已有 mod 迁进
/// 版本目录；迁不干净或同名冲突则放弃建链 —— 任何情况下都不删用户文件。
/// 其他档位：若发现它是符号链接就恢复为真实目录。
- (void)alignSharedModsDirectoryForVersion:(nullable NSString *)versionName
                                      mode:(A2IsolationMode)mode;

@end

NS_ASSUME_NONNULL_END
