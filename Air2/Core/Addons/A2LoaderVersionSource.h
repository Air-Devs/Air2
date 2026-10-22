//
//  A2LoaderVersionSource.h
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
//
//  A2LoaderVersionSource.h
//  Air2
//
//  各模组加载器的「版本列表」获取 —— 对照 ZL2 的 addons/modloader/。
//
//  各家的数据源形态完全不同，这里按加载器分别实现：
//
//    Fabric 系（Fabric/Quilt/LegacyFabric/Babric）
//      meta 服务给 JSON，一次请求拿到 game 支持列表 + loader 列表。
//
//    Forge
//      官方【没有版本列表 API】—— 只能爬 index_{mcVersion}.html。
//      正则提取版本号、推荐标记、时间、MD5。国内走 BMCLAPI 的 JSON 接口。
//      下载 URL 规则：
//        files.minecraftforge.net/maven/net/minecraftforge/forge/
//          {mcVersion}-{forgeVersion}/forge-{mcVersion}-{forgeVersion}-{category}.{ext}
//      文件优先级：installer(jar) > universal(zip) > client(zip)
//
//    NeoForge
//      Maven 仓库，版本号形态复杂（见 A2NeoForgeVersionInfo 的说明）。
//
//    Cleanroom
//      HMCL 维护的 metadata JSON，固定继承 1.12.2。
//
//    OptiFine
//      官方站点无 API，爬 HTML；国内走 BMCLAPI 的 versionList。
//
//  ⚠️ 未实现自动安装的（与 ZL2 的 autoDownloadable=false 一致）：
//     Babric / LiteLoader / Rift —— 官方无稳定接口，UI 标注手动安装。
//

#import <Foundation/Foundation.h>
#import "A2ModLoaderAPI.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Forge 系版本信息

/// Forge 版本的文件类别 —— 决定下载哪个产物
typedef NS_ENUM(NSInteger, A2ForgeFileCategory) {
    A2ForgeFileCategoryUnknown = 0,
    A2ForgeFileCategoryClient,      ///< client.zip，最早期的形态
    A2ForgeFileCategoryUniversal,   ///< universal.zip，1.3.2 ~ 1.6.1
    A2ForgeFileCategoryInstaller,   ///< installer.jar，1.6.1 之后（首选）
};

/// 一个 Forge 版本
@interface A2ForgeVersionInfo : NSObject
@property (nonatomic, copy) NSString *versionName;        ///< 如 55.0.1
@property (nonatomic, copy) NSString *mcVersion;          ///< 继承的游戏版本
@property (nonatomic, copy, nullable) NSString *branch;   ///< 分支后缀，如 1.7.10 的那些
@property (nonatomic, copy, nullable) NSString *releaseTime;
@property (nonatomic, copy, nullable) NSString *md5;
@property (nonatomic, assign) BOOL recommended;
@property (nonatomic, assign) A2ForgeFileCategory category;

/// 用于拼接下载地址的文件版本名（可能含分支后缀）
@property (nonatomic, copy, readonly) NSString *fileVersion;
/// 产物扩展名（installer 是 jar，其余是 zip）
@property (nonatomic, copy, readonly) NSString *fileExtension;
/// 下载地址
@property (nonatomic, copy, readonly) NSString *downloadURL;
@end

#pragma mark - NeoForge 版本信息

/// NeoForge 的版本号形态比 Forge 复杂得多，单独抽出来。
///
/// 三种形态（对照 ZL2 的 NeoForgeVersion）：
///   1) 含 "1.20.1" → 显示为 19.{part}，继承 1.20.1
///      这是 NeoForge 早期从 Forge 分叉时的过渡命名
///   2) 以 "0." 开头 → 特殊版本（如 0.25w14craftmine.3）
///      游戏版本要从版本号里反解
///   3) 其他 → {major}.{minor}.{build}，继承版本按 1.{major}.{minor} 还原
///      26+ 起用新格式（如 26.1.x 对应游戏 26.1）
@interface A2NeoForgeVersionInfo : NSObject
@property (nonatomic, copy) NSString *rawVersion;     ///< 原始版本号（用于拼 URL）
@property (nonatomic, copy) NSString *displayVersion; ///< 展示用版本号
@property (nonatomic, copy) NSString *mcVersion;      ///< 继承的游戏版本
@property (nonatomic, assign) BOOL beta;
@property (nonatomic, assign) BOOL legacyForge;       ///< 1.20.1 那批用 forge 包名

/// 下载地址（Maven）
@property (nonatomic, copy, readonly) NSString *downloadURL;
@end

#pragma mark - OptiFine 版本信息

@interface A2OptiFineVersionInfo : NSObject
@property (nonatomic, copy) NSString *displayName;   ///< OptiFine_1.10.2_HD_U_C1
@property (nonatomic, copy) NSString *fileName;      ///< 带 .jar
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *mcVersion;
@property (nonatomic, copy, nullable) NSString *releaseDate;
/// 最低要求的 Forge 版本。
/// nil = 与 Forge 不兼容；空串 = 无限制；非空 = 需要该版本以上的 Forge
@property (nonatomic, copy, nullable) NSString *forgeVersion;
@property (nonatomic, assign) BOOL preview;

/// 从文件名解析 Maven 版本号
///   OptiFine_1.10.2_HD_U_C1.jar → 1.10.2_HD_U_C1
@property (nonatomic, copy, readonly) NSString *mavenVersion;
@property (nonatomic, copy, readonly) NSString *downloadURL;
@end

#pragma mark - 统一入口

@interface A2LoaderVersionSource : NSObject

+ (instancetype)shared;

/// 按加载器类型取版本列表。
/// 不支持自动安装的类型返回空数组（不是错误）。
- (void)versionsForLoader:(A2ModLoaderType)type
                mcVersion:(NSString *)mcVersion
               completion:(void (^)(NSArray<A2ModLoaderVersion *> * _Nullable versions,
                                    NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
