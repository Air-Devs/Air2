//
//  BuiltinThemes.swift
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
//  内置主题与种子色推导。
//
//  约定：整个 Theme 层只有本文件的种子表允许出现十六进制字面量，
//  组件代码一律消费语义角色，不写色值。

import SwiftUI
import UIKit

// MARK: - 主题种类

public enum ThemeKind: Int, CaseIterable, Sendable {
    case embermire = 0
    case glacier
    case verdantDawn
    case velvetRose
    case urbanAsh
    case dynamic
    case custom
}

// MARK: - 配色风格（MD3 PaletteStyle）

public enum PaletteStyle: Int, CaseIterable, Sendable {
    case tonalSpot = 0
    case neutral
    case vibrant
    case expressive

    public var displayName: String {
        switch self {
        case .tonalSpot: return "TonalSpot"
        case .neutral: return "Neutral"
        case .vibrant: return "Vibrant"
        case .expressive: return "Expressive"
        }
    }

    public var description: String {
        switch self {
        case .tonalSpot: return "中性均衡，MD3 默认"
        case .neutral: return "极低饱和，接近灰阶"
        case .vibrant: return "高饱和，色彩强烈"
        case .expressive: return "色相偏移更大，更活泼"
        }
    }
}

struct PaletteParams {
    var saturationScale: Double
    var saturationCap: Double
    var surfaceTint: Double
    var tertiaryHueShift: Double
    var containerBrightnessShift: Double

    static func forStyle(_ style: PaletteStyle) -> PaletteParams {
        switch style {
        case .neutral:
            return PaletteParams(
                saturationScale: 0.35, saturationCap: 0.22,
                surfaceTint: 0.12, tertiaryHueShift: 0.25,
                containerBrightnessShift: -0.01
            )
        case .vibrant:
            return PaletteParams(
                saturationScale: 1.45, saturationCap: 0.95,
                surfaceTint: 1.15, tertiaryHueShift: 0.33,
                containerBrightnessShift: 0.01
            )
        case .expressive:
            return PaletteParams(
                saturationScale: 1.2, saturationCap: 0.85,
                surfaceTint: 0.9, tertiaryHueShift: 0.48,
                containerBrightnessShift: 0.03
            )
        case .tonalSpot:
            return PaletteParams(
                saturationScale: 1.0, saturationCap: 0.75,
                surfaceTint: 0.6, tertiaryHueShift: 0.33,
                containerBrightnessShift: 0.0
            )
        }
    }
}

// MARK: - 中间结构

/// 推导过程中的单模式色板，最后配对成 ColorSlot。
public struct RawScheme {
    var primary = Color.clear
    var onPrimary = Color.clear
    var primaryContainer = Color.clear
    var onPrimaryContainer = Color.clear
    var secondary = Color.clear
    var onSecondary = Color.clear
    var secondaryContainer = Color.clear
    var onSecondaryContainer = Color.clear
    var tertiary = Color.clear
    var tertiaryContainer = Color.clear
    var surface = Color.clear
    var onSurface = Color.clear
    var surfaceContainerLowest = Color.clear
    var surfaceContainerLow = Color.clear
    var surfaceContainer = Color.clear
    var surfaceContainerHigh = Color.clear
    var surfaceContainerHighest = Color.clear
    var surfaceVariant = Color.clear
    var onSurfaceVariant = Color.clear
    var outline = Color.clear
    var outlineVariant = Color.clear
    var error = Color.clear
    var onError = Color.clear
    var errorContainer = Color.clear
    var onErrorContainer = Color.clear
    var success = Color.clear
    var onSuccess = Color.clear
    var successContainer = Color.clear
    var onSuccessContainer = Color.clear
    var warning = Color.clear
    var inverseSurface = Color.clear
    var inverseOnSurface = Color.clear
    var inversePrimary = Color.clear
}

