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
#import "A2Logger.h"
#import "A2VersionIsolation.h"
#import "A2ModLoaderInstaller.h"
#import "A2MirrorResolver.h"
#import "A2APIModDownloader.h"
#import "A2Log.h"

/// 官方版本清单地址（Mojang piston-meta）—— 镜像链的「原始地址」，
/// 候选顺序由 A2MirrorResolver 决定（镜像优先 → 官方兜底）。
static NSString *const kVersionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
/// 资源对象的官方根：资源索引里只给 hash，不给完整 URL，故这里必须自己拼。
/// （★依赖库不在这里拼★ —— 库的完整 URL 由 manifest 的 downloads.artifact.url 给出。）
static NSString *const kResourcesBaseURL = @"https://resources.download.minecraft.net";

static NSString *const kUserAgent = @"Air-Devs/Air2/0.1.0 (github.com/Air-Devs/Air2)";

// ============================================================
// [DL-CONC] 安装期批量下载（libraries / assets）的并发度
// ------------------------------------------------------------
// ★唯一调参点★：改这里的默认值即可，无需改动任何调用方。
//   · 默认 6 —— 真机实测下 3 路仍把总耗时压在单条连接上
//     （数千个 asset 的网络往返），6 路能把吞吐顶起来；
//   · 建议范围 1..8（上限见 kA2InstallMaxConcurrency）；
//   · 运行期亦可用 NSUserDefaults 键 "air2.install.concurrency" 覆盖，便于真机试参。
// 背景：原实现把每个文件串成一条长龙（下完一个才发下一个），
//   数千个 asset 的网络往返直接线性叠加成总耗时 —— 即用户说的
//   「一个个下、一个要等一秒多」。改为 completion 驱动的有界并发流水线。
// ============================================================
static const NSInteger kA2InstallDefaultConcurrency = 6;
static const NSInteger kA2InstallMaxConcurrency = 8;
static NSString *const kA2InstallConcurrencyPrefKey = @"air2.install.concurrency";

/// 解析本次安装实际使用的并发度：默认值 ← 偏好覆盖，并夹到 [1, 上限]
static NSInteger A2InstallEffectiveConcurrency(void) {
    NSInteger n = kA2InstallDefaultConcurrency;
    NSNumber *pref = [[NSUserDefaults standardUserDefaults] objectForKey:kA2InstallConcurrencyPrefKey];
    if ([pref isKindOfClass:NSNumber.class]) n = pref.integerValue;
    if (n < 1) n = 1;
    if (n > kA2InstallMaxConcurrency) n = kA2InstallMaxConcurrency;
    return n;
}

static void A2Main(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

@interface A2GameInstaller ()
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

// [DL-CONC] 下载辅助（实现见 #pragma mark - 下载辅助）
- (void)download:(NSArray<NSString *> *)urls
              to:(NSString *)dest
      stageLabel:(A2InstallStage)stage
         message:(NSString *)message
  reportIntraFile:(BOOL)reportIntraFile
         thenRun:(void (^)(NSError * _Nullable))then;
- (void)downloadBatch:(NSArray<NSArray<NSString *> *> *)items
                stage:(A2InstallStage)stage
          messageBase:(NSString *)base
             thenRun:(void (^)(NSError * _Nullable))then;
@end

@implementation A2InstallRequest
@end

@implementation A2GameInstaller

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _session = [NSURLSession sessionWithConfiguration:
                NSURLSessionConfiguration.defaultSessionConfiguration];
    return self;
}

