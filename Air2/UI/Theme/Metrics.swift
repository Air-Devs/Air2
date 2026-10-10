//
//  Metrics.swift
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
//  尺寸常量：4pt 网格 + MD3 形状阶梯。视图只读这里，不硬编码数字。

import Foundation

public enum Metrics {
    // MARK: - 间距（4pt 网格）

    public static let spaceXS: CGFloat = 4
    public static let spaceS: CGFloat = 8
    public static let spaceM: CGFloat = 12
    public static let spaceL: CGFloat = 16
    public static let spaceXL: CGFloat = 24
    public static let spaceXXL: CGFloat = 32

    /// 卡片内边距。
    public static let cardPadding: CGFloat = 16
    /// 卡片间距。
    public static let cardSpacing: CGFloat = 12
    /// 操作区相对屏幕的外边距。
    public static let panelOuterPadding: CGFloat = 12
    /// 二级页面左右安全边距（无卡片包裹，需要更多呼吸空间）。
    public static let pageMargin: CGFloat = 16

    /// 二级页面内容最大宽度。横屏下限制行宽，接近纸质文档舒适行宽。
    public static let contentMaxWidth: CGFloat = 680

    // MARK: - 圆角（只用这五档，圆形与胶囊除外）

    public static let radiusXS: CGFloat = 4
    public static let radiusS: CGFloat = 8
    public static let radiusM: CGFloat = 12
    public static let radiusL: CGFloat = 16
    public static let radiusXL: CGFloat = 28

    // MARK: - 高度

    public static let topBarHeight: CGFloat = 52
    public static let buttonHeight: CGFloat = 52
    public static let minTouchTarget: CGFloat = 44

    // MARK: - 头像

    public static let avatarLarge: CGFloat = 64
    public static let avatarSmall: CGFloat = 48

    // MARK: - 布局划分

    /// 右侧操作栏宽度：`min(400, 屏宽 × 0.38)`。
    public static func panelWidth(for screenWidth: CGFloat) -> CGFloat {
        min(400, screenWidth * 0.38)
    }

    /// 屏幕高度达到该值时可用更宽松的布局。
    public static let tallLayoutThreshold: CGFloat = 600
}
