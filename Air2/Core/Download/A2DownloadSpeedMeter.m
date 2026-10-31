//
//  A2DownloadSpeedMeter.m
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
//  滑动平均测速的实现。见头文件里的说明。
//

#import "A2DownloadSpeedMeter.h"
#import <math.h>

/// 两次采样的最小间隔：更近的视为同一个采样的重复上报（覆盖而非追加）。
static const NSTimeInterval A2SpeedMeterDuplicateInterval = 0.2;

/// 采样停摆后仍沿用最后一次值的宽限期（秒）。超出即认为「不转了」。
static const NSTimeInterval A2SpeedMeterIdleGrace = 1.0;

@interface A2DownloadSpeedMeter ()

@property (nonatomic, assign) NSTimeInterval windowSeconds;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *sampleTimes;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *sampleValues;

@end

@implementation A2DownloadSpeedMeter

- (instancetype)init {
    return [self initWithWindow:3.0];
}

- (instancetype)initWithWindow:(NSTimeInterval)window {
    self = [super init];
    if (!self) return nil;
    // 窗口至少留一秒：否则「平均」退化成瞬时值，正是要避免的东西。
    _windowSeconds = MAX(1.0, window);
    _sampleTimes = [NSMutableArray array];
    _sampleValues = [NSMutableArray array];
    return self;
}

- (double)addSample:(double)bytesPerSecond at:(NSTimeInterval)timestamp {
    // 非有限值 / 负值（引擎回退时会给 0）都只是「这一次没测到」，沿用既有窗口。
    if (!isfinite(bytesPerSecond) || bytesPerSecond < 0 || !isfinite(timestamp)) {
        return [self smoothedSpeedAt:timestamp];
    }

    [self dropSamplesOlderThan:timestamp - self.windowSeconds];

    NSNumber *lastTime = self.sampleTimes.lastObject;
    if (lastTime && timestamp - lastTime.doubleValue < A2SpeedMeterDuplicateInterval) {
        NSUInteger lastIndex = self.sampleTimes.count - 1;
        self.sampleTimes[lastIndex] = @(timestamp);
        self.sampleValues[lastIndex] = @(bytesPerSecond);
        return [self smoothedSpeedAt:timestamp];
    }

    [self.sampleTimes addObject:@(timestamp)];
    [self.sampleValues addObject:@(bytesPerSecond)];
    return [self smoothedSpeedAt:timestamp];
}

- (double)smoothedSpeedAt:(NSTimeInterval)timestamp {
    NSNumber *lastTime = self.sampleTimes.lastObject;
    if (!lastTime) return 0;

    // 采样停摆超过「窗口 + 宽限」⇒ 速度按 0 处理（暂停、已完成、失败都会走到这里）。
    if (timestamp - lastTime.doubleValue > self.windowSeconds + A2SpeedMeterIdleGrace) {
        return 0;
    }

    double cutoff = timestamp - self.windowSeconds;
    double sum = 0;
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < self.sampleTimes.count; i++) {
        if (self.sampleTimes[i].doubleValue < cutoff) continue;
        sum += self.sampleValues[i].doubleValue;
        count += 1;
    }
    if (count == 0) {
        // 窗口内一个都没有，但最近一次采样还在宽限期内：
        // 用最近一次的值，别让数字在两个采样之间闪成 0。
        return self.sampleValues.lastObject.doubleValue;
    }
    return sum / (double)count;
}

- (void)reset {
    [self.sampleTimes removeAllObjects];
    [self.sampleValues removeAllObjects];
}

#pragma mark - 内部

/// 丢掉严格早于 cutoff 的采样（保留边界上那条，使窗口内始终有足够历史）。
- (void)dropSamplesOlderThan:(NSTimeInterval)cutoff {
    while (self.sampleTimes.count > 1 && self.sampleTimes.firstObject.doubleValue < cutoff) {
        [self.sampleTimes removeObjectAtIndex:0];
        [self.sampleValues removeObjectAtIndex:0];
    }
}

@end
