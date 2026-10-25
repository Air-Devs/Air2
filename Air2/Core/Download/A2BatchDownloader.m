//
//  A2BatchDownloader.m
//  Air2
//

#import "A2BatchDownloader.h"
#import "A2Logger.h"

/// 进度回调间隔
static const NSTimeInterval kProgressInterval = 0.5;
/// 系统性故障阈值：整批零成功时，连续这么多个永久失败就中止。
/// 5 个 —— 与「连续 5 文件失败且零成功 ⇒ 整批熔断」对齐：
/// 早先定 12，依赖批量里前 11 个 404 都还在继续打，界面上就是进度不动。
static const NSInteger kSystemicFailureLimit = 5;
/// 批级停滞看门狗：连续这么多秒既没有字节增长、也没有文件完成，就报告一次
static const NSTimeInterval kBatchStallSeconds = 30;

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
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSError *> *failures;
/// 在途文件数（已发起、还没回调）—— 停滞日志里要用来说明「卡在哪一步」
@property (nonatomic, assign) NSInteger counterInFlight;
/// 最近一次「有进展」的时刻（字节增长或文件完成），批级停滞看门狗用
@property (nonatomic, assign) CFAbsoluteTime lastProgressAt;
@property (nonatomic, assign) BOOL stallReported;
/// 是否因系统性故障熔断而中止（finishWithSuccess 据此生成可读错误）
@property (nonatomic, assign) BOOL aborted;

@property (nonatomic, strong) dispatch_queue_t scheduleQueue;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
/// 当前许可池容量 —— 每轮按全局限流闸重算，变了才重建
@property (nonatomic, assign) NSInteger semaphoreCapacity;
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, assign, getter=isCancelled) BOOL cancelled;
@property (nonatomic, assign) BOOL started;
/// 本批已发起的引擎请求句柄 —— 取消时只掐自己这一批。
@property (nonatomic, strong) NSMutableArray<A2DownloadOperation *> *operations;
@property (nonatomic, strong) NSLock *operationsLock;
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
    _operations = [NSMutableArray array];
    _operationsLock = [[NSLock alloc] init];
    _scheduleQueue = dispatch_queue_create("dev.airdevs.air2.batch", DISPATCH_QUEUE_SERIAL);
    _semaphoreCapacity = [[A2DownloadThrottle shared] effectiveConnectionsFor:_maxConnections];
    _semaphore = dispatch_semaphore_create(_semaphoreCapacity);
    _lastProgressAt = CFAbsoluteTimeGetCurrent();
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
    _lastProgressAt = CFAbsoluteTimeGetCurrent();

    // 先登记全部文件的总量 —— 进度分母从一开始就是对的
    [_lock lock];
    for (A2DownloadRequest *req in _requests) {
        _counterTotalBytes += req.expectedSize;
    }
    NSInteger total = (NSInteger)_requests.count;
    NSInteger effective = [[A2DownloadThrottle shared] effectiveConnectionsFor:_maxConnections];
    [_lock unlock];

    [A2Logger info:@"BatchDownloader"
           message:[NSString stringWithFormat:
                    @"[A2-DL] 开始批量下载 文件=%ld 请求并发=%ld 生效并发=%ld 重试轮次=%ld（%@）",
                    (long)total, (long)_maxConnections, (long)effective,
                    (long)_retryRounds,
                    [[A2DownloadThrottle shared] diagnosticDescription]]];

    [self publishProgress];

    __weak typeof(self) weakSelf = self;
    _progressTimer = [NSTimer scheduledTimerWithTimeInterval:kProgressInterval
                                                     repeats:YES
                                                       block:^(NSTimer *t) {
        __strong typeof(weakSelf) self = weakSelf;
        [self publishProgress];
        [self checkBatchStall];
    }];

    [self runRound:0 pending:[_requests mutableCopy]];
}

/// 批级停滞看门狗。
///
/// 单文件层面的看门狗在引擎里（20s 无字节就掐）；这里管的是「整批」：
/// 连着 kBatchStallSeconds 既没有字节增长也没有文件完成，说明要么全部
/// 在途请求都卡着、要么并发许可丢了。打印在途数/已完成数/限流状态，
/// 让人一眼看出卡在哪，而不是只看一个不动的进度条。
- (void)checkBatchStall {
    if (self.isCancelled) return;

    [_lock lock];
    CFAbsoluteTime last = _lastProgressAt;
    NSInteger inFlight = _counterInFlight;
    NSInteger done = _counterDownloadedFiles;
    long long bytes = _counterDownloadedBytes;
    NSInteger totalFiles = (NSInteger)_requests.count;
    [_lock unlock];

    NSTimeInterval idle = CFAbsoluteTimeGetCurrent() - last;
    if (idle < kBatchStallSeconds) {
        self.stallReported = NO;
        return;
    }
    if (self.stallReported) return;   // 停滞期间只报一次，避免刷屏
    self.stallReported = YES;

    [A2Logger warning:@"BatchDownloader"
             message:[NSString stringWithFormat:
                      @"[A2-DL] 批级停滞 %.0fs 文件=%ld/%ld 在途=%ld 已收=%lld 字节（%@）",
                      idle, (long)done, (long)totalFiles, (long)inFlight, bytes,
                      [[A2DownloadThrottle shared] diagnosticDescription]]];
}

