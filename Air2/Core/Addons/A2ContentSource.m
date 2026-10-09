//
//  A2ContentSource.m
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

#import "A2ContentSource.h"
#import "A2ModrinthAPI.h"
#import "A2CurseForgeAPI.h"
#import "A2MirrorResolver.h"
#import "A2Settings.h"

// 首选平台 key 收敛到 A2Settings，不再本地定义。

#pragma mark - 排序字段映射

/// CurseForge 的排序码。
/// 取自 ZL2 的 PlatformSortField（其值来自 CurseForge 官方文档）。
NSString *A2SortValueForCurseForge(A2ContentSortField f) {
    switch (f) {
        case A2ContentSortFieldRelevance:  return @"1";
        case A2ContentSortFieldDownloads:  return @"6";
        case A2ContentSortFieldPopularity: return @"2";
        case A2ContentSortFieldNewest:     return @"11";
        case A2ContentSortFieldUpdated:    return @"3";
    }
    return @"1";
}

/// Modrinth 的排序名
NSString *A2SortValueForModrinth(A2ContentSortField f) {
    switch (f) {
        case A2ContentSortFieldRelevance:  return @"relevance";
        case A2ContentSortFieldDownloads:  return @"downloads";
        case A2ContentSortFieldPopularity: return @"follows";
        case A2ContentSortFieldNewest:     return @"newest";
        case A2ContentSortFieldUpdated:    return @"updated";
    }
    return @"relevance";
}

NSString *A2SortDisplayName(A2ContentSortField f) {
    switch (f) {
        case A2ContentSortFieldRelevance:  return @"相关度";
        case A2ContentSortFieldDownloads:  return @"下载量";
        case A2ContentSortFieldPopularity: return @"人气";
        case A2ContentSortFieldNewest:     return @"最新发布";
        case A2ContentSortFieldUpdated:    return @"最近更新";
    }
    return @"相关度";
}

NSArray<NSNumber *> *A2AllSortFields(void) {
    return @[
        @(A2ContentSortFieldRelevance),
        @(A2ContentSortFieldDownloads),
        @(A2ContentSortFieldPopularity),
        @(A2ContentSortFieldNewest),
        @(A2ContentSortFieldUpdated),
    ];
}

#pragma mark - 分类映射

/// CurseForge classId —— 与 ZL2 的 CurseForgeClassID 一致
NSInteger A2ClassIDForCurseForge(A2ContentClass c) {
    switch (c) {
        case A2ContentClassMod:          return 6;
        case A2ContentClassModPack:      return 4471;
        case A2ContentClassResourcePack: return 12;
        case A2ContentClassShader:       return 6552;
        case A2ContentClassWorld:        return 17;
        case A2ContentClassDataPack:     return 6945;
    }
    return 6;
}

/// Modrinth project_type facet
NSString *A2ProjectTypeForModrinth(A2ContentClass c) {
    switch (c) {
        case A2ContentClassMod:          return @"mod";
        case A2ContentClassModPack:      return @"modpack";
        case A2ContentClassResourcePack: return @"resourcepack";
        case A2ContentClassShader:       return @"shader";
        case A2ContentClassWorld:        return @"datapack";   // Modrinth 无存档分类，用 datapack 兜底
        case A2ContentClassDataPack:     return @"datapack";
    }
    return @"mod";
}

/// 对应的版本隔离目录名 —— 与 A2VersionFolder 对齐
NSString *A2VersionFolderForClass(A2ContentClass c) {
    switch (c) {
        case A2ContentClassMod:          return @"mods";
        case A2ContentClassModPack:      return @"modpacks";
        case A2ContentClassResourcePack: return @"resourcepacks";
        case A2ContentClassShader:       return @"shaderpacks";
        case A2ContentClassWorld:        return @"saves";
        case A2ContentClassDataPack:     return @"datapacks";
    }
    return @"mods";
}

