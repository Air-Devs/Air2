//
//  A2DownloadEngine.m
//  Air2
//
//  统一下载客户端。
//
//  设计同时参考两家 iOS/Android 上的成熟实现：
//    · Amethyst-iOS 的 PLDownloadClient（Air 1，iOS 落地经验）
//    · ZalithLauncher2 的 Fetcher / DownloadStats / FileDownloader
//
//  关键机制（来自 ZL2 的 Fetcher.ResumeContext）：
//    断点续传必须严格校验，接受「看起来差不多」会静默损坏文件：
//      · 必须 206（200 说明服务端忽略了 Range）
//      · Content-Encoding 必须是 identity（压缩传输时 Range 语义错乱）
//      · 长度要对得上：contentLength == bodyLength + 已收字节
//      · 优先用 strong ETag（W/ 开头的弱 ETag 不可靠），否则校验 URL + Last-Modified
//      · Content-Range 的 start/end/total 逐字段精确匹配
//      · 请求带 If-Range，服务端不匹配就返回 200 全量，我们据此回退重下
//
//  测速（来自 ZL2 的 DownloadStats）：
//    逐秒采样、不平滑不外推 —— 报出来的数字永远对应真实的落盘流量。
//    平滑会让数字好看但不真实，这是取舍。
//

#import "A2DownloadEngine.h"
#import <CommonCrypto/CommonDigest.h>
#import <zlib.h>

NSString *const A2DownloadErrorDomain = @"A2DownloadError";
NSString *const A2DownloadUnderlyingErrorsKey = @"A2DownloadUnderlyingErrors";

/// 单候选的重试退避（秒）
static const NSTimeInterval kBackoffSeconds[] = {1.0, 2.0, 4.0};
static const NSInteger kBackoffCount = 3;
/// 缓冲写盘阈值：攒够这么多字节写一次，减少磁盘操作
static const NSUInteger kWriteBufferSize = 256 * 1024;
/// 半成品文件后缀
static NSString *const kPartSuffix = @".part";
/// resumeData 存放目录名
static NSString *const kResumeDirName = @"A2DownloadResume";

#pragma mark - 请求

@implementation A2DownloadRequest
@end

#pragma mark - 操作句柄

@interface A2DownloadOperation ()
@property (nonatomic, assign) A2DownloadState state;
@property (nonatomic, copy, nullable) NSData *resumeData;
@property (nonatomic, strong) A2DownloadRequest *request;
@property (nonatomic, copy) NSString *resumeKey;
@property (nonatomic, weak, nullable) id owner;
@end

@implementation A2DownloadOperation
- (instancetype)init NS_UNAVAILABLE { return nil; }
+ (instancetype)new NS_UNAVAILABLE { return nil; }

- (instancetype)initInternalWithRequest:(A2DownloadRequest *)request key:(NSString *)key {
    self = [super init];
    if (!self) return nil;
    _request = request;
    _resumeKey = [key copy];
    _state = A2DownloadStateRunning;
    return self;
}
@end

#pragma mark - 单个下载任务

@interface A2FileFetcher : NSObject <NSURLSessionDataDelegate>

@property (nonatomic, strong) A2DownloadRequest *request;
@property (nonatomic, weak, nullable) A2DownloadOperation *operation;
@property (nonatomic, copy, nullable) A2DownloadProgressHandler progressHandler;
@property (nonatomic, copy, nullable) A2DownloadSpeedHandler speedHandler;
@property (nonatomic, copy, nullable) A2DownloadCompletion completion;

// 状态
@property (nonatomic, assign) NSInteger candidateIndex;
@property (nonatomic, assign) NSInteger retryCount;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, copy, nullable) NSMutableArray<NSError *> *candidateErrors;

// 断点续传校验信息（对应 ZL2 的 ResumeContext）
@property (nonatomic, assign) int64_t contentLength;
@property (nonatomic, assign) int64_t receivedBytes;
@property (nonatomic, copy, nullable) NSString *strongETag;
@property (nonatomic, copy, nullable) NSString *lastModified;
@property (nonatomic, copy, nullable) NSURL *resolvedURL;