/// 由种子色推导单模式色板。明度阶梯参考 MD3 tonal palette 常用档位。
/// 规范用 HCT，这里用 HSB 近似（实现成本低，视觉接近）。
func fillScheme(_ s: inout RawScheme, seed: Color, light: Bool, params: PaletteParams) {
    func cappedSat(_ sat: Double) -> Double {
        min(params.saturationCap, sat * params.saturationScale)
    }

    if light {
        s.primary = seed.tone(saturation: cappedSat(0.72), brightness: 0.48)
        s.onPrimary = Color.white
        s.primaryContainer = seed.tone(saturation: 0.34, brightness: 0.92)
        s.onPrimaryContainer = seed.tone(saturation: 0.66, brightness: 0.24)

        s.secondary = seed.tone(saturation: 0.30, brightness: 0.40)
        s.onSecondary = Color.white
        s.secondaryContainer = seed.tone(saturation: 0.20, brightness: 0.90)
        s.onSecondaryContainer = seed.tone(saturation: 0.38, brightness: 0.26)

        let t3 = seed.shiftedHue(by: params.tertiaryHueShift)
        s.tertiary = t3.tone(saturation: 0.42, brightness: 0.42)
        s.tertiaryContainer = t3.tone(saturation: 0.24, brightness: 0.90)

        s.surface = seed.tone(saturation: 0.03 * params.surfaceTint * 3, brightness: 0.985)
        s.onSurface = seed.tone(saturation: 0.16, brightness: 0.12)
        s.surfaceContainerLowest = Color.white
        s.surfaceContainerLow = seed.tone(saturation: 0.05, brightness: 0.965)
        s.surfaceContainer = seed.tone(saturation: 0.07 * params.surfaceTint * 2, brightness: 0.935)
        s.surfaceContainerHigh = seed.tone(saturation: 0.09, brightness: 0.905)
        s.surfaceContainerHighest = seed.tone(saturation: 0.11, brightness: 0.875)
        s.surfaceVariant = seed.tone(saturation: 0.13, brightness: 0.90)
        s.onSurfaceVariant = seed.tone(saturation: 0.24, brightness: 0.32)

        s.outline = seed.tone(saturation: 0.18, brightness: 0.50)
        s.outlineVariant = seed.tone(saturation: 0.15, brightness: 0.78)

        s.inverseSurface = seed.tone(saturation: 0.16, brightness: 0.20)
        s.inverseOnSurface = seed.tone(saturation: 0.07, brightness: 0.94)
        s.inversePrimary = seed.tone(saturation: 0.34, brightness: 0.86)
    } else {
        s.primary = seed.tone(saturation: cappedSat(0.55), brightness: 0.82)
        s.onPrimary = seed.tone(saturation: 0.75, brightness: 0.18)
        s.primaryContainer = seed.tone(saturation: 0.68, brightness: 0.34)
        s.onPrimaryContainer = seed.tone(saturation: 0.34, brightness: 0.92)

        s.secondary = seed.tone(saturation: 0.26, brightness: 0.80)
        s.onSecondary = seed.tone(saturation: 0.40, brightness: 0.20)
        s.secondaryContainer = seed.tone(saturation: 0.30, brightness: 0.30)
        s.onSecondaryContainer = seed.tone(saturation: 0.20, brightness: 0.90)

        let t3 = seed.shiftedHue(by: params.tertiaryHueShift)
        s.tertiary = t3.tone(saturation: 0.34, brightness: 0.80)
        s.tertiaryContainer = t3.tone(saturation: 0.26, brightness: 0.32)

        s.surface = seed.tone(saturation: 0.16 * params.surfaceTint, brightness: 0.09)
        s.onSurface = seed.tone(saturation: 0.07, brightness: 0.92)
        s.surfaceContainerLowest = seed.tone(saturation: 0.18, brightness: 0.05)
        s.surfaceContainerLow = seed.tone(saturation: 0.16, brightness: 0.12)
        s.surfaceContainer = seed.tone(saturation: 0.15 * params.surfaceTint, brightness: 0.15)
        s.surfaceContainerHigh = seed.tone(saturation: 0.14, brightness: 0.19)
        s.surfaceContainerHighest = seed.tone(saturation: 0.13, brightness: 0.23)
        s.surfaceVariant = seed.tone(saturation: 0.18, brightness: 0.27)
        s.onSurfaceVariant = seed.tone(saturation: 0.12, brightness: 0.80)

        s.outline = seed.tone(saturation: 0.12, brightness: 0.58)
        s.outlineVariant = seed.tone(saturation: 0.16, brightness: 0.30)

        s.inverseSurface = seed.tone(saturation: 0.07, brightness: 0.92)
        s.inverseOnSurface = seed.tone(saturation: 0.16, brightness: 0.20)
        s.inversePrimary = seed.tone(saturation: 0.72, brightness: 0.48)
    }
}

