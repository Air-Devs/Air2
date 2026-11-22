//
//  A2ModLoaderInstaller.h
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
//  把模组加载器真正装进版本目录。
//
//  各家机制不同：
//
//  **Fabric 系**（Fabric / Quilt / LegacyFabric）
//    从 meta 服务取 profile json，里面含完整的启动配置
//    （mainClass / libraries / arguments）。
//    我们只需：
//      1. 下载 profile json
//      2. 与它 inheritFrom 指定的原版 json 合并
//      3. 下载 profile 里声明的额外依赖库
//    这是最简单的，因为 meta 服务直接给了成品。
//
//  **Forge / NeoForge**
//    官方只提供 installer jar，标准做法是跑 `java -jar installer --installClient`。
//    iOS 上不方便在安装期启动 JVM，我们改为：
//      1. 下载 installer jar
//      2. 从 jar 里读 install_profile.json / version.json
//      3. 按其声明的坐标构造 libraries 列表，直接下 maven 依赖
//      4. 合并生成版本 json
//    跳过需要执行代码的 processors 步骤 —— 那些是给旧版本做字节码
//    修补用的，现代版本多数不需要。
//
//  不支持自动安装的（OptiFine / Babric / LiteLoader 等）
//    这些官方没有稳定的自动化接口，ZL2 也标记为 autoDownloadable = false。
//    我们同样不假装支持，UI 上明确标注需要手动安装。
//

#import <Foundation/Foundation.h>
#import "A2ModLoaderAPI.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2ModLoaderInstaller : NSObject

/// 安装加载器到指定版本。
///
/// @param loader   加载器版本
/// @param mcVersion 对应的原版 MC 版本名（原版必须先装好）
/// @param versionName 目标版本名（如 1.21.5-fabric）
/// @param gameHome 游戏根目录
/// @param progress 进度（0~1, 说明）
/// @param completion 完成回调
- (void)installLoader:(A2ModLoaderVersion *)loader
            mcVersion:(NSString *)mcVersion
          versionName:(NSString *)versionName
             gameHome:(NSString *)gameHome
             progress:(void (^)(double progress, NSString *message))progress
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// 该加载器是否支持自动安装
+ (BOOL)supportsAutoInstall:(A2ModLoaderType)type;

@end

NS_ASSUME_NONNULL_END
