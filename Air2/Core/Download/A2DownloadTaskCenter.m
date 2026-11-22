//
//  A2DownloadTaskCenter.m
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
//  见头文件。这里的关键约束：
//    · 任务数组只在内部串行队列上读写；对外通知/回调一律回主线程。
//    · 通知不节流会在逐包进度回调里刷爆 UI，故进度/速度广播做 100ms 节流，
//      状态变化（完成/失败/取消/重试）则立即广播，保证状态不错过。
//    · 完成回调里对「主动取消」要特别处理：引擎取消时也会走 completion，
//      若不拦截会把状态从 Cancelled 覆盖成 Failed。
//

#import "A2DownloadTaskCenter.h"
#import "A2DownloadManifest.h"
#import "A2Log.h"

NSNotificationName const A2DownloadTasksDidChangeNotification = @"A2DownloadTasksDidChangeNotification";

/// 进度/速度通知节流间隔：引擎进度回调很密，逐包广播会拖垮 UI。
static const NSTimeInterval kTaskNotifyThrottle = 0.1;

@interface A2DownloadTaskCenter ()

@property (nonatomic, strong) NSMutableArray<A2DownloadTask *> *tasks;
@property (nonatomic, strong) dispatch_queue_t queue;
/// 任务 ID 的自增序号，仅在 queue 上读写
@property (nonatomic, assign) NSUInteger sequence;
/// 上次广播时间，仅在 queue 上读写
@property (nonatomic, assign) NSTimeInterval lastNotifyTime;

@end

@implementation A2DownloadTaskCenter

