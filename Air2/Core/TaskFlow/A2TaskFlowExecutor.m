//
//  A2TaskFlowExecutor.m
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
//  见头文件。实现要点：
//    · 用 NSLock 保护可变状态，不用 dispatch_sync 到执行队列 ——
//      任务本身就跑在串行队列上，同步过去会自己等自己。
//    · 进度回调可能来自任意线程（任务自己的定时器/网络回调），
//      所以 handleTaskProgress: 只加锁改聚合值，然后按 100ms 节流回主线程。
//    · 结束只允许一次：finishWithResult:error: 用 _running 做幂等，
//      避免「任务失败」和「取消」两条路径同时回调 completion。
//    · 取 completion 时在锁内把引用搬到局部变量并清空，主线程回调期间
//      不再持有 _completionHandler，避免调用方在 completion 里重入 start。
//

#import "A2TaskFlowExecutor.h"
#import "A2TaskFlowSnapshot.h"
#import "A2TaskPhase.h"
#import "A2Task.h"
#import "A2TaskContext.h"
#import "A2Log.h"

#import <dispatch/dispatch.h>

/// 进度回调节流：任务可能每读一个数据块就上报一次，逐包切主线程会拖垮 UI。
/// 与 A2DownloadTaskCenter 的 100ms 保持一致。
static const NSTimeInterval kA2TaskFlowProgressThrottle = 0.1;

NSString *const A2TaskFlowErrorDomain = @"A2TaskFlowErrorDomain";

@interface A2TaskFlowExecutor () {
    NSLock *_lock;
    dispatch_queue_t _executionQueue;

    NSMutableArray<A2TaskPhase *> *_phases;

    BOOL _running;
    A2TaskFlowState _state;
    NSInteger _currentPhaseIndex;
    NSInteger _totalTaskCount;
    NSInteger _completedTaskCount;
    NSString *_currentTaskTitle;
    double _currentTaskProgress;
    NSTimeInterval _lastProgressNotifyTime;

    A2TaskContext *_context;
    A2TaskFlowCompletionHandler _completionHandler;
    A2TaskFlowChangeHandler _changeHandler;
}

- (void)executePhases;
- (A2TaskPhase * _Nullable)advanceToNextPhase;
- (void)beginTask:(A2Task *)task withContext:(A2TaskContext *)context;
- (void)completeTask:(A2Task *)task;
- (void)clearCurrentTask;
- (void)finishWithResult:(A2TaskFlowResult)result error:(NSError * _Nullable)error;
- (void)handleTaskProgress:(double)progress;
- (void)notifyChange;
- (NSInteger)phaseIndexValue;
- (NSError *)errorForTask:(A2Task *)task;

@end

@implementation A2TaskFlowExecutor

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _lock = [[NSLock alloc] init];
    _executionQueue = dispatch_queue_create("dev.airdevs.air2.task-flow", DISPATCH_QUEUE_SERIAL);
    _phases = [NSMutableArray array];
    _state = A2TaskFlowStateIdle;
    _currentPhaseIndex = -1;
    return self;
}

#pragma mark - 阶段配置

- (void)addPhase:(A2TaskPhase *)phase {
    if (!phase) return;

    [_lock lock];
    if (_running) {
        [_lock unlock];
        [A2Log log:@"taskflow: 运行中忽略 addPhase（阶段 \"%@\"）", phase.title ?: @""];
        return;
    }
    [_phases addObject:phase];
    _totalTaskCount += (NSInteger)phase.taskCount;
    [_lock unlock];
}

- (void)addPhases:(NSArray<A2TaskPhase *> *)phases {
    if (!phases) return;

    [_lock lock];
    if (_running) {
        [_lock unlock];
        [A2Log log:@"taskflow: 运行中忽略 addPhases"];
        return;
    }
    for (A2TaskPhase *phase in phases) {
        if (![phase isKindOfClass:[A2TaskPhase class]]) continue;
        [_phases addObject:phase];
        _totalTaskCount += (NSInteger)phase.taskCount;
    }
    [_lock unlock];
}

