//
//  A2LoaderVersionSource.m
//  Air2
//
//  各模组加载器的版本列表获取。
//

#import "A2LoaderVersionSource.h"
#import "A2LoaderVersionSource+Forge.h"
#import "A2MirrorResolver.h"
#import "A2Logger.h"

#pragma mark - 数据源

static NSString *const kFabricMeta    = @"https://meta.fabricmc.net/v2";
static NSString *const kFabricMirror  = @"https://bmclapi2.bangbang93.com/fabric-meta/v2";
static NSString *const kQuiltMeta     = @"https://meta.quiltmc.org/v3";
static NSString *const kLegacyFabricMeta   = @"https://meta.legacyfabric.net/v2";
static NSString *const kLegacyFabricMirror = @"https://bmclapi2.bangbang93.com/legacy-fabric-meta/v2";
static NSString *const kBabricMeta    = @"https://meta.babric.gjgfz.cn/v2";

/// Cleanroom —— HMCL 维护的 metadata
static NSString *const kCleanroomIndex =
    @"https://hmcl-dev.github.io/metadata/cleanroom/index.json";
static NSString *const kCleanroomInstallerBase =
    @"https://hmcl-dev.github.io/metadata/cleanroom/files";

/// OptiFine
static NSString *const kOptiFineSite   = @"https://optifine.net";
static NSString *const kOptiFineMirror  = @"https://bmclapi2.bangbang93.com/optifine";

static NSString *const kUserAgent =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Air2/0.1.0";

static void A2Main(dispatch_block_t b) {
    if ([NSThread isMainThread]) b();
    else dispatch_async(dispatch_get_main_queue(), b);
}

#pragma mark - OptiFine 版本

@implementation A2OptiFineVersionInfo

/// OptiFine_1.10.2_HD_U_C1.jar → 1.10.2_HD_U_C1
- (NSString *)mavenVersion {
    NSString *v = self.fileName;
    if ([v hasPrefix:@"preview_"]) v = [v substringFromIndex:@"preview_".length];
    if ([v hasPrefix:@"OptiFine_"]) v = [v substringFromIndex:@"OptiFine_".length];
    if ([v hasSuffix:@".jar"]) v = [v substringToIndex:v.length - 4];
    return v;
}

- (NSString *)downloadURL {
    // 官方下载走 downloadx 端点（需要带 f 参数）
    return [NSString stringWithFormat:@"%@/downloadx?f=%@&x=%@",
            kOptiFineSite, self.fileName, self.mcVersion];
}

@end

#pragma mark - 主实现

@implementation A2LoaderVersionSource

+ (instancetype)shared {
    static A2LoaderVersionSource *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2LoaderVersionSource alloc] init];
    });
    return shared;
}

#pragma mark - 网络工具

- (void)GET:(NSString *)urlString
      isJSON:(BOOL)isJSON
  completion:(void (^)(id _Nullable result, NSError * _Nullable error))completion {

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        A2Main(^{ if (completion) completion(nil, [self err:@"URL 无效"]); });
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 25;
    [req setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;

        // 404 表示该 MC 版本没有这个加载器 —— 返回空列表而非错误
        if (http.statusCode == 404) {
            A2Main(^{ if (completion) completion(isJSON ? @[] : @"", nil); });
            return;
        }
        if (error || http.statusCode < 200 || http.statusCode >= 300 || !data) {
            A2Main(^{
                if (completion) {
                    completion(nil, error ?: [self err:[NSString stringWithFormat:
                        @"HTTP %ld", (long)http.statusCode]]);
                }
            });
            return;
        }

        if (isJSON) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            A2Main(^{
                if (completion) completion(json, json ? nil : [self err:@"返回数据格式异常"]);
            });
        } else {
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            A2Main(^{
                if (completion) completion(text, text ? nil : [self err:@"文本解码失败"]);
            });
        }
    }];
    [t resume];
}

