//
//  A2ContentSource.m
//  Air2
//

#import "A2ContentSource.h"
#import "A2ModrinthAPI.h"
#import "A2CurseForgeAPI.h"

#pragma mark - 统一条目

@implementation A2ContentItem
@end

@implementation A2ContentVersion
@end

#pragma mark - 统一资源源

@interface A2ContentSource ()
@property (nonatomic, assign) A2ContentPlatform platform;
/// 统一分类索引 → 各平台的分类
@property (nonatomic, copy) NSArray<NSNumber *> *cfClassIDs;
@end

@implementation A2ContentSource

+ (instancetype)sourceForPlatform:(A2ContentPlatform)platform {
    A2ContentSource *s = [A2ContentSource new];
    s.platform = platform;
    // CurseForge 的分类索引 → classId
    s.cfClassIDs = @[
        @(A2CFClassIDMod),          // 0
        @(A2CFClassIDModpack),      // 1
        @(A2CFClassIDResourcePack), // 2
        @(A2CFClassIDShader),       // 3
        @(A2CFClassIDWorld),        // 4
    ];
    return s;
}

- (BOOL)isAvailable {
    if (self.platform == A2ContentPlatformCurseForge) {
        return [A2CurseForgeAPI hasAPIKey];
    }
    return YES;   // Modrinth 无需 Key
}

- (NSString *)unavailableReason {
    if (self.platform == A2ContentPlatformCurseForge && ![A2CurseForgeAPI hasAPIKey]) {
        return @"CurseForge 需要 API Key，请在设置中填写";
    }
    return nil;
}

#pragma mark 搜索

- (void)searchWithQuery:(NSString *)query
               category:(NSInteger)categoryIndex
            gameVersion:(NSString *)gameVersion
                 loader:(NSString *)loader
                 offset:(NSInteger)offset
                  limit:(NSInteger)limit
             completion:(void (^)(NSArray<A2ContentItem *> *, NSError *))completion {

    if (self.platform == A2ContentPlatformModrinth) {
        [self searchModrinth:query category:categoryIndex gameVersion:gameVersion
                      loader:loader offset:offset limit:limit completion:completion];
    } else {
        [self searchCurseForge:query category:categoryIndex gameVersion:gameVersion
                        offset:offset limit:limit completion:completion];
    }
}

- (void)searchModrinth:(NSString *)query
              category:(NSInteger)categoryIndex
           gameVersion:(NSString *)gameVersion
                loader:(NSString *)loader
                offset:(NSInteger)offset
                 limit:(NSInteger)limit
            completion:(void (^)(NSArray<A2ContentItem *> *, NSError *))completion {

    // 统一索引 → Modrinth 的项目类型
    A2ModrinthProjectType type = A2ModrinthProjectTypeMod;
    switch (categoryIndex) {
        case 1: type = A2ModrinthProjectTypeModpack; break;
        case 2: type = A2ModrinthProjectTypeResourcePack; break;
        case 3: type = A2ModrinthProjectTypeShader; break;
        case 4: type = A2ModrinthProjectTypeDatapack; break;
        default: type = A2ModrinthProjectTypeMod; break;
    }

    [[A2ModrinthAPI shared] searchWithQuery:query
                                       type:type
                                gameVersion:gameVersion
                                     loader:loader
                                     offset:offset
                                      limit:limit
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
            item.author = p.author;
            item.categories = p.categories;
            item.downloadable = YES;   // Modrinth 所有项目都可下载
            [out addObject:item];
        }
        if (completion) completion(out, nil);
    }];
}

- (void)searchCurseForge:(NSString *)query
                category:(NSInteger)categoryIndex
             gameVersion:(NSString *)gameVersion
                  offset:(NSInteger)offset
                   limit:(NSInteger)limit
              completion:(void (^)(NSArray<A2ContentItem *> *, NSError *))completion {

    A2CFClassID classID = A2CFClassIDMod;
    if (categoryIndex >= 0 && categoryIndex < (NSInteger)self.cfClassIDs.count) {
        classID = (A2CFClassID)self.cfClassIDs[categoryIndex].integerValue;
    }

    [[A2CurseForgeAPI shared] searchClassID:classID
                                      query:query
                                gameVersion:gameVersion
                                     offset:offset
                                      limit:limit
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
            // 作者禁止分发时标记为不可下载，UI 会显示提示
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
                A2ContentVersion *item = [A2ContentVersion new];
                item.versionID = v.versionID;
                item.displayName = v.versionNumber.length ? v.versionNumber : v.name;
                item.gameVersions = v.gameVersions;
                item.loaders = v.loaders;
                item.downloadURL = v.downloadURL;
                item.fileName = v.fileName;
                item.fileSize = v.fileSize;
                [out addObject:item];
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
                A2ContentVersion *item = [A2ContentVersion new];
                item.versionID = [@(f.fileID) stringValue];
                item.displayName = f.displayName;
                item.gameVersions = f.gameVersions;
                item.loaders = @[];
                // downloadUrl 为 nil 表示作者禁止第三方分发
                item.downloadURL = f.downloadURL;
                item.fileName = f.fileName;
                item.fileSize = f.fileLength;
                [out addObject:item];
            }
            if (completion) completion(out, nil);
        }];
    }
}

@end
