//
//  A2DownloadEngine.m
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
#import "A2Logger.h"
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
/// 单次请求的等待超时（拿到响应/下一包数据的间隔上限）
static const NSTimeInterval kRequestTimeout = 30;
/// 整份资源的下载上限（大文件留足，避免被资源超时误杀）
static const NSTimeInterval kResourceTimeout = 1800;
/// 停滞看门狗：连续这么多秒没有字节增长就判停滞
static const NSTimeInterval kStallTimeout = 20;
/// 看门狗采样间隔
static const NSTimeInterval kStallTickInterval = 5;
/// 全局并发上限的封顶值（限流后从它往下减）
static const NSInteger kConcurrencyCapMax = 8;
/// Retry-After 的取值上限，避免服务端给个离谱值把整批拖死
static const NSTimeInterval kRetryAfterClamp = 30;
/// 每成功这么多次，把限流压下去的并发上限涨回一档
static const NSInteger kSuccessesPerCapStep = 16;

#pragma mark - 请求

@implementation A2DownloadRequest
@end

#pragma mark - 操作句柄

@interface A2DownloadOperation ()
@property (nonatomic, assign) A2DownloadState state;
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

#pragma mark - 全局限流闸

@implementation A2DownloadThrottle {
    NSLock *_lock;
    NSInteger _cap;              ///< 当前并发上限（≤ kConcurrencyCapMax）
    CFAbsoluteTime _cooldownUntil;
    NSInteger _successStreak;
}

+ (instancetype)shared {
    static A2DownloadThrottle *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2DownloadThrottle alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _lock = [[NSLock alloc] init];
    _cap = kConcurrencyCapMax;
    _cooldownUntil = 0;
    _successStreak = 0;
    return self;
}

- (NSInteger)effectiveConnectionsFor:(NSInteger)requested {
    [_lock lock];
    NSInteger cap = _cap;
    [_lock unlock];
    if (requested <= 0) return MAX(1, cap);
    return MAX(1, MIN(requested, cap));
}

- (void)noteRateLimitedRetryAfter:(NSTimeInterval)seconds {
    NSTimeInterval wait = MAX(1.0, MIN(seconds, kRetryAfterClamp));
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    [_lock lock];
    if (now + wait > _cooldownUntil) _cooldownUntil = now + wait;
    NSInteger before = _cap;
    _cap = MAX(1, _cap / 2);
    _successStreak = 0;
    NSInteger after = _cap;
    [_lock unlock];

    [A2Logger warning:@"Download"
               message:[NSString stringWithFormat:
                        @"[A2-DL] 触发限流：全局冷却 %.0fs，并发上限 %ld → %ld",
                        wait, (long)before, (long)after]];
}

- (void)noteTransferSucceeded {
    [_lock lock];
    _successStreak += 1;
    if (_successStreak >= kSuccessesPerCapStep && _cap < kConcurrencyCapMax) {
        _cap += 1;
        _successStreak = 0;
    }
    [_lock unlock];
}

- (NSTimeInterval)cooldownRemaining {
    [_lock lock];
    NSTimeInterval remain = _cooldownUntil - CFAbsoluteTimeGetCurrent();
    [_lock unlock];
    return MAX(0, remain);
}

- (NSString *)diagnosticDescription {
    [_lock lock];
    NSInteger cap = _cap;
    NSTimeInterval remain = MAX(0, _cooldownUntil - CFAbsoluteTimeGetCurrent());
    [_lock unlock];
    return [NSString stringWithFormat:@"cap=%ld cooldown=%.0fs", (long)cap, remain];
}

