//
//  A2LoaderVersionSource+Forge.m
//  Air2
//
//  Forge / NeoForge 的版本列表获取。
//
//  这两家最麻烦的地方在于【版本号与游戏版本的对应关系不是直白的】，
//  各有各的命名演变，必须逐个规则处理。
//

#import "A2LoaderVersionSource.h"
#import "A2MirrorResolver.h"
#import "A2Logger.h"

static NSString *const kForgeMavenBase =
    @"https://files.minecraftforge.net/maven/net/minecraftforge/forge";
static NSString *const kForgeMirrorBase =
    @"https://bmclapi2.bangbang93.com/forge/minecraft";
static NSString *const kNeoForgeMaven =
    @"https://maven.neoforged.net/releases/net/neoforged";
static NSString *const kNeoForgeMirror =
    @"https://bmclapi2.bangbang93.com/maven/net/neoforged";

static NSString *const kUserAgent =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Air2/0.1.0";

#pragma mark - Forge 版本


#pragma mark - NeoForge 版本

@implementation A2NeoForgeVersionInfo

/// NeoForge 下载地址：
///   {maven}/releases/net/neoforged/{forge|neoforge}/{raw}/{name}-{raw}.jar
- (NSString *)downloadURL {
    NSString *pkg = self.legacyForge ? @"forge" : @"neoforge";
    return [NSString stringWithFormat:@"%@/%@/%@/%@-%@.jar",
            kNeoForgeMaven, pkg, self.rawVersion, pkg, self.rawVersion];
}

@end

#pragma mark - 版本号解析

@implementation A2LoaderVersionSource (Forge)

/// Forge 版本列表。
///
/// 官方没有 API —— 只能爬 index_{mcVersion}.html。
/// 国内网络优先用 BMCLAPI 的 JSON 接口（更好解析）。
- (void)fetchForgeVersionsForMC:(NSString *)mcVersion
                     completion:(void (^)(NSArray<A2ModLoaderVersion *> *,
                                          NSError *))completion {

    // URL 里的 . 要换成 _（Forge 处理 1.7.10-pre4 这类版本时的兼容做法）
    NSString *urlSafe = [mcVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"];

    // 国内先用镜像（JSON，好解析）
    if ([A2MirrorResolver isChinaMainland]) {
        NSString *mirrorURL = [NSString stringWithFormat:@"%@/%@", kForgeMirrorBase, urlSafe];
        [self fetchForgeFromBMCLAPI:mirrorURL mcVersion:mcVersion completion:completion];
        return;
    }

    NSString *htmlURL = [NSString stringWithFormat:
        @"%@/index_%@.html", kForgeMavenBase, urlSafe];
    [self fetchForgeFromHTML:htmlURL mcVersion:mcVersion completion:completion];
}

/// BMCLAPI 的 Forge 列表（JSON）
- (void)fetchForgeFromBMCLAPI:(NSString *)urlString
                    mcVersion:(NSString *)mcVersion
                   completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    req.timeoutInterval = 25;
    [req setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        if (error || http.statusCode != 200) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(@[], nil);   // 该 MC 版本无 Forge
            });
            return;
        }

        NSArray *tokens = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSMutableArray<A2ModLoaderVersion *> *out = [NSMutableArray array];

        if ([tokens isKindOfClass:NSArray.class]) {
            for (NSDictionary *token in tokens) {
                if (![token isKindOfClass:NSDictionary.class]) continue;
                NSString *version = token[@"version"];
                if (![version isKindOfClass:NSString.class]) continue;

                NSString *branch = [token[@"branch"] isKindOfClass:NSString.class]
                    ? token[@"branch"] : nil;
                NSString *fileVersion = branch.length
                    ? [NSString stringWithFormat:@"%@-%@", version, branch]
                    : version;

                // 版本列表只需要「版本号 + 是否稳定」，详细信息在安装时再取。
                // BMCLAPI 的 JSON 没给 recommended 标记，统一按稳定处理。
                [out addObject:[A2ModLoaderVersion version:fileVersion
                                                    stable:YES
                                                      type:A2ModLoaderTypeForge]];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(out, nil);
        });
    }];
    [t resume];
}

