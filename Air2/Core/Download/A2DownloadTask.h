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
//  状态机只由 A2DownloadTaskCenter 推进：只读属性在上方主接口，可变接口单独放在
//  文件末尾的类扩展里（标注「内部」）。UI 只要 import 本头就能读进度，但不应写状态，
//  否则会绕过中心的状态机，破坏「唯一入队/暂停/重试」约束。
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

#pragma mark - 内部可变接口

/// 仅供 A2DownloadTaskCenter 推进状态机使用；UI 层请勿写这些属性。
///
/// 与只读主接口同放一个头文件，而不是另开内部头：本地校验脚本按「类名 → 头文件」
/// 建唯一映射（见 scripts/check_imports.py 的组件依赖检查），同一类若被两个头文件
/// 声明，归属会随遍历顺序变化，导致 lint 结果不确定。故本类只允许一个头声明。
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
