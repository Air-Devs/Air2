//
//  A2ModLoaderAPI.m
//  Air2
//
//  模组加载器的版本查询。对照 ZL2 的 addons/modloader 实现。
//

#import "A2ModLoaderAPI.h"

#pragma mark - 数据源

/// Fabric 系（Fabric / Quilt / LegacyFabric / Babric）共用 meta 格式
static NSString *const kFabricOfficial       = @"https://meta.fabricmc.net/v2";
static NSString *const kFabricMirror         = @"https://bmclapi2.bangbang93.com/fabric-meta/v2";
static NSString *const kQuiltOfficial        = @"https://meta.quiltmc.org/v3";
static NSString *const kLegacyFabricOfficial = @"https://meta.legacyfabric.net/v2";
static NSString *const kLegacyFabricMirror   = @"https://bmclapi2.bangbang93.com/legacy-fabric-meta/v2";
static NSString *const kBabricOfficial       = @"https://meta.babric.gjgfz.cn/v2";

/// Forge 系
static NSString *const kForgeMaven    = @"https://maven.minecraftforge.net";
static NSString *const kNeoForgeMaven = @"https://maven.neoforged.net";

/// Cleanroom —— 有独立的 maven
static NSString *const kCleanroomMaven = @"https://repo.cleanroommc.com/releases";

/// Maven 版本列表 API（ZL2 用的就是这个形式）
static NSString *const kMavenVersionsSuffix = @"/api/maven/versions/releases";

static NSString *const kUserAgent = @"Air-Devs/Air2/0.1.0 (github.com/Air-Devs/Air2)";

static void A2RunOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

#pragma mark - 类型判定

BOOL A2ModLoaderIsLoader(A2ModLoaderType type) {
    switch (type) {
        case A2ModLoaderTypeFabric:
        case A2ModLoaderTypeQuilt:
        case A2ModLoaderTypeLegacyFabric:
        case A2ModLoaderTypeBabric:
        case A2ModLoaderTypeForge:
        case A2ModLoaderTypeNeoForge:
        case A2ModLoaderTypeCleanroom:
        case A2ModLoaderTypeLiteLoader:
        case A2ModLoaderTypeOptiFine:
        case A2ModLoaderTypeRift:
            return YES;
        default:
            return NO;
    }
}

BOOL A2ModLoaderIsAPIMod(A2ModLoaderType type) {
    switch (type) {
        case A2ModLoaderTypeFabricAPI:
        case A2ModLoaderTypeQuiltAPI:
        case A2ModLoaderTypeLegacyFabricAPI:
        case A2ModLoaderTypeBabricAPI:
            return YES;
        default:
            return NO;
    }
}

/// 是否支持自动安装。对照 ZL2 的 autoDownloadable 标记：
///   OptiFine / Babric / LiteLoader / Rift 官方没有稳定接口 —— ZL2 也不自动装。
BOOL A2ModLoaderSupportsAutoInstall(A2ModLoaderType type) {
    switch (type) {
        case A2ModLoaderTypeFabric:
        case A2ModLoaderTypeQuilt:
        case A2ModLoaderTypeLegacyFabric:
        case A2ModLoaderTypeForge:
        case A2ModLoaderTypeNeoForge:
        case A2ModLoaderTypeCleanroom:
            return YES;

        // 这几个 ZL2 标的是 autoDownloadable = false
        case A2ModLoaderTypeOptiFine:
        case A2ModLoaderTypeBabric:
        case A2ModLoaderTypeLiteLoader:
        case A2ModLoaderTypeRift:
            return NO;

        // 前置模组走 mod 下载流程，不走加载器安装
        default:
            return NO;
    }
}


#pragma mark - 版本模型

@implementation A2ModLoaderVersion

+ (instancetype)version:(NSString *)v stable:(BOOL)stable type:(A2ModLoaderType)type {
    A2ModLoaderVersion *m = [A2ModLoaderVersion new];
    m.version = v;
    m.stable = stable;
    m.type = type;
    return m;
}

