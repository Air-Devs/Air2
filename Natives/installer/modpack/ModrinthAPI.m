#import "utils.h"
#import "ModrinthAPI.h"
#import "PLMirrorCenter.h"

/// 经 PLMirrorCenter 按资源下载（AssetDownload）策略应用镜像
/// （Modrinth CDN 文件 → MCIM 镜像），URL 为空或无法解析时回退原始字符串
static NSString *MRAMirrorResolvedURL(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return urlString;
    NSURL *resolved = [PLMirrorCenter preferredURLForOriginalURL:[NSURL URLWithString:urlString]
                                                    resourceType:PLMirrorResourceTypeAssetDownload];
    return resolved.absoluteString ?: urlString;
}

#pragma mark - ★ [MODSRC-LIST] 列表/搜索候选链

/// ★ [MODSRC-LIST] 全部候选源均失败时的错误码。
static const NSInteger kMRAMListAllSourcesFailedCode = 9001;

/// ★ [MODSRC-LIST] 把各候选的失败原因汇总成一条可辨识的错误（含 HTTP 状态码 / 源主机），
///   供 UI 显示 —— 取代旧实现「请求失败静默转成空数组 ⇒ 用户只看到『暂无』」。
static NSError *MRAMListRequestError(NSArray<NSString *> *failures) {
    NSString *detail = failures.count ? [failures componentsJoinedByString:@" | "] : @"无可用源";
    return [NSError errorWithDomain:@"ModrinthAPIError"
                               code:kMRAMListAllSourcesFailedCode
                           userInfo:@{NSLocalizedDescriptionKey:
                                          [NSString stringWithFormat:@"Modrinth 列表请求失败: %@", detail]}];
}

@interface ModrinthAPI ()
// ★ [MODSRC-LIST] 候选链列表请求：按顺序尝试 candidates，命中含 arrayKey 数组的 2xx 响应即回调
//   映射后的结果；每个候选失败（网络错误 / 非 2xx / 响应缺少 arrayKey 数组）都会记录原因并切下一个；
//   全部失败才回调 error。这样单一源不可达时不再整张列表直接空掉。
- (void)mramFetchListPathQuery:(NSString *)pathQuery
                    candidates:(NSArray<NSString *> *)candidates
                      arrayKey:(NSString *)arrayKey
                     mapObject:(NSDictionary * _Nullable (^)(NSDictionary *item))mapObject
                         index:(NSUInteger)index
                      failures:(NSMutableArray<NSString *> *)failures
                    completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;
@end

/// 把一个 Modrinth 版本支持的 MC 版本数组拼成界面可读的字符串。
///
/// 此前只取 game_versions.firstObject，导致「支持 1.20.1/1.20.2/1.20.4」的版本
/// 在列表里只显示 1.20.1 —— 用户会以为它不支持自己正在用的 1.20.4，
/// 从而挑错版本甚至放弃安装。
///
/// 保持原平行数组结构不变（mcVersionNames 仍与 versionNames 一一对应），
/// 只把单个字符串换成「多版本拼接」：超过 3 个时折叠为「首个 +N」，
/// 避免把列表行撑开。
static NSString *ameMCVersionsDisplayString(NSArray *gameVersions) {
    if (![gameVersions isKindOfClass:[NSArray class]] || gameVersions.count == 0) {
        return @"";
    }
    NSMutableArray<NSString *> *vers = [NSMutableArray new];
    for (id v in gameVersions) {
        if ([v isKindOfClass:[NSString class]] && [v length] > 0) [vers addObject:v];
    }
    if (vers.count == 0) return @"";
    if (vers.count <= 3) return [vers componentsJoinedByString:@"/"];
    return [NSString stringWithFormat:@"%@ +%lu", vers.firstObject, (unsigned long)(vers.count - 1)];
}

#pragma mark - 中文搜索关键词映射