- (void)cancel {
    _cancelled = YES;
    [A2Log log:@"installer: 取消安装 %@", self.request.versionName ?: @"(未知)"];
    // cancelOperation: 的参数标了 nonnull，传 nil 会警告。
    // 这里改调 cancelAll —— 语义也更对：取消安装就该停掉所有下载。
    [[A2DownloadEngine sharedClient] cancelAll];
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
    // ★[A2-MIRROR] 判据行★：镜像开关 + 判定依据（时区）+ 生效结论 + 镜像出处，
    //   每次安装打一条，默认可见、可 grep（`grep '\[A2-MIRROR\]' lastlog.txt`）。
    [A2Log log:@"[A2-MIRROR] %@", [[A2MirrorResolver shared] auditSummary]];

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

/// 版本清单的候选源：镜像优先 → 官方兜底。
/// 顺序由 A2MirrorResolver 按「开关 / 优先级 / 是否大陆」决定；
/// 关掉镜像或不在大陆时这里只剩官方一条 —— 即「默认国内才启用」。
- (NSArray<NSString *> *)manifestCandidateURLs {
    NSArray<NSString *> *cands =
        [[A2MirrorResolver shared] candidateURLsForURL:kVersionManifestURL];
    return cands.count > 0 ? cands : @[kVersionManifestURL];
}

- (void)fetchManifest {
    [self fetchManifestFromCandidate:0 lastError:nil];
}

/// 依次尝试候选清单源。
///
/// 任一源失败（网络错 / 非 2xx / 不是 JSON / 清单里没有这个版本）就换下一个，
/// 全部耗尽才报错 —— 即「镜像优先，失败自动切源（官方兜底）」。
- (void)fetchManifestFromCandidate:(NSUInteger)index lastError:(NSError *)lastError {
    NSArray<NSString *> *cands = [self manifestCandidateURLs];
    if (index >= cands.count) {
        [self failWithError:lastError ?: [NSError errorWithDomain:@"A2Installer" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"版本清单不可用：镜像与官方源均失败"}]];
        return;
    }

    NSString *urlString = cands[index];
    NSString *source = [A2MirrorResolver sourceLabelForURL:urlString];
    [A2Log log:@"[A2-MIRROR] stage=manifest 候选=%lu/%lu source=%@ url=%@",
          (unsigned long)(index + 1), (unsigned long)cands.count, source, urlString];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                               [NSURL URLWithString:urlString]];
    req.timeoutInterval = 30;
    [req setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *t = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;

        NSString *entryURL = nil;
        NSError *attemptError = error;

        if (!attemptError) {
            // 先看状态码：镜像 404/5xx 时常回 HTML，先看码比让 JSON 解析报错更直接。
            NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)resp).statusCode : 200;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data]
                                                                 options:0 error:nil];
            if (code < 200 || code >= 300) {
                attemptError = [self errorWithMessage:
                    [NSString stringWithFormat:@"HTTP %ld（清单源 %@）", (long)code, source]];
            } else if (![json isKindOfClass:NSDictionary.class]) {
                attemptError = [self errorWithMessage:
                    [NSString stringWithFormat:@"清单不是 JSON 字典（清单源 %@）", source]];
            } else {
                entryURL = [self versionJSONURLInManifest:json];
                if (entryURL.length == 0) {
                    attemptError = [self errorWithMessage:
                        [NSString stringWithFormat:@"清单里没有版本 %@（清单源 %@）",
                         self.request.mcVersion, source]];
                }
            }
        }

        if (entryURL.length > 0) {
            [A2Log log:@"[A2-MIRROR] stage=manifest 采用 source=%@ url=%@", source, urlString];
            [self report:A2InstallStageFetchManifest progress:1 message:@"版本清单已获取"];
            [self report:A2InstallStageDownloadJSON progress:0 message:@"正在下载版本信息…"];
            [self downloadVersionJSON:entryURL];
            return;
        }

        [A2Log log:@"[A2-MIRROR] stage=manifest 失败切源 source=%@ 原因=%@ url=%@",
              source, attemptError.localizedDescription ?: @"(未知)", urlString];
        [self fetchManifestFromCandidate:index + 1 lastError:attemptError];
    }];
    [t resume];
}

/// 从清单里取出目标版本的「版本 JSON」地址；没有则返回 nil。
- (nullable NSString *)versionJSONURLInManifest:(NSDictionary *)json {
    NSArray *versions = json[@"versions"];
    if (![versions isKindOfClass:NSArray.class]) return nil;
    for (NSDictionary *v in versions) {
        if (![v isKindOfClass:NSDictionary.class]) continue;
        if (![v[@"id"] isEqualToString:self.request.mcVersion]) continue;
        id u = v[@"url"];
        return [u isKindOfClass:NSString.class] ? u : nil;
    }
    return nil;
}

