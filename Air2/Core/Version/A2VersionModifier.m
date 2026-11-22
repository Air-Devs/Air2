//
//  A2VersionModifier.m
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
//
//  A2VersionModifier.m
//  Air2
//
//  对照 ZL2：
//    · GameInstaller.kt  modifyVersion()             —— 入口与「不许并发」语义
//    · GameInstaller.kt  getModifyTaskPhase()        —— 阶段顺序
//    · GameInstaller.kt  createVersionModifiedTask() —— 先写临时目录再换
//    · GameInstaller.kt  swapVersionFiles()          —— 备份/替换/失败还原
//    · GameInstaller.kt  clearTempGameDir()          —— 无论成败都清临时目录
//
//  与 ZL2 的**行为差异**（逐条给出理由）：
//    1. ZL2 的临时目录是全局单例（PathManager.DIR_CACHE_GAME_DOWNLOADER），
//       并靠 taskExecutor.isRunning() 拒绝并发安装。
//       Air2 这里给每次修改一个独立 UUID 子目录 —— 我们不依赖任务流锁，
//       独立目录让「两个版本同时改」也不会互相踩临时文件。
//    2. ZL2 在 modify 时把原版 jar/json 也重新下载一遍（保证基底干净）。
//       Air2 不重下：原版已经在盘上，客户端 jar 动辄几十 MB，
//       重下既慢又费流量。改为**只检查存在性**（缺了就明确报错让用户先修复），
//       这也是本任务「不重装整个游戏」的要求。
//    3. ZL2 用 FileUtils.moveFile；Air2 用 NSFileManager 的 rename 语义，
//       并在换入前把新文件**先搬到目标目录的同卷临时名**，
//       跨卷复制被排除在关键区间之外（否则「搬到一半被杀」会留下半个文件）。
//    4. 额外加了 journal（.a2_modify_journal.json）：
//       ZL2 只靠内存中的备份判断，进程被杀后无法自愈。
//       这里把新 json 的 SHA1 写进 journal，下次能明确区分
//       「替换已完成」与「替换被中断」。
//

#import "A2VersionModifier.h"
#import "A2ModLoaderInstaller.h"
#import "A2VersionIsolation.h"
#import "A2IntegrityChecker.h"
#import "A2Logger.h"

#pragma mark - 常量

static NSString *const kJournalFileName = @".a2_modify_journal.json";
static NSString *const kErrorDomain     = @"A2VersionModifier";
static NSString *const kStagingDirName  = @"A2VersionModify";

/// 临时后缀。都放在目标版本目录里，保证 rename 是同卷原子操作。
static NSString *const kNewSuffix = @".a2new";
static NSString *const kBakSuffix = @".a2bak";

typedef NS_ENUM(NSInteger, A2ModifyErrorCode) {
    A2ModifyErrorInvalidRequest = 1,
    A2ModifyErrorVersionMissing,
    A2ModifyErrorUnsupportedLoader,
    A2ModifyErrorBaseIncomplete,
    A2ModifyErrorStagingFailed,
    A2ModifyErrorLoaderInstallFailed,
    A2ModifyErrorMergeFailed,
    A2ModifyErrorSwapFailed,
    A2ModifyErrorNoLoaderVersions,
    A2ModifyErrorCancelled,
};

NSString *A2VersionModifyStageName(A2VersionModifyStage stage) {
    switch (stage) {
        case A2VersionModifyStagePrepare:        return @"准备";
        case A2VersionModifyStageResolveLoader:  return @"查询加载器";
        case A2VersionModifyStageInstallLoader:  return @"安装加载器";
        case A2VersionModifyStageMergeLibraries: return @"合并依赖库";
        case A2VersionModifyStageSwapFiles:      return @"替换版本文件";
        case A2VersionModifyStageFinalize:       return @"收尾";
        case A2VersionModifyStageCount:          break;
    }
    return @"未知";
}

#pragma mark - 小工具