// 写入
@property (nonatomic, strong, nullable) NSFileHandle *fileHandle;
@property (nonatomic, strong) NSMutableData *writeBuffer;

// 测速：逐秒采样
@property (nonatomic, strong) NSTimer *speedTimer;
@property (nonatomic, assign) int64_t bytesSinceLastTick;
@property (nonatomic, assign) int64_t lastReportedTotal;

@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *currentTask;
@property (nonatomic, strong) dispatch_queue_t queue;

@end

@implementation A2FileFetcher

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("dev.airdevs.air2.download.fetcher", DISPATCH_QUEUE_SERIAL);
    _writeBuffer = [NSMutableData data];
    _candidateErrors = [NSMutableArray array];
    return self;
}

#pragma mark 启动

- (void)start {
    dispatch_async(self.queue, ^{
        // 1. 先检查目标文件是否已经完好（增量下载，零流量）
        if ([self isExistingFileValid]) {
            A2DownloadRequest *req = self.request;
            if (self.progressHandler && req.expectedSize > 0) {
                self.progressHandler(req.expectedSize, req.expectedSize);
            }
            [self finishSuccess];
            return;
        }
        [self startCurrentCandidate];
    });
}

/// 已存在的文件是否可用 —— SHA1 匹配或 zip 结构完好
- (BOOL)isExistingFileValid {
    NSString *path = self.request.destinationPath;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    if (size == 0) return NO;

    // 有期望大小且不一致，直接判无效
    if (self.request.expectedSize > 0 && (int64_t)size != self.request.expectedSize) return NO;

    if (self.request.expectedSHA1.length > 0) {
        return [[self sha1OfFile:path] caseInsensitiveCompare:self.request.expectedSHA1] == NSOrderedSame;
    }

    if (self.request.allowZipFallbackCheck) {
        NSString *ext = path.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"zip"] || [ext isEqualToString:@"jar"]) {
            return [self hasValidZipEOCD:path];
        }
    }

    // 没有校验方式时不认为已存在文件可用 —— 宁可重下也不冒损坏风险
    return NO;
}

- (void)startCurrentCandidate {
    if (self.finished) return;
    if (self.candidateIndex >= (NSInteger)self.request.candidateURLs.count) {
        [self finishAllCandidatesExhausted];
        return;
    }

    NSURL *url = self.request.candidateURLs[self.candidateIndex];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 60;
    [req setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];

    // 有断点则带 If-Range，服务端不匹配会返回 200（我们就从 0 重下）
    if (self.receivedBytes > 0 && self.ifRangeValidator) {
        [req setValue:self.ifRangeValidator forHTTPHeaderField:@"If-Range"];
        NSString *range = [NSString stringWithFormat:@"bytes=%lld-", self.receivedBytes];
        [req setValue:range forHTTPHeaderField:@"Range"];
    }

    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
    cfg.timeoutIntervalForRequest = 60;
    cfg.timeoutIntervalForResource = 3600;
    cfg.HTTPMaximumConnectionsPerHost = 8;
    self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];

    self.currentTask = [self.session dataTaskWithRequest:req];
    [self.currentTask resume];
}

/// If-Range 的取值：优先 strong ETag，否则 Last-Modified
- (NSString *)ifRangeValidator {
    if (self.strongETag.length > 0) return self.strongETag;
    if (self.lastModified.length > 0) return self.lastModified;
    return nil;
}

