//
//  A2DownloadTaskCenter.h
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
//  统一下载任务中心 —— 全应用唯一的下载任务队列。
//
//  职责：统一入队/暂停/重试/取消，推进任务状态机，成功时回写已下载清单，
//  并在任务集合变化时广播通知，供底部抽屉/任务列表页订阅。
//  真正的网络与落盘仍由 A2DownloadEngine 完成，这里只做编排。
//
//  线程模型：任务数组由内部串行队列保护；对外通知与回调一律回主线程。
//

#import <Foundation/Foundation.h>
#import "A2DownloadTask.h"
#import "A2DownloadEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// 任务集合发生变化（新增/进度/状态）时广播。UI 收到后重新取 allTasks 刷新。
extern NSNotificationName const A2DownloadTasksDidChangeNotification;

@interface A2DownloadTaskCenter : NSObject

+ (instancetype)shared;

/// 全部任务：进行中（Running/Paused）在前，结束（Completed/Failed/Cancelled）在后。
- (NSArray<A2DownloadTask *> *)allTasks;
- (NSArray<A2DownloadTask *> *)activeTasks;
/// 已完成 + 失败 + 已取消
- (NSArray<A2DownloadTask *> *)finishedTasks;

/// 入队并立即开始下载。
/// projectID/versionID/subdir 非空时，成功后写入 A2DownloadManifest。
/// @return 任务 ID（永不为 nil）
- (NSString *)enqueueWithTitle:(NSString *)title
                      subtitle:(nullable NSString *)subtitle
                       request:(A2DownloadRequest *)request
                     projectID:(nullable NSString *)projectID
                     versionID:(nullable NSString *)versionID
                        subdir:(nullable NSString *)subdir
                    completion:(nullable void (^)(BOOL success, NSError * _Nullable error))completion;

/// 运行中 → 暂停；暂停 → 继续
- (void)togglePauseTaskWithID:(NSString *)taskID;
/// 仅失败/取消的任务可重试：用原始请求重下
- (void)retryTaskWithID:(NSString *)taskID;
- (void)cancelTaskWithID:(NSString *)taskID;
/// 清空已结束任务
- (void)clearFinishedTasks;

@end

NS_ASSUME_NONNULL_END
