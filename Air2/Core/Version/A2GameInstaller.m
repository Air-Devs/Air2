//
//  A2GameInstaller.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#import "A2GameInstaller.h"
#import "A2MirrorResolver.h"
#import "A2BatchDownloader.h"
#import "A2Logger.h"
#import "A2VersionIsolation.h"
#import "A2ModLoaderInstaller.h"
#import "A2APIModDownloader.h"
#import "A2Log.h"
#import <stdarg.h>

/// 官方版本清单地址（Mojang piston-meta）
static NSString *const kVersionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
/// 依赖库与资源的下载根
static NSString *const kResourcesBaseURL = @"https://resources.download.minecraft.net";
/// 依赖库根
static NSString *const kLibrariesBaseURL = @"https://libraries.minecraft.net";

static NSString *const kUserAgent = @"Air-Devs/Air2/0.1.0 (github.com/Air-Devs/Air2)";

/// ★HEAD 预统计的限流参数★
///
/// 预统计只是为了「进度条第一秒就有分母」，不能为了它去打几千个 HEAD 抢掉
/// 真正下载要用的配额（服务器 429 就是这么来的）。所以：
///   · 同时最多 6 条
///   · 待探文件超过 200 个就整体放弃，边下边算
///   · 总预算 8 秒，到点就带着已探到的部分开工
///   · 单个失败只计数，不影响下载
static const NSInteger kHeadMaxConcurrent = 6;
static const NSInteger kHeadMaxRequests = 200;
static const NSTimeInterval kHeadRequestTimeout = 6.0;
static const NSTimeInterval kHeadTotalBudget = 8.0;

static void A2Main(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

@interface A2GameInstaller ()
@property (nonatomic, strong, nullable) A2BatchDownloader *activeDownloader;
/// 单文件下载（版本 json / 客户端 jar / 资源索引）的在途句柄 ——
/// 「取消安装」要能精确停掉这几条，而不是把 App 里所有下载一起 cancelAll。
@property (nonatomic, strong) NSMutableArray<A2DownloadOperation *> *activeSingleOps;
@property (nonatomic, strong, nullable) A2InstallRequest *request;
/// 原版基底的版本名。
///   原版安装 → 与 versionName 相同；
///   带加载器 → = mcVersion，因为加载器必须叠在原版之上，
///   而 A2ModLoaderInstaller 只认 versions/<mcVersion>/ 这一份原版。
@property (nonatomic, copy, nullable) NSString *baseVersionName;
/// 原版基底是否已完整存在，可跳过原版下载直接叠加加载器（复用，不删除）
@property (nonatomic, assign) BOOL reuseVanilla;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy, nullable) void (^progressBlock)(A2InstallStage, double, NSString *);
@property (nonatomic, copy, nullable) void (^completionBlock)(BOOL, NSError *);

// ---- 本单新增（实现见下方同名方法）----
- (void)fetchManifestFromCandidates:(NSArray<NSString *> *)candidates
                              index:(NSUInteger)index
                          lastError:(nullable NSError *)lastError;
- (nullable NSString *)bmclapiURLWithFormat:(NSString *)fmt, ...;
- (NSArray<NSString *> *)candidateListPrepending:(nullable NSString *)extra
                                              to:(NSArray<NSString *> *)base;
- (void)startBatchWithRequests:(NSArray<A2DownloadRequest *> *)requests
                         stage:(A2InstallStage)stage
                   messageBase:(NSString *)base
                maxConnections:(NSInteger)maxConnections
                       thenRun:(void (^)(NSError * _Nullable))then;
- (void)preflightMissingSizes:(NSArray<A2DownloadRequest *> *)requests
                   completion:(void (^)(void))completion;
@end

@implementation A2InstallRequest
@end

@implementation A2GameInstaller

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _activeSingleOps = [NSMutableArray array];
    _session = [NSURLSession sessionWithConfiguration:
                NSURLSessionConfiguration.defaultSessionConfiguration];
    return self;
}

- (void)cancel {
    _cancelled = YES;
    [A2Log log:@"installer: 取消安装 %@", self.request.versionName ?: @"(未知)"];

    // ★精确取消★
    //   之前这里调 [A2DownloadEngine cancelAll] —— 那会把 App 里
    //   其它页面正在跑的下载（模组 / 整合包 / 资源详情）一起杀掉。
    //   现在只停本安装流程发起的：批量下载器 + 几条单文件下载。
    [self.activeDownloader cancel];
    self.activeDownloader = nil;

    NSArray<A2DownloadOperation *> *ops = nil;
    @synchronized (self.activeSingleOps) {
        ops = [self.activeSingleOps copy];
        [self.activeSingleOps removeAllObjects];
    }
    for (A2DownloadOperation *op in ops) {
        [[A2DownloadEngine sharedClient] cancelOperation:op];
    }

    [A2Log log:@"[A2-DL] 取消安装：批量下载器已停，单文件 %lu 个已取消",
     (unsigned long)ops.count];
    [_session invalidateAndCancel];
}

#pragma mark - 主流程

