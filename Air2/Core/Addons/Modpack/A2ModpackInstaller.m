//
//  A2ModpackInstaller.m
//  Air2
//

#import "A2ModpackInstaller.h"
#import "A2ModpackModels.h"
#import "A2ModpackParser.h"
#import "A2ModpackFileDownloader.h"
#import "A2CurseForgeAPI.h"
#import "A2ZipReader.h"
#import "A2ZipExtractor.h"
#import "A2DownloadEngine.h"
#import "A2GameInstaller.h"
#import "A2VersionIsolation.h"

static void A2ModpackMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

/// 安装过程的临时目录，全部落在 Caches 下，结束时整体删除
static NSString *A2ModpackTempRoot(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"A2Modpack"];
}

/// 把 source 目录内容递归复制进 destination，同名覆盖。
/// 用于收尾阶段把临时版本目录合并进正式版本目录。
static BOOL A2ModpackCopyDirectoryContents(NSString *source, NSString *destination, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:nil];

    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:source];
    for (NSString *relative in enumerator) {
        NSString *srcPath = [source stringByAppendingPathComponent:relative];
        NSString *dstPath = [destination stringByAppendingPathComponent:relative];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:srcPath isDirectory:&isDir]) continue;

        if (isDir) {
            [fm createDirectoryAtPath:dstPath withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }
        [fm createDirectoryAtPath:dstPath.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
        if ([fm fileExistsAtPath:dstPath]) [fm removeItemAtPath:dstPath error:nil];
        if (![fm copyItemAtPath:srcPath toPath:dstPath error:error]) return NO;
    }
    return YES;
}

@interface A2ModpackInstaller ()
@property (nonatomic, strong, nullable) A2ModpackInstallRequest *request;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, copy, nullable) void (^progressBlock)(A2ModpackInstallStage, double, NSString *);
@property (nonatomic, copy, nullable) void (^completionBlock)(BOOL, NSError *);

@property (nonatomic, copy, nullable) NSString *tempRoot;
@property (nonatomic, copy, nullable) NSString *packRoot;
@property (nonatomic, copy, nullable) NSString *fkRoot;
@property (nonatomic, copy, nullable) NSString *zipPath;

@property (nonatomic, strong, nullable) A2ModpackInfo *info;
@property (nonatomic, strong, nullable) A2ModpackFileDownloader *downloader;
@property (nonatomic, strong, nullable) A2GameInstaller *gameInstaller;
@property (nonatomic, strong, nullable) A2DownloadOperation *packOperation;
@property (nonatomic, strong, nullable) A2DownloadOperation *iconOperation;
@property (nonatomic, assign) int64_t receivedBytes;
@end

@implementation A2ModpackInstaller

#pragma mark - 入口

- (void)install:(A2ModpackInstallRequest *)request
       progress:(void (^)(A2ModpackInstallStage, double, NSString *))progress
     completion:(void (^)(BOOL, NSError *))completion {

    self.request = request;
    self.progressBlock = progress;
    self.completionBlock = completion;
    self.cancelled = NO;

    if (request.gameHome.length == 0) {
        [self failWithMessage:@"缺少游戏目录"];
        return;
    }
    if (request.packURL.length == 0 && request.localPackPath.length == 0) {
        [self failWithMessage:@"缺少整合包来源"];
        return;
    }

    self.tempRoot = A2ModpackTempRoot();
    self.packRoot = [self.tempRoot stringByAppendingPathComponent:@"pack"];
    self.fkRoot = [self.tempRoot stringByAppendingPathComponent:@"fkVersion"];
    self.zipPath = [self.tempRoot stringByAppendingPathComponent:@"installer.zip"];
    [self clearTemp];
}

- (void)cancel {
    self.cancelled = YES;
    [self.downloader cancel];
    [self.gameInstaller cancel];
    A2DownloadEngine *engine = [A2DownloadEngine sharedClient];
    if (self.packOperation) [engine cancelOperation:self.packOperation];
    if (self.iconOperation) [engine cancelOperation:self.iconOperation];
}

#pragma mark - 1. 清理临时目录

- (void)clearTemp {
    [self report:A2ModpackInstallStageClearTemp progress:0 message:@"正在准备…"];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:self.tempRoot error:nil];
    [fm createDirectoryAtPath:self.packRoot withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:self.fkRoot withIntermediateDirectories:YES attributes:nil error:nil];
    [self report:A2ModpackInstallStageClearTemp progress:1 message:@"准备完成"];
    [self obtainPack];
}

#pragma mark - 2. 下载或导入整合包

