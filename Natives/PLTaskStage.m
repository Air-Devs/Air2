#import "PLTaskStage.h"

/// 快照取值辅助：仅接受非空 NSString，否则返回兜底值（快照内容不可信，需类型清洗）
static NSString *PLStageSnapshotString(id value, NSString *fallback) {
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        return value;
    }
    return fallback;
}

@implementation PLTaskStage

+ (instancetype)stageWithTitle:(NSString *)title iconName:(NSString *)iconName {
    return [[self alloc] initWithTitle:title iconName:iconName];
}

- (instancetype)initWithTitle:(NSString *)title iconName:(NSString *)iconName {
    self = [super init];
    if (self) {
        _title = [title copy] ?: @"";
        _iconName = [iconName copy] ?: @"";
        _status = PLTaskStageStatusPending;
        _message = nil;
        _progress = -1.0;
        _rateBytesPerSec = 0.0;
        _completedFileCount = 0;
        _totalFileCount = 0;
    }
    return self;
}

#pragma mark - 快照序列化

- (NSDictionary *)snapshotDictionary {
    return @{
        @"title": self.title ?: @"",
        @"iconName": self.iconName ?: @"",
        @"status": @(self.status),
        @"message": self.message ?: @"",
        @"progress": @(self.progress),
        @"rateBytesPerSec": @(self.rateBytesPerSec),
        @"completedFileCount": @(self.completedFileCount),
        @"totalFileCount": @(self.totalFileCount),
    };
}

- (instancetype)initWithSnapshotDictionary:(NSDictionary *)snapshot {
    if (![snapshot isKindOfClass:[NSDictionary class]]) return nil;

    self = [self initWithTitle:PLStageSnapshotString(snapshot[@"title"], @"")
                      iconName:PLStageSnapshotString(snapshot[@"iconName"], @"")];
    if (!self) return nil;

    // 状态枚举值做范围清洗（快照内容不可信，越界回退 Pending）
    NSInteger status = [snapshot[@"status"] integerValue];
    if (status < PLTaskStageStatusPending || status > PLTaskStageStatusSkipped) {
        status = PLTaskStageStatusPending;
    }
    _status = status;
    _message = PLStageSnapshotString(snapshot[@"message"], nil);
    _progress = [snapshot[@"progress"] doubleValue];
    _rateBytesPerSec = [snapshot[@"rateBytesPerSec"] doubleValue];
    _completedFileCount = [snapshot[@"completedFileCount"] integerValue];
    _totalFileCount = [snapshot[@"totalFileCount"] integerValue];
    return self;
}

@end