- (void)install:(A2InstallRequest *)request
       progress:(void (^)(A2InstallStage, double, NSString *))progress
     completion:(void (^)(BOOL, NSError *))completion {

    self.request = request;
    self.progressBlock = progress;
    self.completionBlock = completion;
    self.cancelled = NO;

    if (!request.mcVersion.length || !request.gameHome.length) {
        [self failWithMessage:@"参数不完整"];
        return;
    }
    if (!request.versionName.length) {
        request.versionName = request.loaderType
            ? [NSString stringWithFormat:@"%@-%@", request.mcVersion,
               [A2ModLoaderAPI identifierForType:(A2ModLoaderType)request.loaderType.integerValue]]
            : request.mcVersion;
    }

    // 带加载器时，原版要落到 versions/<mcVersion>/（加载器叠在它之上）；
    // 纯原版时基底就是 versionName 自己。
    self.baseVersionName = request.loaderType ? request.mcVersion : request.versionName;
    self.reuseVanilla = request.loaderType ? [self vanillaInstalled:request.mcVersion] : NO;

    [A2Log log:@"installer: 开始安装 mc=%@ 版本名=%@ 加载器=%@ 基底=%@ 目录=%@",
          request.mcVersion, request.versionName,
          request.loaderType ?: @"原版", self.baseVersionName, request.gameHome];

    if (self.reuseVanilla) {
        [A2Log log:@"installer: 原版 %@ 已存在，跳过原版下载直接叠加加载器", request.mcVersion];
        [self skipVanillaStagesAndInstallLoader];
        return;
    }

    [self report:A2InstallStageFetchManifest progress:0 message:@"正在获取版本清单…"];
    [self fetchManifest];
}

/// 原版是否已完整存在（版本 json + 客户端 jar 都齐）。
///
/// 加载器要硬链接原版 jar 并读原版 json 合并，缺任何一份都叠不起来，
/// 所以两个都查；只有都齐才算「可复用」。
- (BOOL)vanillaInstalled:(NSString *)mcVersion {
    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    NSFileManager *fm = NSFileManager.defaultManager;
    return [fm fileExistsAtPath:[path versionJSONPath:mcVersion]]
        && [fm fileExistsAtPath:[path versionJarPath:mcVersion]];
}

/// 原版已就绪：不做任何原版下载，把原版各阶段直接标记为「已复用」，
/// 随即进入加载器安装。
///
/// 这里绝不删除或覆盖已有原版 —— 加载器版 json 会通过 inheritsFrom
/// 引用原版，原版删了加载器版也起不来。
- (void)skipVanillaStagesAndInstallLoader {
    NSString *reuseMessage = [NSString stringWithFormat:@"已有原版 %@，跳过下载", self.request.mcVersion];
    for (A2InstallStage stage = A2InstallStageFetchManifest;
         stage <= A2InstallStageDownloadAssets; stage++) {
        [self report:stage progress:1 message:reuseMessage];
    }
    [self installLoaderIfNeeded];
}

- (void)fetchManifest {
    // 版本清单也走镜像 —— 国内直连 piston-meta 很慢，
    // 这一步是安装的第一个请求，卡在这里最影响观感。
    //
    // ★必须整条候选链依次试★
    //   之前只取 candidateURLs 的 firstObject：一旦镜像挂了/被限流，
    //   整个安装直接失败（官方源就在列表里，却完全没用上）。
    NSArray<NSString *> *candidates =
        [[A2MirrorResolver shared] candidateURLsForURL:kVersionManifestURL];
    if (candidates.count == 0) candidates = @[kVersionManifestURL];
    [self fetchManifestFromCandidates:candidates index:0 lastError:nil];
}

- (void)fetchManifestFromCandidates:(NSArray<NSString *> *)candidates
                              index:(NSUInteger)index
                          lastError:(nullable NSError *)lastError {
    if (self.cancelled) return;
    if (index >= candidates.count) {
        [self failWithError:lastError ?: [NSError errorWithDomain:@"A2Installer" code:1
                                                        userInfo:@{
            NSLocalizedDescriptionKey: @"获取版本清单失败（所有来源都不可用）"}]];
        return;
    }

    NSString *urlString = candidates[index];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                               [NSURL URLWithString:urlString]];
    req.timeoutInterval = 30;
    [req setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];

    [A2Log log:@"[A2-DL] 版本清单候选 %lu/%lu：%@",
     (unsigned long)(index + 1), (unsigned long)candidates.count,
     [NSURL URLWithString:urlString].host ?: urlString];

    NSURLSessionDataTask *t = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (self.cancelled) return;

        NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSDictionary *json = (error == nil && data.length > 0)
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;

        if (error || !([json isKindOfClass:NSDictionary.class])) {
            NSError *e = error ?: [NSError errorWithDomain:@"A2Installer" code:2
                                                 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"版本清单来源不可用（HTTP %ld）", (long)code]}];
            [A2Log log:@"[A2-DL] 版本清单候选失败 %@：%@（换下一个）",
             [NSURL URLWithString:urlString].host ?: urlString,
             e.localizedDescription];
            [self fetchManifestFromCandidates:candidates index:index + 1 lastError:e];
            return;
        }

        // 找到目标版本的清单 URL —— 同时取出 sha1 与 size 做完整性校验。
        // 版本 JSON 里给了 sha1，之前没传，等于放弃了这一层的校验。
        NSArray *versions = json[@"versions"];
        NSString *url = nil;
        NSString *sha1 = nil;
        NSNumber *size = nil;
        for (NSDictionary *v in versions) {
            if ([v[@"id"] isEqualToString:self.request.mcVersion]) {
                url = v[@"url"];
                sha1 = v[@"sha1"];
                size = v[@"size"];
                break;
            }
        }
        if (!url.length) {
            [self failWithMessage:[NSString stringWithFormat:
                                   @"未找到版本 %@", self.request.mcVersion]];
            return;
        }

        [self report:A2InstallStageFetchManifest progress:1 message:@"版本清单已获取"];
        [self report:A2InstallStageDownloadJSON progress:0 message:@"正在下载版本信息…"];
        [self downloadVersionJSON:url sha1:sha1 size:size];
    }];
    [t resume];
}

