//
//  A2VersionIsolation.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  版本隔离 —— 逻辑与 ZL2 完全对齐。
//
//  ZL2 的规则（已核对 GamePathManager.kt / VersionConfig.kt / Version.kt）：
//
//    isIsolation() = isolationType.toBoolean(全局的 versionIsolation)
//      其中 toBoolean:
//        FOLLOW_GLOBAL → 全局设置的值      ← 关键，之前漏了
//        ENABLE        → true
//        DISABLE       → false
//
//    getGameDir():
//        isIsolation()                → {gameHome}/versions/{版本名}/
//        customPath 非空              → customPath
//        否则                         → {gameHome}/
//
//    各隔离目录 = getGameDir() + 文件夹名
//      （ModsManagerScreen 里就是 VersionFolders.MOD.getDir(version.getGameDir())）
//
//  也就是说 mods / saves / resourcepacks / shaderpacks / screenshots
//  全部从「版本的游戏目录」派生；libraries 与 assets 始终共用。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 单个模块的隔离开关状态。对应 ZL2 的 SettingState。
typedef NS_ENUM(NSInteger, A2SettingState) {
    A2SettingStateFollowGlobal = 0,  ///< 跟随全局设置
    A2SettingStateEnable,            ///< 强制开启
    A2SettingStateDisable,           ///< 强制关闭
};

/// 可隔离的模块。对应 ZL2 的 VersionFolders。
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

#pragma mark - 全局设置

/**
 * 全局的游戏设置。
 *
 * ZL2 里对应 AllSettings，版本配置里的 FOLLOW_GLOBAL
 * 会读这里的值。没有这个，FOLLOW_GLOBAL 就无从解析。
 *
 * 注意：真实存储已收敛到 Core/Settings/A2Settings，
 * 本类仅作兼容转发，新代码请直接用 A2Settings。
 */
@interface A2GlobalGameSettings : NSObject

+ (instancetype)shared;

/// 全局的版本隔离开关
@property (nonatomic, assign) BOOL defaultVersionIsolation;
/// 全局的跳过完整性检查
@property (nonatomic, assign) BOOL defaultSkipIntegrityCheck;
/// 全局内存分配（MB）
@property (nonatomic, assign) NSInteger defaultRAMAllocation;
/// 全局渲染器标识
@property (nonatomic, copy, nullable) NSString *defaultRenderer;

@end

#pragma mark - 版本隔离配置

/**
 * 版本隔离配置。挂在每个版本上，字段与 ZL2 的 VersionConfig 对应。
 */
@interface A2VersionIsolation : NSObject <NSCopying>

/// 是否开启版本隔离
@property (nonatomic, assign) A2SettingState isolationType;
/// 是否跳过游戏完整性检查
@property (nonatomic, assign) A2SettingState skipGameIntegrityCheck;
/// 未开启隔离时的自定义游戏目录
@property (nonatomic, copy, nullable) NSString *customPath;
/// 是否置顶
@property (nonatomic, assign, getter=isPinned) BOOL pinned;
/// 内存分配（MB），-1 表示跟随全局
@property (nonatomic, assign) NSInteger ramAllocation;

// ---- 版本级覆盖项（对应 ZL2 的 VersionConfig 字段）----
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

/// 该版本是否开启隔离（FOLLOW_GLOBAL 会落到全局设置）
- (BOOL)isIsolationEnabledWithGlobal:(BOOL)globalIsolation;
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

- (NSString *)versionsHome;
- (NSString *)librariesHome;
- (NSString *)assetsHome;
- (NSString *)versionPath:(NSString *)versionName;
- (NSString *)versionJSONPath:(NSString *)versionName;
- (NSString *)versionJarPath:(NSString *)versionName;
- (NSString *)launcherDataPath:(NSString *)versionName;
- (NSString *)versionIconPath:(NSString *)versionName;

/// 该版本实际使用的游戏目录（隔离逻辑的核心）
- (NSString *)gameDirectoryForVersion:(NSString *)versionName
                            isolation:(A2VersionIsolation *)isolation;

/// 指定全局隔离值（便于测试与批量计算）
- (NSString *)gameDirectoryForVersion:(NSString *)versionName
                            isolation:(A2VersionIsolation *)isolation
                      globalIsolation:(BOOL)globalIsolation;

/// 某个可隔离模块的实际目录 = getGameDir() + 文件夹名
- (NSString *)directoryForFolder:(A2VersionFolder)folder
                     versionName:(NSString *)versionName
                       isolation:(A2VersionIsolation *)isolation;

- (NSString *)directoryForFolder:(A2VersionFolder)folder
                     versionName:(NSString *)versionName
                       isolation:(A2VersionIsolation *)isolation
                 globalIsolation:(BOOL)globalIsolation;

@end

NS_ASSUME_NONNULL_END