/// 中文（及少量简写）→ 英文检索词。
///
/// Modrinth 的搜索索引以英文为主，直接提交中文关键词通常返回空结果，
/// 界面会显示「暂无」，用户容易误判为源不可用。对照 ZalithLauncher2 的
/// localizedModSearchKeywords，这里维护一份启动器用户的高频词映射。
/// 保持「命中才替换」的策略：未命中时原样返回，不劣化现状。
static NSString *ameLocalizedSearchKeyword(NSString *query) {
    if (![query isKindOfClass:[NSString class]] || query.length == 0) return query;

    // 按键长降序匹配，避免「光影」先被「光」之类的短键吃掉。
    static NSArray<NSArray<NSString *> *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            // 性能 / 优化
            @[@"优化", @"optimization"], @[@"性能", @"performance"],
            @[@"帧数", @"fps"], @[@"流畅", @"performance"],
            @[@"钠", @"sodium"], @[@"锂", @"lithium"], @[@"磷", @"phosphor"],
            @[@"铟", @"indium"], @[@"钾", @"potassium"],
            // 光影 / 视觉
            @[@"光影", @"shader"], @[@"着色器", @"shader"],
            @[@"材质", @"resource pack"], @[@"材质包", @"resource pack"],
            @[@"资源包", @"resource pack"], @[@"天空", @"sky"],
            @[@"水面", @"water"], @[@"动态光源", @"dynamic lights"],
            // 玩法 / 内容
            @[@"地图", @"map"], @[@"小地图", @"minimap"],
            @[@"机械", @"technology"], @[@"科技", @"technology"],
            @[@"魔法", @"magic"], @[@"工业", @"industrial"],
            @[@"自动化", @"automation"], @[@"能源", @"energy"],
            @[@"生存", @"survival"], @[@"冒险", @"adventure"],
            @[@"建筑", @"building"], @[@"装饰", @"decoration"],
            @[@"家具", @"furniture"], @[@"食物", @"food"],
            @[@"农业", @"farming"], @[@"钓鱼", @"fishing"],
            // 实用
            @[@"背包", @"inventory"], @[@"合成", @"crafting"],
            @[@"整理", @"sorting"], @[@"储物", @"storage"],
            @[@"任务", @"quest"], @[@"技能", @"skill"],
            @[@"血量", @"health"], @[@"生命", @"health"],
            @[@"生物", @"mob"], @[@"怪物", @"monster"],
            @[@"敌人", @"enemy"], @[@"boss", @"boss"],
            @[@"村民", @"villager"], @[@"村庄", @"village"],
            @[@"维度", @"dimension"], @[@"传送", @"teleport"],
            @[@"附魔", @"enchant"], @[@"药水", @"potion"],
            // 其它
            @[@"汉化", @"chinese"], @[@"中文", @"chinese"],
            @[@"优化模组", @"optimization mod"],
            @[@"辅助", @"utility"], @[@"工具", @"utility"],
            @[@"联机", @"multiplayer"], @[@"服务器", @"server"],
        ];
    });

    for (NSArray<NSString *> *pair in table) {
        if ([query containsString:pair[0]]) {
            NSLog(@"[ModrinthAPI] localized search keyword: '%@' -> '%@'", query, pair[1]);
            return pair[1];
        }
    }
    return query;
}

@implementation ModrinthAPI

@dynamic reachedLastPage, lastError;

/// 重写 baseURL getter，根据 PLMirrorCenter 的资源搜索（AssetSearch）策略
/// 动态返回官方或 MCIM 镜像 URL，这样所有使用 self.baseURL 的请求（搜索/版本列表/详情）都会自动走镜像
- (NSString *)baseURL {
    return [PLMirrorCenter modrinthAPIBaseURL];
}

+ (instancetype)sharedInstance {
    static ModrinthAPI *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

#pragma mark - Helper

- (BOOL)boolValueFromObject:(id)obj {
    if (obj == nil || obj == [NSNull null]) return NO;
    if ([obj isKindOfClass:[NSNumber class]]) return [(NSNumber *)obj boolValue];
    if ([obj isKindOfClass:[NSString class]]) return [(NSString *)obj boolValue];
    return NO;
}

#pragma mark - Sync Search (支持 projectType)

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters
                     previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;
    NSString *projectType = searchFilters[@"projectType"];
    if (projectType.length == 0) {
        // 防御性回退：未指定 projectType 但声明 isModpack 时按整合包搜索，避免误搜 Mod
        projectType = [searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod";
    }

    // 修复 #50: 必须把 loader（categories facet）传给 Modrinth API，否则筛选 neoforge/fabric 不生效
    // Modrinth 的 loader 类别：fabric / quilt / forge / neoforge / liteloader / rift 等
    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", projectType];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@", [\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    NSString *loader = searchFilters[@"loader"] ?: searchFilters[@"categories"];
    if (loader.length > 0) {
        [facetString appendFormat:@", [\"categories:%@\"]", loader];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"] ?: @"",
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) return nil;
    
    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1),
            @"isModpack": @(isModpack),
            @"projectType": hit[@"project_type"] ?: projectType,
            @"id": hit[@"project_id"] ?: hit[@"slug"] ?: @"",
            @"title": hit[@"title"] ?: @"",
            @"description": hit[@"description"] ?: @"",
            @"imageUrl": hit[@"icon_url"] ?: @"",
            @"author": hit[@"author"] ?: @"",
            @"downloads": hit[@"downloads"] ?: @0,
            @"likes": hit[@"follows"] ?: @0,
            @"categories": hit[@"categories"] ?: @[],
            @"lastUpdated": hit[@"date_modified"] ?: @""
        }.mutableCopy];
    }
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

