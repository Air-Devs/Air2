//
//  A2IntegrityRepairer.m
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
//  A2IntegrityRepairer.m
//  Air2
//
//  对照 ZL2：
//    · game/version/download/MinecraftDownloader.kt  VERIFY_AND_REPAIR 分支
//    · game/download/BatchDownloader.kt（文件级并发 / 整批重试 / 熔断）
//    · game/download/game/GameInstaller.kt  createGameInstalledTask 里
//      「校验通过就不动、不通过就重下」的判定
//
//   行为差异：
//     ZL2 的修复与安装共用一次下载编排；Air2 这里只补「已安装版本缺的文件」，
//     不重建版本目录、不合并 json —— 那是 A2GameInstaller 的事。
//     理由：修文件是幂等且低风险的，重装会碰用户 json，两者不该混在一起。
//

#import "A2IntegrityRepairer.h"
#import "A2Logger.h"
#import "A2BatchDownloader.h"
#import "A2MirrorResolver.h"

#pragma mark - 结果

@implementation A2IntegrityRepairResult

- (instancetype)init {
    self = [super init];
    if (self) {
        _failuresByPath = @{};
        _unrepairableIssues = @[];
    }
    return self;
}

- (BOOL)clean {
    // 没复检过就不算干净 —— 「没验过」和「修好了」是两件事
    return self.postReport != nil && self.postReport.clean;
}

- (NSArray<A2IntegrityIssue *> *)remainingIssues {
    return self.postReport.issues ?: @[];
}

- (NSString *)summaryText {
    NSMutableString *text = [NSMutableString stringWithFormat:
                             @"修复：删除损坏 %ld，下载 %ld（成功 %ld）",
                             (long)self.removedCorruptedFiles,
                             (long)self.scheduledFiles,
                             (long)self.succeededFiles];
    if (self.failuresByPath.count > 0) {
        [text appendFormat:@"，失败 %ld", (long)self.failuresByPath.count];
    }
    if (self.unrepairableIssues.count > 0) {
        [text appendFormat:@"，%ld 项需重装", (long)self.unrepairableIssues.count];
    }
    if (self.postReport) {
        [text appendFormat:@"；复检：%@", [self.postReport summaryText]];
    }
    if (self.cancelled) [text appendString:@"（已取消）"];
    return text;
}

@end

#pragma mark - 修复器

@interface A2IntegrityRepairer ()

/// 批量下载器必须由属性持有。
/// 局部变量会在方法返回瞬间被 ARC 释放，下载静默死掉（表现为进度永远 0）。
@property (nonatomic, strong, nullable) A2BatchDownloader *activeDownloader;

/// 自持有。
/// 常见调用写法是 [[A2IntegrityRepairer new] repairVersion:...] —— 调用方不留引用，
/// 我们一返回对象就没了，异步回调永远不会来。这里在流程期间持有自己，
/// finish / cancel 时置 nil 解开。
/// 注意：这是**故意的**所有权环，务必保证每一条路径都会清掉。
@property (nonatomic, strong, nullable) A2IntegrityRepairer *selfRetain;

@property (nonatomic, copy, nullable) void (^progressBlock)(A2IntegrityRepairPhase, double, NSString *);

@end

@implementation A2IntegrityRepairer

- (void)dealloc {
    [_activeDownloader cancel];
}

#pragma mark 入口

- (void)repairVersion:(NSString *)versionName
             gameHome:(NSString *)gameHome
           verifyMode:(A2IntegrityCheckMode)verifyMode
                scope:(A2IntegrityScope)scope
             progress:(void (^)(A2IntegrityRepairPhase, double, NSString *))progress
           completion:(void (^)(A2IntegrityRepairResult *))completion {

    self.selfRetain = self;
    self.progressBlock = progress;
    self.cancelled = NO;

    if (versionName.length == 0 || gameHome.length == 0) {
        A2IntegrityRepairResult *result = [A2IntegrityRepairResult new];
        [self finishWithResult:result completion:completion];
        return;
    }

    [self reportPhase:A2IntegrityRepairPhaseRemoveCorrupted
             fraction:0.0
              message:@"正在校验游戏文件…"];

    __weak typeof(self) weakSelf = self;
    [[A2IntegrityChecker new] verifyVersion:versionName
                                  gameHome:gameHome
                                      mode:verifyMode
                                     scope:scope
                                  progress:nil
                                completion:^(A2IntegrityReport *report) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (self.cancelled) {
            A2IntegrityRepairResult *result = [A2IntegrityRepairResult new];
            result.cancelled = YES;
            [self finishWithResult:result completion:completion];
            return;
        }

        // 分拣可能有上千条问题（资源对象），别压在主线程上做
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self repairReport:report
                      gameHome:gameHome
                    verifyMode:verifyMode
                         scope:scope
                      progress:progress
                    completion:completion];
        });
    }];
}

