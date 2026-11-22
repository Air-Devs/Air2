//
//  A2Task.m
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
//  见头文件。stage/progress/detail 都加了锁：
//  任务在后台线程写、UI 在主线程读是常态，这三个字段又必须成组保持一致，
//  用 atomic 属性不够（atomic 只保证单个访问，不保证 progress 与 stage
//  的先后关系），所以这里显式用 NSLock。
//

#import "A2Task.h"
#import "A2TaskContext.h"

@interface A2Task () {
    NSLock *_stateLock;
    A2TaskStage _stage;
    double _progress;
    NSString *_detail;
}

@end

@implementation A2Task

- (instancetype)initWithTitle:(NSString *)title {
    self = [super init];
    if (!self) return nil;

    _title = [title copy] ?: @"";
    _stateLock = [[NSLock alloc] init];
    _stage = A2TaskStagePending;
    _progress = 0.0;
    return self;
}

+ (instancetype)taskWithTitle:(NSString *)title {
    return [[self alloc] initWithTitle:title];
}

+ (instancetype)taskWithTitle:(NSString *)title action:(A2TaskAction _Nullable)action {
    A2Task *task = [[self alloc] initWithTitle:title];
    task.action = action;
    return task;
}

#pragma mark - 状态

- (A2TaskStage)stage {
    [_stateLock lock];
    A2TaskStage stage = _stage;
    [_stateLock unlock];
    return stage;
}

- (void)setStage:(A2TaskStage)stage {
    [_stateLock lock];
    _stage = stage;
    [_stateLock unlock];
}

- (double)progress {
    [_stateLock lock];
    double progress = _progress;
    [_stateLock unlock];
    return progress;
}

- (void)setProgress:(double)progress {
    if (progress < 0.0) progress = 0.0;
    if (progress > 1.0) progress = 1.0;

    [_stateLock lock];
    _progress = progress;
    [_stateLock unlock];
}

- (NSString * _Nullable)detail {
    [_stateLock lock];
    NSString *detail = _detail;
    [_stateLock unlock];
    return detail;
}

- (void)setDetail:(NSString * _Nullable)detail {
    [_stateLock lock];
    _detail = [detail copy];
    [_stateLock unlock];
}

#pragma mark - 执行

- (void)runWithContext:(A2TaskContext *)context {
    // 基类默认行为：有 block 执行体就调用，没有则当作空任务（直接成功）。
    // 子类重写本方法后，action 一般保持 nil。
    A2TaskAction action = self.action;
    if (action) {
        action(self, context);
    }
}

@end