#pragma mark - Sync Load Details (修复数组赋值)

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) return;

    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSString *> *sizes = [NSMutableArray new];
    NSMutableArray<NSString *> *fileNames = [NSMutableArray new];
    NSMutableArray<NSString *> *fileTypes = [NSMutableArray new];

    for (NSDictionary *version in response) {
        NSArray *files = version[@"files"];
        if (![files isKindOfClass:[NSArray class]] || files.count == 0) continue;
        NSDictionary *file = files.firstObject;

        [names addObject:version[@"name"] ?: @"Unknown"];
        NSArray *gameVersions = version[@"game_versions"];
        [mcNames addObject:ameMCVersionsDisplayString(gameVersions)];
        [urls addObject:file[@"url"] ?: @""];
        NSDictionary *hashesMap = file[@"hashes"];
        [hashes addObject:hashesMap[@"sha1"] ?: @""];
        [sizes addObject:file[@"size"] ?: @0];
        [fileNames addObject:file[@"filename"] ?: @""];
        [fileTypes addObject:version[@"version_type"] ?: @""];
    }

    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionFileNames"] = fileNames;
    item[@"versionFileTypes"] = fileTypes;
    item[@"versionDetailsLoaded"] = @(YES);
}

/// 异步加载整合包版本详情，避免 dispatch_group_wait 同步阻塞主线程/卡 UI
- (void)loadDetailsOfModAsync:(NSMutableDictionary *)item
                   completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    NSString *modID = item[@"id"];
    if (!modID || modID.length == 0) {
        if (completion) completion(NO, [NSError errorWithDomain:@"ModrinthAPIError" code:1
                                                       userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1238", nil)}]);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@/version", self.baseURL, modID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(NO, [NSError errorWithDomain:@"ModrinthAPIError" code:2
                                                       userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1048", nil)}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            self.lastError = error;
            if (completion) completion(NO, error);
            return;
        }
        if (!data) {
            NSError *err = [NSError errorWithDomain:@"ModrinthAPIError" code:3
                                           userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1239", nil)}];
            self.lastError = err;
            if (completion) completion(NO, err);
            return;
        }

        NSError *jsonError = nil;
        id jsonResult = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![jsonResult isKindOfClass:[NSArray class]]) {
            NSError *err = jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:4
                                                       userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_444", nil)}];
            self.lastError = err;
            if (completion) completion(NO, err);
            return;
        }

        NSMutableArray<NSString *> *names = [NSMutableArray new];
        NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
        NSMutableArray<NSString *> *urls = [NSMutableArray new];
        NSMutableArray<NSString *> *hashes = [NSMutableArray new];
        NSMutableArray<NSString *> *sizes = [NSMutableArray new];
        NSMutableArray<NSString *> *fileNames = [NSMutableArray new];
        NSMutableArray<NSString *> *fileTypes = [NSMutableArray new];

        for (NSDictionary *version in jsonResult) {
            NSArray *files = version[@"files"];
            if (![files isKindOfClass:[NSArray class]] || files.count == 0) continue;
            NSDictionary *file = files.firstObject;

            [names addObject:version[@"name"] ?: @"Unknown"];
            NSArray *gameVersions = version[@"game_versions"];
            [mcNames addObject:ameMCVersionsDisplayString(gameVersions)];
            [urls addObject:MRAMirrorResolvedURL(file[@"url"] ?: @"")];
            NSDictionary *hashesMap = file[@"hashes"];
            [hashes addObject:hashesMap[@"sha1"] ?: @""];
            [sizes addObject:file[@"size"] ?: @0];
            [fileNames addObject:file[@"filename"] ?: @""];
            [fileTypes addObject:version[@"version_type"] ?: @""];
        }

        item[@"versionNames"] = names;
        item[@"mcVersionNames"] = mcNames;
        item[@"versionSizes"] = sizes;
        item[@"versionUrls"] = urls;
        item[@"versionHashes"] = hashes;
        item[@"versionFileNames"] = fileNames;
        item[@"versionFileTypes"] = fileTypes;
        item[@"versionDetailsLoaded"] = @(YES);

        if (completion) completion(YES, nil);
    }];
    [task resume];
}

#pragma mark - 补充：ModpackAPI 协议方法（支持所有下载）

- (NSString *)downloadURLForFile:(NSDictionary *)file {
    if ([file isKindOfClass:[NSDictionary class]]) {
        NSString *url = file[@"url"];
        if ([url isKindOfClass:[NSString class]] && url.length > 0) {
            return MRAMirrorResolvedURL(url);
        }
    }
    return @"";
}

- (BOOL)file:(NSDictionary *)file matchesProjectType:(NSString *)projectType {
    if (![file isKindOfClass:[NSDictionary class]]) return NO;
    NSString *fileName = file[@"filename"] ?: file[@"fileName"] ?: @"";
    NSString *extension = fileName.pathExtension.lowercaseString;
    NSArray *extensions = [self preferredFileExtensionsForProjectType:projectType];
    return extensions.count == 0 || [extensions containsObject:extension];
}

- (NSArray<NSString *> *)preferredFileExtensionsForProjectType:(NSString *)projectType {
    if ([projectType isEqualToString:@"shader"] ||
        [projectType isEqualToString:@"resourcepack"] ||
        [projectType isEqualToString:@"datapack"] ||
        [projectType isEqualToString:@"modpack"] ||
        [projectType isEqualToString:@"world"]) {
        return @[@"zip"];
    }
    return @[@"jar"];
}

- (NSMutableDictionary *)projectForFileHash:(NSString *)sha1 projectType:(NSString *)projectType {
    if (sha1.length == 0) return nil;
    // 修复：Modrinth 文件反查 API 要求 hash 作为路径参数（GET /v2/version_file/{sha1}?algorithm=sha1）。
    // 原实现把 hash 放进 getEndpoint 的查询参数（生成 ?hash=xxx），该路由不存在，导致反查永远 404。
    // 参照本类 loadDetailsOfMod 中 project/%@/version 的写法，把 sha1 拼进 endpoint 路径，
    // algorithm=sha1 作为查询参数仍由 params 生成。
    NSString *endpoint = [NSString stringWithFormat:@"version_file/%@", sha1];
    NSDictionary *response = [self getEndpoint:endpoint params:@{@"algorithm": @"sha1"}];
    if (![response isKindOfClass:[NSDictionary class]]) return nil;
    
    NSMutableDictionary *result = [NSMutableDictionary new];
    result[@"id"] = response[@"project_id"] ?: @"";
    result[@"title"] = response[@"name"] ?: @"";
    result[@"projectType"] = projectType ?: @"mod";
    result[@"version"] = response[@"version_number"] ?: @"";
    result[@"fileName"] = response[@"filename"] ?: @"";
    result[@"downloadUrl"] = MRAMirrorResolvedURL([response[@"files"] firstObject][@"url"]) ?: @"";
    return result;
}

#pragma mark - Async Mod Search (推荐使用)

- (void)searchModWithFilters:(NSDictionary *)filters
                  completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion {
    NSString *projectType = filters[@"projectType"];
    if (projectType.length == 0) {
        // 防御性回退：未指定 projectType 但声明 isModpack 时按整合包搜索，避免误搜 Mod
        projectType = [filters[@"isModpack"] boolValue] ? @"modpack" : @"mod";
    }
    NSString *query = ameLocalizedSearchKeyword(filters[@"query"] ?: filters[@"name"] ?: @"");
    NSNumber *limitNum = filters[@"limit"] ?: @50;
    int limit = [limitNum intValue];
    NSNumber *offsetNum = filters[@"offset"] ?: @0;
    int offset = [offsetNum intValue];
    
    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", projectType];
    NSString *mcVersion = filters[@"mcVersion"] ?: filters[@"version"];
    if (mcVersion.length > 0) {
        [facetString appendFormat:@", [\"versions:%@\"]", mcVersion];
    }
    // 修复 #50: 必须把 loader（categories facet）传给 Modrinth API，否则筛选 neoforge/fabric 不生效
    NSString *loader = filters[@"loader"] ?: filters[@"categories"];
    if (loader.length > 0) {
        [facetString appendFormat:@", [\"categories:%@\"]", loader];
    }
    [facetString appendString:@"]"];
    
    NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedFacets = [facetString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *index = query.length > 0 ? @"relevance" : @"follows";
    // ★ [MODSRC-LIST] 路径+查询串（不含 baseURL），交由候选链逐个拼接官方/镜像基址。
    NSString *pathQuery = [NSString stringWithFormat:@"search?query=%@&limit=%d&offset=%d&facets=%@&index=%@",
                           encodedQuery, limit, offset, encodedFacets, index];

    // ★ [MODSRC-LIST] 候选链：官方 ↔ MCIM 镜像交叉回退；不再只打单一 self.baseURL。
    NSArray<NSString *> *candidates = [PLMirrorCenter modrinthAPIBaseURLCandidates];
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    [self mramFetchListPathQuery:pathQuery
                      candidates:candidates
                        arrayKey:@"hits"
                       mapObject:^NSDictionary * _Nullable(NSDictionary *item) {
        NSMutableDictionary *modData = [NSMutableDictionary dictionary];
        modData[@"apiSource"] = @(1);
        modData[@"isModpack"] = @([item[@"project_type"] isEqualToString:@"modpack"]);
        modData[@"projectType"] = item[@"project_type"] ?: projectType;
        modData[@"id"] = item[@"project_id"] ?: item[@"slug"] ?: @"";
        modData[@"title"] = item[@"title"] ?: @"Unknown";
        modData[@"description"] = item[@"description"] ?: @"";
        modData[@"author"] = item[@"author"] ?: @"Unknown";
        modData[@"downloads"] = item[@"downloads"] ?: @0;
        modData[@"likes"] = item[@"follows"] ?: @0;
        modData[@"imageUrl"] = item[@"icon_url"] ?: @"";
        modData[@"categories"] = item[@"categories"] ?: @[];
        modData[@"lastUpdated"] = item[@"date_modified"] ?: @"";
        return modData;
    }
                           index:0
                        failures:failures
                      completion:completion];
}

#pragma mark - ★ [MODSRC-LIST] 候选链列表请求实现

- (void)mramFetchListPathQuery:(NSString *)pathQuery
                    candidates:(NSArray<NSString *> *)candidates
                      arrayKey:(NSString *)arrayKey
                     mapObject:(NSDictionary * _Nullable (^)(NSDictionary *item))mapObject
                         index:(NSUInteger)index
                      failures:(NSMutableArray<NSString *> *)failures
                    completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion {
    if (index >= candidates.count) {
        NSLog(@"[ModrinthAPI] MODSRC-LIST: all sources failed: %@", failures);
        if (completion) completion(nil, MRAMListRequestError(failures));
        return;
    }
    NSString *base = candidates[index];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", base, pathQuery]];
    if (!url) {
        [failures addObject:[NSString stringWithFormat:@"%@ (URL 无效)", base]];
        [self mramFetchListPathQuery:pathQuery candidates:candidates arrayKey:arrayKey mapObject:mapObject
                               index:index + 1 failures:failures completion:completion];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 20.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSLog(@"[ModrinthAPI] MODSRC-LIST: try source[%lu/%lu] %@", (unsigned long)index + 1, (unsigned long)candidates.count, base);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSArray *mapped = nil;
        NSString *reason = nil;

        if (error) {
            reason = [NSString stringWithFormat:@"%@ HTTP=%ld 网络错误(%@)", base, (long)status, error.localizedDescription ?: @"?"];
        } else if (status != 0 && (status < 200 || status >= 300)) {
            // ★ [MODSRC-LIST] 旧实现不检查 HTTP 状态；镜像 5xx 的 JSON 错误体（无 hits）
            //   会被静默转成空数组 ⇒ 用户只看到「暂无」。现在按失败处理并切下一个源。
            reason = [NSString stringWithFormat:@"%@ HTTP=%ld", base, (long)status];
        } else {
            NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSArray *arr = [json isKindOfClass:[NSDictionary class]] ? json[arrayKey] : nil;
            if ([arr isKindOfClass:[NSArray class]]) {
                NSMutableArray *out = [NSMutableArray arrayWithCapacity:arr.count];
                for (NSDictionary *item in arr) {
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    NSDictionary *m = mapObject ? mapObject(item) : nil;
                    if (m) [out addObject:m];
                }
                mapped = out;
            } else {
                reason = [NSString stringWithFormat:@"%@ HTTP=%ld 响应缺少 %@ 数组", base, (long)status, arrayKey];
            }
        }

        if (mapped) {
            NSLog(@"[ModrinthAPI] MODSRC-LIST: source %@ OK (%lu items)", base, (unsigned long)mapped.count);
            if (completion) completion(mapped, nil);
            return;
        }
        [failures addObject:reason ?: [NSString stringWithFormat:@"%@ 未知错误", base]];
        [self mramFetchListPathQuery:pathQuery candidates:candidates arrayKey:arrayKey mapObject:mapObject
                               index:index + 1 failures:failures completion:completion];
    }];
    [task resume];
}

- (void)getVersionsForModWithID:(NSString *)modID
                     completion:(void (^)(NSArray<ModVersion *> * _Nullable, NSError * _Nullable))completion {
    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@/version", self.baseURL, modID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];
    
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (!data) { if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]); return; }
        
        NSError *jsonError = nil;
        id jsonResult = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![jsonResult isKindOfClass:[NSArray class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }
        
        NSMutableArray<ModVersion *> *versions = [NSMutableArray array];
        for (NSDictionary *dict in jsonResult) {
            ModVersion *version = [[ModVersion alloc] initWithDictionary:dict];
            if (version) [versions addObject:version];
        }
        if (completion) completion(versions, nil);
    }];
    [task resume];
}

