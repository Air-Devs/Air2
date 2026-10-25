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
#import "A2Log.h"
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
/// Retry-After 封顶：服务端可能给 3600，装包不能干等一小时（超了就按封顶值重试）
static const NSTimeInterval kMaxRetryAfterSeconds = 30.0;
/// 限流降并发后，连续多少次成功把上限 +1（逐步恢复，不一次弹回）
static const NSInteger kGateRecoverAfterSuccesses = 4;

@class A2FileFetcher;

#pragma mark - 引擎私有接口（fetcher 用）

/// fetcher 只持 task，session 归引擎。这些方法定义在引擎实现里。
@interface A2DownloadEngine (Private)
- (NSURLSession *)sharedSession;
- (void)attachFetcher:(A2FileFetcher *)fetcher toTask:(NSURLSessionDataTask *)task;
- (void)detachTask:(nullable NSURLSessionTask *)task;
- (void)fetcherDidFinish:(A2FileFetcher *)fetcher;
@end

#pragma mark - 全局并发闸门

/// 进程级并发闸门。
///
/// 会话复用之后每个文件不再各建一条 NSURLSession，连接池/TLS 会话只建一次；
/// 但服务端限流是「按 IP / 按账号」的进程级事实，所以还需要一个进程级闸门：
///   · 收到 429 / 503 ⇒ 立刻把并发上限砍半（已在飞的不动，新请求排队）
///   · 之后每连续 4 次成功 ⇒ 上限 +1，逐步恢复到基线
/// 基线取偏好键 A2DownloadConcurrency（与 installer 的批量窗口同一个键，缺省 16）。
@interface A2DownloadGate : NSObject
+ (instancetype)sharedGate;
/// 取一个并发槽位：有空位立即回调，否则 FIFO 排队（回调在闸门串行队列上）
- (void)acquireSlot:(dispatch_block_t)ready;
/// 归还槽位（与 acquireSlot 严格成对；调用方自己保证不重复归还）
- (void)releaseSlot;
/// 429/503：降并发 + 记录冷却时间（秒，0 表示按退避重试）
- (void)throttledFor:(NSTimeInterval)retryAfter reason:(NSString *)reason;
/// 一次成功：累计成功数，够数就恢复一档并发
- (void)noteSuccess;
- (NSInteger)currentLimit;
@end

@implementation A2DownloadGate {
    dispatch_queue_t _q;
    NSInteger _limit;       ///< 当前允许并发
    NSInteger _baseLimit;   ///< 基线（恢复目标）
    NSInteger _inFlight;
    NSInteger _successStreak;
    NSMutableArray<dispatch_block_t> *_waiters;
    BOOL _loggedQueueing;
}

/// 基线并发：与 installer 的 A2DownloadConcurrency 同键，避免两处各说一套
static NSInteger A2DownloadBaseLimit(void) {
    NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:@"A2DownloadConcurrency"];
    if (v <= 0) v = 16;
    return MAX(1, MIN(32, v));
}