- (NSString *)displayName {
    return [NSString stringWithFormat:@"%@ %@",
            [A2ModLoaderAPI displayNameForType:self.type], self.version];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<A2ModLoaderVersion %@ %@%@>",
            [A2ModLoaderAPI identifierForType:self.type], self.version,
            self.stable ? @"" : @" (beta)"];
}

@end

#pragma mark - API

@implementation A2ModLoaderAPI

+ (instancetype)shared {
    static A2ModLoaderAPI *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2ModLoaderAPI alloc] init];
    });
    return shared;
}

+ (NSString *)displayNameForType:(A2ModLoaderType)type {
    switch (type) {
        case A2ModLoaderTypeFabric:          return @"Fabric";
        case A2ModLoaderTypeQuilt:           return @"Quilt";
        case A2ModLoaderTypeLegacyFabric:    return @"Legacy Fabric";
        case A2ModLoaderTypeBabric:          return @"Babric";
        case A2ModLoaderTypeForge:           return @"Forge";
        case A2ModLoaderTypeNeoForge:        return @"NeoForge";
        case A2ModLoaderTypeCleanroom:       return @"Cleanroom";
        case A2ModLoaderTypeLiteLoader:      return @"LiteLoader";
        case A2ModLoaderTypeOptiFine:        return @"OptiFine";
        case A2ModLoaderTypeRift:            return @"Rift";
        case A2ModLoaderTypeFabricAPI:       return @"Fabric API";
        case A2ModLoaderTypeQuiltAPI:        return @"Quilted Fabric API";
        case A2ModLoaderTypeLegacyFabricAPI: return @"Legacy Fabric API";
        case A2ModLoaderTypeBabricAPI:       return @"Babric API";
        case A2ModLoaderTypeUnknown:
        default:                             return @"未知";
    }
}

+ (NSString *)identifierForType:(A2ModLoaderType)type {
    switch (type) {
        case A2ModLoaderTypeFabric:          return @"fabric";
        case A2ModLoaderTypeQuilt:           return @"quilt";
        case A2ModLoaderTypeLegacyFabric:    return @"legacy-fabric";
        case A2ModLoaderTypeBabric:          return @"babric";
        case A2ModLoaderTypeForge:           return @"forge";
        case A2ModLoaderTypeNeoForge:        return @"neoforge";
        case A2ModLoaderTypeCleanroom:       return @"cleanroom";
        case A2ModLoaderTypeLiteLoader:      return @"liteloader";
        case A2ModLoaderTypeOptiFine:        return @"optifine";
        case A2ModLoaderTypeRift:            return @"rift";
        case A2ModLoaderTypeFabricAPI:       return @"fabric-api";
        case A2ModLoaderTypeQuiltAPI:        return @"quilt-api";
        case A2ModLoaderTypeLegacyFabricAPI: return @"legacy-fabric-api";
        case A2ModLoaderTypeBabricAPI:       return @"babric-api";
        default:                             return @"unknown";
    }
}

+ (NSArray<NSNumber *> *)allLoaderTypes {
    return @[
        // 加载器
        @(A2ModLoaderTypeFabric),
        @(A2ModLoaderTypeQuilt),
        @(A2ModLoaderTypeForge),
        @(A2ModLoaderTypeNeoForge),
        @(A2ModLoaderTypeCleanroom),
        @(A2ModLoaderTypeLegacyFabric),
        @(A2ModLoaderTypeOptiFine),
        @(A2ModLoaderTypeLiteLoader),
        @(A2ModLoaderTypeBabric),
        @(A2ModLoaderTypeRift),
    ];
}

#pragma mark - 网络

- (NSMutableURLRequest *)requestWithURLString:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 20;
    [req setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return req;
}

