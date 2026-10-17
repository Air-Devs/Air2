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

// ★批量下载总量进度★
@property (nonatomic) BOOL a2InBatch;
@property (nonatomic) int64_t a2BatchBytesDone;
@property (nonatomic) int64_t a2BatchBytesTotal;
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
    __block int64_t acc = 0;
    __block BOOL counted = NO;   // 每个文件只把总大小计入批次一次
    [[A2DownloadEngine sharedClient] startRequest:req
        progress:^(int64_t delta, int64_t total) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled || total <= 0) return;
        // 用累计值算阶段进度
        acc += delta;
        if (acc < 0) acc = 0;

        // ★批量模式：显示「整批」的已下载/总大小★（用户要求：总大小，不是单文件大小）
        if (self.a2InBatch) {
            @synchronized (self) {
                if (total > 0 && !counted) {
                    counted = YES;
                    self.a2BatchBytesTotal += total;
                }
                self.a2BatchBytesDone += delta;
                if (self.a2BatchBytesDone < 0) self.a2BatchBytesDone = 0;
                double bp = (self.a2BatchBytesTotal > 0)
                    ? MIN(1.0, (double)self.a2BatchBytesDone / (double)self.a2BatchBytesTotal)
                    : 0.0;
                [self report:stage progress:bp
                     message:[NSString stringWithFormat:@"已下载 %.1f MB / 共 %.1f MB",
                              (double)self.a2BatchBytesDone / 1048576.0,
                              (double)self.a2BatchBytesTotal / 1048576.0]];
            }
            return;
        }

        double p = MIN(1.0, (double)acc / (double)total);
        [self report:stage progress:p
             message:[NSString stringWithFormat:@"%@  %.1f / %.1f MB",
                      message, (double)acc / 1048576.0, (double)total / 1048576.0]];
    }
        speed:nil
        completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;
        if (then) then(success ? nil : error);
    }];
}

/// 批量下载（★有上限并行★）。
/// 上游原本是「逐个串行」——几十个库 + 上千个资源文件时慢得明显；
/// 这里只改“同时在飞几个”，每个文件仍走同一条 download: 路径（候选/校验/断点不变），
/// 单文件失败仍只计数、不中断整体。并发数默认 4，可用偏好键 A2DownloadConcurrency 覆盖(1~8)。
- (void)downloadBatch:(NSArray<NSArray<NSString *> *> *)items
                stage:(A2InstallStage)stage
           messageBase:(NSString *)base
              thenRun:(void (^)(NSError * _Nullable))then {

    NSUInteger total = items.count;
    if (total == 0) { if (then) then(nil); return; }

    NSInteger concurrency = [NSUserDefaults.standardUserDefaults integerForKey:@"A2DownloadConcurrency"];
    if (concurrency <= 0) concurrency = 4;
    concurrency = MAX(1, MIN(8, concurrency));
    if (concurrency > (NSInteger)total) concurrency = (NSInteger)total;

    [A2Log log:@"[A2-DL] batch 总 %lu 个文件，并发=%ld（键 A2DownloadConcurrency，缺省 4）",
                 (unsigned long)total, (long)concurrency];
    @synchronized (self) {
        self.a2InBatch = YES;
        self.a2BatchBytesDone = 0;
        self.a2BatchBytesTotal = 0;
    }

    __block NSUInteger index = 0;          // 下一个待发
    __block NSUInteger done = 0;           // 已完成（含失败）
    __block NSUInteger failed = 0;
    __block BOOL finished = NO;
    __weak typeof(self) weakSelf = self;

    __block void (^pump)(void) = nil;
    pump = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || finished) return;
        if (self.cancelled) { finished = YES; pump = nil; return; }

        // 补满窗口
        while (index < total && index - done < (NSUInteger)concurrency) {
            NSUInteger currentIndex = index;
            index++;

            NSArray<NSString *> *pair = items[currentIndex];
            NSString *url = pair.count > 0 ? pair[0] : nil;
            NSString *dest = pair.count > 1 ? pair[1] : nil;
            if (url.length == 0 || dest.length == 0) {
                done++; failed++; continue;
            }

            [self download:@[url] to:dest stageLabel:stage
                   message:base
                   thenRun:^(NSError *error) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;
                // 单个文件失败不中断整体 —— 依赖库里有可选组件，下载不到不影响启动
                if (error) failed++;
                done++;
                [self report:stage progress:(double)done / (double)total message:base];
                if (done >= total) {
                    if (finished) return;
                    finished = YES;
                    @synchronized (self) { self.a2InBatch = NO; }
                    [A2Log log:@"[A2-DL] batch 完成：%lu 个，失败 %lu，总大小 %.1f MB",
                                 (unsigned long)total, (unsigned long)failed,
                                 (double)self.a2BatchBytesTotal / 1048576.0];
                    if (then) then(nil);
                    pump = nil;
                    return;
                }
                if (pump) pump();
            }];
        }
    };

    pump();
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
