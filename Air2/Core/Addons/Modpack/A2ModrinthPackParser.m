//
//  A2ModrinthPackParser.m
//  Air2
//

#import "A2ModrinthPackParser.h"
#import "A2ModpackModels.h"
#import "A2ModpackParser.h"

@implementation A2ModrinthPackParser

+ (A2ModpackInfo *)parseAtRoot:(NSString *)root error:(NSError **)error {
    NSString *indexPath = [root stringByAppendingPathComponent:@"modrinth.index.json"];
    NSDictionary *dict = A2ModpackReadJSONObject(indexPath);
    if (![dict isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = A2ModpackError(A2ModpackParserErrorInvalidFormat,
                                    @"modrinth.index.json 缺失或不是合法 JSON");
        }
        return nil;
    }

    A2ModpackInfo *info = [A2ModpackInfo new];
    info.format = A2ModpackFormatModrinth;
    info.name = A2ModpackString(dict[@"name"]) ?: @"未命名整合包";
    info.summary = A2ModpackString(dict[@"summary"]);

    NSDictionary *dependencies = [dict[@"dependencies"] isKindOfClass:NSDictionary.class]
        ? dict[@"dependencies"] : @{};
    info.gameVersion = A2ModpackString(dependencies[@"minecraft"]);
    // 越具体的键越先判，避免 forge 抢走 neoforge
    for (NSString *key in @[@"neoforge", @"forge", @"quilt-loader",
                            @"fabric-loader", @"legacy-fabric-loader"]) {
        NSString *version = A2ModpackString(dependencies[key]);
        if (version.length == 0) continue;
        info.loaderType = A2ModpackLoaderTypeForIdentifier(key);
        info.loaderVersion = version;
        break;
    }

    NSMutableArray<A2ModpackFile *> *files = [NSMutableArray array];
    NSArray *rawFiles = [dict[@"files"] isKindOfClass:NSArray.class] ? dict[@"files"] : @[];
    for (id raw in rawFiles) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *f = raw;

        NSString *path = A2ModpackString(f[@"path"]);
        if (path.length == 0) continue;

        // 标记为 server unsupported 的文件客户端用不到，下载纯属浪费流量
        NSDictionary *env = [f[@"env"] isKindOfClass:NSDictionary.class] ? f[@"env"] : nil;
        if ([A2ModpackString(env[@"client"]) isEqualToString:@"unsupported"]) continue;

        A2ModpackFile *file = [A2ModpackFile new];
        file.relativePath = A2ModpackNormalizedPath(path);

        NSMutableArray<NSString *> *urls = [NSMutableArray array];
        NSArray *rawURLs = [f[@"downloads"] isKindOfClass:NSArray.class] ? f[@"downloads"] : @[];
        for (id u in rawURLs) {
            NSString *s = A2ModpackString(u);
            if (s.length) [urls addObject:s];
        }
        file.downloadURLs = urls;

        NSDictionary *hashes = [f[@"hashes"] isKindOfClass:NSDictionary.class] ? f[@"hashes"] : nil;
        file.sha1 = A2ModpackString(hashes[@"sha1"]);
        file.size = [f[@"fileSize"] longLongValue];
        [files addObject:file];
    }
    info.files = files;
    info.overrideDirectories = A2ModpackExistingDirectories(root, @[@"overrides", @"client-overrides"]);
    return info;
}

@end