/// 简单重试（2 次）。加载器 meta 服务偶尔抖动，重试比直接失败好。
- (void)GET:(NSString *)urlString
      retry:(NSInteger)retry
 completion:(void (^)(id _Nullable json, NSError * _Nullable error))completion {

    NSMutableURLRequest *req = [self requestWithURLString:urlString];
    if (!req) {
        A2RunOnMain(^{ if (completion) completion(nil, [self error:@"URL 无效"]); });
        return;
    }

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;

        if (error || http.statusCode < 200 || http.statusCode >= 300) {
            if (retry > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    [self GET:urlString retry:retry - 1 completion:completion];
                });
                return;
            }
            A2RunOnMain(^{
                if (completion) {
                    completion(nil, error ?: [self error:[NSString stringWithFormat:
                        @"HTTP %ld", (long)http.statusCode]]);
                }
            });
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        A2RunOnMain(^{
            if (completion) completion(json, json ? nil : [self error:@"返回数据格式异常"]);
        });
    }];
    [task resume];
}

- (NSError *)error:(NSString *)msg {
    return [NSError errorWithDomain:@"A2ModLoader" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

#pragma mark - Fabric 系

/// Fabric / Quilt / LegacyFabric / Babric 的 meta 格式一致
- (void)fetchFabricLikeFrom:(NSString *)baseURL
                       type:(A2ModLoaderType)type
                  mcVersion:(NSString *)mcVersion
                 completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    NSString *url = [baseURL stringByAppendingPathComponent:@"versions"];

    [self GET:url retry:2 completion:^(id json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (![json isKindOfClass:NSDictionary.class]) {
            if (completion) completion(nil, [self error:@"数据格式异常"]);
            return;
        }

        // 先确认这个 MC 版本被该加载器支持
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
            // 不支持就返回空数组（不是错误）—— 上层据此提示「此版本无可用加载器」
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
        if (completion) completion(out, nil);
    }];
}

#pragma mark - Forge 系（Maven 版本列表）

/// 从 Maven 的 versions API 取版本列表。
///
/// 返回的结构是 {"isSnapshot":bool,"versions":[...]}，
/// 版本号形态各家不同，取出后由调用方按 MC 版本过滤。
- (void)fetchMavenVersionsFrom:(NSString *)mavenBase
                          path:(NSString *)artifactPath
                          type:(A2ModLoaderType)type
                    mcVersion:(NSString *)mcVersion
                   completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    NSString *url = [NSString stringWithFormat:@"%@%@/%@", mavenBase, artifactPath,
                     @"maven-metadata.xml"];
    // Maven 的 XML 元数据比 JSON API 通用性更好（有些仓库没有 JSON API）
    // 这里优先试 JSON，失败退回解析 XML。

    NSString *jsonURL = [NSString stringWithFormat:@"%@%@", mavenBase, kMavenVersionsSuffix];
    [self GET:jsonURL retry:2 completion:^(id json, NSError *error) {
        if (error || ![json isKindOfClass:NSDictionary.class]) {
            // 退回 XML 解析
            [self fetchMavenVersionsFromXML:url type:type mcVersion:mcVersion
                                 completion:completion];
            return;
        }
        NSArray *versions = json[@"versions"];
        NSMutableArray<A2ModLoaderVersion *> *out = [NSMutableArray array];
        if ([versions isKindOfClass:NSArray.class]) {
            for (id v in versions) {
                if (![v isKindOfClass:NSString.class]) continue;
                NSString *ver = [self normalizedVersion:v type:type mcVersion:mcVersion];
                if (ver) [out addObject:[A2ModLoaderVersion version:ver stable:YES type:type]];
            }
        }
        if (completion) completion(out, nil);
    }];
}

