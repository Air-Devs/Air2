//
//  A2TaskContext.h
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
//  传给单个任务的执行上下文。
//
//  对应 ZL2 TaskFlowExecutor.kt 里传给 task.task(...) 的 CoroutineScope：
//    · -isCancelled  ≈ Job.ensureActive() 的检查点。ZL2 靠协程在挂起点自动
//      抛 CancellationException；iOS 没有挂起点，任务必须在耗时循环里主动
//      轮询，发现 YES 就尽快 return（见 A2Task.h 的执行契约）。
//    · -log:         ≈ ZL2 的 Logger，统一带 taskflow 前缀。
//    · -updateProgress:detail: —— ZL2 的任务通过 StateFlow 直接更新 UI；
//      iOS 这里由上下文转交给执行器，执行器再加锁、节流并切主线程。
//
//  线程模型：所有公开方法都可以从任意线程调用（内部 NSLock 保护）。
//  但 updateProgress 会同步回调执行器注入的 block，而该 block 只做加锁
//  和一次可能的主线程 dispatch，不会阻塞任务线程。
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class A2Task;

@interface A2TaskContext : NSObject

/// 任务应周期性调用。返回 YES 后任务应尽快把 stage 置为 Cancelled 并返回。
- (BOOL)isCancelled;

/// 请求取消。仅供 A2TaskFlowExecutor 调用；任务实现只读，不要自己调。
- (void)requestCancel;

/// 写日志，自动带 "taskflow:" 前缀。format 与 printf 规则一致。
- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

/// 上报当前任务进度并刷新 detail。
/// progress 越界会被夹到 0.0 ~ 1.0；detail 传 nil 表示保持原 detail 不变。
///
/// 为什么不能直接改 task.progress：执行器只在任务开始/结束和这个入口
/// 感知进度，直接改属性 UI 不会收到实时回调。
- (void)updateProgress:(double)progress detail:(nullable NSString *)detail;

#pragma mark - 执行器内部使用（业务任务不要直接碰）

/// 当前正在执行的任务。weak —— 任务归 phase 持有，上下文不延长其生命周期，
/// 因此不会出现 context → task → context 的循环引用。
@property (nonatomic, weak, nullable) A2Task *currentTask;

/// 进度通知回调，由执行器在启动前注入。
/// 回调运行在调用 -updateProgress:detail: 的那个线程（通常是执行队列），
/// 执行器内部会自行加锁并切主线程，任务侧无需关心。
@property (nonatomic, copy, nullable) void (^progressHandler)(double progress, NSString * _Nullable detail);

@end

NS_ASSUME_NONNULL_END
