#import "utils.h"
//
//  PLDownloadClient.m
//  Amethyst
//
//  统一下载客户端实现（spec: optimize-download-system Task 1.2）。
//
//  核心思想参考 ZalithLauncher2 NetWorkUtils（downloadFromMirrorList /
//  withSpeedReport）：
//   - 镜像顺序尝试 + 单候选多次尝试，失败时以负 delta 回退本次尝试已上报的下载量，
//     保证调用方累计值单调贴合真实进度；
//   - 每秒采样一次字节计数器汇报速率，结束/暂停时清零上报。
//  在 NSURLSession 体系下落地：delegate 串行队列接收回调，统一派发到内部
//  串行状态队列（stateQueue）推进状态机，保证 start/pause/resume/cancel
//  可从任意线程安全调用。
//

#import "PLDownloadClient.h"
#import <CommonCrypto/CommonDigest.h>

NSString *const PLDownloadClientErrorDomain = @"PLDownloadClientErrorDomain";
NSString *const PLDownloadClientUnderlyingErrorsKey = @"PLDownloadClientUnderlyingErrorsKey";

/// 单候选 URL 的最大重试次数（指数退避 1s / 2s / 4s，参考 ZL2 与 FCL 的退避节奏）
static const NSUInteger PLDownloadMaxRetryPerCandidate = 3;
/// 退避基础延迟（秒），第 n 次重试延迟 = base << (n-1)
static const NSTimeInterval PLDownloadRetryDelayBase = 1.0;
/// zip EOCD 兜底扫描的文件尾窗口：EOCD 22 字节 + 最大注释 65535 字节
static const unsigned long long PLDownloadZipEOCDMaxTailBytes = 65557;
/// SHA1 流式计算的读取块大小
static const NSUInteger PLDownloadHashChunkSize = 256 * 1024;
/// resumeData 落盘目录名（位于 NSTemporaryDirectory() 下）
static NSString *const PLDownloadResumeDirectoryName = @"PLDownloadResume";

#pragma mark - 工具函数

/// 构造本错误域的 NSError
static NSError *PLDownloadErrorMake(PLDownloadClientErrorCode code, NSString *desc, NSError *_Nullable underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = desc ?: @"";
    if (underlying) {
        userInfo[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:PLDownloadClientErrorDomain code:code userInfo:userInfo];
}

/// NSData 的 SHA1 十六进制（小写）
static NSString *_Nullable PLDownloadSHA1HexForData(NSData *data) {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

/// NSString 的 SHA1 十六进制（用于稳定派生 taskIdentifier）
static NSString *_Nullable PLDownloadSHA1HexForString(NSString *string) {
    return PLDownloadSHA1HexForData([string dataUsingEncoding:NSUTF8StringEncoding]);
}

/// 文件的流式 SHA1 十六进制（CommonCrypto CC_SHA1 分块计算，支持任意大文件）
static NSString *_Nullable PLDownloadSHA1HexForFile(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        return nil;
    }
    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);
    @try {
        for (;;) {
            NSData *chunk = [handle readDataOfLength:PLDownloadHashChunkSize];
            if (chunk.length == 0) {
                break;
            }
            CC_SHA1_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
        }
    } @catch (NSException *exception) {
        [handle closeFile];
        return nil;
    }
    [handle closeFile];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

/// zip 兜底校验：从文件尾扫描 End of Central Directory 签名 "PK\x05\x06"。
/// EOCD 位于文件末尾（22 字节固定结构 + 最大 65535 字节注释），在最后 65557
/// 字节内找到签名即认为文件完整（参考 ZL2 compareSHA1 缺失时的兜底思路）。
/// 用 NSFileHandle 实现，无第三方依赖。
static BOOL PLDownloadZipHasEOCDAtPath(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        return NO;
    }
    unsigned long long fileSize = [handle seekToEndOfFile];
    unsigned long long tailLength = fileSize < PLDownloadZipEOCDMaxTailBytes ? fileSize : PLDownloadZipEOCDMaxTailBytes;
    if (tailLength < 4) {
        [handle closeFile];
        return NO;
    }
    [handle seekToFileOffset:fileSize - tailLength];
    NSData *tailData = [handle readDataOfLength:tailLength];
    [handle closeFile];
    if (tailData.length != tailLength) {
        return NO;
    }
    // "PK\x05\x06"（0x50 0x4B 0x05 0x06），从尾部向前搜索
    const uint8_t signature[4] = {0x50, 0x4B, 0x05, 0x06};
    NSData *signatureData = [NSData dataWithBytes:signature length:4];
    NSRange range = [tailData rangeOfData:signatureData
                                  options:NSDataSearchBackwards
                                    range:NSMakeRange(0, tailData.length)];
    return range.location != NSNotFound;
}