- (NSError *)errorWithMessage:(NSString *)message {
    return [NSError errorWithDomain:@"A2Installer" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (void)downloadVersionJSON:(NSString *)url {
    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    // 原版一律落到基底版本目录：带加载器时是 versions/<mcVersion>/，
    // 加载器后面会读它、并把它的 jar 硬链到自己的版本目录。
    NSString *dest = [path versionJSONPath:self.baseVersionName];

    [self logStage:@"stage=version-json" sample:url];
    [self download:@[url]
                to:dest
        stageLabel:A2InstallStageDownloadJSON
           message:@"正在下载版本信息"
           thenRun:^(NSError *error) {
        if (error) { [self failWithError:error]; return; }
        [self afterVersionJSON:dest];
    }];
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

    [self report:A2InstallStageDownloadJar progress:0 message:@"正在下载客户端…"];
    [self logStage:@"stage=client-jar" sample:jarURL];
    [self download:@[jarURL] to:jarDest stageLabel:A2InstallStageDownloadJar
           message:@"正在下载客户端"
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
        if ([NSFileManager.defaultManager fileExistsAtPath:dest]) continue;   // 已有就跳过

        [pending addObject:@[url, dest]];
    }

    if (pending.count == 0) {
        [self report:A2InstallStageDownloadLibraries progress:1 message:@"依赖库已完整"];
        [self installAssetsFromJSON:json];
        return;
    }

    [self logStage:@"stage=libraries" sample:pending.firstObject.firstObject];
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
    [self logStage:@"stage=assets-index" sample:indexURL];
    [self download:@[indexURL] to:indexPath stageLabel:A2InstallStageDownloadAssets
           message:@"正在下载资源索引"
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

        if ([NSFileManager.defaultManager fileExistsAtPath:dest]) continue;

        NSString *url = [NSString stringWithFormat:@"%@/%@/%@",
                         kResourcesBaseURL, sub, hash];
        [pending addObject:@[url, dest]];
    }

    if (pending.count == 0) {
        [self report:A2InstallStageDownloadAssets progress:1 message:@"资源已完整"];
        [self installLoaderIfNeeded];
        return;
    }

    [self logStage:@"stage=assets" sample:pending.firstObject.firstObject];
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

    // ========================================================================
    // ★[A2-INSTANCE] 实例落位判据行（安装侧）★
    // ------------------------------------------------------------------------
    // 判据 = 启动链真的要打开的那两个文件：
    //          <gameHome>/versions/<版本名>/<版本名>.json
    //          <gameHome>/versions/<版本名>/<版本名>.jar
    //   两者都走 A2GamePath 的同一处计算（与下载落点、与启动读取同一处，
    //   不在这里另拼一份路径）。
    // 带加载器时另查基底版本：加载器 json 以 inheritsFrom 指向它、
    //   它的 jar 被硬链到加载器版本目录 —— 缺了照样起不来。
    // ★判据为假 ⇒ 如实报失败★：报「安装完成」却不在 versions/ 里留下可用
    //   实例，正是本单要消灭的半成品形态（包内 versions/ = 0 的成因）。
    // ========================================================================
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *instanceJSON = [path versionJSONPath:self.request.versionName];
    NSString *instanceJar = [path versionJarPath:self.request.versionName];
    BOOL jsonExists = [fm fileExistsAtPath:instanceJSON];
    BOOL jarExists = [fm fileExistsAtPath:instanceJar];
    BOOL instanceOK = jsonExists && jarExists;

    BOOL baseOK = YES;
    NSString *baseField = @"";
    if (![self.baseVersionName isEqualToString:self.request.versionName]) {
        baseOK = [fm fileExistsAtPath:[path versionJSONPath:self.baseVersionName]]
              && [fm fileExistsAtPath:[path versionJarPath:self.baseVersionName]];
        baseField = [NSString stringWithFormat:@" base=%@ baseExists=%d",
                     self.baseVersionName, baseOK ? 1 : 0];
    }

    // ★可 grep 的判据行（默认可见）★
    [A2Log log:@"[A2-INSTANCE] id=%@ jar=%@ json=%@ exists=%d stage=install assets=%@ libraries=%@%@",
     self.request.versionName, instanceJar, instanceJSON, instanceOK ? 1 : 0,
     [path assetsHome], [path librariesHome], baseField];

    if (!instanceOK || !baseOK) {
        [self failWithMessage:[NSString stringWithFormat:
            @"安装收尾校验未通过：versions/%@ 缺 json 或 jar（json=%d jar=%d）%@",
            self.request.versionName, jsonExists ? 1 : 0, jarExists ? 1 : 0,
            baseOK ? @"" : [NSString stringWithFormat:@"，且基底 %@ 不完整", self.baseVersionName]]];
        return;
    }

    [self report:A2InstallStageFinalize progress:1 message:@"安装完成"];
    [A2Log log:@"installer: 安装完成 %@", self.request.versionName];
    if (self.completionBlock) self.completionBlock(YES, nil);
}

#pragma mark - 下载辅助

#pragma mark 镜像链

/// 单个地址 → 候选链（镜像优先 → 官方兜底；关掉镜像时只有官方一条）。
///
/// ★只给判据行用★：真正的候选展开发生在 `download:…` 里（唯一入口）。
/// 调用方一律把 manifest 里的**原始官方地址**交给 `download:`，
/// 若这里再展开一次，下载请求的候选链就会变成 [镜像, 官方, 镜像, 官方]。
- (NSArray<NSString *> *)candidatesForURL:(NSString *)url {
    NSArray<NSString *> *cands = [[A2MirrorResolver shared] candidateURLsForURL:url];
    return cands.count > 0 ? cands : @[url];
}

/// 阶段级判据行：本阶段实际会用的源（镜像 / 官方）+ 候选条数 + 样本地址。
///
/// `stage` 传进来的就是完整判据 token（如 `stage=libraries`）—— 这样
/// 「哪些阶段会打源判据」在源码里可 grep（`grep 'stage='` 一眼看全），
/// 编译进包后也是一条完整字面量（包内自证可直接扫到）。
///
/// 每阶段一条而不是每文件一条 —— 库 / 资源阶段的文件数以千计，
/// 逐条打会把日志刷爆，反而看不出「用的哪个源」。
- (void)logStage:(NSString *)stage sample:(NSString *)url {
    NSArray<NSString *> *cands = [self candidatesForURL:url];
    NSString *first = cands.firstObject ?: @"";
    [A2Log log:@"[A2-MIRROR] %@ 首选=%@ source=%@ 候选=%lu 样本=%@",
          stage, first, [A2MirrorResolver sourceLabelForURL:first],
          (unsigned long)cands.count, url];
}

#pragma mark 单文件 / 批量

/// 单文件下载（带校验、断点、镜像）。阶段内进度按该文件字节推进。
- (void)download:(NSArray<NSString *> *)urls
              to:(NSString *)dest
      stageLabel:(A2InstallStage)stage
         message:(NSString *)message
         thenRun:(void (^)(NSError * _Nullable))then {
    [self download:urls to:dest stageLabel:stage message:message
   reportIntraFile:YES thenRun:then];
}

/// 单文件下载核心。
/// @param reportIntraFile YES=用本文件字节数推进阶段进度（单文件阶段：json / jar / 索引）；
///                        NO =不推进（批量阶段：进度由 downloadBatch: 按文件数推进，
///                             否则并行多文件各自的 0..1 会让进度条来回乱跳）。
- (void)download:(NSArray<NSString *> *)urls
              to:(NSString *)dest
      stageLabel:(A2InstallStage)stage
         message:(NSString *)message
  reportIntraFile:(BOOL)reportIntraFile
         thenRun:(void (^)(NSError * _Nullable))then {

    if (self.cancelled) return;

    A2DownloadRequest *req = [A2DownloadRequest new];
    NSMutableArray<NSURL *> *list = [NSMutableArray array];
    // ★[A2-MIRROR] 镜像链的唯一入口★：调用方（版本 json / jar / 索引 / 库 / 资源）
    //   传进来的都是 manifest 里的官方地址，在这里统一展开成「镜像优先 → 官方兜底」
    //   的候选链；引擎按序尝试，前一个候选失败（退避重试耗尽）自动换下一个。
    for (NSString *u in urls) {
        for (NSString *c in [self candidatesForURL:u]) {
            NSURL *url = [NSURL URLWithString:c];
            if (url) [list addObject:url];
        }
    }
    req.candidateURLs = list;
    req.destinationPath = dest;
    req.allowZipFallbackCheck = YES;

    __weak typeof(self) weakSelf = self;
    // [DL-CONC] 累计值改为【每次调用独立】。旧实现用函数内 static：
    //   批量下载时该 static 被所有文件共用 ⇒ 累计值跨文件串味、进度瞬间顶到 1。
    __block int64_t acc = 0;
    [[A2DownloadEngine sharedClient] startRequest:req
        progress:^(int64_t delta, int64_t total) {
        if (!reportIntraFile) return;
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
}

/// 批量下载 —— [DL-CONC] completion 驱动的有界并发流水线。
///
/// 原实现「逐个串行」：一个文件下完才发下一个 ⇒ N 个文件的网络往返线性叠加，
/// 数千 asset 时即用户说的「一个个下、一个要等一秒多」。
///
/// 现实现：始终维持最多 A2InstallEffectiveConcurrency() 个在途下载，任一完成即从
/// 队列补位，全程由 completion 回调驱动 —— 无 sleep、无轮询。
/// · 调度状态（游标/计数）只在串行队列 sched 上访问，故无需额外加锁；
/// · 进度按「已完成文件数 / 总数」单调推进，不随各文件快慢乱跳；
/// · 单文件失败不中断整体（依赖库含可选组件），与原行为一致；
/// · 取消沿用 self.cancelled：不再发起新任务，在途任务自然收尾。
- (void)downloadBatch:(NSArray<NSArray<NSString *> *> *)items
                stage:(A2InstallStage)stage
          messageBase:(NSString *)base
             thenRun:(void (^)(NSError * _Nullable))then {

    NSUInteger total = items.count;
    if (total == 0) {
        [self report:stage progress:1 message:base];
        if (then) then(nil);
        return;
    }

    NSInteger maxConcurrent = A2InstallEffectiveConcurrency();
    [A2Log log:@"[DL-CONC] 批量下载开始: %lu 个文件, 并发度=%ld, 阶段=%ld",
          (unsigned long)total, (long)maxConcurrent, (long)stage];

    dispatch_queue_t sched = dispatch_queue_create("dev.airdevs.air2.installer.batch",
                                                   DISPATCH_QUEUE_SERIAL);
    __block NSUInteger nextIndex = 0;   // 下一个待发起的下标
    __block NSUInteger completed = 0;   // 已收尾（成功+失败）文件数
    __block NSUInteger failed = 0;
    __block NSUInteger inFlight = 0;    // 在途下载数
    __block BOOL finished = NO;

    __weak typeof(self) weakSelf = self;
    __block void (^pump)(void) = nil;   // 补位调度器（仅在 sched 上执行）

    pump = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || finished) return;
        if (self.cancelled) return;     // 取消：停止发起新任务（在途任务自会回调收尾）

        // 把在途窗口补满
        while (inFlight < (NSUInteger)maxConcurrent && nextIndex < total) {
            NSArray<NSString *> *pair = items[nextIndex];
            nextIndex++;

            NSString *url = pair.count > 0 ? pair[0] : nil;
            NSString *dest = pair.count > 1 ? pair[1] : nil;
            if (!url.length || !dest.length) {
                completed++;
                failed++;
                [self report:stage progress:(double)completed / (double)total
                     message:[NSString stringWithFormat:@"%@ (%lu/%lu)",
                              base, (unsigned long)completed, (unsigned long)total]];
                continue;
            }

            inFlight++;
            NSUInteger ordinal = MIN(completed + inFlight, total);
            [self download:@[url] to:dest stageLabel:stage
                   message:[NSString stringWithFormat:@"%@ (%lu/%lu)",
                            base, (unsigned long)ordinal, (unsigned long)total]
            reportIntraFile:NO
                   thenRun:^(NSError *error) {
                dispatch_async(sched, ^{
                    __strong typeof(weakSelf) s2 = weakSelf;
                    if (!s2) return;
                    if (error) failed++;
                    completed++;
                    if (inFlight > 0) inFlight--;
                    [s2 report:stage progress:(double)completed / (double)total
                         message:[NSString stringWithFormat:@"%@ (%lu/%lu)",
                                  base, (unsigned long)completed, (unsigned long)total]];
                    if (pump) pump();
                });
            }];
        }

        // 全部收尾 → 回调（单文件失败不视为整体失败，与旧行为一致）
        if (completed >= total && !finished) {
            finished = YES;
            [A2Log log:@"[DL-CONC] 批量下载结束: %lu 个文件, 失败=%lu",
                  (unsigned long)total, (unsigned long)failed];
            if (then) then(nil);
            pump = nil;   // 打断 pump 的自持有，避免泄漏
        }
    };

    dispatch_async(sched, ^{ if (pump) pump(); });
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
    [self failWithError:[self errorWithMessage:msg]];
}

- (void)failWithError:(NSError *)error {
    [A2Log log:@"installer: 安装失败 %@：%@",
          self.request.versionName ?: @"(未知)", error.localizedDescription];
    A2Main(^{
        if (self.completionBlock) self.completionBlock(NO, error);
    });
}

@end
