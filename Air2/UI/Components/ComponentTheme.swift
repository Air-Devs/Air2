//
//  ComponentTheme.swift
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
//  Shared migration shim for UI/Components Swift rewrite.
//
//  Role: stand-in for the Theme-module Swift APIs (ColorScheme / ThemeManager /
//  Metrics / Typography / Motion) until the Theme agent ships them. Every name
//  mirrors the current ObjC API (cPrimary..., A2Radius*, A2Space*, A2Typography,
//  A2AnimDuration*) so swapping the shim for the real Theme module is mechanical.
//
//  Rules honored here: semantic roles only (no hex anywhere), dark mode free
//  via the environment, touch targets >= 44, spring motion only.
//
//  TODO-MIGRATION: delete this file once Theme provides
//  ColorScheme/ThemeManager/Metrics/Typography/Motion in Swift; expected Theme
//  API names are listed per symbol below. Also route A2ComponentLog through
//  A2Log (Utils) once the bridging header exposes it to Swift.
//

import SwiftUI
import UIKit
import os

// MARK: - Metrics (mirrors A2Metrics.h; TODO-MIGRATION: expected Theme.Metrics)

public let A2SpaceXS: CGFloat = 4
public let A2SpaceS: CGFloat = 8
public let A2SpaceM: CGFloat = 12
public let A2SpaceL: CGFloat = 16
public let A2SpaceXL: CGFloat = 24
public let A2SpaceXXL: CGFloat = 32

public let A2CardPadding: CGFloat = 12
public let A2CardSpacing: CGFloat = 12
public let A2PanelOuterPadding: CGFloat = 12
public let A2PageMargin: CGFloat = 16
public let A2ContentMaxWidth: CGFloat = 680
public let A2PanelWidthRatio: CGFloat = 0.38

public let A2RadiusXS: CGFloat = 4
public let A2RadiusS: CGFloat = 8
public let A2RadiusM: CGFloat = 12
public let A2RadiusL: CGFloat = 16
public let A2RadiusXL: CGFloat = 28

public let A2TopBarHeight: CGFloat = 52
public let A2ButtonHeight: CGFloat = 52
public let A2MinTouchTarget: CGFloat = 44

public let A2AnimDuration: Double = 0.28
public let A2AnimDurationFast: Double = 0.16
public let A2AnimDurationSlow: Double = 0.5
public let A2AnimDurationCard: Double = 0.35
public let A2CardStaggerDelay: Double = 0.05

// MARK: - Typography (mirrors A2Typography; TODO-MIGRATION: expected Theme.Typography)

public enum A2Type {
    public static var titleLarge: Font { .system(size: 22, weight: .bold) }
    public static var titleCard: Font { .system(size: 15, weight: .semibold) }
    public static var subtitleCard: Font { .system(size: 13, weight: .regular) }
    public static var body: Font { .system(size: 15, weight: .regular) }
    public static var caption: Font { .system(size: 12, weight: .regular) }
    public static var button: Font { .system(size: 15, weight: .semibold) }
    public static var numeric: Font { .system(size: 13, weight: .medium).monospacedDigit() }
    public static var sectionTitle: Font { .system(size: 13, weight: .semibold) }
    public static var labelSmall: Font { .system(size: 11, weight: .medium) }
}

// MARK: - Color roles (mirrors A2ColorScheme c* snapshot; TODO-MIGRATION: expected Theme.ColorScheme)
// Every role is semantic and resolves per environment, so dark mode is free.
// SwiftUI resolves dynamic UIColors per-environment at render time, which is
// exactly what the ObjC applyTheme timing bug forbade over there.
//
// Declared on ShapeStyle (constrained to Color) rather than on Color so the
// roles resolve BOTH as explicit Color members (Color.cOnSurface, [Color]
// literals, .background(Color.cX, in:)) AND as leading-dot styles
// (.foregroundStyle(.cOnSurface)). A plain `extension Color` is invisible to
// leading-dot lookup against generic ShapeStyle parameters, which is why
// .foregroundStyle(.cX) failed with "type 'ShapeStyle' has no member".