- (NSError *)err:(NSString *)msg {
    return [NSError errorWithDomain:@"A2LoaderVersionSource" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"加载器版本获取失败"}];
}

#pragma mark - Fabric 系

/// Fabric / Quilt / LegacyFabric / Babric
///
/// 四家 meta 格式一致：
///   GET {base}/versions
///   → { "game": [{"version":"1.20.1"}...], "loader": [{"version":"0.15.0","stable":true}...] }
- (void)fetchFabricLikeFrom:(NSString *)officialURL
                     mirror:(nullable NSString *)mirrorURL
                       type:(A2ModLoaderType)type
                  mcVersion:(NSString *)mcVersion
                 completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    // 国内优先镜像
    NSString *base = officialURL;
    if (mirrorURL.length && [A2MirrorResolver isChinaMainland]) {
        base = mirrorURL;
    }

    NSString *url = [base stringByAppendingPathComponent:@"versions"];

    [self GET:url isJSON:YES completion:^(id result, NSError *error) {
        if (error) {
            // 镜像失败退回官方
            if (mirrorURL.length && ![base isEqualToString:officialURL]) {
                [self fetchFabricLikeFrom:officialURL mirror:nil type:type
                                mcVersion:mcVersion completion:completion];
                return;
            }
            if (completion) completion(@[], nil);
            return;
        }

        NSDictionary *json = [result isKindOfClass:NSDictionary.class] ? result : nil;
        if (!json) { if (completion) completion(@[], nil); return; }

        // 先确认该 MC 版本被支持
        NSArray *games = json[@"game"];
        BOOL supported = NO;
        if ([games isKindOfClass:NSArray.class]) {
            for (NSDictionary *g in games) {
                if ([g isKindOfClass:NSDictionary.class] &&
                    [g[@"version"] isEqualToString:mcVersion]) {
                    supported = YES;
                    break;
                }
            }
        }
        if (!supported) {
            // 不支持返回空 —— 上层据此提示「此版本无可用加载器」
            if (completion) completion(@[], nil);
            return;
        }

        NSArray *loaders = json[@"loader"];
        NSMutableArray<A2ModLoaderVersion *> *out = [NSMutableArray array];
        if ([loaders isKindOfClass:NSArray.class]) {
            for (NSDictionary *l in loaders) {
                if (![l isKindOfClass:NSDictionary.class]) continue;
                NSString *v = l[@"version"];
                if (![v isKindOfClass:NSString.class]) continue;
                [out addObject:[A2ModLoaderVersion version:v
                                                     stable:[l[@"stable"] boolValue]
                                                       type:type]];
            }
        }

        [A2Logger info:@"LoaderVersionSource"
               message:[NSString stringWithFormat:@"%@ %@ → %lu 个版本",
                        [A2ModLoaderAPI displayNameForType:type], mcVersion,
                        (unsigned long)out.count]];

        if (completion) completion(out, nil);
    }];
}

#pragma mark - Cleanroom

