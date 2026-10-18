#import <UIKit/UIKit.h>

// FCL风格左侧边栏 - 功能菜单

@interface LauncherMenuViewController : UIViewController

// 菜单项点击回调
@property(nonatomic, copy) void (^onMenuItemSelected)(NSInteger index, NSString *title);

// 刷新账户信息
- (void)updateAccountInfo;

@end
