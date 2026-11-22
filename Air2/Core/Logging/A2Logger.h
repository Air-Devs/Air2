//
//  A2Logger.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
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

/// 初始化。App 启动时调用一次 —— 现在由 +shared 自动调用，无需显式调用。
/// 会创建日志文件、打印启动器信息、清理过期日志。
- (void)initialize;

#pragma mark - 进程级输出接管

/// 把进程的 stdout / stderr 接到日志文件上。
///
/// 为什么需要：游戏启动链路上真正有诊断价值的东西大多走 C 的 printf/fprintf
/// 和 JVM 自己的输出流（egl_bridge / gl_bridge / main_hook / spvc_shim 的
/// fprintf(stderr, ...)、HotSpot 的致命错误、MC 的 System.out）—— 这些一行
/// 都不经过 A2Logger。iOS 上进程没有终端，stdout/stderr 默认进系统日志，
/// 换个构建就找不回来，于是「启动黑屏」永远只剩一句「没反应」。
///
/// 实现为 dup2 到同一个文件描述符：之后所有 C 层输出与 ObjC 日志落在同一份
/// 文件里，顺序由内核保证。可重复调用（幂等）。
/// 环境变量 A2_LOG_CAPTURE_STDIO=0 可关闭。
- (void)captureStandardIO;

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
