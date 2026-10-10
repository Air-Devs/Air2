//
//  Typography.swift
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
//  字体阶梯：系统字体 + M3 type scale 的字号 / 行高 / 字重，
//  不引入自定义字体。全部支持 Dynamic Type。

import SwiftUI
import UIKit

// MARK: - M3 Type 角色

/// M3 type scale（字号 / 字重 / 相对行高），iOS 落地用系统字体。
public enum TypeRole {
    case displayLarge
    case displayMedium
    case displaySmall
    case headlineLarge
    case headlineMedium
    case headlineSmall
    case titleLarge
    case titleMedium
    case titleSmall
    case bodyLarge
    case bodyMedium
    case bodySmall
    case labelLarge
    case labelMedium
    case labelSmall

    var size: CGFloat {
        switch self {
        case .displayLarge: return 57
        case .displayMedium: return 45
        case .displaySmall: return 36
        case .headlineLarge: return 32
        case .headlineMedium: return 28
        case .headlineSmall: return 24
        case .titleLarge: return 22
        case .titleMedium: return 16
        case .titleSmall: return 14
        case .bodyLarge: return 16
        case .bodyMedium: return 14
        case .bodySmall: return 12
        case .labelLarge: return 14
        case .labelMedium: return 12
        case .labelSmall: return 11
        }
    }

    var weight: Font.Weight {
        switch self {
        case .displayLarge, .displayMedium, .displaySmall: return .regular
        case .headlineLarge, .headlineMedium, .headlineSmall: return .semibold
        case .titleLarge: return .bold
        case .titleMedium, .labelLarge: return .semibold
        case .titleSmall: return .medium
        case .bodyLarge, .bodyMedium, .bodySmall: return .regular
        case .labelMedium, .labelSmall: return .medium
        }
    }

    /// 相对行高（M3 规范行高 / 字号）。
    var lineHeightMultiple: CGFloat {
        switch self {
        case .displayLarge: return 64 / 57
        case .displayMedium: return 52 / 45
        case .displaySmall: return 44 / 36
        case .headlineLarge: return 40 / 32
        case .headlineMedium: return 36 / 28
        case .headlineSmall: return 32 / 24
        case .titleLarge: return 28 / 22
        case .titleMedium: return 24 / 16
        case .titleSmall: return 20 / 14
        case .bodyLarge: return 24 / 16
        case .bodyMedium: return 20 / 14
        case .bodySmall: return 16 / 12
        case .labelLarge: return 20 / 14
        case .labelMedium: return 16 / 12
        case .labelSmall: return 16 / 11
        }
    }

    /// SwiftUI 字体（系统字体，Dynamic Type 自动缩放）。
    public var font: Font {
        .system(size: size, weight: weight)
    }

    /// UIKit 字体（Dynamic Type 缩放）。
    public var uiFont: UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: uiWeight)
        return UIFontMetrics.default.scaledFont(for: base)
    }

    private var uiWeight: UIFont.Weight {
        switch weight {
        case .bold: return .bold
        case .semibold: return .semibold
        case .medium: return .medium
        default: return .regular
        }
    }
}

public extension Font {
    static let displayLarge = TypeRole.displayLarge.font
    static let displayMedium = TypeRole.displayMedium.font
    static let displaySmall = TypeRole.displaySmall.font
    static let headlineLarge = TypeRole.headlineLarge.font
    static let headlineMedium = TypeRole.headlineMedium.font
    static let headlineSmall = TypeRole.headlineSmall.font
    static let m3TitleLarge = TypeRole.titleLarge.font
    static let titleMedium = TypeRole.titleMedium.font
    static let titleSmall = TypeRole.titleSmall.font
    static let bodyLarge = TypeRole.bodyLarge.font
    static let bodyMedium = TypeRole.bodyMedium.font
    static let bodySmall = TypeRole.bodySmall.font
    static let labelLarge = TypeRole.labelLarge.font
    static let labelMedium = TypeRole.labelMedium.font
    static let labelSmall = TypeRole.labelSmall.font
}

// MARK: - 旧名兼容（迁移期别名，对应 ObjC A2Typography）

public enum Typography {
    /// 大标题：页面主标题。→ headlineSmall(24/semibold)
    public static var titleLarge: Font { TypeRole.headlineSmall.font }
    /// 卡片标题。→ titleMedium(16/semibold)
    public static var titleCard: Font { TypeRole.titleMedium.font }
    /// 卡片副标题 / 次要信息。→ bodySmall(12/regular)
    public static var subtitleCard: Font { TypeRole.bodySmall.font }
    /// 正文。→ bodyLarge(15→16/regular)
    public static var body: Font { TypeRole.bodyLarge.font }
    /// 说明文字。→ labelSmall(11/medium)
    public static var caption: Font { TypeRole.labelSmall.font }
    /// 按钮文字。→ labelLarge(14/semibold)
    public static var button: Font { TypeRole.labelLarge.font }

    /// 数字强调（进度、大小、时长）：等宽数字，避免跳动。
    public static func numeric(size: CGFloat = 13, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// UIKit 兼容。
    public static func uiTitleLarge() -> UIFont { TypeRole.headlineSmall.uiFont }
    public static func uiTitleCard() -> UIFont { TypeRole.titleMedium.uiFont }
    public static func uiSubtitleCard() -> UIFont { TypeRole.bodySmall.uiFont }
    public static func uiBody() -> UIFont { TypeRole.bodyLarge.uiFont }
    public static func uiCaption() -> UIFont { TypeRole.labelSmall.uiFont }
    public static func uiButton() -> UIFont { TypeRole.labelLarge.uiFont }
    public static func uiNumeric(size: CGFloat = 13, weight: UIFont.Weight = .medium) -> UIFont {
        let base = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return UIFontMetrics.default.scaledFont(for: base)
    }
}