- (void)obtainPack {
    if (self.request.localPackPath.length > 0) {
        [self report:A2ModpackInstallStageDownloadPack progress:0 message:@"正在导入本地整合包…"];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:self.zipPath error:nil];
        NSError *error = nil;
        if (![fm copyItemAtPath:self.request.localPackPath toPath:self.zipPath error:&error]) {
            [self failWithError:error ?: [self errorWithMessage:@"导入本地整合包失败"]];
            return;
        }
        [self report:A2ModpackInstallStageDownloadPack progress:1 message:@"导入完成"];
        [self extractPack];
        return;
    }

    [self report:A2ModpackInstallStageDownloadPack progress:0 message:@"正在下载整合包…"];
    A2DownloadRequest *req = [A2DownloadRequest new];
    req.candidateURLs = @[[NSURL URLWithString:self.request.packURL]];
    req.destinationPath = self.zipPath;
    req.expectedSHA1 = self.request.packSHA1;
    req.expectedSize = self.request.packSize;
    req.allowZipFallbackCheck = self.request.packSHA1.length == 0;

    __weak typeof(self) weakSelf = self;
    A2DownloadOperation *op = [[A2DownloadEngine sharedClient] startRequest:req
        progress:^(int64_t delta, int64_t total) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled || total <= 0) return;
        self.receivedBytes += delta;
        if (self.receivedBytes < 0) self.receivedBytes = 0;
        double p = MIN(1.0, (double)self.receivedBytes / (double)total);
        [self report:A2ModpackInstallStageDownloadPack progress:p message:@"正在下载整合包…"];
    }
        speed:nil
        completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;
        if (!success) { [self failWithError:error]; return; }
        [self report:A2ModpackInstallStageDownloadPack progress:1 message:@"下载完成"];
        [self extractPack];
    }];
    self.packOperation = op;
}

#pragma mark - 3. 解压

- (void)extractPack {
    [self report:A2ModpackInstallStageExtractPack progress:0 message:@"正在解压整合包…"];
    A2ZipReader *reader = [[A2ZipReader alloc] initWithPath:self.zipPath];
    if (!reader) {
        [self failWithMessage:@"无法读取整合包，文件可能已损坏"];
        return;
    }
    A2ZipExtractor *extractor = [A2ZipExtractor extractorWithReader:reader];
    __weak typeof(self) weakSelf = self;
    NSError *error = nil;
    if (![extractor extractToDirectory:self.packRoot
                           entryPrefix:nil
                             overwrite:YES
                              progress:^(NSUInteger completed, NSUInteger total) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled || total == 0) return;
        [self report:A2ModpackInstallStageExtractPack progress:(double)completed / (double)total
             message:@"正在解压整合包…"];
    } error:&error]) {
        [self failWithError:error ?: [self errorWithMessage:@"解压整合包失败"]];
        return;
    }
    [self report:A2ModpackInstallStageExtractPack progress:1 message:@"解压完成"];
    [self parsePack];
}

#pragma mark - 4. 识别格式

- (void)parsePack {
    [self report:A2ModpackInstallStageParsePack progress:0 message:@"正在识别整合包…"];
    NSError *error = nil;
    A2ModpackInfo *info = [A2ModpackParser parseExtractedPackAtRoot:self.packRoot error:&error];
    if (!info) {
        [self failWithError:error ?: [self errorWithMessage:@"无法识别整合包格式"]];
        return;
    }
    self.info = info;
    if (self.request.versionName.length == 0) {
        self.request.versionName = info.name.length > 0 ? info.name : @"整合包";
    }
    [self report:A2ModpackInstallStageParsePack progress:1
         message:[NSString stringWithFormat:@"已识别：%@", A2ModpackFormatDisplayName(info.format)]];
    [self extractOverrides];
}

#pragma mark - 5. overrides 铺盘

- (void)extractOverrides {
    NSArray<NSString *> *directories = self.info.overrideDirectories;
    if (directories.count == 0) {
        [self report:A2ModpackInstallStageExtractOverrides progress:1 message:@"整合包无 overrides"];
        [self resolveModFiles];
        return;
    }

    A2ZipReader *reader = [[A2ZipReader alloc] initWithPath:self.zipPath];
    if (!reader) {
        [self failWithMessage:@"无法读取整合包，文件可能已损坏"];
        return;
    }
    A2ZipExtractor *extractor = [A2ZipExtractor extractorWithReader:reader];

    NSUInteger index = 0;
    for (NSString *directory in directories) {
        if (self.cancelled) return;
        // 包内是 overrides/mods/x.jar，落到游戏目录要变成 mods/x.jar，
        // extractor 会在写盘时剥掉这个前缀
        NSString *prefix = [directory stringByAppendingString:@"/"];
        NSError *error = nil;
        if (![extractor extractToDirectory:self.fkRoot
                               entryPrefix:prefix
                                 overwrite:YES
                                  progress:nil
                                     error:&error]) {
            [self failWithError:error ?: [self errorWithMessage:@"铺开 overrides 失败"]];
            return;
        }
        index++;
        [self report:A2ModpackInstallStageExtractOverrides
            progress:(double)index / (double)directories.count
             message:[NSString stringWithFormat:@"正在铺开 %@…", directory]];
    }
    [self resolveModFiles];
}

