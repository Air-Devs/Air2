//
//  A2SharedSession.m
//  Air2
//

#import "A2SharedSession.h"
#import "A2Logger.h"

static NSURLSession *sSession = nil;
static NSURLSessionConfiguration *sConfig = nil;
static NSInteger sMaxPerHost = 8;
static NSLock *sLock = nil;

@implementation A2SharedSession

+ (void)initialize {
    if (self == [A2SharedSession class]) {
        sLock = [[NSLock alloc] init];
    }
}

+ (NSURLSessionConfiguration *)configuration {
    [sLock lock];
    if (!sConfig) {
        sConfig = [NSURLSessionConfiguration defaultSessionConfiguration];

        // 单请求 60s / 整体 1 小时（大文件允许长时间下载）
        sConfig.timeoutIntervalForRequest = 60;
        sConfig.timeoutIntervalForResource = 3600;

        // 单 host 连接上限 —— 见头文件说明。
        // iOS 默认就是 8，这里显式写出来是为了让读者知道它存在。
        sConfig.HTTPMaximumConnectionsPerHost = sMaxPerHost;

        // 允许大量并发请求排队（不是连接数，是「同时存在的任务数」）
        sConfig.HTTPShouldUsePipelining = NO;   // HTTP/2 下无意义
        sConfig.URLCache = nil;                 // 下载不需要缓存
        sConfig.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    }
    [sLock unlock];
    return sConfig;
}

+ (NSURLSession *)shared {
    [sLock lock];
    if (!sSession) {
        NSURLSessionConfiguration *cfg = [self configuration];
        sSession = [NSURLSession sessionWithConfiguration:cfg];
        [A2Logger info:@"SharedSession"
               message:[NSString stringWithFormat:
                        @"创建共享 session（单 host 上限 %ld 条连接）",
                        (long)cfg.HTTPMaximumConnectionsPerHost]];
    }
    [sLock unlock];
    return sSession;
}

+ (void)setMaxConnectionsPerHost:(NSInteger)count {
    count = MAX(2, MIN(64, count));

    [sLock lock];
    sMaxPerHost = count;
    if (sConfig) {
        sConfig.HTTPMaximumConnectionsPerHost = count;
    }
    // 配置变了要重建 session（已有的 session 不能改配置）
    if (sSession) {
        [sSession invalidateAndCancel];
        sSession = nil;
    }
    [sLock unlock];

    [A2Logger info:@"SharedSession"
           message:[NSString stringWithFormat:@"单 host 上限改为 %ld，session 已重建", (long)count]];
}

+ (NSInteger)maxConnectionsPerHost {
    [sLock lock];
    NSInteger v = sMaxPerHost;
    [sLock unlock];
    return v;
}

@end
