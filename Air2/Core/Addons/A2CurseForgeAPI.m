//
//  A2CurseForgeAPI.m
//  Air2
//

#import "A2CurseForgeAPI.h"

NSString *const A2CurseForgeErrorDomain = @"A2CurseForge";

static NSString *const kBaseURL = @"https://api.curseforge.com/v1";
/// Minecraft 在 CurseForge 的游戏 ID
static const long long kMinecraftGameID = 432;
/// 整合包分类 ID
static const NSInteger kModpackClassID = 4471;
/// API Key 暂存键，等设置模块就位后迁走
static NSString *const kAPIKeyDefaultsKey = @"A2CurseForgeAPIKey";
/// 批量接口的单次上限，官方允许更大，这里控到 100 以稳住请求体量
static const NSUInteger kBatchChunkSize = 100;
/// 搜索页大小上限
static const NSInteger kMaxPageSize = 50;

/// 回调统一回到主线程 —— 调用方（UI 层）不该关心线程问题
static void dispatch_main_async(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

#pragma mark - 项目

@implementation A2CurseForgeProject

+ (instancetype)fromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    A2CurseForgeProject *p = [A2CurseForgeProject new];
    p.projectID = [json[@"id"] longLongValue];
    p.name = [json[@"name"] isKindOfClass:NSString.class] ? json[@"name"] : @"";
    p.slug = [json[@"slug"] isKindOfClass:NSString.class] ? json[@"slug"] : @"";
    p.projectDescription = [json[@"summary"] isKindOfClass:NSString.class] ? json[@"summary"] : @"";
    p.downloads = [json[@"downloadCount"] longLongValue];
    p.classID = [json[@"classId"] integerValue];

    NSDictionary *logo = [json[@"logo"] isKindOfClass:NSDictionary.class] ? json[@"logo"] : nil;
    p.iconURL = [logo[@"thumbnailUrl"] isKindOfClass:NSString.class] ? logo[@"thumbnailUrl"] : nil;

    NSArray *authors = [json[@"authors"] isKindOfClass:NSArray.class] ? json[@"authors"] : @[];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id raw in authors) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSString *name = raw[@"name"];
        if ([name isKindOfClass:NSString.class]) [names addObject:name];
    }
    p.authors = names;
    return p;
}

@end

#pragma mark - 文件

@implementation A2CurseForgeFile

+ (instancetype)fromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    A2CurseForgeFile *f = [A2CurseForgeFile new];
    f.fileID = [json[@"id"] longLongValue];
    f.projectID = [json[@"modId"] longLongValue];
    f.displayName = [json[@"displayName"] isKindOfClass:NSString.class] ? json[@"displayName"] : @"";
    f.fileName = [json[@"fileName"] isKindOfClass:NSString.class] ? json[@"fileName"] : @"";
    f.fileLength = [json[@"fileLength"] longLongValue];
    f.downloadURL = [json[@"downloadUrl"] isKindOfClass:NSString.class] ? json[@"downloadUrl"] : nil;

    // algo 1 = SHA1，2 = MD5；下载校验只用 SHA1
    NSArray *hashes = [json[@"hashes"] isKindOfClass:NSArray.class] ? json[@"hashes"] : @[];
    for (id raw in hashes) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        if ([raw[@"algo"] integerValue] == 1 && [raw[@"value"] isKindOfClass:NSString.class]) {
            f.sha1 = [(NSString *)raw[@"value"] lowercaseString];
            break;
        }
    }

    NSArray *gameVersions = [json[@"gameVersions"] isKindOfClass:NSArray.class] ? json[@"gameVersions"] : @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id raw in gameVersions) {
        if ([raw isKindOfClass:NSString.class]) [out addObject:raw];
    }
    f.gameVersions = out;

    // 作者禁止第三方下载时接口不给 downloadUrl，但 CDN 直链规律固定，按它回退。
    // 这是通行做法，仍沿用清单里给出的 fileID 与文件名。
    if (!f.downloadURL && f.fileID > 0 && f.fileName.length > 0) {
        f.downloadURL = [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%lld/%lld/%@",
                         f.fileID / 1000, f.fileID % 1000, f.fileName];
    }
    return f;
}