static void A2Main(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static NSError *A2ModifyError(A2ModifyErrorCode code, NSString *message) {
    return [NSError errorWithDomain:kErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

static BOOL A2HasValue(id value) {
    return value != nil && ![value isKindOfClass:NSNull.class];
}

/// 安全读 json（读不出 / 不是字典都返回 nil）
static NSDictionary *A2ReadJSONDictionary(NSString *path) {
    if (path.length == 0) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static BOOL A2WriteJSONDictionary(NSString *path, NSDictionary *json, NSError **error) {
    NSError *serializeError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:json
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&serializeError];
    if (!data) {
        if (error) {
            *error = A2ModifyError(A2ModifyErrorSwapFailed,
                                   [NSString stringWithFormat:@"序列化 JSON 失败：%@",
                                    serializeError.localizedDescription ?: @""]);
        }
        return NO;
    }
    if ([data writeToFile:path atomically:YES]) return YES;
    if (error) *error = A2ModifyError(A2ModifyErrorSwapFailed, @"写入版本 json 失败");
    return NO;
}

static BOOL A2RemoveIfExists(NSString *path) {
    if (path.length == 0) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) return YES;
    NSError *error = nil;
    if ([fm removeItemAtPath:path error:&error]) return YES;
    [A2Logger warning:@"VersionModifier"
              message:[NSString stringWithFormat:@"删除失败 %@：%@",
                       path, error.localizedDescription ?: @""]];
    return NO;
}

/// 移动并覆盖目标（rename 语义；跨卷时系统会自动复制+删除）
static BOOL A2MoveReplacing(NSString *from, NSString *to, NSError **error) {
    if (from.length == 0 || to.length == 0) {
        if (error) *error = A2ModifyError(A2ModifyErrorSwapFailed, @"路径为空");
        return NO;
    }
    A2RemoveIfExists(to);
    return [NSFileManager.defaultManager moveItemAtPath:from toPath:to error:error];
}

static NSString *A2JournalPath(NSString *versionDir) {
    return [versionDir stringByAppendingPathComponent:kJournalFileName];
}

static NSDictionary *A2ReadJournal(NSString *versionDir) {
    NSDictionary *json = A2ReadJSONDictionary(A2JournalPath(versionDir));
    return json;
}

/// 库条目的唯一键：优先 name，其次 artifact.path
static NSString *A2LibraryKey(id lib) {
    if (![lib isKindOfClass:NSDictionary.class]) return nil;
    id name = lib[@"name"];
    if ([name isKindOfClass:NSString.class] && [name length] > 0) return name;

    id downloads = lib[@"downloads"];
    if (![downloads isKindOfClass:NSDictionary.class]) return nil;
    id artifact = ((NSDictionary *)downloads)[@"artifact"];
    if (![artifact isKindOfClass:NSDictionary.class]) return nil;
    id path = ((NSDictionary *)artifact)[@"path"];
    if ([path isKindOfClass:NSString.class] && [path length] > 0) return path;
    return nil;
}

/// 合并 libraries：父在前，子层同名项覆盖父层（对照 ZL2 mergeProfile 的 libs 合并）
static NSArray *A2MergeLibraries(NSArray *parent, NSArray *child) {
    NSMutableSet<NSString *> *childKeys = [NSMutableSet set];
    for (id lib in child) {
        NSString *key = A2LibraryKey(lib);
        if (key.length) [childKeys addObject:key];
    }

    NSMutableArray *out = [NSMutableArray array];
    for (id lib in parent) {
        NSString *key = A2LibraryKey(lib);
        if (key.length && [childKeys containsObject:key]) continue;  // 子层覆盖
        [out addObject:lib];
    }
    [out addObjectsFromArray:child];
    return out;
}

/// 把「基底原版 json」与「加载器 json」内联合并成一份自包含 json。
///
/// 只在「目标版本名 == 基底原版版本名」时使用。
/// 不这么做的话产物会写成 inheritsFrom 指向自己 —— 启动必崩。
///
/// 规则（逐条对齐 ZL2 的 mergeGameJson）：
///   · 基底为底，加载器层的标量键覆盖基底
///   · libraries 父在前、同名子覆盖
///   · arguments.game / arguments.jvm 拼接（父在前，子在后）
///   · minecraftArguments（老字段）子层有就用子层
///   · id 强制改写为目标版本名，inheritsFrom 删除
static NSMutableDictionary *A2InlineMergeVersionJSON(NSDictionary *root,
                                                     NSDictionary *child,
                                                     NSString *targetID) {
    NSMutableDictionary *merged = root ? [root mutableCopy] : [NSMutableDictionary dictionary];

    for (NSString *key in child) {
        if ([key isEqualToString:@"libraries"]) continue;
        if ([key isEqualToString:@"arguments"]) continue;
        if ([key isEqualToString:@"inheritsFrom"]) continue;
        if ([key isEqualToString:@"id"]) continue;
        merged[key] = child[key];
    }
    merged[@"id"] = targetID;
    [merged removeObjectForKey:@"inheritsFrom"];

    // ---- libraries ----
    NSArray *rootLibs = [root[@"libraries"] isKindOfClass:NSArray.class] ? root[@"libraries"] : @[];
    NSArray *childLibs = [child[@"libraries"] isKindOfClass:NSArray.class] ? child[@"libraries"] : @[];
    merged[@"libraries"] = A2MergeLibraries(rootLibs, childLibs);

    // ---- arguments ----
    NSDictionary *rootArgs = [root[@"arguments"] isKindOfClass:NSDictionary.class]
                                ? root[@"arguments"] : @{};
    NSDictionary *childArgs = [child[@"arguments"] isKindOfClass:NSDictionary.class]
                                ? child[@"arguments"] : @{};
    if (rootArgs.count > 0 || childArgs.count > 0) {
        NSMutableDictionary *args = [rootArgs mutableCopy] ?: [NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithObjects:@"game", @"jvm", nil];
        for (NSString *key in childArgs) {
            if (![keys containsObject:key]) [keys addObject:key];
        }
        for (NSString *key in keys) {
            id a = rootArgs[key];
            id b = childArgs[key];
            NSMutableArray *combined = [NSMutableArray array];
            if ([a isKindOfClass:NSArray.class]) [combined addObjectsFromArray:a];
            if ([b isKindOfClass:NSArray.class]) [combined addObjectsFromArray:b];
            if (combined.count > 0) args[key] = combined;
        }
        merged[@"arguments"] = args;
    }

    // ---- 老版本启动参数 ----
    if (A2HasValue(child[@"minecraftArguments"])) {
        merged[@"minecraftArguments"] = child[@"minecraftArguments"];
    }

    return merged;
}

#pragma mark - 请求

@implementation A2VersionModifyRequest

- (instancetype)init {
    self = [super init];
    if (self) {
        // 默认 Unknown：忘记赋值的请求会在入口校验里被明确拒绝，
        // 而不是「当作 Fabric 试一把」。
        _loaderType = A2ModLoaderTypeUnknown;
    }
    return self;
}

@end

#pragma mark - 修改器

@interface A2VersionModifier ()

/// 串行队列：所有阶段推进都在它上面，避免回调来自不同线程时状态互相踩
@property (nonatomic, strong) dispatch_queue_t workQueue;

@property (nonatomic, strong, nullable) A2VersionModifyRequest *request;
@property (nonatomic, copy, nullable) void (^progressBlock)(A2VersionModifyStage, double, NSString *);
@property (nonatomic, copy, nullable) void (^completionBlock)(BOOL, NSError * _Nullable);

/// 加载器安装器必须由属性持有 —— 局部变量会被 ARC 提前放掉，
/// 异步回调永远不来（表现为「进度停在 10%」）。
@property (nonatomic, strong, nullable) A2ModLoaderInstaller *activeLoaderInstaller;

@property (nonatomic, copy, nullable) NSString *stagingRoot;
@property (nonatomic, copy, nullable) NSString *stagingHome;
/// 基底原版版本名（继承链根）
@property (nonatomic, copy, nullable) NSString *baseVersionName;
/// 目标版本 == 基底原版（纯原版加加载器，产物必须内联合并）
@property (nonatomic, assign) BOOL inPlaceVanilla;

/// 自持有。
/// 调用方常写成 [[A2VersionModifier new] modifyVersion:...]，
/// 我们一返回对象就没了，加载器安装的回调永远不会来。
/// 流程期间持有自己，finishSuccess / finishFailure 里置 nil。
/// 这是**故意的**所有权环，所有退出路径都必须经过那两个方法。
@property (nonatomic, strong, nullable) A2VersionModifier *selfRetain;

/// 完成只允许触发一次
@property (nonatomic, assign) BOOL finished;
@property (atomic, assign) BOOL cancelled;

@end

@implementation A2VersionModifier

- (instancetype)init {
    self = [super init];
    if (self) {
        _workQueue = dispatch_queue_create("dev.airdevs.air2.versionmodify",
                                           DISPATCH_QUEUE_SERIAL);
        _finished = NO;
        _cancelled = NO;
    }
    return self;
}

#pragma mark 入口

- (void)modifyVersion:(A2VersionModifyRequest *)request
             progress:(void (^)(A2VersionModifyStage, double, NSString *))progress
           completion:(void (^)(BOOL, NSError * _Nullable))completion {

    self.request = request;
    self.progressBlock = progress;
    self.completionBlock = completion;
    self.finished = NO;
    self.cancelled = NO;
    self.selfRetain = self;

    // 同步参数校验 —— 明显错的不必排到队列里再报
    if (request.versionName.length == 0 || request.gameHome.length == 0) {
        [self finishFailure:A2ModifyError(A2ModifyErrorInvalidRequest, @"参数不完整")];
        return;
    }
    if (!A2ModLoaderIsLoader(request.loaderType)) {
        [self finishFailure:A2ModifyError(A2ModifyErrorUnsupportedLoader,
                                          @"请选择加载器类型（前置模组不适用）")];
        return;
    }
    if (![A2ModLoaderInstaller supportsAutoInstall:request.loaderType]) {
        [self finishFailure:A2ModifyError(A2ModifyErrorUnsupportedLoader,
                                          [NSString stringWithFormat:
                                           @"%@ 不支持自动安装，只能手动装",
                                           [A2ModLoaderAPI displayNameForType:request.loaderType]])];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.workQueue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (self.cancelled) {
            [self finishFailure:A2ModifyError(A2ModifyErrorCancelled, @"已取消")];
            return;
        }

        [self report:A2VersionModifyStagePrepare fraction:0 message:@"正在检查版本…"];

        NSError *error = nil;
        if (![self prepareStaging:&error]) {
            [self finishFailure:error];
            return;
        }
        [self report:A2VersionModifyStagePrepare fraction:1 message:@"临时目录已就绪"];
        [self resolveLoader];
    });
}

- (void)cancel {
    self.cancelled = YES;
    [A2Logger info:@"VersionModifier" message:@"收到取消请求"];
}

#pragma mark 1. 准备

- (BOOL)prepareStaging:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    A2GamePath *path = [A2GamePath pathWithGameHome:self.request.gameHome];
    NSString *target = self.request.versionName;

    // 1.1 目标版本必须已安装
    NSString *targetJSON = [path versionJSONPath:target];
    if (![fm fileExistsAtPath:targetJSON]) {
        if (error) *error = A2ModifyError(A2ModifyErrorVersionMissing,
                                          [NSString stringWithFormat:@"版本 %@ 尚未安装", target]);
        return NO;
    }

    // 1.2 先自愈上一次被中断的替换。
    //     这一步必须在动任何文件之前做 —— 否则可能在一个「半个 json」的版本上开工。
    NSError *recoverError = nil;
    if (![A2VersionModifier recoverInterruptedModifyForVersion:target
                                                      gameHome:self.request.gameHome
                                                         error:&recoverError]) {
        if (error) *error = recoverError;
        return NO;
    }

    // 1.3 解析继承链，拿基底原版
    BOOL chainBroken = NO;
    NSArray<NSString *> *chain =
        [A2IntegrityChecker resolvedVersionChainFor:target
                                           gameHome:self.request.gameHome
                                             broken:&chainBroken];
    if (chainBroken || chain.count == 0) {
        if (error) *error = A2ModifyError(A2ModifyErrorVersionMissing,
                                          @"版本继承链不完整（缺父版本或 json 损坏），请先修复");
        return NO;
    }

    self.baseVersionName = chain.lastObject;
    self.inPlaceVanilla = (chain.count == 1 && [self.baseVersionName isEqualToString:target]);

    // 1.4 基底原版的 json 与 jar 必须齐 —— 加载器叠在它上面
    NSString *baseJSON = [path versionJSONPath:self.baseVersionName];
    NSString *baseJar = [path versionJarPath:self.baseVersionName];
    if (![fm fileExistsAtPath:baseJSON] || ![fm fileExistsAtPath:baseJar]) {
        if (error) *error = A2ModifyError(
            A2ModifyErrorBaseIncomplete,
            [NSString stringWithFormat:@"原版 %@ 不完整（缺 json 或客户端 jar），请先修复",
             self.baseVersionName]);
        return NO;
    }

    // 1.5 建临时 gameHome：A2ModLoaderInstaller 只认 versions/<mc>/ 这一份原版
    NSURL *cachesURL = [fm URLsForDirectory:NSCachesDirectory
                                  inDomains:NSUserDomainMask].firstObject;
    NSString *caches = cachesURL.path;
    if (caches.length == 0) {
        if (error) *error = A2ModifyError(A2ModifyErrorStagingFailed, @"取不到缓存目录");
        return NO;
    }

    NSString *root = [caches stringByAppendingPathComponent:kStagingDirName];
    root = [root stringByAppendingPathComponent:
            [[NSUUID UUID] UUIDString]];
    self.stagingRoot = root;
    self.stagingHome = [root stringByAppendingPathComponent:@"home"];

    A2GamePath *stagingPath = [A2GamePath pathWithGameHome:self.stagingHome];
    NSString *stagingVersionDir = [stagingPath versionPath:self.baseVersionName];
    if (![fm createDirectoryAtPath:stagingVersionDir
       withIntermediateDirectories:YES attributes:nil error:error]) {
        if (error && *error == nil) {
            *error = A2ModifyError(A2ModifyErrorStagingFailed, @"创建临时目录失败");
        }
        return NO;
    }

    // 复制基底 json（小文件，直接复制）
    if (![fm copyItemAtPath:baseJSON
                     toPath:[stagingPath versionJSONPath:self.baseVersionName]
                      error:error]) {
        if (error && *error == nil) {
            *error = A2ModifyError(A2ModifyErrorStagingFailed, @"复制原版 json 失败");
        }
        return NO;
    }

    // jar 优先硬链接（省磁盘），失败退回复制
    NSString *stagedJar = [stagingPath versionJarPath:self.baseVersionName];
    NSError *linkError = nil;
    if (![fm linkItemAtPath:baseJar toPath:stagedJar error:&linkError]) {
        if (![fm copyItemAtPath:baseJar toPath:stagedJar error:error]) {
            if (error && *error == nil) {
                *error = A2ModifyError(A2ModifyErrorStagingFailed, @"复制原版 jar 失败");
            }
            return NO;
        }
    }

    [A2Logger info:@"VersionModifier"
           message:[NSString stringWithFormat:
                    @"%@：基底=%@，就地合并=%@，临时目录=%@",
                    target, self.baseVersionName,
                    self.inPlaceVanilla ? @"是" : @"否", root]];
    return YES;
}