+ (instancetype)shared {
    static A2DownloadTaskCenter *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 注意：这里【不能】发通知。UI 可能在通知回调里首次访问 shared，
        // 若 init 内同步广播就会重入同一个 dispatch_once 而死锁（本项目踩过）。
        shared = [[A2DownloadTaskCenter alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _tasks = [NSMutableArray array];
    _queue = dispatch_queue_create("dev.airdevs.air2.download-task-center", DISPATCH_QUEUE_SERIAL);
    return self;
}

#pragma mark - 查询

- (NSArray<A2DownloadTask *> *)allTasks {
    __block NSArray<A2DownloadTask *> *snapshot = nil;
    dispatch_sync(self.queue, ^{
        // 进行中的排前面，组内按创建时间升序 —— UI 直接顺序渲染即可。
        snapshot = [self.tasks sortedArrayUsingComparator:^NSComparisonResult(A2DownloadTask *a, A2DownloadTask *b) {
            BOOL aActive = a.isActive;
            BOOL bActive = b.isActive;
            if (aActive != bActive) {
                return aActive ? NSOrderedAscending : NSOrderedDescending;
            }
            return [a.createdAt compare:b.createdAt];
        }];
    });
    return snapshot;
}

- (NSArray<A2DownloadTask *> *)activeTasks {
    NSMutableArray<A2DownloadTask *> *result = [NSMutableArray array];
    for (A2DownloadTask *task in [self allTasks]) {
        if (task.isActive) [result addObject:task];
    }
    return result;
}

- (NSArray<A2DownloadTask *> *)finishedTasks {
    NSMutableArray<A2DownloadTask *> *result = [NSMutableArray array];
    for (A2DownloadTask *task in [self allTasks]) {
        if (!task.isActive) [result addObject:task];
    }
    return result;
}

#pragma mark - 入队

- (NSString *)enqueueWithTitle:(NSString *)title
                      subtitle:(NSString *)subtitle
                       request:(A2DownloadRequest *)request
                     projectID:(NSString *)projectID
                     versionID:(NSString *)versionID
                        subdir:(NSString *)subdir
                    completion:(void (^)(BOOL, NSError *))completion {
    A2DownloadTask *task = [A2DownloadTask taskWithTitle:title subtitle:subtitle createdAt:[NSDate date]];
    task.request = request;
    task.projectID = projectID;
    task.versionID = versionID;
    task.subdir = subdir;
    task.completion = completion;
    task.state = A2DownloadStateRunning;

    dispatch_sync(self.queue, ^{
        self.sequence += 1;
        task.taskID = [NSString stringWithFormat:@"%.0f-%lu",
                       [NSDate date].timeIntervalSince1970 * 1000, (unsigned long)self.sequence];
        [self.tasks addObject:task];
    });

    [A2Log log:@"download-task: 入队 %@ \"%@\"", task.taskID, title];
    [self startTask:task];
    [self notifyChange];
    return task.taskID;
}

/// 发起一次引擎请求并把句柄挂到任务上（入队与重试共用）。
- (void)startTask:(A2DownloadTask *)task {
    NSString *taskID = task.taskID;
    __weak typeof(self) weakSelf = self;
    A2DownloadOperation *operation =
        [[A2DownloadEngine sharedClient] startRequest:task.request
            progress:^(int64_t deltaBytes, int64_t totalExpectedBytes) {
                [weakSelf handleProgressWithTaskID:taskID deltaBytes:deltaBytes totalBytes:totalExpectedBytes];
            }
            speed:^(int64_t bytesPerSecond) {
                [weakSelf handleSpeedWithTaskID:taskID bytesPerSecond:bytesPerSecond];
            }
            completion:^(BOOL success, NSError *error) {
                [weakSelf handleCompletionWithTaskID:taskID success:success error:error];
            }];
    dispatch_async(self.queue, ^{
        A2DownloadTask *current = [self taskForID:taskID];
        if (current) current.operation = operation;
    });
}

#pragma mark - 引擎回调（内部队列）

- (void)handleProgressWithTaskID:(NSString *)taskID deltaBytes:(int64_t)deltaBytes totalBytes:(int64_t)totalBytes {
    dispatch_async(self.queue, ^{
        A2DownloadTask *task = [self taskForID:taskID];
        if (!task || !task.isActive) return;
        [task applyProgressDelta:deltaBytes totalBytes:totalBytes];
        [self notifyChangeThrottled];
    });
}

- (void)handleSpeedWithTaskID:(NSString *)taskID bytesPerSecond:(int64_t)bytesPerSecond {
    dispatch_async(self.queue, ^{
        A2DownloadTask *task = [self taskForID:taskID];
        if (!task || !task.isActive) return;
        task.speed = (double)bytesPerSecond;
        [self notifyChangeThrottled];
    });
}

- (void)handleCompletionWithTaskID:(NSString *)taskID success:(BOOL)success error:(NSError *)error {
    dispatch_async(self.queue, ^{
        A2DownloadTask *task = [self taskForID:taskID];
        if (!task) return;

        // 主动取消时引擎也会回调一次；状态已是 Cancelled，不能被覆盖成 Failed。
        if (task.state == A2DownloadStateCancelled) {
            task.operation = nil;
            task.completion = nil;
            return;
        }

        task.operation = nil;
        task.speed = 0;
        if (success) {
            task.state = A2DownloadStateCompleted;
            [self recordManifestForTask:task];
            [A2Log log:@"download-task: 完成 %@ \"%@\"", taskID, task.title];
        } else {
            task.state = A2DownloadStateFailed;
            task.errorMessage = error.localizedDescription;
            [A2Log log:@"download-task: 失败 %@ \"%@\" - %@",
                  taskID, task.title, error.localizedDescription ?: @"未知错误"];
        }

        void (^done)(BOOL, NSError *) = task.completion;
        task.completion = nil;
        NSError *finalError = error;

        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:A2DownloadTasksDidChangeNotification
                                                              object:self];
            if (done) done(success, finalError);
        });
    });
}

