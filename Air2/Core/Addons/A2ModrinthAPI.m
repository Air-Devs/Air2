//
//  A2ModrinthAPI.m
//  Air2
//

#import "A2ModrinthAPI.h"
#import <Foundation/Foundation.h>

/// 回调统一回到主线程 —— 调用方（UI 层）不该关心线程问题
static void dispatch_main_async(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

static NSString *const kBaseURL = @"https://api.modrinth.com/v2";
/// Modrinth 要求带 User-Agent，格式：应用名/版本 (联系方式)
static NSString *const kUserAgent = @"Air-Devs/Air2/0.1.0 (github.com/Air-Devs/Air2)";

#pragma mark - 项目

@implementation A2ModrinthProject

+ (instancetype)fromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    A2ModrinthProject *p = [A2ModrinthProject new];
    p.projectID = json[@"project_id"] ?: json[@"id"] ?: @"";
    p.slug = json[@"slug"] ?: @"";
    p.title = json[@"title"] ?: @"";
    p.projectDescription = json[@"description"] ?: @"";
    p.iconURL = [json[@"icon_url"] isKindOfClass:NSString.class] ? json[@"icon_url"] : nil;
    p.downloads = [json[@"downloads"] longLongValue];
    p.followers = [json[@"followers"] longLongValue];

    NSArray *cats = json[@"categories"] ?: json[@"display_categories"];
    if ([cats isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id c in cats) {
            if ([c isKindOfClass:NSString.class]) [out addObject:c];
        }
        p.categories = out;
    } else {
        p.categories = @[];
    }
    p.author = [json[@"author"] isKindOfClass:NSString.class] ? json[@"author"] : nil;
    return p;
}

@end

#pragma mark - 版本

@implementation A2ModrinthVersion

+ (instancetype)fromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    A2ModrinthVersion *v = [A2ModrinthVersion new];
    v.versionID = json[@"id"] ?: @"";
    v.name = json[@"name"] ?: @"";
    v.versionNumber = json[@"version_number"] ?: @"";
    v.gameVersions = [json[@"game_versions"] isKindOfClass:NSArray.class] ? json[@"game_versions"] : @[];
    v.loaders = [json[@"loaders"] isKindOfClass:NSArray.class] ? json[@"loaders"] : @[];
    v.downloads = [json[@"downloads"] integerValue];
    v.datePublished = [json[@"date_published"] isKindOfClass:NSString.class] ? json[@"date_published"] : nil;
    v.changelog = [json[@"changelog"] isKindOfClass:NSString.class] ? json[@"changelog"] : nil;

    // 取第一个文件作为主文件
    NSArray *files = json[@"files"];
    if ([files isKindOfClass:NSArray.class] && files.count > 0) {
        NSDictionary *f = files.firstObject;
        v.downloadURL = f[@"url"];
        v.fileName = f[@"filename"];
        NSDictionary *hashes = [f[@"hashes"] isKindOfClass:NSDictionary.class] ? f[@"hashes"] : nil;
        // Modrinth 同时给 sha1/sha512，下载校验用 sha1
        NSString *sha1 = [hashes[@"sha1"] isKindOfClass:NSString.class] ? hashes[@"sha1"] : nil;
        v.sha1 = sha1.lowercaseString;
        v.fileSize = [f[@"size"] longLongValue];
    }
    return v;
}

@end

#pragma mark - API

@implementation A2ModrinthAPI

+ (instancetype)shared {
    static A2ModrinthAPI *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2ModrinthAPI alloc] init];
    });
    return shared;
}