#pragma mark 2. 查加载器版本

- (void)resolveLoader {
    if (self.cancelled) {
        [self finishFailure:A2ModifyError(A2ModifyErrorCancelled, @"已取消")];
        return;
    }

    [self report:A2VersionModifyStageResolveLoader fraction:0 message:@"正在查询加载器版本…"];

    A2ModLoaderType type = self.request.loaderType;
    __weak typeof(self) weakSelf = self;
    [[A2ModLoaderAPI shared] versionsForLoader:type
                                     mcVersion:self.baseVersionName
                                    completion:^(NSArray<A2ModLoaderVersion *> *versions,
                                                 NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (self.cancelled) {
            [self finishFailure:A2ModifyError(A2ModifyErrorCancelled, @"已取消")];
            return;
        }
        if (error) {
            [self finishFailure:error];
            return;
        }
        if (versions.count == 0) {
            [self finishFailure:A2ModifyError(
                A2ModifyErrorNoLoaderVersions,
                [NSString stringWithFormat:@"%@ 不支持 MC %@",
                 [A2ModLoaderAPI displayNameForType:type], self.baseVersionName])];
            return;
        }

        // 选定：用户指定优先 → 最新稳定版 → 第一个
        A2ModLoaderVersion *chosen = nil;
        NSString *wanted = self.request.loaderVersion;
        if (wanted.length > 0) {
            for (A2ModLoaderVersion *v in versions) {
                if ([v.version isEqualToString:wanted]) { chosen = v; break; }
            }
        }
        if (!chosen) {
            for (A2ModLoaderVersion *v in versions) {
                if (v.stable) { chosen = v; break; }
            }
        }
        if (!chosen) chosen = versions.firstObject;

        [self report:A2VersionModifyStageResolveLoader fraction:1
             message:[NSString stringWithFormat:@"选定 %@", chosen.displayName]];
        [self installLoader:chosen];
    }];
}