#pragma mark - 执行

/// 跑一轮。一轮结束后仍失败的项进入下一轮（最多 retryRounds 次）。
- (void)runRound:(NSInteger)round pending:(NSMutableArray<A2DownloadRequest *> *)pending {
    if (self.isCancelled || pending.count == 0) {
        [self finishWithSuccess:pending.count == 0];
        return;
    }

    // 每轮按全局限流闸的当前上限重建许可池。
    // 轮次之间没有在途请求，重建是安全的；这样 429 之后本该降下来的
    // 并发能真的降下来（早先许可池在 init 里就定死了，限流等于没降）。
    NSInteger effective = [[A2DownloadThrottle shared] effectiveConnectionsFor:_maxConnections];
    if (effective != _semaphoreCapacity) {
        _semaphoreCapacity = effective;
        _semaphore = dispatch_semaphore_create(effective);
        [A2Logger info:@"BatchDownloader"
               message:[NSString stringWithFormat:@"[A2-DL] 本轮并发调整为 %ld（%@）",
                        (long)effective,
                        [[A2DownloadThrottle shared] diagnosticDescription]]];
    }

    // 限流冷却期内先等一等，别硬撞
    NSTimeInterval cooldown = [[A2DownloadThrottle shared] cooldownRemaining];
    if (cooldown > 0.5) {
        [A2Logger info:@"BatchDownloader"
               message:[NSString stringWithFormat:@"[A2-DL] 限流冷却中，%.0fs 后继续", cooldown]];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(cooldown * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.isCancelled) return;
            [self runRound:round pending:pending];
        });
        return;
    }

    [_lock lock];
    _lastProgressAt = CFAbsoluteTimeGetCurrent();
    [_lock unlock];
    self.stallReported = NO;

    [A2Logger info:@"BatchDownloader"
           message:[NSString stringWithFormat:@"[A2-DL] 第 %ld 轮开始，待下载 %lu 个文件",
                    (long)(round + 1), (unsigned long)pending.count]];

    dispatch_group_t group = dispatch_group_create();
    NSMutableArray<A2DownloadRequest *> *stillFailing = [NSMutableArray array];
    NSLock *failLock = [[NSLock alloc] init];
    __block BOOL aborted = NO;

    __weak typeof(self) weakSelf = self;

    for (A2DownloadRequest *req in pending) {
        if (aborted) break;

        dispatch_group_enter(group);
        dispatch_async(_scheduleQueue, ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) { dispatch_group_leave(group); return; }

            // 先取许可再开始 —— 关键：如果先打开文件再排队，
            // 几百个作业会同时持着打开的句柄，拖垮存储层。
            dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);

            if (self.isCancelled || aborted) {
                dispatch_semaphore_signal(self.semaphore);
                dispatch_group_leave(group);
                return;
            }

            __block A2DownloadOperation *operation = nil;
            [self noteFileStarted];
            operation = [[A2DownloadEngine sharedClient] startRequest:req
                progress:^(int64_t delta, int64_t totalIgnore) {
                    (void)totalIgnore;
                    [self addDownloadedBytes:delta];
                }
                speed:nil
                completion:^(BOOL success, NSError *error) {
                [self forgetOperation:operation];
                [self noteFileSettled];
                if (success) {
                    [self markFileDone];
                } else {
                    BOOL systemic = [self recordFailure:req error:error];
                    if (systemic) aborted = YES;
                    [failLock lock];
                    if (!aborted) [stillFailing addObject:req];
                    [failLock unlock];
                }

                if (success && self.onFileSuccess) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (self.onFileSuccess) self.onFileSuccess(req);
                    });
                }

                dispatch_semaphore_signal(self.semaphore);
                dispatch_group_leave(group);
            }];
            [self rememberOperation:operation];
        });
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.isCancelled) return;

        if (aborted) {
            [A2Logger error:@"BatchDownloader"
                     message:[NSString stringWithFormat:
                              @"[A2-DL] 熔断：连续 %ld 个文件失败且零成功，停止剩余文件",
                              (long)kSystemicFailureLimit]];
            [self finishWithSuccess:NO];
            return;
        }

        NSArray<A2DownloadRequest *> *retryList = nil;
        [failLock lock];
        retryList = [stillFailing copy];
        [failLock unlock];

        if (round < self.retryRounds && retryList.count > 0) {
            [A2Logger info:@"BatchDownloader"
                   message:[NSString stringWithFormat:@"第 %ld 轮结束，%lu 个文件待重试",
                            (long)(round + 1), (unsigned long)retryList.count]];
            // 重试前清掉失败计数，否则上一轮攒的会误触发熔断
            [self resetConsecutiveFailuresForRetry];
            [self runRound:round + 1 pending:[retryList mutableCopy]];
        } else {
            [self finishWithSuccess:retryList.count == 0];
        }
    });
}

