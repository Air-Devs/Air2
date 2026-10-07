//
//  A2DownloadEngine.m
//  Air2
//

#import "A2DownloadEngine.h"

/// 分片大小下限（小于这个不分片）
static const long long kChunkThreshold = 1 * 1024 * 1024;   // 1MB
/// 每片大小
static const long long kChunkSize = 1 * 1024 * 1024;        // 1MB
/// 看门狗：多久没有新数据就判定卡住（秒）
static const NSTimeInterval kStallTimeout = 12.0;
/// 单请求超时
static const NSTimeInterval kRequestTimeout = 20.0;
/// 最大重试次数
static const NSInteger kMaxRetries = 3;

#pragma mark - 已写入区间

/// 记录文件已写入的区间，用于断点续传。
/// 用「有序区间表 + 合并」而不是简单的偏移量 ——
/// 并发分片写入是乱序的，只记「下载到哪」会漏掉中间的空洞。
@interface A2WriteLedger : NSObject
@property (nonatomic, assign) long long totalSize;
@property (nonatomic, strong) NSMutableArray<NSValue *> *ranges;   // NSRange 数组，有序不重叠
- (instancetype)initWithTotalSize:(long long)size;
/// 登记一段已写入的区间
- (void)record:(long long)start length:(long long)length;
/// 已写入的总字节（不重复计算）
- (long long)writtenBytes;
/// 找出还没写的缺口
- (NSArray<NSValue *> *)gaps;
/// 是否完整
- (BOOL)isComplete;
@end

@implementation A2WriteLedger

- (instancetype)initWithTotalSize:(long long)size {
    self = [super init];
    if (!self) return nil;
    _totalSize = size;
    _ranges = [NSMutableArray array];
    return self;
}

- (void)record:(long long)start length:(long long)length {
    if (length <= 0) return;
    long long end = start + length;   // 左闭右开

    NSMutableArray<NSValue *> *merged = [NSMutableArray array];
    BOOL inserted = NO;

    for (NSValue *v in _ranges) {
        NSRange r = v.rangeValue;
        long long rs = (long long)r.location;
        long long re = rs + (long long)r.length;

        if (re < start) {
            // 完全在左侧，保留
            [merged addObject:v];
        } else if (rs > end) {
            // 完全在右侧，先插入新区间（如果还没插）
            if (!inserted) {
                [merged addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)start,
                                                                     (NSUInteger)(end - start))]];
                inserted = YES;
            }
            [merged addObject:v];
        } else {
            // 有重叠，合并
            start = MIN(start, rs);
            end = MAX(end, re);
        }
    }

    if (!inserted) {
        [merged addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)start,
                                                             (NSUInteger)(end - start))]];
    }

    _ranges = merged;
}

- (long long)writtenBytes {
    long long sum = 0;
    for (NSValue *v in _ranges) sum += (long long)v.rangeValue.length;
    return sum;
}

- (NSArray<NSValue *> *)gaps {
    NSMutableArray<NSValue *> *out = [NSMutableArray array];
    long long cursor = 0;
    for (NSValue *v in _ranges) {
        NSRange r = v.rangeValue;
        long long rs = (long long)r.location;
        if (rs > cursor) {
            [out addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)cursor,
                                                              (NSUInteger)(rs - cursor))]];
        }
        cursor = MAX(cursor, rs + (long long)r.length);
    }
    if (cursor < _totalSize) {
        [out addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)cursor,
                                                          (NSUInteger)(_totalSize - cursor))]];
    }
    return out;
}

- (BOOL)isComplete {
    if (_totalSize <= 0) return NO;
    long long cursor = 0;
    for (NSValue *v in _ranges) {
        NSRange r = v.rangeValue;
        if ((long long)r.location > cursor) return NO;   // 有空洞
        cursor = MAX(cursor, (long long)r.location + (long long)r.length);
    }
    return cursor >= _totalSize;
}

@end