- (void)removeAllPhases {
    [_lock lock];
    if (_running) {
        [_lock unlock];
        [A2Log log:@"taskflow: 运行中忽略 removeAllPhases"];
        return;
    }
    [_phases removeAllObjects];
    _totalTaskCount = 0;
    _completedTaskCount = 0;
    _currentTaskTitle = nil;
    _currentTaskProgress = 0.0;
    _currentPhaseIndex = -1;
    _state = A2TaskFlowStateIdle;
    [_lock unlock];

    [self notifyChange];
}

#pragma mark - 启动 / 取消

- (BOOL)start {
    return [self startWithCompletion:nil];
}

- (BOOL)startWithCompletion:(A2TaskFlowCompletionHandler _Nullable)completion {
    A2TaskContext *context = nil;
    NSInteger phaseCount = 0;
    NSInteger totalTaskCount = 0;

    [_lock lock];
    if (_running) {
        [_lock unlock];
        return NO;
    }

    _running = YES;
    _state = A2TaskFlowStateRunning;
    _currentPhaseIndex = -1;
    _completedTaskCount = 0;
    _currentTaskTitle = nil;
    _currentTaskProgress = 0.0;
    _lastProgressNotifyTime = 0.0;
    _completionHandler = [completion copy];

    // 重跑同一批阶段时，把上一次留下的终态清掉，避免 UI 一开始就显示 100%。
    for (A2TaskPhase *phase in _phases) {
        for (A2Task *task in phase.tasks) {
            task.stage = A2TaskStagePending;
            task.progress = 0.0;
            task.detail = nil;
        }
    }

    phaseCount = (NSInteger)_phases.count;
    totalTaskCount = 0;
    for (A2TaskPhase *phase in _phases) {
        totalTaskCount += (NSInteger)phase.taskCount;
    }
    _totalTaskCount = totalTaskCount;

    context = [[A2TaskContext alloc] init];
    _context = context;
    [_lock unlock];

    // progressHandler 里只弱引用执行器：context 由执行器强持有，
    // 若 block 强持有执行器就会形成 context → block → executor → context 的环。
    __weak typeof(self) weakSelf = self;
    context.progressHandler = ^(double progress, NSString * _Nullable detail) {
        (void)detail; // 快照只汇总进度；detail 已经由 context 写进任务对象。
        [weakSelf handleTaskProgress:progress];
    };

    [A2Log log:@"taskflow: 启动 %ld 个阶段 / %ld 个任务", (long)phaseCount, (long)totalTaskCount];

    // 先让 UI 看到 RUNNING 初始态，再开始跑。
    [self notifyChange];

    // 这里强引用 self：任务流一旦启动，就应持有执行器直到结束，
    // 不能因为调用方释放了变量而让流程半路消失。
    dispatch_async(_executionQueue, ^{
        [self executePhases];
    });

    return YES;
}

- (void)cancel {
    A2TaskContext *context = nil;

    [_lock lock];
    if (_running) {
        context = _context;
    }
    [_lock unlock];

    if (!context) return;

    // 只置取消标记，不等待：任务要自己轮询 context.isCancelled 才能尽快退出。
    [context requestCancel];
    [A2Log log:@"taskflow: 收到取消请求"];
}

#pragma mark - 查询

- (BOOL)isRunning {
    [_lock lock];
    BOOL running = _running;
    [_lock unlock];
    return running;
}

- (A2TaskFlowChangeHandler)changeHandler {
    [_lock lock];
    A2TaskFlowChangeHandler handler = _changeHandler;
    [_lock unlock];
    return handler;
}

- (void)setChangeHandler:(A2TaskFlowChangeHandler)changeHandler {
    [_lock lock];
    _changeHandler = [changeHandler copy];
    [_lock unlock];
}