#pragma mark 3. 在临时目录里装加载器

- (void)installLoader:(A2ModLoaderVersion *)loader {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.workQueue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (self.cancelled) {
            [self finishFailure:A2ModifyError(A2ModifyErrorCancelled, @"已取消")];
            return;
        }

        [self report:A2VersionModifyStageInstallLoader fraction:0
             message:[NSString stringWithFormat:@"正在安装 %@…", loader.displayName]];

        A2ModLoaderInstaller *installer = [[A2ModLoaderInstaller alloc] init];
        self.activeLoaderInstaller = installer;   // 保活，完成回调里再放

        [installer installLoader:loader
                       mcVersion:self.baseVersionName
                     versionName:self.request.versionName
                        gameHome:self.stagingHome
                        progress:^(double p, NSString *message) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self report:A2VersionModifyStageInstallLoader fraction:p message:message];
        }
                      completion:^(BOOL success, NSError *installError) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;

            // 安装器的完成回调可能在任意线程，所有后续状态只在工作队列上动
            dispatch_async(self.workQueue, ^{
                self.activeLoaderInstaller = nil;

                if (self.cancelled) {
                    [self finishFailure:A2ModifyError(A2ModifyErrorCancelled, @"已取消")];
                    return;
                }
                if (!success) {
                    [self finishFailure:installError
                        ?: A2ModifyError(A2ModifyErrorLoaderInstallFailed,
                                         @"加载器安装失败")];
                    return;
                }
                [self mergeAndSwap];
            });
        }];
    });
}