@end

#pragma mark - API

@implementation A2CurseForgeAPI

+ (instancetype)shared {
    static A2CurseForgeAPI *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2CurseForgeAPI alloc] init];
    });
    return shared;
}

#pragma mark API Key

+ (BOOL)hasAPIKey {
    return [self apiKey].length > 0;
}

+ (NSString *)apiKey {
    return [NSUserDefaults.standardUserDefaults stringForKey:kAPIKeyDefaultsKey];
}

+ (void)setAPIKey:(NSString *)apiKey {
    NSString *trimmed = [apiKey stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length > 0) {
        [NSUserDefaults.standardUserDefaults setObject:trimmed forKey:kAPIKeyDefaultsKey];
    } else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kAPIKeyDefaultsKey];
    }
}

#pragma mark 分类映射

+ (NSString *)directoryForClassID:(NSInteger)classID {
    // 整合包里的文件只可能是这几种客户端内容，其余一律按模组处理。
    // 与主流启动器一致：世界、自定内容等条目极少出现，且不该被下载。
    switch (classID) {
        case 12:   return @"resourcepacks";
        case 17:   return @"saves";
        case 6552: return @"shaderpacks";
        case 6:
        case 4471:
        default:   return @"mods";
    }
}

#pragma mark 请求

- (NSMutableURLRequest *)requestWithPath:(NSString *)path
                                  method:(NSString *)method
                                  params:(nullable NSDictionary<NSString *, NSString *> *)params
                                jsonBody:(nullable NSDictionary *)jsonBody {
    NSURLComponents *comp = [NSURLComponents componentsWithString:
                             [kBaseURL stringByAppendingString:path]];
    if (params.count > 0) {
        NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
        for (NSString *key in params) {
            [items addObject:[NSURLQueryItem queryItemWithName:key value:params[key]]];
        }
        comp.queryItems = items;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:comp.URL];
    req.HTTPMethod = method;
    req.timeoutInterval = 20;
    NSString *key = [A2CurseForgeAPI apiKey];
    if (key.length > 0) [req setValue:key forHTTPHeaderField:@"x-api-key"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (jsonBody) {
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:jsonBody options:0 error:nil];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    return req;
}

- (void)executeRequest:(NSURLRequest *)request
            completion:(void (^)(id _Nullable json, NSError * _Nullable error))completion {
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) {
            dispatch_main_async(^{ if (completion) completion(nil, error); });
            return;
        }
        NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class]
                         ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        id json = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (code < 200 || code >= 300) {
            NSString *msg = [NSString stringWithFormat:@"CurseForge 请求失败（HTTP %ld）", (long)code];
            dispatch_main_async(^{
                if (completion) completion(nil, A2CurseForgeMakeError(A2CurseForgeErrorHTTPFailure, msg));
            });
            return;
        }
        if (![json isKindOfClass:NSDictionary.class]) {
            dispatch_main_async(^{
                if (completion) {
                    completion(nil, A2CurseForgeMakeError(A2CurseForgeErrorInvalidResponse, @"返回数据格式异常"));
                }
            });
            return;
        }
        dispatch_main_async(^{ if (completion) completion(json, nil); });
    }];
    [task resume];
}

/// 未配置 Key 时的错误
- (NSError *)missingKeyError {
    return A2CurseForgeMakeError(A2CurseForgeErrorMissingAPIKey, @"请先配置 CurseForge API Key");
}

#pragma mark 批量（分块递归）