#pragma mark - 6. 下载模组文件

/// CurseForge 清单只给 projectID/fileID，先联网补齐直链、文件名与落盘目录
- (void)resolveModFiles {
    NSMutableArray<NSNumber *> *fileIDs = [NSMutableArray array];
    NSMutableArray<NSNumber *> *projectIDs = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seenProjects = [NSMutableSet set];

    for (A2ModpackFile *file in self.info.files) {
        if (!file.requiresCurseForgeLookup) continue;
        [fileIDs addObject:@(file.curseForgeFileID)];
        NSNumber *projectID = @(file.curseForgeProjectID);
        if (![seenProjects containsObject:projectID]) {
            [seenProjects addObject:projectID];
            [projectIDs addObject:projectID];
        }
    }

    if (fileIDs.count == 0) {
        [self downloadModFiles];
        return;
    }

    [self report:A2ModpackInstallStageDownloadMods progress:0 message:@"正在解析 CurseForge 文件…"];
    __weak typeof(self) weakSelf = self;
    [[A2CurseForgeAPI shared] fileDetailsForFileIDs:fileIDs
        completion:^(NSArray<A2CurseForgeFile *> *detailFiles, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;
        if (error) { [self failWithError:error]; return; }

        [[A2CurseForgeAPI shared] classIDsForProjectIDs:projectIDs
            completion:^(NSDictionary<NSNumber *, NSNumber *> *classIDs, NSError *projectError) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.cancelled) return;
            // 分类查不到不算致命，落盘目录退回 mods
            NSDictionary<NSNumber *, NSNumber *> *map = projectError ? @{} : (classIDs ?: @{});
            [self applyCurseForgeDetails:detailFiles classIDs:map];
            [self downloadModFiles];
        }];
    }];
}

- (void)applyCurseForgeDetails:(NSArray<A2CurseForgeFile *> *)detailFiles
                      classIDs:(NSDictionary<NSNumber *, NSNumber *> *)classIDs {
    NSMutableDictionary<NSNumber *, A2CurseForgeFile *> *byFileID = [NSMutableDictionary dictionary];
    for (A2CurseForgeFile *detail in detailFiles) {
        if (detail.fileID > 0) byFileID[@(detail.fileID)] = detail;
    }

    for (A2ModpackFile *file in self.info.files) {
        if (!file.requiresCurseForgeLookup) continue;
        A2CurseForgeFile *detail = byFileID[@(file.curseForgeFileID)];
        if (!detail) continue;

        NSString *fileName = detail.fileName.length > 0 ? detail.fileName : detail.displayName;
        if (fileName.length == 0) continue;

        NSNumber *classID = classIDs[@(file.curseForgeProjectID)];
        NSString *subdir = [A2CurseForgeAPI directoryForClassID:classID ? classID.integerValue : 0];
        file.relativePath = [subdir stringByAppendingPathComponent:fileName];
        file.downloadURLs = detail.downloadURL.length > 0 ? @[detail.downloadURL] : @[];
        file.sha1 = detail.sha1;
        file.size = detail.fileLength;
    }
}

- (void)downloadModFiles {
    NSArray<A2ModpackFile *> *files = self.info.files;
    if (files.count == 0) {
        [self report:A2ModpackInstallStageDownloadMods progress:1 message:@"无需下载模组文件"];
        [self installGame];
        return;
    }

    [self report:A2ModpackInstallStageDownloadMods progress:0 message:@"正在下载模组文件…"];
    A2ModpackFileDownloader *downloader = [[A2ModpackFileDownloader alloc] initWithConcurrency:4];
    self.downloader = downloader;

    __weak typeof(self) weakSelf = self;
    [downloader downloadFiles:files
                       toRoot:self.fkRoot
                     progress:^(NSInteger completed, NSInteger total, NSString *message) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled || total == 0) return;
        [self report:A2ModpackInstallStageDownloadMods
            progress:(double)completed / (double)total
             message:message];
    }
                   completion:^(NSArray<NSString *> *failures) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;
        self.downloader = nil;
        if (failures.count > 0) {
            [self failWithMessage:[NSString stringWithFormat:@"有 %lu 个文件下载失败：%@",
                                   (unsigned long)failures.count,
                                   [failures componentsJoinedByString:@"；"]]];
            return;
        }
        [self installGame];
    }];
}

#pragma mark - 7. 安装游戏本体与加载器