#pragma mark 4. 并库 + 换文件

- (void)mergeAndSwap {
    if (self.cancelled) {
        [self finishFailure:A2ModifyError(A2ModifyErrorCancelled, @"已取消")];
        return;
    }

    [self report:A2VersionModifyStageMergeLibraries fraction:0
         message:@"正在合并依赖库…"];

    NSError *error = nil;
    if (![self mergeStagingLibraries:&error]) {
        [self finishFailure:error];
        return;
    }

    if (self.cancelled) {
        [self finishFailure:A2ModifyError(A2ModifyErrorCancelled, @"已取消")];
        return;
    }

    // 进入替换阶段后不再响应取消：换文件要么做完要么回滚
    [self report:A2VersionModifyStageSwapFiles fraction:0
         message:@"正在替换版本文件…"];

    if (![self swapVersionFiles:&error]) {
        [self finishFailure:error];
        return;
    }

    [self report:A2VersionModifyStageFinalize fraction:1 message:@"修改完成"];
    [self cleanupStaging];
    [self finishSuccess];
}

#pragma mark 4.1 合并 libraries

- (BOOL)mergeStagingLibraries:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;

    A2GamePath *stagingPath = [A2GamePath pathWithGameHome:self.stagingHome];
    A2GamePath *realPath = [A2GamePath pathWithGameHome:self.request.gameHome];

    NSString *srcRoot = [stagingPath librariesHome];
    NSString *dstRoot = [realPath librariesHome];

    if (![fm fileExistsAtPath:srcRoot]) return YES;   // 加载器没带额外库，正常

    // 先收集文件清单 —— 才能算真实进度
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:srcRoot];
    for (NSString *rel in enumerator) {
        NSString *abs = [srcRoot stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:abs isDirectory:&isDir] && isDir) continue;
        [files addObject:rel];
    }

    NSInteger total = MAX(1, (NSInteger)files.count);
    NSInteger skipped = 0;

    for (NSInteger i = 0; i < (NSInteger)files.count; i++) {
        if (self.cancelled) {
            if (error) *error = A2ModifyError(A2ModifyErrorCancelled, @"已取消");
            return NO;
        }

        NSString *rel = files[(NSUInteger)i];
        NSString *from = [srcRoot stringByAppendingPathComponent:rel];
        NSString *to = [dstRoot stringByAppendingPathComponent:rel];

        // 已存在且大小一致 → 保留。绝不用临时目录里的文件覆盖用户现有的库
        NSDictionary *existing = [fm attributesOfItemAtPath:to error:nil];
        if (existing) {
            NSNumber *existingSize = existing[NSFileSize];
            NSDictionary *sourceAttrs = [fm attributesOfItemAtPath:from error:nil];
            NSNumber *sourceSize = sourceAttrs[NSFileSize];
            if (existingSize && sourceSize &&
                [existingSize unsignedLongLongValue] == [sourceSize unsignedLongLongValue]) {
                skipped++;
                continue;
            }
        }

        NSString *parent = [to stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];

        NSError *moveError = nil;
        if ([fm fileExistsAtPath:to]) {
            if (![fm removeItemAtPath:to error:&moveError]) {
                if (error) *error = A2ModifyError(A2ModifyErrorMergeFailed,
                                                  [NSString stringWithFormat:@"替换 %@ 失败：%@",
                                                   rel, moveError.localizedDescription ?: @""]);
                return NO;
            }
        }

        if (![fm moveItemAtPath:from toPath:to error:&moveError]) {
            // 跨卷 / 权限 → 退回复制
            if (![fm copyItemAtPath:from toPath:to error:&moveError]) {
                if (error) *error = A2ModifyError(A2ModifyErrorMergeFailed,
                                                  [NSString stringWithFormat:@"写入 %@ 失败：%@",
                                                   rel, moveError.localizedDescription ?: @""]);
                return NO;
            }
            [fm removeItemAtPath:from error:nil];
        }

        // 节流：几百个文件逐个上报会把主队列灌满
        if ((i % 20 == 0) || i == (NSInteger)files.count - 1) {
            [self report:A2VersionModifyStageMergeLibraries
                fraction:(double)(i + 1) / (double)total
                 message:[NSString stringWithFormat:@"依赖库 %ld/%ld",
                          (long)(i + 1), (long)files.count]];
        }
    }

    [A2Logger info:@"VersionModifier"
           message:[NSString stringWithFormat:@"依赖库合并完成：%ld 个文件，跳过 %ld",
                    (long)files.count, (long)skipped]];
    return YES;
}

#pragma mark 4.2 原子替换 json/jar

