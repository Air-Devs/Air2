//
//  A2ModPackInstaller.h
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
//  整合包「导入」执行层 —— 把清单计划真正落地成一个可玩版本。
//
//  A2ModPackParser 只出计划（下什么、落哪），本类负责执行，串起四步：
//    1. 解析本地 zip → A2ModPackPlan（复用 A2ModPackParser）
//    2. 装游戏本体 + 加载器，生成新版本目录（复用 A2GameInstaller）
//    3. 按计划把 mods 等文件下到该版本的游戏目录（复用 A2DownloadEngine）
//    4. 解压包内 overrides/ 覆盖文件到同一目录（复用 A2ZipReader）
//
//  为什么强制开版本隔离：
//    整合包的 mods/config 必须落在这个版本自己的目录里，不能污染游戏根目录，
//    否则两个整合包会互相覆盖。安装完成后本类会把该版本的隔离配置写成「开启」。
//
//  只用 Foundation。取消语义与 A2GameInstaller 一致：取消后不再回调完成，
//  调用方以「不再收到回调」作为结束信号。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 导入阶段（与 UI 的分步清单一一对应）
typedef NS_ENUM(NSInteger, A2ModPackImportStage) {
    A2ModPackImportStageParse = 0,      ///< 解析清单
    A2ModPackImportStageInstallGame,    ///< 安装本体 + 加载器
    A2ModPackImportStageDownloadContent,///< 下载整合包内容
    A2ModPackImportStageExtractOverrides,///< 解压覆盖文件
    A2ModPackImportStageFinalize,       ///< 收尾
    A2ModPackImportStageCount,
};

FOUNDATION_EXPORT NSString *const A2ModPackInstallerErrorDomain;

typedef NS_ENUM(NSInteger, A2ModPackInstallerError) {
    A2ModPackInstallerErrorInvalidParameter = 1,   ///< 参数不完整
    A2ModPackInstallerErrorUnreadableArchive,      ///< 打不开 / 解析不了整合包
    A2ModPackInstallerErrorMissingGameVersion,     ///< 清单没声明 MC 版本
    A2ModPackInstallerErrorUnsupportedLoader,      ///< 加载器不识别或不支持自动安装
    A2ModPackInstallerErrorGameInstallFailed,      ///< 本体 / 加载器安装失败
    A2ModPackInstallerErrorPathEscape,             ///< 包内条目路径越界
    A2ModPackInstallerErrorIncompleteContent,      ///< 有必需文件未能写入
};

/// 导入请求
@interface A2ModPackImportRequest : NSObject
/// 本地整合包文件绝对路径（.mrpack / CurseForge zip）
@property (nonatomic, copy) NSString *archivePath;
/// 游戏根目录
@property (nonatomic, copy) NSString *gameHome;
/// 目标版本名；留空则用整合包名派生
@property (nonatomic, copy, nullable) NSString *versionName;
@end

/// 导入器（一次实例只执行一次导入）
@interface A2ModPackInstaller : NSObject

/// 开始导入。
/// @param progress 阶段进度（stage, 该阶段进度 0~1, 说明文字）
/// @param completion 完成回调；success 为 NO 时 error 非空，versionName 为派生出的版本名
- (void)importRequest:(A2ModPackImportRequest *)request
             progress:(void (^)(A2ModPackImportStage stage, double progress, NSString *message))progress
           completion:(void (^)(BOOL success, NSString * _Nullable versionName, NSError * _Nullable error))completion;

/// 取消导入（会连带停掉在途下载）。取消后不再回调完成。
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
