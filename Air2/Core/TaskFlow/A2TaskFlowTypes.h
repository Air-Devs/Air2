//
//  A2TaskFlowTypes.h
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
//  TaskFlow 的公共类型。
//
//  与 ZL2 coroutine/TaskFlowExecutor.kt、TitledTask.kt 的对应关系：
//    · A2TaskStage  —— 对应 ZL2 的 TaskStage。
//      但 ZL2 只有 Pending/Running/Completed，因为 Kotlin 协程的取消走
//      CancellationException，不会把任务留在 Completed。iOS 没有协程取消点，
//      任务只能靠轮询 isCancelled 主动返回，所以必须把「成功结束」和
//      「被取消」拆成两个终态，否则 UI 无法区分「完成」与「用户取消」。
//    · A2TaskFlowState —— 整个任务流的状态，供快照与 UI 使用。
//
//  这些类型单独放在叶子头文件里，避免 A2Task / A2TaskPhase /
//  A2TaskFlowSnapshot 之间互相 import 形成环。
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 单个任务的生命周期。
typedef NS_ENUM(NSInteger, A2TaskStage) {
    A2TaskStagePending = 0,     ///< 未开始
    A2TaskStageRunning = 1,     ///< 执行中
    A2TaskStageSuccess = 2,     ///< 正常结束
    A2TaskStageFailed = 3,      ///< 失败（detail 里写原因）
    A2TaskStageCancelled = 4,   ///< 被取消（任务主动返回，或被上下文取消）
};

/// 整个任务流的状态。
typedef NS_ENUM(NSInteger, A2TaskFlowState) {
    A2TaskFlowStateIdle = 0,        ///< 未启动 / 已复位
    A2TaskFlowStateRunning = 1,     ///< 执行中
    A2TaskFlowStateSucceeded = 2,   ///< 全部阶段成功
    A2TaskFlowStateFailed = 3,      ///< 某个任务失败，后续任务未执行
    A2TaskFlowStateCancelled = 4,   ///< 被取消
};

/// 枚举转字符串，仅用于日志/调试（不参与本地化）。
FOUNDATION_EXPORT NSString *A2TaskStageName(A2TaskStage stage);
FOUNDATION_EXPORT NSString *A2TaskFlowStateName(A2TaskFlowState state);

NS_ASSUME_NONNULL_END