- (void)repairReport:(A2IntegrityReport *)report
            gameHome:(NSString *)gameHome
          verifyMode:(A2IntegrityCheckMode)verifyMode
               scope:(A2IntegrityScope)scope
            progress:(void (^)(A2IntegrityRepairPhase, double, NSString *))progress
          completion:(void (^)(A2IntegrityRepairResult *))completion {

    self.selfRetain = self;
    self.progressBlock = progress;

    A2IntegrityRepairResult *result = [A2IntegrityRepairResult new];

    // 干净的版本直接不再进下载流程 —— 复检也不用跑，报告本身就是结论
    if (report.issues.count == 0) {
        result.postReport = report;
        [self finishWithResult:result completion:completion];
        return;
    }

    // ---- 1. 分拣：能修的进下载队列，不能修的如实列出 ----
    NSMutableArray<A2IntegrityIssue *> *unrepairable = [NSMutableArray array];
    NSMutableArray<A2IntegrityIssue *> *toRemove = [NSMutableArray array];
    NSMutableArray<A2DownloadRequest *> *requests = [NSMutableArray array];

    A2MirrorResolver *mirror = [A2MirrorResolver shared];

    for (A2IntegrityIssue *issue in report.issues) {
        if (issue.path.length == 0) continue;

        if (issue.downloadURLs.count == 0) {
            [unrepairable addObject:issue];
            continue;
        }

        // 展开镜像候选（顺序与安装器一致：镜像优先/官方优先由用户设置决定）
        NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
        for (NSString *urlString in issue.downloadURLs) {
            if (urlString.length == 0) continue;
            NSArray<NSString *> *expanded = [mirror candidateURLsForURL:urlString];
            for (NSString *candidate in (expanded.count ? expanded : @[urlString])) {
                NSURL *url = [NSURL URLWithString:candidate];
                if (url) [candidates addObject:url];
            }
        }

        if (candidates.count == 0) {
            [unrepairable addObject:issue];
            continue;
        }

        A2DownloadRequest *req = [A2DownloadRequest new];
        req.candidateURLs = candidates;
        req.destinationPath = issue.path;
        // 无 sha1 且目标是 .jar/.zip 时让引擎扫 EOCD 兜底；
        // 有 sha1 时引擎不会用这条兜底，所以开着无害
        req.allowZipFallbackCheck = YES;
        if (issue.expectedSHA1.length == 40) req.expectedSHA1 = issue.expectedSHA1;
        if (issue.expectedSize > 0) req.expectedSize = issue.expectedSize;

        if (issue.needsRemovalBeforeRepair) [toRemove addObject:issue];

        [requests addObject:req];
    }

    result.unrepairableIssues = unrepairable;
    result.scheduledFiles = (NSInteger)requests.count;

    // ---- 2. 后台删损坏文件 + 起批量下载 ----
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        NSFileManager *fm = NSFileManager.defaultManager;
        NSInteger removed = 0;
        for (A2IntegrityIssue *issue in toRemove) {
            if ([fm removeItemAtPath:issue.path error:nil]) removed++;
        }
        result.removedCorruptedFiles = removed;

        if (self.cancelled || requests.count == 0) {
            result.cancelled = self.cancelled;
            [self verifyAfterRepairForResult:result
                                    report:report
                                  gameHome:gameHome
                                verifyMode:verifyMode
                                     scope:scope
                                completion:completion];
            return;
        }

        [self reportPhase:A2IntegrityRepairPhaseDownload
                 fraction:0.05
                  message:[NSString stringWithFormat:@"开始补下载 %ld 个文件…",
                           (long)requests.count]];

        // 并发数与安装器保持一致（ZL2 的 DEFAULT_MAX_CONNECTIONS = 64）
        NSInteger configured = [NSUserDefaults.standardUserDefaults
                                integerForKey:@"A2MaxConnections"];
        NSInteger maxConnections = (configured > 0) ? MIN(configured, 128) : 64;

        A2BatchDownloader *downloader =
            [[A2BatchDownloader alloc] initWithRequests:requests
                                        maxConnections:maxConnections
                                           retryRounds:1];
        self.activeDownloader = downloader;

        downloader.onProgress = ^(A2BatchProgress *batchProgress) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.cancelled) return;

            double fraction = 0.05 + batchProgress.fraction * 0.80;
            NSString *message = [NSString stringWithFormat:
                                 @"补下载 %ld/%ld",
                                 (long)batchProgress.downloadedFiles,
                                 (long)batchProgress.totalFiles];
            if (batchProgress.speedBytesPerSec > 0) {
                message = [message stringByAppendingFormat:@" · %.1f MB/s",
                           batchProgress.speedBytesPerSec / (1024.0 * 1024.0)];
            }
            [self reportPhase:A2IntegrityRepairPhaseDownload
                     fraction:fraction
                      message:message];
        };

        downloader.onCompletion = ^(BOOL success,
                                    NSDictionary<NSString *, NSError *> *failures) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;

            // 先松开下载器，再进复检。
            // 这里用 precise_lifetime 把它的生命周期钉到本回调结束 ——
            // 直接在下载器自己的 onCompletion 里把它释放掉属于 use-after-free 边缘行为
            // （回调返回后它的方法还在跑）。
            __attribute__((objc_precise_lifetime))
            A2BatchDownloader *finishedDownloader = self.activeDownloader;
            self.activeDownloader = nil;
            (void)finishedDownloader;

            result.failuresByPath = failures ?: @{};
            result.succeededFiles = MAX(0, (NSInteger)requests.count -
                                           (NSInteger)result.failuresByPath.count);
            result.cancelled = self.cancelled;

            if (result.failuresByPath.count > 0) {
                [A2Logger warning:@"IntegrityRepairer"
                          message:[NSString stringWithFormat:
                                   @"补下载完成，%ld 个文件仍失败",
                                   (long)result.failuresByPath.count]];
            }

            [self verifyAfterRepairForResult:result
                                      report:report
                                    gameHome:gameHome
                                  verifyMode:verifyMode
                                       scope:scope
                                  completion:completion];
        };

        [downloader start];
    });
}

