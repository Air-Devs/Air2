//
//  A2TaskFlowSnapshot.m
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
//  见头文件。纯值对象，没有可变状态，因此不需要加锁。
//

#import "A2TaskFlowSnapshot.h"

@implementation A2TaskFlowSnapshot

- (instancetype)initWithState:(A2TaskFlowState)state
          currentPhaseIndex:(NSInteger)currentPhaseIndex
                  phaseCount:(NSInteger)phaseCount
             totalTaskCount:(NSInteger)totalTaskCount
          completedTaskCount:(NSInteger)completedTaskCount
            currentTaskTitle:(NSString * _Nullable)currentTaskTitle
               totalProgress:(double)totalProgress {
    self = [super init];
    if (!self) return nil;

    _state = state;
    _currentPhaseIndex = currentPhaseIndex;
    _phaseCount = phaseCount;
    _totalTaskCount = totalTaskCount;
    _completedTaskCount = completedTaskCount;
    _currentTaskTitle = [currentTaskTitle copy];
    _totalProgress = totalProgress;
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:
            @"<A2TaskFlowSnapshot state=%@ phase=%ld/%ld tasks=%ld/%ld progress=%.3f title=%@>",
            A2TaskFlowStateName(self.state),
            (long)self.currentPhaseIndex,
            (long)self.phaseCount,
            (long)self.completedTaskCount,
            (long)self.totalTaskCount,
            self.totalProgress,
            self.currentTaskTitle ?: @"(none)"];
}

@end
