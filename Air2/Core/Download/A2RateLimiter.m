//
//  A2RateLimiter.m
//  Air2
//

#import "A2RateLimiter.h"
#import "A2Logger.h"

static NSMutableDictionary<NSString *, NSDate *> *sUntil = nil;
static NSLock *sLock = nil;

@implementation A2RateLimiter

+ (void)initialize {
    if (self == [A2RateLimiter class]) {
        sUntil = [NSMutableDictionary dictionary];
        sLock = [[NSLock alloc] init];
    }
}

+ (void)noteRateLimited:(NSString *)host until:(NSTimeInterval)seconds {
    if (host.length == 0) return;
    seconds = MAX(1.0, MIN(300.0, seconds));

    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];

    [sLock lock];
    // 取较晚的那个 —— 别的请求可能已经记了更长的等待
    NSDate *existing = sUntil[host];
    if (!existing || [until compare:existing] == NSOrderedDescending) {
        sUntil[host] = until;
    }
    [sLock unlock];

    [A2Logger warning:@"RateLimiter"
              message:[NSString stringWithFormat:@"%@ 被限流，等待 %.0fs", host, seconds]];
}

+ (NSTimeInterval)remainingWaitForHost:(NSString *)host {
    if (host.length == 0) return 0;

    [sLock lock];
    NSDate *until = sUntil[host];
    [sLock unlock];

    if (!until) return 0;
    NSTimeInterval left = [until timeIntervalSinceNow];
    return MAX(0, left);
}

+ (void)reset {
    [sLock lock];
    [sUntil removeAllObjects];
    [sLock unlock];
    [A2Logger info:@"RateLimiter" message:@"限流记录已清空"];
}

@end
