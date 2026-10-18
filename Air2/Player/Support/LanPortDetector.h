//
//  LanPortDetector.h
//  Amethyst
//
//  Minecraft "对局域网开放"端口检测器（手动输入版）
//
//  说明：自动检测（解析 latestlog.txt 日志）已移除，因不同 MC 版本
//  日志格式差异大、且旧日志可能导致误检测。现仅保留手动输入端口 API。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 通知名称：当手动设置端口时发送
/// userInfo: @{ @"port": @(端口号) }
extern NSString *const LanPortDetectorDidDetectPortNotification;

/// Minecraft "对局域网开放"端口检测器（手动输入版）
@interface LanPortDetector : NSObject

/// 单例访问
+ (instancetype)sharedInstance;

/// 手动设置 MC LAN 端口
/// @param port MC 中"对局域网开放"后聊天框显示的端口号
- (void)setManualPort:(uint16_t)port;

@end

NS_ASSUME_NONNULL_END
