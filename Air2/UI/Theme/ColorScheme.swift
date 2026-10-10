//
//  ColorScheme.swift
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
//  MD3 语义色板（Swift）。
//
//  设计决策（沿用 ObjC 版）：不用动态颜色解析。
//  每个色槽同时持有亮 / 暗两套具体值，视图按 isDark 取用，
//  结果完全可预测，不受 trait 环境影响。
//  视图层只消费这里的语义角色，不写色值。

import SwiftUI
import UIKit

// MARK: - Hex 基础设施（无字面量，字面量只出现在 BuiltinThemes 种子表）

public extension Color {
    /// 0xRRGGBB → Color。sRGB。
    init(hexRGB: UInt32, opacity: Double = 1.0) {
        let r = Double((hexRGB >> 16) & 0xFF) / 255.0
        let g = Double((hexRGB >> 8) & 0xFF) / 255.0
        let b = Double(hexRGB & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// 取 0xRRGGBB（持久化自定义种子色用）。
    var rgbValue: UInt32 {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0x808080 }
        return (UInt32(lround(Double(r) * 255)) << 16)
            | (UInt32(lround(Double(g) * 255)) << 8)
            | UInt32(lround(Double(b) * 255))
    }

    /// 同色相重建（饱和度 / 亮度替换）。灰阶种子保留一丝饱和度以保层次。
    func tone(saturation: Double, brightness: Double) -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &br, alpha: &a) else {
            return Color(hue: 0, saturation: 0.02, brightness: min(1, max(0, brightness)))
        }
        if s < 0.02 { s = 0.02 }
        return Color(
            hue: Double(h),
            saturation: min(1, max(0, saturation)),
            brightness: min(1, max(0, brightness))
        )
    }

    /// 色相偏移（0~1 环形）。
    func shiftedHue(by delta: Double) -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &br, alpha: &a) else { return self }
        var shifted = (Double(h) + delta).truncatingRemainder(dividingBy: 1.0)
        if shifted < 0 { shifted += 1.0 }
        return Color(hue: shifted, saturation: Double(s), brightness: Double(br))
    }
}

