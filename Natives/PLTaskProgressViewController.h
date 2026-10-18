#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 统一下载/安装进度页（redesign-download-ui Phase 2）。
 *
 * ZL2 风格阶段步骤列表（五态图标，仅运行中阶段展开详情区：当前文件名、
 * 进度条+速率+百分比、双维度"12/38 个文件 · 45MB/180MB"、ETA），
 * 加上总进度汇总条（全部阶段加权汇总 + 实时速率）与底部操作按钮区
 * （最小化始终可用；暂停/继续/取消/重试/查看详情按任务状态与能力动态显示）。
 *
 * 展示对象为注册到 DownloadTaskManager 的任意任务（按 taskId 订阅
 * DownloadTaskManagerDidUpdateTaskNotification 实时刷新）。
 * 双端形态：iPhone PageSheet 全屏模态 / iPad FormSheet 居中卡片（约 560pt 宽），
 * 内容超高时内部滚动；深色模式通过系统动态色自动适配。
 */
@interface PLTaskProgressViewController : UIViewController

/// 当前展示的任务 ID（presentForTaskId: 替换任务时会变化）
@property (nonatomic, copy, readonly) NSString *taskId;

/// 任务成功完成后是否延迟自动最小化（默认 YES：完成态停留 1.5s 后自动 dismiss）；
/// 失败/取消不自动关闭（显示终态与操作按钮）
@property (nonatomic, assign) BOOL autoDismissOnCompletion;

/// 指定初始化：按任务 ID 创建进度页
- (instancetype)initWithTaskId:(NSString *)taskId;

/// 从 keyWindow 顶层视图控制器弹出统一进度页。
/// 若同屏已有进度页实例：展示相同任务则直接返回，否则原地替换其展示任务
/// （不再叠加弹出，保证同屏仅一个进度页）。
/// 安装类流程的"自动弹出"（spec：autoPresentDetail）无需调用本方法：
/// 业务方在任务注册后将 DownloadTaskItem.autoPresentDetail 置 YES，
/// DownloadTaskManager 会在该任务首次更新时自动调用本方法弹出。
+ (void)presentForTaskId:(NSString *)taskId;

@end

NS_ASSUME_NONNULL_END