/// 从官方 HTML 解析。
///
/// 页面里每个版本是一段 <td class="download-version...">，
/// 用正则抽出需要的字段。这是 ZL2 的做法 —— Forge 官方确实没有 API。
- (void)fetchForgeFromHTML:(NSString *)urlString
                 mcVersion:(NSString *)mcVersion
                completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    req.timeoutInterval = 30;
    [req setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        if (error || http.statusCode != 200 || !data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(@[], nil);
            });
            return;
        }

        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSMutableArray<A2ModLoaderVersion *> *out = [NSMutableArray array];

        if (html.length > 100) {
            // 按版本区块切分
            NSArray<NSString *> *chunks = [html componentsSeparatedByString:@"<td class=\"download-version"];
            for (NSUInteger i = 1; i < chunks.count; i++) {
                NSString *chunk = chunks[i];

                // 版本号：(?<=\D)\d+(\.\d+)+
                NSRegularExpression *verRE = [NSRegularExpression
                    regularExpressionWithPattern:@"(\\d+(?:\\.\\d+)+)" options:0 error:nil];
                NSTextCheckingResult *verMatch =
                    [verRE firstMatchInString:chunk options:0
                                        range:NSMakeRange(0, chunk.length)];
                if (!verMatch) continue;
                NSString *version = [chunk substringWithRange:verMatch.range];

                // 是否有安装产物（installer.jar 优先）
                A2ForgeFileCategory cat = A2ForgeFileCategoryUnknown;
                if ([chunk containsString:@"classifier-installer"]) {
                    cat = A2ForgeFileCategoryInstaller;
                } else if ([chunk containsString:@"classifier-universal"]) {
                    cat = A2ForgeFileCategoryUniversal;
                } else if ([chunk containsString:@"client.zip"]) {
                    cat = A2ForgeFileCategoryClient;
                }
                if (cat == A2ForgeFileCategoryUnknown) continue;

                // 分支：从下载链接里抠
                NSString *branch = nil;
                NSRegularExpression *branchRE = [NSRegularExpression
                    regularExpressionWithPattern:
                        [NSString stringWithFormat:@"-%@-([^-\\\"]+)-[a-z]+\\.[a-z]{3}", version]
                                     options:0 error:nil];
                NSTextCheckingResult *bm =
                    [branchRE firstMatchInString:chunk options:0 range:NSMakeRange(0, chunk.length)];
                if (bm && bm.numberOfRanges > 1) {
                    branch = [chunk substringWithRange:[bm rangeAtIndex:1]];
                }

                NSString *fileVersion = branch.length
                    ? [NSString stringWithFormat:@"%@-%@", version, branch]
                    : version;

                [out addObject:[A2ModLoaderVersion version:fileVersion
                                                    stable:YES
                                                      type:A2ModLoaderTypeForge]];
            }
        }

        [A2Logger info:@"LoaderVersionSource"
               message:[NSString stringWithFormat:@"Forge %@ → %lu 个版本（HTML）",
                        mcVersion, (unsigned long)out.count]];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(out, nil);
        });
    }];
    [t resume];
}

#pragma mark - NeoForge

/// NeoForge 版本列表。
///
/// 数据源是 Maven 的版本列表。麻烦的是版本号到游戏版本的映射。
- (void)fetchNeoForgeVersionsForMC:(NSString *)mcVersion
                        completion:(void (^)(NSArray<A2ModLoaderVersion *> *,
                                             NSError *))completion {

    NSString *url = [NSString stringWithFormat:@"%@/neoforge/maven-metadata.xml", kNeoForgeMaven];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 30;
    [req setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error || !data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(@[], nil);
            });
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
                A2NeoForgeVersionInfo *info = [self parseNeoForgeVersion:raw];

                // 只保留属于目标 MC 版本的
                if (![info.mcVersion isEqualToString:mcVersion]) continue;

                [out addObject:[A2ModLoaderVersion version:info.displayVersion
                                                    stable:!info.beta
                                                      type:A2ModLoaderTypeNeoForge]];
            }
        }

        [A2Logger info:@"LoaderVersionSource"
               message:[NSString stringWithFormat:@"NeoForge %@ → %lu 个版本",
                        mcVersion, (unsigned long)out.count]];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(out, nil);
        });
    }];
    [t resume];
}

/// 解析 NeoForge 的版本号 —— 对照 ZL2 的三条规则。
- (A2NeoForgeVersionInfo *)parseNeoForgeVersion:(NSString *)raw {
    A2NeoForgeVersionInfo *info = [A2NeoForgeVersionInfo new];
    info.rawVersion = raw;
    info.beta = [raw.lowercaseString containsString:@"beta"];

    // 规则 1：含 1.20.1 —— 早期从 Forge 分叉的过渡命名
    if ([raw containsString:@"1.20.1"]) {
        info.legacyForge = YES;
        info.mcVersion = @"1.20.1";
        info.displayVersion = [raw stringByReplacingOccurrencesOfString:@"1.20.1-" withString:@""];
        return info;
    }

    // 规则 2：以 0. 开头 —— 特殊版本（快照类）
    if ([raw hasPrefix:@"0."]) {
        NSString *body = [raw substringFromIndex:2];
        NSString *beforeDash = [body componentsSeparatedByString:@"-"].firstObject;
        // "25w14craftmine.3" → "25w14craftmine"
        NSRange lastDot = [beforeDash rangeOfString:@"." options:NSBackwardsSearch];
        info.mcVersion = (lastDot.location != NSNotFound)
            ? [beforeDash substringToIndex:lastDot.location]
            : beforeDash;
        info.displayVersion = raw;
        return info;
    }

    // 规则 3：{major}.{minor}.{build}.
    //   21.1.72 → 游戏 1.21.1
    //   26.1.x 起改用新格式
    info.displayVersion = raw;
    info.mcVersion = [self mcVersionForNeoForgeBuild:raw];
    return info;
}

/// 从 NeoForge 的 21.1.72 反推游戏版本 1.21.1
- (NSString *)mcVersionForNeoForgeBuild:(NSString *)raw {
    NSArray<NSString *> *parts = [raw componentsSeparatedByString:@"-"].firstObject
        ? [[raw componentsSeparatedByString:@"-"].firstObject componentsSeparatedByString:@"."]
        : @[];
    if (parts.count < 2) return @"";

    NSInteger major = parts[0].integerValue;
    NSInteger minor = parts[1].integerValue;

    // 26+ 用新格式：26.1.x 直接对应游戏 26.1
    if (major >= 26) {
        return [NSString stringWithFormat:@"%ld.%ld", (long)major, (long)minor];
    }

    // 老格式：1.{major}.{minor}，minor 为 0 时省略
    return minor == 0
        ? [NSString stringWithFormat:@"1.%ld", (long)major]
        : [NSString stringWithFormat:@"1.%ld.%ld", (long)major, (long)minor];
}

@end
