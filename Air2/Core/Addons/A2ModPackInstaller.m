//
//  A2ModPackInstaller.m
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
//  见头文件：整合包导入的四步编排。
//  只做编排与路径守卫，真正的下载 / 解压 / 安装都委托给现成组件。
//

#import "A2ModPackInstaller.h"
#import "A2ModPack.h"
#import "A2ModLoaderAPI.h"
#import "A2ModLoaderInstaller.h"
#import "A2GameInstaller.h"
#import "A2DownloadEngine.h"
#import "A2ZipReader.h"
#import "A2VersionIsolation.h"

NSString *const A2ModPackInstallerErrorDomain = @"A2ModPackInstaller";

/// 回调统一回主线程（与 A2GameInstaller 保持一致）
static void A2ImportMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

/// 把 root 与相对路径安全拼接：越界（绝对路径 / .. 逃出）返回 nil。
/// 不做截断式「修正」—— 那会让调用方误以为写到了别处。
static NSString *A2ImportSafeJoin(NSString *root, NSString *relative) {
    if (relative.length == 0) return nil;
    if ([relative hasPrefix:@"/"]) return nil;
    // 显式拒绝 .. 分量，不依赖 stringByStandardizingPath 的折叠行为
    for (NSString *component in [relative componentsSeparatedByString:@"/"]) {
        if ([component isEqualToString:@".."]) return nil;
    }
    NSString *stdRoot = root.stringByStandardizingPath;
    NSString *joined = [[stdRoot stringByAppendingPathComponent:relative] stringByStandardizingPath];
    if ([joined isEqualToString:stdRoot]) return nil;
    if (![joined hasPrefix:[stdRoot stringByAppendingString:@"/"]]) return nil;
    return joined;
}

@implementation A2ModPackImportRequest
@end

@interface A2ModPackInstaller ()
@property (nonatomic, strong, nullable) A2ModPackImportRequest *request;
@property (nonatomic, copy, nullable) void (^progressBlock)(A2ModPackImportStage, double, NSString *);
@property (nonatomic, copy, nullable) void (^completionBlock)(BOOL, NSString *, NSError *);
@property (nonatomic, assign) BOOL cancelled;
/// 未能写入的必需文件数（下载失败 / 路径越界）
@property (nonatomic, assign) NSUInteger failedRequiredCount;
@property (nonatomic, copy, nullable) NSString *resolvedVersionName;
@property (nonatomic, copy, nullable) NSString *gameDirectory;
@property (nonatomic, strong, nullable) A2ModPackPlan *plan;
/// 持有正在运行的安装器，避免其被提前释放
@property (nonatomic, strong, nullable) A2GameInstaller *gameInstaller;

- (void)parseArchive;
- (NSString *)resolveVersionName:(nullable NSString *)packName;
- (void)beginGameInstallWithLoaderType:(nullable NSNumber *)loaderType;
- (void)prepareGameDirectoryForIsolation;
- (void)downloadContent;
- (void)downloadFiles:(NSArray<A2ModPackFile *> *)files;
- (void)extractOverrides;
- (void)finishImport;
- (void)report:(A2ModPackImportStage)stage progress:(double)progress message:(NSString *)message;
- (void)failWithCode:(A2ModPackInstallerError)code message:(NSString *)message;
- (void)failWithError:(NSError *)error;
- (void)complete:(BOOL)success error:(nullable NSError *)error;
- (NSError *)errorWithCode:(A2ModPackInstallerError)code message:(NSString *)message;
@end

@implementation A2ModPackInstaller

#pragma mark - 入口

- (void)cancel {
    self.cancelled = YES;
    // 先停子安装器（本体/加载器阶段），再杀掉在途下载
    [self.gameInstaller cancel];
    [[A2DownloadEngine sharedClient] cancelAll];
}

- (void)importRequest:(A2ModPackImportRequest *)request
             progress:(void (^)(A2ModPackImportStage, double, NSString *))progress
           completion:(void (^)(BOOL, NSString *, NSError *))completion {

    self.request = request;
    self.progressBlock = progress;
    self.completionBlock = completion;
    self.cancelled = NO;
    self.failedRequiredCount = 0;
    self.plan = nil;
    self.gameDirectory = nil;

    if (request.archivePath.length == 0 || request.gameHome.length == 0) {
        [self failWithCode:A2ModPackInstallerErrorInvalidParameter message:@"参数不完整"];
        return;
    }

    [self report:A2ModPackImportStageParse progress:0 message:@"正在解析整合包…"];
    [self parseArchive];
}