- (void)downloadVersionJSON:(NSString *)url sha1:(NSString *)sha1 size:(NSNumber *)size {
    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    // 原版一律落到基底版本目录：带加载器时是 versions/<mcVersion>/，
    // 加载器后面会读它、并把它的 jar 硬链到自己的版本目录。
    NSString *dest = [path versionJSONPath:self.baseVersionName];

    // BMCLAPI 的「版本 json」是按版本号给的端点，路径结构跟 piston-meta
    // 的 /v1/packages/<sha1>/<ver>.json 完全不同 —— 必须显式构造候选，
    // 不能只靠前缀映射（否则映射出来的是 404）。
    NSString *bmcl = [self bmclapiURLWithFormat:@"/version/%@/json", self.request.mcVersion];

    [self download:[self candidateListPrepending:bmcl to:@[url]]
                to:dest
        stageLabel:A2InstallStageDownloadJSON
           message:@"正在下载版本信息"
              sha1:sha1
              size:size
           thenRun:^(NSError *error) {
        if (error) { [self failWithError:error]; return; }
        [self afterVersionJSON:dest];
    }];
}

/// 构造 BMCLAPI 端点（关掉镜像 / 不在国内 / 没有版本号时返回 nil）
- (nullable NSString *)bmclapiURLWithFormat:(NSString *)fmt, ... {
    A2MirrorResolver *mirror = [A2MirrorResolver shared];
    if (!mirror.enabled || ![A2MirrorResolver isChinaMainland]) return nil;
    va_list args;
    va_start(args, fmt);
    NSString *path = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    if (path.length == 0) return nil;
    return [@"https://bmclapi2.bangbang93.com" stringByAppendingString:path];
}

/// 把镜像端点插到候选链的最前（官方优先设置时放到最后），并去重。
- (NSArray<NSString *> *)candidateListPrepending:(nullable NSString *)extra
                                              to:(NSArray<NSString *> *)base {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    BOOL mirrorFirst = ([A2MirrorResolver shared].priority == A2MirrorPriorityMirrorFirst);
    if (extra.length > 0 && mirrorFirst) [out addObject:extra];
    for (NSString *u in base) {
        if (u.length == 0 || [out containsObject:u]) continue;
        [out addObject:u];
    }
    if (extra.length > 0 && !mirrorFirst && ![out containsObject:extra]) [out addObject:extra];
    return out;
}

/// 版本 json 到手后，解析出 jar / libraries / assets 的下载清单
- (void)afterVersionJSON:(NSString *)jsonPath {
    NSData *data = [NSData dataWithContentsOfFile:jsonPath];
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:NSDictionary.class]) {
        [self failWithMessage:@"版本信息解析失败"];
        return;
    }

    // 客户端 jar 的下载地址
    NSDictionary *downloads = json[@"downloads"];
    NSDictionary *client = downloads[@"client"];
    NSString *jarURL = client[@"url"];

    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    NSString *jarDest = [path versionJarPath:self.baseVersionName];

    if (!jarURL.length) {
        [self failWithMessage:@"版本信息里没有客户端下载地址"];
        return;
    }

    // 客户端 jar 也带完整性字段 —— MC 版本 json 里 downloads.client
    // 就给了 sha1 与 size，直接透传。
    NSString *jarSHA1 = client[@"sha1"];
    NSNumber *jarSize = client[@"size"];

    // 官方地址是 piston-data 的 /v1/objects/<sha1>/client.jar；
    // BMCLAPI 对应的是按版本号给的 /version/<ver>/client。
    NSString *bmclJar = [self bmclapiURLWithFormat:@"/version/%@/client", self.request.mcVersion];

    [self report:A2InstallStageDownloadJar progress:0 message:@"正在下载客户端…"];
    [self download:[self candidateListPrepending:bmclJar to:@[jarURL]]
                to:jarDest stageLabel:A2InstallStageDownloadJar
           message:@"正在下载客户端" sha1:jarSHA1 size:jarSize
           thenRun:^(NSError *error) {
        if (error) { [self failWithError:error]; return; }
        [self installLibrariesFromJSON:json];
    }];
}

/// 依赖库：逐个下载，跳过已存在的
- (void)installLibrariesFromJSON:(NSDictionary *)json {
    NSArray *libraries = json[@"libraries"];
    if (![libraries isKindOfClass:NSArray.class] || libraries.count == 0) {
        [self installAssetsFromJSON:json];
        return;
    }

    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    NSString *libRoot = [path librariesHome];

    NSMutableArray<NSArray<NSString *> *> *pending = [NSMutableArray array];
    for (NSDictionary *lib in libraries) {
        if (![lib isKindOfClass:NSDictionary.class]) continue;

        // 检查规则：allow/disallow（区分操作系统）
        if (![self isLibraryAllowed:lib]) continue;

        NSDictionary *artifacts = lib[@"downloads"];
        NSDictionary *artifact = artifacts[@"artifact"];
        if (![artifact isKindOfClass:NSDictionary.class]) continue;

        NSString *relPath = artifact[@"path"];
        NSString *url = artifact[@"url"];
        if (!relPath.length || !url.length) continue;

        NSString *dest = [libRoot stringByAppendingPathComponent:relPath];

        // ⚠️ 不要在这里用 fileExistsAtPath: 跳过！
        //
        // 之前就是「文件存在就跳过」—— 大小对、内容是坏的（镜像给错区间、
        // 续传拼错）也照样通过，最后在启动时报 NoClassDefFoundError，
        // 用户完全看不出是下载问题。
        //
        // 正确做法（对照 ZL2）：把 sha1 交给下载引擎，由它在【开始前】
        // 校验本地文件 —— 一致就跳过（省掉整个下载），不一致就重下。
        NSString *sha1 = artifact[@"sha1"];
        NSNumber *size = artifact[@"size"];

        [pending addObject:@[url, dest, sha1 ?: @"", size ?: @0]];
    }

    if (pending.count == 0) {
        [self report:A2InstallStageDownloadLibraries progress:1 message:@"依赖库已完整"];
        [self installAssetsFromJSON:json];
        return;
    }

    [self downloadBatch:pending
                  stage:A2InstallStageDownloadLibraries
            messageBase:@"正在下载依赖库"
               thenRun:^(NSError *error) {
        if (error) { [self failWithError:error]; return; }
        [self installAssetsFromJSON:json];
    }];
}