- (BOOL)swapVersionFiles:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;

    A2GamePath *realPath = [A2GamePath pathWithGameHome:self.request.gameHome];
    A2GamePath *stagingPath = [A2GamePath pathWithGameHome:self.stagingHome];

    NSString *target = self.request.versionName;
    NSString *versionDir = [realPath versionPath:target];

    NSString *stagedJSON = [stagingPath versionJSONPath:target];
    NSString *stagedJar = [stagingPath versionJarPath:target];

    // ---- 4.2.1 读产物并做最后一道结构校验 ----
    NSDictionary *staged = A2ReadJSONDictionary(stagedJSON);
    if (!staged) {
        if (error) *error = A2ModifyError(A2ModifyErrorLoaderInstallFailed,
                                          @"加载器没有产出可用的版本 json");
        return NO;
    }
    NSMutableDictionary *finalJSON = [staged mutableCopy];

    if (self.inPlaceVanilla) {
        // 原版就地加加载器：内联合并，去掉 inheritsFrom（否则自己继承自己）
        NSDictionary *baseJSON = A2ReadJSONDictionary([realPath versionJSONPath:self.baseVersionName]);
        if (!baseJSON) {
            if (error) *error = A2ModifyError(A2ModifyErrorSwapFailed,
                                              @"读不到基底原版 json，无法内联合并");
            return NO;
        }
        finalJSON = A2InlineMergeVersionJSON(baseJSON, staged, target);
    } else {
        finalJSON[@"id"] = target;
        id parent = finalJSON[@"inheritsFrom"];
        if (![parent isKindOfClass:NSString.class] ||
            ![parent isEqualToString:self.baseVersionName]) {
            // 兜底：父版本必须是基底，否则启动时找不到被继承的原版
            finalJSON[@"inheritsFrom"] = self.baseVersionName;
        }
    }

    id mainClass = finalJSON[@"mainClass"];
    if (![mainClass isKindOfClass:NSString.class] || [mainClass length] == 0) {
        if (error) *error = A2ModifyError(A2ModifyErrorSwapFailed,
                                          @"合并后的版本 json 缺少 mainClass，已放弃替换");
        return NO;
    }

    // 写到临时根下的新文件，再搬进目标目录（同卷 rename）
    NSString *newJSONPath = [self.stagingRoot stringByAppendingPathComponent:@"new.json"];
    if (!A2WriteJSONDictionary(newJSONPath, finalJSON, error)) return NO;

    NSString *newSHA1 = [A2IntegrityChecker sha1OfFile:newJSONPath];
    if (newSHA1.length != 40) {
        if (error) *error = A2ModifyError(A2ModifyErrorSwapFailed,
                                          @"算不出新 json 的 SHA1，已放弃替换");
        return NO;
    }

    // ---- 4.2.2 决定 jar 是否要换 ----
    //  加载器版与原版共用客户端 jar；只有内容不同（大小不同）才替换，
    //  避免把几十 MB 的文件白搬一遍。
    NSString *finalJson = [realPath versionJSONPath:target];
    NSString *finalJar = [realPath versionJarPath:target];
    NSString *bakJson = [versionDir stringByAppendingPathComponent:
                         [target stringByAppendingFormat:@"%@%@", @".json", kBakSuffix]];
    NSString *bakJar = [versionDir stringByAppendingPathComponent:
                        [target stringByAppendingFormat:@"%@%@", @".jar", kBakSuffix]];
    NSString *tmpJson = [versionDir stringByAppendingPathComponent:
                         [target stringByAppendingFormat:@"%@%@", @".json", kNewSuffix]];
    NSString *tmpJar = [versionDir stringByAppendingPathComponent:
                        [target stringByAppendingFormat:@"%@%@", @".jar", kNewSuffix]];

    BOOL stagedJarExists = [fm fileExistsAtPath:stagedJar];
    BOOL replaceJar = NO;
    if (stagedJarExists) {
        NSDictionary *stagedAttrs = [fm attributesOfItemAtPath:stagedJar error:nil];
        NSDictionary *targetAttrs = [fm attributesOfItemAtPath:finalJar error:nil];
        unsigned long long stagedSize = [stagedAttrs[NSFileSize] unsignedLongLongValue];
        unsigned long long targetSize = [targetAttrs[NSFileSize] unsignedLongLongValue];
        replaceJar = (stagedSize != targetSize) || targetSize == 0;
    }
    if (!replaceJar && ![fm fileExistsAtPath:finalJar]) {
        // 目标没有 jar 而临时有 → 必须补上
        replaceJar = stagedJarExists;
    }

    // ---- 4.2.3 搬进目标目录（关键区间内只剩 rename） ----
    NSString *journalPath = A2JournalPath(versionDir);

    if (!A2MoveReplacing(newJSONPath, tmpJson, error)) {
        A2RemoveIfExists(tmpJson);
        return NO;
    }
    if (replaceJar && !A2MoveReplacing(stagedJar, tmpJar, error)) {
        A2RemoveIfExists(tmpJson);
        A2RemoveIfExists(tmpJar);
        return NO;
    }

    // ---- 4.2.4 写 journal（含新 json 的 SHA1，供下次自愈判定） ----
    NSDictionary *journal = @{
        @"version": target,
        @"baseVersion": self.baseVersionName ?: @"",
        @"newJSONSHA1": newSHA1,
        @"replaceJar": @(replaceJar),
        @"startedAt": @([[NSDate date] timeIntervalSince1970]),
    };
    NSError *journalError = nil;
    if (!A2WriteJSONDictionary(journalPath, journal, &journalError)) {
        A2RemoveIfExists(tmpJson);
        A2RemoveIfExists(tmpJar);
        if (error) *error = A2ModifyError(A2ModifyErrorSwapFailed,
                                          [NSString stringWithFormat:@"写 journal 失败：%@",
                                           journalError.localizedDescription ?: @""]);
        return NO;
    }

    // ---- 4.2.5 备份原文件（同卷 rename） ----
    NSError *backupError = nil;
    if ([fm fileExistsAtPath:finalJson] &&
        !A2MoveReplacing(finalJson, bakJson, &backupError)) {
        [self rollbackInDir:versionDir target:target replaceJar:replaceJar];
        if (error) *error = A2ModifyError(A2ModifyErrorSwapFailed,
                                          [NSString stringWithFormat:@"备份版本 json 失败：%@",
                                           backupError.localizedDescription ?: @""]);
        return NO;
    }
    if (replaceJar && [fm fileExistsAtPath:finalJar] &&
        !A2MoveReplacing(finalJar, bakJar, &backupError)) {
        [self rollbackInDir:versionDir target:target replaceJar:replaceJar];
        if (error) *error = A2ModifyError(A2ModifyErrorSwapFailed,
                                          [NSString stringWithFormat:@"备份客户端 jar 失败：%@",
                                           backupError.localizedDescription ?: @""]);
        return NO;
    }

    // ---- 4.2.6 换入 ----
    BOOL ok = A2MoveReplacing(tmpJson, finalJson, error);
    if (ok && replaceJar) {
        ok = A2MoveReplacing(tmpJar, finalJar, error);
    }

    // ---- 4.2.7 换完立刻验一遍能解析 ----
    if (ok) {
        NSDictionary *check = A2ReadJSONDictionary(finalJson);
        if (!check) {
            ok = NO;
            if (error) *error = A2ModifyError(A2ModifyErrorSwapFailed,
                                              @"替换后的版本 json 无法解析");
        }
    }

    if (!ok) {
        // 回滚的细节由 rollbackInDir: 自己写日志（它可能是救命的最后一条记录）
        [self rollbackInDir:versionDir target:target replaceJar:replaceJar];
        [A2Logger error:@"VersionModifier"
                 message:[NSString stringWithFormat:@"%@ 替换失败，已尝试从备份还原", target]];
        return NO;
    }

    // ---- 4.2.8 成功：清备份与 journal ----
    A2RemoveIfExists(bakJson);
    A2RemoveIfExists(bakJar);
    A2RemoveIfExists(journalPath);

    [A2Logger info:@"VersionModifier"
           message:[NSString stringWithFormat:@"%@ 替换完成（jar %@）",
                    target, replaceJar ? @"已换" : @"沿用"]];
    return YES;
}