/// 完整性校验：SHA1 优先，其次 zip EOCD 兜底；返回 nil 表示通过
static NSError *_Nullable PLDownloadValidateFile(NSString *path, PLDownloadRequest *request) {
    if (request.expectedSHA1.length > 0) {
        NSString *actual = PLDownloadSHA1HexForFile(path);
        if (!actual || ![actual.lowercaseString isEqualToString:request.expectedSHA1.lowercaseString]) {
            return PLDownloadErrorMake(PLDownloadClientErrorCodeChecksumMismatch,
                [NSString stringWithFormat:localize(@"i18n_str_832", nil),
                    request.expectedSHA1, actual ?: localize(@"i18n_str_833", nil), path.lastPathComponent],
                nil);
        }
        return nil;
    }
    if (request.allowZipFallbackCheck) {
        NSString *extension = request.destinationPath.pathExtension.lowercaseString;
        if ([extension isEqualToString:@"zip"] || [extension isEqualToString:@"jar"]) {
            if (!PLDownloadZipHasEOCDAtPath(path)) {
                return PLDownloadErrorMake(PLDownloadClientErrorCodeChecksumMismatch,
                    [NSString stringWithFormat:localize(@"i18n_str_834", nil),
                        path.lastPathComponent],
                    nil);
            }
        }
    }
    return nil;
}

#pragma mark - PLDownloadRequest

@implementation PLDownloadRequest
// 纯数据模型：五个属性均由编译器自动合成（nonatomic/copy/assign），
// 初始化默认值由调用方按需赋值（allowZipFallbackCheck 默认 NO）
@end

#pragma mark - PLDownloadOperation（内部）

@interface PLDownloadOperation ()
@property (nonatomic, strong) PLDownloadRequest *request;
@property (nonatomic, assign) PLDownloadOperationState state;
@property (nonatomic, copy, nullable) NSData *resumeData;
@property (nonatomic, weak, nullable) PLDownloadClient *client;
@property (nonatomic, copy, nullable) PLDownloadProgressHandler progressHandler;
@property (nonatomic, copy, nullable) PLDownloadSpeedHandler speedHandler;
@property (nonatomic, copy) PLDownloadCompletion completionHandler;

/// 私有指定初始化器（公开 init 已标记 NS_UNAVAILABLE，仅供本类与 client 调用）
- (instancetype)initWithRequest:(PLDownloadRequest *)request
                         client:(PLDownloadClient *)client
                       progress:(nullable PLDownloadProgressHandler)progress
                          speed:(nullable PLDownloadSpeedHandler)speed
                     completion:(PLDownloadCompletion)completion;

// ---- 尝试状态（仅 stateQueue 访问）----
/// 当前候选 URL 索引
@property (nonatomic, assign) NSUInteger urlIndex;
/// 当前候选已重试次数（0..PLDownloadMaxRetryPerCandidate）
@property (nonatomic, assign) NSUInteger retryCount;
/// 本次尝试已上报的正向字节数，失败 / 切换时用于负 delta 回退（参考 ZL2 attemptReportedBytes）
@property (nonatomic, assign) int64_t attemptReportedBytes;
/// 当前任务生命周期内最后一次上报的 totalBytesWritten（delta 计算基准）
@property (nonatomic, assign) int64_t lastReportedBytes;
/// 本次连续下载段内是否已有正向上报（区分"恢复基线静默对齐"与"断点失效回退"）
@property (nonatomic, assign) BOOL hasReportedInStretch;
/// 当前活动下载任务
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask *currentTask;
/// 每个候选 URL 的最后一次错误（索引 → 错误），用于聚合错误
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSError *> *candidateErrors;
/// 状态代数：pause / resume / cancel / 终态时自增，使过期的 dispatch_after 退避回调失效
@property (nonatomic, assign) uint64_t generation;

// ---- delegate 队列 → stateQueue 传递（didFinishDownloadingToURL 同步阶段写入）----
/// didFinishDownloadingToURL 已移动就绪的半成品文件路径（.part）
@property (nonatomic, copy, nullable) NSString *pendingPartPath;
/// didFinishDownloadingToURL 阶段记录的错误（HTTP 非 2xx / 移动失败）
@property (nonatomic, copy, nullable) NSError *pendingDownloadError;

// ---- 断点续传 ----
/// 待用于创建 downloadTaskWithResumeData: 的断点数据（一次性）
@property (nonatomic, copy, nullable) NSData *pendingResumeData;
/// 稳定的 resumeData 存取键（taskIdentifier 或派生值）
@property (nonatomic, copy) NSString *resolvedTaskIdentifier;

// ---- 速率统计 ----
@property (nonatomic, strong, nullable) dispatch_source_t speedTimer;
/// 自上次采样以来的字节增量（NSLock 保护，参考 ZL2 withSpeedReport 的 AtomicLong 计数器）
@property (nonatomic, assign) int64_t pendingSpeedBytes;
@property (nonatomic, strong) NSLock *speedLock;

/// completion 恰好回调一次的保护
@property (nonatomic, assign) BOOL completionDelivered;
@end

@implementation PLDownloadOperation

- (instancetype)initWithRequest:(PLDownloadRequest *)request
                         client:(PLDownloadClient *)client
                       progress:(nullable PLDownloadProgressHandler)progress
                          speed:(nullable PLDownloadSpeedHandler)speed
                     completion:(PLDownloadCompletion)completion {
    self = [super init];
    if (!self) {
        return nil;
    }
    _request = request;
    _client = client;
    _progressHandler = progress;
    _speedHandler = speed;
    _completionHandler = completion;
    _state = PLDownloadOperationStateRunning;
    _candidateErrors = [NSMutableDictionary dictionary];
    _speedLock = [[NSLock alloc] init];
    return self;
}

