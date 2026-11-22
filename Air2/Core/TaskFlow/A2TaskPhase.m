//
//  A2TaskPhase.m
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
//  见头文件。阶段只在启动前构建，运行期只读，
//  所以这里不给 tasks 加锁 —— 加锁反而会掩盖「运行中改阶段」的误用。
//  执行器会在启动时复制任务计数；运行中 addTask 不会生效。
//

#import "A2TaskPhase.h"
#import "A2Task.h"

@interface A2TaskPhase () {
    NSMutableArray<A2Task *> *_mutableTasks;
}

@end

@implementation A2TaskPhase

- (instancetype)initWithTitle:(NSString * _Nullable)title {
    self = [super init];
    if (!self) return nil;

    _title = [title copy];
    _mutableTasks = [NSMutableArray array];
    return self;
}

+ (instancetype)phaseWithTitle:(NSString * _Nullable)title {
    return [[self alloc] initWithTitle:title];
}

+ (instancetype)phaseWithTasks:(NSArray<A2Task *> *)tasks {
    A2TaskPhase *phase = [[self alloc] initWithTitle:nil];
    [phase addTasks:tasks];
    return phase;
}

+ (instancetype)phaseWithTitle:(NSString * _Nullable)title tasks:(NSArray<A2Task *> *)tasks {
    A2TaskPhase *phase = [[self alloc] initWithTitle:title];
    [phase addTasks:tasks];
    return phase;
}

#pragma mark - 任务集合

- (NSArray<A2Task *> *)tasks {
    return [_mutableTasks copy];
}

- (void)addTask:(A2Task * _Nullable)task {
    if (!task) return;
    [_mutableTasks addObject:task];
}

- (void)addTasks:(NSArray<A2Task *> * _Nullable)tasks {
    if (!tasks) return;
    for (A2Task *task in tasks) {
        if (task) {
            [_mutableTasks addObject:task];
        }
    }
}

- (NSUInteger)taskCount {
    return _mutableTasks.count;
}

@end