NSString *A2ClassDisplayName(A2ContentClass c) {
    switch (c) {
        case A2ContentClassMod:          return @"模组";
        case A2ContentClassModPack:      return @"整合包";
        case A2ContentClassResourcePack: return @"资源包";
        case A2ContentClassShader:       return @"光影";
        case A2ContentClassWorld:        return @"存档";
        case A2ContentClassDataPack:     return @"数据包";
    }
    return @"模组";
}

NSArray<NSNumber *> *A2AllContentClasses(void) {
    return @[
        @(A2ContentClassMod),
        @(A2ContentClassModPack),
        @(A2ContentClassResourcePack),
        @(A2ContentClassShader),
        @(A2ContentClassWorld),
    ];
}

#pragma mark - 模型

@implementation A2ContentItem
@end

@implementation A2ContentVersion
@end

@implementation A2ContentFilter

+ (instancetype)defaultFilter {
    A2ContentFilter *f = [A2ContentFilter new];
    f.sortField = A2ContentSortFieldRelevance;
    f.limit = 20;
    return f;
}

@end

#pragma mark - 资源源

@interface A2ContentSource ()
@property (nonatomic, assign) A2ContentPlatform platform;
@end

@implementation A2ContentSource

+ (instancetype)sourceForPlatform:(A2ContentPlatform)platform {
    A2ContentSource *s = [A2ContentSource new];
    s.platform = platform;
    return s;
}

+ (A2ContentPlatform)preferredPlatform {
    NSInteger v = A2Settings.shared.preferredContentPlatform;
    return (v == 1) ? A2ContentPlatformCurseForge : A2ContentPlatformModrinth;
}

+ (void)setPreferredPlatform:(A2ContentPlatform)platform {
    A2Settings.shared.preferredContentPlatform = (NSInteger)platform;
}

- (NSString *)displayName {
    return (self.platform == A2ContentPlatformModrinth) ? @"Modrinth" : @"CurseForge";
}

- (BOOL)isAvailable {
    if (self.platform == A2ContentPlatformCurseForge) {
        return [A2CurseForgeAPI hasAPIKey];
    }
    return YES;
}

- (NSString *)unavailableReason {
    if (self.platform == A2ContentPlatformCurseForge && ![A2CurseForgeAPI hasAPIKey]) {
        return @"CurseForge 需要 API Key，请在设置 → 资源下载中填写";
    }
    return nil;
}

#pragma mark 搜索

- (void)searchWithFilter:(A2ContentFilter *)filter
            contentClass:(A2ContentClass)contentClass
              completion:(void (^)(NSArray<A2ContentItem *> *, NSError *))completion {

    if (!self.isAvailable) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"A2ContentSource" code:1
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           self.unavailableReason ?: @"源不可用"}]);
        }
        return;
    }

    if (self.platform == A2ContentPlatformModrinth) {
        [self searchModrinth:filter contentClass:contentClass completion:completion];
    } else {
        [self searchCurseForge:filter contentClass:contentClass completion:completion];
    }
}

- (void)searchModrinth:(A2ContentFilter *)filter
          contentClass:(A2ContentClass)contentClass
            completion:(void (^)(NSArray<A2ContentItem *> *, NSError *))completion {

    [[A2ModrinthAPI shared] searchWithProjectType:A2ProjectTypeForModrinth(contentClass)
                                            query:filter.query
                                      gameVersion:filter.gameVersion
                                           loader:filter.loader
                                        sortField:A2SortValueForModrinth(filter.sortField)
                                           offset:filter.offset
                                            limit:filter.limit
                                       completion:^(NSArray<A2ModrinthProject *> *results,
                                                    NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }

        NSMutableArray<A2ContentItem *> *out = [NSMutableArray array];
        for (A2ModrinthProject *p in results) {
            A2ContentItem *item = [A2ContentItem new];
            item.platform = A2ContentPlatformModrinth;
            item.projectID = p.projectID;
            item.title = p.title;
            item.summary = p.projectDescription;
            item.iconURL = p.iconURL;
            item.downloadCount = p.downloads;
            item.followCount = p.followers;
            item.author = p.author;
            item.categories = p.categories;
            item.downloadable = YES;   // Modrinth 全部可下载
            [out addObject:item];
        }
        if (completion) completion(out, nil);
    }];
}