#pragma mark 响应处理

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {

    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSInteger code = http.statusCode;

    if (code < 200 || code >= 300) {
        completionHandler(NSURLSessionResponseCancel);
        NSError *err = [self errorWithCode:A2DownloadErrorNetworkFailure
                                   message:[NSString stringWithFormat:@"HTTP %ld", (long)code]];
        dispatch_async(self.queue, ^{ [self handleCandidateFailure:err]; });
        return;
    }

    // ---- 断点续传的严格校验（对应 ZL2 的 ResumeContext.canResume）----
    if (code == 206 && self.receivedBytes > 0) {
        if (![self validateResumeResponse:http]) {
            // 校验不过 → 丢弃断点，从头下
            dispatch_async(self.queue, ^{
                [self discardPartialDownload];
                completionHandler(NSURLSessionResponseCancel);
                [self restartCurrentCandidateFromScratch];
            });
            return;
        }
    } else if (code == 200) {
        // 200：服务端返回全量。若本地有半成品，说明服务端不支持续传或内容已变
        if (self.receivedBytes > 0) {
            dispatch_async(self.queue, ^{
                // 上报负增量，让调用方的累计值回退到真实进度
                if (self.progressHandler) self.progressHandler(-self.receivedBytes, -1);
                [self discardPartialDownload];
            });
        }
        [self captureResumeInfoFromResponse:http];
        self.contentLength = http.expectedContentLength;
    } else if (code == 206) {
        [self captureResumeInfoFromResponse:http];
    }

    // 首次收到响应时开测速
    dispatch_async(self.queue, ^{
        if (!self.speedTimer) [self startSpeedTimer];
    });

    completionHandler(NSURLSessionResponseAllow);
}

/// 校验 206 响应是否真的对得上我们的断点
- (BOOL)validateResumeResponse:(NSHTTPURLResponse *)http {
    // 压缩传输时 Range 语义错乱，不接受
    NSString *encoding = http.allHeaderFields[@"Content-Encoding"];
    if (encoding.length > 0 && ![encoding.lowercaseString isEqualToString:@"identity"]) {
        return NO;
    }

    // 长度必须对得上
    int64_t bodyLength = http.expectedContentLength;
    if (self.contentLength != bodyLength + self.receivedBytes) return NO;

    // 校验器：优先 strong ETag
    if (self.strongETag.length > 0) {
        NSString *etag = http.allHeaderFields[@"ETag"];
        if (![self.strongETag isEqualToString:etag]) return NO;
    } else {
        NSURL *respURL = http.URL;
        if (![respURL.absoluteString isEqualToString:self.resolvedURL.absoluteString]) return NO;
        NSString *lm = http.allHeaderFields[@"Last-Modified"];
        if (![self.lastModified isEqualToString:lm ?: @""]) return NO;
    }

    // Content-Range 逐字段精确匹配
    NSString *contentRange = http.allHeaderFields[@"Content-Range"];
    if (contentRange.length == 0) return NO;

    NSArray<NSNumber *> *parsed = [self parseContentRange:contentRange];
    if (parsed.count != 3) return NO;

    int64_t start = parsed[0].longLongValue;
    int64_t end = parsed[1].longLongValue;
    int64_t total = parsed[2].longLongValue;

    if (start != self.receivedBytes) return NO;
    if (end < start) return NO;
    if (total != self.contentLength) return NO;
    if (end - start + 1 != bodyLength) return NO;

    return YES;
}

/// 解析 "bytes 0-499/1000"
- (NSArray<NSNumber *> *)parseContentRange:(NSString *)range {
    if (![range hasPrefix:@"bytes "]) return nil;
    NSString *body = [range substringFromIndex:6];
    NSArray<NSString *> *parts = [body componentsSeparatedByString:@"/"];
    if (parts.count != 2) return nil;

    NSArray<NSString *> *se = [parts[0] componentsSeparatedByString:@"-"];
    if (se.count != 2) return nil;

    NSNumber *start = @(se[0].longLongValue);
    NSNumber *end = @(se[1].longLongValue);
    NSNumber *total = @(parts[1].longLongValue);
    return @[start, end, total];
}

/// 从 200 响应里记录续传所需的校验信息
- (void)captureResumeInfoFromResponse:(NSHTTPURLResponse *)http {
    self.contentLength = http.expectedContentLength;
    self.resolvedURL = http.URL;

    NSString *acceptRanges = http.allHeaderFields[@"Accept-Ranges"];
    BOOL supportsRange = [acceptRanges.lowercaseString isEqualToString:@"bytes"];

    NSString *etag = http.allHeaderFields[@"ETag"];
    // 弱 ETag（W/ 开头）不做续传依据 —— 它允许内容有微妙差异
    if (etag.length > 0 && ![etag hasPrefix:@"W/"] && ![etag hasPrefix:@"w/"]) {
        self.strongETag = etag;
    } else {
        self.strongETag = nil;
    }
    self.lastModified = http.allHeaderFields[@"Last-Modified"];

    // 服务端不支持 Range 时清掉校验器，后续不做续传尝试
    if (!supportsRange) {
        self.strongETag = nil;
        self.lastModified = nil;
    }
}

