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
#import "A2RateLimiter.h"
#import <stdatomic.h>

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

/// 一轮下载的运行时状态。
///
/// 之前这些是 __block 局部变量，配合递归 block 用，有两个坑：
///   1. `A2DownloadOperation *op = [startRequest:... completion:^{ ...op... }]`
///      block 捕获 op 时它还没被赋值（startRequest 尚未返回）→ 垃圾值
///   2. aborted / inFlight 在多线程里裸读裸写
/// 最终表现是 malloc 报堆损坏（abort）。
@interface A2BatchRunState : NSObject
@property (nonatomic, strong) NSMutableArray<A2DownloadRequest *> *queue;
@property (nonatomic, strong) NSMutableArray<A2DownloadRequest *> *stillFailing;
@property (nonatomic, assign) NSInteger inFlight;
@property (nonatomic, assign) NSInteger maxLanes;
@property (nonatomic, assign) NSInteger round;
@property (nonatomic, assign) BOOL aborted;
@property (nonatomic, strong) NSLock *qLock;
@property (nonatomic, weak, nullable) id weakOwner;
@end

@implementation A2BatchRunState
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = [NSMutableArray array];
    _stillFailing = [NSMutableArray array];
    return self;
}
@end

@interface A2BatchDownloader ()
@property (nonatomic, strong) NSArray<A2DownloadRequest *> *requests;
@property (nonatomic, assign) NSInteger maxConnections;
@property (nonatomic, assign) NSInteger retryRounds;

/// 只保护「非计数类」的可变容器（失败表 / 在途操作表）。
/// 计数器全部走原子量（见 @implementation 里的 ivar）—— 见 addDownloadedBytes: 的说明。
@property (nonatomic, strong) NSLock *lock;
/// 上一秒的字节数 —— 用于算瞬时速度
@property (nonatomic, assign) long long bytesAtLastTick;
/// 本批次发起的所有下载操作 —— 取消时逐个取消，
/// 不能调 engine 的 cancelAll（那会杀掉 App 里其他下载）
@property (nonatomic, strong) NSMutableArray<A2DownloadOperation *> *activeOps;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSError *> *failures;

@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, assign) BOOL started;

/// 是否已取消（原子量承载，见 @implementation 里的 _cancelledFlag）
- (BOOL)isCancelled;
@end

@implementation A2BatchDownloader {
    /// ---- 进度计数器：全部原子量 ----
    ///
    /// ZL2 的 DownloadStats 用的是 AtomicLong / AtomicInteger：
    ///   addDownloaded(num)、addCompletedFile()、totalSize、downloadedSize
    /// 读侧永远拿到「某一瞬间自洽」的数，写侧不排队。
    ///
    /// 之前这里是 NSLock + 裸 long long 混用（字节数原子、总大小加锁、
    /// 速度又是加锁读），于是 UI 上会出现「已下载 > 总大小」这种撕裂值：
    /// 总大小那一次读发生在后面的写入之前，而已下载读到了更新的值。
    _Atomic long long _dlBytes;        ///< 已下载字节（可为负：换源回退）
    _Atomic long long _totalBytes;     ///< 总字节（含已复用文件）
    _Atomic int      _doneFiles;       ///< 已完成文件数
    _Atomic int      _consecutiveFails;
    _Atomic int      _cancelledFlag;
}

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
    _activeOps = [NSMutableArray array];
    atomic_store(&_dlBytes, 0);
    atomic_store(&_totalBytes, 0);
    atomic_store(&_doneFiles, 0);
    atomic_store(&_consecutiveFails, 0);
    atomic_store(&_cancelledFlag, 0);
    return self;
}

#pragma mark - 取消标志

- (BOOL)isCancelled {
    return atomic_load(&_cancelledFlag) != 0;
}

#pragma mark - 登记

- (void)registerReusedFileWithPath:(NSString *)path size:(long long)size {
    (void)path;
    atomic_fetch_add(&_doneFiles, 1);
    atomic_fetch_add(&_totalBytes, size);
    atomic_fetch_add(&_dlBytes, size);
}

#pragma mark - 启动

- (void)start {
    if (_started) return;
    _started = YES;
    atomic_store(&_cancelledFlag, 0);

    // 先登记全部文件的总量 —— 进度分母从一开始就是对的
    long long total = 0;
    for (A2DownloadRequest *req in _requests) {
        total += req.expectedSize;
    }
    atomic_store(&_totalBytes, total);
    NSInteger count = (NSInteger)_requests.count;

    [A2Logger info:@"BatchDownloader"
           message:[NSString stringWithFormat:@"开始批量下载 %ld 个文件，并发 %ld",
                    (long)count, (long)_maxConnections]];

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

    // ---- 状态全部包在一个类里，避免 block 捕获大量局部变量 ----
    //
    // 之前用 __block 局部变量（queue / inFlight / stillFailing / aborted）
    // 配合递归 block，问题是：
    //   1. `A2DownloadOperation *op = [startRequest:... completion:^{ ...op... }]`
    //      —— block 捕获 op 时它还没被赋值（startRequest 尚未返回），是垃圾值
    //   2. aborted 在多个线程里裸读裸写
    //   结果就是 malloc 报堆损坏（abort）。
    //
    // 现在用一个独立对象持有状态，所有访问走它的锁。
    A2BatchRunState *state = [A2BatchRunState new];
    state.queue = [pending mutableCopy];
    state.maxLanes = MIN(_maxConnections, (NSInteger)state.queue.count);
    state.weakOwner = self;
    state.round = round;
    state.qLock = [[NSLock alloc] init];

    [self pumpWithState:state];
}

