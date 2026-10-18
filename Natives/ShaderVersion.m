//
//  ShaderVersion.m
//  Amethyst
//
//  Shader version model implementation
//

#import "ShaderVersion.h"

@interface ShaderVersion ()
- (instancetype)parseCurseForgeDictionary:(NSDictionary *)dictionary;
@end

@implementation ShaderVersion

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    self = [super init];
    if (self) {
        if (![dictionary isKindOfClass:[NSDictionary class]]) {
            return nil;
        }

        // CurseForge file 格式适配（识别 gameVersions/downloadUrl/fileLength/fileDate/id/modId 字段）
        if (dictionary[@"gameVersions"] != nil && dictionary[@"downloadUrl"] != nil) {
            return [self parseCurseForgeDictionary:dictionary];
        }

        _name = [dictionary[@"name"] isKindOfClass:[NSString class]] ? dictionary[@"name"] : @"Unknown Name";
        _versionNumber = [dictionary[@"version_number"] isKindOfClass:[NSString class]] ? dictionary[@"version_number"] : @"Unknown Version";
        _datePublished = [dictionary[@"date_published"] isKindOfClass:[NSString class]] ? dictionary[@"date_published"] : @"";
        _gameVersions = [dictionary[@"game_versions"] isKindOfClass:[NSArray class]] ? dictionary[@"game_versions"] : @[];
        _loaders = [dictionary[@"loaders"] isKindOfClass:[NSArray class]] ? dictionary[@"loaders"] : @[];
        // 发布类型（Modrinth: release/beta/alpha）
        _versionType = [dictionary[@"version_type"] isKindOfClass:[NSString class]] ? dictionary[@"version_type"] : @"release";

        NSArray *files = [dictionary[@"files"] isKindOfClass:[NSArray class]] ? dictionary[@"files"] : @[];
        _primaryFile = [files firstObject];
    }
    return self;
}

- (instancetype)parseCurseForgeDictionary:(NSDictionary *)dictionary {
    _apiSource = 2; // CurseForge
    // 文件名
    NSString *fileName = dictionary[@"fileName"];
    // 发布类型（CurseForge: 1=release, 2=beta, 3=alpha）
    NSInteger releaseType = [dictionary[@"releaseType"] integerValue];
    if (releaseType == 2) {
        _versionType = @"beta";
    } else if (releaseType == 3) {
        _versionType = @"alpha";
    } else {
        _versionType = @"release";
    }
    // 文件大小
    if (dictionary[@"fileLength"]) {
        _fileSize = dictionary[@"fileLength"];
    }
    // 发布时间（fileDate 格式：ISO8601，存储为字符串以与 Modrinth 路径保持一致）
    NSString *dateStr = dictionary[@"fileDate"];
    if (dateStr) {
        _datePublished = dateStr;
    }
    // file ID 和 project ID
    _fileId = [dictionary[@"id"] stringValue];
    _projectId = [dictionary[@"modId"] stringValue];
    // gameVersions 数组（包含游戏版本和加载器）
    NSArray *gameVersions = dictionary[@"gameVersions"];
    NSString *gameVer = nil;
    NSMutableArray *loaders = [NSMutableArray array];
    NSMutableArray *gameVerArr = [NSMutableArray array];
    for (NSString *v in gameVersions) {
        if ([v hasPrefix:@"Fabric"] || [v hasPrefix:@"Forge"] || [v hasPrefix:@"NeoForge"] || [v hasPrefix:@"Quilt"]) {
            [loaders addObject:v];
        } else if ([v containsString:@"."]) {
            if (gameVer == nil) {
                gameVer = v;
            }
            [gameVerArr addObject:v];
        }
    }
    _gameVersions = [gameVerArr copy];
    _loaders = [loaders copy];
    _name = [NSString stringWithFormat:@"%@ (%@)", fileName ?: @"", gameVer ?: @""];
    _versionNumber = _fileId;
    // hashes（algo 1 = SHA1）
    NSString *sha1 = nil;
    NSArray *hashes = dictionary[@"hashes"];
    for (NSDictionary *h in hashes) {
        if ([h[@"algo"] integerValue] == 1) {
            sha1 = h[@"value"];
        }
    }
    // 构造 primaryFile 以兼容 Modrinth 格式读取（url/filename/hashes）
    NSMutableDictionary *pf = [NSMutableDictionary dictionary];
    if (dictionary[@"downloadUrl"]) {
        pf[@"url"] = dictionary[@"downloadUrl"];
    }
    if (fileName) {
        pf[@"filename"] = fileName;
    }
    pf[@"primary"] = @(YES);
    if (sha1) {
        pf[@"hashes"] = @{ @"sha1": sha1 };
    }
    _primaryFile = [pf copy];
    return self;
}

@end