#pragma mark 复检

/// 修完复检。用与校验时相同的路径根与范围 —— 口径不一致就判断不准。
- (void)verifyAfterRepairForResult:(A2IntegrityRepairResult *)result
                            report:(A2IntegrityReport *)report
                          gameHome:(NSString *)gameHome
                        verifyMode:(A2IntegrityCheckMode)verifyMode
                             scope:(A2IntegrityScope)scope
                        completion:(void (^)(A2IntegrityRepairResult *))completion {

    NSString *versionName = report.versionChain.firstObject;
    if (versionName.length == 0 || gameHome.length == 0) {
        // 连版本名都没有（报告构造异常）就不复检，直接交结果
        [self finishWithResult:result completion:completion];
        return;
    }

    [self reportPhase:A2IntegrityRepairPhaseVerify fraction:0.88 message:@"正在复检…"];

    __weak typeof(self) weakSelf = self;
    [[A2IntegrityChecker new] verifyVersion:versionName
                                  gameHome:gameHome
                                      mode:verifyMode
                                     scope:scope
                                  progress:nil
                                completion:^(A2IntegrityReport *postReport) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        result.postReport = postReport;
        [A2Logger info:@"IntegrityRepairer"
               message:[NSString stringWithFormat:@"%@：%@",
                        versionName, [result summaryText]]];
        [self finishWithResult:result completion:completion];
    }];
}

#pragma mark 收尾

- (void)finishWithResult:(A2IntegrityRepairResult *)result
              completion:(void (^)(A2IntegrityRepairResult *))completion {

    self.progressBlock = nil;
    // 解开自持有，放在回调之前也行：block 已捕获 result，不依赖 self
    self.selfRetain = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(result);
    });
}

- (void)cancel {
    self.cancelled = YES;
    [self.activeDownloader cancel];
    self.activeDownloader = nil;
    // 注意：不在这里置 selfRetain = nil —— 下载回调还在路上，
    // 提前放掉自己会让那些回调全部落空。交给 finishWithResult 收尾。
}

#pragma mark 进度

- (void)reportPhase:(A2IntegrityRepairPhase)phase
           fraction:(double)fraction
            message:(NSString *)message {

    void (^block)(A2IntegrityRepairPhase, double, NSString *) = self.progressBlock;
    if (!block) return;

    double clamped = MAX(0.0, MIN(1.0, fraction));
    NSString *text = message ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        block(phase, clamped, text);
    });
}

@end