public extension ShapeStyle where Self == Color {
    static var cPrimary: Color { .accentColor }
    static var cOnPrimary: Color { .white }
    static var cPrimaryContainer: Color { .accentColor.opacity(0.18) }
    static var cOnPrimaryContainer: Color { .accentColor }
    static var cSecondary: Color { .secondary }
    static var cOnSecondary: Color { Color(uiColor: .systemBackground) }
    static var cSecondaryContainer: Color { Color(uiColor: .secondarySystemFill) }
    static var cOnSecondaryContainer: Color { Color(uiColor: .label) }
    static var cTertiary: Color { .teal }
    static var cTertiaryContainer: Color { .teal.opacity(0.18) }
    static var cSurface: Color { Color(uiColor: .systemBackground) }
    static var cOnSurface: Color { Color(uiColor: .label) }
    static var cSurfaceContainerLowest: Color { Color(uiColor: .systemBackground) }
    static var cSurfaceContainerLow: Color { Color(uiColor: .secondarySystemBackground) }
    static var cSurfaceContainer: Color { Color(uiColor: .secondarySystemBackground) }
    static var cSurfaceContainerHigh: Color { Color(uiColor: .tertiarySystemBackground) }
    static var cSurfaceContainerHighest: Color { Color(uiColor: .systemGroupedBackground) }
    static var cSurfaceVariant: Color { Color(uiColor: .systemGroupedBackground) }
    static var cOnSurfaceVariant: Color { .secondary }
    static var cOutline: Color { Color(uiColor: .separator) }
    static var cOutlineVariant: Color { Color(uiColor: .opaqueSeparator).opacity(0.6) }
    static var cError: Color { .red }
    static var cOnError: Color { .white }
    static var cErrorContainer: Color { .red.opacity(0.15) }
    static var cOnErrorContainer: Color { .red }
    static var cSuccess: Color { .green }
    static var cWarning: Color { .orange }
    static var cInverseSurface: Color { Color(uiColor: .label) }
    static var cInverseOnSurface: Color { Color(uiColor: .systemBackground) }
    static var cInversePrimary: Color { .accentColor }
}

// MARK: - Motion (mirrors A2SpringAnimator family; TODO-MIGRATION: expected Theme.Motion)

public extension Animation {
    /// Fast press feedback. Spring only; ease-in-out is banned on iOS feel grounds.
    static var a2Press: Animation { .spring(response: 0.28, dampingFraction: 0.75) }
    static var a2Standard: Animation { .spring(response: 0.32, dampingFraction: 0.82) }
    static var a2Soft: Animation { .spring(response: 0.45, dampingFraction: 0.85) }
}

// MARK: - Logger

/// Component-level log. Call sites use this on every fallback branch to record WHY.
/// TODO-MIGRATION: route through A2Log (Utils) once the bridging header exposes
/// it to Swift; signature intentionally matches A2Log +log: message semantics.
public func A2ComponentLog(_ message: String) {
    Logger(subsystem: "Air2", category: "UI").info("\(message, privacy: .public)")
}

// MARK: - Shared press style (scale 0.96–0.97, spring, haptic)

/// ButtonStyle giving every tappable card/button identical press physics.
public struct A2PressButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.a2Press, value: configuration.isPressed)
    }
}

// MARK: - SF Symbol container (symbols never appear bare)

/// Every SF Symbol in Components renders inside this tonal container.
public struct A2Symbol: View {
    public let name: String
    public var pointSize: CGFloat
    public init(_ name: String, pointSize: CGFloat = 17) {
        self.name = name
        self.pointSize = pointSize
    }
    public var body: some View {
        Image(systemName: name)
            .font(.system(size: pointSize, weight: .medium))
            .foregroundStyle(Color.cPrimary)
            .frame(width: 34, height: 34)
            .background(Color.cPrimaryContainer, in: RoundedRectangle(cornerRadius: A2RadiusS, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Remote icon phase (unified loader contract; networking stays in Core)

/// Owner (backed by a Core service) drives this phase; the View only renders.
/// Tri-states: empty (no URL) / loading / loaded / failed + retry.
public enum A2RemotePhase: Equatable {
    case empty
    case loading(URL)
    case loaded(URL, UIImage)
    case failed(URL)
}

public struct A2RemoteIcon: View {
    public let phase: A2RemotePhase
    public var size: CGFloat
    public var onRetry: (() -> Void)?
    public init(phase: A2RemotePhase, size: CGFloat = 34, onRetry: (() -> Void)? = nil) {
        self.phase = phase
        self.size = size
        self.onRetry = onRetry
    }
    public var body: some View {
        Group {
            switch phase {
            case .empty:
                Image(systemName: "cube.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.cOnPrimaryContainer)
                    .frame(width: size, height: size)
                    .background(Color.cPrimaryContainer, in: RoundedRectangle(cornerRadius: A2RadiusS, style: .continuous))
            case .loading:
                ProgressView()
                    .frame(width: size, height: size)
                    .background(Color.cSurfaceContainerHigh, in: RoundedRectangle(cornerRadius: A2RadiusS, style: .continuous))
            case let .loaded(_, image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: A2RadiusS, style: .continuous))
            case .failed:
                Button {
                    onRetry?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.cOnSurfaceVariant)
                        .frame(width: max(size, A2MinTouchTarget), height: max(size, A2MinTouchTarget))
                        .background(Color.cSurfaceContainerHigh, in: RoundedRectangle(cornerRadius: A2RadiusS, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reload image")
            }
        }
        .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
    }
}
