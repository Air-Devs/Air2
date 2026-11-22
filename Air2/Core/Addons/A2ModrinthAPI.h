//
//  A2ModrinthAPI.h
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
//  Modrinth API 客户端。
//
//  公开 API，无需 Key：https://api.modrinth.com/v2
//  需要对所有请求设置 User-Agent（Modrinth 的要求，
//  不设会被限流或拒绝）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 项目类型
typedef NS_ENUM(NSInteger, A2ModrinthProjectType) {
    A2ModrinthProjectTypeMod = 0,
    A2ModrinthProjectTypeModpack,
    A2ModrinthProjectTypeResourcePack,
    A2ModrinthProjectTypeShader,
    A2ModrinthProjectTypeDatapack,
};

/// 搜索结果里的一个项目
@interface A2ModrinthProject : NSObject
@property (nonatomic, copy) NSString *projectID;
@property (nonatomic, copy) NSString *slug;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *projectDescription;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, assign) long long downloads;
@property (nonatomic, assign) long long followers;
@property (nonatomic, copy) NSArray<NSString *> *categories;
@property (nonatomic, copy, nullable) NSString *author;
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

/// 项目的某个版本
@interface A2ModrinthVersion : NSObject
@property (nonatomic, copy) NSString *versionID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *versionNumber;
@property (nonatomic, copy) NSArray<NSString *> *gameVersions;
@property (nonatomic, copy) NSArray<NSString *> *loaders;
@property (nonatomic, assign) NSInteger downloads;
@property (nonatomic, copy, nullable) NSString *datePublished;
@property (nonatomic, copy, nullable) NSString *changelog;
/// 主文件的下载地址
@property (nonatomic, copy, nullable) NSString *downloadURL;
@property (nonatomic, copy, nullable) NSString *fileName;
@property (nonatomic, assign) long long fileSize;
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

@interface A2ModrinthAPI : NSObject

+ (instancetype)shared;

/// 搜索项目
- (void)searchWithQuery:(nullable NSString *)query
                   type:(A2ModrinthProjectType)type
            gameVersion:(nullable NSString *)gameVersion
                 loader:(nullable NSString *)loader
                 offset:(NSInteger)offset
                  limit:(NSInteger)limit
             completion:(void (^)(NSArray<A2ModrinthProject *> * _Nullable results,
                                  NSError * _Nullable error))completion;

/// 取项目的所有版本
- (void)versionsForProject:(NSString *)projectID
              gameVersion:(nullable NSString *)gameVersion
                   loader:(nullable NSString *)loader
               completion:(void (^)(NSArray<A2ModrinthVersion *> * _Nullable versions,
                                    NSError * _Nullable error))completion;

/// 取项目详情
- (void)projectWithID:(NSString *)projectID
           completion:(void (^)(A2ModrinthProject * _Nullable project,
                                NSError * _Nullable error))completion;

/// 按 project_type 字符串搜索（供统一资源源调用）
/// @param categories 分类 tag 多选，组内为 OR 关系；nil 或空表示不限。
- (void)searchWithProjectType:(nullable NSString *)projectType
                        query:(nullable NSString *)query
                  gameVersion:(nullable NSString *)gameVersion
                       loader:(nullable NSString *)loader
                   categories:(nullable NSArray<NSString *> *)categories
                    sortField:(NSString *)sortField
                       offset:(NSInteger)offset
                        limit:(NSInteger)limit
                   completion:(void (^)(NSArray<A2ModrinthProject *> * _Nullable results,
                                        NSError * _Nullable error))completion;

/// 按 project_type 拉取可选分类（Modrinth /tag/category）
- (void)categoryTagsForProjectType:(nullable NSString *)projectType
                        completion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> * _Nullable tags,
                                             NSError * _Nullable error))completion;

/// 按文件的 SHA1 反查版本 —— 用于检查已装资源的更新
- (void)versionBySHA1:(NSString *)sha1
           completion:(void (^)(A2ModrinthVersion * _Nullable version,
                                NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
