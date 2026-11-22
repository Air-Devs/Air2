//
//  A2TaskContext.m
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
//  见头文件。关键点：
//    · 取消标志用 NSLock 保护，而不是 dispatch_sync 到执行队列 ——
//      执行队列是串行的，任务正在里面跑，同步过去会自己等自己，死锁。
//    · updateProgress 先写任务属性再回调，保证执行器取快照时任务本身
//      已经是新值（执行器另有自己的聚合进度，两者不冲突）。
//

#import "A2TaskContext.h"
#import "A2Task.h"
#import "A2Log.h"

#import <stdarg.h>

@interface A2TaskContext () {
    NSLock *_lock;
    BOOL _cancelled;
}

@end

@implementation A2TaskContext

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _lock = [[NSLock alloc] init];
    _cancelled = NO;
    return self;
}

#pragma mark - 取消

- (BOOL)isCancelled {
    [_lock lock];
    BOOL cancelled = _cancelled;
    [_lock unlock];
    return cancelled;
}

- (void)requestCancel {
    [_lock lock];
    _cancelled = YES;
    [_lock unlock];
}

#pragma mark - 日志

- (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    [A2Log log:@"taskflow: %@", message];
}

#pragma mark - 进度

- (void)updateProgress:(double)progress detail:(NSString * _Nullable)detail {
    if (progress < 0.0) progress = 0.0;
    if (progress > 1.0) progress = 1.0;

    // 先更新任务自身，保证任务对象的状态与上报值一致。
    A2Task *task = self.currentTask;
    if (task) {
        task.progress = progress;
        if (detail) {
            task.detail = detail;
        }
    }

    // 再通知执行器；handler 内部只做加锁/派发，不会回调任务。
    void (^handler)(double, NSString * _Nullable) = self.progressHandler;
    if (handler) {
        handler(progress, detail);
    }
}

@end