#pragma mark - Shader Search (专用方法)

- (void)searchShaderWithFilters:(NSDictionary *)filters
                     completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSMutableDictionary *shaderFilters = [filters mutableCopy];
    shaderFilters[@"projectType"] = @"shader";
    [self searchModWithFilters:shaderFilters completion:completion];
}

- (void)getVersionsForShaderWithID:(NSString *)shaderID
                        completion:(void (^)(NSArray<ShaderVersion *> * _Nullable, NSError * _Nullable))completion {
    if (shaderID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid shader ID"}]);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@/version", self.baseURL, shaderID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (!data) { if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]); return; }

        NSError *jsonError = nil;
        id jsonResult = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![jsonResult isKindOfClass:[NSArray class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }

        NSMutableArray<ShaderVersion *> *versions = [NSMutableArray array];
        for (NSDictionary *dict in jsonResult) {
            ShaderVersion *version = [[ShaderVersion alloc] initWithDictionary:dict];
            if (version) [versions addObject:version];
        }
        if (completion) completion(versions, nil);
    }];
    [task resume];
}

#pragma mark - Server Projects 搜索

/// 内部工具：发起一次 server 或 modpack 的搜索请求
- (void)_searchServerWithProjectType:(NSString *)projectType
                              filters:(NSDictionary *)filters
                           completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSString *query = ameLocalizedSearchKeyword(filters[@"query"] ?: filters[@"name"] ?: @"");
    NSNumber *limitNum = filters[@"limit"] ?: @30;
    int limit = [limitNum intValue];
    NSNumber *offsetNum = filters[@"offset"] ?: @0;
    int offset = [offsetNum intValue];

    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", projectType];
    NSString *mcVersion = filters[@"mcVersion"] ?: filters[@"version"];
    if (mcVersion.length > 0) {
        [facetString appendFormat:@", [\"versions:%@\"]", mcVersion];
    }
    NSString *loader = filters[@"loader"] ?: filters[@"categories"];
    if (loader.length > 0) {
        [facetString appendFormat:@", [\"categories:%@\"]", loader];
    }
    [facetString appendString:@"]"];

    NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedFacets = [facetString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *index = query.length > 0 ? @"relevance" : @"follows";
    // ★ [MODSRC-LIST] 路径+查询串交由候选链（官方 ↔ 镜像交叉回退）。
    NSString *pathQuery = [NSString stringWithFormat:@"search?query=%@&limit=%d&offset=%d&facets=%@&index=%@",
                           encodedQuery, limit, offset, encodedFacets, index];

    NSArray<NSString *> *candidates = [PLMirrorCenter modrinthAPIBaseURLCandidates];
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    [self mramFetchListPathQuery:pathQuery
                      candidates:candidates
                        arrayKey:@"hits"
                       mapObject:^NSDictionary * _Nullable(NSDictionary *item) {
        NSMutableDictionary *serverData = [NSMutableDictionary dictionary];
        serverData[@"apiSource"] = @(1);
        serverData[@"projectType"] = item[@"project_type"] ?: projectType;
        serverData[@"serverID"] = item[@"project_id"] ?: item[@"slug"] ?: @"";
        serverData[@"title"] = item[@"title"] ?: @"Unknown";
        serverData[@"description"] = item[@"description"] ?: @"";
        serverData[@"author"] = item[@"author"] ?: @"Unknown";
        serverData[@"downloads"] = item[@"downloads"] ?: @0;
        serverData[@"likes"] = item[@"follows"] ?: @0;
        serverData[@"icon_url"] = item[@"icon_url"] ?: @"";
        serverData[@"page_url"] = item[@"page_url"] ?: @"";
        serverData[@"categories"] = item[@"categories"] ?: @[];
        serverData[@"date_modified"] = item[@"date_modified"] ?: @"";
        return serverData;
    }
                           index:0
                        failures:failures
                      completion:completion];
}

