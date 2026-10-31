//
//  A2DownloadSpeedMeter.h
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
//  滑动平均测速 —— 展示层专用。
//
//  为什么不在引擎里算：引擎每秒上报一次「这一秒的真实吞吐」，那是块状采样。
//  直接画到界面上，数字每秒跳一格，网络抖一下更明显（用户看到的是「速度乱跳」）。
//  这里对最近若干秒的采样做滑动平均，只决定「看起来稳不稳」，
//  不参与任何下载决策 —— 引擎与任务中心的逻辑一行不改。
//
//  时间戳由调用方传入（一般取 CACurrentMediaTime()），本类不读时钟：
//  这样单元测试可以喂任意时间轴，也不受系统时间被改动的影响。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2DownloadSpeedMeter : NSObject

/// 窗口时长（秒），默认 3 秒。窗口越短越跟手，越长越稳。
- (instancetype)initWithWindow:(NSTimeInterval)window NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

/// 记录一次速度采样（bytes/s），返回当前平滑速度。
///
/// 与上一次采样间隔小于 0.2 秒时视为「同一次采样的重复上报」——
/// 任务中心按 100ms 节流广播，同一个引擎采样会被推多次；
/// 这种重复只覆盖最新值、不追加，否则平均值会被重复值带偏。
- (double)addSample:(double)bytesPerSecond at:(NSTimeInterval)timestamp;

/// 当前平滑速度（bytes/s）。
/// 窗口内没有采样，或最近一次采样已超出「窗口 + 1 秒」（暂停 / 已结束），返回 0。
- (double)smoothedSpeedAt:(NSTimeInterval)timestamp;

- (void)reset;

@end

NS_ASSUME_NONNULL_END