- (void)fetchFileDetailsChunk:(NSArray<NSNumber *> *)fileIDs
                         index:(NSUInteger)index
                     collected:(NSMutableArray<A2CurseForgeFile *> *)collected
                    completion:(void (^)(NSArray<A2CurseForgeFile *> * _Nullable files,
                                         NSError * _Nullable error))completion {
    if (index >= fileIDs.count) {
        if (completion) completion(collected, nil);
        return;
    }
    NSUInteger end = MIN(index + kBatchChunkSize, fileIDs.count);
    NSArray<NSNumber *> *chunk = [fileIDs subarrayWithRange:NSMakeRange(index, end - index)];
    NSDictionary *body = @{@"fileIds": chunk};

    [self executeRequest:[self requestWithPath:@"/mods/files" method:@"POST" params:nil jsonBody:body]
             completion:^(id json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSArray *data = [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[];
        for (id raw in data) {
            A2CurseForgeFile *file = [A2CurseForgeFile fromJSON:raw];
            if (file) [collected addObject:file];
        }
        [self fetchFileDetailsChunk:fileIDs index:end collected:collected completion:completion];
    }];
}

- (void)fetchClassIDsChunk:(NSArray<NSNumber *> *)projectIDs
                     index:(NSUInteger)index
                 collected:(NSMutableDictionary<NSNumber *, NSNumber *> *)collected
                completion:(void (^)(NSDictionary<NSNumber *, NSNumber *> * _Nullable classIDs,
                                     NSError * _Nullable error))completion {
    if (index >= projectIDs.count) {
        if (completion) completion(collected, nil);
        return;
    }
    NSUInteger end = MIN(index + kBatchChunkSize, projectIDs.count);
    NSArray<NSNumber *> *chunk = [projectIDs subarrayWithRange:NSMakeRange(index, end - index)];
    NSDictionary *body = @{@"modIds": chunk};

    [self executeRequest:[self requestWithPath:@"/mods" method:@"POST" params:nil jsonBody:body]
             completion:^(id json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSArray *data = [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[];
        for (id raw in data) {
            if (![raw isKindOfClass:NSDictionary.class]) continue;
            NSNumber *modID = [raw[@"id"] isKindOfClass:NSNumber.class] ? raw[@"id"] : nil;
            if (!modID) continue;
            collected[modID] = @([raw[@"classId"] integerValue]);
        }
        [self fetchClassIDsChunk:projectIDs index:end collected:collected completion:completion];
    }];
}

#pragma mark 查询

- (void)searchModpacksWithQuery:(NSString *)query
                    gameVersion:(NSString *)gameVersion
                         offset:(NSInteger)offset
                          limit:(NSInteger)limit
                     completion:(void (^)(NSArray<A2CurseForgeProject *> * _Nullable projects,
                                          NSError * _Nullable error))completion {
    if (![A2CurseForgeAPI hasAPIKey]) {
        if (completion) completion(nil, [self missingKeyError]);
        return;
    }

    NSMutableDictionary<NSString *, NSString *> *params = [NSMutableDictionary dictionary];
    params[@"gameId"] = [NSString stringWithFormat:@"%lld", kMinecraftGameID];
    params[@"classId"] = [NSString stringWithFormat:@"%ld", (long)kModpackClassID];
    params[@"sortField"] = @"2";
    params[@"sortOrder"] = @"desc";
    params[@"index"] = [NSString stringWithFormat:@"%ld", (long)MAX(0, offset)];
    params[@"pageSize"] = [NSString stringWithFormat:@"%ld",
                           (long)MIN(kMaxPageSize, MAX(1, limit))];
    if (query.length > 0) params[@"searchFilter"] = query;
    if (gameVersion.length > 0) params[@"gameVersion"] = gameVersion;

    [self executeRequest:[self requestWithPath:@"/mods/search" method:@"GET" params:params jsonBody:nil]
             completion:^(id json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSArray *data = [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[];
        NSMutableArray<A2CurseForgeProject *> *out = [NSMutableArray array];
        for (id raw in data) {
            A2CurseForgeProject *p = [A2CurseForgeProject fromJSON:raw];
            if (p) [out addObject:p];
        }
        if (completion) completion(out, nil);
    }];
}

- (void)filesForProject:(long long)projectID
                 offset:(NSInteger)offset
                  limit:(NSInteger)limit
             completion:(void (^)(NSArray<A2CurseForgeFile *> * _Nullable files,
                                  NSError * _Nullable error))completion {
    if (![A2CurseForgeAPI hasAPIKey]) {
        if (completion) completion(nil, [self missingKeyError]);
        return;
    }

    NSMutableDictionary<NSString *, NSString *> *params = [NSMutableDictionary dictionary];
    params[@"index"] = [NSString stringWithFormat:@"%ld", (long)MAX(0, offset)];
    params[@"pageSize"] = [NSString stringWithFormat:@"%ld",
                           (long)MIN(kMaxPageSize, MAX(1, limit))];

    NSString *path = [NSString stringWithFormat:@"/mods/%lld/files", projectID];
    [self executeRequest:[self requestWithPath:path method:@"GET" params:params jsonBody:nil]
             completion:^(id json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSArray *data = [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[];
        NSMutableArray<A2CurseForgeFile *> *out = [NSMutableArray array];
        for (id raw in data) {
            A2CurseForgeFile *f = [A2CurseForgeFile fromJSON:raw];
            if (f) [out addObject:f];
        }
        if (completion) completion(out, nil);
    }];
}

- (void)versionDetailForProject:(long long)projectID
                         fileID:(long long)fileID
                     completion:(void (^)(A2CurseForgeFile * _Nullable file,
                                          NSError * _Nullable error))completion {
    if (![A2CurseForgeAPI hasAPIKey]) {
        if (completion) completion(nil, [self missingKeyError]);
        return;
    }

    NSString *path = [NSString stringWithFormat:@"/mods/%lld/files/%lld", projectID, fileID];
    [self executeRequest:[self requestWithPath:path method:@"GET" params:nil jsonBody:nil]
             completion:^(id json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        A2CurseForgeFile *file = [A2CurseForgeFile fromJSON:json[@"data"]];
        if (!file) {
            if (completion) {
                completion(nil, A2CurseForgeMakeError(A2CurseForgeErrorInvalidResponse, @"文件不存在"));
            }
            return;
        }
        // 再取一次项目，拿到 classID 才知道该落到哪个目录
        NSString *projectPath = [NSString stringWithFormat:@"/mods/%lld", projectID];
        [self executeRequest:[self requestWithPath:projectPath method:@"GET" params:nil jsonBody:nil]
                 completion:^(id projectJson, NSError *projectError) {
            if (!projectError) {
                NSDictionary *data = [projectJson[@"data"] isKindOfClass:NSDictionary.class]
                                     ? projectJson[@"data"] : nil;
                file.classID = [data[@"classId"] integerValue];
            }
            if (completion) completion(file, nil);
        }];
    }];
}

- (void)fileDetailsForFileIDs:(NSArray<NSNumber *> *)fileIDs
                   completion:(void (^)(NSArray<A2CurseForgeFile *> * _Nullable files,
                                        NSError * _Nullable error))completion {
    if (fileIDs.count == 0) {
        if (completion) completion(@[], nil);
        return;
    }
    if (![A2CurseForgeAPI hasAPIKey]) {
        if (completion) completion(nil, [self missingKeyError]);
        return;
    }
    [self fetchFileDetailsChunk:fileIDs index:0 collected:[NSMutableArray array] completion:completion];
}

- (void)classIDsForProjectIDs:(NSArray<NSNumber *> *)projectIDs
                   completion:(void (^)(NSDictionary<NSNumber *, NSNumber *> * _Nullable classIDs,
                                        NSError * _Nullable error))completion {
    if (projectIDs.count == 0) {
        if (completion) completion(@{}, nil);
        return;
    }
    if (![A2CurseForgeAPI hasAPIKey]) {
        if (completion) completion(nil, [self missingKeyError]);
        return;
    }
    [self fetchClassIDsChunk:projectIDs index:0 collected:[NSMutableDictionary dictionary]
                  completion:completion];
}

@end
