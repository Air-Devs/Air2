//
//  LanPortDetector.h
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
