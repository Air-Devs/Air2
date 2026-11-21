//
//  A2ModPackExporter.h
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
//  A2ModPackExporter.h
//  Air2
//
//  整合包导出 —— 对照 ZL2 的 game/version/export/。
//
//  支持的格式（各自要求的字段不同，这与 ZL2 的 PackType 一致）：
//
//    **Modrinth**（.mrpack）
//      需要：简介、项目 ID（Modrinth 与 CurseForge 各一）
//      结构：modrinth.index.json + overrides/
//
//    **CurseForge**（.zip）
//      需要：作者、CurseForge 项目 ID、最低内存
//      结构：manifest.json + overrides/
//
//  导出流程：
//    1. 扫描版本目录，识别哪些文件来自平台（比对已知的项目）
//    2. 平台文件写入清单（记 URL 与 hash），不打包内容
//    3. 非平台文件（本地自制的 mod、配置）打进 overrides/
//    4. 生成清单 json，整体打包
//
//  为什么平台文件不打包：
//    整合包规范就是只存「从哪下的」，接收方自己下载。
//    这样包体积小得多，也避免二次分发他人的 mod。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2PackExportFormat) {
    A2PackExportFormatModrinth = 0,
    A2PackExportFormatCurseForge,
};

/// 导出参数
@interface A2PackExportOptions : NSObject
@property (nonatomic, copy) NSString *packName;
@property (nonatomic, copy, nullable) NSString *summary;
@property (nonatomic, copy, nullable) NSString *author;
@property (nonatomic, copy, nullable) NSString *version;

/// 平台项目 ID（该整合包在平台上的 ID，不是里面 mod 的）
@property (nonatomic, copy, nullable) NSString *modrinthProjectID;
@property (nonatomic, copy, nullable) NSString *curseForgeProjectID;

/// 最低内存要求（MB），CurseForge 格式用
@property (nonatomic, assign) NSInteger minimumMemoryMB;

/// 要导出的文件相对路径（相对版本目录）。
/// nil 表示导出全部 —— 但会跳过 logs / crash-reports 这类无意义目录。
@property (nonatomic, copy, nullable) NSArray<NSString *> *selectedPaths;
@end

@interface A2ModPackExporter : NSObject

/// 扫描版本目录，列出「可选导出」的文件（供 UI 勾选）
- (void)scanVersionAtPath:(NSString *)versionPath
               completion:(void (^)(NSArray<NSString *> *relativePaths))completion;

/// 导出整合包。
///
/// @param versionPath 版本目录
/// @param format 导出格式
/// @param options 参数
/// @param outputPath 输出文件路径（.mrpack 或 .zip）
- (void)exportVersionAtPath:(NSString *)versionPath
                     format:(A2PackExportFormat)format
                    options:(A2PackExportOptions *)options
                 outputPath:(NSString *)outputPath
                   progress:(void (^)(double progress, NSString *message))progress
                 completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