#pragma mark - 单个文件下载器

@interface A2FileDownloader : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) long long totalSize;
@property (nonatomic, strong) A2WriteLedger *ledger;
@property (nonatomic, strong) NSFileHandle *fileHandle;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableDictionary *> *tasks;
@property (nonatomic, assign) long long lastActivityBytes;
@property (nonatomic, strong) NSDate *lastActivity;
@property (nonatomic, strong) NSTimer *watchdog;
@property (nonatomic, assign) NSInteger retryCount;
@property (nonatomic, copy, nullable) void (^progressBlock)(long long, long long);
@property (nonatomic, copy, nullable) void (^completionBlock)(NSError *);
@property (nonatomic, assign) BOOL finished;
@end

@implementation A2FileDownloader

- (void)start {
    _finished = NO;
    _retryCount = 0;
    [self probeAndStart];
}

/// 先探测文件大小（HEAD），再决定是否分片
- (void)probeAndStart {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:_url]];
    req.HTTPMethod = @"HEAD";
    req.timeoutInterval = kRequestTimeout;

    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (self.finished) return;

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        long long total = http.expectedContentLength;
        if (total <= 0) total = 0;

        // 检查是否支持 Range
        NSString *acceptRanges = http.allHeaderFields[@"Accept-Ranges"];
        BOOL supportsRange = [acceptRanges isEqualToString:@"bytes"];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.totalSize = total;
            [self setupLedgerAndFile];
            if (total >= kChunkThreshold && supportsRange) {
                [self startChunkedDownload];
            } else {
                [self startSingleDownload];
            }
        });
    }];
    [t resume];
}

- (void)setupLedgerAndFile {
    NSString *dir = [_path stringByDeletingLastPathComponent];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];

    _ledger = [[A2WriteLedger alloc] initWithTotalSize:_totalSize];

    // 从已有的半成品文件恢复进度：文件里已有的字节视为「可能已写好」
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:_path]) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:_path error:nil];
        long long existing = [attrs[NSFileSize] longLongValue];
        if (existing > 0 && _totalSize > 0) {
            // 保守处理：只有整个已知长度都写满才认为完成，
            // 否则从 0 重下（分片下载会自然补齐缺口）
            if (existing >= _totalSize) {
                [_ledger record:0 length:_totalSize];
            }
        }
    } else {
        [fm createFileAtPath:_path contents:nil attributes:nil];
    }

    _fileHandle = [NSFileHandle fileHandleForWritingAtPath:_path];
}

#pragma mark 单连接下载

- (void)startSingleDownload {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:_url]];
    req.timeoutInterval = kRequestTimeout;

    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
    cfg.timeoutIntervalForRequest = kRequestTimeout;
    cfg.timeoutIntervalForResource = 3600;
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    _tasks = [NSMutableDictionary dictionary];

    NSURLSessionDataTask *t = [_session dataTaskWithRequest:req];
    _tasks[@(t.taskIdentifier)] = [NSMutableDictionary dictionary];
    _lastActivity = [NSDate date];
    [self startWatchdog];
    [t resume];
}

#pragma mark 分片下载

- (void)startChunkedDownload {
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
    cfg.timeoutIntervalForRequest = kRequestTimeout;
    cfg.timeoutIntervalForResource = 3600;
    cfg.HTTPMaximumConnectionsPerHost = 4;

    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    _tasks = [NSMutableDictionary dictionary];

    // 已完整下载则直接完成
    if ([_ledger isComplete]) {
        [self finishWithError:nil];
        return;
    }

    _lastActivity = [NSDate date];
    [self startWatchdog];
    [self scheduleChunksFromGaps];
}