- (NSMutableURLRequest *)requestWithPath:(NSString *)path
                                  params:(nullable NSDictionary<NSString *, NSString *> *)params {
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
    req.timeoutInterval = 20;
    [req setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return req;
}

- (NSString *)facetsForType:(A2ModrinthProjectType)type
                gameVersion:(NSString *)gameVersion
                     loader:(NSString *)loader {
    NSMutableArray *groups = [NSMutableArray array];

    // 项目类型
    NSString *typeName = nil;
    switch (type) {
        case A2ModrinthProjectTypeMod:          typeName = @"mod"; break;
        case A2ModrinthProjectTypeModpack:      typeName = @"modpack"; break;
        case A2ModrinthProjectTypeResourcePack: typeName = @"resourcepack"; break;
        case A2ModrinthProjectTypeShader:       typeName = @"shader"; break;
        case A2ModrinthProjectTypeDatapack:     typeName = @"datapack"; break;
    }
    if (typeName) {
        [groups addObject:[NSString stringWithFormat:@"[[\"project_type:%@\"]]", typeName]];
    }
    if (gameVersion.length) {
        [groups addObject:[NSString stringWithFormat:@"[[\"versions:%@\"]]", gameVersion]];
    }
    if (loader.length) {
        [groups addObject:[NSString stringWithFormat:@"[[\"categories:%@\"]]", loader]];
    }
    return [groups componentsJoinedByString:@","];
}

- (void)searchWithQuery:(NSString *)query
                   type:(A2ModrinthProjectType)type
            gameVersion:(NSString *)gameVersion
                 loader:(NSString *)loader
                 offset:(NSInteger)offset
                  limit:(NSInteger)limit
             completion:(void (^)(NSArray<A2ModrinthProject *> *, NSError *))completion {

    NSMutableDictionary<NSString *, NSString *> *params = [NSMutableDictionary dictionary];
    if (query.length) params[@"query"] = query;
    params[@"limit"] = [NSString stringWithFormat:@"%ld", (long)limit];
    params[@"offset"] = [NSString stringWithFormat:@"%ld", (long)offset];
    params[@"index"] = @"relevance";

    NSString *facets = [self facetsForType:type gameVersion:gameVersion loader:loader];
    if (facets.length) params[@"facets"] = facets;

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:
        [self requestWithPath:@"/search" params:params]
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { dispatch_main_async(^{ if (completion) completion(nil, error); }); return; }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class]) {
            dispatch_main_async(^{
                if (completion) completion(nil, [self errorWithMessage:@"返回数据格式异常"]);
            });
            return;
        }

        NSArray *hits = json[@"hits"];
        NSMutableArray<A2ModrinthProject *> *out = [NSMutableArray array];
        if ([hits isKindOfClass:NSArray.class]) {
            for (NSDictionary *h in hits) {
                A2ModrinthProject *p = [A2ModrinthProject fromJSON:h];
                if (p) [out addObject:p];
            }
        }
        dispatch_main_async(^{ if (completion) completion(out, nil); });
    }];
    [task resume];
}

- (void)versionsForProject:(NSString *)projectID
               gameVersion:(NSString *)gameVersion
                    loader:(NSString *)loader
                completion:(void (^)(NSArray<A2ModrinthVersion *> *, NSError *))completion {

    if (!projectID.length) {
        if (completion) completion(nil, [self errorWithMessage:@"项目 ID 为空"]);
        return;
    }

    NSMutableDictionary<NSString *, NSString *> *params = [NSMutableDictionary dictionary];
    if (gameVersion.length) {
        params[@"game_versions"] = [NSString stringWithFormat:@"[\"%@\"]", gameVersion];
    }
    if (loader.length) {
        params[@"loaders"] = [NSString stringWithFormat:@"[\"%@\"]", loader];
    }

    NSString *path = [NSString stringWithFormat:@"/project/%@/version", projectID];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:
        [self requestWithPath:path params:params]
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { dispatch_main_async(^{ if (completion) completion(nil, error); }); return; }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSMutableArray<A2ModrinthVersion *> *out = [NSMutableArray array];
        if ([json isKindOfClass:NSArray.class]) {
            for (NSDictionary *j in json) {
                A2ModrinthVersion *v = [A2ModrinthVersion fromJSON:j];
                if (v) [out addObject:v];
            }
        }
        dispatch_main_async(^{ if (completion) completion(out, nil); });
    }];
    [task resume];
}

- (void)projectWithID:(NSString *)projectID
           completion:(void (^)(A2ModrinthProject *, NSError *))completion {
    if (!projectID.length) {
        if (completion) completion(nil, [self errorWithMessage:@"项目 ID 为空"]);
        return;
    }
    NSString *path = [NSString stringWithFormat:@"/project/%@", projectID];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:
        [self requestWithPath:path params:nil]
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { dispatch_main_async(^{ if (completion) completion(nil, error); }); return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        A2ModrinthProject *p = [A2ModrinthProject fromJSON:json];
        dispatch_main_async(^{
            if (completion) completion(p, p ? nil : [self errorWithMessage:@"项目不存在"]);
        });
    }];
    [task resume];
}

- (NSError *)errorWithMessage:(NSString *)msg {
    return [NSError errorWithDomain:@"A2Modrinth" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

@end