+ (instancetype)sharedGate {
    static A2DownloadGate *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[A2DownloadGate alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _q = dispatch_queue_create("dev.airdevs.air2.download.gate", DISPATCH_QUEUE_SERIAL);
    _baseLimit = _limit = A2DownloadBaseLimit();
    _waiters = [NSMutableArray array];
    return self;
}

- (void)acquireSlot:(dispatch_block_t)ready {
    if (!ready) return;
    dispatch_async(_q, ^{
        if (self->_inFlight < self->_limit) {
            self->_inFlight++;
            ready();
            return;
        }
        [self->_waiters addObject:[ready copy]];
        if (!self->_loggedQueueing) {
            self->_loggedQueueing = YES;
            [A2Log log:@"[A2-DL] 并发闸门排队：limit=%ld inFlight=%ld 等待=%lu（429/503 后降并发生效）",
                  (long)self->_limit, (long)self->_inFlight, (unsigned long)self->_waiters.count];
        }
    });
}

- (void)releaseSlot {
    dispatch_async(_q, ^{
        if (self->_inFlight > 0) self->_inFlight--;
        [self pumpLocked];
    });
}

/// 只在 _q 上调用
- (void)pumpLocked {
    while (self->_waiters.count > 0 && self->_inFlight < self->_limit) {
        dispatch_block_t blk = self->_waiters.firstObject;
        [self->_waiters removeObjectAtIndex:0];
        self->_inFlight++;
        blk();
    }
    if (self->_waiters.count == 0) self->_loggedQueueing = NO;
}

- (void)throttledFor:(NSTimeInterval)retryAfter reason:(NSString *)reason {
    dispatch_async(_q, ^{
        NSInteger next = MAX(1, self->_limit / 2);
        BOOL changed = (next < self->_limit);
        self->_limit = next;
        self->_successStreak = 0;
        [A2Log log:@"[A2-DL] 限流降并发 %ld -> %ld retryAfter=%.0fs reason=%@",
              (long)(changed ? self->_limit * 2 : self->_limit), (long)self->_limit,
              retryAfter < 0 ? 0 : retryAfter, reason ?: @"(未知)"];
    });
}

- (void)noteSuccess {
    dispatch_async(_q, ^{
        if (self->_limit >= self->_baseLimit) return;
        self->_successStreak++;
        if (self->_successStreak < kGateRecoverAfterSuccesses) return;
        self->_successStreak = 0;
        self->_limit++;
        [A2Log log:@"[A2-DL] 并发恢复 %ld/%ld", (long)self->_limit, (long)self->_baseLimit];
        [self pumpLocked];
    });
}

- (NSInteger)currentLimit {
    __block NSInteger v = 0;
    dispatch_sync(_q, ^{ v = self->_limit; });
    return v;
}

@end


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

@property (nonatomic, strong, nullable) NSURLSessionDataTask *currentTask;
/// currentTask 是否正握着一个并发闸门的槽位（槽位跟 task 走，必须成对归还）
@property (nonatomic, assign) BOOL currentTaskHoldsSlot;
/// 共享 session 的持有者（fetcher 自己不再建 session）
@property (nonatomic, weak, nullable) A2DownloadEngine *engine;
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

    // 每次发起（含重试/换源）前先把上一条 task 摘干净：
    // 旧 task 取消 + 从 task→fetcher 映射里移除 + 归还闸门槽位，
    // 这样它迟到的 delegate 回调不会再串到这一次 attempt 上。
    [self detachCurrentTask];

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

    // ★会话复用★ 全部文件共一条 session（引擎持有），这里只拿 task。
    //   以前每个 fetcher 每次尝试都 sessionWithConfiguration → 64 个文件 64 次
    //   TCP+TLS 握手，连接池/HTTP2 复用全废。现在只有会话缓存与多路复用。
    A2DownloadEngine *engine = self.engine ?: [A2DownloadEngine sharedClient];
    NSURLSession *session = [engine sharedSession];

    // 并发闸门：429/503 之后上限被砍半，这里自然排队；正常时与批量窗口同量级（不额外限流）
    __weak typeof(self) weakSelf = self;
    [[A2DownloadGate sharedGate] acquireSlot:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { [[A2DownloadGate sharedGate] releaseSlot]; return; }
        dispatch_async(self.queue, ^{
            if (self.finished || self.currentTask != nil) {
                [[A2DownloadGate sharedGate] releaseSlot];
                return;
            }
            NSURLSessionDataTask *task = [session dataTaskWithRequest:req];
            if (!task) {
                [[A2DownloadGate sharedGate] releaseSlot];
                [self handleCandidateFailure:[self errorWithCode:A2DownloadErrorInvalidParameter
                                                         message:@"请求无法构造"]];
                return;
            }
            self.currentTask = task;
            self.currentTaskHoldsSlot = YES;
            [engine attachFetcher:self toTask:task];
            [task resume];
        });
    }];
}


/// If-Range 的取值：优先 strong ETag，否则 Last-Modified
- (NSString *)ifRangeValidator {
    if (self.strongETag.length > 0) return self.strongETag;
    if (self.lastModified.length > 0) return self.lastModified;
    return nil;
}

#pragma mark 响应处理

