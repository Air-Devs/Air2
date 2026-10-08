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
@end

@implementation A2TransitionAnimator

- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)ctx {
    return A2AnimDuration;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)ctx {
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

        [anim addAnimations:^{
            switch (self.style) {
                case A2TransitionStyleSheet:
                    toView.frame = CGRectMake(0, 0, w, h);
                    fromView.transform = CGAffineTransformMakeScale(0.96, 0.96);
                    fromView.alpha = 0.72;
                    break;
                case A2TransitionStylePush:
                    toView.frame = container.bounds;
                    fromView.transform = CGAffineTransformMakeTranslation(-w * 0.26, 0);
                    fromView.alpha = 0.7;
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
            [ctx completeTransition:!ctx.transitionWasCancelled];
        }];
        [anim startAnimation];

    } else {
        // ---- 返回 ----
        [container insertSubview:toView belowSubview:fromView];
        toView.transform = CGAffineTransformMakeScale(0.96, 0.96);
        toView.alpha = 0.75;

        UIViewPropertyAnimator *anim = A2SpringAnimator(duration * 0.9);
        [anim addAnimations:^{
            toView.transform = CGAffineTransformIdentity;
            toView.alpha = 1;
            switch (self.style) {
                case A2TransitionStyleSheet:
                    fromView.frame = CGRectMake(0, h, w, h);
                    break;
                case A2TransitionStylePush:
                    fromView.frame = CGRectMake(w, 0, w, h);
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
@end

@implementation A2NavigationController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.delegate = self;
    // 用自绘顶栏，隐藏系统导航栏
    self.navigationBarHidden = YES;
    self.view.backgroundColor = A2ThemeManager.shared.scheme.cSurface;
    // 保留边缘返回手势
    self.interactivePopGestureRecognizer.enabled = YES;
    self.interactivePopGestureRecognizer.delegate = nil;
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
    self.pendingStyle = style;
    self.hasPendingStyle = YES;
    [self pushViewController:viewController animated:animated];
}

#pragma mark - UINavigationControllerDelegate

- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)nc
                                  animationControllerForOperation:(UINavigationControllerOperation)operation
                                               fromViewController:(UIViewController *)fromVC
                                                 toViewController:(UIViewController *)toVC {
    A2TransitionAnimator *a = [A2TransitionAnimator new];
    a.isPresenting = (operation == UINavigationControllerOperationPush);

    if (a.isPresenting) {
        a.style = self.hasPendingStyle ? self.pendingStyle : A2TransitionStyleScaleFade;
        self.hasPendingStyle = NO;
    } else {
        a.style = A2TransitionStyleScaleFade;
    }
    return a;
}

@end
