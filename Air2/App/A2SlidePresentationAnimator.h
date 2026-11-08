//
//  A2SlidePresentationAnimator.h
//  Air2
//
//  ★全屏 modal 的 iOS 观感转场★
//
//  背景：`presentViewController:` + `UIModalPresentationFullScreen` 的系统默认动画是
//  "从下往上淡入"，和 iOS 导航的横向推入完全两种手感；用户反馈"有些地方直接出来、
//  不是右边进来"就是这些全屏页。
//
//  用法（唯一入口，避免每个调用点各写一套）：
//      [vc a2_presentFromRightFrom:self];
//  它会：① 设 FullScreen ② 装上本转场 ③ present。
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 右进右出的全屏转场（推入 0.35s / spring 0.90；退出 0.30s）
@interface A2SlidePresentationAnimator : NSObject <UIViewControllerAnimatedTransitioning>
@property (nonatomic, assign) BOOL presenting;
+ (instancetype)shared;
@end

@interface UIViewController (A2SlidePresentation)
/// 以 iOS 横向推入的方式全屏呈现（替代裸的 presentViewController:animated:）
- (void)a2_presentFromRightFrom:(UIViewController *)presenter;

/// ★从来源视图放大呈现（iOS 桌面开 App 那种）★
///   source 传被点的卡片/图标；等于 nil 时退化为右滑呈现。
- (void)a2_presentZoomFrom:(UIView *)source presenter:(UIViewController *)presenter;
@end

NS_ASSUME_NONNULL_END
