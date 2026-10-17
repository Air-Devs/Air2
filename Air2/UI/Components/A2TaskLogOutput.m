//
//  A2TaskLogOutput.m
//  Air2
//

#import "A2TaskLogOutput.h"

/// 默认行数上限。安装过程可能产生上千行，全留着会吃内存且没人往回翻。
static const NSInteger kDefaultMaxLines = 200;

@interface A2TaskLogOutput ()
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSMutableArray<NSString *> *mutableLines;
@property (nonatomic, assign, getter=isActive) BOOL active;
/// 上一行的「进度类型」—— 用于覆盖式更新
@property (nonatomic, copy, nullable) NSString *lastProgressKind;
@property (nonatomic, assign) NSUInteger lastProgressIndex;
@end

@implementation A2TaskLogOutput

- (instancetype)initWithTitle:(NSString *)title {
    return [self initWithTitle:title maxLines:kDefaultMaxLines];
}

- (instancetype)initWithTitle:(NSString *)title maxLines:(NSInteger)maxLines {
    self = [super init];
    if (!self) return nil;
    _title = [title copy];
    _maxLines = maxLines > 0 ? maxLines : kDefaultMaxLines;
    _mutableLines = [NSMutableArray array];
    return self;
}

- (NSArray<NSString *> *)lines {
    return [_mutableLines copy];
}

#pragma mark - 会话

- (void)start {
    [_mutableLines removeAllObjects];
    _lastProgressKind = nil;
    self.active = YES;
    [self notifyLinesChanged];
}

- (void)stop {
    self.active = NO;
    if (self.onActiveChanged) self.onActiveChanged(NO);
}

- (void)clear {
    [_mutableLines removeAllObjects];
    _lastProgressKind = nil;
    [self notifyLinesChanged];
}

#pragma mark - 追加

- (void)append:(NSString *)line {
    if (line.length == 0) return;
    [self appendRaw:[self timestamped:line]];

    // 新的一行意味着上一段进度结束了 —— 下次进度要新起一行
    _lastProgressKind = nil;
}

/// 覆盖式进度行。
///
/// 「下载中 45%」这种每秒更新好几次的内容，如果每次都追加，
/// 几秒钟就能刷满整个列表，把真正的信息挤出去。
/// 这里让同一类进度只占一行，不断就地替换。
- (void)appendProgress:(NSString *)line {
    if (line.length == 0) return;

    // 进度类型的标识：取第一个空格前的词（如「下载」「解压」）
    NSString *kind = [[line componentsSeparatedByString:@" "] firstObject] ?: line;

    NSString *formatted = [self timestamped:line];

    if (_lastProgressKind && [_lastProgressKind isEqualToString:kind] &&
        _lastProgressIndex < _mutableLines.count) {
        // 就地替换同一类进度的上一行
        _mutableLines[_lastProgressIndex] = formatted;
        [self notifyLinesChanged];
        return;
    }

    // 新类型的进度 —— 追加并记录位置
    [self appendRaw:formatted];
    _lastProgressKind = kind;
    _lastProgressIndex = _mutableLines.count - 1;
}

- (void)appendRaw:(NSString *)line {
    [_mutableLines addObject:line];

    // 超上限时丢最旧的 —— 用户看的是最新的几行
    while ((NSInteger)_mutableLines.count > _maxLines) {
        [_mutableLines removeObjectAtIndex:0];
    }

    [self notifyLinesChanged];
}

/// 加时间戳前缀，与 ZL2 的日志格式一致
- (NSString *)timestamped:(NSString *)line {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [NSString stringWithFormat:@"[%@] %@", [fmt stringFromDate:[NSDate date]], line];
}

- (void)notifyLinesChanged {
    NSArray<NSString *> *snapshot = self.lines;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onLinesChanged) self.onLinesChanged(snapshot);
        });
    } else {
        if (self.onLinesChanged) self.onLinesChanged(snapshot);
    }
}

@end
