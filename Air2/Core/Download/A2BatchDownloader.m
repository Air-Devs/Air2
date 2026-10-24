//
//  A2BatchDownloader.m
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
//
//  A2BatchDownloader.m
//  Air2
//

#import "A2BatchDownloader.h"
#import "A2Logger.h"

/// 进度回调间隔
static const NSTimeInterval kProgressInterval = 0.5;
/// 系统性故障阈值：整批零成功时，连续这么多个永久失败就中止
static const NSInteger kSystemicFailureLimit = 12;

@implementation A2BatchProgress

- (double)fraction {
    if (_totalBytes <= 0) return 0;
    return MIN(1.0, (double)_downloadedBytes / (double)_totalBytes);
}

@end

@interface A2BatchDownloader ()
@property (nonatomic, strong) NSArray<A2DownloadRequest *> *requests;
@property (nonatomic, assign) NSInteger maxConnections;
@property (nonatomic, assign) NSInteger retryRounds;

// 计数器（用锁保护 —— 多个下载线程并发更新）
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, assign) long long counterDownloadedBytes;
@property (nonatomic, assign) long long counterTotalBytes;
@property (nonatomic, assign) NSInteger counterDownloadedFiles;
@property (nonatomic, assign) NSInteger consecutiveFailures;
/// 上一秒的字节数 —— 用于算瞬时速度
@property (nonatomic, assign) long long bytesAtLastTick;
/// 本批次发起的所有下载操作 —— 取消时逐个取消，
/// 不能调 engine 的 cancelAll（那会杀掉 App 里其他下载）
@property (nonatomic, strong) NSMutableArray<A2DownloadOperation *> *activeOps;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSError *> *failures;

@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, assign, getter=isCancelled) BOOL cancelled;
@property (nonatomic, assign) BOOL started;
@end

@implementation A2BatchDownloader

- (instancetype)initWithRequests:(NSArray<A2DownloadRequest *> *)requests
                  maxConnections:(NSInteger)maxConnections
                     retryRounds:(NSInteger)retryRounds {
    self = [super init];
    if (!self) return nil;
    _requests = [requests copy];
    _maxConnections = MAX(1, maxConnections);
    _retryRounds = MAX(0, retryRounds);
    _lock = [[NSLock alloc] init];
    _failures = [NSMutableDictionary dictionary];
    return self;
}

#pragma mark - 登记

- (void)registerReusedFileWithPath:(NSString *)path size:(long long)size {
    [_lock lock];
    _counterDownloadedFiles += 1;
    _counterTotalBytes += size;
    _counterDownloadedBytes += size;
    [_lock unlock];
}

#pragma mark - 启动

- (void)start {
    if (_started) return;
    _started = YES;
    _cancelled = NO;

    // 先登记全部文件的总量 —— 进度分母从一开始就是对的
    [_lock lock];
    for (A2DownloadRequest *req in _requests) {
        _counterTotalBytes += req.expectedSize;
    }
    NSInteger total = (NSInteger)_requests.count;
    [_lock unlock];

    [A2Logger info:@"BatchDownloader"
           message:[NSString stringWithFormat:@"开始批量下载 %ld 个文件，并发 %ld",
                    (long)total, (long)_maxConnections]];

    [self publishProgress];

    __weak typeof(self) weakSelf = self;
    _progressTimer = [NSTimer scheduledTimerWithTimeInterval:kProgressInterval
                                                     repeats:YES
                                                       block:^(NSTimer *t) {
        __strong typeof(weakSelf) self = weakSelf;
        [self publishProgress];
    }];

    [self runRound:0 pending:[_requests mutableCopy]];
}

#pragma mark - 执行

