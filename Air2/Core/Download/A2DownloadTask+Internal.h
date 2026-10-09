//
//  A2DownloadTask+Internal.h
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
//  下载任务的内部可变接口（类扩展）。
//
//  为什么不并入公开头：状态只能由 A2DownloadTaskCenter 推进。若把可变属性
//  暴露给 UI，调用方就能绕过中心直接改状态，中心维护的排序/清单/重试语义全会错乱。
//  故用类扩展单独给中心，UI 不引入本文件。
//

#import "A2DownloadTask.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2DownloadTask ()

@property (nonatomic, copy) NSString *taskID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, assign) A2DownloadState state;
@property (nonatomic, assign) int64_t totalBytes;
@property (nonatomic, assign) int64_t downloadedBytes;
@property (nonatomic, assign) double speed;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic, strong) NSDate *createdAt;

/// 引擎句柄，结束/取消后置空释放。
@property (nonatomic, strong, nullable) A2DownloadOperation *operation;
/// 原始请求，失败/取消后重试时复用。
@property (nonatomic, strong, nullable) A2DownloadRequest *request;
/// 成功回写已下载清单所需的元信息。
@property (nonatomic, copy, nullable) NSString *projectID;
@property (nonatomic, copy, nullable) NSString *versionID;
@property (nonatomic, copy, nullable) NSString *subdir;
/// 完成回调；中心取出后立即置空，避免中心与调用方互相持有。
@property (nonatomic, copy, nullable) void (^completion)(BOOL success, NSError * _Nullable error);

+ (instancetype)taskWithTitle:(NSString *)title
                     subtitle:(nullable NSString *)subtitle
                    createdAt:(NSDate *)createdAt;

/// 累加进度增量（引擎上报的负 delta 直接累加即回退），并更新总大小。
- (void)applyProgressDelta:(int64_t)deltaBytes totalBytes:(int64_t)totalBytes;

@end

NS_ASSUME_NONNULL_END
