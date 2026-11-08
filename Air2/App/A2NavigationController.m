//
//  A2NavigationController.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//

#import "A2NavigationController.h"
#import "A2Metrics.h"
#import "A2ThemeManager.h"

#pragma mark - 转场动画器

@interface A2TransitionAnimator : NSObject <UIViewControllerAnimatedTransitioning>
@property (nonatomic, assign) BOOL isPresenting;
@property (nonatomic, assign) A2TransitionStyle style;
/// ★Zoom 的起始视图（被点的卡片/图标）★
@property (nonatomic, weak) UIView *sourceView;
/// ★返回时用的起点矩形（窗口坐标）★
@property (nonatomic, assign) CGRect a2PopSourceRect;
/// ★入场用的起点矩形（窗口坐标）★（由 push 侧计算好，避免二次消费）
@property (nonatomic, assign) CGRect a2PushSourceRect;
@end

@implementation A2TransitionAnimator

- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)ctx {
    // ★iOS 基准★ 推入/返回 0.35s；弹层（sheet）稍慢 0.40s
    return ((self.style == A2TransitionStyleSheet) ? 0.40 : 0.35) * [A2NavigationController transitionSpeedMultiplier];
}

/// ★iOS 开 App 观感（遮罩版）★
///   内容保持原尺寸不缩放；用一个**从来源小块开始的圆角遮罩**扩张到全屏，
///   视觉上就是"那个图标/按钮被撑开成整页"，而不是"缩小的整页在放大"。
- (void)a2_animateZoom:(id<UIViewControllerContextTransitioning>)ctx {
    UIView *container = ctx.containerView;
    UIViewController *fromVC = [ctx viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIViewController *toVC   = [ctx viewControllerForKey:UITransitionContextToViewControllerKey];
    UIView *fromView = fromVC.view;
    UIView *toView   = toVC.view;
    const NSTimeInterval dur = (self.isPresenting ? 0.36 : 0.30) * [A2NavigationController transitionSpeedMultiplier];

    CGRect src = CGRectZero;
    BOOL haveSource = NO;
    const CGFloat d = 34.0;
    CGPoint winPoint = CGPointZero;
    if (self.isPresenting && !CGRectIsNull(self.a2PushSourceRect) && !CGRectIsEmpty(self.a2PushSourceRect)) {
        CGPoint c = CGPointMake(CGRectGetMidX(self.a2PushSourceRect), CGRectGetMidY(self.a2PushSourceRect));
        if (container.window != nil) c = [container.window convertPoint:c toView:container];
        src = CGRectMake(c.x - d / 2.0, c.y - d / 2.0, d, d);
        haveSource = YES;
    } else if (!self.isPresenting && !CGRectIsNull(self.a2PopSourceRect) && !CGRectIsEmpty(self.a2PopSourceRect)) {
        // ★返回：直接用 push 时记下的起点矩形★（sourceView 在 push 后已释放）
        CGPoint c = CGPointMake(CGRectGetMidX(self.a2PopSourceRect), CGRectGetMidY(self.a2PopSourceRect));
        if (container.window != nil) c = [container.window convertPoint:c toView:container];
        src = CGRectMake(c.x - d / 2.0, c.y - d / 2.0, d, d);
        haveSource = YES;
    } else if ([A2NavigationController consumeNextZoomOrigin:&winPoint]) {
        // ★优先用"实际按下的坐标"★（sender 是整张卡片时，卡片中心≠手指位置）
        CGPoint c = winPoint;
        if (container.window != nil) c = [container.window convertPoint:winPoint toView:container];
        src = CGRectMake(c.x - d / 2.0, c.y - d / 2.0, d, d);
        haveSource = YES;
    } else if (self.sourceView != nil && self.sourceView.window != nil) {
        CGPoint c = [self.sourceView.superview convertPoint:self.sourceView.center toView:container];
        src = CGRectMake(c.x - d / 2.0, c.y - d / 2.0, d, d);
        haveSource = YES;
    }

    if (self.isPresenting) {
        toView.frame = container.bounds;
        [container addSubview:toView];

        if (haveSource) {
            // ★遮罩用 frame+cornerRadius 动画★
            //   原来对 path 做补间：圆和矩形的控制点数量对不上 ⇒ 中间会变成不规则四边形。
            //   改成普通 CALayer 蒙版，动画 bounds/position/cornerRadius，形状始终是圆角矩形。
            CALayer *mask = [CALayer layer];
            mask.backgroundColor = UIColor.blackColor.CGColor;
            mask.cornerRadius = MIN(src.size.width, src.size.height) / 2.0;
            CGRect startInView = [container convertRect:src toView:toView];
            mask.frame = startInView;
            toView.layer.mask = mask;

            CGRect endInView = toView.bounds;
            CABasicAnimation *ab = [CABasicAnimation animationWithKeyPath:@"bounds"];
            ab.fromValue = [NSValue valueWithCGRect:startInView];
            ab.toValue   = [NSValue valueWithCGRect:endInView];
            CABasicAnimation *ap = [CABasicAnimation animationWithKeyPath:@"position"];
            ap.fromValue = [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(startInView), CGRectGetMidY(startInView))];
            ap.toValue   = [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(endInView), CGRectGetMidY(endInView))];
            CABasicAnimation *ar = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
            ar.fromValue = @(MIN(src.size.width, src.size.height) / 2.0);
            ar.toValue   = @(0);
            CAAnimationGroup *grp = [CAAnimationGroup animation];
            grp.animations = @[ab, ap, ar];
            grp.duration = dur;
            grp.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.22f :0.9f :0.22f :1.0f];
            mask.bounds = endInView;
            mask.position = CGPointMake(CGRectGetMidX(endInView), CGRectGetMidY(endInView));
            mask.cornerRadius = 0;
            [mask addAnimation:grp forKey:@"a2zoom"];
        } else {
            toView.alpha = 0;
            [UIView animateWithDuration:dur animations:^{ toView.alpha = 1; }];
        }

        [UIView animateWithDuration:dur delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            fromView.transform = CGAffineTransformMakeScale(1.04, 1.04);
            fromView.alpha = 0.6;
        } completion:nil];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dur * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            toView.layer.mask = nil;
            fromView.transform = CGAffineTransformIdentity;
            fromView.alpha = 1;
            [ctx completeTransition:!ctx.transitionWasCancelled];
        });
    } else {
        [container insertSubview:toView belowSubview:fromView];
        toView.frame = container.bounds;
        toView.alpha = 1;

        if (haveSource) {
            // 返回：同一个遮罩从全屏收成圆（同样用 frame/cornerRadius，避免 path 补间变形）
            CALayer *mask = [CALayer layer];
            mask.backgroundColor = UIColor.blackColor.CGColor;
            CGRect endInView = [container convertRect:src toView:fromView];
            mask.frame = endInView;
            mask.cornerRadius = MIN(src.size.width, src.size.height) / 2.0;
            fromView.layer.mask = mask;

            CGRect startInView = fromView.bounds;
            CABasicAnimation *ab = [CABasicAnimation animationWithKeyPath:@"bounds"];
            ab.fromValue = [NSValue valueWithCGRect:startInView];
            ab.toValue   = [NSValue valueWithCGRect:endInView];
            CABasicAnimation *ap = [CABasicAnimation animationWithKeyPath:@"position"];
            ap.fromValue = [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(startInView), CGRectGetMidY(startInView))];
            ap.toValue   = [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(endInView), CGRectGetMidY(endInView))];
            CABasicAnimation *ar = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
            ar.fromValue = @(0);
            ar.toValue   = @(MIN(src.size.width, src.size.height) / 2.0);
            CAAnimationGroup *grp = [CAAnimationGroup animation];
            grp.animations = @[ab, ap, ar];
            grp.duration = dur;
            grp.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.4f :0.0f :1.0f :1.0f];
            [mask addAnimation:grp forKey:@"a2zoomback"];
        } else {
            fromView.alpha = 1;
        }

        // ★返回只缩小、不淡出★（用户要求：缩到那个小圆就行，不要再叠加 alpha）
        [UIView animateWithDuration:dur delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            toView.transform = CGAffineTransformIdentity;
            toView.alpha = 1;
        } completion:nil];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dur * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            fromView.layer.mask = nil;
            fromView.alpha = 1;
            [ctx completeTransition:!ctx.transitionWasCancelled];
        });
    }
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)ctx {
    // ★Zoom 走专用实现：圆角遮罩从图标/按钮那一小块扩张，内容不缩放★
    if (self.style == A2TransitionStyleZoom) {
        [self a2_animateZoom:ctx];
        return;
    }
    UIView *container = ctx.containerView;
    UIViewController *fromVC = [ctx viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIViewController *toVC = [ctx viewControllerForKey:UITransitionContextToViewControllerKey];

    if (!toVC) {
        [ctx completeTransition:YES];
        return;
    }

    UIView *fromView = fromVC.view;
    UIView *toView = toVC.view;
    NSTimeInterval duration = [self transitionDuration:ctx];
    CGFloat w = container.bounds.size.width;
    CGFloat h = container.bounds.size.height;

    if (self.isPresenting) {
        // ---- 入场 ----
        switch (self.style) {
            case A2TransitionStyleSheet:
                toView.frame = CGRectMake(0, h, w, h);
                break;
            case A2TransitionStylePush:
                toView.frame = CGRectMake(w, 0, w, h);
                break;
            case A2TransitionStyleZoom: {
                // ★iOS 开 App 观感★ 新页**从被点的那个卡片/图标的位置和大小长出来**，
                //   不是从中心放大（那是"变慢的直接打开"，用户明确否掉过）。
                toView.frame = container.bounds;
                toView.alpha = 0;
                toView.layer.masksToBounds = YES;

                CGRect srcRect = CGRectZero;
                BOOL haveSource = NO;
                if (self.sourceView != nil && self.sourceView.window != nil) {
                    srcRect = [self.sourceView.superview convertRect:self.sourceView.bounds
                                                              toView:container];
                    haveSource = (srcRect.size.width > 8 && srcRect.size.height > 8);
                }
                if (haveSource) {
                    const CGFloat sWant = srcRect.size.width / MAX(1.0, container.bounds.size.width);
                    const CGFloat s = MIN(MAX(sWant, 0.05), 0.9);
                    toView.transform = CGAffineTransformMakeScale(s, s);
                    toView.center = CGPointMake(CGRectGetMidX(srcRect), CGRectGetMidY(srcRect));
                    // 视觉上的圆角 ≈ 卡片本身圆角：视图被缩放了 s，所以要除以 s 补偿
                    toView.layer.cornerRadius = (srcRect.size.width * 0.22) / s;
                } else {
                    toView.transform = CGAffineTransformMakeScale(0.60, 0.60);
                    toView.layer.cornerRadius = 28;
                }
                break;
            }
            case A2TransitionStyleScaleFade:
            default:
                toView.frame = container.bounds;
                toView.transform = CGAffineTransformMakeScale(0.94, 0.94);
                toView.alpha = 0;
                break;
        }
        [container addSubview:toView];

        // 缩放转场用标准弹簧（有回弹感），位移转场用更稳的软弹簧
        UIViewPropertyAnimator *anim = (self.style == A2TransitionStyleScaleFade)
            ? A2SpringAnimator(duration)
            : A2SoftSpring(duration);

        // ★2026-11-07 iOS 层次感★ 新页像卡片盖上来：左缘投影 + 旧页不压暗
        if (self.style == A2TransitionStylePush) {
            toView.layer.shadowColor = UIColor.blackColor.CGColor;
            toView.layer.shadowOpacity = 0.18f;
            toView.layer.shadowRadius = 12.0f;
            toView.layer.shadowOffset = CGSizeMake(-6, 0);
            toView.layer.masksToBounds = NO;
        }

        [anim addAnimations:^{
            switch (self.style) {
                case A2TransitionStyleSheet:
                    toView.frame = CGRectMake(0, 0, w, h);
                    fromView.transform = CGAffineTransformMakeScale(0.96, 0.96);
                    fromView.alpha = 0.72;
                    break;
                case A2TransitionStylePush:
                    toView.frame = container.bounds;
                    fromView.transform = CGAffineTransformMakeTranslation(-w * 0.30, 0);
                    fromView.alpha = 1.0;   // ★iOS: 前页不压暗，靠阴影区分层级
                    break;
                case A2TransitionStyleZoom:
                    toView.transform = CGAffineTransformIdentity;
                    toView.center = CGPointMake(CGRectGetMidX(container.bounds),
                                                CGRectGetMidY(container.bounds));
                    toView.alpha = 1;
                    toView.layer.cornerRadius = 0;
                    // 桌面被"推远"：轻微放大 + 变暗（iOS 同款）
                    fromView.transform = CGAffineTransformMakeScale(1.06, 1.06);
                    fromView.alpha = 0.55;
                    break;
                case A2TransitionStyleScaleFade:
                default:
                    toView.transform = CGAffineTransformIdentity;
                    toView.alpha = 1;
                    fromView.transform = CGAffineTransformMakeScale(1.03, 1.03);
                    fromView.alpha = 0.55;
                    break;
            }
        }];
        [anim addCompletion:^(UIViewAnimatingPosition pos) {
            fromView.transform = CGAffineTransformIdentity;
            fromView.alpha = 1;
            if (self.style == A2TransitionStylePush) {
                toView.layer.shadowOpacity = 0.0f;   // 收掉转场阴影
            }
            [ctx completeTransition:!ctx.transitionWasCancelled];
        }];
        [anim startAnimation];

    } else {
        // ---- 返回 ----
        [container insertSubview:toView belowSubview:fromView];
        if (self.style == A2TransitionStylePush) {
            // ★iOS 返回★ 上一页从左侧 30% 处回到原位（不是缩放）
            toView.frame = CGRectMake(-w * 0.30, 0, w, h);
            toView.transform = CGAffineTransformIdentity;
            toView.alpha = 1.0;
            fromView.layer.shadowOpacity = 0.18f;   // 滑出时同样带阴影，方向对称
            fromView.layer.shadowColor = UIColor.blackColor.CGColor;
            fromView.layer.shadowRadius = 12.0f;
            fromView.layer.shadowOffset = CGSizeMake(-6, 0);
        } else if (self.style == A2TransitionStyleZoom) {
            // ★Zoom 返回★ 下层页先处于"放大 + 略暗"，随当前页缩小一起复原
            toView.transform = CGAffineTransformMakeScale(1.04, 1.04);
            toView.alpha = 0.55;
        } else {
            toView.transform = CGAffineTransformMakeScale(0.96, 0.96);
            toView.alpha = 0.75;
        }

        UIViewPropertyAnimator *anim = A2SpringAnimator(duration * 0.9);
        [anim addAnimations:^{
            toView.transform = CGAffineTransformIdentity;
            toView.alpha = 1;
            switch (self.style) {
                case A2TransitionStyleSheet:
                    fromView.frame = CGRectMake(0, h, w, h);
                    break;
                case A2TransitionStylePush:
                    toView.frame = container.bounds;
                    toView.alpha = 1;
                    fromView.frame = CGRectMake(w, 0, w, h);
                    break;
                case A2TransitionStyleZoom:
                    toView.transform = CGAffineTransformIdentity;
                    toView.alpha = 1;
                    fromView.transform = CGAffineTransformMakeScale(0.60, 0.60);
                    fromView.alpha = 0;
                    break;
                default:
                    fromView.transform = CGAffineTransformMakeScale(0.94, 0.94);
                    fromView.alpha = 0;
                    break;
            }
        }];
        [anim addCompletion:^(UIViewAnimatingPosition pos) {
            [fromView removeFromSuperview];
            [ctx completeTransition:!ctx.transitionWasCancelled];
        }];
        [anim startAnimation];
    }
}

@end

#pragma mark - 导航控制器

@interface A2NavigationController () <UINavigationControllerDelegate>
@property (nonatomic, assign) A2TransitionStyle pendingStyle;
@property (nonatomic, assign) BOOL hasPendingStyle;
@property (nonatomic, weak) UIView *pendingSourceView;   // ★由 push...fromView: 记录★
@property (nonatomic, strong) NSMutableArray<NSNumber *> *a2StyleStack;
/// ★每个 push 的起点矩形（窗口坐标）★ 返回时用它做遮罩收缩；nil 表示没有
@property (nonatomic, strong) NSMutableArray<NSValue *> *a2SourceRectStack;
@property (nonatomic, assign) CGRect a2NextPushRect;
@property (nonatomic, assign) BOOL a2PopInteractive;
@end

static NSString *const kA2TransitionStyleKey = @"ui.transitionStyle";

@implementation A2NavigationController

+ (A2TransitionStyle)preferredTransitionStyle {
    NSNumber *n = [NSUserDefaults.standardUserDefaults objectForKey:kA2TransitionStyleKey];
    // ★2026-11-07 口径★ 这个偏好只作用于"非主页入口"的普通页面，
    //   可选范围是前三种（缩放淡入 / 底部滑入 / 横向推入）；主页那五个入口固定 Zoom。
    if (n == nil) return A2TransitionStylePush;
    NSInteger v = n.integerValue;
    if (v < A2TransitionStyleScaleFade || v > A2TransitionStylePush) return A2TransitionStylePush;
    return (A2TransitionStyle)v;
}

+ (void)setPreferredTransitionStyle:(A2TransitionStyle)style {
    [NSUserDefaults.standardUserDefaults setInteger:style forKey:kA2TransitionStyleKey];
}

static CGPoint sA2NextZoomOrigin;
static BOOL sA2NextZoomOriginValid = NO;

+ (void)setNextZoomOrigin:(CGPoint)pointInWindow {
    sA2NextZoomOrigin = pointInWindow;
    sA2NextZoomOriginValid = YES;
}

static NSString *const kA2TransitionSpeedKey = @"ui.transitionSpeed";

+ (NSInteger)preferredTransitionSpeed {
    NSNumber *n = [NSUserDefaults.standardUserDefaults objectForKey:kA2TransitionSpeedKey];
    if (n == nil) return 1;
    NSInteger v = n.integerValue;
    return (v < 0 || v > 2) ? 1 : v;
}

+ (void)setPreferredTransitionSpeed:(NSInteger)speed {
    [NSUserDefaults.standardUserDefaults setInteger:speed forKey:kA2TransitionSpeedKey];
}

+ (CGFloat)transitionSpeedMultiplier {
    switch ([self preferredTransitionSpeed]) {
        case 0:  return 1.40;   // 慢
        case 2:  return 0.72;   // 快
        default: return 1.00;   // 标准
    }
}

- (void)a2_handleInteractivePop:(UIGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) self.a2PopInteractive = YES;
}