#pragma mark - 1. 解析

- (void)parseArchive {
    NSError *parseError = nil;
    A2ModPackPlan *plan = [A2ModPackParser parseZipAtPath:self.request.archivePath
                                                    error:&parseError];
    if (!plan) {
        [self failWithError:parseError ?: [self errorWithCode:A2ModPackInstallerErrorUnreadableArchive
                                                      message:@"整合包解析失败"]];
        return;
    }
    if (plan.gameVersion.length == 0) {
        [self failWithCode:A2ModPackInstallerErrorMissingGameVersion
                   message:@"整合包没有声明游戏版本，无法确定要装的版本"];
        return;
    }

    // 加载器：标识为空 = 原版包；标识非空但解析不出类型 = 不认识的加载器，明确拒绝，
    // 不静默退化成原版（那会装出一个跑不起来的版本）。
    NSNumber *loaderType = [A2ModPackParser loaderTypeForIdentifier:plan.loaderID];
    if (plan.loaderID.length > 0 && loaderType == nil) {
        [self failWithCode:A2ModPackInstallerErrorUnsupportedLoader
                   message:[NSString stringWithFormat:@"无法识别的模组加载器：%@", plan.loaderID]];
        return;
    }
    if (loaderType && ![A2ModLoaderInstaller supportsAutoInstall:(A2ModLoaderType)loaderType.integerValue]) {
        [self failWithCode:A2ModPackInstallerErrorUnsupportedLoader
                   message:[NSString stringWithFormat:@"%@ 不支持自动安装，该整合包无法自动导入",
                            [A2ModLoaderAPI displayNameForType:(A2ModLoaderType)loaderType.integerValue]]];
        return;
    }

    self.plan = plan;
    self.resolvedVersionName = [self resolveVersionName:plan.name];
    [self report:A2ModPackImportStageParse progress:1
         message:[NSString stringWithFormat:@"已识别：%@", plan.name]];
    [self beginGameInstallWithLoaderType:loaderType];
}

/// 版本名：优先用调用方指定，否则用整合包名派生。
/// 去掉路径分隔符等非法字符，避免拼出跨目录的路径。
- (NSString *)resolveVersionName:(NSString *)packName {
    NSString *raw = self.request.versionName.length ? self.request.versionName
                                                    : (packName.length ? packName : @"整合包");
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?*|\"<>"];
    NSMutableString *sanitized = [NSMutableString stringWithCapacity:raw.length];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ([bad characterIsMember:c]) [sanitized appendString:@"-"];
        else [sanitized appendFormat:@"%C", c];
    }
    NSString *trimmed = [sanitized stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length ? trimmed : @"整合包";
}

#pragma mark - 2. 安装本体 + 加载器

- (void)beginGameInstallWithLoaderType:(nullable NSNumber *)loaderType {
    [self report:A2ModPackImportStageInstallGame progress:0 message:@"正在安装游戏本体与加载器…"];

    A2InstallRequest *request = [A2InstallRequest new];
    request.mcVersion = self.plan.gameVersion;
    request.versionName = self.resolvedVersionName;
    request.loaderType = loaderType;
    request.loaderVersion = [A2ModPackParser loaderVersionForIdentifier:self.plan.loaderID];
    request.gameHome = self.request.gameHome;

    A2GameInstaller *installer = [[A2GameInstaller alloc] init];
    self.gameInstaller = installer;

    __weak typeof(self) weakSelf = self;
    [installer install:request
        progress:^(A2InstallStage stage, double progress, NSString *message) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.cancelled) return;
            // 子安装器的阶段细节映射到本类的「安装本体+加载器」阶段
            [self report:A2ModPackImportStageInstallGame progress:progress message:message];
        }
        completion:^(BOOL success, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.cancelled) return;
            self.gameInstaller = nil;
            if (!success) {
                [self failWithError:[self gameInstallError:error]];
                return;
            }
            [self prepareGameDirectoryForIsolation];
        }];
}

