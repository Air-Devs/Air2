//
//  A2MCBBSPackParser.m
//  Air2
//

#import "A2MCBBSPackParser.h"
#import "A2ModpackModels.h"
#import "A2ModpackParser.h"

/// mcbbs.packmeta 的 files 条目未必带 path，
/// 此时按 type 猜目录、用 URL 最后一段当文件名。
static NSString *A2MCBBSPathForEntry(NSDictionary *entry) {
    NSString *type = [A2ModpackString(entry[@"type"]) ?: @"" lowercaseString];
    NSString *dir = @"mods";
    if ([type containsString:@"shader"]) {
        dir = @"shaderpacks";
    } else if ([type containsString:@"resourcepack"] || [type containsString:@"texture"]) {
        dir = @"resourcepacks";
    } else if ([type containsString:@"save"] || [type containsString:@"world"]) {
        dir = @"saves";
    } else if ([type containsString:@"minecraft"]) {
        dir = @"";
    }

    NSString *name = A2ModpackString(entry[@"url"]).lastPathComponent;
    if (name.length == 0) return nil;
    return dir.length ? [dir stringByAppendingPathComponent:name] : name;
}

@implementation A2MCBBSPackParser

+ (A2ModpackInfo *)parseAtRoot:(NSString *)root error:(NSError **)error {
    NSDictionary *dict = A2ModpackReadJSONObject([root stringByAppendingPathComponent:@"mcbbs.packmeta"]);
    if (![dict isKindOfClass:NSDictionary.class]) {
        // 旧包没有 packmeta，退回 manifest.json
        dict = A2ModpackReadJSONObject([root stringByAppendingPathComponent:@"manifest.json"]);
    }
    if (![dict isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = A2ModpackError(A2ModpackParserErrorInvalidFormat,
                                    @"找不到 mcbbs.packmeta 或 manifest.json");
        }
        return nil;
    }

    A2ModpackInfo *info = [A2ModpackInfo new];
    info.format = A2ModpackFormatMCBBS;
    info.name = A2ModpackString(dict[@"name"]) ?: @"未命名整合包";
    info.summary = A2ModpackString(dict[@"description"]) ?: A2ModpackString(dict[@"summary"]);

    NSDictionary *addons = [dict[@"addons"] isKindOfClass:NSDictionary.class] ? dict[@"addons"] : nil;
    NSDictionary *game = [addons[@"game"] isKindOfClass:NSDictionary.class] ? addons[@"game"] : nil;
    info.gameVersion = A2ModpackString(game[@"version"]) ?: A2ModpackString(dict[@"mcversion"]);

    // addons 里除 game 外的第一个可识别项就是加载器
    for (NSString *key in addons) {
        if ([key isEqualToString:@"game"]) continue;
        NSNumber *type = A2ModpackLoaderTypeForIdentifier(key);
        if (!type) continue;
        NSDictionary *entry = [addons[key] isKindOfClass:NSDictionary.class] ? addons[key] : nil;
        info.loaderType = type;
        info.loaderVersion = A2ModpackString(entry[@"version"]) ?: A2ModpackString(entry[@"name"]);
        break;
    }

    NSMutableArray<A2ModpackFile *> *files = [NSMutableArray array];
    NSArray *rawFiles = [dict[@"files"] isKindOfClass:NSArray.class] ? dict[@"files"] : @[];
    for (id raw in rawFiles) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *f = raw;

        NSString *path = A2ModpackString(f[@"path"]);
        if (path.length == 0) path = A2MCBBSPathForEntry(f);
        if (path.length == 0) continue;

        NSMutableArray<NSString *> *urls = [NSMutableArray array];
        NSArray *rawURLs = [f[@"urls"] isKindOfClass:NSArray.class] ? f[@"urls"] : @[];
        for (id u in rawURLs) {
            NSString *s = A2ModpackString(u);
            if (s.length) [urls addObject:s];
        }
        NSString *single = A2ModpackString(f[@"url"]);
        if (single.length) [urls addObject:single];

        A2ModpackFile *file = [A2ModpackFile new];
        file.relativePath = A2ModpackNormalizedPath(path);
        file.downloadURLs = urls;
        file.sha1 = A2ModpackString(f[@"hash"]) ?: A2ModpackString(f[@"sha1"]);
        file.size = [f[@"size"] longLongValue];
        [files addObject:file];
    }
    info.files = files;
    info.overrideDirectories = A2ModpackExistingDirectories(root, @[@"overrides"]);
    return info;
}

@end