/// 从备份还原并清掉临时文件。
/// 失败不抛错（此时已经在错误路径上了），但会写日志 —— 还原失败是最坏情况，
/// 必须让人在日志里看见。
- (void)rollbackInDir:(NSString *)versionDir
               target:(NSString *)target
           replaceJar:(BOOL)replaceJar {

    NSFileManager *fm = NSFileManager.defaultManager;

    NSString *finalJson = [versionDir stringByAppendingPathComponent:
                           [target stringByAppendingString:@".json"]];
    NSString *finalJar = [versionDir stringByAppendingPathComponent:
                          [target stringByAppendingString:@".jar"]];
    NSString *bakJson = [versionDir stringByAppendingPathComponent:
                         [target stringByAppendingFormat:@"%@%@", @".json", kBakSuffix]];
    NSString *bakJar = [versionDir stringByAppendingPathComponent:
                        [target stringByAppendingFormat:@"%@%@", @".jar", kBakSuffix]];
    NSString *tmpJson = [versionDir stringByAppendingPathComponent:
                         [target stringByAppendingFormat:@"%@%@", @".json", kNewSuffix]];
    NSString *tmpJar = [versionDir stringByAppendingPathComponent:
                        [target stringByAppendingFormat:@"%@%@", @".jar", kNewSuffix]];

    NSError *restoreError = nil;

    if ([fm fileExistsAtPath:bakJson]) {
        A2RemoveIfExists(finalJson);
        if (![fm moveItemAtPath:bakJson toPath:finalJson error:&restoreError]) {
            [A2Logger error:@"VersionModifier"
                     message:[NSString stringWithFormat:@"还原 json 失败：%@",
                              restoreError.localizedDescription ?: @""]];
        }
    }

    if (replaceJar && [fm fileExistsAtPath:bakJar]) {
        A2RemoveIfExists(finalJar);
        if (![fm moveItemAtPath:bakJar toPath:finalJar error:&restoreError]) {
            [A2Logger error:@"VersionModifier"
                     message:[NSString stringWithFormat:@"还原 jar 失败：%@",
                              restoreError.localizedDescription ?: @""]];
        }
    }

    A2RemoveIfExists(tmpJson);
    A2RemoveIfExists(tmpJar);
    A2RemoveIfExists(A2JournalPath(versionDir));
}

#pragma mark 5. 收尾

- (void)cleanupStaging {
    if (self.stagingRoot.length == 0) return;
    A2RemoveIfExists(self.stagingRoot);
    [A2Logger debug:@"VersionModifier"
            message:[NSString stringWithFormat:@"临时目录已清理：%@", self.stagingRoot]];
    self.stagingRoot = nil;
    self.stagingHome = nil;
}

- (void)finishSuccess {
    if (self.finished) return;
    self.finished = YES;

    [self report:A2VersionModifyStageFinalize fraction:1
         message:[NSString stringWithFormat:@"%@ 已更新",
                  self.request.versionName]];

    void (^done)(BOOL, NSError *) = self.completionBlock;
    self.completionBlock = nil;
    self.progressBlock = nil;
    self.selfRetain = nil;   // 解开自持有

    A2Main(^{
        if (done) done(YES, nil);
    });
}