#pragma mark 速率计数（NSLock 保护，timer 与 stateQueue 均可访问）

- (void)appendSpeedBytes:(int64_t)delta {
    [self.speedLock lock];
    self->_pendingSpeedBytes += delta;
    [self.speedLock unlock];
}

/// 取走并清零累计字节（对应 ZL2 withSpeedReport 的 bytesWritten.getAndSet(0)）
- (int64_t)takePendingSpeedBytes {
    [self.speedLock lock];
    int64_t bytes = self->_pendingSpeedBytes;
    self->_pendingSpeedBytes = 0;
    [self.speedLock unlock];
    return bytes;
}

- (void)drainPendingSpeedBytes {
    [self takePendingSpeedBytes];
}

@end

#pragma mark - 会话回调转发声明

/// NSURLSession delegate 回调经独立 delegate 对象转发回 client（实现在 @implementation 内）。
/// delegate 类定义于下方、早于类扩展与实现，故在此提前声明保证编译可见。
@interface PLDownloadClient (SessionDelegateForwarding)
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error;
- (void)URLSession:(NSURLSession *)session
       downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location;
- (void)URLSession:(NSURLSession *)session
       downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite;
- (void)URLSession:(NSURLSession *)session
       downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes;
@end

#pragma mark - 会话 delegate（独立对象打破 session → client 强引用循环）

/// NSURLSession 的 delegate 对象被会话强持有；若直接用 client 做 delegate，
/// client 持有 session、session 持有 client 会造成循环引用。此处用独立轻量对象
/// 弱引用 client 转发回调，client 释放时由 dealloc invalidate 会话解除持有。
@interface PLDownloadSessionDelegate : NSObject <NSURLSessionDownloadDelegate, NSURLSessionDelegate>
@property (nonatomic, weak, nullable) PLDownloadClient *client;
@end

@implementation PLDownloadSessionDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error {
    [self.client URLSession:session task:task didCompleteWithError:error];
}

- (void)URLSession:(NSURLSession *)session
       downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    [self.client URLSession:session downloadTask:downloadTask didFinishDownloadingToURL:location];
}

- (void)URLSession:(NSURLSession *)session
       downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    [self.client URLSession:session
                downloadTask:downloadTask
                  didWriteData:bytesWritten
             totalBytesWritten:totalBytesWritten
        totalBytesExpectedToWrite:totalBytesExpectedToWrite];
}

- (void)URLSession:(NSURLSession *)session
       downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes {
    [self.client URLSession:session
                downloadTask:downloadTask
              didResumeAtOffset:fileOffset
           expectedTotalBytes:expectedTotalBytes];
}

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(nullable NSError *)error {
    if (error) {
        NSLog(@"[PLDownload] Session invalidated with error: %@", error);
    }
}

@end

#pragma mark - PLDownloadClient

@interface PLDownloadClient ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) PLDownloadSessionDelegate *sessionDelegate;
/// 串行状态队列：所有状态机推进与 pause/resume/cancel 入口均在此执行
@property (nonatomic, strong) dispatch_queue_t stateQueue;
/// task → operation 映射（NSLock 保护：didFinishDownloadingToURL 在 delegate 队列同步读取）
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, PLDownloadOperation *> *operations;
@property (nonatomic, strong) NSLock *operationsLock;
@end

@implementation PLDownloadClient

#pragma mark 生命周期

+ (instancetype)sharedClient {
    static PLDownloadClient *sharedClient = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedClient = [[PLDownloadClient alloc] initWithSessionConfiguration:nil];
    });
    return sharedClient;
}

- (instancetype)initWithSessionConfiguration:(nullable NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (!self) {
        return nil;
    }

    NSURLSessionConfiguration *config = [configuration copy];
    if (!config) {
        // 默认前台配置：后台会话会被 nsurlsessiond 限流（参照
        // MinecraftResourceDownloadTask / ModService 的结论），前台会话即下即用。
        config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.HTTPMaximumConnectionsPerHost = 8;
        // 60 秒无数据即判定候选故障，尽快切换镜像；总时长放宽以支持大文件
        config.timeoutIntervalForRequest = 60.0;
        config.timeoutIntervalForResource = 86400.0;
    }

    _stateQueue = dispatch_queue_create("com.angelaura.pldownloadclient.state", DISPATCH_QUEUE_SERIAL);
    _operationsLock = [[NSLock alloc] init];
    _operations = [NSMutableDictionary dictionary];
    _sessionDelegate = [[PLDownloadSessionDelegate alloc] init];
    _sessionDelegate.client = self;

    // delegate 队列保持串行，保证 didFinishDownloadingToURL（同步移动文件）与
    // didCompleteWithError 的顺序性
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.name = @"com.angelaura.pldownloadclient.delegate";
    delegateQueue.maxConcurrentOperationCount = 1;

    _session = [NSURLSession sessionWithConfiguration:config
                                             delegate:_sessionDelegate
                                        delegateQueue:delegateQueue];
    return self;
}

- (void)dealloc {
    // session 强持有 _sessionDelegate；invalidate 后释放，避免会话对象泄漏
    [_session invalidateAndCancel];
}