/// 检查依赖库在当前系统上是否适用
- (BOOL)isLibraryAllowed:(NSDictionary *)lib {
    NSArray *rules = lib[@"rules"];
    if (![rules isKindOfClass:NSArray.class] || rules.count == 0) return YES;

    // 默认不允许，遇到匹配的 allow 才通过
    BOOL allowed = NO;
    for (NSDictionary *rule in rules) {
        if (![rule isKindOfClass:NSDictionary.class]) continue;
        NSString *action = rule[@"action"];
        NSDictionary *os = rule[@"os"];
        BOOL matches = YES;

        if ([os isKindOfClass:NSDictionary.class]) {
            NSString *osName = os[@"name"];
            // iOS 上按 macOS 处理（原生库大多通用），部分库有 ios 专属条目
            if ([osName isEqualToString:@"windows"] ||
                [osName isEqualToString:@"linux"]) {
                matches = NO;
            } else if ([osName isEqualToString:@"osx"] ||
                       [osName isEqualToString:@"macos"] ||
                       [osName isEqualToString:@"ios"]) {
                matches = YES;
            } else {
                matches = NO;
            }
        }

        if (matches) {
            allowed = [action isEqualToString:@"allow"];
        }
    }
    return allowed;
}

/// 资源文件（assets）
- (void)installAssetsFromJSON:(NSDictionary *)json {
    NSDictionary *assetIndex = json[@"assetIndex"];
    NSString *indexURL = assetIndex[@"url"];

    if (!indexURL.length) {
        [self report:A2InstallStageDownloadAssets progress:1 message:@"无需下载资源"];
        [self installLoaderIfNeeded];
        return;
    }

    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    NSString *assetsRoot = [path assetsHome];
    NSString *indexesDir = [assetsRoot stringByAppendingPathComponent:@"indexes"];
    [NSFileManager.defaultManager createDirectoryAtPath:indexesDir
                            withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *indexID = assetIndex[@"id"] ?: @"legacy";
    NSString *indexPath = [indexesDir stringByAppendingPathComponent:
                           [indexID stringByAppendingPathExtension:@"json"]];

    [self report:A2InstallStageDownloadAssets progress:0 message:@"正在下载资源索引…"];
    // 资源索引同样带 sha1 与 size（MC 的版本 json 里 assetIndex 字段）。
    // BMCLAPI 的资源索引路径是 /assets/indexes/<id>.json —— 放在官方之后兜底，
    // 探测失败只多一次 4xx，不影响安装。
    NSString *bmclIndex = [self bmclapiURLWithFormat:@"/assets/indexes/%@.json", indexID];
    [self download:[self candidateListPrepending:bmclIndex to:@[indexURL]]
                to:indexPath stageLabel:A2InstallStageDownloadAssets
           message:@"正在下载资源索引"
              sha1:assetIndex[@"sha1"]
              size:assetIndex[@"size"]
           thenRun:^(NSError *error) {
        if (error) { [self failWithError:error]; return; }
        [self downloadAssetObjects:indexPath assetsRoot:assetsRoot];
    }];
}

/// 按索引逐个下载资源对象。
/// 注意：数千个文件，这里只下必要的一批（音效/语言/字体），
/// 材质与模型在启动时按需下载，避免安装阶段过久。
- (void)downloadAssetObjects:(NSString *)indexPath assetsRoot:(NSString *)assetsRoot {
    NSData *data = [NSData dataWithContentsOfFile:indexPath];
    NSDictionary *index = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *objects = index[@"objects"];

    if (![objects isKindOfClass:NSDictionary.class] || objects.count == 0) {
        [self report:A2InstallStageDownloadAssets progress:1 message:@"资源已就绪"];
        [self installLoaderIfNeeded];
        return;
    }

    NSString *objectsRoot = [assetsRoot stringByAppendingPathComponent:@"objects"];
    NSMutableArray<NSArray<NSString *> *> *pending = [NSMutableArray array];

    for (NSString *key in objects) {
        NSDictionary *obj = objects[key];
        NSString *hash = obj[@"hash"];
        if (hash.length < 2) continue;

        // 对象按 hash 前两位分目录存
        NSString *sub = [hash substringToIndex:2];
        NSString *dir = [objectsRoot stringByAppendingPathComponent:sub];
        NSString *dest = [dir stringByAppendingPathComponent:hash];

        // 不在这里判存在 —— 交给下载引擎按 SHA1 校验。
        // 资源文件的 hash 字段【就是】它的 SHA1（MC 资源索引的定义），
        // 只判存在会漏掉损坏的纹理/音效/语言文件。
        NSString *url = [NSString stringWithFormat:@"%@/%@/%@",
                         kResourcesBaseURL, sub, hash];
        NSNumber *size = obj[@"size"];
        [pending addObject:@[url, dest, hash, size ?: @0]];
    }

    if (pending.count == 0) {
        [self report:A2InstallStageDownloadAssets progress:1 message:@"资源已完整"];
        [self installLoaderIfNeeded];
        return;
    }

    [self downloadBatch:pending
                  stage:A2InstallStageDownloadAssets
            messageBase:[NSString stringWithFormat:@"正在下载资源（%lu 个文件）",
                         (unsigned long)pending.count]
               thenRun:^(NSError *error) {
        if (error) { [self failWithError:error]; return; }
        [self installLoaderIfNeeded];
    }];
}

#pragma mark - 加载器

- (void)installLoaderIfNeeded {
    if (!self.request.loaderType) {
        // 没有加载器时 API 模组无法工作 —— 直接跳过并收尾
        [self endInstallation];
        return;
    }

    A2ModLoaderType type = (A2ModLoaderType)self.request.loaderType.integerValue;

    // 不支持自动安装的加载器直接拒绝，不假装成功
    if (![A2ModLoaderInstaller supportsAutoInstall:type]) {
        [self failWithMessage:[NSString stringWithFormat:
            @"%@ 不支持自动安装，请手动下载安装包后放入 versions 目录",
            [A2ModLoaderAPI displayNameForType:type]]];
        return;
    }

    [self report:A2InstallStageInstallLoader progress:0
         message:[NSString stringWithFormat:@"正在准备 %@…",
                  [A2ModLoaderAPI displayNameForType:type]]];

    __weak typeof(self) weakSelf = self;
    [[A2ModLoaderAPI shared] versionsForLoader:type
                                     mcVersion:self.request.mcVersion
                                    completion:^(NSArray<A2ModLoaderVersion *> *versions,
                                                 NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self.cancelled) return;
        if (error) { [self failWithError:error]; return; }

        if (versions.count == 0) {
            [self failWithMessage:[NSString stringWithFormat:
                @"%@ 不支持游戏版本 %@",
                [A2ModLoaderAPI displayNameForType:type], self.request.mcVersion]];
            return;
        }

        // 选定版本：用户指定优先，否则取第一个稳定版
        A2ModLoaderVersion *chosen = nil;
        if (self.request.loaderVersion.length) {
            for (A2ModLoaderVersion *v in versions) {
                if ([v.version isEqualToString:self.request.loaderVersion]) { chosen = v; break; }
            }
        }
        if (!chosen) {
            for (A2ModLoaderVersion *v in versions) {
                if (v.stable) { chosen = v; break; }
            }
        }
        if (!chosen) chosen = versions.firstObject;

        [self report:A2InstallStageInstallLoader progress:0.1
             message:[NSString stringWithFormat:@"正在安装 %@…", chosen.displayName]];

        // 真正执行安装
        A2ModLoaderInstaller *installer = [[A2ModLoaderInstaller alloc] init];
        [installer installLoader:chosen
                       mcVersion:self.request.mcVersion
                     versionName:self.request.versionName
                        gameHome:self.request.gameHome
                        progress:^(double p, NSString *message) {
            // 把加载器安装的进度映射到本阶段
            [self report:A2InstallStageInstallLoader progress:p message:message];
        }
                      completion:^(BOOL success, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (self.cancelled) return;
            if (!success) { [self failWithError:error]; return; }
            [self installAPIModIfNeeded];
        }];
    }];
}