/// 把亮 / 暗两个单模式色板配对成 ColorSlot 色板。
func pairScheme(light: RawScheme, dark: RawScheme) -> ColorScheme {
    func slot(_ l: Color, _ d: Color) -> ColorSlot { ColorSlot(light: l, dark: d) }
    return ColorScheme(
        primary: slot(light.primary, dark.primary),
        onPrimary: slot(light.onPrimary, dark.onPrimary),
        primaryContainer: slot(light.primaryContainer, dark.primaryContainer),
        onPrimaryContainer: slot(light.onPrimaryContainer, dark.onPrimaryContainer),
        secondary: slot(light.secondary, dark.secondary),
        onSecondary: slot(light.onSecondary, dark.onSecondary),
        secondaryContainer: slot(light.secondaryContainer, dark.secondaryContainer),
        onSecondaryContainer: slot(light.onSecondaryContainer, dark.onSecondaryContainer),
        tertiary: slot(light.tertiary, dark.tertiary),
        tertiaryContainer: slot(light.tertiaryContainer, dark.tertiaryContainer),
        surface: slot(light.surface, dark.surface),
        onSurface: slot(light.onSurface, dark.onSurface),
        surfaceContainerLowest: slot(light.surfaceContainerLowest, dark.surfaceContainerLowest),
        surfaceContainerLow: slot(light.surfaceContainerLow, dark.surfaceContainerLow),
        surfaceContainer: slot(light.surfaceContainer, dark.surfaceContainer),
        surfaceContainerHigh: slot(light.surfaceContainerHigh, dark.surfaceContainerHigh),
        surfaceContainerHighest: slot(light.surfaceContainerHighest, dark.surfaceContainerHighest),
        surfaceVariant: slot(light.surfaceVariant, dark.surfaceVariant),
        onSurfaceVariant: slot(light.onSurfaceVariant, dark.onSurfaceVariant),
        outline: slot(light.outline, dark.outline),
        outlineVariant: slot(light.outlineVariant, dark.outlineVariant),
        error: slot(light.error, dark.error),
        onError: slot(light.onError, dark.onError),
        errorContainer: slot(light.errorContainer, dark.errorContainer),
        onErrorContainer: slot(light.onErrorContainer, dark.onErrorContainer),
        success: slot(light.success, dark.success),
        onSuccess: slot(light.onSuccess, dark.onSuccess),
        successContainer: slot(light.successContainer, dark.successContainer),
        onSuccessContainer: slot(light.onSuccessContainer, dark.onSuccessContainer),
        warning: slot(light.warning, dark.warning),
        inverseSurface: slot(light.inverseSurface, dark.inverseSurface),
        inverseOnSurface: slot(light.inverseOnSurface, dark.inverseOnSurface),
        inversePrimary: slot(light.inversePrimary, dark.inversePrimary)
    )
}

/// 语义色全主题统一：错误必须是红的，不跟着主色走（跨应用认知一致性）。
func applySemanticColors(light: inout RawScheme, dark: inout RawScheme) {
    light.error = Color(hexRGB: 0xBA1A1A)
    light.onError = Color(hexRGB: 0xFFFFFF)
    light.errorContainer = Color(hexRGB: 0xFFDAD6)
    light.onErrorContainer = Color(hexRGB: 0x410002)
    light.success = Color(hexRGB: 0x2E6B36)
    light.onSuccess = Color(hexRGB: 0xFFFFFF)
    light.successContainer = Color(hexRGB: 0xC8EFC6)
    light.onSuccessContainer = Color(hexRGB: 0x002204)
    light.warning = Color(hexRGB: 0x8A5300)

    dark.error = Color(hexRGB: 0xFFB4AB)
    dark.onError = Color(hexRGB: 0x690005)
    dark.errorContainer = Color(hexRGB: 0x93000A)
    dark.onErrorContainer = Color(hexRGB: 0xFFDAD6)
    dark.success = Color(hexRGB: 0x8ED88E)
    dark.onSuccess = Color(hexRGB: 0x00390F)
    dark.successContainer = Color(hexRGB: 0x0F5220)
    dark.onSuccessContainer = Color(hexRGB: 0xC8EFC6)
    dark.warning = Color(hexRGB: 0xF5C36B)
}

// MARK: - 主题

public struct ColorTheme: Sendable {
    public var kind: ThemeKind
    public var displayName: String
    public var themeDescription: String
    public var scheme: ColorScheme
    public var lightPrimary: Color
    public var darkPrimary: Color
    /// 无自定义背景图时的页面渐变底色。
    public var backgroundGradient: [Color]

