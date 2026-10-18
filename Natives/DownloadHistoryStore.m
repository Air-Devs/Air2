#import "DownloadHistoryStore.h"

/// 历史条目上限（LRU 裁尾）
static const NSUInteger kDownloadHistoryMaxEntries = 200;

@interface DownloadHistoryStore ()
@property (nonatomic, strong) dispatch_queue_t ioQueue;                    // 专用串行 IO 队列
@property (nonatomic, strong) NSLock *lock;                                // 保护内存数组与 loaded 标记
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *entries;     // 新→旧
@property (nonatomic, assign) BOOL loaded;
@end

@implementation DownloadHistoryStore

+ (instancetype)sharedStore {
    static DownloadHistoryStore *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _ioQueue = dispatch_queue_create("com.amethyst.downloadhistory.io", DISPATCH_QUEUE_SERIAL);
        _lock = [[NSLock alloc] init];
        _entries = [NSMutableArray array];
        _loaded = NO;
    }
    return self;
}

#pragma mark - 路径

- (NSString *)historyFilePath {
    NSString *directory = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/Amethyst"];
    return [directory stringByAppendingPathComponent:@"download_history.json"];
}

#pragma mark - 懒加载

- (void)ensureLoaded {
    [self.lock lock];
    BOOL needLoad = !self.loaded;
    self.loaded = YES;
    [self.lock unlock];
    if (!needLoad) return;

    // 首次访问：在串行队列上同步读取（读取完成后队列继续处理后续写入，保证顺序一致）
    dispatch_sync(self.ioQueue, ^{
        NSString *path = [self historyFilePath];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length == 0) return;

        id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![object isKindOfClass:[NSArray class]]) {
            // 文件损坏：删除重建
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            return;
        }

        NSMutableArray<NSDictionary *> *valid = [NSMutableArray array];
        for (id entry in (NSArray *)object) {
            if ([entry isKindOfClass:[NSDictionary class]]) {
                [valid addObject:entry];
            }
        }
        [self.lock lock];
        [self.entries removeAllObjects];
        [self.entries addObjectsFromArray:valid];
        [self.lock unlock];
    });
}

#pragma mark - 公开接口

- (void)recordEntryWithDictionary:(NSDictionary *)entry {
    if (!entry || entry.count == 0 || ![entry isKindOfClass:[NSDictionary class]]) return;

    NSMutableDictionary *mutableEntry = [entry mutableCopy];
    if (!mutableEntry[@"time"]) {
        mutableEntry[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    }

    [self ensureLoaded];

    [self.lock lock];
    // 新条目插头部，超出上限裁尾（LRU）
    [self.entries insertObject:[mutableEntry copy] atIndex:0];
    if (self.entries.count > kDownloadHistoryMaxEntries) {
        [self.entries removeObjectsInRange:NSMakeRange(kDownloadHistoryMaxEntries,
                                                        self.entries.count - kDownloadHistoryMaxEntries)];
    }
    NSArray *snapshot = [self.entries copy];
    [self.lock unlock];

    dispatch_async(self.ioQueue, ^{
        [self writeEntriesToDisk:snapshot];
    });
}

- (NSArray<NSDictionary *> *)allEntries {
    [self ensureLoaded];
    [self.lock lock];
    NSArray<NSDictionary *> *copy = [self.entries copy];
    [self.lock unlock];
    return copy;
}

- (void)clearAll {
    [self.lock lock];
    self.loaded = YES;
    [self.entries removeAllObjects];
    [self.lock unlock];

    dispatch_async(self.ioQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:[self historyFilePath] error:nil];
    });
}

#pragma mark - 写盘

- (void)writeEntriesToDisk:(NSArray<NSDictionary *> *)entries {
    NSString *path = [self historyFilePath];
    NSString *directory = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSData *data = [NSJSONSerialization dataWithJSONObject:(entries ?: @[])
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (!data) return;
    [data writeToFile:path options:NSDataWritingAtomic error:nil];
}

@end
