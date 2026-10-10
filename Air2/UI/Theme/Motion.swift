//
//  Motion.swift
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
//  动效系统：统一弹簧，禁用 ease-in-out。
//  仅有的两个例外是主题交叉淡入（0.45s）与背景切换（0.6s），
//  它们是颜色 / 透明度过渡，不用弹簧——见 UI-DESIGN.md 第五节。

import SwiftUI
import UIKit

public enum Motion {
    // MARK: - 时长

    /// 标准过渡（页面推入缩放淡入）。
    public static let duration: TimeInterval = 0.38
    /// 快速反馈（按压、高亮、主按钮）。
    public static let durationFast: TimeInterval = 0.18
    /// 主按钮点击。
    public static let durationTap: TimeInterval = 0.16
    /// 慢速（背景切换）。
    public static let durationSlow: TimeInterval = 0.6
    /// 卡片入场。
    public static let durationCard: TimeInterval = 0.42
    /// 页面返回。
    public static let durationPop: TimeInterval = 0.34
    /// 开关切换。
    public static let durationToggle: TimeInterval = 0.2
    /// 列表项插入 / 删除。
    public static let durationListMutation: TimeInterval = 0.3
    /// 抽屉展开。
    public static let durationDrawer: TimeInterval = 0.4

    // MARK: - 弹簧参数

    /// 标准阻尼（页面推入）。
    public static let damping: Double = 0.78
    /// 卡片入场阻尼。
    public static let dampingCard: Double = 0.82
    /// 强调操作（启动游戏）回弹更明显。
    public static let dampingExpressive: Double = 0.72
    /// 大面积元素（背景、抽屉）更软。
    public static let dampingSoft: Double = 0.88
    /// 进度弹性跟随。
    public static let dampingProgress: Double = 0.9
    /// 抽屉。
    public static let dampingDrawer: Double = 0.75

    // MARK: - 缩放 / 位移

    /// 页面推入起始缩放。
    public static let pushFromScale: CGFloat = 0.96
    /// 按压缩放（卡片）。
    public static let pressScale: CGFloat = 0.97
    /// 按压缩放（主按钮）。
    public static let pressScalePrimary: CGFloat = 0.96
    /// 卡片入场上浮距离。
    public static let cardEntranceOffset: CGFloat = 16

    /// 卡片入场逐个延迟（35ms，可延长至 50ms）。
    public static let cardStaggerDelay: TimeInterval = 0.035
    public static let cardStaggerDelayMax: TimeInterval = 0.05

    // MARK: - 例外（非弹簧：颜色 / 透明度过渡）

    /// 主题切换：全界面颜色交叉淡入。
    public static let themeCrossfade: TimeInterval = 0.45
    /// 背景切换：交叉淡入 + 轻微缩放。
    public static let backgroundCrossfade: TimeInterval = 0.6

    // MARK: - SwiftUI 动画

    /// 标准弹簧（页面推入 0.38s / damping 0.78）。
    public static var standard: Animation {
        .spring(duration: duration, bounce: 1 - damping)
    }

    /// 卡片入场弹簧（0.42s / damping 0.82）。
    public static var card: Animation {
        .spring(duration: durationCard, bounce: 1 - dampingCard)
    }

    /// 强调弹簧（启动游戏这类操作）。
    public static var expressive: Animation {
        .spring(duration: durationCard, bounce: 1 - dampingExpressive)
    }

    /// 柔和弹簧（大面积元素）。
    public static func soft(duration: TimeInterval = 0.6) -> Animation {
        .spring(duration: duration, bounce: 1 - dampingSoft)
    }

    /// 快速按压反馈。
    public static var press: Animation {
        .spring(duration: durationFast, bounce: 1 - damping)
    }

    /// 带序号的卡片入场延迟。
    public static func cardDelay(index: Int) -> TimeInterval {
        TimeInterval(index) * cardStaggerDelay
    }

    // MARK: - UIKit 动画器（非 SwiftUI 宿主用）

    /// 标准弹簧动画器。
    public static func springAnimator(duration: TimeInterval = Motion.duration) -> UIViewPropertyAnimator {
        let params = UISpringTimingParameters(
            dampingRatio: CGFloat(damping),
            initialVelocity: CGVector(dx: 0, dy: 0.35)
        )
        return UIViewPropertyAnimator(duration: duration, timingParameters: params)
    }

    /// 柔和弹簧（大面积元素）。
    public static func softSpring(duration: TimeInterval = Motion.durationSlow) -> UIViewPropertyAnimator {
        let params = UISpringTimingParameters(
            dampingRatio: CGFloat(dampingSoft),
            initialVelocity: CGVector(dx: 0, dy: 0.1)
        )
        return UIViewPropertyAnimator(duration: duration, timingParameters: params)
    }

    /// 强调弹簧（启动游戏这类操作）。
    public static func expressiveSpring(
        duration: TimeInterval = Motion.durationCard
    ) -> UIViewPropertyAnimator {
        let params = UISpringTimingParameters(
            dampingRatio: CGFloat(dampingExpressive),
            initialVelocity: CGVector(dx: 0, dy: 0.5)
        )
        return UIViewPropertyAnimator(duration: duration, timingParameters: params)
    }

    /// 卡片依次入场：淡入 + 上浮 16pt，错峰启动。
    public static func animateCardEntrance(
        _ views: [UIView],
        staggerDelay: TimeInterval = Motion.cardStaggerDelay,
        completion: (() -> Void)? = nil
    ) {
        guard !views.isEmpty else { return }
        for (i, view) in views.enumerated() {
            view.alpha = 0
            view.transform = CGAffineTransform(translationX: 0, y: cardEntranceOffset)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * staggerDelay) {
                let animator = expressiveSpring(duration: durationCard)
                animator.addAnimations {
                    view.alpha = 1
                    view.transform = .identity
                }
                if i == views.count - 1, let completion {
                    animator.addCompletion { _ in completion() }
                }
                animator.startAnimation()
            }
        }
    }
}

// MARK: - 触觉反馈分级

public enum Haptics {
    /// 轻：选择。→ UISelectionFeedbackGenerator
    public static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// 中：按钮。→ UIImpactFeedbackGenerator(.medium)
    public static func impact() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 成功 / 失败。→ UINotificationFeedbackGenerator
    public static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}
