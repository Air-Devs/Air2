//
//  PLTaskStage.m
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
#import "PLTaskStage.h"

/// 快照取值辅助：仅接受非空 NSString，否则返回兜底值（快照内容不可信，需类型清洗）
static NSString *PLStageSnapshotString(id value, NSString *fallback) {
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        return value;
    }
    return fallback;
}

@implementation PLTaskStage

+ (instancetype)stageWithTitle:(NSString *)title iconName:(NSString *)iconName {
    return [[self alloc] initWithTitle:title iconName:iconName];
}

- (instancetype)initWithTitle:(NSString *)title iconName:(NSString *)iconName {
    self = [super init];
    if (self) {
        _title = [title copy] ?: @"";
        _iconName = [iconName copy] ?: @"";
        _status = PLTaskStageStatusPending;
        _message = nil;
        _progress = -1.0;
        _rateBytesPerSec = 0.0;
        _completedFileCount = 0;
        _totalFileCount = 0;
    }
    return self;
}

#pragma mark - 快照序列化

- (NSDictionary *)snapshotDictionary {
    return @{
        @"title": self.title ?: @"",
        @"iconName": self.iconName ?: @"",
        @"status": @(self.status),
        @"message": self.message ?: @"",
        @"progress": @(self.progress),
        @"rateBytesPerSec": @(self.rateBytesPerSec),
        @"completedFileCount": @(self.completedFileCount),
        @"totalFileCount": @(self.totalFileCount),
    };
}

- (instancetype)initWithSnapshotDictionary:(NSDictionary *)snapshot {
    if (![snapshot isKindOfClass:[NSDictionary class]]) return nil;

    self = [self initWithTitle:PLStageSnapshotString(snapshot[@"title"], @"")
                      iconName:PLStageSnapshotString(snapshot[@"iconName"], @"")];
    if (!self) return nil;

    // 状态枚举值做范围清洗（快照内容不可信，越界回退 Pending）
    NSInteger status = [snapshot[@"status"] integerValue];
    if (status < PLTaskStageStatusPending || status > PLTaskStageStatusSkipped) {
        status = PLTaskStageStatusPending;
    }
    _status = status;
    _message = PLStageSnapshotString(snapshot[@"message"], nil);
    _progress = [snapshot[@"progress"] doubleValue];
    _rateBytesPerSec = [snapshot[@"rateBytesPerSec"] doubleValue];
    _completedFileCount = [snapshot[@"completedFileCount"] integerValue];
    _totalFileCount = [snapshot[@"totalFileCount"] integerValue];
    return self;
}

@end
