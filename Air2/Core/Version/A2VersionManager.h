//
//  A2VersionManager.h
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
//  已安装版本的管理 —— 扫描、选择、删除、重命名、复制。
//
//  职责：
//    · 扫描 {gameHome}/versions/ 下的所有版本
//    · 读取每个版本的 {name}.json 与 .air_version/config.json
//    · 维护「当前选中版本」
//    · 提供删除/重命名/复制等操作
//

#import <Foundation/Foundation.h>
#import "A2VersionIsolation.h"
#import "A2VersionInfo.h"

NS_ASSUME_NONNULL_BEGIN

/// 版本复制粒度。两种是不同的用户意图，不是一个开关的两面。
typedef NS_ENUM(NSInteger, A2VersionCopyMode) {
    A2VersionCopyModeMinimal = 0,  ///< 只拷 json + jar（干净的新版本）
    A2VersionCopyModeFull,         ///< 拷整个目录（含存档模组）
};

/// 版本类型
typedef NS_ENUM(NSInteger, A2VersionType) {
    A2VersionTypeUnknown = 0,
    A2VersionTypeRelease,      ///< 正式版
    A2VersionTypeSnapshot,     ///< 快照
    A2VersionTypeOldBeta,      ///< 旧版 Beta
    A2VersionTypeOldAlpha,     ///< 旧版 Alpha
};

/// 一个已安装的版本
@interface A2Version : NSObject

@property (nonatomic, copy, readonly) NSString *name;
/// 版本所在的游戏根目录
@property (nonatomic, copy, readonly) NSString *gameHome;
/// 版本隔离配置
@property (nonatomic, strong, readonly) A2VersionIsolation *isolation;
/// 版本类型
@property (nonatomic, assign, readonly) A2VersionType type;
/// 客户端 jar 是否存在
@property (nonatomic, assign, readonly, getter=isValid) BOOL valid;
/// 上次游玩时间（用于排序）
@property (nonatomic, strong, nullable) NSDate *lastPlayed;
/// 加载器信息（兼容转发，取自 versionInfo.loaderDisplayString）
@property (nonatomic, copy, nullable) NSString *loaderInfo;
/// 版本身份（MC 版本 + 加载器列表，解析失败时为 nil）
@property (nonatomic, strong, readonly, nullable) A2VersionInfo *versionInfo;
/// 无效原因（有效时为 nil；缺 json / 缺 jar / json 解析失败三选一）
@property (nonatomic, copy, readonly, nullable) NSString *invalidReason;
/// 该版本能否安装模组。
///
/// 取决于版本自带的加载器：Fabric / Quilt / LegacyFabric / Forge / NeoForge
/// 可以装，原版与只装 OptiFine 的版本不能（OptiFine 只是优化模组，不加载其它 Mod）。
@property (nonatomic, assign, readonly) BOOL canInstallMods;

- (instancetype)initWithName:(NSString *)name gameHome:(NSString *)gameHome;

/// 版本文件夹  {gameHome}/versions/{name}
- (NSString *)versionPath;
/// 版本 json 路径
- (NSString *)jsonPath;
/// 启动器私有数据目录
- (NSString *)launcherDataPath;
/// 该版本实际使用的游戏目录（隔离档位在这里生效）
- (NSString *)gameDirectory;
/// 模组目录（生效档位为仅 Mod / 全部时在版本目录下，关闭档在游戏根目录）
- (NSString *)modsDirectory;
/// 某个可隔离模块的实际目录（mods / saves / ...）
- (NSString *)directoryForFolder:(A2VersionFolder)folder;
/// 当前全局隔离档位（所有版本统一，取自设置）
- (A2IsolationMode)isolationMode;
/// 本版本实际生效的隔离档位。
///
/// 与 isolationMode 的区别：全局档位是「仅 Mod」时，只有能装模组的版本才会隔离，
/// 不能装模组的版本（原版 / 仅 OptiFine）实际按「关闭」处理 —— 隔离 mods 没有意义。
/// 其余档位与全局一致。
- (A2IsolationMode)effectiveIsolationMode;
/// 按生效档位建好该版本需要的目录
- (void)ensureIsolationDirectories;

- (void)loadConfig;
- (void)saveConfig;

/// 置顶并落盘，失败时回滚为旧值并返回 NO（调用方据此决定是否回滚 UI）。
- (BOOL)applyPinnedAndSave:(BOOL)pinned;

@end

/// 版本列表变更通知
extern NSNotificationName const A2VersionsDidChangeNotification;

@interface A2VersionManager : NSObject

+ (instancetype)shared;

/// 校验版本名并返回去空白后的名字；空名或非法名返回 nil。
/// 安装/改名/复制共用同一份规则（名字必须是单路径段），不各写一遍。
+ (nullable NSString *)validatedVersionName:(NSString *)name error:(NSError **)error;

/// 当前游戏根目录（只读，切换用 setGameHome: —— 它会触发重新扫描）
@property (nonatomic, copy, readonly) NSString *gameHome;
/// 所有已安装版本
@property (nonatomic, copy, readonly) NSArray<A2Version *> *versions;
/// 当前选中的版本（只读，切换请用 selectCurrentVersion:）
@property (nonatomic, strong, readonly, nullable) A2Version *currentVersion;

/// 重新扫描版本目录
- (void)reload;

/// 按当前全局档位建好各版本目录，并对齐当前版本的共享 mods 符号链接。
/// 全局档位改动、切换当前版本、扫描完成时都要调一次。
- (void)applyIsolation;

/// 切换当前版本。
///
/// 用动词命名而不是 setCurrentVersion: —— 后者会被编译器当成
/// currentVersion 属性的 setter，而 setter 必须返回 void。
/// 这个方法可能失败（版本无效），所以要能返回 BOOL。
- (BOOL)selectCurrentVersion:(A2Version *)version;

/// 删除版本
- (BOOL)deleteVersion:(A2Version *)version error:(NSError **)error;
/// 重命名版本
- (BOOL)renameVersion:(A2Version *)version to:(NSString *)newName error:(NSError **)error;
/// 复制版本。目标已存在直接失败，不覆盖用户文件；中途失败删掉新建一半的目标。
/// 全量与最小是两个入口（各自对应菜单上一个按钮），不共用布尔开关。
- (BOOL)copyVersionFully:(A2Version *)version to:(NSString *)newName error:(NSError **)error;
- (BOOL)copyVersionMinimal:(A2Version *)version to:(NSString *)newName error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