/// 成功后回写已下载清单（元信息不全则跳过）。
- (void)recordManifestForTask:(A2DownloadTask *)task {
    if (task.projectID.length == 0 || task.versionID.length == 0 || task.subdir.length == 0) return;
    NSString *fileName = task.request.destinationPath.lastPathComponent;
    if (fileName.length == 0) return;
    [[A2DownloadManifest shared] recordDownloadWithProjectID:task.projectID
                                                  versionID:task.versionID
                                                   fileName:fileName
                                                     subdir:task.subdir];
}

#pragma mark - 暂停 / 重试 / 取消

- (void)togglePauseTaskWithID:(NSString *)taskID {
    dispatch_async(self.queue, ^{
        A2DownloadTask *task = [self taskForID:taskID];
        A2DownloadOperation *operation = task.operation;
        if (!task || !operation) return;

        A2DownloadEngine *engine = [A2DownloadEngine sharedClient];
        if (task.state == A2DownloadStateRunning) {
            [engine pauseOperation:operation];
            task.state = A2DownloadStatePaused;
            task.speed = 0;
            [A2Log log:@"download-task: 暂停 %@", taskID];
        } else if (task.state == A2DownloadStatePaused) {
            [engine resumeOperation:operation];
            task.state = A2DownloadStateRunning;
            [A2Log log:@"download-task: 继续 %@", taskID];
        } else {
            return;
        }
        [self notifyChange];
    });
}

- (void)retryTaskWithID:(NSString *)taskID {
    dispatch_async(self.queue, ^{
        A2DownloadTask *task = [self taskForID:taskID];
        if (!task || !task.request) return;
        if (task.state != A2DownloadStateFailed && task.state != A2DownloadStateCancelled) return;

        task.errorMessage = nil;
        task.speed = 0;
        task.state = A2DownloadStateRunning;
        [A2Log log:@"download-task: 重试 %@ \"%@\"", taskID, task.title];
        // 重试即新建一次引擎请求替换旧句柄（旧句柄在结束时已置空）。
        [self startTask:task];
        [self notifyChange];
    });
}

- (void)cancelTaskWithID:(NSString *)taskID {
    dispatch_async(self.queue, ^{
        A2DownloadTask *task = [self taskForID:taskID];
        if (!task) return;
        if (task.state != A2DownloadStateRunning && task.state != A2DownloadStatePaused) return;

        A2DownloadOperation *operation = task.operation;
        // 先落 Cancelled 再通知引擎：引擎取消会回调 completion，
        // 届时状态已是 Cancelled，完成回调会据此忽略，避免被改成 Failed。
        task.operation = nil;
        task.state = A2DownloadStateCancelled;
        task.speed = 0;
        if (operation) {
            [[A2DownloadEngine sharedClient] cancelOperation:operation];
        }
        [A2Log log:@"download-task: 取消 %@ \"%@\"", taskID, task.title];
        [self notifyChange];
    });
}

- (void)clearFinishedTasks {
    dispatch_async(self.queue, ^{
        NSMutableArray<A2DownloadTask *> *kept = [NSMutableArray array];
        for (A2DownloadTask *task in self.tasks) {
            if (task.isActive) [kept addObject:task];
        }
        [self.tasks setArray:kept];
        [self notifyChange];
    });
}

#pragma mark - 通知

/// 广播任务集合变化。始终回主线程，UI 订阅方可直接刷新。
- (void)notifyChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:A2DownloadTasksDidChangeNotification
                                                          object:self];
    });
}

/// 节流版广播，仅在 queue 上调用（lastNotifyTime 受 queue 保护）。
- (void)notifyChangeThrottled {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - self.lastNotifyTime < kTaskNotifyThrottle) return;
    self.lastNotifyTime = now;
    [self notifyChange];
}

#pragma mark - 工具

- (nullable A2DownloadTask *)taskForID:(NSString *)taskID {
    for (A2DownloadTask *task in self.tasks) {
        if ([task.taskID isEqualToString:taskID]) return task;
    }
    return nil;
}

@end
