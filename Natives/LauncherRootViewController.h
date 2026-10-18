#import <UIKit/UIKit.h>

// FCL风格启动器根视图控制器 - 管理三栏布局
// 左侧：功能菜单 | 中间：内容区 | 右侧：账户和启动

@interface LauncherRootViewController : UIViewController <UINavigationControllerDelegate>

// 三个主要区域
@property(nonatomic, strong, readonly) UIViewController *sidebarViewController;      // 左侧边栏
@property(nonatomic, strong, readonly) UIViewController *contentViewController;      // 中间内容
@property(nonatomic, strong, readonly) UIViewController *rightPanelViewController;   // 右侧面板

// 切换中间内容
- (void)setContentViewController:(UIViewController *)viewController animated:(BOOL)animated;

@end
