#import <UIKit/UIKit.h>

@interface AccountListViewController: UITableViewController<UIPopoverPresentationControllerDelegate>


@property (nonatomic, copy) void (^whenDelete)(NSString* name);
@property(nonatomic, copy) void (^whenItemSelected)();

/// FCL 风格底部"添加账户"浮动按钮（暴露属性便于布局/动画控制）
@property (nonatomic, strong) UIButton *addAccountButton;

@end