+ (BOOL)consumeNextZoomOrigin:(CGPoint *)outPoint {
    if (!sA2NextZoomOriginValid) return NO;
    sA2NextZoomOriginValid = NO;
    if (outPoint != NULL) *outPoint = sA2NextZoomOrigin;
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.delegate = self;
    // 用自绘顶栏，隐藏系统导航栏
    self.navigationBarHidden = YES;
    self.view.backgroundColor = A2ThemeManager.shared.scheme.cSurface;
    // 保留边缘返回手势
    self.interactivePopGestureRecognizer.enabled = YES;
    self.interactivePopGestureRecognizer.delegate = nil;
    [self.interactivePopGestureRecognizer addTarget:self action:@selector(a2_handleInteractivePop:)];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (void)pushViewController:(UIViewController *)viewController
                transition:(A2TransitionStyle)style
                  animated:(BOOL)animated {
    [self pushViewController:viewController transition:style fromView:nil animated:animated];
}

- (void)pushViewController:(UIViewController *)viewController
                transition:(A2TransitionStyle)style
                  fromView:(UIView *)sourceView
                  animated:(BOOL)animated {
    self.pendingStyle = style;
    self.hasPendingStyle = YES;
    self.pendingSourceView = sourceView;
    if (self.a2StyleStack == nil) self.a2StyleStack = [NSMutableArray array];
    [self.a2StyleStack addObject:@(style)];
    if (self.a2SourceRectStack == nil) self.a2SourceRectStack = [NSMutableArray array];
    // 起点矩形：优先实际触摸点，其次来源视图中心（都换成窗口坐标存起来，供返回时用）
    CGPoint wp = CGPointZero;
    BOOL hasPt = [A2NavigationController consumeNextZoomOrigin:&wp];
    const CGFloat d = 34.0;
    CGRect srcRect;
    if (hasPt) {
        srcRect = CGRectMake(wp.x - d/2, wp.y - d/2, d, d);
    } else if (sourceView != nil && sourceView.window != nil) {
        CGPoint c = [sourceView convertPoint:CGPointMake(CGRectGetMidX(sourceView.bounds),
                                                         CGRectGetMidY(sourceView.bounds))
                                      toView:sourceView.window];
        srcRect = CGRectMake(c.x - d/2, c.y - d/2, d, d);
    } else {
        srcRect = CGRectNull;
    }
    [self.a2SourceRectStack addObject:[NSValue valueWithCGRect:srcRect]];
    self.a2NextPushRect = srcRect;   // 交给 animator 做入场*/

    [super pushViewController:viewController animated:animated];
}

#pragma mark - 两参 push：补压栈（否则返回时弹错样式）

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    // ★2026-11-08 修「二级全屏页面退出变缩小」★
    //   系统两参 push 以前没被重写 ⇒ 不往 a2StyleStack 压条目，
    //   返回时弹出的是父页面（主页入口=Zoom）的那一条 ⇒ 二级页缩小、一级页反而侧滑。
    //   这里补上：未显式指定样式时按「用户偏好（默认横向推入）」记一条。
    if (self.a2StyleStack == nil) self.a2StyleStack = [NSMutableArray array];
    if (self.a2SourceRectStack == nil) self.a2SourceRectStack = [NSMutableArray array];
    A2TransitionStyle st = self.hasPendingStyle ? self.pendingStyle
                                                : [A2NavigationController preferredTransitionStyle];
    // 三参方法现在直接走 super，不会回到这里 ⇒ 这里总是压一条
    [self.a2StyleStack addObject:@(st)];
    [self.a2SourceRectStack addObject:[NSValue valueWithCGRect:CGRectNull]];
    self.pendingStyle = st;
    self.hasPendingStyle = YES;
    [super pushViewController:viewController animated:animated];
}

