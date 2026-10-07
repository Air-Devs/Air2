//
//  A2CurseForgePackParser.m
//  Air2
//

#import "A2CurseForgePackParser.h"
#import "A2ModpackModels.h"
#import "A2ModpackParser.h"

@implementation A2CurseForgePackParser

+ (A2ModpackInfo *)parseAtRoot:(NSString *)root error:(NSError **)error {
    NSDictionary *dict = A2ModpackReadJSONObject([root stringByAppendingPathComponent:@"manifest.json"]);
    if (![dict isKindOfClass:NSDictionary.class]) return nil;

    // CurseForge 的 manifest 必带 minecraft 段。
    // 没有就说明是别的格式借用了 manifest.json 这个文件名，
    // 这里安静返回 nil，让调度器继续往后试，而不是报错中断。
    NSDictionary *mc = [dict[@"minecraft"] isKindOfClass:NSDictionary.class] ? dict[@"minecraft"] : nil;
    if (!mc) return nil;

    A2ModpackInfo *info = [A2ModpackInfo new];
    info.format = A2ModpackFormatCurseForge;
    info.name = A2ModpackString(dict[@"name"]) ?: @"未命名整合包";
    info.recommendedRAM = [dict[@"recommendedRam"] integerValue];
    info.gameVersion = A2ModpackString(mc[@"version"]);

    // modLoaders 里 primary 那条才是要装的加载器
    NSArray *loaders = [mc[@"modLoaders"] isKindOfClass:NSArray.class] ? mc[@"modLoaders"] : @[];
    NSDictionary *chosen = nil;
    for (id raw in loaders) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        if (!chosen) chosen = raw;
        if ([raw[@"primary"] boolValue]) {
            chosen = raw;
            break;
        }
    }
    NSString *loaderID = A2ModpackString(chosen[@"id"]);
    info.loaderType = A2ModpackLoaderTypeForIdentifier(loaderID);
    info.loaderVersion = A2ModpackVersionFromCurseForgeLoaderID(loaderID);

    NSMutableArray<A2ModpackFile *> *files = [NSMutableArray array];
    NSArray *rawFiles = [dict[@"files"] isKindOfClass:NSArray.class] ? dict[@"files"] : @[];
    for (id raw in rawFiles) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *f = raw;
        NSNumber *projectID = [f[@"projectID"] isKindOfClass:NSNumber.class] ? f[@"projectID"] : nil;
        NSNumber *fileID = [f[@"fileID"] isKindOfClass:NSNumber.class] ? f[@"fileID"] : nil;
        if (!projectID || !fileID) continue;

        A2ModpackFile *file = [A2ModpackFile new];
        // 清单里既没有直链也没有目标目录：落盘位置要按项目分类决定，
        // 这两件都得联网查 API，交给安装器补齐。
        file.requiresCurseForgeLookup = YES;
        file.curseForgeProjectID = projectID.longLongValue;
        file.curseForgeFileID = fileID.longLongValue;
        [files addObject:file];
    }
    info.files = files;

    NSString *overrideName = A2ModpackString(dict[@"overrides"]) ?: @"overrides";
    info.overrideDirectories = A2ModpackExistingDirectories(root, @[overrideName]);
    return info;
}

@end