- (void)searchServersWithFilters:(NSDictionary *)filters
                      completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    // 优先使用 project_type=server（Modrinth Server Projects，2026 年新功能）
    __weak typeof(self) weakSelf = self;
    [self _searchServerWithProjectType:@"server" filters:filters completion:^(NSArray * _Nullable serverResults, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (error) {
            // server 类型 API 不可用，直接回退到 modpack 搜索
            NSLog(@"[ModrinthAPI] Server Projects search failed, falling back to modpack search: %@", error.localizedDescription);
            [strongSelf _searchServerWithProjectType:@"modpack" filters:filters completion:completion];
            return;
        }
        if (serverResults.count > 0) {
            if (completion) completion(serverResults, nil);
            return;
        }
        // server 类型结果为空，回退到 modpack 搜索（作为"服务器整合包"展示）
        NSLog(@"[ModrinthAPI] Server Projects result is empty, falling back to modpack search");
        [strongSelf _searchServerWithProjectType:@"modpack" filters:filters completion:completion];
    }];
}

- (void)getServerDetailsForID:(NSString *)serverID
                   completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    if (serverID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid server ID"}]);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@", self.baseURL, serverID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (!data) { if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]); return; }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }

        // 提取关键字段，统一字段命名以便 ServerItem.applyDetailData: 处理
        NSMutableDictionary *details = [NSMutableDictionary dictionary];
        details[@"serverID"] = json[@"id"] ?: json[@"slug"] ?: @"";
        details[@"title"] = json[@"title"] ?: @"";
        details[@"description"] = json[@"description"] ?: @"";
        details[@"projectType"] = json[@"project_type"] ?: @"server";
        details[@"icon_url"] = json[@"icon_url"] ?: @"";
        details[@"page_url"] = json[@"page_url"] ?: @"";
        details[@"downloads"] = json[@"downloads"] ?: @0;
        details[@"likes"] = json[@"followers"] ?: @0;
        details[@"date_modified"] = json[@"updated"] ?: @"";

        // Server Projects 详情可能直接包含 server_address 字段
        id addrObj = json[@"server_address"] ?: json[@"ip"] ?: json[@"address"];
        if ([addrObj isKindOfClass:[NSString class]]) {
            NSString *addr = (NSString *)addrObj;
            if (addr.length > 0) {
                details[@"serverAddress"] = addr;
            }
        }
        // 关联整合包 ID
        id mpIDObj = json[@"modpack_project_id"] ?: json[@"modpack_id"];
        if ([mpIDObj isKindOfClass:[NSString class]]) {
            NSString *mpID = (NSString *)mpIDObj;
            if (mpID.length > 0) {
                details[@"modpack_project_id"] = mpID;
            }
        }

        if (completion) completion(details, nil);
    }];
    [task resume];
}

// Task 5.10：在线整合包下载路径统一——zip 下载完成后由
// MinecraftResourceDownloadTask.importDownloadedModpackPackage:detail: 复用
// ModpackImportService 统一导入（解析/解压/依赖下载/加载器/游戏文件/profile），
// 此处不再维护 API 侧的整合包解包双轨逻辑。

@end