#pragma mark - 公开 API

- (nullable PLDownloadOperation *)startRequest:(PLDownloadRequest *)request
                                      progress:(nullable PLDownloadProgressHandler)progress
                                         speed:(nullable PLDownloadSpeedHandler)speed
                                    completion:(PLDownloadCompletion)completion {
    // 参数校验（轻量，无 IO）
    if (!request || request.candidateURLs.count == 0 || request.destinationPath.length == 0) {
        NSError *error = PLDownloadErrorMake(PLDownloadClientErrorCodeInvalidParameter,
            localize(@"i18n_str_835", nil), nil);
        if (completion) {
            dispatch_async(self.stateQueue, ^{
                completion(NO, error);
            });
        }
        return nil;
    }

    PLDownloadOperation *operation = [[PLDownloadOperation alloc] initWithRequest:request
                                                                            client:self
                                                                          progress:progress
                                                                             speed:speed
                                                                        completion:completion];
    [self resolveTaskIdentifierForOperation:operation];

    dispatch_async(self.stateQueue, ^{
        [self beginOperation:operation];
    });
    return operation;
}

- (void)pauseOperation:(id)operation {
    dispatch_async(self.stateQueue, ^{
        if (![operation isKindOfClass:[PLDownloadOperation class]]) {
            return;
        }
        PLDownloadOperation *op = (PLDownloadOperation *)operation;
        if (op.client != self || op.state != PLDownloadOperationStateRunning) {
            return;
        }
        op.state = PLDownloadOperationStatePaused;
        op.generation++; // 使挂起的退避重试失效（恢复时立即重试当前候选）
        [self stopSpeedTimerForOperation:op reportZero:YES];
        NSLog(@"[PLDownload] Pause %@", op.request.destinationPath.lastPathComponent);
        if (op.currentTask) {
            // resumeData 的提取在 didCompleteWithError(NSURLErrorCancelled) 的
            // stateQueue 处理中完成（避免与 resumeOperation 的跨队列竞态），
            // 此处的 completionHandler 仅需非 nil
            [op.currentTask cancelByProducingResumeData:^(NSData *_Nullable resumeData) {
                // 服务器不支持续传时 resumeData 为 nil，走重新下载路径
                if (!resumeData) {
                    NSLog(@"[PLDownload] Pause produced no resumeData (server may not support Range)");
                }
            }];
        }
    });
}

- (void)resumeOperation:(id)operation {
    dispatch_async(self.stateQueue, ^{
        if (![operation isKindOfClass:[PLDownloadOperation class]]) {
            return;
        }
        PLDownloadOperation *op = (PLDownloadOperation *)operation;
        if (op.client != self || op.state != PLDownloadOperationStatePaused) {
            return;
        }
        op.state = PLDownloadOperationStateRunning;
        NSLog(@"[PLDownload] Resume %@", op.request.destinationPath.lastPathComponent);
        if (!op.pendingResumeData) {
            // 内存断点缺失时回退读磁盘（覆盖 App 重启后恢复的场景）
            NSData *stored = [self storedResumeDataForOperation:op];
            if (stored.length > 0) {
                op.pendingResumeData = stored;
            }
        }
        // 注意：此处不重置 lastReportedBytes / attemptReportedBytes——
        // 若断点可用，didResumeAtOffset 会以实际偏移对齐基线（正向补差）；
        // 若断点失效从 0 重下，首次 didWriteData 的 delta 自然为负，自动回退
        // 已上报字节，两种情况进度累计都正确。
        [self startAttemptForOperation:op];
    });
}