/// 强制开启版本隔离，并把游戏目录固定在「版本文件夹」。
/// 整合包的 mods/config 只有落在这里才不会和别的整合包互相覆盖。
- (void)prepareGameDirectoryForIsolation {
    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];

    A2VersionIsolation *isolation = [A2VersionIsolation new];
    isolation.isolationType = A2SettingStateEnable;
    isolation.versionSummary = self.plan.version.length
        ? [NSString stringWithFormat:@"%@ %@", self.plan.name, self.plan.version]
        : self.plan.name;

    NSString *dataDir = [path launcherDataPath:self.resolvedVersionName];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:dataDir
                             withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) {
        [self failWithCode:A2ModPackInstallerErrorGameInstallFailed
                   message:[NSString stringWithFormat:@"无法创建版本目录：%@", error.localizedDescription]];
        return;
    }

    error = nil;
    NSData *configData = [NSJSONSerialization dataWithJSONObject:[isolation toDictionary]
                                                         options:NSJSONWritingPrettyPrinted
                                                           error:&error];
    NSString *configPath = [dataDir stringByAppendingPathComponent:@"config.json"];
    BOOL wrote = configData && [configData writeToFile:configPath options:NSDataWritingAtomic error:&error];
    if (!wrote) {
        // 隔离配置写不下去 = mods 会被落到错目录且游戏读不到，必须显式失败而不是假装成功
        [self failWithCode:A2ModPackInstallerErrorGameInstallFailed
                   message:[NSString stringWithFormat:@"无法写入版本隔离配置：%@",
                            error.localizedDescription ?: configPath]];
        return;
    }

    self.gameDirectory = [path gameDirectoryForVersion:self.resolvedVersionName isolation:isolation];
    [self downloadContent];
}

#pragma mark - 3. 下载整合包内容

- (void)downloadContent {
    NSMutableArray<A2ModPackFile *> *queue = [NSMutableArray array];
    NSUInteger unroutable = 0;
    for (A2ModPackFile *file in self.plan.files) {
        if (file.downloadURL.length > 0 && file.relativePath.length > 0) {
            [queue addObject:file];
        } else {
            // 清单里没有直链（或没给落盘路径），下不了；
            // 若是必需项，算作内容缺失。
            unroutable++;
            if (file.required) self.failedRequiredCount++;
        }
    }

    if (queue.count == 0) {
        [self report:A2ModPackImportStageDownloadContent progress:1
             message:unroutable > 0
                 ? [NSString stringWithFormat:@"跳过 %lu 个无直链文件", (unsigned long)unroutable]
                 : @"整合包无额外下载内容"];
        [self extractOverrides];
        return;
    }

    [self report:A2ModPackImportStageDownloadContent progress:0 message:@"正在下载整合包内容…"];
    [self downloadFiles:queue];
}

/// 串行下载（并发过高容易被 CDN 限流），单个失败不中断整体。
- (void)downloadFiles:(NSArray<A2ModPackFile *> *)files {
    NSUInteger total = files.count;
    __block NSUInteger index = 0;
    __block void (^next)(void) = nil;
    __weak typeof(self) weakSelf = self;

    next = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) { next = nil; return; }
        if (index >= total) {
            next = nil;                       // 打断自引用，避免循环持有
            [self extractOverrides];
            return;
        }

        A2ModPackFile *file = files[index];
        NSUInteger current = index;

        NSString *dest = A2ImportSafeJoin(self.gameDirectory, file.relativePath);
        NSURL *url = file.downloadURL.length ? [NSURL URLWithString:file.downloadURL] : nil;
        if (dest == nil || url == nil) {
            if (file.required) self.failedRequiredCount++;
            index++;
            [self report:A2ModPackImportStageDownloadContent
                progress:(double)index / (double)total
                 message:[NSString stringWithFormat:@"跳过无效条目：%@", file.relativePath]];
            if (next) next();
            return;
        }

        A2DownloadRequest *req = [A2DownloadRequest new];
        req.candidateURLs = @[url];
        req.destinationPath = dest;
        req.expectedSHA1 = file.sha1;
        req.expectedSize = file.fileSize > 0 ? file.fileSize : 0;
        // 无 SHA1 的条目（CurseForge 常见）用 zip 结构兜底校验
        req.allowZipFallbackCheck = file.sha1.length == 0;

        __block int64_t received = 0;
        [[A2DownloadEngine sharedClient] startRequest:req
            progress:^(int64_t deltaBytes, int64_t totalBytes) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || self.cancelled) { next = nil; return; }
                received += deltaBytes;
                if (received < 0) received = 0;
                double fileProgress = totalBytes > 0 ? MIN(1.0, (double)received / (double)totalBytes) : 0;
                double overall = ((double)current + fileProgress) / (double)total;
                [self report:A2ModPackImportStageDownloadContent
                    progress:overall
                     message:[NSString stringWithFormat:@"正在下载内容 (%lu/%lu)",
                              (unsigned long)(current + 1), (unsigned long)total]];
            }
            speed:nil
            completion:^(BOOL success, NSError *error) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || self.cancelled) { next = nil; return; }
                if (!success && file.required) self.failedRequiredCount++;
                index++;
                if (next) next();
            }];
    };

    next();
}