/// Cleanroom —— 固定继承 1.12.2。
///
/// 数据源是 HMCL 维护的 metadata JSON：
///   { "versions": [ { "version": "0.4.4-alpha", "createdAt": "..." } ] }
/// 安装器地址：
///   https://hmcl-dev.github.io/metadata/cleanroom/files/cleanroom-{v}-installer.jar
- (void)fetchCleanroomVersions:(NSString *)mcVersion
                    completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    // Cleanroom 只支持 1.12.2
    if (![mcVersion isEqualToString:@"1.12.2"]) {
        if (completion) completion(@[], nil);
        return;
    }

    [self GET:kCleanroomIndex isJSON:YES completion:^(id result, NSError *error) {
        if (error) { if (completion) completion(@[], nil); return; }

        NSDictionary *json = [result isKindOfClass:NSDictionary.class] ? result : nil;
        NSArray *versions = json[@"versions"];
        NSMutableArray<A2ModLoaderVersion *> *out = [NSMutableArray array];

        if ([versions isKindOfClass:NSArray.class]) {
            for (id v in versions) {
                // 兼容两种结构：字符串数组 或 对象数组
                NSString *ver = nil;
                if ([v isKindOfClass:NSString.class]) {
                    ver = v;
                } else if ([v isKindOfClass:NSDictionary.class]) {
                    ver = v[@"version"];
                }
                if (![ver isKindOfClass:NSString.class]) continue;

                BOOL stable = ![ver.lowercaseString containsString:@"alpha"]
                           && ![ver.lowercaseString containsString:@"beta"];
                [out addObject:[A2ModLoaderVersion version:ver
                                                     stable:stable
                                                       type:A2ModLoaderTypeCleanroom]];
            }
        }

        [A2Logger info:@"LoaderVersionSource"
               message:[NSString stringWithFormat:@"Cleanroom → %lu 个版本",
                        (unsigned long)out.count]];

        if (completion) completion(out, nil);
    }];
}

#pragma mark - OptiFine

/// OptiFine 版本列表。
///
/// 官方站点没有 API，只能爬页面。国内走 BMCLAPI 的 versionList（JSON）。
- (void)fetchOptiFineVersions:(NSString *)mcVersion
                   completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    if ([A2MirrorResolver isChinaMainland]) {
        NSString *url = [NSString stringWithFormat:@"%@/versionList", kOptiFineMirror];
        [self GET:url isJSON:YES completion:^(id result, NSError *error) {
            if (error || ![result isKindOfClass:NSArray.class]) {
                [self fetchOptiFineFromHTML:mcVersion completion:completion];
                return;
            }
            NSArray *list = result;
            NSMutableArray<A2ModLoaderVersion *> *out = [NSMutableArray array];
            for (id item in list) {
                NSString *name = nil;
                if ([item isKindOfClass:NSString.class]) {
                    name = item;
                } else if ([item isKindOfClass:NSDictionary.class]) {
                    name = item[@"name"];
                }
                if (![name isKindOfClass:NSString.class]) continue;

                A2OptiFineVersionInfo *info = [self parseOptiFineName:name];
                if (!info) continue;
                if (![info.mcVersion isEqualToString:mcVersion]) continue;

                [out addObject:[A2ModLoaderVersion version:info.version
                                                     stable:!info.preview
                                                       type:A2ModLoaderTypeOptiFine]];
            }
            [A2Logger info:@"LoaderVersionSource"
                   message:[NSString stringWithFormat:@"OptiFine %@ → %lu 个版本",
                            mcVersion, (unsigned long)out.count]];
            if (completion) completion(out, nil);
        }];
        return;
    }

    [self fetchOptiFineFromHTML:mcVersion completion:completion];
}

/// 从 OptiFine 官方页面解析。
/// 页面地址：https://optifine.net/downloads
/// 每个条目形如：
///   <a href="adloadx?f=OptiFine_1.10.2_HD_U_C1.jar">...
- (void)fetchOptiFineFromHTML:(NSString *)mcVersion
                   completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    NSString *url = [kOptiFineSite stringByAppendingPathComponent:@"downloads"];

    [self GET:url isJSON:NO completion:^(id result, NSError *error) {
        NSString *html = [result isKindOfClass:NSString.class] ? result : nil;
        NSMutableArray<A2ModLoaderVersion *> *out = [NSMutableArray array];

        if (html.length > 100) {
            // 提取所有 OptiFine_*.jar / preview_OptiFine_*.jar 的文件名
            NSRegularExpression *re = [NSRegularExpression
                regularExpressionWithPattern:@"(preview_)?OptiFine_[0-9A-Za-z_.]+\\.jar"
                                     options:0 error:nil];
            NSArray *matches = [re matchesInString:html options:0
                                             range:NSMakeRange(0, html.length)];
            NSMutableSet<NSString *> *seen = [NSMutableSet set];

            for (NSTextCheckingResult *m in matches) {
                NSString *name = [html substringWithRange:m.range];
                if ([seen containsObject:name]) continue;
                [seen addObject:name];

                A2OptiFineVersionInfo *info = [self parseOptiFineName:name];
                if (!info) continue;
                if (![info.mcVersion isEqualToString:mcVersion]) continue;

                [out addObject:[A2ModLoaderVersion version:info.version
                                                     stable:!info.preview
                                                       type:A2ModLoaderTypeOptiFine]];
            }
        }

        [A2Logger info:@"LoaderVersionSource"
               message:[NSString stringWithFormat:@"OptiFine %@ → %lu 个版本（HTML）",
                        mcVersion, (unsigned long)out.count]];

        if (completion) completion(out, nil);
    }];
}

