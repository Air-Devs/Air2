//
//  A2ContentSource.h
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
//  资源源统一抽象 —— 设计对齐 ZL2 的 assets/platform：
//    AbstractPlatformSearcher / PlatformSearchFilter / PlatformSortField
//
//  ZL2 的两个关键设计我照搬：
//
//  **1. 排序字段用一个枚举同时携带两家的值**
//     PlatformSortField(RELEVANCE, DOWNLOADS, ...) 里
//     每个枚举项直属 curseforge 值和 modrinth 值。
//     这样新增排序方式只需加一个枚举项，不用改两处 switch。
//
//  **2. 分类也是一对多映射**
//     PlatformClasses(MOD, MOD_PACK, ...) 里同时给出
//     CurseForge 的 classId 与 Modrinth 的 project_type，
//     还带上对应的版本隔离目录名。
//
//  另外补了 ZL2 有而我没做的能力：
//    getVersionByLocalFile(sha1) —— 通过本地文件反查项目，用于检查更新
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2ContentPlatform) {
    A2ContentPlatformModrinth = 0,
    A2ContentPlatformCurseForge,
};

#pragma mark - 排序字段

/// 排序方式。每个枚举项同时给出两家平台的实际取值。
///
/// CurseForge 用数字码，Modrinth 用字符串 —— 差异在这里一次抹平，
/// 调用方只需说「按下载量排序」。
typedef NS_ENUM(NSInteger, A2ContentSortField) {
    A2ContentSortFieldRelevance = 0,
    A2ContentSortFieldDownloads,
    A2ContentSortFieldPopularity,
    A2ContentSortFieldNewest,
    A2ContentSortFieldUpdated,
};

/// 取该排序在两家的实际参数值
FOUNDATION_EXPORT NSString *A2SortValueForCurseForge(A2ContentSortField f);
FOUNDATION_EXPORT NSString *A2SortValueForModrinth(A2ContentSortField f);
FOUNDATION_EXPORT NSString *A2SortDisplayName(A2ContentSortField f);
/// 全部排序方式（供 UI 列出）
FOUNDATION_EXPORT NSArray<NSNumber *> *A2AllSortFields(void);

#pragma mark - 资源分类

/// 资源大类。每个枚举项同时给出两家的分类标识与版本隔离目录名。
typedef NS_ENUM(NSInteger, A2ContentClass) {
    A2ContentClassMod = 0,
    A2ContentClassModPack,
    A2ContentClassResourcePack,
    A2ContentClassShader,
    A2ContentClassWorld,
    A2ContentClassDataPack,
};

FOUNDATION_EXPORT NSInteger A2ClassIDForCurseForge(A2ContentClass c);
/// Modrinth 的 project_type。world 分类在 Modrinth 不存在，返回 nil。
FOUNDATION_EXPORT NSString * _Nullable A2ProjectTypeForModrinth(A2ContentClass c);
FOUNDATION_EXPORT NSString *A2VersionFolderForClass(A2ContentClass c);
FOUNDATION_EXPORT NSString *A2ClassDisplayName(A2ContentClass c);
FOUNDATION_EXPORT NSArray<NSNumber *> *A2AllContentClasses(void);

#pragma mark - 资源分类项

/// 平台内的资源分类项（用于筛选面板的「资源分类」多选）
@interface A2ContentCategory : NSObject
/// 传给 A2ContentFilter.categories 的标识（Modrinth 为分类 tag 名；CurseForge 为 categoryId 字符串）
@property (nonatomic, copy) NSString *identifier;
/// 展示名
@property (nonatomic, copy) NSString *displayName;
@end

#pragma mark - 数据模型

