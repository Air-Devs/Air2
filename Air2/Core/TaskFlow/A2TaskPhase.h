//
//  A2TaskPhase.h
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
//  任务流中的一个阶段，持有一组按顺序串行执行的 A2Task。
//  对应 ZL2 TaskFlowExecutor.TaskPhase：
//      data class TaskPhase(val tasks: List<TitledTask>,
//                           val onComplete: (suspend () -> Unit)?)
//
//  与 ZL2 的差异：
//    · ZL2 的 onComplete 是 suspend 函数，运行在 Dispatchers.IO 的协程里；
//      这里的 onComplete 是普通 block，运行在执行器的后台串行队列上，
//      不是主线程。需要更新 UI 请自行 dispatch_get_main_queue()。
//    · tasks 只读，通过 -addTask:/-addTasks: 追加。执行器启动后不要再改。
//    · 阶段标题（title）是 iOS 侧新增的，ZL2 没有；只用于日志和调试，
//      不进入快照，避免 UI 文案与数据结构绑死。
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class A2Task;

@interface A2TaskPhase : NSObject

/// 阶段标题，可为 nil。仅用于日志/调试。
@property (nonatomic, copy, readonly, nullable) NSString *title;

/// 阶段内任务，按数组顺序执行。返回的是不可变拷贝。
@property (nonatomic, copy, readonly) NSArray<A2Task *> *tasks;

/// 阶段完成回调，可为 nil；在该阶段所有任务成功后被调用。
/// 运行在执行器后台队列，禁止阻塞，内部抛异常会中断整个任务流。
@property (nonatomic, copy, nullable) void (^onComplete)(void);

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)initWithTitle:(nullable NSString *)title NS_DESIGNATED_INITIALIZER;

+ (instancetype)phaseWithTitle:(nullable NSString *)title;
+ (instancetype)phaseWithTasks:(NSArray<A2Task *> *)tasks;
+ (instancetype)phaseWithTitle:(nullable NSString *)title tasks:(NSArray<A2Task *> *)tasks;

/// 追加一个任务。nil 会被忽略。
- (void)addTask:(nullable A2Task *)task;
/// 批量追加。nil 元素会被忽略。
- (void)addTasks:(nullable NSArray<A2Task *> *)tasks;

/// 任务数量。
- (NSUInteger)taskCount;

@end

NS_ASSUME_NONNULL_END