#pragma mark 数据接收

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {

    if (data.length == 0) return;

    dispatch_async(self.queue, ^{
        if (self.finished) return;

        [self ensureFileHandleOpen];

        [self.writeBuffer appendData:data];
        if (self.writeBuffer.length >= kWriteBufferSize) {
            [self flushBuffer];
        }

        self.receivedBytes += (int64_t)data.length;
        self.bytesSinceLastTick += (int64_t)data.length;

        // 进度回调：正增量
        if (self.progressHandler) {
            self.progressHandler((int64_t)data.length,
                                 self.contentLength > 0 ? self.contentLength : self.request.expectedSize);
        }
    });
}

- (void)ensureFileHandleOpen {
    if (self.fileHandle) return;
    NSString *partPath = [self partFilePath];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:[partPath stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm fileExistsAtPath:partPath]) {
        [fm createFileAtPath:partPath contents:nil attributes:nil];
    }
    self.fileHandle = [NSFileHandle fileHandleForWritingAtPath:partPath];
    [self.fileHandle seekToEndOfFile];
}

- (void)flushBuffer {
    if (self.writeBuffer.length == 0 || !self.fileHandle) return;
    @try {
        [self.fileHandle writeData:self.writeBuffer];
    } @catch (NSException *e) {
        // 磁盘写失败
    }
    [self.writeBuffer setLength:0];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {

    dispatch_async(self.queue, ^{
        if (self.finished) return;
        [self flushBuffer];

        if (error) {
            if (error.code == NSURLErrorCancelled) return;   // 主动取消，不处理
            [self handleCandidateFailure:error];
            return;
        }

        // 下完了：校验完整性
        [self closeFileHandle];
        [self verifyAndFinish];
    });
}

#pragma mark 完成校验

- (void)verifyAndFinish {
    NSString *partPath = [self partFilePath];
    NSString *destPath = self.request.destinationPath;

    // SHA1 校验
    if (self.request.expectedSHA1.length > 0) {
        NSString *actual = [self sha1OfFile:partPath];
        if (!actual || [actual caseInsensitiveCompare:self.request.expectedSHA1] != NSOrderedSame) {
            [[NSFileManager defaultManager] removeItemAtPath:partPath error:nil];
            NSError *err = [self errorWithCode:A2DownloadErrorChecksumMismatch
                                       message:@"SHA1 校验失败"];
            [self handleCandidateFailure:err];
            return;
        }
    }

    // zip 兜底校验
    if (self.request.expectedSHA1.length == 0 && self.request.allowZipFallbackCheck) {
        NSString *ext = destPath.pathExtension.lowercaseString;
        if (([ext isEqualToString:@"zip"] || [ext isEqualToString:@"jar"])
            && ![self hasValidZipEOCD:partPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:partPath error:nil];
            NSError *err = [self errorWithCode:A2DownloadErrorChecksumMismatch
                                       message:@"压缩包结构损坏"];
            [self handleCandidateFailure:err];
            return;
        }
    }

    // 大小校验（有期望值时）
    if (self.request.expectedSize > 0) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:partPath error:nil];
        if ([attrs[NSFileSize] longLongValue] != self.request.expectedSize) {
            [[NSFileManager defaultManager] removeItemAtPath:partPath error:nil];
            [self handleCandidateFailure:[self errorWithCode:A2DownloadErrorChecksumMismatch
                                                     message:@"文件大小不符"]];
            return;
        }
    }

    // 原子替换到目标路径
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:destPath error:nil];
    NSError *moveErr = nil;
    if (![fm moveItemAtPath:partPath toPath:destPath error:&moveErr]) {
        [self finishWithError:[self errorWithCode:A2DownloadErrorFileWriteFailure
                                          message:moveErr.localizedDescription ?: @"移动文件失败"]];
        return;
    }

    [self cleanupResumeData];
    [self finishSuccess];
}