- (void)installGame {
    NSString *mcVersion = self.info.gameVersion;
    if (mcVersion.length == 0) {
        [self failWithMessage:@"整合包未声明游戏版本，无法安装"];
        return;
    }
    [self report:A2ModpackInstallStageInstallGame progress:0 message:@"正在安装游戏与加载器…"];

    A2InstallRequest *req = [A2InstallRequest new];
    req.mcVersion = mcVersion;
    req.versionName = self.request.versionName;
    req.loaderType = self.info.loaderType;
    req.loaderVersion = self.info.loaderVersion;
    req.gameHome = self.request.gameHome;

    A2GameInstaller *installer = [[A2GameInstaller alloc] init];
    self.gameInstaller = installer;

    __weak typeof(self) weakSelf = self;
    [installer install:req
        progress:^(A2InstallStage stage, double p, NSString *message) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;
        // 本体安装内部的阶段也映射到「安装游戏」这一段
        double overall = ((double)stage + p) / (double)A2InstallStageCount;
        [self report:A2ModpackInstallStageInstallGame progress:MIN(0.99, overall) message:message];
    }
        completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;
        self.gameInstaller = nil;
        if (!success) { [self failWithError:error]; return; }
        [self finalize];
    }];
}

#pragma mark - 8. 收尾

- (void)finalize {
    [self report:A2ModpackInstallStageFinalize progress:0 message:@"正在收尾…"];

    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    NSString *versionDir = [path versionPath:self.request.versionName];
    NSError *error = nil;
    if (!A2ModpackCopyDirectoryContents(self.fkRoot, versionDir, &error)) {
        [self failWithError:error ?: [self errorWithMessage:@"写入版本目录失败"]];
        return;
    }
    [self writeVersionConfig];
    [self downloadIconThenFinish];
}

/// 版本配置：强制版本隔离，并把整合包的摘要与推荐内存写进去
- (void)writeVersionConfig {
    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    NSString *dir = [path launcherDataPath:self.request.versionName];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *configPath = [dir stringByAppendingPathComponent:@"config.json"];

    A2VersionIsolation *iso = nil;
    NSData *existing = [NSData dataWithContentsOfFile:configPath];
    if (existing.length > 0) {
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:existing options:0 error:nil];
        if ([dict isKindOfClass:NSDictionary.class]) iso = [A2VersionIsolation fromDictionary:dict];
    }
    if (!iso) iso = [A2VersionIsolation new];

    // 整合包必须版本隔离：overrides 与 mods 都落在版本目录下
    iso.isolationType = A2SettingStateEnable;
    if (self.info.summary.length > 0) iso.versionSummary = self.info.summary;
    if (self.info.recommendedRAM > 0) iso.ramAllocation = self.info.recommendedRAM;

    NSData *data = [NSJSONSerialization dataWithJSONObject:[iso toDictionary]
                                                   options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:configPath atomically:YES];
}

- (void)downloadIconThenFinish {
    NSString *iconURL = self.request.iconURL;
    if (iconURL.length == 0) {
        [self finishSuccess];
        return;
    }

    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    A2DownloadRequest *req = [A2DownloadRequest new];
    req.candidateURLs = @[[NSURL URLWithString:iconURL]];
    req.destinationPath = [path versionIconPath:self.request.versionName];

    __weak typeof(self) weakSelf = self;
    A2DownloadOperation *op = [[A2DownloadEngine sharedClient] startRequest:req
        progress:nil speed:nil
        completion:^(BOOL success, NSError *error) {
        // 图标只是点缀，拿不到不影响安装
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self finishSuccess];
    }];
    self.iconOperation = op;
}

- (void)finishSuccess {
    A2ModpackMain(^{
        [NSFileManager.defaultManager removeItemAtPath:self.tempRoot error:nil];
        [self report:A2ModpackInstallStageFinalize progress:1 message:@"安装完成"];
        if (self.completionBlock) self.completionBlock(YES, nil);
    });
}

#pragma mark - 回调

- (void)report:(A2ModpackInstallStage)stage progress:(double)progress message:(NSString *)message {
    A2ModpackMain(^{
        if (self.progressBlock) {
            self.progressBlock(stage, MAX(0, MIN(1, progress)), message);
        }
    });
}

- (NSError *)errorWithMessage:(NSString *)message {
    return [NSError errorWithDomain:@"A2ModpackInstaller" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (void)failWithMessage:(NSString *)message {
    [self failWithError:[self errorWithMessage:message]];
}

- (void)failWithError:(NSError *)error {
    [NSFileManager.defaultManager removeItemAtPath:self.tempRoot error:nil];
    A2ModpackMain(^{
        if (self.completionBlock) self.completionBlock(NO, error);
    });
}

@end