/// 统一的资源条目
@interface A2ContentItem : NSObject
@property (nonatomic, assign) A2ContentPlatform platform;
/// 平台内的项目标识（Modrinth 是字符串，CurseForge 是数字的字符串形式）
@property (nonatomic, copy) NSString *projectID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, assign) long long downloadCount;
@property (nonatomic, assign) long long followCount;
@property (nonatomic, copy, nullable) NSString *author;
@property (nonatomic, copy) NSArray<NSString *> *categories;
@property (nonatomic, copy, nullable) NSString *dateModified;
/// 是否允许第三方下载（CurseForge 上部分作者禁止）
@property (nonatomic, assign) BOOL downloadable;
@end

/// 统一的文件版本
@interface A2ContentVersion : NSObject
@property (nonatomic, copy) NSString *versionID;
/// 所属项目 ID（SHA1 反查时用得上）
@property (nonatomic, copy, nullable) NSString *projectID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *versionNumber;
@property (nonatomic, copy) NSArray<NSString *> *gameVersions;
@property (nonatomic, copy) NSArray<NSString *> *loaders;
/// 下载地址（已含候选，会按镜像设置展开）
@property (nonatomic, copy) NSArray<NSString *> *candidateURLs;
@property (nonatomic, copy, nullable) NSString *fileName;
@property (nonatomic, assign) long long fileSize;
@end

/// 统一的搜索条件（对应 ZL2 的 PlatformSearchFilter）
@interface A2ContentFilter : NSObject
@property (nonatomic, copy, nullable) NSString *query;
@property (nonatomic, copy, nullable) NSString *gameVersion;
@property (nonatomic, copy, nullable) NSString *loader;
/// 资源分类多选。元素为 A2ContentCategory.identifier；空数组表示不限。
@property (nonatomic, copy) NSArray<NSString *> *categories;
@property (nonatomic, assign) A2ContentSortField sortField;
@property (nonatomic, assign) NSInteger offset;
@property (nonatomic, assign) NSInteger limit;
+ (instancetype)defaultFilter;
@end

#pragma mark - 资源源

@interface A2ContentSource : NSObject

/// 取指定平台的资源源
+ (instancetype)sourceForPlatform:(A2ContentPlatform)platform;
/// 当前用户选择的平台
+ (A2ContentPlatform)preferredPlatform;
+ (void)setPreferredPlatform:(A2ContentPlatform)platform;

@property (nonatomic, assign, readonly) A2ContentPlatform platform;
@property (nonatomic, copy, readonly) NSString *displayName;
@property (nonatomic, assign, readonly, getter=isAvailable) BOOL available;
@property (nonatomic, copy, nullable, readonly) NSString *unavailableReason;

/// 该平台是否支持某资源大类。Modrinth 不提供存档（World），返回 NO；其余 YES。
- (BOOL)supportsContentClass:(A2ContentClass)c;

/// 拉取某资源大类的可选分类（用于筛选面板）
- (void)categoriesForContentClass:(A2ContentClass)c
                       completion:(void (^)(NSArray<A2ContentCategory *> * _Nullable categories,
                                            NSError * _Nullable error))completion;

/// 搜索
- (void)searchWithFilter:(A2ContentFilter *)filter
                 contentClass:(A2ContentClass)contentClass
                   completion:(void (^)(NSArray<A2ContentItem *> * _Nullable items,
                                        NSError * _Nullable error))completion;

/// 取项目的版本列表
- (void)versionsForProject:(NSString *)projectID
               gameVersion:(nullable NSString *)gameVersion
                    loader:(nullable NSString *)loader
                completion:(void (^)(NSArray<A2ContentVersion *> * _Nullable versions,
                                     NSError * _Nullable error))completion;

/// 取项目详情
- (void)projectWithID:(NSString *)projectID
           completion:(void (^)(A2ContentItem * _Nullable item,
                                NSError * _Nullable error))completion;

/// 通过本地文件的 SHA1 反查是哪个项目的哪个版本。
/// 用于「检查已安装资源的更新」。
- (void)versionByLocalFileSHA1:(NSString *)sha1
                         size:(long long)size
                   completion:(void (^)(A2ContentVersion * _Nullable version,
                                        NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
