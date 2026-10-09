//
//  A2DownloadTask.h
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
//  下载任务记录 —— 任务中心对外的只读视图。
//
//  状态机只由 A2DownloadTaskCenter 推进（见内部头 A2DownloadTask+Internal.h），
//  这里只暴露读接口：UI 拿到可写状态就能绕过中心直接改，破坏「唯一入队/暂停/重试」约束。
//  状态枚举复用 A2DownloadEngine.h 的 A2DownloadState，不再另立一套（历史隐患）。
//

#import <Foundation/Foundation.h>
#import "A2DownloadEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2DownloadTask : NSObject

@property (nonatomic, copy, readonly) NSString *taskID;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly, nullable) NSString *subtitle;
@property (nonatomic, assign, readonly) A2DownloadState state;

/// 总字节数；未知为 0。
@property (nonatomic, assign, readonly) int64_t totalBytes;
/// 已下载字节数（引擎增量累加，回退换源时可能变小）。
@property (nonatomic, assign, readonly) int64_t downloadedBytes;
/// 进度 0.0~1.0；totalBytes 未知时为 0。
@property (nonatomic, assign, readonly) double progress;
/// 实时速度（bytes/s）。
@property (nonatomic, assign, readonly) double speed;
@property (nonatomic, copy, readonly, nullable) NSString *errorMessage;
@property (nonatomic, strong, readonly) NSDate *createdAt;

/// 速度展示文本，形如 "1.2 MB/s"；速度为 0 时返回 nil。
- (nullable NSString *)speedText;

/// 是否处于活跃态（Running / Paused）—— 用于任务分组与排序。
- (BOOL)isActive;

@end

NS_ASSUME_NONNULL_END