/// 安装前置模组（Fabric API 等）。
///
/// 对照 ZL2：API 模组是独立的下载项 —— 它本质上是个普通模组，
/// 只是几乎所有模组都依赖它，所以值得在界面上单列、在流程里必装。
/// 它落在版本的 mods 目录下，不走加载器那套版本 json 合并。
- (void)installAPIModIfNeeded {
    if (!self.request.apiModType) {
        [self endInstallation];
        return;
    }

    A2ModLoaderType apiType = (A2ModLoaderType)self.request.apiModType.integerValue;
    NSString *apiName = [A2ModLoaderAPI displayNameForType:apiType];

    [self report:A2InstallStageInstallLoader progress:0
         message:[NSString stringWithFormat:@"正在获取 %@…", apiName]];

    __weak typeof(self) weakSelf = self;
    [[A2ModLoaderAPI shared] versionsForLoader:apiType
                                     mcVersion:self.request.mcVersion
                                    completion:^(NSArray<A2ModLoaderVersion *> *versions,
                                                 NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;
        if (error || versions.count == 0) {
            // API 模组失败不阻断整个安装 —— 用户仍可手动补装
            [A2Logger warning:@"GameInstaller"
                   message:[NSString stringWithFormat:
                            @"%@ 获取失败，跳过（不影响游戏本体）", apiName]];
            [self report:A2InstallStageInstallLoader progress:1
                 message:[NSString stringWithFormat:@"%@ 获取失败，已跳过", apiName]];
            [self endInstallation];
            return;
        }

        // 选定版本
        A2ModLoaderVersion *chosen = versions.firstObject;
        if (self.request.apiModVersion.length) {
            for (A2ModLoaderVersion *v in versions) {
                if ([v.version isEqualToString:self.request.apiModVersion]) { chosen = v; break; }
            }
        }

        [A2Logger info:@"GameInstaller"
               message:[NSString stringWithFormat:@"%@ 选定版本 %@", apiName, chosen.version]];

        // 真的下载并装到版本的 mods 目录
        [[A2APIModDownloader shared]
            installAPIType:apiType
                 mcVersion:self.request.mcVersion
               versionName:self.request.versionName
                  gameHome:self.request.gameHome
          preferredVersion:chosen.version
                  progress:^(double p, NSString *msg) {
            [self report:A2InstallStageInstallLoader progress:p message:msg];
        }
                completion:^(BOOL success, NSError *apiError) {
            // 失败不阻断 —— 用户仍可手动补装，游戏本体已经装好了
            if (!success) {
                [A2Logger warning:@"GameInstaller"
                       message:[NSString stringWithFormat:@"%@ 安装失败：%@（不影响游戏本体）",
                                apiName, apiError.localizedDescription ?: @""]];
            }
            [self endInstallation];
        }];
    }];
}

