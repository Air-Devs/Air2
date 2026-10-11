//
//  A2APIModDownloader.m
//  Air2
//

#import "A2VersionManager.h"
#import "A2Version.h"
#import "A2APIModDownloader.h"
#import "A2ModrinthAPI.h"
#import "A2DownloadEngine.h"
#import "A2MirrorResolver.h"
#import "A2VersionIsolation.h"
#import "A2Logger.h"

static void A2Main(dispatch_block_t b) {
    if ([NSThread isMainThread]) b();
    else dispatch_async(dispatch_get_main_queue(), b);
}

@implementation A2APIModDownloader

+ (instancetype)shared {
    static A2APIModDownloader *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2APIModDownloader alloc] init];
    });
    return shared;
}

#pragma mark - 映射表

/// 这些 slug 是 Modrinth 上的项目标识，不随版本变化。
+ (NSString *)modrinthSlugForAPIType:(A2ModLoaderType)apiType {
    switch (apiType) {
        case A2ModLoaderTypeFabricAPI:       return @"fabric-api";
        case A2ModLoaderTypeQuiltAPI:        return @"quilted-fabric-api";
        case A2ModLoaderTypeLegacyFabricAPI: return @"legacy-fabric-api";
        // Babric API 不在 Modrinth 上 —— 官方无稳定分发渠道
        default:                             return nil;
    }
}

/// 前置模组对应的加载器标识（Modrinth 的 loaders 字段取值）
+ (NSString *)loaderIdentifierForAPIType:(A2ModLoaderType)apiType {
    switch (apiType) {
        case A2ModLoaderTypeFabricAPI:       return @"fabric";
        case A2ModLoaderTypeQuiltAPI:        return @"quilt";
        case A2ModLoaderTypeLegacyFabricAPI: return @"fabric";   // Legacy Fabric 也用 fabric 标识
        default:                             return nil;
    }
}

#pragma mark - 版本查询

- (void)versionsForAPIType:(A2ModLoaderType)apiType
                mcVersion:(NSString *)mcVersion
               completion:(void (^)(NSArray<A2ModLoaderVersion *> *,
                                    NSError *))completion {

    NSString *slug = [A2APIModDownloader modrinthSlugForAPIType:apiType];
    if (!slug) {
        if (completion) {
            completion(nil, [self err:[NSString stringWithFormat:
                @"%@ 没有已知的下载来源", [A2ModLoaderAPI displayNameForType:apiType]]]);
        }
        return;
    }

    NSString *loader = [A2APIModDownloader loaderIdentifierForAPIType:apiType];

    [[A2ModrinthAPI shared] versionsForProject:slug
                                   gameVersion:mcVersion
                                        loader:loader
                                    completion:^(NSArray<A2ModrinthVersion *> *versions,
                                                 NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }

        NSMutableArray<A2ModLoaderVersion *> *out = [NSMutableArray array];
        for (A2ModrinthVersion *v in versions) {
            [out addObject:[A2ModLoaderVersion version:v.versionNumber
                                                 stable:YES
                                                   type:apiType]];
        }

        [A2Logger info:@"APIModDownloader"
               message:[NSString stringWithFormat:@"%@ 在 MC %@ 下有 %lu 个版本",
                        [A2ModLoaderAPI displayNameForType:apiType], mcVersion,
                        (unsigned long)out.count]];

        if (completion) completion(out, nil);
    }];
}

#pragma mark - 安装