- (void)cancelOperation:(id)operation {
    dispatch_async(self.stateQueue, ^{
        if (![operation isKindOfClass:[PLDownloadOperation class]]) {
            return;
        }
        PLDownloadOperation *op = (PLDownloadOperation *)operation;
        if (op.client != self ||
            (op.state != PLDownloadOperationStateRunning && op.state != PLDownloadOperationStatePaused)) {
            return;
        }
        op.state = PLDownloadOperationStateCancelled;
        op.generation++;
        [self stopSpeedTimerForOperation:op reportZero:YES];
        if (op.currentTask) {
            [op.currentTask cancel];
            op.currentTask = nil;
        }
        op.pendingResumeData = nil;
        op.pendingPartPath = nil;
        op.pendingDownloadError = nil;
        // 删除 resumeData 与半成品文件
        [self removeResumeDataForOperation:op];
        [[NSFileManager defaultManager] removeItemAtPath:[self partPathForOperation:op] error:nil];
        NSLog(@"[PLDownload] Cancel %@", op.request.destinationPath.lastPathComponent);
        NSError *cancelled = [NSError errorWithDomain:NSURLErrorDomain
                                                  code:NSURLErrorCancelled
                                              userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_836", nil)}];
        [self deliverCompletionForOperation:op success:NO error:cancelled];
    });
}

#pragma mark - 状态机（仅 stateQueue 调用）

/// 操作起点：增量检查 → 磁盘断点恢复 → 发起首次尝试
- (void)beginOperation:(PLDownloadOperation *)op {
    // 增量下载（spec Phase 5 / ZL2 思想）：目标文件已存在且校验通过 → 直接成功，
    // 不产生任何网络流量
    if ([[NSFileManager defaultManager] fileExistsAtPath:op.request.destinationPath]) {
        NSError *existingError = PLDownloadValidateFile(op.request.destinationPath, op.request);
        if (!existingError) {
            op.state = PLDownloadOperationStateCompleted;
            [self removeResumeDataForOperation:op]; // 文件已完整，陈旧断点无意义
            NSLog(@"[PLDownload] Incremental hit: %@", op.request.destinationPath.lastPathComponent);
            [self deliverCompletionForOperation:op success:YES error:nil];
            return;
        }
        // 已存在但校验不过：保留旧文件继续下载，成功后原子替换（失败时旧文件不动）
    }

    // 磁盘存在同 taskIdentifier 的 resumeData（上次暂停 / App 被杀）→ 优先续传
    NSData *stored = [self storedResumeDataForOperation:op];
    if (stored.length > 0) {
        op.pendingResumeData = stored;
        NSLog(@"[PLDownload] Restored resumeData (%llu bytes) for %@",
            (unsigned long long)stored.length, op.request.destinationPath.lastPathComponent);
    }

    [self startAttemptForOperation:op];
}

/// 发起一次下载尝试（新候选 / 重试 / 恢复共用入口）
- (void)startAttemptForOperation:(PLDownloadOperation *)op {
    if (op.state != PLDownloadOperationStateRunning) {
        return;
    }
    NSURL *url = op.request.candidateURLs[op.urlIndex];

    NSURLSessionDownloadTask *task = nil;
    NSData *resumeData = op.pendingResumeData;
    if (resumeData.length > 0) {
        // 断点续传：优先用 resumeData 恢复（spec Phase 2 真断点续传）
        op.pendingResumeData = nil; // 一次性消费；失败重试一律从头，保证 delta 语义清晰
        task = [self.session downloadTaskWithResumeData:resumeData];
        NSLog(@"[PLDownload] Attempt (resume) %lu/%lu retry=%lu %@",
            (unsigned long)(op.urlIndex + 1), (unsigned long)op.request.candidateURLs.count,
            (unsigned long)op.retryCount, url.host);
    } else {
        task = [self.session downloadTaskWithURL:url];
        NSLog(@"[PLDownload] Attempt %lu/%lu retry=%lu %@",
            (unsigned long)(op.urlIndex + 1), (unsigned long)op.request.candidateURLs.count,
            (unsigned long)op.retryCount, url.host);
    }
    if (!task) {
        // 理论不可达（URL 已过参数校验）；防御性走失败路径
        [self handleAttemptFailureForOperation:op
            error:PLDownloadErrorMake(PLDownloadClientErrorCodeInvalidParameter,
                [NSString stringWithFormat:localize(@"i18n_str_837", nil), url.absoluteString], nil)];
        return;
    }

    op.currentTask = task;
    [self setOperation:op forTask:task];
    [self startSpeedTimerForOperation:op];
    [task resume];
}

/// 任务结束（didCompleteWithError 派发而来）后的统一处理
- (void)handleTaskCompletion:(NSURLSessionTask *)task error:(nullable NSError *)error {
    PLDownloadOperation *op = [self takeOperationForTask:task];
    if (!op) {
        return;
    }
    NSString *partPath = [self partPathForOperation:op];

    BOOL isCancelledError = [error.domain isEqualToString:NSURLErrorDomain] &&
                            error.code == NSURLErrorCancelled;
    if (error && isCancelledError) {
        // 取消类错误：可能是 pause / cancel / 已被新尝试取代的旧任务。
        // 仅当仍是当前活动任务且处于 Paused 时提取 resumeData 落盘，其余静默丢弃
        if (op.currentTask == task && op.state == PLDownloadOperationStatePaused) {
            NSData *resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData];
            if (resumeData.length > 0) {
                op.resumeData = resumeData;
                op.pendingResumeData = resumeData;
                [self persistResumeData:resumeData forOperation:op];
            } else {
                op.pendingResumeData = nil;
                [self removeResumeDataForOperation:op];
            }
        }
        // 竞态兜底：didFinish 与 cancelled 交叠时可能残留 .part，幂等清理
        op.pendingPartPath = nil;
        op.pendingDownloadError = nil;
        [[NSFileManager defaultManager] removeItemAtPath:partPath error:nil];
        return;
    }

    op.currentTask = nil;

    if (!error) {
        if (op.pendingDownloadError) {
            NSError *downloadError = op.pendingDownloadError;
            op.pendingDownloadError = nil;
            op.pendingPartPath = nil;
            [self handleAttemptFailureForOperation:op error:downloadError];
            return;
        }
        NSString *readyPartPath = op.pendingPartPath;
        op.pendingPartPath = nil;
        if (readyPartPath.length == 0) {
            // 理论不可达：didFinishDownloadingToURL 必先于本回调设置 .part 或错误
            [self handleAttemptFailureForOperation:op
                error:PLDownloadErrorMake(PLDownloadClientErrorCodeNetworkFailure,
                    localize(@"i18n_str_838", nil), nil)];
            return;
        }
        // 完整性校验：SHA1 → zip EOCD 兜底
        NSError *validationError = PLDownloadValidateFile(readyPartPath, op.request);
        if (validationError) {
            // 校验失败：删除损坏文件并按重试节奏重试（参考现有
            // MinecraftResourceDownloadTask 的 SHA 失败重试语义）
            [[NSFileManager defaultManager] removeItemAtPath:readyPartPath error:nil];
            [self handleAttemptFailureForOperation:op error:validationError];
            return;
        }
        // 校验通过：原子替换到目标路径
        NSError *installError = [self installPartFileAtPath:readyPartPath
                                                toPath:op.request.destinationPath];
        if (installError) {
            [self handleAttemptFailureForOperation:op error:installError];
            return;
        }
        [self finishOperation:op success:YES error:nil];
        return;
    }

    // 网络错误 → 失败处理（退避重试 / 切换候选 / 聚合失败）
    [self handleAttemptFailureForOperation:op
        error:PLDownloadErrorMake(PLDownloadClientErrorCodeNetworkFailure,
            [NSString stringWithFormat:localize(@"i18n_str_839", nil),
                op.request.candidateURLs[op.urlIndex].absoluteString, error.localizedDescription],
            error)];
}