#pragma mark 失败与换源

/// 当前候选失败 —— 先退避重试，重试耗尽再换下一个候选
- (void)handleCandidateFailure:(NSError *)error {
    if (self.finished) return;
    [self closeFileHandle];
    [self.session invalidateAndCancel];
    self.session = nil;

    if (self.retryCount < kBackoffCount) {
        NSTimeInterval delay = kBackoffSeconds[self.retryCount];
        self.retryCount++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       self.queue, ^{
            if (!self.finished) [self startCurrentCandidate];
        });
        return;
    }

    // 该候选耗尽，记下错误并换源
    [self.candidateErrors addObject:error];
    self.retryCount = 0;
    self.candidateIndex++;

    // 换源时进度回退（新源从头下）
    if (self.receivedBytes > 0 && self.progressHandler) {
        self.progressHandler(-self.receivedBytes, -1);
    }
    [self discardPartialDownload];
    self.receivedBytes = 0;
    self.strongETag = nil;
    self.lastModified = nil;

    [self startCurrentCandidate];
}

- (void)restartCurrentCandidateFromScratch {
    [self discardPartialDownload];
    self.receivedBytes = 0;
    self.strongETag = nil;
    self.lastModified = nil;
    self.retryCount = 0;
    if (!self.finished) [self startCurrentCandidate];
}

- (void)discardPartialDownload {
    [self closeFileHandle];
    [[NSFileManager defaultManager] removeItemAtPath:[self partFilePath] error:nil];
    [self.writeBuffer setLength:0];
}

- (void)finishAllCandidatesExhausted {
    NSString *msg = [NSString stringWithFormat:@"全部 %lu 个源均失败",
                     (unsigned long)self.request.candidateURLs.count];
    NSError *err = [NSError errorWithDomain:A2DownloadErrorDomain
                                       code:A2DownloadErrorAllCandidatesExhausted
                                   userInfo:@{
        NSLocalizedDescriptionKey: msg,
        A2DownloadUnderlyingErrorsKey: [self.candidateErrors copy],
    }];
    [self finishWithError:err];
}

- (void)finishSuccess {
    if (self.finished) return;
    self.finished = YES;
    self.operation.state = A2DownloadStateCompleted;
    [self stopSpeedTimer];
    [self.session invalidateAndCancel];

    A2DownloadCompletion cb = self.completion;
    if (cb) cb(YES, nil);
}

- (void)finishWithError:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    [self closeFileHandle];
    [self stopSpeedTimer];
    [self.session invalidateAndCancel];
    self.operation.state = A2DownloadStateFailed;

    A2DownloadCompletion cb = self.completion;
    if (cb) cb(NO, error);
}

#pragma mark 测速

/// 逐秒采样，不平滑不外推 —— 报出来的数字永远对应真实落盘流量
- (void)startSpeedTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.speedTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                          repeats:YES
                                                            block:^(NSTimer *timer) {
            int64_t bytes = self.bytesSinceLastTick;
            self.bytesSinceLastTick = 0;
            // ZL2 的做法：回滚增量可能让单秒采样为负，速率不应为负
            if (bytes < 0) bytes = 0;
            if (self.speedHandler) self.speedHandler(bytes);
        }];
    });
}

- (void)stopSpeedTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.speedTimer invalidate];
        self.speedTimer = nil;
        if (self.speedHandler) self.speedHandler(0);
    });
}

#pragma mark 工具

- (NSString *)partFilePath {
    return [self.request.destinationPath stringByAppendingString:kPartSuffix];
}

- (void)closeFileHandle {
    if (!self.fileHandle) return;
    @try { [self.fileHandle closeFile]; } @catch (NSException *e) {}
    self.fileHandle = nil;
}

- (NSError *)errorWithCode:(A2DownloadErrorCode)code message:(NSString *)msg {
    return [NSError errorWithDomain:A2DownloadErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"下载失败"}];
}