#pragma mark - 4. 解压覆盖文件

- (void)extractOverrides {
    NSString *archivePath = self.request.archivePath;
    NSString *gameDir = self.gameDirectory;
    NSString *overridesDir = self.plan.overridesDir.length ? self.plan.overridesDir : @"overrides";
    if (![overridesDir hasSuffix:@"/"]) overridesDir = [overridesDir stringByAppendingString:@"/"];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;

        A2ZipReader *zip = [[A2ZipReader alloc] initWithPath:archivePath];
        NSMutableArray<NSString *> *targets = [NSMutableArray array];
        for (NSString *name in zip.entryNames) {
            if ([name hasPrefix:overridesDir] && name.length > overridesDir.length) {
                [targets addObject:name];
            }
        }

        NSUInteger total = targets.count;
        if (total == 0) {
            [self report:A2ModPackImportStageExtractOverrides progress:1 message:@"无覆盖文件"];
            A2ImportMain(^{ [self finishImport]; });
            return;
        }

        NSUInteger index = 0;
        for (NSString *name in targets) {
            if (self.cancelled) return;
            NSString *relative = [name substringFromIndex:overridesDir.length];
            NSString *dest = A2ImportSafeJoin(gameDir, relative);
            if (dest == nil) {
                // 包内条目越界属于异常输入，直接中止并报清楚，而不是悄悄跳过
                A2ImportMain(^{
                    [self failWithCode:A2ModPackInstallerErrorPathEscape
                               message:[NSString stringWithFormat:@"覆盖文件路径越界：%@", name]];
                });
                return;
            }
            if (![zip extractEntry:name toPath:dest]) self.failedRequiredCount++;
            index++;
            // 大整合包条目多，隔一批报一次进度，避免刷爆主线程
            if (index == total || index % 20 == 0) {
                double progress = (double)index / (double)total;
                NSUInteger reporting = index;
                A2ImportMain(^{
                    [self report:A2ModPackImportStageExtractOverrides progress:progress
                         message:[NSString stringWithFormat:@"正在解压覆盖文件 (%lu/%lu)",
                                  (unsigned long)reporting, (unsigned long)total]];
                });
            }
        }

        A2ImportMain(^{ [self finishImport]; });
    });
}

#pragma mark - 收尾

- (void)finishImport {
    if (self.cancelled) return;
    [self report:A2ModPackImportStageFinalize progress:0 message:@"正在收尾…"];

    if (self.failedRequiredCount > 0) {
        NSError *error = [self errorWithCode:A2ModPackInstallerErrorIncompleteContent
                                     message:[NSString stringWithFormat:
                                              @"有 %lu 个必需文件未能写入，整合包可能不完整",
                                              (unsigned long)self.failedRequiredCount]];
        [self complete:NO error:error];
        return;
    }

    [self report:A2ModPackImportStageFinalize progress:1 message:@"导入完成"];
    [self complete:YES error:nil];
}

#pragma mark - 回调与错误

- (void)report:(A2ModPackImportStage)stage progress:(double)progress message:(NSString *)message {
    A2ImportMain(^{
        if (self.cancelled) return;
        if (self.progressBlock) {
            self.progressBlock(stage, MAX(0, MIN(1, progress)), message);
        }
    });
}

- (void)complete:(BOOL)success error:(NSError *)error {
    A2ImportMain(^{
        // 取消后一律不回调完成（项目约定：调用方以「不再收到回调」为结束信号）
        if (self.cancelled) return;
        if (self.completionBlock) self.completionBlock(success, self.resolvedVersionName, error);
    });
}

- (void)failWithCode:(A2ModPackInstallerError)code message:(NSString *)message {
    [self failWithError:[self errorWithCode:code message:message]];
}

- (void)failWithError:(NSError *)error {
    [self complete:NO error:error];
}

- (NSError *)gameInstallError:(NSError *)underlying {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = underlying.localizedDescription ?: @"游戏本体安装失败";
    if (underlying) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:A2ModPackInstallerErrorDomain
                               code:A2ModPackInstallerErrorGameInstallFailed
                           userInfo:userInfo];
}

- (NSError *)errorWithCode:(A2ModPackInstallerError)code message:(NSString *)message {
    return [NSError errorWithDomain:A2ModPackInstallerErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