/// 把 API 模组的选择写进版本配置，供后续补装
- (void)recordAPIModSelection:(A2ModLoaderType)type version:(NSString *)version {
    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    NSString *dir = [path launcherDataPath:self.request.versionName];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];

    NSDictionary *info = @{
        @"apiModType": [A2ModLoaderAPI identifierForType:type],
        @"apiModVersion": version,
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:info
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    NSString *dest = [dir stringByAppendingPathComponent:@"api_mod.json"];
    [data writeToFile:dest atomically:YES];
}

#pragma mark - 收尾

- (void)endInstallation {
    [self report:A2InstallStageFinalize progress:0 message:@"正在收尾…"];

    // 写入版本配置（含隔离的初始值：跟随全局）
    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    NSString *dir = [path launcherDataPath:self.request.versionName];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *configPath = [dir stringByAppendingPathComponent:@"config.json"];
    if (![NSFileManager.defaultManager fileExistsAtPath:configPath]) {
        A2VersionIsolation *iso = [A2VersionIsolation new];
        NSData *d = [NSJSONSerialization dataWithJSONObject:[iso toDictionary]
                                                    options:NSJSONWritingPrettyPrinted error:nil];
        [d writeToFile:configPath atomically:YES];
    }

    [self report:A2InstallStageFinalize progress:1 message:@"安装完成"];
    [A2Log log:@"installer: 安装完成 %@", self.request.versionName];
    if (self.completionBlock) self.completionBlock(YES, nil);
}

#pragma mark - 下载辅助

/// 单文件下载（带校验、断点、镜像）
- (void)download:(NSArray<NSString *> *)urls
              to:(NSString *)dest
      stageLabel:(A2InstallStage)stage
         message:(NSString *)message
            sha1:(nullable NSString *)sha1
            size:(nullable NSNumber *)size
         thenRun:(void (^)(NSError * _Nullable))then {

    // 同样展开镜像候选
    A2MirrorResolver *mirror = [A2MirrorResolver shared];
    urls = [mirror candidateURLsForURLs:urls];

    if (self.cancelled) return;

    A2DownloadRequest *req = [A2DownloadRequest new];
    NSMutableArray<NSURL *> *list = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *u in urls) {
        if (u.length == 0 || [seen containsObject:u]) continue;
        NSURL *url = [NSURL URLWithString:u];
        if (!url) continue;
        [seen addObject:u];
        [list addObject:url];
    }
    req.candidateURLs = list;
    req.destinationPath = dest;
    req.allowZipFallbackCheck = YES;

    // 完整性字段。引擎会在两处用它们：
    //   1. 开始前：本地已有且 SHA1 一致 → 直接跳过（不重下）
    //   2. 完成后：SHA1 不符 → 丢弃半成品、换源重试
    if (sha1.length) req.expectedSHA1 = sha1;
    if (size) req.expectedSize = size.longLongValue;

    [A2Log log:@"[A2-DL] 单文件 %@ 候选=%lu（首个 %@）sha1=%@ 期望=%lldB",
     dest.lastPathComponent, (unsigned long)list.count,
     list.firstObject.host ?: @"?", sha1.length ? @"有" : @"无",
     (long long)req.expectedSize];

    __weak typeof(self) weakSelf = self;
    __block int64_t acc = 0;
    A2DownloadOperation *op = [[A2DownloadEngine sharedClient] startRequest:req
        progress:^(int64_t delta, int64_t total) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled || total <= 0) return;
        acc += delta;
        if (acc < 0) acc = 0;
        double p = MIN(1.0, (double)acc / (double)total);
        [self report:stage progress:p message:message];
    }
        speed:nil
        completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;
        if (then) then(success ? nil : error);
    }];

    if (op) {
        @synchronized (self.activeSingleOps) { [self.activeSingleOps addObject:op]; }
    }
}