/// 跑一轮。
///
/// ## 调度模型（对照 ZL2 的 BatchDownloader.run）
///
/// ZL2 用「每文件一个协程 + Semaphore.withPermit」：
/// withPermit 是【挂起】，不占线程，所以 5000 个文件也只是
/// 5000 个挂起的协程，内存可控。
///
/// 我之前用 dispatch_async + dispatch_semaphore_wait：
/// 那是【阻塞】—— 5000 个 block 会各自占一个 GCD 线程在等信号量，
/// GCD 线程池被打满后整个 App 卡住（下到资源阶段就不动了，
/// 因为资源有 5000+ 个文件）。
///
/// 现在改成【拉取式】：只维持 maxConnections 个在途下载，
/// 每完成一个就从队列里取下一个。线程数恒定，与文件总数无关。
- (void)runRound:(NSInteger)round pending:(NSMutableArray<A2DownloadRequest *> *)pending {
    if (self.isCancelled || pending.count == 0) {
        [self finishWithSuccess:pending.count == 0];
        return;
    }

    __block NSMutableArray<A2DownloadRequest *> *queue = [pending mutableCopy];
    __block NSMutableArray<A2DownloadRequest *> *stillFailing = [NSMutableArray array];
    __block NSInteger inFlight = 0;
    __block BOOL aborted = NO;
    NSLock *qLock = [[NSLock alloc] init];

    __weak typeof(self) weakSelf = self;

    // 从队列取一个；取不到返回 nil
    A2DownloadRequest * (^nextRequest)(void) = ^A2DownloadRequest * {
        [qLock lock];
        A2DownloadRequest *r = queue.firstObject;
        if (r) [queue removeObjectAtIndex:0];
        [qLock unlock];
        return r;
    };

    // 检查是否该收尾
    void (^maybeFinish)(void) = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [qLock lock];
        BOOL done = (inFlight == 0 && queue.count == 0);
        [qLock unlock];
        if (!done) return;

        if (self.isCancelled) return;
        if (aborted) {
            [A2Logger error:@"BatchDownloader"
                     message:@"检测到系统性故障（整批零成功且连续多次失败），已中止剩余文件"];
            [self finishWithSuccess:NO];
            return;
        }

        NSArray<A2DownloadRequest *> *retryList = nil;
        [qLock lock];
        retryList = [stillFailing copy];
        [qLock unlock];

        if (round < self.retryRounds && retryList.count > 0) {
            [A2Logger info:@"BatchDownloader"
                   message:[NSString stringWithFormat:@"第 %ld 轮结束，%lu 个文件待重试",
                            (long)(round + 1), (unsigned long)retryList.count]];
            [self resetConsecutiveFailuresForRetry];
            [self runRound:round + 1 pending:[retryList mutableCopy]];
        } else {
            [self finishWithSuccess:retryList.count == 0];
        }
    };

    // 启动下一个下载。内部递归：完成一个立刻拉下一个。
    __block void (^startNext)(void) = nil;
    startNext = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.isCancelled) return;

        [qLock lock];
        BOOL shouldStop = aborted;
        [qLock unlock];
        if (shouldStop) { maybeFinish(); return; }

        A2DownloadRequest *req = nextRequest();
        if (!req) { maybeFinish(); return; }

        [qLock lock];
        inFlight += 1;
        [qLock unlock];

        A2DownloadOperation *op = [[A2DownloadEngine sharedClient] startRequest:req
            progress:^(int64_t delta, int64_t totalIgnore) {
                (void)totalIgnore;
                [self addDownloadedBytes:delta];
            }
            speed:nil
            completion:^(BOOL success, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;

            [self.lock lock];
            [self.activeOps removeObject:op];
            [self.lock unlock];

            if (success) {
                [self markFileDone];
            } else {
                BOOL systemic = [self recordFailure:req error:error];
                if (systemic) {
                    [qLock lock];
                    aborted = YES;
                    [queue removeAllObjects];   // 熔断：不再发起新的
                    [qLock unlock];
                }
                if (!aborted) {
                    [qLock lock];
                    [stillFailing addObject:req];
                    [qLock unlock];
                }
            }

            if (success && self.onFileSuccess) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.onFileSuccess) self.onFileSuccess(req);
                });
            }

            [qLock lock];
            inFlight -= 1;
            [qLock unlock];

            // 立刻拉下一个 —— 线程数恒定，不因文件总数增长
            startNext();
        }];

        if (op) {
            [self.lock lock];
            [self.activeOps addObject:op];
            [self.lock unlock];
        } else {
            // 引擎没接（队列满等），稍后重试这个文件
            [qLock lock];
            inFlight -= 1;
            [queue insertObject:req atIndex:0];
            [qLock unlock];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                startNext();
            });
        }
    };

    // 启动 maxConnections 条"车道"
    NSInteger lanes = MIN(_maxConnections, (NSInteger)queue.count);
    for (NSInteger i = 0; i < lanes; i++) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            startNext();
        });
    }
}