- (void)installAPIType:(A2ModLoaderType)apiType
             mcVersion:(NSString *)mcVersion
           versionName:(NSString *)versionName
              gameHome:(NSString *)gameHome
      preferredVersion:(NSString *)preferredVersion
              progress:(void (^)(double, NSString *))progress
            completion:(void (^)(BOOL, NSError *))completion {

    NSString *slug = [A2APIModDownloader modrinthSlugForAPIType:apiType];
    NSString *apiName = [A2ModLoaderAPI displayNameForType:apiType];

    if (!slug) {
        if (completion) {
            completion(NO, [self err:[NSString stringWithFormat:
                @"%@ 没有已知的下载来源，请手动安装", apiName]]);
        }
        return;
    }

    void (^report)(double, NSString *) = ^(double p, NSString *msg) {
        A2Main(^{ if (progress) progress(p, msg); });
    };

    report(0.05, [NSString stringWithFormat:@"正在查询 %@…", apiName]);

    NSString *loader = [A2APIModDownloader loaderIdentifierForAPIType:apiType];

    [[A2ModrinthAPI shared] versionsForProject:slug
                                   gameVersion:mcVersion
                                        loader:loader
                                    completion:^(NSArray<A2ModrinthVersion *> *versions,
                                                 NSError *error) {
        if (error || versions.count == 0) {
            A2Main(^{
                if (completion) {
                    completion(NO, [self err:[NSString stringWithFormat:
                        @"%@ 在 MC %@ 下没有可用版本", apiName, mcVersion]]);
                }
            });
            return;
        }

        // 选定版本：指定优先，否则取第一个
        A2ModrinthVersion *chosen = versions.firstObject;
        if (preferredVersion.length) {
            for (A2ModrinthVersion *v in versions) {
                if ([v.versionNumber isEqualToString:preferredVersion]) { chosen = v; break; }
            }
        }

        if (chosen.downloadURL.length == 0) {
            A2Main(^{
                if (completion) {
                    completion(NO, [self err:[NSString stringWithFormat:
                        @"%@ 的该版本没有下载地址", apiName]]);
                }
            });
            return;
        }

        NSString *fileName = chosen.fileName.length ? chosen.fileName
            : [NSString stringWithFormat:@"%@.jar", slug];

        // 目标：#版本目录/mods/ —— 前置模组要落在游戏能加载到的地方
        // 目标：#版本目录/mods/ —— 前置模组要落在游戏能加载到的地方
        A2GamePath *path = [A2GamePath pathWithGameHome:gameHome];
        A2IsolationMode mode = A2IsolationModeFull;
        for (A2Version *v in A2VersionManager.shared.versions) {
            if ([v.name isEqualToString:versionName]) {
                mode = [v effectiveIsolationMode];
                break;
            }
        }
        NSString *modsDir = [path modsDirectoryForVersion:versionName mode:mode];
                                withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *dest = [modsDir stringByAppendingPathComponent:fileName];

        // 已存在就不重下
        if ([NSFileManager.defaultManager fileExistsAtPath:dest]) {
            [A2Logger info:@"APIModDownloader"
                   message:[NSString stringWithFormat:@"%@ 已存在，跳过", fileName]];
            report(1.0, [NSString stringWithFormat:@"%@ 已安装", apiName]);
            A2Main(^{ if (completion) completion(YES, nil); });
            return;
        }

        report(0.3, [NSString stringWithFormat:@"正在下载 %@…", fileName]);

        A2DownloadRequest *req = [A2DownloadRequest new];
        // 展开镜像候选
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        for (NSString *u in [[A2MirrorResolver shared] candidateURLsForURL:chosen.downloadURL]) {
            NSURL *url = [NSURL URLWithString:u];
            if (url) [urls addObject:url];
        }
        req.candidateURLs = urls;
        req.destinationPath = dest;
        req.expectedSize = chosen.fileSize;
        req.allowZipFallbackCheck = YES;

        [[A2DownloadEngine sharedClient] startRequest:req
            progress:^(int64_t delta, int64_t total) {
                if (total > 0) {
                    report(0.3 + 0.65 * ((double)delta / (double)total),
                           [NSString stringWithFormat:@"正在下载 %@…", fileName]);
                }
            }
            speed:nil
            completion:^(BOOL success, NSError *downloadError) {
            A2Main(^{
                if (success) {
                    [A2Logger info:@"APIModDownloader"
                           message:[NSString stringWithFormat:@"%@ 已装到 %@", apiName, dest]];
                    report(1.0, [NSString stringWithFormat:@"%@ 安装完成", apiName]);
                    if (completion) completion(YES, nil);
                } else {
                    if (completion) completion(NO, downloadError);
                }
            });
        }];
    }];
}

- (NSError *)err:(NSString *)msg {
    return [NSError errorWithDomain:@"A2APIModDownloader" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"前置模组安装失败"}];
}

@end