/// 填满空闲车道。
/// 每次只启动「当前空闲数」个，完成一个回调里再调一次 ——
/// 线程数恒定，与文件总数无关。
- (void)pumpWithState:(A2BatchRunState *)state {
    __weak typeof(self) weakSelf = self;

    while (YES) {
        A2DownloadRequest *req = nil;
        @synchronized (state) {
            if (state.aborted || self.isCancelled) break;
            if (state.inFlight >= state.maxLanes) break;
            req = state.queue.firstObject;
            if (!req) break;
            [state.queue removeObjectAtIndex:0];
            state.inFlight += 1;
        }

        // 立刻外面开始下载
        [self startOneRequest:req state:state];
    }

    // 没有在途任务也没有待办 → 本轮结束
    BOOL done = NO;
    @synchronized (state) {
        done = (state.inFlight == 0 && state.queue.count == 0);
    }
    if (done) {
        [self finishRound:state];
    }
    (void)weakSelf;
}

- (void)startOneRequest:(A2DownloadRequest *)req state:(A2BatchRunState *)state {
    __weak typeof(self) weakSelf = self;

    A2DownloadOperation *op =
    [[A2DownloadEngine sharedClient] startRequest:req
        progress:^(int64_t delta, int64_t totalIgnore) {
            (void)totalIgnore;
            [weakSelf addDownloadedBytes:delta];
        }
        speed:nil
        completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        // 句柄用完即摘：否则 cancel 时会对已完成的操作再取消一遍
        [self untrackOperationForRequest:req];

        BOOL systemic = NO;
        if (success) {
            [self markFileDone];
        } else {
            systemic = [self recordFailure:req error:error];
        }

        @synchronized (state) {
            state.inFlight -= 1;
            if (systemic) {
                state.aborted = YES;
                [state.queue removeAllObjects];
            } else if (!success) {
                [state.stillFailing addObject:req];
            }
        }

        if (success && self.onFileSuccess) {
            A2DownloadRequest *r = req;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onFileSuccess) self.onFileSuccess(r);
            });
        }

        // 拉下一个，把车道填满
        [self pumpWithState:state];
    }];

    // ★在途句柄必须登记★
    //   之前 startRequest: 的返回值被直接丢掉，activeOps 永远是空数组，
    //   于是 cancel 只能「不再发新文件」，已经在飞的几十个下载继续跑到完 ——
    //   用户看到的就是「点了取消还在下」。
    if (op) {
        BOOL alreadyCancelled = NO;
        [_lock lock];
        alreadyCancelled = atomic_load(&_cancelledFlag) != 0;
        if (!alreadyCancelled) [_activeOps addObject:op];
        [_lock unlock];
        if (alreadyCancelled) {
            [[A2DownloadEngine sharedClient] cancelOperation:op];
        }
    }
}

/// 摘掉某个文件对应的在途句柄（完成 / 取消时调用；重复调用安全）
- (void)untrackOperationForRequest:(A2DownloadRequest *)req {
    if (req.destinationPath.length == 0) return;
    [_lock lock];
    NSMutableArray<A2DownloadOperation *> *kept = [NSMutableArray array];
    for (A2DownloadOperation *op in _activeOps) {
        if (op.request.destinationPath &&
            [op.request.destinationPath isEqualToString:req.destinationPath]) continue;
        [kept addObject:op];
    }
    [_activeOps setArray:kept];
    [_lock unlock];
}

- (void)finishRound:(A2BatchRunState *)state {
    if (self.isCancelled) return;

    if (state.aborted) {
        [A2Logger error:@"BatchDownloader"
                 message:@"检测到系统性故障（整批零成功且连续多次失败），已中止剩余文件"];
        [self finishWithSuccess:NO];
        return;
    }

    NSArray<A2DownloadRequest *> *retryList = nil;
    @synchronized (state) {
        retryList = [state.stillFailing copy];
    }

    if (state.round < self.retryRounds && retryList.count > 0) {
        [A2Logger info:@"BatchDownloader"
               message:[NSString stringWithFormat:@"第 %ld 轮结束，%lu 个文件待重试",
                        (long)(state.round + 1), (unsigned long)retryList.count]];
        [self resetConsecutiveFailuresForRetry];
        [self runRound:state.round + 1 pending:[retryList mutableCopy]];
    } else {
        [self finishWithSuccess:retryList.count == 0];
    }
}