    /// 通用构造：种子色 + 风格推导，可手调关键色。
    public static func make(
        seed: Color,
        kind: ThemeKind,
        name: String,
        desc: String,
        gradient: [Color],
        style: PaletteStyle = .tonalSpot,
        lightOverride: ((inout RawScheme) -> Void)? = nil,
        darkOverride: ((inout RawScheme) -> Void)? = nil
    ) -> ColorTheme {
        let params = PaletteParams.forStyle(style)
        var light = RawScheme()
        var dark = RawScheme()
        fillScheme(&light, seed: seed, light: true, params: params)
        fillScheme(&dark, seed: seed, light: false, params: params)
        applySemanticColors(light: &light, dark: &dark)
        lightOverride?(&light)
        darkOverride?(&dark)
        return ColorTheme(
            kind: kind,
            displayName: name,
            themeDescription: desc,
            scheme: pairScheme(light: light, dark: dark),
            lightPrimary: light.primary,
            darkPrimary: dark.primary,
            backgroundGradient: gradient
        )
    }
}

// MARK: - 内置主题种子表（唯一的十六进制字面量位置）

public enum BuiltinThemes {
    public static var embermire: ColorTheme {
        ColorTheme.make(
            seed: Color(hexRGB: 0xA63A17),
            kind: .embermire, name: "烈焰红棕", desc: "暖调，视觉重心强",
            gradient: [
                Color(hexRGB: 0x8B2D0F),
                Color(hexRGB: 0xC4502B),
                Color(hexRGB: 0x4A1A08),
            ],
            lightOverride: {
                $0.primary = Color(hexRGB: 0xA63A17)
                $0.primaryContainer = Color(hexRGB: 0xFFDBD1)
                $0.surface = Color(hexRGB: 0xFFF8F6)
                $0.surfaceContainer = Color(hexRGB: 0xFCEAE5)
                $0.surfaceContainerHigh = Color(hexRGB: 0xF7E3DE)
                $0.onSurface = Color(hexRGB: 0x241916)
                $0.onSurfaceVariant = Color(hexRGB: 0x58423B)
            },
            darkOverride: {
                $0.primary = Color(hexRGB: 0xFFB59F)
                $0.primaryContainer = Color(hexRGB: 0x7F2A05)
                $0.surface = Color(hexRGB: 0x1A110E)
                $0.surfaceContainer = Color(hexRGB: 0x271A16)
                $0.surfaceContainerHigh = Color(hexRGB: 0x33231F)
                $0.onSurface = Color(hexRGB: 0xF1DFDA)
                $0.onSurfaceVariant = Color(hexRGB: 0xDBC2BA)
            }
        )
    }

    public static var glacier: ColorTheme {
        ColorTheme.make(
            seed: Color(hexRGB: 0x00658B),
            kind: .glacier, name: "冰川蓝", desc: "冷调，长时间使用更舒适",
            gradient: [
                Color(hexRGB: 0x004A66),
                Color(hexRGB: 0x0A8FB8),
                Color(hexRGB: 0x002F42),
            ],
            lightOverride: {
                $0.primary = Color(hexRGB: 0x00658B)
                $0.primaryContainer = Color(hexRGB: 0xC2E8FF)
                $0.onPrimaryContainer = Color(hexRGB: 0x001E2E)
            },
            darkOverride: {
                $0.primary = Color(hexRGB: 0x7FD0F5)
                $0.onPrimary = Color(hexRGB: 0x003549)
                $0.primaryContainer = Color(hexRGB: 0x004C6B)
            }
        )
    }

    public static var verdantDawn: ColorTheme {
        ColorTheme.make(
            seed: Color(hexRGB: 0x2C6B36),
            kind: .verdantDawn, name: "青野绿", desc: "自然色，与游戏主题呼应",
            gradient: [
                Color(hexRGB: 0x14501E),
                Color(hexRGB: 0x2E7A3A),
                Color(hexRGB: 0x0A3313),
            ],
            lightOverride: {
                $0.primary = Color(hexRGB: 0x2C6B36)
                $0.primaryContainer = Color(hexRGB: 0xC8EFC6)
                $0.onPrimaryContainer = Color(hexRGB: 0x002204)
            },
            darkOverride: {
                $0.primary = Color(hexRGB: 0x8ED88E)
                $0.onPrimary = Color(hexRGB: 0x00390F)
                $0.primaryContainer = Color(hexRGB: 0x0F5220)
            }
        )
    }

    public static var velvetRose: ColorTheme {
        ColorTheme.make(
            seed: Color(hexRGB: 0x7A3D58),
            kind: .velvetRose, name: "绛紫玫瑰", desc: "柔和，低对比",
            gradient: [
                Color(hexRGB: 0x4E2438),
                Color(hexRGB: 0x8A4A68),
                Color(hexRGB: 0x33172A),
            ],
            lightOverride: {
                $0.primary = Color(hexRGB: 0x7A3D58)
                $0.primaryContainer = Color(hexRGB: 0xFFD8E6)
                $0.onPrimaryContainer = Color(hexRGB: 0x31081F)
            },
            darkOverride: {
                $0.primary = Color(hexRGB: 0xF9B2D2)
                $0.onPrimary = Color(hexRGB: 0x4B1130)
                $0.primaryContainer = Color(hexRGB: 0x622947)
            }
        )
    }

