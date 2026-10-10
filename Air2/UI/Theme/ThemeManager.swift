//
//  ThemeManager.swift
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
//  主题与外观的全局管理。
//  职责边界：持有当前主题与外观模式；广播变更；管理自定义背景。
//  不负责具体视图怎么画。

import SwiftUI
import UIKit

// MARK: - 通知名（字符串保持与 ObjC 版一致，其他层照旧观察）

public extension Notification.Name {
    static let A2ThemeDidChange = Notification.Name("A2ThemeDidChangeNotification")
    static let A2BackgroundDidChange = Notification.Name("A2BackgroundDidChangeNotification")
}

/// ObjC 风格的常量别名（迁移期兼容）。
public let A2ThemeDidChangeNotification = Notification.Name.A2ThemeDidChange
public let A2BackgroundDidChangeNotification = Notification.Name.A2BackgroundDidChange

public enum AppearanceMode: Int, Sendable {
    case system = 0
    case light
    case dark
}

@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()

    private enum Keys {
        static let themeKind = "A2ThemeKind"
        static let appearance = "A2AppearanceMode"
        static let bgBlur = "A2BackgroundBlur"
        static let bgOverlay = "A2BackgroundDarkOverlay"
        static let bgFade = "A2BackgroundFadeRatio"
        static let paletteStyle = "A2PaletteStyle"
        static let customSeed = "A2CustomSeedColor"
        static let backgroundFile = "air2_background.jpg"
    }

    // MARK: - 主题

    /// 当前主题（永不为 nil 语义：总有回落值）。
    @Published public private(set) var theme: ColorTheme = BuiltinThemes.glacier

    /// 当前生效的语义色板：已按 isDark 解析。视图直接取用，不判断模式。
    @Published public private(set) var scheme: ResolvedColorScheme

    @Published public var selectedKind: ThemeKind {
        didSet { guard oldValue != selectedKind else { return }; rebuildAndPublish(themeChanged: true) }
    }

    @Published public var paletteStyle: PaletteStyle {
        didSet { guard oldValue != paletteStyle else { return }; rebuildAndPublish(themeChanged: true) }
    }

    /// 用户自定义的种子色。非 nil 时视为自定义主题，覆盖 selectedKind 预设。
    @Published public var customSeedColor: Color? {
        didSet { rebuildAndPublish(themeChanged: true) }
    }

    // MARK: - 外观

    @Published public var appearanceMode: AppearanceMode {
        didSet { guard oldValue != appearanceMode else { return }; refreshScheme(); persist(); notifyThemeChanged() }
    }

    /// 当前是否为暗色（综合窗口 trait 与用户设置）。
    public var isDark: Bool {
        switch appearanceMode {
        case .light: return false
        case .dark: return true
        case .system: return resolveSystemDark()
        }
    }

    // MARK: - 自定义背景

    /// 用户设置的背景图。nil 表示使用主题 surface 纯色。
    @Published public var backgroundImage: UIImage? {
        didSet {
            if selectedKind == .dynamic { rebuildTheme(); refreshScheme() }
            notifyBackgroundChanged()
            if selectedKind == .dynamic { notifyThemeChanged() }
        }
    }

    /// 背景模糊强度 0~100。
    @Published public var backgroundBlur: Int {
        didSet { backgroundBlur = min(100, max(0, backgroundBlur)); persist(); notifyBackgroundChanged() }
    }

    /// 暗色模式下的遮罩强度 0~1，默认 0.28。
    @Published public var backgroundDarkOverlay: Double {
        didSet { backgroundDarkOverlay = min(1, max(0, backgroundDarkOverlay)); persist(); notifyBackgroundChanged() }
    }

    /// 操作栏一侧渐隐遮罩宽度比例 0~1，默认 0.35。
    @Published public var backgroundFadeRatio: Double {
        didSet { backgroundFadeRatio = min(1, max(0, backgroundFadeRatio)); persist(); notifyBackgroundChanged() }
    }

    // MARK: - init

    private init() {
        let d = UserDefaults.standard
        let kindRaw = d.object(forKey: Keys.themeKind).map { d.integer(forKey: Keys.themeKind) }
            ?? ThemeKind.glacier.rawValue
        let kind = ThemeKind(rawValue: kindRaw) ?? .glacier
        let appearance = AppearanceMode(rawValue: d.integer(forKey: Keys.appearance)) ?? .system
        let style = PaletteStyle(rawValue: d.object(forKey: Keys.paletteStyle).map { d.integer(forKey: Keys.paletteStyle) } ?? 0)
            ?? .tonalSpot

        selectedKind = kind
        appearanceMode = appearance
        paletteStyle = style
        backgroundBlur = d.object(forKey: Keys.bgBlur) != nil ? d.integer(forKey: Keys.bgBlur) : 24
        backgroundDarkOverlay = d.object(forKey: Keys.bgOverlay) != nil ? d.double(forKey: Keys.bgOverlay) : 0.28
        backgroundFadeRatio = d.object(forKey: Keys.bgFade) != nil ? d.double(forKey: Keys.bgFade) : 0.35
        if d.object(forKey: Keys.customSeed) != nil {
            let rgb = UInt32(bitPattern: Int32(d.integer(forKey: Keys.customSeed)))
            customSeedColor = Color(hexRGB: rgb)
        } else {
            customSeedColor = nil
        }
        // 先给一个临时快照，保证所有存储属性初始化完成后再重建。
        scheme = BuiltinThemes.glacier.scheme.resolved(isDark: false)
        backgroundImage = nil
        rebuildTheme()
        backgroundImage = loadPersistedBackground()
        rebuildTheme()
        refreshScheme()
    }

    // MARK: - 主题重建

    private func rebuildTheme() {
        if let seed = customSeedColor {
            theme = BuiltinThemes.theme(
                seedColor: seed, style: paletteStyle,
                name: "自定义", desc: "从色盘选取的种子色"
            )
            return
        }
        if selectedKind == .dynamic, let image = backgroundImage {
            theme = BuiltinThemes.theme(from: image)
        } else if selectedKind == .dynamic {
            theme = BuiltinThemes.theme(for: .glacier)
        } else {
            theme = BuiltinThemes.theme(for: selectedKind)
        }
    }

    private func refreshScheme() {
        scheme = theme.scheme.resolved(isDark: isDark)
    }

    private func rebuildAndPublish(themeChanged: Bool) {
        rebuildTheme()
        refreshScheme()
        persist()
        if themeChanged { notifyThemeChanged() }
    }

    private func resolveSystemDark() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            guard scene.activationState == .foregroundActive
                || scene.activationState == .foregroundInactive
            else { continue }
            if let key = windowScene.windows.first(where: \.isKeyWindow) {
                return key.traitCollection.userInterfaceStyle == .dark
            }
        }
        if let any = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first
        {
            return any.traitCollection.userInterfaceStyle == .dark
        }
        return false
    }

    /// 应用到窗口。
    public func applyAppearance(to window: UIWindow?) {
        guard let window else { return }
        switch appearanceMode {
        case .light: window.overrideUserInterfaceStyle = .light
        case .dark: window.overrideUserInterfaceStyle = .dark
        case .system: window.overrideUserInterfaceStyle = .unspecified
        }
        window.tintColor = UIColor(theme.lightPrimary)
    }

    // MARK: - 背景持久化（沙盒存图，不进 UserDefaults）

    private func backgroundFilePath() -> String? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return docs.appendingPathComponent(Keys.backgroundFile).path
    }

    /// 缩到合理尺寸再存：原图可能好几 MB，界面用不到那么大。
    @discardableResult
    public func persistBackgroundImage(_ image: UIImage) -> Bool {
        guard let path = backgroundFilePath() else { return false }
        var size = image.size
        let maxSide: CGFloat = 2400
        if max(size.width, size.height) > maxSide {
            let scale = maxSide / max(size.width, size.height)
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: size))
        let scaled = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        guard let data = scaled?.jpegData(compressionQuality: 0.88) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func loadPersistedBackground() -> UIImage? {
        guard let path = backgroundFilePath(),
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        return UIImage(contentsOfFile: path)
    }

    public func clearBackgroundImage() {
        if let path = backgroundFilePath() {
            try? FileManager.default.removeItem(atPath: path)
        }
        backgroundImage = nil
        rebuildAndPublish(themeChanged: true)
        notifyBackgroundChanged()
    }

    // MARK: - 持久化与广播

    private func persist() {
        let d = UserDefaults.standard
        d.set(selectedKind.rawValue, forKey: Keys.themeKind)
        d.set(appearanceMode.rawValue, forKey: Keys.appearance)
        d.set(backgroundBlur, forKey: Keys.bgBlur)
        d.set(backgroundDarkOverlay, forKey: Keys.bgOverlay)
        d.set(backgroundFadeRatio, forKey: Keys.bgFade)
        d.set(paletteStyle.rawValue, forKey: Keys.paletteStyle)
        if let seed = customSeedColor {
            d.set(Int(seed.rgbValue), forKey: Keys.customSeed)
        } else {
            d.removeObject(forKey: Keys.customSeed)
        }
    }

    public func notifyThemeChanged() {
        NotificationCenter.default.post(
            name: .A2ThemeDidChange, object: self,
            userInfo: ["theme": theme]
        )
    }

    public func notifyBackgroundChanged() {
        NotificationCenter.default.post(name: .A2BackgroundDidChange, object: self)
    }
}
