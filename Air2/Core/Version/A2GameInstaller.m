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
    // 这一步是安装的第一个请求，卡在这里最影响观感
    NSString *manifestURL = [[A2MirrorResolver shared]
                             candidateURLsForURL:kVersionManifestURL].firstObject
                         ?: kVersionManifestURL;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                               [NSURL URLWithString:manifestURL]];
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
    // 原版一律落到基底版本目录：带加载器时是 versions/<mcVersion>/，
    // 加载器后面会读它、并把它的 jar 硬链到自己的版本目录。
    NSString *dest = [path versionJSONPath:self.baseVersionName];

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
    NSString *jarDest = [path versionJarPath:self.baseVersionName];

    if (!jarURL.length) {
        [self failWithMessage:@"版本信息里没有客户端下载地址"];
        return;
    }

    // 客户端 jar 也带完整性字段 —— MC 版本 json 里 downloads.client
    // 就给了 sha1 与 size，直接透传。
    NSString *jarSHA1 = client[@"sha1"];
    NSNumber *jarSize = client[@"size"];

    [self report:A2InstallStageDownloadJar progress:0 message:@"正在下载客户端…"];
    [self download:@[jarURL] to:jarDest stageLabel:A2InstallStageDownloadJar
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
    for (NSString *u in urls) {
        NSURL *url = [NSURL URLWithString:u];
        if (url) [list addObject:url];
    }
    req.candidateURLs = list;
    req.destinationPath = dest;
    req.allowZipFallbackCheck = YES;

    // 完整性字段。引擎会在两处用它们：
    //   1. 开始前：本地已有且 SHA1 一致 → 直接跳过（不重下）
    //   2. 完成后：SHA1 不符 → 丢弃半成品、换源重试
    if (sha1.length) req.expectedSHA1 = sha1;
    if (size) req.expectedSize = size.longLongValue;

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

    // 并发数可配置 —— 默认 64（与 ZL2 的 DEFAULT_MAX_CONNECTIONS 一致）。
    //
    // 上限不是越高越好：每个连接都要占内存与文件句柄，
    // iOS 上超过 128 容易触发系统限制或服务端限流。
    NSInteger configured = [NSUserDefaults.standardUserDefaults
                            integerForKey:@"A2MaxConnections"];
    NSInteger kMaxConnections = (configured > 0) ? MIN(configured, 128) : 64;

    A2BatchDownloader *downloader =
        [[A2BatchDownloader alloc] initWithRequests:requests
                                     maxConnections:kMaxConnections
                                        retryRounds:1];

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
        if (!self || self.cancelled) return;

        if (failures.count > 0) {
            [A2Log log:@"installer: %@ 完成，%lu 个文件失败",
                  base, (unsigned long)failures.count];
        }
        // 单文件失败不阻断 —— 依赖库里有可选组件，缺几个不影响启动
        if (then) then(nil);
    };

    [downloader start];
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