- (A2TaskFlowSnapshot *)snapshot {
    [_lock lock];
    A2TaskFlowState state = _state;
    NSInteger currentPhaseIndex = _currentPhaseIndex;
    NSInteger phaseCount = (NSInteger)_phases.count;
    NSInteger totalTaskCount = _totalTaskCount;
    NSInteger completedTaskCount = _completedTaskCount;
    if (state == A2TaskFlowStateIdle) {
        // 配置阶段时任务数会随 addTask 变化，IDLE 下按当前阶段重新数一遍。
        totalTaskCount = 0;
        for (A2TaskPhase *phase in _phases) {
            totalTaskCount += (NSInteger)phase.taskCount;
        }
    }
    NSString *currentTaskTitle = [_currentTaskTitle copy];
    double currentTaskProgress = _currentTaskProgress;
    [_lock unlock];

    double totalProgress = 0.0;
    if (totalTaskCount > 0) {
        totalProgress = ((double)completedTaskCount + currentTaskProgress) / (double)totalTaskCount;
    } else if (state == A2TaskFlowStateSucceeded) {
        // 空任务流也算「全部完成」。
        totalProgress = 1.0;
    }
    if (totalProgress < 0.0) totalProgress = 0.0;
    if (totalProgress > 1.0) totalProgress = 1.0;

    return [[A2TaskFlowSnapshot alloc] initWithState:state
                                   currentPhaseIndex:currentPhaseIndex
                                           phaseCount:phaseCount
                                      totalTaskCount:totalTaskCount
                                   completedTaskCount:completedTaskCount
                                     currentTaskTitle:currentTaskTitle
                                        totalProgress:totalProgress];
}

- (NSInteger)phaseIndexValue {
    [_lock lock];
    NSInteger index = _currentPhaseIndex;
    [_lock unlock];
    return index;
}

#pragma mark - 执行（私有串行队列）

- (void)executePhases {
    A2TaskContext *context = nil;

    [_lock lock];
    context = _context;
    [_lock unlock];

    if (!context) return;

    // 启动前就被取消（例如 start 之后立刻 cancel）。
    if ([context isCancelled]) {
        [self finishWithResult:A2TaskFlowResultCancelled error:nil];
        return;
    }

    while (YES) {
        if ([context isCancelled]) {
            [self finishWithResult:A2TaskFlowResultCancelled error:nil];
            return;
        }

        A2TaskPhase *phase = [self advanceToNextPhase];
        if (!phase) break;

        [A2Log log:@"taskflow: 阶段 %ld 开始 \"%@\"",
                    (long)[self phaseIndexValue], phase.title ?: @""];
        [self notifyChange];

        for (A2Task *task in phase.tasks) {
            if (!task) continue;

            if ([context isCancelled]) {
                [self finishWithResult:A2TaskFlowResultCancelled error:nil];
                return;
            }

            [self beginTask:task withContext:context];
            [task runWithContext:context];

            // 被取消：任务自己写了 CANCELLED，或上下文已取消。
            if ([context isCancelled] || task.stage == A2TaskStageCancelled) {
                if (task.stage != A2TaskStageCancelled) {
                    task.stage = A2TaskStageCancelled;
                }
                [self clearCurrentTask];
                [A2Log log:@"taskflow: 任务取消 \"%@\"", task.title];
                [self finishWithResult:A2TaskFlowResultCancelled error:nil];
                return;
            }

            // 失败：任务把 stage 置 FAILED，detail 里是原因。
            if (task.stage == A2TaskStageFailed) {
                NSError *error = [self errorForTask:task];
                [self clearCurrentTask];
                [A2Log log:@"taskflow: 任务失败 \"%@\" - %@",
                            task.title, task.detail ?: @"未知原因"];
                [self finishWithResult:A2TaskFlowResultFailed error:error];
                return;
            }

            // 正常返回且没有显式标记失败/取消 —— 视为成功。
            task.stage = A2TaskStageSuccess;
            [self completeTask:task];
        }

        // 阶段完成回调。按 ZL2 的语义在后台执行，不是主线程。
        void (^onComplete)(void) = phase.onComplete;
        if (onComplete) {
            onComplete();
        }

        [A2Log log:@"taskflow: 阶段 %ld 完成", (long)[self phaseIndexValue]];
        [self notifyChange];
    }

    // 最后一个任务刚结束、准备收尾时也可能收到取消请求。
    if ([context isCancelled]) {
        [self finishWithResult:A2TaskFlowResultCancelled error:nil];
        return;
    }

    [self finishWithResult:A2TaskFlowResultSucceeded error:nil];
}

