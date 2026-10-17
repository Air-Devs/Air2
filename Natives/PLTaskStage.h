#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 任务阶段状态（五态）。
 * 相比 ZL2 的三态（Pending/Running/Completed）增加 Failed/Skipped：
 * - Failed：该阶段执行失败（对应任务整体失败）
 * - Skipped：条件性跳过（如文件已缓存无需下载）
 */
typedef NS_ENUM(NSInteger, PLTaskStageStatus) {
    PLTaskStageStatusPending = 0,    // 未开始
    PLTaskStageStatusRunning = 1,    // 进行中
    PLTaskStageStatusCompleted = 2,  // 已完成
    PLTaskStageStatusFailed = 3,     // 失败
    PLTaskStageStatusSkipped = 4     // 已跳过
};

/**
 * 统一任务阶段模型（阶段化任务流的最小单元，参考 ZL2 Task.kt 扩展）。
 * 安装类任务（原版/加载器/整合包）由多个阶段组成，业务方通过
 * DownloadTaskManager 的阶段上报 API 逐阶段推进状态与进度。
 * title 约定存储本地化 key（见 PLTaskStages.h 统一常量，快照跨语言稳定），
 * 由 UI 层负责 NSLocalizedString 渲染。
 */
@interface PLTaskStage : NSObject

/// 阶段标题（本地化 key）
@property (nonatomic, copy) NSString *title;
/// SF Symbol 图标名（如 list.bullet / arrow.down.circle）
@property (nonatomic, copy) NSString *iconName;
/// 阶段状态，默认 Pending
@property (nonatomic, assign) PLTaskStageStatus status;
/// 动态详情文案（如当前下载的文件名），可为 nil
@property (nonatomic, copy, nullable) NSString *message;
/// 0.0 ~ 1.0；-1 表示不确定进度（UI 显示流动动画，不显示百分比）
@property (nonatomic, assign) double progress;
/// 当前速率（bytes/s）
@property (nonatomic, assign) double rateBytesPerSec;
/// 已完成文件数（双维度计数：文件数 + 字节）
@property (nonatomic, assign) NSInteger completedFileCount;
/// 总文件数；<= 0 表示不展示文件计数维度
@property (nonatomic, assign) NSInteger totalFileCount;

/// 便捷构造：标题 + 图标名，其余字段取默认值（Pending / -1 / 0）
+ (instancetype)stageWithTitle:(NSString *)title iconName:(NSString *)iconName;

/// 指定初始化：标题 + 图标名，其余字段取默认值（Pending / -1 / 0）
- (instancetype)initWithTitle:(NSString *)title iconName:(NSString *)iconName;

#pragma mark - 快照序列化（随 DownloadTaskItem 快照一并持久化/恢复）

/// 导出可 JSON 序列化的阶段快照
- (NSDictionary *)snapshotDictionary;

/// 从快照重建阶段（快照非法时返回 nil）
- (nullable instancetype)initWithSnapshotDictionary:(NSDictionary *)snapshot;

@end

NS_ASSUME_NONNULL_END
