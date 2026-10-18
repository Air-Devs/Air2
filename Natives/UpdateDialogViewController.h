#import <UIKit/UIKit.h>
#import "UpdateChecker.h"

NS_ASSUME_NONNULL_BEGIN

/// 启动器更新弹窗（参照 ZL2 的 UpgradeDialog）。
///
/// 布局：顶部标题 + 版本号 + 发布时间 → 中间可滚动的更新日志（简易 Markdown 渲染）
/// → 底部三个操作：忽略此版本 / 稍后 / 更新（跳转到本次查到的 release 页面）。
@interface UpdateDialogViewController : UIViewController

+ (instancetype)dialogWithInfo:(UpdateInfo *)info;

/// 用户点"忽略此版本"时回调（传入被忽略的版本号）
@property(nonatomic, copy, nullable) void (^onSkipped)(NSString *version);

@end

NS_ASSUME_NONNULL_END