/// 单次尝试失败处理：进度回退 → 记录错误 → 退避重试 / 切换候选 / 聚合失败
- (void)handleAttemptFailureForOperation:(PLDownloadOperation *)op error:(NSError *)error {
    // 1. 进度回退（参考 ZL2 downloadFromMirrorList：以负 delta 撤回本次尝试的上报量，
    //    保证调用方累计值在镜像切换 / 重试后不虚高）
    if (op.attemptReportedBytes != 0) {
        int64_t rollback = -op.attemptReportedBytes;
        op.attemptReportedBytes = 0;
        if (op.progressHandler) {
            op.progressHandler(rollback, -1);
        }
    }
    op.lastReportedBytes = 0;
    op.hasReportedInStretch = NO;

    // 2. 清理半成品
    [[NSFileManager defaultManager] removeItemAtPath:[self partPathForOperation:op] error:nil];

    // 3. 记录该候选的错误（每候选保留最后一次，供聚合）
    op.candidateErrors[@(op.urlIndex)] = error;
    NSLog(@"[PLDownload] Attempt failed (candidate %lu, retry %lu/%lu): %@",
        (unsigned long)(op.urlIndex + 1), (unsigned long)op.retryCount,
        (unsigned long)PLDownloadMaxRetryPerCandidate, error.localizedDescription);

    // 4. 决策：同候选退避重试 → 下一候选 → 聚合失败
    if (op.retryCount < PLDownloadMaxRetryPerCandidate) {
        op.retryCount++;
        // 指数退避：1s / 2s / 4s
        NSTimeInterval delay = PLDownloadRetryDelayBase * (1 << (op.retryCount - 1));
        uint64_t capturedGeneration = ++op.generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       self.stateQueue, ^{
            // generation 不匹配 = 期间发生过 pause / resume / cancel / 终态，丢弃本次重试
            if (op.generation != capturedGeneration ||
                op.state != PLDownloadOperationStateRunning ||
                op.client != self) {
                return;
            }
            [self startAttemptForOperation:op];
        });
        return;
    }

    if (op.urlIndex + 1 < op.request.candidateURLs.count) {
        // 当前候选重试耗尽 → 切换下一候选（立即尝试，不额外等待）
        op.urlIndex++;
        op.retryCount = 0;
        [self startAttemptForOperation:op];
        return;
    }

    // 全部候选耗尽 → 聚合错误（userInfo 附每个候选的错误数组）
    NSMutableArray<NSError *> *errors = [NSMutableArray array];
    for (NSUInteger i = 0; i < op.request.candidateURLs.count; i++) {
        NSError *candidateError = op.candidateErrors[@(i)];
        if (candidateError) {
            [errors addObject:candidateError];
        }
    }
    NSError *aggregated = PLDownloadErrorMake(PLDownloadClientErrorCodeAllCandidatesExhausted,
        [NSString stringWithFormat:localize(@"i18n_str_840", nil),
            (unsigned long)op.request.candidateURLs.count, (unsigned long)PLDownloadMaxRetryPerCandidate],
        nil);
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithDictionary:aggregated.userInfo];
    userInfo[PLDownloadClientUnderlyingErrorsKey] = [errors copy];
    aggregated = [NSError errorWithDomain:PLDownloadClientErrorDomain
                                      code:PLDownloadClientErrorCodeAllCandidatesExhausted
                                  userInfo:userInfo];
    [self finishOperation:op success:NO error:aggregated];
}

/// 操作终态
- (void)finishOperation:(PLDownloadOperation *)op success:(BOOL)success error:(nullable NSError *)error {
    op.state = success ? PLDownloadOperationStateCompleted : PLDownloadOperationStateFailed;
    op.generation++;
    op.currentTask = nil;
    op.pendingResumeData = nil;
    op.pendingPartPath = nil;
    op.pendingDownloadError = nil;
    [self stopSpeedTimerForOperation:op reportZero:YES];
    // 终态后断点数据无意义，清理磁盘
    [self removeResumeDataForOperation:op];
    [self deliverCompletionForOperation:op success:success error:error];
}

