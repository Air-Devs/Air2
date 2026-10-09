//
//  A2CurseForgeAPI.h
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
//  CurseForge API 客户端。
//
//  与 Modrinth 的差异：
//    · 需要 API Key（在 console.curseforge.com 申请）
//    · 请求要带两个头：x-api-key 和 Authorization: Bearer
//    · Minecraft 的 gameId 固定为 432
//    · 部分作者禁止第三方分发，能否下载要看项目的 allowModDistribution
//
//  Key 不硬编码在源码里 —— 从 Keychain / 设置读取。
//  硬编码会进 git 历史，且无法吊销。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// CurseForge 的资源分类（classId）
typedef NS_ENUM(NSInteger, A2CFClassID) {
    A2CFClassIDMod = 6,
    A2CFClassIDModpack = 4471,
    A2CFClassIDResourcePack = 12,
    A2CFClassIDShader = 6552,
    A2CFClassIDWorld = 17,
    A2CFClassIDDataPack = 6945,
};

/// Minecraft 在 CurseForge 的固定 ID
extern const NSInteger A2CFMinecraftGameID;

#pragma mark - 模型

/// 搜索结果里的一个项目
@interface A2CFProject : NSObject
@property (nonatomic, assign) NSInteger projectID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, assign) long long downloadCount;
@property (nonatomic, assign) NSInteger classID;
@property (nonatomic, copy, nullable) NSString *slug;
@property (nonatomic, copy, nullable) NSString *authorName;
/// 作者是否允许第三方分发（false 表示只能去官网下）
@property (nonatomic, assign) BOOL allowDistribution;
+ (nullable instancetype)fromJSON:(NSDictionary *)json;
@end

/// 项目的某个文件
@interface A2CFFile : NSObject
@property (nonatomic, assign) NSInteger fileID;
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *displayName;
/// 下载地址。为 nil 表示作者禁止第三方分发。
@property (nonatomic, copy, nullable) NSString *downloadURL;
@property (nonatomic, assign) long long fileLength;
/// 支持的 MC 版本（如 1.21.5）
@property (nonatomic, copy) NSArray<NSString *> *gameVersions;
+ (nullable instancetype)fromJSON:(NSDictionary *)json;
@end

#pragma mark - 客户端

@interface A2CurseForgeAPI : NSObject

+ (instancetype)shared;

/// API Key。不设置则所有请求都会失败。
/// 存 Keychain 而不是 UserDefaults —— 它是凭据。
@property (nonatomic, copy, nullable) NSString *apiKey;
+ (BOOL)hasAPIKey;
+ (void)setAPIKey:(nullable NSString *)key;

/// 测试 Key 是否有效
- (void)validateKeyWithCompletion:(void (^)(BOOL valid, NSError * _Nullable error))completion;

/// 搜索项目
/// @param loader 平台中立加载器标识（fabric / quilt / forge / neoforge…），
///               nil 表示不限。CurseForge 的数字码由本类内部换算，
///               调用方不需要知道 CurseForge 的枚举差异。
- (void)searchClassID:(A2CFClassID)classID
                query:(nullable NSString *)query
          gameVersion:(nullable NSString *)gameVersion
               loader:(nullable NSString *)loader
          categoryIDs:(nullable NSArray<NSString *> *)categoryIDs
            sortField:(nullable NSString *)sortField
               offset:(NSInteger)offset
                limit:(NSInteger)limit
           completion:(void (^)(NSArray<A2CFProject *> * _Nullable results,
                                NSError * _Nullable error))completion;

/// 拉取某 classId 下的可选分类（CurseForge /categories?gameId=432&classId=X）
- (void)categoriesForClassID:(NSInteger)classID
                  completion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> * _Nullable categories,
                                       NSError * _Nullable error))completion;

/// 按文件的 murmur2 哈希反查版本。
/// CurseForge 用 MurmurHash2 而不是 SHA1 —— 这是它自己的指纹体系。
/// @param murmur 本地按指纹规则算好的 murmur2（见 A2MurmurHash2 + 指纹剔除集）。
- (void)versionByMurmur:(uint32_t)murmur
             completion:(void (^)(A2CFFile * _Nullable file,
                                  NSError * _Nullable error))completion;

/// 按本地文件反查版本：本地算 murmur2 后调指纹接口。
/// 旧的 versionByMurmurHash:sha1 拿 SHA1 字符串查 CurseForge 是查不出的
/// （两种哈希体系不同），保留仅作兼容，始终返回 nil；新代码走本方法。
- (void)versionByLocalFileAtPath:(NSString *)path
                      completion:(void (^)(A2CFFile * _Nullable file,
                                           NSError * _Nullable error))completion;

/// CurseForge 指纹剔除的空白字节：\t \n \r 空格（与 ZL2 一致）。
+ (NSSet<NSNumber *> *)fingerprintSkipBytes;

- (void)versionByMurmurHash:(NSString *)sha1
                      size:(long long)size
                completion:(void (^)(A2CFFile * _Nullable file,
                                     NSError * _Nullable error))completion;

/// 取项目的文件列表
- (void)filesForProject:(NSInteger)projectID
            gameVersion:(nullable NSString *)gameVersion
             completion:(void (^)(NSArray<A2CFFile *> * _Nullable files,
                                  NSError * _Nullable error))completion;

/// 取项目详情
- (void)projectWithID:(NSInteger)projectID
           completion:(void (^)(A2CFProject * _Nullable project,
                                NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