#pragma mark - 计数

- (void)addDownloadedBytes:(long long)delta {
    [_lock lock];
    _counterDownloadedBytes += delta;
    if (delta > 0) _lastProgressAt = CFAbsoluteTimeGetCurrent();
    [_lock unlock];
}

- (void)markFileDone {
    [_lock lock];
    _counterDownloadedFiles += 1;
    // 任何一次成功都清零连续失败计数 —— 说明网络本身是通的
    _consecutiveFailures = 0;
    _lastProgressAt = CFAbsoluteTimeGetCurrent();
    [_lock unlock];
}

/// 在途文件数增减 —— 停滞诊断要能说清「还有几个在飞」
- (void)noteFileStarted {
    [_lock lock];
    _counterInFlight += 1;
    [_lock unlock];
}

- (void)noteFileSettled {
    [_lock lock];
    if (_counterInFlight > 0) _counterInFlight -= 1;
    _lastProgressAt = CFAbsoluteTimeGetCurrent();
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
    if (systemic) _aborted = YES;
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
    BOOL abortedFlag = _aborted;
    [_lock unlock];

    [A2Logger info:@"BatchDownloader"
           message:[NSString stringWithFormat:@"[A2-DL] 批量下载结束：成功 %ld/%ld，失败 %ld%@",
                    (long)done, (long)_requests.count, (long)fails.count,
                    abortedFlag ? @"（已熔断）" : @""]];

    NSError *abortError = nil;
    if (abortedFlag) {
        // 可读错误：说清「多少个文件、零成功、连续失败几次」，而不是只有一个「失败」。
        NSString *msg = [NSString stringWithFormat:
            @"下载中断：连续 %ld 个文件失败且无一个成功，已停止剩余 %ld 个文件。"
            @"请检查网络或镜像设置后重试（失败示例：%@）",
            (long)kSystemicFailureLimit,
            (long)((NSInteger)_requests.count - done),
            fails.allKeys.firstObject.lastPathComponent ?: @"未知文件"];
        abortError = [NSError errorWithDomain:A2DownloadErrorDomain
                                        code:A2DownloadErrorAllCandidatesExhausted
                                    userInfo:@{NSLocalizedDescriptionKey: msg}];
    }

    if (self.onCompletion) {
        self.onCompletion(success && fails.count == 0, fails, abortError);
    }
}

- (void)cancel {
    [_operationsLock lock];
    _cancelled = YES;
    NSArray<A2DownloadOperation *> *operations = [_operations copy];
    [_operations removeAllObjects];
    [_operationsLock unlock];

    [_progressTimer invalidate];
    _progressTimer = nil;

    // 只取消本批自己发起的请求。
    //
    // 原先这里调 cancelAll：一次「取消安装」会把用户在任务页里跑的
    // 其它下载（资源 / 整合包）一起掐断，属于跨任务误伤。
    for (A2DownloadOperation *operation in operations) {
        [[A2DownloadEngine sharedClient] cancelOperation:operation];
    }
}

#pragma mark - 请求句柄

- (void)rememberOperation:(A2DownloadOperation *)operation {
    if (!operation) return;
    [_operationsLock lock];
    [_operations addObject:operation];
    BOOL cancelled = _cancelled;
    [_operationsLock unlock];
    // 登记与取消之间的竞态：已取消就补一刀，避免漏网的在途请求。
    if (cancelled) [[A2DownloadEngine sharedClient] cancelOperation:operation];
}

- (void)forgetOperation:(A2DownloadOperation *)operation {
    if (!operation) return;
    [_operationsLock lock];
    [_operations removeObjectIdenticalTo:operation];
    [_operationsLock unlock];
}

@end
