#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 下载历史页（spec Phase 6 Task 6.2）。
 * 数据源为 [DownloadHistoryStore sharedStore].allEntries（新→旧），
 * 展示名称/类型/大小/时间/结果，支持一键清空（确认弹窗）。
 */
@interface DownloadHistoryViewController : UITableViewController

@end

NS_ASSUME_NONNULL_END