- (void)finishFailure:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;

    [self cleanupStaging];

    [A2Logger error:@"VersionModifier"
             message:[NSString stringWithFormat:@"%@ 修改失败：%@",
                      self.request.versionName ?: @"(未知)",
                      error.localizedDescription ?: @"(无描述)"]];

    void (^done)(BOOL, NSError *) = self.completionBlock;
    self.completionBlock = nil;
    self.progressBlock = nil;
    self.selfRetain = nil;   // 解开自持有

    NSError *finalError = error ?: A2ModifyError(A2ModifyErrorSwapFailed, @"未知错误");
    A2Main(^{
        if (done) done(NO, finalError);
    });
}

- (void)report:(A2VersionModifyStage)stage
      fraction:(double)fraction
       message:(NSString *)message {

    void (^block)(A2VersionModifyStage, double, NSString *) = self.progressBlock;
    if (!block) return;

    double clamped = MAX(0.0, MIN(1.0, fraction));
    NSString *text = message ?: @"";
    A2Main(^{
        block(stage, clamped, text);
    });
}

#pragma mark - 中断恢复

+ (BOOL)hasPendingModifyForVersion:(NSString *)versionName gameHome:(NSString *)gameHome {
    if (versionName.length == 0 || gameHome.length == 0) return NO;
    A2GamePath *path = [A2GamePath pathWithGameHome:gameHome];
    return A2ReadJournal([path versionPath:versionName]) != nil;
}

+ (BOOL)recoverInterruptedModifyForVersion:(NSString *)versionName
                                  gameHome:(NSString *)gameHome
                                     error:(NSError **)error {

    if (versionName.length == 0 || gameHome.length == 0) {
        if (error) *error = A2ModifyError(A2ModifyErrorInvalidRequest, @"参数不完整");
        return NO;
    }

    A2GamePath *path = [A2GamePath pathWithGameHome:gameHome];
    NSString *versionDir = [path versionPath:versionName];
    NSDictionary *journal = A2ReadJournal(versionDir);

    // 没有 journal = 没有未完成的替换
    if (!journal) return YES;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *finalJson = [path versionJSONPath:versionName];
    NSString *finalJar = [path versionJarPath:versionName];
    NSString *bakJson = [versionDir stringByAppendingPathComponent:
                         [versionName stringByAppendingFormat:@"%@%@", @".json", kBakSuffix]];
    NSString *bakJar = [versionDir stringByAppendingPathComponent:
                        [versionName stringByAppendingFormat:@"%@%@", @".jar", kBakSuffix]];
    NSString *tmpJson = [versionDir stringByAppendingPathComponent:
                         [versionName stringByAppendingFormat:@"%@%@", @".json", kNewSuffix]];
    NSString *tmpJar = [versionDir stringByAppendingPathComponent:
                        [versionName stringByAppendingFormat:@"%@%@", @".jar", kNewSuffix]];

    BOOL replaceJar = [journal[@"replaceJar"] boolValue];
    id expectedSHA1Obj = journal[@"newJSONSHA1"];
    NSString *expectedSHA1 = [expectedSHA1Obj isKindOfClass:NSString.class]
                                ? expectedSHA1Obj : nil;

    // 关键判定：目标 json 的 SHA1 与新文件一致 → 替换其实已经完成，
    // 只是没来得及清备份/删 journal。这种情况必须【保留新文件】。
    NSString *actualSHA1 = [A2IntegrityChecker sha1OfFile:finalJson];
    BOOL swapped = (expectedSHA1.length == 40 && actualSHA1.length == 40 &&
                    [actualSHA1 caseInsensitiveCompare:expectedSHA1] == NSOrderedSame);

    if (swapped) {
        A2RemoveIfExists(bakJson);
        A2RemoveIfExists(tmpJson);
        A2RemoveIfExists(tmpJar);
        if (replaceJar) A2RemoveIfExists(bakJar);
        A2RemoveIfExists(A2JournalPath(versionDir));
        [A2Logger info:@"VersionModifier"
               message:[NSString stringWithFormat:@"%@：上次替换已完成，清理残留", versionName]];
        return YES;
    }

    // 未完成 → 从备份还原
    NSError *restoreError = nil;
    if ([fm fileExistsAtPath:bakJson]) {
        A2RemoveIfExists(finalJson);
        if (![fm moveItemAtPath:bakJson toPath:finalJson error:&restoreError]) {
            if (error) *error = A2ModifyError(A2ModifyErrorSwapFailed,
                                              [NSString stringWithFormat:@"还原版本 json 失败：%@",
                                               restoreError.localizedDescription ?: @""]);
            return NO;
        }
    }

    if (replaceJar && [fm fileExistsAtPath:bakJar]) {
        A2RemoveIfExists(finalJar);
        if (![fm moveItemAtPath:bakJar toPath:finalJar error:&restoreError]) {
            if (error) *error = A2ModifyError(A2ModifyErrorSwapFailed,
                                              [NSString stringWithFormat:@"还原客户端 jar 失败：%@",
                                               restoreError.localizedDescription ?: @""]);
            return NO;
        }
    }

    A2RemoveIfExists(tmpJson);
    A2RemoveIfExists(tmpJar);
    A2RemoveIfExists(A2JournalPath(versionDir));

    // 还原后目标 json 还是不存在 → 说明既没换成也没备份，只能重装
    if (![fm fileExistsAtPath:finalJson]) {
        if (error) *error = A2ModifyError(A2ModifyErrorSwapFailed,
                                          @"上次修改中断且没有可用备份，请重新安装该版本");
        return NO;
    }

    [A2Logger info:@"VersionModifier"
           message:[NSString stringWithFormat:@"%@：已从备份还原中断的替换", versionName]];
    return YES;
}

@end