/// 流式算 SHA1，避免把大文件整个读进内存
- (nullable NSString *)sha1OfFile:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;

    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);

    while (YES) {
        @autoreleasepool {
            NSData *chunk = nil;
            @try { chunk = [fh readDataOfLength:256 * 1024]; } @catch (NSException *e) { break; }
            if (chunk.length == 0) break;
            CC_SHA1_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [fh closeFile];

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &ctx);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

/// 从文件尾扫 EOCD 签名（PK\x05\x06）做 zip 完整性兜底
- (BOOL)hasValidZipEOCD:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;

    unsigned long long size = [fh seekToEndOfFile];
    if (size < 22) { [fh closeFile]; return NO; }   // EOCD 至少 22 字节

    // EOCD 在最后 64KB 内（可能带注释）
    unsigned long long scanLen = MIN(size, (unsigned long long)65557);
    [fh seekToFileOffset:size - scanLen];
    NSData *tail = [fh readDataToEndOfFile];
    [fh closeFile];

    const uint8_t sig[4] = {0x50, 0x4B, 0x05, 0x06};
    const uint8_t *bytes = tail.bytes;
    NSUInteger n = tail.length;
    if (n < 22) return NO;

    for (NSInteger i = (NSInteger)n - 22; i >= 0; i--) {
        if (memcmp(bytes + i, sig, 4) == 0) return YES;
    }
    return NO;
}

#pragma mark 续传数据

- (NSString *)resumeDataPath {
    NSString *tmp = NSTemporaryDirectory();
    NSString *dir = [tmp stringByAppendingPathComponent:kResumeDirName];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:
            [self.operation.resumeKey stringByAppendingPathExtension:@"data"]];
}

- (void)cleanupResumeData {
    NSString *p = [self resumeDataPath];
    [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
}

#pragma mark 暂停 / 恢复 / 取消

- (void)pause {
    dispatch_async(self.queue, ^{
        if (self.finished) return;
        [self flushBuffer];
        [self closeFileHandle];

        __weak typeof(self) weakSelf = self;
        [self.currentTask cancelByProducingResumeData:^(NSData *resumeData) {
            __strong typeof(weakSelf) self = weakSelf;
            dispatch_async(self.queue, ^{
                if (resumeData) {
                    self.operation.resumeData = resumeData;
                    [resumeData writeToFile:[self resumeDataPath] atomically:YES];
                }
                self.operation.state = A2DownloadStatePaused;
                [self stopSpeedTimer];
                [self.session invalidateAndCancel];
                self.session = nil;
            });
        }];
    });
}

- (void)resume {
    dispatch_async(self.queue, ^{
        if (self.finished) return;
        self.operation.state = A2DownloadStateRunning;

        NSData *data = self.operation.resumeData;
        if (!data) {
            data = [NSData dataWithContentsOfFile:[self resumeDataPath]];
        }

        if (data.length > 0) {
            NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
            cfg.timeoutIntervalForRequest = 60;
            cfg.timeoutIntervalForResource = 3600;
            self.session = [NSURLSession sessionWithConfiguration:cfg
                                                         delegate:self
                                                    delegateQueue:nil];
            self.currentTask = [self.session downloadTaskWithResumeData:data];
            // downloadTask 与 dataTask 的 delegate 回调不同，这里退回普通请求更可控
            [self.session invalidateAndCancel];
            self.session = nil;
            [self.operation setResumeData:nil];
        }

        // 用普通请求续传：从 part 文件已有长度继续
        NSDictionary *attrs = [[NSFileManager defaultManager]
                               attributesOfItemAtPath:[self partFilePath] error:nil];
        self.receivedBytes = [attrs[NSFileSize] longLongValue];
        [self startCurrentCandidate];
    });
}

- (void)cancel {
    dispatch_async(self.queue, ^{
        if (self.finished) return;
        self.finished = YES;
        [self closeFileHandle];
        [self stopSpeedTimer];
        [self.session invalidateAndCancel];
        [self discardPartialDownload];
        [self cleanupResumeData];

        self.operation.state = A2DownloadStateCancelled;
        A2DownloadCompletion cb = self.completion;
        if (cb) {
            cb(NO, [NSError errorWithDomain:NSURLErrorDomain
                                       code:NSURLErrorCancelled
                                   userInfo:@{NSLocalizedDescriptionKey: @"已取消"}]);
        }
    });
}

@end

#pragma mark - 客户端

@interface A2DownloadEngine ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, A2FileFetcher *> *active;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation A2DownloadEngine

+ (instancetype)sharedClient {
    static A2DownloadEngine *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2DownloadEngine alloc] init];
    });
    return shared;
}

