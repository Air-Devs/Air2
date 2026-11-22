//
//  A2TaskFlowSnapshot.h
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
//  执行器状态的不可变快照，供 UI 观察。
//
//  ZL2 用 StateFlow<List<TitledTask>> 让 Compose 直接订阅任务列表；
//  iOS 侧没有 Compose 的自动重绘，所以这里退一步：执行器在每个关键点
//  生成一份值快照并回主线程，UI 只读这份快照即可，不需要持有执行器、
//  也不需要自己加锁。
//
//  快照字段是「某一瞬间」的拷贝；连续两次 -snapshot 的结果可能不同。
//

#pragma once

#import <Foundation/Foundation.h>

#import "A2TaskFlowTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2TaskFlowSnapshot : NSObject

/// 任务流状态。
@property (nonatomic, readonly) A2TaskFlowState state;

/// 当前阶段索引（0 起）；尚未启动时为 -1。
/// 失败/取消时保留在出错的那个阶段，方便 UI 展示「卡在哪一步」。
@property (nonatomic, readonly) NSInteger currentPhaseIndex;

/// 已登记的阶段总数。
@property (nonatomic, readonly) NSInteger phaseCount;

/// 所有阶段的任务总数（含尚未执行的）。
@property (nonatomic, readonly) NSInteger totalTaskCount;

/// 已成功完成的任务数（失败/取消的任务不计入）。
@property (nonatomic, readonly) NSInteger completedTaskCount;

/// 正在执行的任务标题；没有任务在跑时为 nil。
@property (nonatomic, copy, readonly, nullable) NSString *currentTaskTitle;

/// 总进度 0.0 ~ 1.0。
/// 计算方式：按任务等权，(已完成数 + 当前任务进度) / 任务总数。
/// 空任务流在成功时为 1.0，其余情况为 0.0。
/// 失败/取消时保留当时的部分进度，便于 UI 显示「完成了多少」。
@property (nonatomic, readonly) double totalProgress;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// 仅供 A2TaskFlowExecutor 构造。外部拿到快照后只读。
- (instancetype)initWithState:(A2TaskFlowState)state
          currentPhaseIndex:(NSInteger)currentPhaseIndex
                  phaseCount:(NSInteger)phaseCount
             totalTaskCount:(NSInteger)totalTaskCount
          completedTaskCount:(NSInteger)completedTaskCount
            currentTaskTitle:(nullable NSString *)currentTaskTitle
               totalProgress:(double)totalProgress NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
