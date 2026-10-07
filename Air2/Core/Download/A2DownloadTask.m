//
//  A2DownloadTask.m
//  Air2
//

#import "A2DownloadTask.h"

#pragma mark - A2DownloadItem

@implementation A2DownloadItem
+ (instancetype)url:(NSString *)url destination:(NSString *)dest size:(long long)size {
    A2DownloadItem *i = [A2DownloadItem new];
    i.url = url;
    i.destinationPath = dest;
    i.expectedSize = size;
    return i;
}
@end

#pragma mark - A2DownloadTask

@interface A2DownloadTask ()
@property (nonatomic, copy) NSString *taskID;
@property (nonatomic, assign) A2DownloadState state;
@property (nonatomic, strong) NSMutableArray<A2DownloadItem *> *items;
@property (nonatomic, assign) long long totalBytes;
@property (nonatomic, assign) long long downloadedBytes;
@property (nonatomic, assign) double speed;

// 速度计算：滑动窗口，避免瞬时抖动
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *samples;
@property (nonatomic, assign) NSTimeInterval lastNotifyTime;
// 供引擎更新字节数
- (void)addDownloadedBytes:(long long)delta;
@end

@implementation A2DownloadTask

- (instancetype)initWithTitle:(NSString *)title {
    self = [super init];
    if (!self) return nil;
    _title = [title copy];
    _taskID = [NSString stringWithFormat:@"%.0f-%u",
               [NSDate date].timeIntervalSince1970 * 1000, arc4random_uniform(10000)];
    _items = [NSMutableArray array];
    _samples = [NSMutableArray array];
    _state = A2DownloadStatePending;
    _totalBytes = 0;
    _downloadedBytes = 0;
    return self;
}

- (void)addItem:(A2DownloadItem *)item {
    if (!item) return;
    [_items addObject:item];
    _totalBytes += item.expectedSize;
}

- (double)progress {
    if (_totalBytes <= 0) return 0;
    return MIN(1.0, (double)_downloadedBytes / (double)_totalBytes);
}

/// 更新已下载字节并计算速度。
///
/// 速度用最近 3 秒的滑动窗口算，而不是「本次 - 上次」，
/// 否则网络抖动时速度数字会疯狂跳动，看起来像坏了。
- (void)addDownloadedBytes:(long long)delta {
    _downloadedBytes += delta;

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    [_samples addObject:@{ @"t": @(now), @"b": @(delta) }];

    // 注意：NSDictionary 的下标返回 id，不能直接点 longLongValue。
    // 要先取出来再拆箱。
    while (_samples.count > 0) {
        NSNumber *oldest = _samples.firstObject[@"t"];
        if (now - oldest.doubleValue <= 3.0) break;
        [_samples removeObjectAtIndex:0];
    }

    long long totalInWindow = 0;
    for (NSDictionary<NSString *, NSNumber *> *s in _samples) {
        NSNumber *bytes = s[@"b"];
        totalInWindow += bytes.longLongValue;
    }

    NSTimeInterval window = 3.0;
    if (_samples.count > 0) {
        NSNumber *oldest = _samples.firstObject[@"t"];
        window = MAX(0.5, now - oldest.doubleValue);
    }
    _speed = (double)totalInWindow / window;

    // 进度回调节流到 100ms —— 每收一个包就刷 UI 会掉帧
    if (now - _lastNotifyTime >= 0.1) {
        _lastNotifyTime = now;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self.onProgress) self.onProgress(self.progress, self.speed);
        });
    }
}

- (void)setState:(A2DownloadState)state {
    if (_state == state) return;
    _state = state;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self.onStateChange) self.onStateChange(state);
    });
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<A2DownloadTask %@ %.1f%% %.1fMB/s>",
            self.title, self.progress * 100, self.speed / 1024.0 / 1024.0];
}

@end
