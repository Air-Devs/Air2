//
//  A2Task.h
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
//  任务流里的单个任务。对应 ZL2 TitledTask 里的 Task 本体
//  （TitledTask = title + icon + Task；iOS 侧没有 Android 资源图标，
//   title 直接存在任务上，图标留给 UI 按业务自行映射）。
//
//  执行契约（重要）：
//    1. 执行器在调用 -runWithContext: 前把 stage 置 RUNNING、progress 置 0。
//    2. -runWithContext: 正常返回，且任务没有把 stage 改成 FAILED / CANCELLED，
//       执行器就把它置 SUCCESS，并计入「已完成」。
//    3. 任务失败时自己写：
//           self.stage = A2TaskStageFailed;
//           self.detail = @"具体原因";
//       执行器会用 detail 组装 NSError，并终止后续任务。
//    4. 任务要支持取消，就在耗时循环里轮询 context.isCancelled；
//       发现 YES 后写 stage = CANCELLED（执行器也会兜底判断上下文，
//       即使任务没写也会被标成 CANCELLED）并尽快 return。
//    5. 进度请用 [context updateProgress:detail:] 上报；直接改
//       self.progress 只会改任务对象，不会触发 UI 回调。
//
//  线程模型：title 初始化后不可变；stage / progress / detail 由内部 NSLock
//  保护，可从任务线程写、从任意线程读。
//

#pragma once

#import <Foundation/Foundation.h>

#import "A2TaskFlowTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class A2Task;
@class A2TaskContext;

/// block 形式的任务体。task 是任务自身，context 用于取消检查/日志/进度。
typedef void (^A2TaskAction)(A2Task *task, A2TaskContext *context);

@interface A2Task : NSObject

/// 任务标题，初始化后不可变。UI 直接显示。
@property (nonatomic, copy, readonly) NSString *title;

/// 当前阶段，默认 PENDING。
@property (nonatomic, assign) A2TaskStage stage;

/// 0.0 ~ 1.0；setter 会把越界值夹紧。默认 0。
@property (nonatomic, assign) double progress;

/// 动态详情（如当前文件名、错误原因），可为 nil。
@property (nonatomic, copy, nullable) NSString *detail;

/// block 形式的执行体。子类通常不设置它，而是重写 -runWithContext:。
@property (nonatomic, copy, nullable) A2TaskAction action;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)initWithTitle:(NSString *)title NS_DESIGNATED_INITIALIZER;

+ (instancetype)taskWithTitle:(NSString *)title;
+ (instancetype)taskWithTitle:(NSString *)title action:(nullable A2TaskAction)action;

/// 子类重写。默认实现：有 action 就调用，没有就什么都不做（视为成功）。
/// 不要在执行体里阻塞主线程 —— 这个方法是执行器后台串行队列上调用的。
/// 返回后不要再调用 context 的上报方法：执行器可能已经切到下一个任务。
- (void)runWithContext:(A2TaskContext *)context;

@end

NS_ASSUME_NONNULL_END