/// 从文件名解析 OptiFine 信息。
///   OptiFine_1.10.2_HD_U_C1.jar → mcVersion=1.10.2, version=C1
///   1.20.6_J1_pre18.jar 这种则用 _ 分段
- (nullable A2OptiFineVersionInfo *)parseOptiFineName:(NSString *)fileName {
    if (fileName.length == 0) return nil;

    A2OptiFineVersionInfo *info = [A2OptiFineVersionInfo new];
    info.fileName = fileName;
    info.preview = [fileName hasPrefix:@"preview_"];
    info.displayName = [fileName stringByReplacingOccurrencesOfString:@".jar" withString:@""];

    // 去掉前缀得到 "1.10.2_HD_U_C1"
    NSString *body = info.displayName;
    if ([body hasPrefix:@"preview_"]) body = [body substringFromIndex:@"preview_".length];
    if ([body hasPrefix:@"OptiFine_"]) body = [body substringFromIndex:@"OptiFine_".length];

    NSArray<NSString *> *parts = [body componentsSeparatedByString:@"_"];
    if (parts.count < 2) return nil;

    info.mcVersion = parts[0];
    // 版本号是剩余部分的拼接，去掉 HD/U 这类固定标记
    NSMutableArray<NSString *> *versionParts = [NSMutableArray array];
    for (NSUInteger i = 1; i < parts.count; i++) {
        NSString *p = parts[i];
        // HD / U 是固定的画质与版本标记，不进版本号
        if ([p isEqualToString:@"HD"] || [p isEqualToString:@"U"]) continue;
        [versionParts addObject:p];
    }
    info.version = [versionParts componentsJoinedByString:@"_"];
    if (info.version.length == 0) return nil;

    return info;
}

#pragma mark - 统一入口

- (void)versionsForLoader:(A2ModLoaderType)type
                mcVersion:(NSString *)mcVersion
               completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    if (mcVersion.length == 0) {
        if (completion) completion(@[], nil);
        return;
    }

    switch (type) {
        case A2ModLoaderTypeFabric:
            [self fetchFabricLikeFrom:kFabricMeta mirror:kFabricMirror
                                 type:type mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeQuilt:
            [self fetchFabricLikeFrom:kQuiltMeta mirror:nil
                                 type:type mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeLegacyFabric:
            [self fetchFabricLikeFrom:kLegacyFabricMeta mirror:kLegacyFabricMirror
                                 type:type mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeBabric:
            [self fetchFabricLikeFrom:kBabricMeta mirror:nil
                                 type:type mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeForge:
            [self fetchForgeVersionsForMC:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeNeoForge:
            [self fetchNeoForgeVersionsForMC:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeCleanroom:
            [self fetchCleanroomVersions:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeOptiFine:
            [self fetchOptiFineVersions:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeLiteLoader:
        case A2ModLoaderTypeRift:
        default:
            // 这两个没有稳定的公开接口 —— 与 ZL2 的 autoDownloadable=false 一致。
            // 返回空数组而不是假数据。
            if (completion) completion(@[], nil);
            break;
    }
}

@end