    public static var urbanAsh: ColorTheme {
        ColorTheme.make(
            seed: Color(hexRGB: 0x5E5E5F),
            kind: .urbanAsh, name: "都市灰", desc: "中性无彩，专注场景",
            gradient: [
                Color(hexRGB: 0x3A3A3C),
                Color(hexRGB: 0x5A5A5D),
                Color(hexRGB: 0x28282A),
            ],
            lightOverride: {
                $0.primary = Color(hexRGB: 0x5E5E5F)
                $0.primaryContainer = Color(hexRGB: 0xE4E2E2)
                $0.onPrimaryContainer = Color(hexRGB: 0x1B1B1C)
            },
            darkOverride: {
                $0.primary = Color(hexRGB: 0xC7C6C6)
                $0.onPrimary = Color(hexRGB: 0x2F3131)
                $0.primaryContainer = Color(hexRGB: 0x454747)
            }
        )
    }

    public static var allThemes: [ColorTheme] {
        [embermire, glacier, verdantDawn, velvetRose, urbanAsh]
    }

    public static func theme(for kind: ThemeKind) -> ColorTheme {
        switch kind {
        case .embermire: return embermire
        case .glacier: return glacier
        case .verdantDawn: return verdantDawn
        case .velvetRose: return velvetRose
        case .urbanAsh: return urbanAsh
        case .dynamic, .custom:
            // 需要外部种子或背景图才能构造，回落默认，由 ThemeManager 覆盖。
            return glacier
        }
    }

    /// 从种子色 + 配色风格构造主题（颜色主题弹窗用）。
    public static func theme(
        seedColor: Color,
        style: PaletteStyle,
        name: String,
        desc: String
    ) -> ColorTheme {
        let params = PaletteParams.forStyle(style)
        var light = RawScheme()
        var dark = RawScheme()
        fillScheme(&light, seed: seedColor, light: true, params: params)
        fillScheme(&dark, seed: seedColor, light: false, params: params)
        applySemanticColors(light: &light, dark: &dark)
        let cap = min(1.0, params.saturationCap * 1.1)
        let cap2 = min(1.0, params.saturationCap * 1.15)
        return ColorTheme(
            kind: .custom,
            displayName: name,
            themeDescription: desc,
            scheme: pairScheme(light: light, dark: dark),
            lightPrimary: light.primary,
            darkPrimary: dark.primary,
            backgroundGradient: [
                seedColor.tone(saturation: cap, brightness: 0.34),
                seedColor,
                seedColor.tone(saturation: cap2, brightness: 0.16),
            ]
        )
    }

    /// 从背景图提取种子色并构造动态主题。
    /// 缩到 1x1 取平均色：快且天然抗噪；灰阶图给饱和度下限 + 亮度钳制。
    public static func theme(from image: UIImage) -> ColorTheme {
        guard let seed = Self.averageColor(of: image) else { return glacier }
        let uiSeed = UIColor(seed)
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        uiSeed.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
        if s < 0.15 { s = 0.15 + s * 0.5 }
        if br < 0.30 { br = 0.30 }
        if br > 0.80 { br = 0.80 }
        let normalized = Color(hue: Double(h), saturation: Double(s), brightness: Double(br))
        return ColorTheme.make(
            seed: normalized,
            kind: .dynamic, name: "动态取色", desc: "从自定义背景提取主色",
            gradient: [
                normalized.tone(saturation: min(1.0, Double(s) * 1.1), brightness: max(0.22, Double(br) * 0.55)),
                normalized,
                normalized.tone(saturation: min(1.0, Double(s) * 1.15), brightness: max(0.12, Double(br) * 0.30)),
            ]
        )
    }

    private static func averageColor(of image: UIImage) -> Color? {
        let size = CGSize(width: 1, height: 1)
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: size))
        guard
            let averaged = UIGraphicsGetImageFromCurrentImageContext(),
            let cg = averaged.cgImage,
            let provider = cg.dataProvider,
            let data = provider.data as Data?,
            data.count >= 4
        else { return nil }
        let r = Double(data[data.startIndex]) / 255.0
        let g = Double(data[data.startIndex + 1]) / 255.0
        let b = Double(data[data.startIndex + 2]) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