public extension UIColor {
    /// 0xRRGGBB → UIColor。sRGB。
    convenience init(hexRGB: UInt32) {
        self.init(
            red: CGFloat((hexRGB >> 16) & 0xFF) / 255.0,
            green: CGFloat((hexRGB >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hexRGB & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

// MARK: - 单个色槽

/// 一个语义色槽：同时持有亮色与暗色的具体值。
public struct ColorSlot: Sendable {
    public var light: Color
    public var dark: Color

    public init(light: Color, dark: Color) {
        self.light = light
        self.dark = dark
    }

    /// 按模式取具体色值。
    public func color(forDark isDark: Bool) -> Color {
        isDark ? dark : light
    }

    /// UIKit 互操作。
    public func uiColor(forDark isDark: Bool) -> UIColor {
        UIColor(color(forDark: isDark))
    }
}

// MARK: - 色板

/// MD3 语义色板。字段名沿用 ObjC A2ColorScheme 的迁移契约，
/// Components / Screens 直接依赖这套角色名。
public struct ColorScheme: Sendable {
    // MARK: 主色
    public var primary: ColorSlot
    public var onPrimary: ColorSlot
    public var primaryContainer: ColorSlot
    public var onPrimaryContainer: ColorSlot

    // MARK: 次要色
    public var secondary: ColorSlot
    public var onSecondary: ColorSlot
    public var secondaryContainer: ColorSlot
    public var onSecondaryContainer: ColorSlot

    // MARK: 第三色
    public var tertiary: ColorSlot
    public var tertiaryContainer: ColorSlot

    // MARK: 表面
    public var surface: ColorSlot
    public var onSurface: ColorSlot
    public var surfaceContainerLowest: ColorSlot
    public var surfaceContainerLow: ColorSlot
    public var surfaceContainer: ColorSlot
    public var surfaceContainerHigh: ColorSlot
    public var surfaceContainerHighest: ColorSlot
    public var surfaceVariant: ColorSlot
    public var onSurfaceVariant: ColorSlot

    // MARK: 描边
    public var outline: ColorSlot
    public var outlineVariant: ColorSlot

    // MARK: 语义
    public var error: ColorSlot
    public var onError: ColorSlot
    public var errorContainer: ColorSlot
    public var onErrorContainer: ColorSlot
    public var success: ColorSlot
    public var onSuccess: ColorSlot
    public var successContainer: ColorSlot
    public var onSuccessContainer: ColorSlot
    /// 兼容旧字段：告警色。
    public var warning: ColorSlot

    // MARK: 反色
    public var inverseSurface: ColorSlot
    public var inverseOnSurface: ColorSlot
    public var inversePrimary: ColorSlot

    public init(
        primary: ColorSlot,
        onPrimary: ColorSlot,
        primaryContainer: ColorSlot,
        onPrimaryContainer: ColorSlot,
        secondary: ColorSlot,
        onSecondary: ColorSlot,
        secondaryContainer: ColorSlot,
        onSecondaryContainer: ColorSlot,
        tertiary: ColorSlot,
        tertiaryContainer: ColorSlot,
        surface: ColorSlot,
        onSurface: ColorSlot,
        surfaceContainerLowest: ColorSlot,
        surfaceContainerLow: ColorSlot,
        surfaceContainer: ColorSlot,
        surfaceContainerHigh: ColorSlot,
        surfaceContainerHighest: ColorSlot,
        surfaceVariant: ColorSlot,
        onSurfaceVariant: ColorSlot,
        outline: ColorSlot,
        outlineVariant: ColorSlot,
        error: ColorSlot,
        onError: ColorSlot,
        errorContainer: ColorSlot,
        onErrorContainer: ColorSlot,
        success: ColorSlot,
        onSuccess: ColorSlot,
        successContainer: ColorSlot,
        onSuccessContainer: ColorSlot,
        warning: ColorSlot,
        inverseSurface: ColorSlot,
        inverseOnSurface: ColorSlot,
        inversePrimary: ColorSlot
    ) {
        self.primary = primary
        self.onPrimary = onPrimary
        self.primaryContainer = primaryContainer
        self.onPrimaryContainer = onPrimaryContainer
        self.secondary = secondary
        self.onSecondary = onSecondary
        self.secondaryContainer = secondaryContainer
        self.onSecondaryContainer = onSecondaryContainer
        self.tertiary = tertiary
        self.tertiaryContainer = tertiaryContainer
        self.surface = surface
        self.onSurface = onSurface
        self.surfaceContainerLowest = surfaceContainerLowest
        self.surfaceContainerLow = surfaceContainerLow
        self.surfaceContainer = surfaceContainer
        self.surfaceContainerHigh = surfaceContainerHigh
        self.surfaceContainerHighest = surfaceContainerHighest
        self.surfaceVariant = surfaceVariant
        self.onSurfaceVariant = onSurfaceVariant
        self.outline = outline
        self.outlineVariant = outlineVariant
        self.error = error
        self.onError = onError
        self.errorContainer = errorContainer
        self.onErrorContainer = onErrorContainer
        self.success = success
        self.onSuccess = onSuccess
        self.successContainer = successContainer
        self.onSuccessContainer = onSuccessContainer
        self.warning = warning
        self.inverseSurface = inverseSurface
        self.inverseOnSurface = inverseOnSurface
        self.inversePrimary = inversePrimary
    }

    /// 生成「已按模式解析」的快照：视图取色一次，之后全从快照读具体值。
    public func resolved(isDark: Bool) -> ResolvedColorScheme {
        ResolvedColorScheme(scheme: self, isDark: isDark)
    }
}

// MARK: - 已解析快照

/// 按亮暗解析后的具体色值集合。视图层持有它，不再判断模式。
public struct ResolvedColorScheme: Sendable {
    public let isDark: Bool

    public let primary: Color
    public let onPrimary: Color
    public let primaryContainer: Color
    public let onPrimaryContainer: Color
    public let secondary: Color
    public let onSecondary: Color
    public let secondaryContainer: Color
    public let onSecondaryContainer: Color
    public let tertiary: Color
    public let tertiaryContainer: Color
    public let surface: Color
    public let onSurface: Color
    public let surfaceContainerLowest: Color
    public let surfaceContainerLow: Color
    public let surfaceContainer: Color
    public let surfaceContainerHigh: Color
    public let surfaceContainerHighest: Color
    public let surfaceVariant: Color
    public let onSurfaceVariant: Color
    public let outline: Color
    public let outlineVariant: Color
    public let error: Color
    public let onError: Color
    public let errorContainer: Color
    public let onErrorContainer: Color
    public let success: Color
    public let onSuccess: Color
    public let successContainer: Color
    public let onSuccessContainer: Color
    public let warning: Color
    public let inverseSurface: Color
    public let inverseOnSurface: Color
    public let inversePrimary: Color

    init(scheme: ColorScheme, isDark: Bool) {
        self.isDark = isDark
        primary = scheme.primary.color(forDark: isDark)
        onPrimary = scheme.onPrimary.color(forDark: isDark)
        primaryContainer = scheme.primaryContainer.color(forDark: isDark)
        onPrimaryContainer = scheme.onPrimaryContainer.color(forDark: isDark)
        secondary = scheme.secondary.color(forDark: isDark)
        onSecondary = scheme.onSecondary.color(forDark: isDark)
        secondaryContainer = scheme.secondaryContainer.color(forDark: isDark)
        onSecondaryContainer = scheme.onSecondaryContainer.color(forDark: isDark)
        tertiary = scheme.tertiary.color(forDark: isDark)
        tertiaryContainer = scheme.tertiaryContainer.color(forDark: isDark)
        surface = scheme.surface.color(forDark: isDark)
        onSurface = scheme.onSurface.color(forDark: isDark)
        surfaceContainerLowest = scheme.surfaceContainerLowest.color(forDark: isDark)
        surfaceContainerLow = scheme.surfaceContainerLow.color(forDark: isDark)
        surfaceContainer = scheme.surfaceContainer.color(forDark: isDark)
        surfaceContainerHigh = scheme.surfaceContainerHigh.color(forDark: isDark)
        surfaceContainerHighest = scheme.surfaceContainerHighest.color(forDark: isDark)
        surfaceVariant = scheme.surfaceVariant.color(forDark: isDark)
        onSurfaceVariant = scheme.onSurfaceVariant.color(forDark: isDark)
        outline = scheme.outline.color(forDark: isDark)
        outlineVariant = scheme.outlineVariant.color(forDark: isDark)
        error = scheme.error.color(forDark: isDark)
        onError = scheme.onError.color(forDark: isDark)
        errorContainer = scheme.errorContainer.color(forDark: isDark)
        onErrorContainer = scheme.onErrorContainer.color(forDark: isDark)
        success = scheme.success.color(forDark: isDark)
        onSuccess = scheme.onSuccess.color(forDark: isDark)
        successContainer = scheme.successContainer.color(forDark: isDark)
        onSuccessContainer = scheme.onSuccessContainer.color(forDark: isDark)
        warning = scheme.warning.color(forDark: isDark)
        inverseSurface = scheme.inverseSurface.color(forDark: isDark)
        inverseOnSurface = scheme.inverseOnSurface.color(forDark: isDark)
        inversePrimary = scheme.inversePrimary.color(forDark: isDark)
    }

    /// UIKit 互操作：按 keyPath 取 UIColor。
    public func uiColor(_ keyPath: KeyPath<ResolvedColorScheme, Color>) -> UIColor {
        UIColor(self[keyPath: keyPath])
    }
}

// MARK: - SwiftUI 环境注入

private struct ResolvedSchemeKey: EnvironmentKey {
    static let defaultValue: ResolvedColorScheme = BuiltinThemes.embermire.scheme.resolved(isDark: false)
}

public extension EnvironmentValues {
    /// 当前解析后的语义色板。视图只从这里取色，不判断亮暗。
    var colorScheme: ResolvedColorScheme {
        get { self[ResolvedSchemeKey.self] }
        set { self[ResolvedSchemeKey.self] = newValue }
    }
}