- (void)deliverCompletionForOperation:(PLDownloadOperation *)op
                              success:(BOOL)success
                                error:(nullable NSError *)error {
    if (op.completionDelivered) {
        return;
    }
    op.completionDelivered = YES;
    PLDownloadCompletion handler = op.completionHandler;
    if (handler) {
        handler(success, error);
    }
}

#pragma mark - NSURLSession delegate（由 PLDownloadSessionDelegate 转发）

- (void)URLSession:(NSURLSession *)session
       downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    // 必须同步处理：本方法返回后系统会删除 location 临时文件。
    // 此处仅做 HTTP 状态检查 + 移动到 .part（同卷 rename，耗时可控）；
    // 校验与状态推进派发到 stateQueue。
    PLDownloadOperation *op = [self operationForTask:downloadTask];
    if (!op) {
        return;
    }

    // download task 对非 2xx 也会正常结束（body 为错误页），必须显式拦截
    NSInteger statusCode = 0;
    if ([downloadTask.response isKindOfClass:[NSHTTPURLResponse class]]) {
        statusCode = ((NSHTTPURLResponse *)downloadTask.response).statusCode;
    }
    if (statusCode > 0 && (statusCode < 200 || statusCode >= 300)) {
        op.pendingDownloadError = PLDownloadErrorMake(PLDownloadClientErrorCodeNetworkFailure,
            [NSString stringWithFormat:@"HTTP %ld（%@）", (long)statusCode,
                op.request.candidateURLs[op.urlIndex].absoluteString],
            nil);
        op.pendingPartPath = nil;
        return; // 不移动文件，让系统清理 location
    }

    NSString *partPath = [self partPathForOperation:op];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *moveError = nil;
    NSString *parentDirectory = [partPath stringByDeletingLastPathComponent];
    if (parentDirectory.length > 0) {
        [fileManager createDirectoryAtPath:parentDirectory
               withIntermediateDirectories:YES attributes:nil error:nil];
    }
    [fileManager removeItemAtPath:partPath error:nil];
    if (![fileManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:partPath] error:&moveError]) {
        op.pendingDownloadError = PLDownloadErrorMake(PLDownloadClientErrorCodeFileWriteFailure,
            [NSString stringWithFormat:localize(@"i18n_str_841", nil), moveError.localizedDescription], moveError);
        op.pendingPartPath = nil;
        return;
    }
    op.pendingPartPath = partPath;
}

- (void)URLSession:(NSURLSession *)session
       downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    dispatch_async(self.stateQueue, ^{
        PLDownloadOperation *op = [self operationForTask:downloadTask];
        if (!op || op.currentTask != downloadTask) {
            return; // 已被取代 / 已结束的任务迟到回调
        }
        // 以 totalBytesWritten 差值计算增量：断点失效从 0 重下时 delta 自然为负，
        // 自动回退此前多报的字节（与 ZL2 sizeCallback 负数语义一致）
        int64_t delta = totalBytesWritten - op.lastReportedBytes;
        op.lastReportedBytes = totalBytesWritten;
        if (delta == 0) {
            return;
        }
        if (delta > 0) {
            op.hasReportedInStretch = YES;
            [op appendSpeedBytes:delta]; // 速率只累计真实正向流量
        }
        // delta 为负时原样透传（断点失效从 0 重下的首次回调，回退此前多报的字节）
        op.attemptReportedBytes += delta;
        if (op.attemptReportedBytes < 0) {
            op.attemptReportedBytes = 0;
        }
        if (op.progressHandler) {
            op.progressHandler(delta, totalBytesExpectedToWrite);
        }
    });
}

- (void)URLSession:(NSURLSession *)session
       downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes {
    dispatch_async(self.stateQueue, ^{
        PLDownloadOperation *op = [self operationForTask:downloadTask];
        if (!op || op.currentTask != downloadTask) {
            return;
        }
        if (op.hasReportedInStretch) {
            // 本连续下载段已有上报：以实际恢复点对齐基线。
            // offset > 基线 → 补报差值（pause 前最后回调之后的未上报字节）；
            // offset < 基线（服务器忽略 Range 返回全量）→ 负 delta 回退多报部分
            int64_t delta = fileOffset - op.lastReportedBytes;
            if (delta != 0) {
                op.attemptReportedBytes += delta;
                if (op.attemptReportedBytes < 0) {
                    op.attemptReportedBytes = 0;
                }
                if (op.progressHandler) {
                    op.progressHandler(delta, expectedTotalBytes);
                }
            }
        }
        // 首段无上报（App 重启后恢复等）：静默设置基线，由调用方以持久化的
        // downloadedSize 对齐已有进度（Phase 2 DownloadTaskManager 职责）
        op.lastReportedBytes = fileOffset;
    });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error {
    dispatch_async(self.stateQueue, ^{
        [self handleTaskCompletion:task error:error];
    });
}

#pragma mark - 速率统计

/// 启动每秒采样定时器（参考 ZL2 withSpeedReport：1 秒间隔汇报期间数据量）
- (void)startSpeedTimerForOperation:(PLDownloadOperation *)op {
    if (op.speedTimer || !op.speedHandler) {
        return;
    }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     self.stateQueue);
    __weak PLDownloadOperation *weakOp = op;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                              (uint64_t)(1.0 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        PLDownloadOperation *strongOp = weakOp;
        if (!strongOp) {
            return;
        }
        int64_t bytes = [strongOp takePendingSpeedBytes];
        PLDownloadSpeedHandler speedHandler = strongOp.speedHandler;
        if (speedHandler) {
            speedHandler(bytes);
        }
    });
    dispatch_resume(timer);
    op.speedTimer = timer;
}