#pragma mark - 计数

/// 累加已下载字节。
///
/// 这是**热路径**：64 个并发下载时每秒可能调用上千次
/// （每个分片回调一次），用 NSLock 会在锁上排队，
/// 拖慢整条下载链路。
///
/// 改成原子自增 —— 单个 long long 的读改写本来就该用原子操作，
/// 不需要锁。读的时候用 atomic load 即可（64 位对齐在 arm64 上
/// 本身就是原子的，但用 stdatomic 语义更明确）。
///
/// ★负增量必须接受★：换源/校验失败时引擎会回退上报，
/// 丢掉负值会让「已下载」永久性偏高（用户看到 120%，或者进度条不回退）。
- (void)addDownloadedBytes:(long long)delta {
    if (delta == 0) return;
    atomic_fetch_add(&_dlBytes, delta);
}

- (void)markFileDone {
    atomic_fetch_add(&_doneFiles, 1);
    // 任何一次成功都清零连续失败计数 —— 说明网络本身是通的
    atomic_store(&_consecutiveFails, 0);
}

/// 记录失败。返回 YES 表示触发了系统性故障熔断。
- (BOOL)recordFailure:(A2DownloadRequest *)req error:(NSError *)error {
    if (req.destinationPath.length) {
        [_lock lock];
        _failures[req.destinationPath] = error ?: [NSError errorWithDomain:@"A2Batch" code:1
                                                                 userInfo:nil];
        [_lock unlock];
    }
    int fails = atomic_fetch_add(&_consecutiveFails, 1) + 1;

    // 熔断条件：一次都没成功过 + 连续失败达到阈值。
    // 只判「连续失败」会误伤 —— 下到一半时网络抖动造成连续失败是正常的。
    BOOL zeroSuccess = (atomic_load(&_doneFiles) == 0);
    return zeroSuccess && (fails >= kSystemicFailureLimit);
}

- (void)resetConsecutiveFailuresForRetry {
    atomic_store(&_consecutiveFails, 0);
}

#pragma mark - 进度与收尾

- (void)publishProgress {
    A2BatchProgress *p = [A2BatchProgress new];

    // ★一次读齐★ 三个数在同一段原子读里取出，UI 不会看到
    //   「已下载 300MB / 共 200MB」这种自相矛盾的快照。
    long long done = atomic_load(&_dlBytes);
    if (done < 0) done = 0;                       // 回退到 0 为止，不显示负数
    long long total = atomic_load(&_totalBytes);
    if (total < done) total = done;               // 分母兜底：HEAD 失败/服务端不给大小时
    p.downloadedBytes = done;
    p.totalBytes = total;
    p.downloadedFiles = (NSInteger)atomic_load(&_doneFiles);
    p.totalFiles = (NSInteger)_requests.count;

    // 瞬时速度：本次采样与上次采样的字节差 / 时间差
    //
    // 不做平滑 —— 与 ZL2 的 DownloadStats 一致：
    // 「每个报表值就是刚刚完整过去的那一秒里真实落盘的字节数」。
    // 平滑会让数字好看但不真实。
    long long delta = done - _bytesAtLastTick;
    _bytesAtLastTick = done;
    p.speedBytesPerSec = (double)MAX(0LL, delta) / kProgressInterval;

    if (self.onProgress) self.onProgress(p);
}

- (void)finishWithSuccess:(BOOL)success {
    [_progressTimer invalidate];
    _progressTimer = nil;

    [_lock lock];
    NSDictionary<NSString *, NSError *> *fails = [_failures copy];
    [_lock unlock];
    NSInteger done = (NSInteger)atomic_load(&_doneFiles);

    [A2Logger info:@"BatchDownloader"
           message:[NSString stringWithFormat:@"批量下载结束：成功 %ld/%ld，失败 %ld",
                    (long)done, (long)_requests.count, (long)fails.count]];

    if (self.onCompletion) {
        self.onCompletion(success && fails.count == 0, fails);
    }
}

- (void)cancel {
    atomic_store(&_cancelledFlag, 1);
    [_progressTimer invalidate];
    _progressTimer = nil;
    // 只取消本批次发起的操作。
    // 之前调 [engine cancelAll] 会把 App 里其他下载（资源详情页、
    // 模组安装）也一起杀掉 —— 用户看到的是「别的下载莫名其妙变失败」。
    [_lock lock];
    NSArray<A2DownloadOperation *> *ops = [self.activeOps copy];
    [self.activeOps removeAllObjects];
    [_lock unlock];

    [A2Logger info:@"BatchDownloader"
           message:[NSString stringWithFormat:@"取消：逐个取消 %lu 个在途下载",
                    (unsigned long)ops.count]];
    for (A2DownloadOperation *op in ops) {
        [[A2DownloadEngine sharedClient] cancelOperation:op];
    }
}

@end