- (A2TaskPhase * _Nullable)advanceToNextPhase {
    A2TaskPhase *phase = nil;

    [_lock lock];
    NSInteger next = _currentPhaseIndex + 1;
    if (next >= 0 && next < (NSInteger)_phases.count) {
        _currentPhaseIndex = next;
        phase = _phases[(NSUInteger)next];
    }
    [_lock unlock];

    return phase;
}

- (void)beginTask:(A2Task *)task withContext:(A2TaskContext *)context {
    task.stage = A2TaskStageRunning;
    if (task.progress >= 1.0) {
        task.progress = 0.0;
    }

    // 让 context.updateProgress: 直接作用到这个任务上。
    context.currentTask = task;

    [_lock lock];
    _currentTaskTitle = [task.title copy];
    _currentTaskProgress = task.progress;
    [_lock unlock];

    [A2Log log:@"taskflow: 任务开始 \"%@\"", task.title];
    [self notifyChange];
}

- (void)completeTask:(A2Task *)task {
    NSInteger completed = 0;
    NSInteger total = 0;

    [_lock lock];
    _completedTaskCount += 1;
    _currentTaskTitle = nil;
    _currentTaskProgress = 0.0;
    completed = _completedTaskCount;
    total = _totalTaskCount;
    [_lock unlock];

    [A2Log log:@"taskflow: 任务完成 \"%@\"（%ld/%ld）",
                task.title, (long)completed, (long)total];
    [self notifyChange];
}

- (void)clearCurrentTask {
    [_lock lock];
    _currentTaskTitle = nil;
    [_lock unlock];
}

- (void)finishWithResult:(A2TaskFlowResult)result error:(NSError * _Nullable)error {
    A2TaskFlowState finalState = A2TaskFlowStateIdle;

    switch (result) {
        case A2TaskFlowResultSucceeded:
            finalState = A2TaskFlowStateSucceeded;
            break;
        case A2TaskFlowResultFailed:
            finalState = A2TaskFlowStateFailed;
            break;
        case A2TaskFlowResultCancelled:
            finalState = A2TaskFlowStateCancelled;
            break;
    }

    A2TaskFlowCompletionHandler completion = nil;
    BOOL didFinish = NO;

    [_lock lock];
    if (_running) {
        _running = NO;
        _state = finalState;
        _currentTaskTitle = nil;
        _context = nil;
        completion = _completionHandler;
        _completionHandler = nil;
        didFinish = YES;
    }
    [_lock unlock];

    if (!didFinish) return;

    [A2Log log:@"taskflow: 结束 %@", A2TaskFlowStateName(finalState)];

    // 先发最终快照，再回调 completion —— 两者都走主队列，顺序有保证。
    [self notifyChange];

    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result, error);
        });
    }
}

#pragma mark - 进度

- (void)handleTaskProgress:(double)progress {
    if (progress < 0.0) progress = 0.0;
    if (progress > 1.0) progress = 1.0;

    BOOL shouldNotify = NO;

    [_lock lock];
    if (_running) {
        _currentTaskProgress = progress;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - _lastProgressNotifyTime >= kA2TaskFlowProgressThrottle) {
            _lastProgressNotifyTime = now;
            shouldNotify = YES;
        }
    }
    [_lock unlock];

    if (shouldNotify) {
        [self notifyChange];
    }
}

#pragma mark - 通知

- (void)notifyChange {
    A2TaskFlowChangeHandler handler = self.changeHandler;
    if (!handler) return;

    A2TaskFlowSnapshot *snapshot = [self snapshot];

    // 只捕获 handler 与快照，不捕获 self；主线程执行完即释放。
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(snapshot);
    });
}

#pragma mark - 错误

- (NSError *)errorForTask:(A2Task *)task {
    NSString *detail = task.detail;
    NSString *reason = detail.length > 0 ? detail : @"任务未提供失败原因";
    NSString *description = [NSString stringWithFormat:@"任务「%@」执行失败：%@", task.title, reason];

    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: description,
        NSLocalizedFailureReasonErrorKey: reason,
    };

    return [NSError errorWithDomain:A2TaskFlowErrorDomain
                               code:A2TaskFlowErrorTaskFailed
                           userInfo:userInfo];
}

@end
