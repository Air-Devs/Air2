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
//
//
//  A2ModPackInstaller.h
//  Air2
//
//  整合包安装 —— 对照 ZL2 的 download/modpack/（28 个文件）。
//
//  支持的格式（ZL2 支持四种，我们做前两种 —— 它们覆盖 99% 的实际使用）：
//
//    **Modrinth**（modrinth.index.json）
//      {
//        "game": "minecraft",
//        "versionId": "...",
//        "name": "...",
//        "files": [{ "path", "hashes": {"sha1"}, "downloads": [url], "fileSize" }],
//        "dependencies": { "minecraft": "1.20.1", "fabric-loader": "0.15.0" }
//      }
//      文件用绝对 path 指定目标位置。
//
//    **CurseForge**（manifest.json）
//      {
//        "minecraft": {
//          "version": "1.20.1",
//          "modLoaders": [{ "id": "fabric-0.15.0", "primary": true }]
//        },
//        "files": [{ "projectID", "fileID", "required" }],
//        "overrides": "overrides"
//      }
//      文件只给 projectID/fileID，要靠 CurseForge API 换下载地址。
//      另有 overrides 目录里的文件是原样覆盖，不走下载。
//
//  安装流程：
//    1. 解压整合包，找清单文件
//    2. 解析清单 → 游戏版本 + 加载器 + 文件列表
//    3. 若本地没有对应版本，先装游戏本体 + 加载器
//    4. 下载所有 mod/资源包到对应目录
//    5. 解压 overrides 覆盖
//
//    **MCBBS**（mcbbs.packmeta）
//      中文社区格式。结构是 MCBBSManifest：
//        { name, version, author, description, url, origins[], addons[], libraries[] }
//      origins 是「从哪下游戏本体」，addons 是内容文件。
//
//    **MultiMC**（mmc-pack.json）
//      MultiMC / Prism Launcher / ATLauncher 系通用。
//      结构是 components 列表，每项有 uid（如 net.minecraft / net.fabricmc.fabric-loader）
//      与 version —— 靠 uid 反推游戏版本与加载器。
//

#import <Foundation/Foundation.h>
#import "A2ContentSource.h"

NS_ASSUME_NONNULL_BEGIN

/// 整合包格式
typedef NS_ENUM(NSInteger, A2ModPackFormat) {
    A2ModPackFormatUnknown = 0,
    A2ModPackFormatModrinth,      ///< modrinth.index.json
    A2ModPackFormatCurseForge,    ///< manifest.json（CurseForge 版）
    A2ModPackFormatMCBBS,         ///< mcbbs.packmeta（中文社区格式）
    A2ModPackFormatMultiMC,       ///< mmc-pack.json（MultiMC 系，含 Prism/ATLauncher）
};

/// 清单里描述的一个待下载文件
@interface A2ModPackFile : NSObject
/// 相对游戏目录的目标路径（如 mods/xxx.jar）
@property (nonatomic, copy) NSString *relativePath;
/// 候选下载地址
@property (nonatomic, copy) NSArray<NSString *> *urls;
/// 期望的 SHA1（用于校验与去重）
@property (nonatomic, copy, nullable) NSString *sha1;
@property (nonatomic, assign) long long fileSize;
/// CurseForge 专用：项目与文件 ID（要靠 API 换地址）
@property (nonatomic, assign) NSInteger curseForgeProjectID;
@property (nonatomic, assign) NSInteger curseForgeFileID;
@end

/// 解析出来的整合包信息
@interface A2ModPackManifest : NSObject
@property (nonatomic, assign) A2ModPackFormat format;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *summary;
@property (nonatomic, copy) NSString *gameVersion;

/// 加载器标识（如 "fabric"）与版本号（如 "0.15.0"），无则 nil
@property (nonatomic, copy, nullable) NSString *loaderIdentifier;
@property (nonatomic, copy, nullable) NSString *loaderVersion;

@property (nonatomic, copy) NSArray<A2ModPackFile *> *files;
/// overrides 目录名（CurseForge 有，Modrinth 用 "overrides" 固定值）
@property (nonatomic, copy, nullable) NSString *overridesDir;
@end

@interface A2ModPackInstaller : NSObject

/// 探测某个 zip 是哪种整合包格式（不安装，只识别）
+ (A2ModPackFormat)detectFormatAtPath:(NSString *)zipPath;

/// 读取并解析清单
- (void)parseManifestAtPath:(NSString *)zipPath
                 completion:(void (^)(A2ModPackManifest * _Nullable manifest,
                                      NSError * _Nullable error))completion;

/// 安装整合包。
///
/// @param zipPath 整合包文件
/// @param versionName 目标版本名（会创建 versions/{name}/）
/// @param gameHome 游戏根目录
/// @param progress 进度回调
- (void)installPackAtPath:(NSString *)zipPath
              versionName:(NSString *)versionName
                 gameHome:(NSString *)gameHome
                 progress:(void (^)(double progress, NSString *message))progress
               completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