/// 批量下载（逐个串行，避免并发过高被限流）
/// 批量下载 —— **并发**，不是逐个串行。
///
/// 之前的实现是「下完一个再下一个」，几百个依赖库要几分钟。
/// ZL2 用 64 个并发（BatchDownloader.DEFAULT_MAX_CONNECTIONS），
/// 现在改用 A2BatchDownloader。
///
/// 为什么之前会慢：一个文件 100KB，串行下载意味着每次都要
/// 完整走一遍 TCP 握手 + TLS 协商 + 首字节等待。并发能把这些
/// 延迟重叠起来。
- (void)downloadBatch:(NSArray<NSArray<NSString *> *> *)items
                stage:(A2InstallStage)stage
          messageBase:(NSString *)base
             thenRun:(void (^)(NSError * _Nullable))then {

    if (items.count == 0) {
        if (then) then(nil);
        return;
    }

    // 组请求 —— 每个 URL 都展开镜像候选
    //
    // 这一步很关键：之前直接拿官方 URL 下载，国内用户
    // 每个文件都要等 piston-data / libraries.minecraft.net 的响应，
    // 几百个库就慢得离谱。BMCLAPI 镜像能把延迟从几百毫秒降到几十毫秒。
    NSMutableArray<A2DownloadRequest *> *requests = [NSMutableArray array];
    A2MirrorResolver *mirror = [A2MirrorResolver shared];

    for (NSArray<NSString *> *pair in items) {
        if (pair.count < 2) continue;

        NSArray<NSString *> *candidates = [mirror candidateURLsForURL:pair[0]];
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        for (NSString *u in candidates) {
            NSURL *url = [NSURL URLWithString:u];
            if (url) [urls addObject:url];
        }
        if (urls.count == 0) continue;

        A2DownloadRequest *req = [A2DownloadRequest new];
        req.candidateURLs = urls;
        req.destinationPath = pair[1];
        req.allowZipFallbackCheck = YES;

        // 完整性字段：[url, dest, sha1, size]
        //
        // 交给引擎做两件事（对照 ZL2 的 scheduleDownload(urls, hash, file, size)）：
        //   1. 开始前：本地文件 SHA1 一致 → 直接跳过（重装会非常快）
        //   2. 完成后：SHA1 不一致 → 丢弃、换源重试
        if (pair.count >= 3 && [pair[2] length] > 0) {
            req.expectedSHA1 = pair[2];
        }
        if (pair.count >= 4) {
            req.expectedSize = [pair[3] longLongValue];
        }

        [requests addObject:req];
    }

    if (requests.count == 0) {
        if (then) then(nil);
        return;
    }

    // ★判据行★ 镜像候选链是否真的铺开了（每个文件独立 fallback）
    {
        NSUInteger multi = 0, withSHA1 = 0, withSize = 0;
        for (A2DownloadRequest *r in requests) {
            if (r.candidateURLs.count > 1) multi++;
            if (r.expectedSHA1.length > 0) withSHA1++;
            if (r.expectedSize > 0) withSize++;
        }
        [A2Log log:@"[A2-DL] 批量 %lu 个文件：多候选 %lu，带 sha1 %lu，带 size %lu（镜像启用=%d 国内=%d 优先=%d）",
         (unsigned long)requests.count, (unsigned long)multi,
         (unsigned long)withSHA1, (unsigned long)withSize,
         mirror.enabled ? 1 : 0, [A2MirrorResolver isChinaMainland] ? 1 : 0,
         (int)mirror.priority];
    }

    // 并发数可配置 —— 默认 64，与 ZL2 的 DEFAULT_MAX_CONNECTIONS 一致。
    //
    // 我之前降到 16 是错的 —— ZL2 用 64 跑得很稳，说明瓶颈不在并发数。
    // 真正的问题是【超时太长】（30/60s 让坏连接占满槽位），
    // 那个已经改成 10s 了。
    NSInteger configured = [NSUserDefaults.standardUserDefaults
                            integerForKey:@"A2MaxConnections"];
    NSInteger kMaxConnections = (configured > 0) ? MIN(configured, 128) : 64;

    // ★先补总量，再开工★（有上限的 HEAD 预统计，见 preflightMissingSizes）
    //
    // 只探「清单里没给 size」的那几个。MC 的 version json / asset index
    // 本来就带 size，正常情况下这一步一个请求都不发。
    __weak typeof(self) weakSelf = self;
    [self preflightMissingSizes:requests completion:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;
        [self startBatchWithRequests:requests
                               stage:stage
                          messageBase:base
                       maxConnections:kMaxConnections
                             thenRun:then];
    }];
}

/// 真正发起批量下载（预统计完成之后）。
- (void)startBatchWithRequests:(NSArray<A2DownloadRequest *> *)requests
                         stage:(A2InstallStage)stage
                   messageBase:(NSString *)base
                maxConnections:(NSInteger)kMaxConnections
                       thenRun:(void (^)(NSError * _Nullable))then {

    if (self.cancelled) return;

    // ⚠️ 必须用属性持有：批量下载器是异步的，
    // 用局部变量的话 downloadBatch: 一返回 ARC 就释放它，
    // 下载会在启动瞬间静默死掉（表现就是「0/80」永远不动）。
    // 这已经是我第二次踩同一个坑（上次是 A2GameInstaller 自己）。
    self.activeDownloader = [[A2BatchDownloader alloc] initWithRequests:requests
                                                        maxConnections:kMaxConnections
                                                           retryRounds:1];
    A2BatchDownloader *downloader = self.activeDownloader;

    __weak typeof(self) weakSelf = self;

    downloader.onProgress = ^(A2BatchProgress *progress) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;

        NSString *msg = [NSString stringWithFormat:@"%@ (%ld/%ld)",
                         base,
                         (long)progress.downloadedFiles,
                         (long)progress.totalFiles];
        if (progress.speedBytesPerSec > 0) {
            msg = [msg stringByAppendingFormat:@" · %@",
                   [self formatSpeed:progress.speedBytesPerSec]];
        }
        [self report:stage progress:progress.fraction message:msg];
    };

    downloader.onCompletion = ^(BOOL success, NSDictionary<NSString *, NSError *> *failures) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.activeDownloader = nil;   // 完成后释放
        if (self.cancelled) return;

        if (failures.count > 0) {
            [A2Log log:@"[A2-DL] %@ 完成，%lu 个文件失败", base, (unsigned long)failures.count];
        }
        // 单文件失败不阻断 —— 依赖库里有可选组件，缺几个不影响启动
        if (then) then(nil);
    };

    [downloader start];
}

#pragma mark - 总大小预统计（有上限的 HEAD）

