//
//  A2CrashGuard.h
//  Air2
//
//  崩溃兜底 —— 把异常信息落盘，便于在没有 Xcode 的情况下定位问题。
//
//  为什么需要：这个环境里没有调试器，用户拿到的是直接闪退。
//  装上前先注册异常处理器，崩溃时把原因写到 Documents/air2_crash.log，
//  用户可以通过「文件」App 取出来，或者下次启动时自动显示。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2CrashGuard : NSObject

/// 注册异常与信号处理器。应在 main() 最早期调用。
+ (void)install;

/// 读取上一次崩溃日志，没有则返回 nil
+ (nullable NSString *)lastCrashLog;

/// 清除崩溃日志
+ (void)clearCrashLog;

/// 崩溃日志文件路径
+ (NSString *)crashLogPath;

@end

NS_ASSUME_NONNULL_END