- (instancetype)init {
    return [self initWithSessionConfiguration:nil];
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (!self) return nil;
    (void)configuration;
    _active = [NSMutableDictionary dictionary];
    _queue = dispatch_queue_create("dev.airdevs.air2.download", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (A2DownloadOperation *)startRequest:(A2DownloadRequest *)request
                             progress:(A2DownloadProgressHandler)progress
                                speed:(A2DownloadSpeedHandler)speed
                           completion:(A2DownloadCompletion)completion {
    // 参数校验：出错也要异步回调，调用方不必区分同步/异步
    if (!request || request.candidateURLs.count == 0 || request.destinationPath.length == 0) {
        NSError *err = [NSError errorWithDomain:A2DownloadErrorDomain
                                           code:A2DownloadErrorInvalidParameter
                                       userInfo:@{NSLocalizedDescriptionKey: @"参数不完整"}];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO, err); });
        return nil;
    }

    // 断点续传的存取键：没给就按「目标路径 + 首个 URL」稳定派生，
    // 这样同一文件重复下载能复用断点
    NSString *key = request.taskIdentifier;
    if (key.length == 0) {
        key = [NSString stringWithFormat:@"%08lx",
               (unsigned long)[[request.destinationPath stringByAppendingString:
                                request.candidateURLs.firstObject.absoluteString] hash]];
    }

    A2DownloadOperation *op = [[A2DownloadOperation alloc] initInternalWithRequest:request key:key];

    A2FileFetcher *fetcher = [A2FileFetcher new];
    fetcher.request = request;
    fetcher.operation = op;
    fetcher.progressHandler = progress;
    fetcher.speedHandler = speed;
    fetcher.completion = completion;
    op.owner = fetcher;

    self.active[key] = fetcher;
    [fetcher start];

    return op;
}

- (void)pauseOperation:(A2DownloadOperation *)operation {
    A2FileFetcher *f = [self fetcherForOperation:operation];
    [f pause];
}

- (void)resumeOperation:(A2DownloadOperation *)operation {
    A2FileFetcher *f = [self fetcherForOperation:operation];
    [f resume];
}

- (void)cancelOperation:(A2DownloadOperation *)operation {
    A2FileFetcher *f = [self fetcherForOperation:operation];
    [f cancel];
    if (operation.resumeKey) [self.active removeObjectForKey:operation.resumeKey];
}

- (nullable A2FileFetcher *)fetcherForOperation:(A2DownloadOperation *)op {
    if (!op.resumeKey) return nil;
    return self.active[op.resumeKey];
}

#pragma mark 便捷方法

- (void)downloadURL:(NSString *)url
             toPath:(NSString *)path
       expectedSize:(int64_t)size
           progress:(void (^)(int64_t, int64_t))progress
         completion:(void (^)(NSError *))completion {

    A2DownloadRequest *req = [A2DownloadRequest new];
    NSURL *u = [NSURL URLWithString:url];
    req.candidateURLs = u ? @[u] : @[];
    req.destinationPath = path;
    req.expectedSize = size;
    req.allowZipFallbackCheck = YES;

    [self startRequest:req
              progress:^(int64_t delta, int64_t total) {
        // 转成累计值给调用方（内部用增量是为了支持回退）
        static int64_t accumulated = 0;
        accumulated += delta;
        if (accumulated < 0) accumulated = 0;
        if (progress) progress(accumulated, total);
    }
                 speed:nil
            completion:^(BOOL success, NSError *error) {
        if (completion) completion(success ? nil : error);
    }];
}

@end