#pragma mark - 计数

- (void)addDownloadedBytes:(long long)delta {
    [_lock lock];
    _counterDownloadedBytes += delta;
    [_lock unlock];
}

- (void)markFileDone {
    [_lock lock];
    _counterDownloadedFiles += 1;
    // 任何一次成功都清零连续失败计数 —— 说明网络本身是通的
    _consecutiveFailures = 0;
    _activeOps = [NSMutableArray array];
    [_lock unlock];
}

/// 记录失败。返回 YES 表示触发了系统性故障熔断。
- (BOOL)recordFailure:(A2DownloadRequest *)req error:(NSError *)error {
    [_lock lock];
    if (req.destinationPath.length) {
        _failures[req.destinationPath] = error ?: [NSError errorWithDomain:@"A2Batch" code:1
                                                                 userInfo:nil];
    }
    _consecutiveFailures += 1;

    // 熔断条件：一次都没成功过 + 连续失败达到阈值。
    // 只判「连续失败」会误伤 —— 下到一半时网络抖动造成连续失败是正常的。
    BOOL zeroSuccess = (_counterDownloadedFiles == 0);
    BOOL systemic = zeroSuccess && (_consecutiveFailures >= kSystemicFailureLimit);
    [_lock unlock];
    return systemic;
}

- (void)resetConsecutiveFailuresForRetry {
    [_lock lock];
    _consecutiveFailures = 0;
    [_lock unlock];
}

#pragma mark - 进度与收尾

- (void)publishProgress {
    A2BatchProgress *p = [A2BatchProgress new];
    [_lock lock];
    p.downloadedBytes = _counterDownloadedBytes;
    p.totalBytes = _counterTotalBytes;
    p.downloadedFiles = _counterDownloadedFiles;
    p.totalFiles = (NSInteger)_requests.count;

    // 瞬时速度：本次采样与上次采样的字节差 / 时间差
    //
    // 不做平滑 —— 与 ZL2 的 DownloadStats 一致：
    // 「每个报表值就是刚刚完整过去的那一秒里真实落盘的字节数」。
    // 平滑会让数字好看但不真实。
    long long delta = _counterDownloadedBytes - _bytesAtLastTick;
    _bytesAtLastTick = _counterDownloadedBytes;
    p.speedBytesPerSec = (double)MAX(0LL, delta) / kProgressInterval;
    [_lock unlock];

    if (self.onProgress) self.onProgress(p);
}

- (void)finishWithSuccess:(BOOL)success {
    [_progressTimer invalidate];
    _progressTimer = nil;

    [_lock lock];
    NSDictionary<NSString *, NSError *> *fails = [_failures copy];
    NSInteger done = _counterDownloadedFiles;
    [_lock unlock];

    [A2Logger info:@"BatchDownloader"
           message:[NSString stringWithFormat:@"批量下载结束：成功 %ld/%ld，失败 %ld",
                    (long)done, (long)_requests.count, (long)fails.count]];

    if (self.onCompletion) {
        self.onCompletion(success && fails.count == 0, fails);
    }
}

- (void)cancel {
    _cancelled = YES;
    [_progressTimer invalidate];
    _progressTimer = nil;
    // 只取消本批次发起的操作。
    // 之前调 [engine cancelAll] 会把 App 里其他下载（资源详情页、
    // 模组安装）也一起杀掉 —— 用户看到的是「别的下载莫名其妙变失败」。
    [_lock lock];
    NSArray<A2DownloadOperation *> *ops = [self.activeOps copy];
    [self.activeOps removeAllObjects];
    [_lock unlock];

    for (A2DownloadOperation *op in ops) {
        [[A2DownloadEngine sharedClient] cancelOperation:op];
    }
}

@end