- (void)searchCurseForge:(A2ContentFilter *)filter
            contentClass:(A2ContentClass)contentClass
              completion:(void (^)(NSArray<A2ContentItem *> *, NSError *))completion {

    [[A2CurseForgeAPI shared] searchClassID:A2ClassIDForCurseForge(contentClass)
                                      query:filter.query
                                gameVersion:filter.gameVersion
                                     loader:filter.loader
                                  sortField:A2SortValueForCurseForge(filter.sortField)
                                     offset:filter.offset
                                      limit:filter.limit
                                 completion:^(NSArray<A2CFProject *> *results,
                                              NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }

        NSMutableArray<A2ContentItem *> *out = [NSMutableArray array];
        for (A2CFProject *p in results) {
            A2ContentItem *item = [A2ContentItem new];
            item.platform = A2ContentPlatformCurseForge;
            item.projectID = [@(p.projectID) stringValue];
            item.title = p.name;
            item.summary = p.summary;
            item.iconURL = p.iconURL;
            item.downloadCount = p.downloadCount;
            item.author = p.authorName;
            item.categories = @[];
            // 作者禁止分发时标记为不可下载
            item.downloadable = p.allowDistribution;
            [out addObject:item];
        }
        if (completion) completion(out, nil);
    }];
}

#pragma mark 版本列表

- (void)versionsForProject:(NSString *)projectID
               gameVersion:(NSString *)gameVersion
                    loader:(NSString *)loader
                completion:(void (^)(NSArray<A2ContentVersion *> *, NSError *))completion {

    if (self.platform == A2ContentPlatformModrinth) {
        [[A2ModrinthAPI shared] versionsForProject:projectID
                                       gameVersion:gameVersion
                                            loader:loader
                                        completion:^(NSArray<A2ModrinthVersion *> *versions,
                                                     NSError *error) {
            if (error) { if (completion) completion(nil, error); return; }
            NSMutableArray<A2ContentVersion *> *out = [NSMutableArray array];
            for (A2ModrinthVersion *v in versions) {
                [out addObject:[self versionFromModrinth:v projectID:projectID]];
            }
            if (completion) completion(out, nil);
        }];
    } else {
        [[A2CurseForgeAPI shared] filesForProject:projectID.integerValue
                                      gameVersion:gameVersion
                                       completion:^(NSArray<A2CFFile *> *files,
                                                    NSError *error) {
            if (error) { if (completion) completion(nil, error); return; }
            NSMutableArray<A2ContentVersion *> *out = [NSMutableArray array];
            for (A2CFFile *f in files) {
                [out addObject:[self versionFromCurseForge:f projectID:projectID]];
            }
            if (completion) completion(out, nil);
        }];
    }
}

- (A2ContentVersion *)versionFromModrinth:(A2ModrinthVersion *)v projectID:(NSString *)pid {
    A2ContentVersion *item = [A2ContentVersion new];
    item.versionID = v.versionID;
    item.projectID = pid;
    item.displayName = v.name.length ? v.name : v.versionNumber;
    item.versionNumber = v.versionNumber;
    item.gameVersions = v.gameVersions;
    item.loaders = v.loaders;
    item.fileName = v.fileName;
    item.fileSize = v.fileSize;
    // 展开镜像候选
    item.candidateURLs = v.downloadURL.length
        ? [[A2MirrorResolver shared] candidateURLsForURL:v.downloadURL] : @[];
    return item;
}

