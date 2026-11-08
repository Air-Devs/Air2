//
//  A2SlidePresentationAnimator.m
//  Air2
//

#import "A2SlidePresentationAnimator.h"
#import "A2Metrics.h"

@interface A2SlidePresentationAnimator ()
@property (nonatomic, weak) UIView *zoomSource;   // 非空 ⇒ 走"从来源放大"
@end

@implementation A2SlidePresentationAnimator

+ (instancetype)shared {
    static A2SlidePresentationAnimator *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[A2SlidePresentationAnimator alloc] init]; });
    return s;
}

- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)ctx {
    return self.presenting ? 0.35 : 0.30;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)ctx {
    UIView *container = ctx.containerView;
    UIViewController *fromVC = [ctx viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIViewController *toVC   = [ctx viewControllerForKey:UITransitionContextToViewControllerKey];
    UIView *fromView = fromVC.view;
    UIView *toView   = toVC.view;
    const CGFloat w = container.bounds.size.width;
    const CGFloat h = container.bounds.size.height;

    if (self.presenting) {
        // ★有来源 ⇒ 从来源的位置/大小长出来（iOS 桌面观感）★
        UIView *src = self.zoomSource;
        if (src != nil && src.window != nil) {
            // ★起点 = 被按控件的中心，固定 34pt 圆★
            const CGFloat d = 34.0;
            CGPoint c = [src.superview convertPoint:src.center toView:container];
            CGRect r = CGRectMake(c.x - d / 2.0, c.y - d / 2.0, d, d);
            {
                // ★遮罩扩张★ 内容不缩放，从图标/按钮那一小块揭开成整页
                toView.frame = container.bounds;
                [container addSubview:toView];
                // ★遮罩用 frame+cornerRadius 动画★（path 补间在圆→矩形时会变成不规则四边形）
                CALayer *mask = [CALayer layer];
                mask.backgroundColor = UIColor.blackColor.CGColor;
                CGRect startInView = [container convertRect:r toView:toView];
                mask.frame = startInView;
                mask.cornerRadius = MIN(r.size.width, r.size.height) / 2.0;
                toView.layer.mask = mask;
                CGRect endInView = toView.bounds;
                CABasicAnimation *ab = [CABasicAnimation animationWithKeyPath:@"bounds"];
                ab.fromValue = [NSValue valueWithCGRect:startInView];
                ab.toValue   = [NSValue valueWithCGRect:endInView];
                CABasicAnimation *ap = [CABasicAnimation animationWithKeyPath:@"position"];
                ap.fromValue = [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(startInView), CGRectGetMidY(startInView))];
                ap.toValue   = [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(endInView), CGRectGetMidY(endInView))];
                CABasicAnimation *ar = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
                ar.fromValue = @(MIN(r.size.width, r.size.height) / 2.0);
                ar.toValue   = @(0);
                CAAnimationGroup *grp = [CAAnimationGroup animation];
                grp.animations = @[ab, ap, ar];
                grp.duration = 0.36;
                grp.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.22f :0.9f :0.22f :1.0f];
                mask.bounds = endInView;
                mask.position = CGPointMake(CGRectGetMidX(endInView), CGRectGetMidY(endInView));
                mask.cornerRadius = 0;
                [mask addAnimation:grp forKey:@"a2zoom"];
                [UIView animateWithDuration:0.36 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                    fromView.transform = CGAffineTransformMakeScale(1.04, 1.04);
                    fromView.alpha = 0.6;
                } completion:nil];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.36 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    toView.layer.mask = nil;
                    fromView.transform = CGAffineTransformIdentity;
                    fromView.alpha = 1;
                    [ctx completeTransition:!ctx.transitionWasCancelled];
                });
                return;
            }
        }
        toView.frame = CGRectMake(w, 0, w, h);
        [container addSubview:toView];

        UISpringTimingParameters *params =
            [[UISpringTimingParameters alloc] initWithDampingRatio:0.90 initialVelocity:CGVectorMake(0, 0)];
        UIViewPropertyAnimator *a =
            [[UIViewPropertyAnimator alloc] initWithDuration:0.35 timingParameters:params];
        [a addAnimations:^{
            toView.frame = container.bounds;
            fromView.transform = CGAffineTransformMakeTranslation(-w * 0.30, 0);
            fromView.alpha = 0.88;
        }];
        [a addCompletion:^(UIViewAnimatingPosition pos) {
            fromView.transform = CGAffineTransformIdentity;
            fromView.alpha = 1;
            [ctx completeTransition:!ctx.transitionWasCancelled];
        }];
        [a startAnimation];
    } else {
        [container insertSubview:toView belowSubview:fromView];
        toView.frame = CGRectMake(-w * 0.30, 0, w, h);
        toView.alpha = 0.88;

        UISpringTimingParameters *params =
            [[UISpringTimingParameters alloc] initWithDampingRatio:0.92 initialVelocity:CGVectorMake(0, 0)];
        UIViewPropertyAnimator *a =
            [[UIViewPropertyAnimator alloc] initWithDuration:0.30 timingParameters:params];
        [a addAnimations:^{
            toView.frame = container.bounds;
            toView.alpha = 1;
            fromView.frame = CGRectMake(w, 0, w, h);
        }];
        [a addCompletion:^(UIViewAnimatingPosition pos) {
            [ctx completeTransition:!ctx.transitionWasCancelled];
        }];
        [a startAnimation];
    }
}

@end

// ============================================================================
//  呈现方：让 modal 用上面这套转场。必须实现 transitioningDelegate 的两个方法。
// ============================================================================

@interface A2SlideTransitionDelegate : NSObject <UIViewControllerTransitioningDelegate>
@property (nonatomic, weak) UIView *zoomSource;
@end

@implementation A2SlideTransitionDelegate
- (id<UIViewControllerAnimatedTransitioning>)animationControllerForPresentedController:(UIViewController *)presented
                                                                   presentingController:(UIViewController *)presenting
                                                                       sourceController:(UIViewController *)source {
    A2SlidePresentationAnimator *a = [A2SlidePresentationAnimator shared];
    a.presenting = YES;
    a.zoomSource = self.zoomSource;
    return a;
}
- (id<UIViewControllerAnimatedTransitioning>)animationControllerForDismissedController:(UIViewController *)dismissed {
    A2SlidePresentationAnimator *a = [A2SlidePresentationAnimator shared];
    a.presenting = NO;
    // ★2026-11-07 修★ 共享实例会把上一次的 zoomSource 留着，
    //   导致「侧滑呈现」的全屏页关闭时也被缩小。这里按当前 delegate 重新同步。
    a.zoomSource = self.zoomSource;
    return a;
}
@end

@implementation UIViewController (A2SlidePresentation)

- (void)a2_presentZoomFrom:(UIView *)source presenter:(UIViewController *)presenter {
    static A2SlideTransitionDelegate *delegate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ delegate = [[A2SlideTransitionDelegate alloc] init]; });
    delegate.zoomSource = source;
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    self.transitioningDelegate = delegate;
    [presenter presentViewController:self animated:YES completion:nil];
}

- (void)a2_presentFromRightFrom:(UIViewController *)presenter {
    static A2SlideTransitionDelegate *delegate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ delegate = [[A2SlideTransitionDelegate alloc] init]; });

    delegate.zoomSource = nil;                // 右滑模式：不带来源
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    self.transitioningDelegate = delegate;    // ★delegate 由 static 强持有★（UIKit 只弱引用）
    [presenter presentViewController:self animated:YES completion:nil];
}

@end
