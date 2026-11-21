//
//  A2RateLimiter.h
//  Air2
//
//  全局限流闸门 —— 按 host 记录「服务端让我们等到什么时候」。
//
//  ## 为什么需要全局
//
//  服务端的限流是**按 IP / 按 host 算的**，不是按单个请求。
//  64 个并发下载同时打同一个 host，只要其中几个收到 429，
//  说明这个 host 现在在拒绝我们 —— 其他请求继续冲只会：
//    · 全部拿到 429（浪费时间）
//    · 让服务端的限流窗口延长
//
//  所以收到 429 时要把「这个 host 到什么时候才能再请求」记下来，
//  其他请求在发起前先查一次，没到时间就主动等。
//
//  ## 与退避的区别
//
//    · 单个请求的失败退避（1s/2s/4s）是「这个请求运气不好」
//    · 全局闸门是「这个 host 现在不欢迎我们」
//  两者要分开：前者按请求重试，后者按 host 排队。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2RateLimiter : NSObject

/// 记录某 host 被限流，需要等到什么时候
+ (void)noteRateLimited:(nullable NSString *)host until:(NSTimeInterval)seconds;

/// 查询某 host 还要等多久（0 = 可以立即请求）
+ (NSTimeInterval)remainingWaitForHost:(nullable NSString *)host;

/// 清空（测试或用户手动重试时用）
+ (void)reset;

@end

NS_ASSUME_NONNULL_END