- (A2ContentVersion *)versionFromCurseForge:(A2CFFile *)f projectID:(NSString *)pid {
    A2ContentVersion *item = [A2ContentVersion new];
    item.versionID = [@(f.fileID) stringValue];
    item.projectID = pid;
    item.displayName = f.displayName;
    item.versionNumber = f.displayName;
    item.gameVersions = f.gameVersions;
    item.loaders = @[];   // CurseForge 的文件不带加载器字段
    item.fileName = f.fileName;
    item.fileSize = f.fileLength;
    // downloadUrl 为 nil 表示作者禁止第三方分发
    item.candidateURLs = f.downloadURL.length
        ? [[A2MirrorResolver shared] candidateURLsForURL:f.downloadURL] : @[];
    return item;
}

#pragma mark 项目详情

- (void)projectWithID:(NSString *)projectID
           completion:(void (^)(A2ContentItem *, NSError *))completion {

    if (self.platform == A2ContentPlatformModrinth) {
        [[A2ModrinthAPI shared] projectWithID:projectID
                                   completion:^(A2ModrinthProject *p, NSError *error) {
            if (error) { if (completion) completion(nil, error); return; }
            A2ContentItem *item = [A2ContentItem new];
            item.platform = A2ContentPlatformModrinth;
            item.projectID = p.projectID;
            item.title = p.title;
            item.summary = p.projectDescription;
            item.iconURL = p.iconURL;
            item.downloadCount = p.downloads;
            item.author = p.author;
            item.categories = p.categories;
            item.downloadable = YES;
            if (completion) completion(item, nil);
        }];
    } else {
        [[A2CurseForgeAPI shared] projectWithID:projectID.integerValue
                                     completion:^(A2CFProject *p, NSError *error) {
            if (error) { if (completion) completion(nil, error); return; }
            A2ContentItem *item = [A2ContentItem new];
            item.platform = A2ContentPlatformCurseForge;
            item.projectID = [@(p.projectID) stringValue];
            item.title = p.name;
            item.summary = p.summary;
            item.iconURL = p.iconURL;
            item.downloadCount = p.downloadCount;
            item.author = p.authorName;
            item.downloadable = p.allowDistribution;
            if (completion) completion(item, nil);
        }];
    }
}

#pragma mark SHA1 反查（检查更新用）

- (void)versionByLocalFileSHA1:(NSString *)sha1
                         size:(long long)size
                   completion:(void (^)(A2ContentVersion *, NSError *))completion {

    if (sha1.length == 0) {
        if (completion) completion(nil, nil);
        return;
    }

    if (self.platform == A2ContentPlatformModrinth) {
        // Modrinth 支持按 SHA1 直接查版本
        [[A2ModrinthAPI shared] versionBySHA1:sha1 completion:^(A2ModrinthVersion *v, NSError *error) {
            if (error || !v) { if (completion) completion(nil, error); return; }
            A2ContentVersion *item = [A2ContentVersion new];
            item.versionID = v.versionID;
            item.displayName = v.name;
            item.versionNumber = v.versionNumber;
            item.gameVersions = v.gameVersions;
            item.loaders = v.loaders;
            item.fileName = v.fileName;
            item.fileSize = v.fileSize;
            item.candidateURLs = v.downloadURL.length
                ? [[A2MirrorResolver shared] candidateURLsForURL:v.downloadURL] : @[];
            if (completion) completion(item, nil);
        }];
    } else {
        // CurseForge 用 fingerprints 接口按 murmur2 哈希查
        [[A2CurseForgeAPI shared] versionByMurmurHash:sha1 size:size
                                           completion:^(A2CFFile *f, NSError *error) {
            if (error || !f) { if (completion) completion(nil, error); return; }
            A2ContentVersion *item = [A2ContentVersion new];
            item.versionID = [@(f.fileID) stringValue];
            item.displayName = f.displayName;
            item.fileName = f.fileName;
            item.fileSize = f.fileLength;
            item.gameVersions = f.gameVersions;
            item.candidateURLs = f.downloadURL.length
                ? [[A2MirrorResolver shared] candidateURLsForURL:f.downloadURL] : @[];
            if (completion) completion(item, nil);
        }];
    }
}

@end
