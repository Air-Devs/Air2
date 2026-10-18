#import <UIKit/UIKit.h>
#import "DownloadTaskItem.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * 全屏下载任务管理页。
 * 集中展示所有已注册到 DownloadTaskManager 的下载任务，
 * 支持按下载状态与资源类型两级筛选，以及暂停/恢复/取消/切换下载源等操作。
 */
@interface DownloadTasksViewController : UIViewController

/// 进入页面时默认选中的下载状态筛选（默认 DownloadTaskStatePending 表示全部）
@property (nonatomic, assign) DownloadTaskState filterState;

/// 进入页面时默认选中的资源类型筛选（nil 表示全部）
@property (nonatomic, copy, nullable) NSString *filterType;

@end

NS_ASSUME_NONNULL_END
