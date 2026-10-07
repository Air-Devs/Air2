//
//  A2NavigationController.h
//  Air2
//
//  自定义导航控制器 —— 承载页面转场动画。
//
//  为什么不用系统默认转场：
//  默认的「从右侧推入」在启动器这种卡片化界面里显得生硬，
//  且横向位移在横屏大屏上视觉跨度太大。
//  这里提供三种转场，按页面性质选用。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2TransitionStyle) {
    /// 缩放淡入（默认）—— 新页从 94% 展开，适合同级页面切换
    A2TransitionStyleScaleFade = 0,
    /// 从底部滑入 —— 适合模态性质较强的页面（如安装流程）
    A2TransitionStyleSheet,
    /// 右侧推入 —— 适合层级较深的钻取（如设置 → 子设置）
    A2TransitionStylePush,
};

@interface A2NavigationController : UINavigationController

/// 以指定转场样式推入页面
- (void)pushViewController:(UIViewController *)viewController
                transition:(A2TransitionStyle)style
                  animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
