//
//  A2TaskFlowTypes.m
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
//  见头文件。这里只做枚举 → 字符串，方便日志里直接打印。
//

#import "A2TaskFlowTypes.h"

NSString *A2TaskStageName(A2TaskStage stage) {
    switch (stage) {
        case A2TaskStagePending:
            return @"PENDING";
        case A2TaskStageRunning:
            return @"RUNNING";
        case A2TaskStageSuccess:
            return @"SUCCESS";
        case A2TaskStageFailed:
            return @"FAILED";
        case A2TaskStageCancelled:
            return @"CANCELLED";
    }
    return [NSString stringWithFormat:@"UNKNOWN(%ld)", (long)stage];
}

NSString *A2TaskFlowStateName(A2TaskFlowState state) {
    switch (state) {
        case A2TaskFlowStateIdle:
            return @"IDLE";
        case A2TaskFlowStateRunning:
            return @"RUNNING";
        case A2TaskFlowStateSucceeded:
            return @"SUCCEEDED";
        case A2TaskFlowStateFailed:
            return @"FAILED";
        case A2TaskFlowStateCancelled:
            return @"CANCELLED";
    }
    return [NSString stringWithFormat:@"UNKNOWN(%ld)", (long)state];
}