/// 给「清单里没有 size」的文件补大小。
///
/// 对照 ZL2 的 DownloadStats：总量来自清单元数据，不靠 HEAD 探。
/// 我们这里也以清单为准 —— 只有 size 缺失时才会发 HEAD，而且：
///   · 并发 ≤ kHeadMaxConcurrent(6)，不是几千个一起打
///   · 待探数 > kHeadMaxRequests(200) 直接放弃（边下边算）
///   · 总预算 kHeadTotalBudget(8s)，到点开工
///   · 失败只计数，不影响下载（分母有兜底，见 publishProgress）
- (void)preflightMissingSizes:(NSArray<A2DownloadRequest *> *)requests
                   completion:(void (^)(void))completion {

    NSMutableArray<A2DownloadRequest *> *unknown = [NSMutableArray array];
    for (A2DownloadRequest *req in requests) {
        if (req.expectedSize <= 0) [unknown addObject:req];
    }

    if (unknown.count == 0 || unknown.count > (NSUInteger)kHeadMaxRequests || self.cancelled) {
        if (unknown.count > (NSUInteger)kHeadMaxRequests) {
            [A2Log log:@"[A2-DL] 预统计跳过：%lu 个文件缺 size（超过上限 %ld），改为边下边算",
             (unsigned long)unknown.count, (long)kHeadMaxRequests];
        }
        if (completion) completion();
        return;
    }

    [A2Log log:@"[A2-DL] 预统计：%lu 个文件缺 size，HEAD 并发上限 %ld，预算 %.0fs",
     (unsigned long)unknown.count, (long)kHeadMaxConcurrent, kHeadTotalBudget];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = kHeadRequestTimeout;
    cfg.HTTPMaximumConnectionsPerHost = kHeadMaxConcurrent;
    cfg.URLCache = nil;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    NSUInteger total = unknown.count;
    __block NSUInteger cursor = 0;
    __block NSUInteger inFlight = 0;
    __block NSUInteger okCount = 0;
    __block NSUInteger failCount = 0;
    __block int64_t sum = 0;
    __block BOOL finished = NO;
    NSLock *lock = [NSLock new];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kHeadTotalBudget];

    __block void (^pump)(void) = nil;
    __block void (^finish)(void) = nil;

    finish = ^{
        BOOL fire = NO;
        int64_t value = 0;
        NSUInteger ok = 0, fail = 0;
        [lock lock];
        if (!finished) { finished = YES; fire = YES; }
        value = sum; ok = okCount; fail = failCount;
        [lock unlock];
        if (!fire) return;
        [session finishTasksAndInvalidate];
        [A2Log log:@"[A2-DL] 预统计结束：命中 %lu，失败 %lu，合计 %.1f MB",
         (unsigned long)ok, (unsigned long)fail, (double)value / 1048576.0];
        if (completion) completion();
    };

    pump = ^{
        while (YES) {
            A2DownloadRequest *req = nil;
            [lock lock];
            if (finished) { [lock unlock]; return; }
            if ([deadline timeIntervalSinceNow] <= 0) { [lock unlock]; finish(); return; }
            if (inFlight >= (NSUInteger)kHeadMaxConcurrent || cursor >= total) { [lock unlock]; break; }
            req = unknown[cursor++];
            inFlight++;
            [lock unlock];

            NSURL *url = req.candidateURLs.firstObject;
            if (!url) {
                [lock lock];
                if (inFlight > 0) inFlight--;
                failCount++;
                [lock unlock];
                continue;
            }
            NSMutableURLRequest *hreq = [NSMutableURLRequest requestWithURL:url];
            hreq.HTTPMethod = @"HEAD";
            hreq.timeoutInterval = kHeadRequestTimeout;
            [[session dataTaskWithRequest:hreq
                      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
                int64_t len = (error == nil) ? (int64_t)resp.expectedContentLength : 0;
                BOOL done = NO;
                [lock lock];
                if (len > 0) { sum += len; okCount++; } else { failCount++; }
                if (len > 0) req.expectedSize = len;   // 回填，批量统计才有分母
                if (inFlight > 0) inFlight--;
                done = (cursor >= total && inFlight == 0);
                [lock unlock];
                if (done) { finish(); return; }
                pump();
            }] resume];
        }

        BOOL done = NO;
        [lock lock];
        done = (cursor >= total && inFlight == 0);
        [lock unlock];
        if (done) finish();
    };

    // 到点强制收尾（有文件一直不返回时不能让下载干等）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHeadTotalBudget * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ finish(); });

    pump();
}

- (NSString *)formatSpeed:(double)bytesPerSec {
    if (bytesPerSec >= 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f MB/s", bytesPerSec / (1024 * 1024)];
    }
    if (bytesPerSec >= 1024) {
        return [NSString stringWithFormat:@"%.0f KB/s", bytesPerSec / 1024];
    }
    return [NSString stringWithFormat:@"%.0f B/s", bytesPerSec];
}


#pragma mark - 回调

- (void)report:(A2InstallStage)stage progress:(double)progress message:(NSString *)message {
    A2Main(^{
        if (self.progressBlock) {
            self.progressBlock(stage, MAX(0, MIN(1, progress)), message);
        }
    });
}

- (void)failWithMessage:(NSString *)msg {
    [self failWithError:[NSError errorWithDomain:@"A2Installer" code:1
                                        userInfo:@{NSLocalizedDescriptionKey: msg}]];
}

- (void)failWithError:(NSError *)error {
    [A2Log log:@"installer: 安装失败 %@：%@",
          self.request.versionName ?: @"(未知)", error.localizedDescription];
    A2Main(^{
        if (self.completionBlock) self.completionBlock(NO, error);
    });
}

@end