/// 由引擎的 session delegate 转发进来（引擎按 task 找到本 fetcher）
- (void)handleResponse:(NSURLResponse *)response
               forTask:(NSURLSessionDataTask *)dataTask
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {

    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
        ? (NSHTTPURLResponse *)response : nil;
    NSInteger code = http ? http.statusCode : 0;

    if (code < 200 || code >= 300) {
        completionHandler(NSURLSessionResponseCancel);
        // ★状态分类★ 不再一律当“网络抖动”重试 —— 见 classifyHTTPStatus
        [self classifyHTTPStatus:code headers:http.allHeaderFields];
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

/// ★HTTP 状态分类（本单三改之一）★
///   以前所有非 2xx 都走 handleCandidateFailure（指数退避重试 3 次再换源）——
///   对 403/404 这种“源本身没有这个文件”的情况，重试只是把同一个 4xx 再打三遍，
///   还会在批量里把每个文件都拖慢 7 秒。
///
///   现在的分类：
///     · 4xx（除 408/429）⇒ 该源对本文件不可用：不重试，立刻换下一个候选
///     · 429 / 503      ⇒ 服务端限流/过载：读 Retry-After，全局并发砍半，按冷却时间再试
///     · 其余 5xx / 408 ⇒ 按原退避（1s/2s/4s）重试
- (void)classifyHTTPStatus:(NSInteger)code headers:(NSDictionary *)headers {
    // 状态分类与后续状态机推进都放到 fetcher 串行队列（delegate 回调在 session 的队列上）
    dispatch_async(self.queue, ^{
        if (self.finished) return;
        NSString *msg = [NSString stringWithFormat:@"HTTP %ld", (long)code];
        NSError *err = [self errorWithCode:A2DownloadErrorNetworkFailure message:msg];

        BOOL rateLimited = (code == 429 || code == 503);
        BOOL hardClientError = (code >= 400 && code < 500 && code != 408 && code != 429);

        if (rateLimited) {
            NSTimeInterval retryAfter = [self retryAfterFromHeaders:headers];
            [[A2DownloadGate sharedGate] throttledFor:retryAfter reason:msg];
            [A2Log log:@"[A2-DL] 限流 %@ retryAfter=%.0fs 全局并发上限=%ld（冷却后重试）",
                  msg, retryAfter, (long)[[A2DownloadGate sharedGate] currentLimit]];
            [self failCurrentCandidateWith:err hard:NO minDelay:retryAfter];
            return;
        }

        if (hardClientError) {
            [A2Log log:@"[A2-DL] 源不可用 %@ （4xx 不重试，直接换源）", msg];
            [self failCurrentCandidateWith:err hard:YES minDelay:0];
            return;
        }

        [self failCurrentCandidateWith:err hard:NO minDelay:0];
    });
}

/// Retry-After 既可能是秒数，也可能是 HTTP 日期；解析不出来就返回 0（用退避）
- (NSTimeInterval)retryAfterFromHeaders:(NSDictionary *)headers {
    NSString *raw = headers[@"Retry-After"];
    if (raw.length == 0) return 0;

    NSTimeInterval seconds = raw.doubleValue;
    if (seconds > 0) return MIN(seconds, kMaxRetryAfterSeconds);

    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
        fmt.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
    });
    NSDate *date = [fmt dateFromString:raw];
    if (!date) return 0;
    NSTimeInterval delta = date.timeIntervalSinceNow;
    if (delta <= 0) return 0;
    return MIN(delta, kMaxRetryAfterSeconds);
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

- (void)handleData:(NSData *)data forTask:(NSURLSessionDataTask *)dataTask {

    if (data.length == 0) return;

    dispatch_async(self.queue, ^{
        // 迟到的旧 task 数据不写盘（换源/重试后 currentTask 已经换了）
        if (self.finished || (dataTask != self.currentTask)) return;

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

/// 由引擎转发（按 task 找到本 fetcher）
- (void)handleTask:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {

    dispatch_async(self.queue, ^{
        // 迟到的旧 task 回调：不推进状态，也不还槽（槽在 detach 时已还）
        if (task != self.currentTask) return;
        self.currentTask = nil;
        [self releaseTaskSlot];
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

    [self finishSuccess];
}

#pragma mark 失败与换源

/// 当前候选失败 —— 先退避重试，重试耗尽再换下一个候选（默认路径：可重试的失败）
- (void)handleCandidateFailure:(NSError *)error {
    [self failCurrentCandidateWith:error hard:NO minDelay:0];
}

/// 失败的唯一出口。
///   hard=YES（4xx 之类“这个源对这个文件就是不行”）⇒ 跳过重试，直接换源
///   minDelay>0（429/503 的 Retry-After）⇒ 重试间隔至少这么久（封顶 kMaxRetryAfterSeconds）
- (void)failCurrentCandidateWith:(NSError *)error hard:(BOOL)hard minDelay:(NSTimeInterval)minDelay {
    if (self.finished) return;
    [self closeFileHandle];

    // ★换源/重试前先摘干净旧 task★
    //   旧实现的问题是“每个 fetcher 一条 session，换源时不 invalidate”，
    //   每换一次源就漏一条 session（连接池 + 队列 + delegate 全挂在那儿）。
    //   现在 session 只有引擎一条，换源只需取消 task 并从映射里摘除 ——
    //   迟到的回调因为 task != currentTask 会被丢掉，不会串到新 attempt。
    [self detachCurrentTask];

    if (!hard && self.retryCount < kBackoffCount) {
        NSTimeInterval delay = kBackoffSeconds[self.retryCount];
        if (minDelay > delay) delay = MIN(minDelay, kMaxRetryAfterSeconds);
        self.retryCount++;
        [A2Log log:@"[A2-DL] 重试 attempt=%ld/%ld delay=%.0fs 原因=%@",
              (long)self.retryCount, (long)kBackoffCount, delay,
              error.localizedDescription ?: @"(未知)"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       self.queue, ^{
            if (!self.finished) [self startCurrentCandidate];
        });
        return;
    }

    // 该候选耗尽（硬失败立刻算耗尽），记下错误并换源
    [self.candidateErrors addObject:error];
    self.retryCount = 0;
    self.candidateIndex++;

    // ★[A2-MIRROR] 判据行：失败切源（镜像 ⇄ 官方）★
    //   本轮命令里加镜像链后，候选链默认是「镜像优先 → 官方兜底」，
    //   所以这条行是「真机上到底切没切、切到哪」的唯一证据。
    {
        NSUInteger total = self.request.candidateURLs.count;
        NSString *from = self.request.candidateURLs[(NSUInteger)(self.candidateIndex - 1)].absoluteString;
        NSString *to = self.candidateIndex < (NSInteger)total
            ? self.request.candidateURLs[(NSUInteger)self.candidateIndex].absoluteString
            : @"(无更多候选)";
        [A2Log log:@"[A2-MIRROR] failover 候选=%ld/%lu from=%@ to=%@ 原因=%@",
              (long)self.candidateIndex, (unsigned long)total, from, to,
              error.localizedDescription ?: @"(未知)"];
    }

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
    [self detachCurrentTask];
    [self discardPartialDownload];
    self.receivedBytes = 0;
    self.strongETag = nil;
    self.lastModified = nil;
    self.retryCount = 0;
    if (!self.finished) [self startCurrentCandidate];
}

#pragma mark task / 槽位

/// 取消当前 task 并从引擎的 task→fetcher 映射里摘除，同时归还并发槽位。
/// 只在 self.queue 上调用（startCurrentCandidate / 失败出口 / pause / cancel / finish）。
- (void)detachCurrentTask {
    NSURLSessionDataTask *task = self.currentTask;
    if (task) {
        self.currentTask = nil;
        A2DownloadEngine *engine = self.engine ?: [A2DownloadEngine sharedClient];
        [engine detachTask:task];       // 先摘映射：迟到的 delegate 回调将查不到 fetcher
        [task cancel];
    }
    [self releaseTaskSlot];
}

/// 归还闸门槽位（槽位跟 task 走，成对归还；重复调用是安全的）
- (void)releaseTaskSlot {
    if (!self.currentTaskHoldsSlot) return;
    self.currentTaskHoldsSlot = NO;
    [[A2DownloadGate sharedGate] releaseSlot];
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
    [self detachCurrentTask];               // 只还槽 + 摘映射，共享 session 不销毁
    [[A2DownloadGate sharedGate] noteSuccess];
    {
        A2DownloadEngine *engine = self.engine ?: [A2DownloadEngine sharedClient];
        [engine fetcherDidFinish:self];
    }

    A2DownloadCompletion cb = self.completion;
    if (cb) cb(YES, nil);
}

- (void)finishWithError:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    [self closeFileHandle];
    [self stopSpeedTimer];
    [self detachCurrentTask];
    self.operation.state = A2DownloadStateFailed;
    {
        A2DownloadEngine *engine = self.engine ?: [A2DownloadEngine sharedClient];
        [engine fetcherDidFinish:self];
    }

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
        // ★共享 session 不在这里 invalidate★ —— 只取消这一条 task、还掉闸门槽位。
        [self detachCurrentTask];

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
        [self closeFileHandle];
        [self stopSpeedTimer];
        [self detachCurrentTask];
        [self discardPartialDownload];
        {
        A2DownloadEngine *engine = self.engine ?: [A2DownloadEngine sharedClient];
        [engine fetcherDidFinish:self];
    }

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

@interface A2DownloadEngine () <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableDictionary<NSString *, A2FileFetcher *> *active;
@property (nonatomic, strong) dispatch_queue_t queue;
/// ★会话复用★ 进程内唯一一条 session：连接池 / TLS 会话 / HTTP2 多路复用都只在这里建立一次。
///   delegate 挂在引擎上，回调按 taskIdentifier 分发给对应的 fetcher。
@property (nonatomic, strong, nullable) NSURLSession *session;
/// taskIdentifier -> fetcher（session 只有一条，靠它把回调送回正确的下载句柄）
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, A2FileFetcher *> *taskMap;
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
    _taskMap = [NSMutableDictionary dictionary];
    _queue = dispatch_queue_create("dev.airdevs.air2.download", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc {
    [self.session invalidateAndCancel];
}

#pragma mark 共享 session

- (NSURLSession *)sharedSession {
    @synchronized (self) {
        if (self.session) return self.session;

        NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
        cfg.timeoutIntervalForRequest = 60;
        cfg.timeoutIntervalForResource = 3600;
        // 小文件多 ⇒ 单 host 连接上限要跟批量并发同量级（iOS 默认 6 会把并发压回去）
        cfg.HTTPMaximumConnectionsPerHost = 32;
        cfg.HTTPShouldUsePipelining = YES;      // 老字段（现代系统多忽略），保留无害
        cfg.waitsForConnectivity = NO;          // 无网时立即失败由上层重试，别在这里干等

        // delegateQueue=nil ⇒ NSURLSession 自建串行 queue，保证 didReceiveResponse/didReceiveData/
        // didCompleteWithError 的先后顺序；真正的活都 dispatch 到各 fetcher 自己的队列。
        self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];

        // ★判据行★ 只要这条出现一次（而不是每个文件一次），就说明会话复用生效了。
        [A2Log log:@"[A2-DL] session 复用：进程内单实例（每文件不再各建 session）maxConnPerHost=%ld",
              (long)cfg.HTTPMaximumConnectionsPerHost];
        return self.session;
    }
}

#pragma mark task -> fetcher 分发

- (void)attachFetcher:(A2FileFetcher *)fetcher toTask:(NSURLSessionDataTask *)task {
    if (!fetcher || !task) return;
    @synchronized (self) { self.taskMap[@(task.taskIdentifier)] = fetcher; }
}

- (void)detachTask:(NSURLSessionTask *)task {
    if (!task) return;
    @synchronized (self) { [self.taskMap removeObjectForKey:@(task.taskIdentifier)]; }
}

- (nullable A2FileFetcher *)fetcherForTask:(NSURLSessionTask *)task {
    if (!task) return nil;
    @synchronized (self) { return self.taskMap[@(task.taskIdentifier)]; }
}

/// 下载句柄收尾：从活跃表与映射里摘掉，避免 active/taskMap 只增不减
- (void)fetcherDidFinish:(A2FileFetcher *)fetcher {
    if (!fetcher) return;
    @synchronized (self) {
        NSArray<NSString *> *keys = [self.active allKeysForObject:fetcher];
        if (keys.count > 0) [self.active removeObjectsForKeys:keys];
        for (NSNumber *key in self.taskMap.allKeys) {
            if (self.taskMap[key] == fetcher) [self.taskMap removeObjectForKey:key];
        }
    }
}

#pragma mark NSURLSessionDataDelegate（转发到对应 fetcher）

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {

    A2FileFetcher *fetcher = [self fetcherForTask:dataTask];
    if (!fetcher) { completionHandler(NSURLSessionResponseCancel); return; }
    [fetcher handleResponse:response forTask:dataTask completionHandler:completionHandler];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {

    A2FileFetcher *fetcher = [self fetcherForTask:dataTask];
    if (!fetcher) return;
    [fetcher handleData:data forTask:dataTask];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {

    A2FileFetcher *fetcher = [self fetcherForTask:task];
    // 映射先摘：后续迟到的数据/回调不会再落到这个 fetcher
    [self detachTask:task];
    if (!fetcher) return;
    [fetcher handleTask:task didCompleteWithError:error];
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
    fetcher.engine = self;          // ★session 归引擎，fetcher 只持 task★
    fetcher.operation = op;
    fetcher.progressHandler = progress;
    fetcher.speedHandler = speed;
    fetcher.completion = completion;
    op.owner = fetcher;

    @synchronized (self) { self.active[key] = fetcher; }
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
    if (operation.resumeKey) {
        @synchronized (self) { [self.active removeObjectForKey:operation.resumeKey]; }
    }
}

- (void)cancelAll {
    // 先取快照再遍历 —— cancel 会修改 active 字典，直接遍历会崩
    NSArray<A2FileFetcher *> *fetchers = nil;
    NSArray<NSString *> *keys = nil;
    @synchronized (self) {
        fetchers = self.active.allValues;
        keys = self.active.allKeys;
        [self.active removeObjectsForKeys:keys];
    }

    for (A2FileFetcher *f in fetchers) {
        [f cancel];
    }
}

- (nullable A2FileFetcher *)fetcherForOperation:(A2DownloadOperation *)op {
    if (!op.resumeKey) return nil;
    @synchronized (self) { return self.active[op.resumeKey]; }
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