- (void)stopSpeedTimerForOperation:(PLDownloadOperation *)op reportZero:(BOOL)reportZero {
    if (op.speedTimer) {
        dispatch_source_cancel(op.speedTimer);
        op.speedTimer = nil;
    }
    [op drainPendingSpeedBytes];
    if (reportZero && op.speedHandler) {
        op.speedHandler(0); // 结束 / 暂停时报 0（对应 ZL2 onClear → onSpeedReport(0)）
    }
}

#pragma mark - 文件与断点工具（仅 stateQueue 调用，persist 例外见注释）

/// 半成品路径（下载中先落 .part，校验通过后原子替换到目标路径）
- (NSString *)partPathForOperation:(PLDownloadOperation *)op {
    return [op.request.destinationPath stringByAppendingString:@".part"];
}

/// 校验通过后安装文件：目标已存在则原子替换（replaceItemAtURL），否则直接移动
- (nullable NSError *)installPartFileAtPath:(NSString *)partPath toPath:(NSString *)destinationPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *destinationURL = [NSURL fileURLWithPath:destinationPath];
    NSURL *partURL = [NSURL fileURLWithPath:partPath];
    NSError *error = nil;
    BOOL ok = NO;
    if ([fileManager fileExistsAtPath:destinationPath]) {
        ok = [fileManager replaceItemAtURL:destinationURL
                            withItemAtURL:partURL
                           backupItemName:nil
                                      options:0
                         resultingItemURL:NULL
                                       error:&error];
    } else {
        ok = [fileManager moveItemAtURL:partURL toURL:destinationURL error:&error];
    }
    if (!ok) {
        return PLDownloadErrorMake(PLDownloadClientErrorCodeFileWriteFailure,
            [NSString stringWithFormat:localize(@"i18n_str_842", nil),
                error.localizedDescription ?: localize(@"i18n_str_843", nil)],
            error);
    }
    return nil;
}

/// 稳定解析 resumeData 存取键：优先用业务指定的 taskIdentifier（清洗路径分隔符），
/// 缺省时按 destinationPath + 首个 URL 派生（同一文件重复下载可复用断点）
- (void)resolveTaskIdentifierForOperation:(PLDownloadOperation *)op {
    NSString *identifier = op.request.taskIdentifier;
    if (identifier.length == 0) {
        NSString *seed = [NSString stringWithFormat:@"%@|%@",
            op.request.destinationPath, op.request.candidateURLs.firstObject.absoluteString ?: @""];
        identifier = PLDownloadSHA1HexForString(seed) ?: @"anonymous";
    } else {
        identifier = [identifier stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    }
    op.resolvedTaskIdentifier = identifier;
}

- (NSString *)resumeDataPathForOperation:(PLDownloadOperation *)op {
    NSString *directory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:PLDownloadResumeDirectoryName];
    return [directory stringByAppendingPathComponent:
        [op.resolvedTaskIdentifier stringByAppendingPathExtension:@"data"]];
}

/// resumeData 原子落盘（目录自动创建）；仅在 stateQueue 或 pause 链路内调用
- (void)persistResumeData:(NSData *)resumeData forOperation:(PLDownloadOperation *)op {
    NSString *path = [self resumeDataPathForOperation:op];
    NSString *directory = [path stringByDeletingLastPathComponent];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    if (![resumeData writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"[PLDownload] Failed to persist resumeData: %@", error.localizedDescription);
    }
}

- (nullable NSData *)storedResumeDataForOperation:(PLDownloadOperation *)op {
    return [NSData dataWithContentsOfFile:[self resumeDataPathForOperation:op]];
}

- (void)removeResumeDataForOperation:(PLDownloadOperation *)op {
    [[NSFileManager defaultManager] removeItemAtPath:[self resumeDataPathForOperation:op] error:nil];
}

#pragma mark - 任务映射（NSLock 保护，delegate 队列与 stateQueue 均可访问）

- (void)setOperation:(PLDownloadOperation *)operation forTask:(NSURLSessionTask *)task {
    [self.operationsLock lock];
    self.operations[task] = operation;
    [self.operationsLock unlock];
}

- (nullable PLDownloadOperation *)operationForTask:(NSURLSessionTask *)task {
    [self.operationsLock lock];
    PLDownloadOperation *operation = self.operations[task];
    [self.operationsLock unlock];
    return operation;
}

- (nullable PLDownloadOperation *)takeOperationForTask:(NSURLSessionTask *)task {
    [self.operationsLock lock];
    PLDownloadOperation *operation = self.operations[task];
    if (operation) {
        [self.operations removeObjectForKey:task];
    }
    [self.operationsLock unlock];
    return operation;
}

@end