- (void)reset {
    [_lock lock];
    _cap = kConcurrencyCapMax;
    _cooldownUntil = 0;
    _successStreak = 0;
    [_lock unlock];
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

// 诊断：日志里要能说清「卡在哪个文件、哪个源、HTTP 多少」
@property (nonatomic, assign) NSInteger attemptCount;        ///< 累计发起请求次数
@property (nonatomic, assign) NSInteger lastHTTPStatus;      ///< 最近一次响应码（0=还没收到）
@property (nonatomic, assign) CFAbsoluteTime lastByteAt;     ///< 最近一次收到字节的时刻
@property (nonatomic, assign) BOOL cancelledByUser;          ///< 主动取消（不是传输错误）
@property (nonatomic, strong, nullable) dispatch_source_t watchdog;

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
    req.timeoutInterval = kRequestTimeout;                 // 每次请求都有超时
    [req setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];

    // 有断点则带 If-Range，服务端不匹配会返回 200（我们就从 0 重下）
    if (self.receivedBytes > 0 && self.ifRangeValidator) {
        [req setValue:self.ifRangeValidator forHTTPHeaderField:@"If-Range"];
        NSString *range = [NSString stringWithFormat:@"bytes=%lld-", self.receivedBytes];
        [req setValue:range forHTTPHeaderField:@"Range"];
    }

    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
    cfg.timeoutIntervalForRequest = kRequestTimeout;
    cfg.timeoutIntervalForResource = kResourceTimeout;
    cfg.HTTPMaximumConnectionsPerHost = 4;
    self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];

    self.attemptCount += 1;
    self.lastHTTPStatus = 0;
    self.lastByteAt = CFAbsoluteTimeGetCurrent();

    // 每次发起都把「文件 / 源 / 第几次」写清楚 ——
    // 卡住时从日志就能判断是源的问题还是本地的问题。
    [A2Logger info:@"Download"
           message:[NSString stringWithFormat:
                    @"[A2-DL] 请求 文件=%@ 源=%ld/%lu(%@) 尝试=%ld 重试=%ld 已收=%lld",
                    self.request.destinationPath.lastPathComponent ?: @"(未知)",
                    (long)(self.candidateIndex + 1),
                    (unsigned long)self.request.candidateURLs.count,
                    url.host ?: @"?",
                    (long)self.attemptCount,
                    (long)self.retryCount,
                    self.receivedBytes]];

    self.currentTask = [self.session dataTaskWithRequest:req];
    [self.currentTask resume];
    [self startWatchdog];
}

#pragma mark 停滞看门狗

/// 每 kStallTickInterval 秒看一次：多久没字节增长了。
/// 判停滞就主动掐掉这次请求（走失败路径换源），并打印当前文件/源/HTTP 状态。
- (void)startWatchdog {
    if (self.watchdog) return;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    uint64_t interval = (uint64_t)(kStallTickInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval, (uint64_t)(0.5 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.finished) return;
        if (self.lastByteAt <= 0) return;

        NSTimeInterval idle = CFAbsoluteTimeGetCurrent() - self.lastByteAt;
        if (idle < kStallTimeout) return;

        NSURL *url = self.candidateIndex < (NSInteger)self.request.candidateURLs.count
                   ? self.request.candidateURLs[self.candidateIndex] : nil;
        NSString *detail = [NSString stringWithFormat:
            @"[A2-DL] 停滞 %lds 文件=%@ 源=%@ HTTP=%ld 已收=%lld 尝试=%ld",
            (long)idle,
            self.request.destinationPath.lastPathComponent ?: @"(未知)",
            url.host ?: @"(无源)",
            (long)self.lastHTTPStatus,
            self.receivedBytes,
            (long)self.attemptCount];
        [A2Logger warning:@"Download" message:detail];

        // 掐掉这次请求，交给统一的失败处理（退避重试 / 换源 / 放弃）
        [self.currentTask cancel];
        [self.session invalidateAndCancel];
        self.session = nil;
        [self handleCandidateFailure:[self errorWithCode:A2DownloadErrorStalled
                                                 message:detail]];
        [self stopWatchdog];
    });
    dispatch_resume(timer);
    self.watchdog = timer;
}