#pragma mark - UINavigationControllerDelegate

- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)nc
                                  animationControllerForOperation:(UINavigationControllerOperation)operation
                                               fromViewController:(UIViewController *)fromVC
                                                 toViewController:(UIViewController *)toVC {
    A2TransitionAnimator *a = [A2TransitionAnimator new];
    a.isPresenting = (operation == UINavigationControllerOperationPush);
    a.sourceView = self.pendingSourceView;
    a.a2PushSourceRect = self.a2NextPushRect;
    a.a2PopSourceRect = CGRectNull;
    self.pendingSourceView = nil;      // 一次性

    if (a.isPresenting) {
        // ★2026-11-07 iOS 观感★ 默认改成横向推入（iOS 标准）。
        //   原来的默认是 ScaleFade（缩放+淡入），那是 Material 的风格，不是 iOS。
        // 未显式指定时按用户偏好（默认横向推入）；主页入口显式传 Zoom
        a.style = self.hasPendingStyle ? self.pendingStyle : [A2NavigationController preferredTransitionStyle];
        self.hasPendingStyle = NO;
    } else {
        // ★返回★ 点返回键 ⇒ 原路收回；边缘手势 ⇒ 侧滑
        A2TransitionStyle pushed = A2TransitionStylePush;
        if (self.a2StyleStack.count > 0) {
            pushed = (A2TransitionStyle)[self.a2StyleStack.lastObject integerValue];
            [self.a2StyleStack removeLastObject];
        }
        // ★返回用的起点矩形（窗口坐标）★
        if (self.a2SourceRectStack.count > 0) {
            CGRect r = [self.a2SourceRectStack.lastObject CGRectValue];
            [self.a2SourceRectStack removeLastObject];
            if (!CGRectIsNull(r)) a.a2PopSourceRect = r;
        }
        a.style = self.a2PopInteractive ? A2TransitionStylePush : pushed;
        self.a2PopInteractive = NO;
    }
    return a;
}

@end