/// Maven metadata XML 兜底解析。
/// 只做最朴素的 <version>xxx</version> 提取 —— 没必要引入 XML 库。
- (void)fetchMavenVersionsFromXML:(NSString *)url
                             type:(A2ModLoaderType)type
                        mcVersion:(NSString *)mcVersion
                       completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    NSMutableURLRequest *req = [self requestWithURLString:url];
    if (!req) {
        if (completion) completion(@[], nil);
        return;
    }

    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error || !data) {
            A2RunOnMain(^{ if (completion) completion(@[], nil); });
            return;
        }
        NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSMutableArray<A2ModLoaderVersion *> *out = [NSMutableArray array];
        if (xml) {
            NSRegularExpression *re = [NSRegularExpression
                regularExpressionWithPattern:@"<version>([^<]+)</version>"
                                     options:0 error:nil];
            NSArray *matches = [re matchesInString:xml options:0
                                             range:NSMakeRange(0, xml.length)];
            for (NSTextCheckingResult *m in matches) {
                NSString *raw = [xml substringWithRange:[m rangeAtIndex:1]];
                NSString *ver = [self normalizedVersion:raw type:type mcVersion:mcVersion];
                if (ver) [out addObject:[A2ModLoaderVersion version:ver stable:YES type:type]];
            }
        }
        A2RunOnMain(^{ if (completion) completion(out, nil); });
    }];
    [t resume];
}

/// 版本号归一化与过滤。
///
/// Maven 里的版本号形态：
///   Forge:    {mcVersion}-{forgeVersion}  如 1.21.5-55.0.1
///   NeoForge: {mcMajor}.{mcMinor}.{build} 如 21.1.72
///   Cleanroom: {mcVersion}-{build}        如 1.12.2-0.4.4-alpha
///
/// 返回 nil 表示该版本不属于目标 MC 版本。
- (NSString *)normalizedVersion:(NSString *)raw
                           type:(A2ModLoaderType)type
                      mcVersion:(NSString *)mcVersion {

    if (type == A2ModLoaderTypeNeoForge) {
        // 1.21.1 → "21.1."，1.21 → "21.0."
        NSArray<NSString *> *parts = [mcVersion componentsSeparatedByString:@"."];
        if (parts.count < 2) return nil;
        NSString *prefix = [NSString stringWithFormat:@"%@.%@.",
                            parts[1], parts.count >= 3 ? parts[2] : @"0"];
        return [raw hasPrefix:prefix] ? raw : nil;
    }

    if (type == A2ModLoaderTypeForge || type == A2ModLoaderTypeCleanroom) {
        NSString *p = [mcVersion stringByAppendingString:@"-"];
        if (![raw hasPrefix:p]) return nil;
        // 展示时去掉 MC 版本前缀
        return [raw substringFromIndex:p.length];
    }

    return raw;
}

#pragma mark - 统一入口

- (void)versionsForLoader:(A2ModLoaderType)type
                mcVersion:(NSString *)mcVersion
               completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    if (mcVersion.length == 0) {
        if (completion) completion(nil, [self error:@"未指定游戏版本"]);
        return;
    }

    switch (type) {
        case A2ModLoaderTypeFabric:
            [self fetchFabricLikeFrom:kFabricOfficial type:type
                            mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeQuilt:
            [self fetchFabricLikeFrom:kQuiltOfficial type:type
                            mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeLegacyFabric:
            [self fetchFabricLikeFrom:kLegacyFabricOfficial type:type
                            mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeBabric:
            [self fetchFabricLikeFrom:kBabricOfficial type:type
                            mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeForge:
            [self fetchMavenVersionsFrom:kForgeMaven
                                    path:@"/net/minecraftforge/forge"
                                    type:type mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeNeoForge:
            [self fetchMavenVersionsFrom:kNeoForgeMaven
                                    path:@"/net/neoforged/neoforge"
                                    type:type mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeCleanroom:
            [self fetchMavenVersionsFrom:kCleanroomMaven
                                    path:@"/com/cleanroommc/cleanroom"
                                    type:type mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeOptiFine:
        case A2ModLoaderTypeLiteLoader:
        case A2ModLoaderTypeRift:
            // 这三个没有稳定的公开 API —— ZL2 也不自动装，UI 上标注手动安装。
            // 返回空数组而不是假数据。
            if (completion) completion(@[], nil);
            break;

        default:
            // 前置模组走 mod 下载流程
            if (completion) completion(@[], nil);
            break;
    }
}

@end