- (void)stopWatchdog {
    if (!self.watchdog) return;
    dispatch_source_cancel(self.watchdog);
    self.watchdog = nil;
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
    // 诊断用的最近状态码（看门狗日志要打它；只做诊断，不做判据）
    self.lastHTTPStatus = code;
    self.lastByteAt = CFAbsoluteTimeGetCurrent();

    if (code < 200 || code >= 300) {
        // 关键分类：4xx 里「文件不存在 / 没权限」不是网络抖动。
        // 早先一视同仁当网络失败重试 3 次（1s+2s+4s），一个 404 要空转 7 秒；
        // 依赖批量下载里这种地址成片出现时，界面上就是「进度不动」。
        // 现在：永久失败立即换源，不重试。
        BOOL permanent = (code == 401 || code == 403 || code == 404 ||
                          code == 410 || code == 451);
        BOOL rateLimited = (code == 429 || code == 503);

        if (rateLimited) {
            NSTimeInterval retryAfter = [self retryAfterSecondsFromResponse:http];
            [[A2DownloadThrottle shared] noteRateLimitedRetryAfter:retryAfter];
        }

        [A2Logger warning:@"Download"
                 message:[NSString stringWithFormat:
                          @"[A2-DL] HTTP %ld %@ 文件=%@ 源=%@ 尝试=%ld",
                          (long)code,
                          permanent ? @"永久失败→换源" : (rateLimited ? @"限流→降并发退避" : @"临时失败→退避重试"),
                          self.request.destinationPath.lastPathComponent ?: @"(未知)",
                          http.URL.host ?: @"?",
                          (long)self.attemptCount]];

        completionHandler(NSURLSessionResponseCancel);

        NSString *msg = [NSString stringWithFormat:@"HTTP %ld", (long)code];
        if (permanent) {
            dispatch_async(self.queue, ^{
                [self giveUpCurrentCandidate:[self errorWithCode:A2DownloadErrorNetworkFailure
                                                         message:msg]];
            });
        } else {
            NSError *err = [self errorWithCode:(rateLimited ? A2DownloadErrorRateLimited
                                                           : A2DownloadErrorNetworkFailure)
                                       message:msg];
            dispatch_async(self.queue, ^{ [self handleCandidateFailure:err]; });
        }
        return;
    }

    // 拿到 2xx 就说明链路通了，让全局并发上限有涨回去的机会
    [[A2DownloadThrottle shared] noteTransferSucceeded];

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
        self.lastByteAt = CFAbsoluteTimeGetCurrent();

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
            // NSURLErrorCancelled 有两种来源：
            //   · 用户主动暂停/取消 —— 不回调，由 cancel/pause 自己收尾
            //   · 我们自己掐的会话（看门狗、换源时 invalidateAndCancel）——
            //     必须当作失败继续走流程
            // 早先一律 return，后者会让 completion 永远不触发：
            // 批量下载器的并发许可永远不还，整批卡死不再前进。
            if (error.code == NSURLErrorCancelled && self.cancelledByUser) return;
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
            [self giveUpCurrentCandidate:err];
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
            [self giveUpCurrentCandidate:err];
            return;
        }
    }

    // 大小校验（有期望值时）
    if (self.request.expectedSize > 0) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:partPath error:nil];
        if ([attrs[NSFileSize] longLongValue] != self.request.expectedSize) {
            [[NSFileManager defaultManager] removeItemAtPath:partPath error:nil];
            [self giveUpCurrentCandidate:[self errorWithCode:A2DownloadErrorChecksumMismatch
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

    [self finishSuccess];
}

#pragma mark 失败与换源

/// Retry-After：优先按秒数解析，HTTP-date 形态退化为默认 5 秒。
- (NSTimeInterval)retryAfterSecondsFromResponse:(NSHTTPURLResponse *)http {
    NSString *raw = http.allHeaderFields[@"Retry-After"];
    if (![raw isKindOfClass:NSString.class] || raw.length == 0) return 5.0;

    NSScanner *scanner = [NSScanner scannerWithString:raw];
    double seconds = 0;
    if ([scanner scanDouble:&seconds] && seconds > 0) {
        return MIN(seconds, kRetryAfterClamp);
    }
    return 5.0;   // HTTP-date 或畸形值：给一个保守的固定等待
}

/// 当前候选失败 —— 先退避重试，重试耗尽再换下一个候选
- (void)handleCandidateFailure:(NSError *)error {
    if (self.finished) return;
    [self closeFileHandle];
    [self.session invalidateAndCancel];
    self.session = nil;
    [self stopWatchdog];

    // 同一候选重试也要把已收字节回退上报。
    // 不回退的话，重下的那部分会被重复累计 ⇒ 总进度提前顶到 100% 后
    // 一直停在满格，用户看到的就是「卡住」。
    if (self.receivedBytes > 0 && self.progressHandler) {
        self.progressHandler(-self.receivedBytes, -1);
    }

    if (self.retryCount < kBackoffCount) {
        NSTimeInterval delay = kBackoffSeconds[self.retryCount];
        // 429/503 的退避至少按 Retry-After 走，别比它更急
        NSTimeInterval cooldown = [[A2DownloadThrottle shared] cooldownRemaining];
        if (cooldown > delay) delay = cooldown;

        self.retryCount++;
        [A2Logger info:@"Download"
               message:[NSString stringWithFormat:
                        @"[A2-DL] 重试 文件=%@ 第 %ld/%d 次 等 %.0fs 原因=%@",
                        self.request.destinationPath.lastPathComponent ?: @"(未知)",
                        (long)self.retryCount, kBackoffCount, delay,
                        error.localizedDescription ?: @"(无)"]];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       self.queue, ^{
            if (!self.finished) [self startCurrentCandidate];
        });
        return;
    }

    [self giveUpCurrentCandidate:error];
}

/// 放弃当前候选，换下一个（不重试）。
/// 4xx 一律走这里 —— 文件不存在/没权限，重试一百次也是同一个结果。
- (void)giveUpCurrentCandidate:(NSError *)error {
    if (self.finished) return;
    [self closeFileHandle];
    [self.session invalidateAndCancel];
    self.session = nil;
    [self stopWatchdog];

    [self.candidateErrors addObject:error ?: [self errorWithCode:A2DownloadErrorNetworkFailure
                                                        message:@"候选失败"]];
    self.retryCount = 0;
    self.candidateIndex += 1;

    [A2Logger warning:@"Download"
             message:[NSString stringWithFormat:
                      @"[A2-DL] 换源 文件=%@ 失败源序号=%ld 剩余=%lu 原因=%@",
                      self.request.destinationPath.lastPathComponent ?: @"(未知)",
                      (long)self.candidateIndex,
                      (unsigned long)(self.request.candidateURLs.count > (NSUInteger)self.candidateIndex
                                      ? self.request.candidateURLs.count - (NSUInteger)self.candidateIndex : 0),
                      error.localizedDescription ?: @"(无)"]];

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
    NSString *msg = [NSString stringWithFormat:@"全部 %lu 个源均失败：%@（%@）",
                     (unsigned long)self.request.candidateURLs.count,
                     self.request.destinationPath.lastPathComponent ?: @"(未知文件)",
                     self.candidateErrors.lastObject.localizedDescription ?: @"无具体原因"];
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
    [self stopWatchdog];
    [self.session invalidateAndCancel];

    [A2Logger info:@"Download"
           message:[NSString stringWithFormat:@"[A2-DL] 完成 文件=%@ 字节=%lld 尝试=%ld",
                    self.request.destinationPath.lastPathComponent ?: @"(未知)",
                    self.receivedBytes ?: self.request.expectedSize,
                    (long)self.attemptCount]];

    A2DownloadCompletion cb = self.completion;
    if (cb) cb(YES, nil);
}

- (void)finishWithError:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    [self closeFileHandle];
    [self stopSpeedTimer];
    [self stopWatchdog];
    [self.session invalidateAndCancel];
    self.operation.state = A2DownloadStateFailed;

    [A2Logger error:@"Download"
            message:[NSString stringWithFormat:@"[A2-DL] 失败 文件=%@ 已收=%lld 状态=%ld 尝试=%ld 原因=%@",
                     self.request.destinationPath.lastPathComponent ?: @"(未知)",
                     self.receivedBytes, (long)self.lastHTTPStatus,
                     (long)self.attemptCount,
                     error.localizedDescription ?: @"(无)"]];

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



#pragma mark 暂停 / 恢复 / 取消

- (void)pause {
    dispatch_async(self.queue, ^{
        if (self.finished) return;
        self.cancelledByUser = YES;

        // 先落盘缓冲，保证已收数据都写进 .part 文件
        [self flushBuffer];
        [self closeFileHandle];

        // 取消当前请求。
        //
        // 这里【不能】用 cancelByProducingResumeData: ——
        // 那是 NSURLSessionDownloadTask 的方法，而我们用 dataTask
        // （自己写文件、自己管断点区间）。
        //
        // 我们的断点是「半成品文件 + Range 请求」：
        // .part 里已有 N 字节，恢复时带 Range: bytes=N- 继续下。
        // 所以暂停只需取消请求，进度本来就在磁盘上。
        [self.currentTask cancel];
        [self.session invalidateAndCancel];
        self.session = nil;
        [self stopWatchdog];

        self.operation.state = A2DownloadStatePaused;
        [self stopSpeedTimer];
    });
}

- (void)resume {
    dispatch_async(self.queue, ^{
        if (self.finished) return;
        self.operation.state = A2DownloadStateRunning;

        // 从 .part 文件的当前长度继续 —— 这就是我们的断点
        NSDictionary *attrs = [[NSFileManager defaultManager]
                               attributesOfItemAtPath:[self partFilePath] error:nil];
        int64_t existing = [attrs[NSFileSize] longLongValue];

        if (self.contentLength > 0 && existing >= self.contentLength) {
            // 其实已经下完，直接校验
            [self verifyAndFinish];
            return;
        }

        if (existing > 0 && (self.contentLength <= 0 || existing < self.contentLength)) {
            // startCurrentCandidate 会在 receivedBytes > 0 时自动带 Range 头
            self.receivedBytes = existing;
        } else {
            self.receivedBytes = 0;
        }

        [self startCurrentCandidate];
    });
}

- (void)cancel {
    dispatch_async(self.queue, ^{
        if (self.finished) return;
        self.finished = YES;
        self.cancelledByUser = YES;
        [self closeFileHandle];
        [self stopSpeedTimer];
        [self stopWatchdog];
        [self.session invalidateAndCancel];
        [self discardPartialDownload];
    
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

    // 收尾时把句柄从 active 里摘掉 —— 早先从不摘，装几百个库就在
    // 字典里留下几百个 fetcher（含各自 NSURLSession），越装越胖。
    __weak typeof(self) weakSelf = self;
    __weak A2FileFetcher *weakFetcher = fetcher;
    fetcher.completion = ^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        A2FileFetcher *f = weakFetcher;
        if (strongSelf && f) {
            @synchronized (strongSelf.active) {
                if (strongSelf.active[key] == (id)f) {
                    [strongSelf.active removeObjectForKey:key];
                }
            }
        }
        if (completion) completion(success, error);
    };
    op.owner = fetcher;

    @synchronized (self.active) {
        self.active[key] = fetcher;
    }
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

- (void)cancelAll {
    // 先取快照再遍历 —— cancel 会修改 active 字典，直接遍历会崩
    NSArray<A2FileFetcher *> *fetchers = self.active.allValues;
    NSArray<NSString *> *keys = self.active.allKeys;

    for (A2FileFetcher *f in fetchers) {
        [f cancel];
    }
    [self.active removeObjectsForKeys:keys];
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
