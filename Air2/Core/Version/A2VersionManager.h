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
//  已安装版本的管理 —— 扫描、选择、删除、重命名。
//
//  与 ZL2 的 VersionsManager 对应。
//  职责：
//    · 扫描 {gameHome}/versions/ 下的所有版本
//    · 读取每个版本的 {name}.json 与 .air_version/config.json
//    · 维护「当前选中版本」
//    · 提供删除/重命名/复制等操作
//

#import <Foundation/Foundation.h>
#import "A2VersionIsolation.h"

NS_ASSUME_NONNULL_BEGIN

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
/// 加载器信息（从 json 里解析出来的展示文本）
@property (nonatomic, copy, nullable) NSString *loaderInfo;

- (instancetype)initWithName:(NSString *)name gameHome:(NSString *)gameHome;

/// 版本文件夹  {gameHome}/versions/{name}
- (NSString *)versionPath;
/// 版本 json 路径
- (NSString *)jsonPath;
/// 启动器私有数据目录
- (NSString *)launcherDataPath;
/// 该版本实际使用的游戏目录（隔离档位在这里生效）
- (NSString *)gameDirectory;
/// 模组目录（仅 Mod / 全部档在版本目录下，关闭档在游戏根目录）
- (NSString *)modsDirectory;
/// 某个可隔离模块的实际目录（mods / saves / ...）
- (NSString *)directoryForFolder:(A2VersionFolder)folder;
/// 当前全局隔离档位（所有版本统一，取自设置）
- (A2IsolationMode)isolationMode;
/// 按当前档位建好该版本需要的目录
- (void)ensureIsolationDirectories;

- (void)loadConfig;
- (void)saveConfig;

@end

/// 版本列表变更通知
extern NSNotificationName const A2VersionsDidChangeNotification;

@interface A2VersionManager : NSObject

+ (instancetype)shared;

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

@end

NS_ASSUME_NONNULL_END
