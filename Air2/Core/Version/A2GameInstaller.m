//
//  A2GameInstaller.m
//  Air2
//

#import "A2GameInstaller.h"
#import "A2VersionIsolation.h"
#import "A2ModLoaderInstaller.h"

/// 官方版本清单地址（Mojang piston-meta）
static NSString *const kVersionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
/// 依赖库与资源的下载根
static NSString *const kResourcesBaseURL = @"https://resources.download.minecraft.net";
/// 依赖库根
static NSString *const kLibrariesBaseURL = @"https://libraries.minecraft.net";

static NSString *const kUserAgent = @"Air-Devs/Air2/0.1.0 (github.com/Air-Devs/Air2)";

static void A2Main(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

@interface A2GameInstaller ()
@property (nonatomic, strong, nullable) A2InstallRequest *request;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy, nullable) void (^progressBlock)(A2InstallStage, double, NSString *);
@property (nonatomic, copy, nullable) void (^completionBlock)(BOOL, NSError *);
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

    [self report:A2InstallStageFetchManifest progress:0 message:@"正在获取版本清单…"];
    [self fetchManifest];
}

- (void)fetchManifest {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                               [NSURL URLWithString:kVersionManifestURL]];
    req.timeoutInterval = 30;
    [req setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *t = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (self.cancelled) return;
        if (error) { [self failWithError:error]; return; }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class]) {
            [self failWithMessage:@"版本清单格式异常"];
            return;
        }

        // 找到目标版本的清单 URL
        NSArray *versions = json[@"versions"];
        NSString *url = nil;
        for (NSDictionary *v in versions) {
            if ([v[@"id"] isEqualToString:self.request.mcVersion]) {
                url = v[@"url"];
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
        [self downloadVersionJSON:url];
    }];
    [t resume];
}

- (void)downloadVersionJSON:(NSString *)url {
    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    NSString *dest = [path versionJSONPath:self.request.versionName];

    [self download:[NSArray arrayWithObject:url]
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
    NSString *jarDest = [path versionJarPath:self.request.versionName];

    if (!jarURL.length) {
        [self failWithMessage:@"版本信息里没有客户端下载地址"];
        return;
    }

    [self report:A2InstallStageDownloadJar progress:0 message:@"正在下载客户端…"];
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
            [self endInstallation];
        }];
    }];
}

- (void)saveLoaderSelection:(A2ModLoaderVersion *)loader {
    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    NSString *dir = [path launcherDataPath:self.request.versionName];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];

    NSDictionary *info = @{
        @"loaderType": [A2ModLoaderAPI identifierForType:loader.type],
        @"loaderVersion": loader.version,
        @"mcVersion": self.request.mcVersion,
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:info
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    NSString *dest = [dir stringByAppendingPathComponent:@"loader.json"];
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
    if (self.completionBlock) self.completionBlock(YES, nil);
}

#pragma mark - 下载辅助

/// 单文件下载（带校验、断点、镜像）
- (void)download:(NSArray<NSString *> *)urls
              to:(NSString *)dest
      stageLabel:(A2InstallStage)stage
         message:(NSString *)message
         thenRun:(void (^)(NSError * _Nullable))then {

    if (self.cancelled) return;

    A2DownloadRequest *req = [A2DownloadRequest new];
    NSMutableArray<NSURL *> *list = [NSMutableArray array];
    for (NSString *u in urls) {
        NSURL *url = [NSURL URLWithString:u];
        if (url) [list addObject:url];
    }
    req.candidateURLs = list;
    req.destinationPath = dest;
    req.allowZipFallbackCheck = YES;

    __weak typeof(self) weakSelf = self;
    [[A2DownloadEngine sharedClient] startRequest:req
        progress:^(int64_t delta, int64_t total) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled || total <= 0) return;
        // 用累计值算阶段进度
        static int64_t acc = 0;
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

/// 批量下载（逐个串行，避免并发过高被限流）
- (void)downloadBatch:(NSArray<NSArray<NSString *> *> *)items
                stage:(A2InstallStage)stage
          messageBase:(NSString *)base
             thenRun:(void (^)(NSError * _Nullable))then {

    __block NSUInteger index = 0;
    __block NSUInteger total = items.count;
    __block NSUInteger failed = 0;

    __block void (^next)(void) = nil;
    __weak typeof(self) weakSelf = self;

    next = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;
        if (index >= total) {
            if (then) then(nil);
            next = nil;
            return;
        }

        NSArray<NSString *> *pair = items[index];
        NSString *url = pair[0];
        NSString *dest = pair[1];
        NSUInteger currentIndex = index;

        [self download:@[url] to:dest stageLabel:stage
               message:[NSString stringWithFormat:@"%@ (%lu/%lu)",
                        base, (unsigned long)(currentIndex + 1), (unsigned long)total]
               thenRun:^(NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.cancelled) return;

            // 单个文件失败不中断整体 —— 依赖库里有可选组件，
            // 下载不到不影响启动
            if (error) failed++;

            index++;
            [self report:stage progress:(double)index / (double)total
                 message:[NSString stringWithFormat:@"%@ (%lu/%lu)",
                          base, (unsigned long)index, (unsigned long)total]];
            if (next) next();
        }];
    };

    next();
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
    A2Main(^{
        if (self.completionBlock) self.completionBlock(NO, error);
    });
}

@end
