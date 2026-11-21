//
//  LanPortDetector.m
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
//  LanPortDetector.m
//  Amethyst
//
//  Minecraft "对局域网开放"端口检测器（手动输入版）实现
//

#import "LanPortDetector.h"

/// 通知名：手动设置端口时发送
NSString *const LanPortDetectorDidDetectPortNotification = @"LanPortDetectorDidDetectPort";

@interface LanPortDetector ()
/// 当前已设置的端口（0 表示未设置）
@property (nonatomic, assign, readwrite) uint16_t detectedPort;
@end

@implementation LanPortDetector

#pragma mark - 单例

+ (instancetype)sharedInstance {
    static LanPortDetector *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

#pragma mark - 手动设置端口

/// 手动设置 MC LAN 端口
- (void)setManualPort:(uint16_t)port {
    self.detectedPort = port;

    NSLog(@"[LanPortDetector] Manually set LAN port: %u", port);

    // 发送通知，userInfo 包含端口号
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:LanPortDetectorDidDetectPortNotification
                                                            object:self
                                                          userInfo:@{ @"port": @(port) }];
    });
}

@end
