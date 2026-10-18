//
//  AmePerfProbe.h
//  ★ [PERF] 低开销滚动帧率探针（默认关闭）
//
//  目的：用日志回答「滚动期间到底还有没有超过一帧预算（16.7ms @60Hz）的卡顿帧」。
//
//  ★ 判据（单一口径，写在 AmePerfProbe.m 里，改那里即改口径）：
//    · 帧间隔 > 16.7ms  ⇒ 记一次 jank   （已经掉到 60fps 以下，丢了一帧）
//    · 帧间隔 > 33.4ms  ⇒ 记一次 severe （已经掉到 30fps 以下）
//    · 单帧 > 500ms     ⇒ 视作会话断档，不计入统计
//    · 一次滚动会话结束时打印一行：
//        [PERF][scroll] tag=<页面> frames=N avg=?ms p95=?ms max=?ms
//                       jank(>16.7ms)=n(P%) severe(>33.4ms)=m ⇒ 判定:流畅/有卡顿
//      判「流畅」的条件：severe == 0 且 jank 占比 < 1%。
//    · 若 severe > 0，再补一行打印最重的几帧耗时，便于定位。
//
//  ★ 开销：不滚动时探针【完全不运行】—— 没有 CADisplayLink、没有定时器、没有轮询。
//    滚动时每帧只做十几次浮点比较 + 一次静态数组写入；不分配对象、不加锁、不拼字符串
//    （字符串只在会话结束那一次拼）。因此探针本身不会制造卡顿。
//
//  ★ 开启方式（任一，默认关）：
//    1) 环境变量   AME_PERF_PROBE=1
//    2) 偏好键     debug.perf_probe = YES   （setPrefObject(@"debug.perf_probe", @YES)）
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AmePerfProbe : NSObject

/// 探针是否启用（环境变量 AME_PERF_PROBE=1 或偏好键 debug.perf_probe=YES）。结果只解析一次并缓存。
+ (BOOL)isEnabled;

/// 在滚动回调里调用（每个 scrollViewDidScroll 调一次即可）。
/// 首次调用开启 CADisplayLink，之后约 0.25s 无滚动活动即自动结束并输出一次统计。
/// 未启用时本方法立即返回（一次静态 BOOL 判断）。
/// tag 用于区分页面（如 @"VersionManager" / @"ProfileSettings"）；同一会话只记第一个 tag。
+ (void)noteScrollActivity:(NSString *)tag;

@end

NS_ASSUME_NONNULL_END
