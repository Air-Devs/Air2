//
//  A2Logger.h
//  Air2
//
//  日志系统 —— 对照 ZL2 的 utils/logging/Logger.kt。
//
//  ZL2 的设计要点（照搬）：
//    · 五级：ERROR / WARNING / INFO / DEBUG / TRACE
//    · 格式：[HH:mm:ss.SSS] [tag/LEVEL] message
//    · 文件名带时间戳：log_2026-10-11T09-30-00_main.log
//    · 异步写入（ZL2 用 Channel + 协程；iOS 用串行队列）
//    · 写盘失败降级到内存缓冲（1MB）
//    · 保留天数可配，初始化时清理旧日志
//    · 清理规则含「遗留的 0KB 空日志」（排除当前文件，且创建满 1 分钟）
//    · 支持打包整个日志目录（分享给开发者排查）
//
//  ⚠️ 与 ZL2 的差异：
//    ZL2 用 processName 区分进程（Android 多进程）。iOS 是单进程，
//    没有这个概念，但保留文件名的「进程标识」位以对齐格式。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2LogLevel) {
    A2LogLevelError = 0,
    A2LogLevelWarning,
    A2LogLevelInfo,
    A2LogLevelDebug,
    A2LogLevelTrace,
};

/// 日志等级的中文名（用于界面显示）
FOUNDATION_EXPORT NSString *A2LogLevelName(A2LogLevel level);

@interface A2Logger : NSObject

+ (instancetype)shared;

/// 初始化。App 启动时调用一次。
/// 会创建日志文件、打印启动器信息、清理过期日志。
- (void)initialize;

#pragma mark - 分级写入

+ (void)error:(NSString *)tag message:(NSString *)message;
+ (void)error:(NSString *)tag message:(NSString *)message error:(nullable NSError *)error;
+ (void)warning:(NSString *)tag message:(NSString *)message;
+ (void)info:(NSString *)tag message:(NSString *)message;
+ (void)debug:(NSString *)tag message:(NSString *)message;
+ (void)trace:(NSString *)tag message:(NSString *)message;

/// 通用入口。throwable 对应 ZL2 的 throwable 参数（这里用 NSError）。
+ (void)log:(A2LogLevel)level
        tag:(NSString *)tag
    message:(NSString *)message
      error:(nullable NSError *)error;

#pragma mark - 文件与打包

/// 当前日志文件路径（未初始化时为 nil）
@property (nonatomic, copy, readonly, nullable) NSString *currentLogFilePath;

/// 日志目录
@property (nonatomic, copy, readonly) NSString *logDirectory;

/// 打包整个日志目录到 zip，用于分享
- (void)packLogsToPath:(NSString *)zipPath
            completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// 日志保留天数（默认 7，写入时持久化）
@property (nonatomic, assign) NSInteger retentionDays;

@end

NS_ASSUME_NONNULL_END