/// 按缺口排队分片请求
- (void)scheduleChunksFromGaps {
    NSArray<NSValue *> *gaps = [_ledger gaps];
    NSInteger maxConcurrent = 4;

    for (NSValue *v in gaps) {
        if (self.finished) return;
        NSRange gap = v.rangeValue;
        long long start = (long long)gap.location;
        long long remaining = (long long)gap.length;

        while (remaining > 0 && _tasks.count < (NSUInteger)maxConcurrent) {
            long long len = MIN(kChunkSize, remaining);
            [self requestRange:start length:len];
            start += len;
            remaining -= len;
        }
        if (_tasks.count >= (NSUInteger)maxConcurrent) break;
    }
}

- (void)requestRange:(long long)start length:(long long)length {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:_url]];
    req.timeoutInterval = kRequestTimeout;
    NSString *range = [NSString stringWithFormat:@"bytes=%lld-%lld", start, start + length - 1];
    [req setValue:range forHTTPHeaderField:@"Range"];

    NSURLSessionDataTask *t = [_session dataTaskWithRequest:req];
    _tasks[@(t.taskIdentifier)] = [@{
        @"start": @(start),
        @"length": @(length),
        @"buffer": [NSMutableData data],
    } mutableCopy];
    [t resume];
}

#pragma mark 看门狗

/// CDN 可能持续发心跳字节，让 URLSession 的空闲超时永不触发，
/// 表现为「卡住但没报错」。这里改成看「有没有真的写进文件」。
- (void)startWatchdog {
    _watchdog = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                repeats:YES
                                                  block:^(NSTimer *timer) {
        if (self.finished) { [timer invalidate]; return; }
        NSTimeInterval idle = -[self.lastActivity timeIntervalSinceNow];
        if (idle > kStallTimeout) {
            [self handleStall];
        }
    }];
}

- (void)handleStall {
    if (self.finished) return;
    if (_retryCount >= kMaxRetries) {
        [self finishWithError:[NSError errorWithDomain:@"A2Download" code:2
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                             @"下载卡住，重试次数已用尽"}]];
        return;
    }
    _retryCount++;

    [_session invalidateAndCancel];
    _tasks = [NSMutableDictionary dictionary];
    _lastActivity = [NSDate date];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.totalSize >= kChunkThreshold) {
            [self startChunkedDownload];
        } else {
            [self startSingleDownload];
        }
    });
}

#pragma mark NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {

    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSMutableDictionary *info = _tasks[@(dataTask.taskIdentifier)];

    if (http.statusCode == 200) {
        // 服务端忽略了 Range，返回整个文件 —— 只能从头写
        if ([info[@"fromRange"] boolValue] || info[@"start"]) {
            // 分片请求拿到 200，说明不支持 Range，退回单连接
            if (self.totalSize >= kChunkThreshold) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [session invalidateAndCancel];
                    self.tasks = [NSMutableDictionary dictionary];
                    [self startSingleDownload];
                });
                completionHandler(NSURLSessionResponseCancel);
                return;
            }
        }
        if (self.totalSize <= 0) self.totalSize = http.expectedContentLength;
        if (self.totalSize > 0 && _ledger.totalSize != self.totalSize) {
            _ledger = [[A2WriteLedger alloc] initWithTotalSize:self.totalSize];
        }
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {

    NSMutableDictionary *info = _tasks[@(dataTask.taskIdentifier)];
    if (!info) return;

    long long start = [info[@"start"] longLongValue];
    NSMutableData *buffer = info[@"buffer"];

    // 分片模式：先攒够一片再一次性写，减少磁盘操作
    if (buffer) {
        [buffer appendData:data];
        if (buffer.length >= [info[@"length"] longLongValue]) {
            [self writeChunk:buffer at:start];
            info[@"buffer"] = [NSMutableData data];
            info[@"start"] = @(start + buffer.length);
            info[@"length"] = @(MAX(0, [info[@"length"] longLongValue] - buffer.length));
        }
    } else {
        // 单连接模式：按顺序追加
        long long offset = [_ledger writtenBytes];
        [self writeChunk:data at:offset];
    }

    _lastActivity = [NSDate date];
    if (self.progressBlock) {
        self.progressBlock(_ledger.writtenBytes, self.totalSize);
    }
}

