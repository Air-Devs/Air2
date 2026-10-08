//
//  A2ModPack.h
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
//  整合包清单解析 —— 只建模，不执行下载。
//
//  格式决策（参考 ZL2 modpack/platform，不照抄实现）：
//    · CurseForge 包：根目录 manifest.json（manifestType=minecraftModpack），
//      文件项 projectID/fileID + 可选直链，否则按 fileID 拼 edge.forgecdn.net。
//    · Modrinth 包（.mrpack）：根目录 modrinth.index.json（game=minecraft），
//      文件项 path/downloads[0]/sha1/fileSize，env.server=required 的跳过
//      （启动器只要客户端侧）。
//    · 解析只产出“计划”（下什么、落哪），下载执行另起任务接 A2DownloadEngine。
//  只用 Foundation；zip 读取复用 A2ZipReader（不自己再写一份）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2ModPackFormat) {
    A2ModPackFormatUnknown = 0,
    A2ModPackFormatCurseForge,
    A2ModPackFormatModrinth,
};

/// 清单里的一个待下载文件（两种格式统一后）。
@interface A2ModPackFile : NSObject
/// 落盘相对路径（如 mods/foo.jar；CurseForge 的按 fileName 落 mods/）。
@property (nonatomic, copy, readonly) NSString *relativePath;
/// 首选下载地址（CurseForge 无直链时为拼出的 CDN 地址）。
@property (nonatomic, copy, readonly, nullable) NSString *downloadURL;
/// 期望 SHA1（Modrinth 有，CurseForge 无则 nil，下载后不做不存在的校验）。
@property (nonatomic, copy, readonly, nullable) NSString *sha1;
/// 期望字节数（未知为 -1）。
@property (nonatomic, assign, readonly) long long fileSize;
/// 是否必需（CurseForge required=false 的为可选）。
@property (nonatomic, assign, readonly) BOOL required;
- (instancetype)initWithRelativePath:(NSString *)relativePath
                         downloadURL:(nullable NSString *)downloadURL
                                sha1:(nullable NSString *)sha1
                            fileSize:(long long)fileSize
                            required:(BOOL)required NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// 解析出的安装计划。
@interface A2ModPackPlan : NSObject
@property (nonatomic, assign, readonly) A2ModPackFormat format;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly, nullable) NSString *version;
@property (nonatomic, copy, readonly, nullable) NSString *gameVersion;
@property (nonatomic, copy, readonly, nullable) NSString *loaderID;
/// 覆盖目录名（CurseForge overrides，Modrinth 同义为 overrides）。
@property (nonatomic, copy, readonly, nullable) NSString *overridesDir;
@property (nonatomic, copy, readonly) NSArray<A2ModPackFile *> *files;
@end

@interface A2ModPackParser : NSObject

/// 看 zip 里有没有两种清单，返回格式（不解析内容）。
+ (A2ModPackFormat)detectFormatOfZipAtPath:(NSString *)zipPath;

/// 解析成计划。格式不明/清单坏掉返回 nil 并填原因。
+ (nullable A2ModPackPlan *)parseZipAtPath:(NSString *)zipPath
                                     error:(NSError **)error;

@end

FOUNDATION_EXPORT NSString *const A2ModPackErrorDomain;

typedef NS_ENUM(NSInteger, A2ModPackError) {
    A2ModPackErrorUnreadableZip = 1,
    A2ModPackErrorUnsupportedFormat,
    A2ModPackErrorBadManifest,
};

NS_ASSUME_NONNULL_END
