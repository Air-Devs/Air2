//
//  A2MultiMCPackParser.m
//  Air2
//

#import "A2MultiMCPackParser.h"
#import "A2ModpackModels.h"
#import "A2ModpackParser.h"

/// 从 instance.cfg 里读一个键。该文件是简单的 key=value 文本。
static NSString *A2MMCInstanceValue(NSString *root, NSString *key) {
    NSString *path = [root stringByAppendingPathComponent:@"instance.cfg"];
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (text.length == 0) return nil;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:
                            NSCharacterSet.newlineCharacterSet]) {
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        if ([[line substringToIndex:eq.location] isEqualToString:key]) {
            return [line substringFromIndex:eq.location + 1];
        }
    }
    return nil;
}

@implementation A2MultiMCPackParser

+ (A2ModpackInfo *)parseAtRoot:(NSString *)root error:(NSError **)error {
    NSDictionary *dict = A2ModpackReadJSONObject([root stringByAppendingPathComponent:@"mmc-pack.json"]);
    if (![dict isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = A2ModpackError(A2ModpackParserErrorInvalidFormat,
                                    @"mmc-pack.json 缺失或不是合法 JSON");
        }
        return nil;
    }

    A2ModpackInfo *info = [A2ModpackInfo new];
    info.format = A2ModpackFormatMultiMC;
    info.name = A2MMCInstanceValue(root, @"name") ?: root.lastPathComponent;

    NSString *memory = A2MMCInstanceValue(root, @"MaxMemAlloc");
    if (memory.length) info.recommendedRAM = (NSInteger)[memory integerValue];

    NSArray *components = [dict[@"components"] isKindOfClass:NSArray.class] ? dict[@"components"] : @[];
    for (id raw in components) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *c = raw;
        NSString *uid = A2ModpackString(c[@"uid"]);
        NSString *version = A2ModpackString(c[@"version"]);

        if ([uid isEqualToString:@"net.minecraft"]) {
            info.gameVersion = version;
            continue;
        }
        NSNumber *type = A2ModpackLoaderTypeForIdentifier(uid);
        if (type && info.loaderType == nil) {
            info.loaderType = type;
            info.loaderVersion = version;
        }
    }

    // MultiMC 把模组与配置直接放在实例目录里，没有需要逐个下载的清单
    info.files = @[];
    info.overrideDirectories = A2ModpackExistingDirectories(root, @[@".minecraft", @"minecraft", @"overrides"]);
    return info;
}

@end