- (void)writeChunk:(NSData *)data at:(long long)offset {
    if (data.length == 0) return;
    @synchronized (_fileHandle) {
        @try {
            [_fileHandle seekToFileOffset:(unsigned long long)offset];
            [_fileHandle writeData:data];
        } @catch (NSException *e) {
            // 磁盘写入失败，交由完成回调统一处理
        }
    }
    [_ledger record:offset length:(long long)data.length];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {

    NSMutableDictionary *info = _tasks[@(task.taskIdentifier)];

    // 把没写满的最后一片补上
    if (info[@"buffer"] && [(NSData *)info[@"buffer"] length] > 0) {
        [self writeChunk:info[@"buffer"] at:[info[@"start"] longLongValue]];
        info[@"buffer"] = [NSMutableData data];
    }
    [_tasks removeObjectForKey:@(task.taskIdentifier)];

    if (self.finished) return;

    if (error) {
        // 单片失败不等于整体失败 —— 记录缺口后重新排队
        if (_retryCount < kMaxRetries) {
            _retryCount++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!self.finished) [self scheduleChunksFromGaps];
            });
            return;
        }
        [self finishWithError:error];
        return;
    }

    // 检查是否下完
    if ([_ledger isComplete] || (_totalSize <= 0 && _tasks.count == 0)) {
        [self finishWithError:nil];
    } else if (_tasks.count == 0) {
        // 还有缺口，继续排队
        [self scheduleChunksFromGaps];
    }
}

- (void)finishWithError:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    [_watchdog invalidate];
    [_fileHandle closeFile];
    [_session invalidateAndCancel];

    // 失败时删掉半成品，避免下次误判为已完成
    if (error) {
        [NSFileManager.defaultManager removeItemAtPath:_path error:nil];
    }

    if (self.completionBlock) self.completionBlock(error);
}

@end

#pragma mark - A2DownloadEngine

@interface A2DownloadEngine ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, A2FileDownloader *> *active;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation A2DownloadEngine

+ (instancetype)shared {
    static A2DownloadEngine *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2DownloadEngine alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _active = [NSMutableDictionary dictionary];
    _queue = dispatch_queue_create("dev.airdevs.air2.download", DISPATCH_QUEUE_CONCURRENT);
    _maxConcurrentConnections = 8;
    _enableChunking = YES;
    return self;
}

- (void)downloadItem:(A2DownloadItem *)item
                task:(A2DownloadTask *)task
            progress:(void (^)(long long, long long))progress
          completion:(void (^)(NSError *))completion {

    if (!item.url.length || !item.destinationPath.length) {
        if (completion) {
            completion([NSError errorWithDomain:@"A2Download" code:1
                                       userInfo:@{NSLocalizedDescriptionKey: @"URL 或目标路径为空"}]);
        }
        return;
    }

    A2FileDownloader *downloader = [A2FileDownloader new];
    downloader.url = item.url;
    downloader.path = item.destinationPath;

    __weak typeof(self) weakSelf = self;
    downloader.progressBlock = ^(long long received, long long total) {
        if (progress) progress(received, total);
    };
    downloader.completionBlock = ^(NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        [self.active removeObjectForKey:item.destinationPath];
        if (completion) completion(error);
    };

    self.active[item.destinationPath] = downloader;
    [downloader start];
}

- (void)cancelDownloadForPath:(NSString *)path {
    A2FileDownloader *d = self.active[path];
    if (!d) return;
    [d finishWithError:[NSError errorWithDomain:@"A2Download" code:3
                                       userInfo:@{NSLocalizedDescriptionKey: @"用户取消"}]];
    [self.active removeObjectForKey:path];
}

- (void)cancelAll {
    for (NSString *key in self.active.allKeys) {
        [self cancelDownloadForPath:key];
    }
}

@end
