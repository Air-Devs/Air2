//
//  NavigationHost.swift
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
//  自定义导航宿主 —— 承载页面转场动画。
//
//  为什么不用系统默认转场：默认的「从右侧推入」在启动器这种卡片化界面里
//  显得生硬，且横向位移在横屏大屏上视觉跨度太大。
//  三种转场按页面性质选用，默认缩放淡入（同级页面切换）。
//
//  ObjC 侧的老名字（A2NavigationController / A2TransitionStyleScaleFade 等）
//  经 @objc 映射继续有效，调用方无需改动；Swift 侧用新名字。
//

import UIKit

/// 转场样式。ObjC 侧写作 A2TransitionStyle / A2TransitionStyleScaleFade 等。
@objc(A2TransitionStyle)
public enum TransitionStyle: Int {
    /// 缩放淡入（默认）—— 新页从 94% 展开，适合同级页面切换。
    case scaleFade = 0
    /// 从底部滑入 —— 适合模态性质较强的页面（如安装流程）。
    case sheet
    /// 右侧推入 —— 适合层级较深的钻取（如设置 → 子设置）。
    case push
}

// MARK: - 转场动画器

private final class TransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    var isPresenting = true
    var style: TransitionStyle = .scaleFade

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        // 返回比入场稍快：退出是「离开」，停留感要短。
        isPresenting ? Motion.duration : Motion.durationPop
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let toVC = context.viewController(forKey: .to) else {
            context.completeTransition(true)
            return
        }
        let container = context.containerView
        let fromVC = context.viewController(forKey: .from)
        let fromView = fromVC?.view
        let toView = toVC.view!
        let duration = transitionDuration(using: context)
        let bounds = container.bounds
        let width = bounds.width
        let height = bounds.height

        if isPresenting {
            // ---- 入场 ----
            switch style {
            case .sheet:
                toView.frame = CGRect(x: 0, y: height, width: width, height: height)
            case .push:
                toView.frame = CGRect(x: width, y: 0, width: width, height: height)
            case .scaleFade:
                toView.frame = bounds
                toView.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
                toView.alpha = 0
            }
            container.addSubview(toView)

            // 缩放转场用标准弹簧（有回弹感），位移转场用更稳的软弹簧。
            let animator = style == .scaleFade
                ? Motion.springAnimator(duration: duration)
                : Motion.softSpring(duration: duration)

            animator.addAnimations {
                switch self.style {
                case .sheet:
                    toView.frame = CGRect(x: 0, y: 0, width: width, height: height)
                    fromView?.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
                    fromView?.alpha = 0.72
                case .push:
                    toView.frame = bounds
                    fromView?.transform = CGAffineTransform(translationX: -width * 0.26, y: 0)
                    fromView?.alpha = 0.7
                case .scaleFade:
                    toView.transform = .identity
                    toView.alpha = 1
                    fromView?.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
                    fromView?.alpha = 0.55
                }
            }
            animator.addCompletion { _ in
                fromView?.transform = .identity
                fromView?.alpha = 1
                context.completeTransition(!context.transitionWasCancelled)
            }
            animator.startAnimation()
        } else {
            // ---- 返回 ----
            container.insertSubview(toView, belowSubview: fromView ?? toView)
            toView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            toView.alpha = 0.75

            let animator = Motion.springAnimator(duration: duration)
            animator.addAnimations {
                toView.transform = .identity
                toView.alpha = 1
                switch self.style {
                case .sheet:
                    fromView?.frame = CGRect(x: 0, y: height, width: width, height: height)
                case .push:
                    fromView?.frame = CGRect(x: width, y: 0, width: width, height: height)
                case .scaleFade:
                    fromView?.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
                    fromView?.alpha = 0
                }
            }
            animator.addCompletion { _ in
                fromView?.removeFromSuperview()
                context.completeTransition(!context.transitionWasCancelled)
            }
            animator.startAnimation()
        }
    }
}

// MARK: - 导航宿主

/// 导航控制器。ObjC 侧写作 A2NavigationController。
@objc(A2NavigationController)
public final class NavigationHost: UINavigationController, UINavigationControllerDelegate {
    private var pendingStyle: TransitionStyle = .scaleFade
    private var hasPendingStyle = false

    public override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        // 用自绘顶栏，隐藏系统导航栏。
        isNavigationBarHidden = true
        // 保留边缘返回手势。
        interactivePopGestureRecognizer?.isEnabled = true
        interactivePopGestureRecognizer?.delegate = nil
    }

    public override var prefersStatusBarHidden: Bool { true }

    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    /// 以指定转场样式推入页面。未指定时走默认的缩放淡入。
    public func pushViewController(
        _ viewController: UIViewController,
        transition style: TransitionStyle,
        animated: Bool
    ) {
        pendingStyle = style
        hasPendingStyle = true
        pushViewController(viewController, animated: animated)
    }

    // MARK: UINavigationControllerDelegate

    public func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        let animator = TransitionAnimator()
        animator.isPresenting = operation == .push
        if animator.isPresenting {
            animator.style = hasPendingStyle ? pendingStyle : .scaleFade
            hasPendingStyle = false
        } else {
            animator.style = .scaleFade
        }
        return animator
    }
}
