//
//  A2ModpackFileDownloader.m
//  Air2
//

#import "A2ModpackFileDownloader.h"
#import "A2ModpackModels.h"
#import "A2DownloadEngine.h"

@interface A2ModpackFileDownloader ()

/// 状态机只在 stateQueue 上推进，避免「主线程 pump」与「下载回调 complete」
/// 同时读写 active/queue 造成竞态。
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, assign) NSUInteger concurrency;
@property (nonatomic, assign) BOOL cancelled;

@property (nonatomic, copy, nullable) NSString *root;
@property (nonatomic, strong) NSMutableArray<A2ModpackFile *> *queue;
@property (nonatomic, strong) NSMutableArray<NSString *> *failures;
@property (nonatomic, strong) NSMutableArray<A2DownloadOperation *> *operations;
@property (nonatomic, assign) NSInteger total;
@property (nonatomic, assign) NSInteger completed;
@property (nonatomic, assign) NSUInteger active;

@property (nonatomic, copy, nullable) A2ModpackDownloadProgress progressBlock;
@property (nonatomic, copy, nullable) A2ModpackDownloadCompletion completionBlock;

@end

@implementation A2ModpackFileDownloader

- (instancetype)initWithConcurrency:(NSUInteger)concurrency {
    self = [super init];
    if (!self) return nil;
    _concurrency = concurrency > 0 ? concurrency : 4;
    _stateQueue = dispatch_queue_create("com.airdevs.air2.modpack.downloader", DISPATCH_QUEUE_SERIAL);
    _queue = [NSMutableArray array];
    _failures = [NSMutableArray array];
    _operations = [NSMutableArray array];
    return self;
}

- (instancetype)init {
    return [self initWithConcurrency:4];
}

#pragma mark - 对外入口

- (void)downloadFiles:(NSArray<A2ModpackFile *> *)files
                toRoot:(NSString *)root
              progress:(A2ModpackDownloadProgress)progress
            completion:(A2ModpackDownloadCompletion)completion {

    __weak typeof(self) weakSelf = self;
    dispatch_async(_stateQueue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.root = root;
        [self.queue setArray:files];
        [self.failures removeAllObjects];
        [self.operations removeAllObjects];
        self.total = (NSInteger)files.count;
        self.completed = 0;
        self.active = 0;
        self.cancelled = NO;
        self.progressBlock = progress;
        self.completionBlock = completion;

        if (self.total == 0) {
            [self finish];
            return;
        }
        [self pump];
    });
}

- (void)cancel {
    __weak typeof(self) weakSelf = self;
    dispatch_async(_stateQueue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.cancelled = YES;
        [self.queue removeAllObjects];
        for (A2DownloadOperation *op in self.operations) {
            [[A2DownloadEngine sharedClient] cancelOperation:op];
        }
        [self.operations removeAllObjects];
        self.completionBlock = nil;
        self.progressBlock = nil;
    });
}

#pragma mark - 调度（stateQueue 上执行）

- (void)pump {
    if (self.cancelled) return;
    while (self.active < self.concurrency && self.queue.count > 0) {
        A2ModpackFile *file = self.queue.firstObject;
        [self.queue removeObjectAtIndex:0];
        [self startFile:file];
    }
}

- (void)startFile:(A2ModpackFile *)file {
    NSString *relative = file.relativePath;
    if (relative.length == 0 || file.downloadURLs.count == 0) {
        NSString *name = relative.length > 0 ? relative : @"未知文件";
        [self.failures addObject:[NSString stringWithFormat:@"%@：缺少下载地址", name]];
        [self completeOne];
        return;
    }

    NSString *dest = [self.root stringByAppendingPathComponent:relative];
    [NSFileManager.defaultManager createDirectoryAtPath:dest.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];

    A2DownloadRequest *req = [A2DownloadRequest new];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *raw in file.downloadURLs) {
        NSURL *url = [NSURL URLWithString:raw];
        if (url) [urls addObject:url];
    }
    req.candidateURLs = urls;
    req.destinationPath = dest;
    req.expectedSHA1 = file.sha1;
    req.expectedSize = file.size;
    // 没有 SHA1 时，jar / zip 用 EOCD 兜底校验完整性
    req.allowZipFallbackCheck = file.sha1.length == 0;
    req.taskIdentifier = relative;

    self.active++;
    __weak typeof(self) weakSelf = self;
    A2DownloadOperation *op = [[A2DownloadEngine sharedClient] startRequest:req
        progress:nil speed:nil
        completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        dispatch_async(self.stateQueue, ^{
            if (!success) {
                NSString *reason = error.localizedDescription ?: @"下载失败";
                [self.failures addObject:[NSString stringWithFormat:@"%@：%@", relative, reason]];
            }
            [self completeOne];
        });
    }];
    if (op) [self.operations addObject:op];
}

- (void)completeOne {
    self.completed++;
    if (self.active > 0) self.active--;
    [self reportProgress];
    if (self.completed >= self.total) {
        [self finish];
        return;
    }
    [self pump];
}

#pragma mark - 回调

- (void)reportProgress {
    NSInteger done = self.completed;
    NSInteger total = self.total;
    A2ModpackDownloadProgress block = self.progressBlock;
    if (!block) return;
    NSString *message = [NSString stringWithFormat:@"正在下载整合包文件（%ld/%ld）", (long)done, (long)total];
    dispatch_async(dispatch_get_main_queue(), ^{ block(done, total, message); });
}

- (void)finish {
    A2ModpackDownloadCompletion block = self.completionBlock;
    NSArray<NSString *> *failures = [self.failures copy];
    self.completionBlock = nil;
    self.progressBlock = nil;
    [self.operations removeAllObjects];
    if (!block) return;
    dispatch_async(dispatch_get_main_queue(), ^{ block(failures); });
}

@end
