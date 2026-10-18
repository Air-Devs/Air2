#import <Foundation/Foundation.h>
#import "DownloadTaskItem.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const DownloadTaskManagerDidUpdateTaskNotification;
extern NSString * const DownloadTaskManagerAggregateStateDidChangeNotification;
extern NSString * const DownloadTaskManagerTaskCompletedNotification;
extern NSString * const DownloadTaskManagerTaskKey;

/// 全局并发下载上限（同时处于 Downloading 状态的任务数，信号量控制）
FOUNDATION_EXPORT NSInteger const PLDownloadMaxConcurrentTasks;

/**
 * 统一下载任务管理器（单例）。
 * 负责集中管理所有下载任务的生命周期、状态聚合与操作。
 */
@interface DownloadTaskManager : NSObject

+ (instancetype)sharedManager;

#pragma mark - Registration / Query

- (DownloadTaskItem *)registerTaskWithResourceType:(NSString *)resourceType
                                      resourceName:(NSString *)resourceName
                                       displayName:(NSString *)displayName
                                    downloadSource:(NSString *)downloadSource
                                           rawTask:(nullable id)rawTask
                                    supportsResume:(BOOL)supportsResume
                                           iconURL:(nullable NSString *)iconURL;

- (void)removeTaskWithId:(NSString *)taskId;
- (nullable DownloadTaskItem *)taskWithId:(NSString *)taskId;
- (NSArray<DownloadTaskItem *> *)allTasks;
- (NSArray<DownloadTaskItem *> *)tasksWithState:(DownloadTaskState)state;
- (NSArray<DownloadTaskItem *> *)tasksWithStates:(NSArray<NSNumber *> *)states;
- (NSInteger)countOfTasksWithState:(DownloadTaskState)state;

#pragma mark - Aggregate State

- (DownloadTaskAggregateState)currentAggregateState;
- (BOOL)hasActiveTasks;                       // 存在 downloading / pending
- (BOOL)hasTasksInStates:(NSArray<NSNumber *> *)states;

#pragma mark - Actions

- (void)pauseTaskWithId:(NSString *)taskId;
- (void)resumeTaskWithId:(NSString *)taskId;
- (void)cancelTaskWithId:(NSString *)taskId;

/// 重新下载（FCL 风格）。
/// 取消旧 rawTask、重置 item 状态（progress/speed/error）、retryCount++，
/// 然后调用 item.retryHandler 重建底层 rawTask。若未设置 retryHandler 或超过 maxRetryCount 则无效。
- (void)retryTaskWithId:(NSString *)taskId;

/// 切换下载源。completion 返回 shouldRecreate：YES 表示调用方需要取消旧任务并重新创建下载。
- (void)switchDownloadSourceForTaskId:(NSString *)taskId
                             toSource:(NSString *)source
                           completion:(void (^)(BOOL shouldRecreate,
                                                BOOL supportsResume,
                                                NSError * _Nullable error))completion;

#pragma mark - Progress / State Reporting

- (void)updateTaskWithId:(NSString *)taskId
                progress:(double)progress
              totalBytes:(int64_t)totalBytes
         downloadedBytes:(int64_t)downloadedBytes;

- (void)updateTaskWithId:(NSString *)taskId
                   speed:(double)speed
  estimatedTimeRemaining:(NSTimeInterval)estimatedTimeRemaining;

/// 多文件任务（如整合包按文件推进）上报文件级进度（Phase 6 Task 6.1 双维度进度）。
/// totalFileCount <= 0 表示清除文件计数维度（回到单文件展示）。
- (void)updateTaskWithId:(NSString *)taskId
      completedFileCount:(NSInteger)completedFileCount
          totalFileCount:(NSInteger)totalFileCount;

- (void)setTaskWithId:(NSString *)taskId state:(DownloadTaskState)state;

/// 标记任务完成或失败；error 为 nil 表示成功
- (void)setTaskWithId:(NSString *)taskId completedWithError:(nullable NSError *)error;

/// 更新任务错误信息（不修改状态）
- (void)updateTaskWithId:(NSString *)taskId error:(nullable NSError *)error;

#pragma mark - 阶段上报（redesign-download-ui Phase 1）

/// 整体替换任务的阶段列表（currentStageIndex 重置为 0；传入空数组等价于清除阶段信息，回退纯进度展示）
- (void)setTaskWithId:(NSString *)taskId stages:(NSArray<PLTaskStage *> *)stages;

/// 更新指定阶段的状态（index 越界时 no-op 并记录日志）
- (void)updateTaskWithId:(NSString *)taskId
           stageAtIndex:(NSUInteger)index
                 status:(PLTaskStageStatus)status;

/// 更新指定阶段的进度与动态详情文案（message 传 nil 保留原值；index 越界时 no-op）
- (void)updateTaskWithId:(NSString *)taskId
           stageAtIndex:(NSUInteger)index
                progress:(double)progress
                message:(nullable NSString *)message;

/// 更新指定阶段的速率（index 越界时 no-op）
- (void)updateTaskWithId:(NSString *)taskId
           stageAtIndex:(NSUInteger)index
                   rate:(double)rate;

/// 更新指定阶段的文件计数（双维度；totalFileCount <= 0 表示清除文件计数维度；index 越界时 no-op）
- (void)updateTaskWithId:(NSString *)taskId
           stageAtIndex:(NSUInteger)index
              fileCount:(NSInteger)completedFileCount
          totalFileCount:(NSInteger)totalFileCount;

/// 更新任务当前阶段下标（越界时 no-op 并记录日志）
- (void)updateTaskWithId:(NSString *)taskId
      currentStageIndex:(NSInteger)currentStageIndex;

#pragma mark - 并发 / 断点查询（Phase 2 新增）

/// 当前排队等待下载槽位的任务数（并发上限触发后 Pending 排队）
- (NSInteger)pendingQueueCount;

/// 读取任务的持久化断点数据（pause 时落盘；供业务方 retryHandler 内用
/// downloadTaskWithResumeData: 重建断点续传；不存在时返回 nil）
- (nullable NSData *)storedResumeDataForTaskId:(NSString *)taskId;

@end

NS_ASSUME_NONNULL_END
