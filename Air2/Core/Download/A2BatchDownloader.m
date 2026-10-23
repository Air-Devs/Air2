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
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSError *> *failures;

@property (nonatomic, strong) dispatch_queue_t scheduleQueue;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
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
    _semaphore = dispatch_semaphore_create(_maxConnections);
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

/// 跑一轮。一轮结束后仍失败的项进入下一轮（最多 retryRounds 次）。
- (void)runRound:(NSInteger)round pending:(NSMutableArray<A2DownloadRequest *> *)pending {
    if (self.isCancelled || pending.count == 0) {
        [self finishWithSuccess:pending.count == 0];
        return;
    }

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
            operation = [[A2DownloadEngine sharedClient] startRequest:req
                progress:^(int64_t delta, int64_t totalIgnore) {
                    (void)totalIgnore;
                    [self addDownloadedBytes:delta];
                }
                speed:nil
                completion:^(BOOL success, NSError *error) {
                [self forgetOperation:operation];
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
                     message:@"检测到系统性故障（整批零成功且连续多次失败），已中止剩余文件"];
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
    [_lock unlock];
}

- (void)markFileDone {
    [_lock lock];
    _counterDownloadedFiles += 1;
    // 任何一次成功都清零连续失败计数 —— 说明网络本身是通的
    _consecutiveFailures = 0;
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
