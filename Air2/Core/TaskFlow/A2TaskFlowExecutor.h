//
//  A2TaskFlowExecutor.h
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
//  多阶段串行任务流执行器。
//
//  对应 ZL2 coroutine/TaskFlowExecutor.kt：
//    · addPhase / addPhases      → -addPhase: / -addPhases:
//    · executePhasesAsync        → -startWithCompletion: / -start
//    · cancel                    → -cancel
//    · TaskPhase.onComplete      → A2TaskPhase.onComplete
//    · tasksFlow（StateFlow）    → -snapshot + changeHandler（主线程回调）
//
//  线程模型（iOS 用 GCD 替代协程）：
//    · 所有阶段/任务在内部私有串行队列上执行，等价于 ZL2 的 Dispatchers.IO；
//    · changeHandler 与 completion 一律 dispatch 到主队列，
//      等价于 withContext(Dispatchers.Main)；
//    · -snapshot / -addPhase: / -cancel 从任意线程调用都安全（NSLock）；
//    · 取消不是抢占式的。ZL2 靠 Job.cancel() 中断协程；iOS 没有可中断的
//      执行点，只能置标记，由任务自己轮询 context.isCancelled 后返回。
//      因此任务实现必须配合（见 A2Task.h 的执行契约），否则取消会失败。
//
//  生命周期：
//    · start 会把所有任务的 stage 重置为 PENDING、progress 归零、
//      detail 清空，所以同一个执行器可以重跑同一批阶段；
//    · 运行中调用 -addPhase: / -removeAllPhases 会被忽略（避免任务总数变化）；
//    · 启动后执行队列会持有执行器直到任务流结束，调用方不必担心提前释放。
//

#pragma once

#import <Foundation/Foundation.h>

#import "A2TaskFlowTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class A2TaskPhase;
@class A2TaskFlowSnapshot;

/// 任务流结束原因。
typedef NS_ENUM(NSInteger, A2TaskFlowResult) {
    A2TaskFlowResultSucceeded = 0,  ///< 全部阶段成功
    A2TaskFlowResultFailed = 1,     ///< 某个任务失败
    A2TaskFlowResultCancelled = 2,  ///< 被取消
};

FOUNDATION_EXPORT NSString *const A2TaskFlowErrorDomain;

typedef NS_ENUM(NSInteger, A2TaskFlowErrorCode) {
    A2TaskFlowErrorTaskFailed = 1,  ///< 任务把 stage 置为 FAILED
};

/// 进度/状态变化回调。始终在主线程执行。
/// snapshot 是该时刻的只读快照；handler 里若捕获执行器请用 weak。
typedef void (^A2TaskFlowChangeHandler)(A2TaskFlowSnapshot *snapshot);

/// 结束回调。result 区分成功/失败/取消；error 仅在 Failed 时非空（可能为 nil，
/// 取决于失败原因是否可组装）。始终在主线程执行。
typedef void (^A2TaskFlowCompletionHandler)(A2TaskFlowResult result, NSError * _Nullable error);

@interface A2TaskFlowExecutor : NSObject

/// 进度/状态变化回调，可为 nil。设置它会替换旧值；可从任意线程设置。
@property (nonatomic, copy, nullable) A2TaskFlowChangeHandler changeHandler;

/// 追加一个阶段（运行中忽略）。nil 会被忽略。
- (void)addPhase:(A2TaskPhase *)phase;
/// 批量追加阶段（运行中忽略）。nil 元素会被忽略。
- (void)addPhases:(NSArray<A2TaskPhase *> *)phases;
/// 清空所有阶段（运行中忽略），状态回到 IDLE。
- (void)removeAllPhases;

/// 启动任务流。已在运行则返回 NO 且不触发任何回调。
/// 阶段为空时按 ZL2 行为立即以 SUCCEEDED 结束（异步回调）。
/// completion 只在本次运行结束时回调一次，结束后释放。
- (BOOL)startWithCompletion:(nullable A2TaskFlowCompletionHandler)completion;
/// 等价于 -startWithCompletion:nil。
- (BOOL)start;

/// 请求取消。不阻塞、不等待当前任务返回。
/// 当前任务返回后，执行器把它标记为 CANCELLED，并以 Cancelled 结果回调；
/// 未开始的任务保持 PENDING。可重复调用。
- (void)cancel;

/// 是否正在执行。
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// 只读瞬态快照，任意线程可调用，不会阻塞执行队列。
- (A2TaskFlowSnapshot *)snapshot;

@end

NS_ASSUME_NONNULL_END
