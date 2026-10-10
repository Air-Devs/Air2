//
//  GlassCard.swift
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
//  Mapping: A2GlassCard (ObjC UIView, A2CardElevation Surface/Low/High/Highest)
//  -> GlassCard (SwiftUI) + CardLevel.
//  Elevation mapping: Surface->.l1, Low->.l2, High->.l3, Highest->.l6.
//  blurAmount/tappable/onTap/contentInsets -> useGlass/insets/isTappable/onTap.
//  No UIKit host needed; present from UIKit via UIHostingController.
//

import SwiftUI

/// Visual hierarchy. Every screen must mix levels; same-spec cards are banned.
/// Radii/shadows are fixed per level so depth is systematic, not per-call-site.
public enum CardLevel: Equatable {
    /// L1 list-item: r8, no shadow. Dense rows nested inside cards.
    case l1
    /// L2 standard card: r12, light shadow.
    case l2
    /// L3 detail/focus card: r16, medium shadow.
    case l3
    /// L4 bento tile: r12, medium shadow + press animation. Tiles vary in
    /// size; equal-size grids are fake Bento and banned.
    case l4
    /// L6 grouping/modal frame: r28, heavy shadow.
    case l6

    var radius: CGFloat {
        switch self {
        case .l1: return A2RadiusS
        case .l2, .l4: return A2RadiusM
        case .l3: return A2RadiusL
        case .l6: return A2RadiusXL
        }
    }

    /// Fill roles step through surfaceContainer tiers so depth reads by tone.
    var fill: Color {
        switch self {
        case .l1: return .cSurfaceContainerLowest
        case .l2: return .cSurfaceContainer
        case .l3: return .cSurfaceContainerHigh
        case .l4: return .cSurfaceContainer
        case .l6: return .cSurfaceContainerHighest
        }
    }

    /// (opacity, radius, y). L1 deliberately shadowless.
    var shadow: (opacity: Double, radius: CGFloat, y: CGFloat) {
        switch self {
        case .l1: return (0, 0, 0)
        case .l2: return (0.06, 10, 3)
        case .l3: return (0.10, 16, 5)
        case .l4: return (0.10, 16, 5)
        case .l6: return (0.18, 20, 6)
        }
    }
}

/// MD3 card with system glass on top and surface fallback underneath.
///
/// Glass (.regularMaterial) is used only when the caller opts in AND the
/// device can show it; otherwise the MD3 surface fill carries the hierarchy.
/// Shadow is applied to the outer shape while the fill is clipped inside, so
/// the UIKit invariant (masksToBounds=false when shadowed, shadowPath when
/// clipping) holds structurally: nothing here ever clips a shadow.
public struct GlassCard<Content: View>: View {
    public var level: CardLevel
    public var insets: EdgeInsets
    /// Opt-in glass. Default false: tone carries depth; blur is expensive with
    /// many cards and unpredictable over custom wallpapers.
    public var useGlass: Bool
    public var isTappable: Bool
    public var onTap: (() -> Void)?
    @ViewBuilder public var content: () -> Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    public init(
        level: CardLevel = .l2,
        insets: EdgeInsets = EdgeInsets(top: A2CardPadding, leading: A2CardPadding, bottom: A2CardPadding, trailing: A2CardPadding),
        useGlass: Bool = false,
        isTappable: Bool = false,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.level = level
        self.insets = insets
        self.useGlass = useGlass
        self.isTappable = isTappable
        self.onTap = onTap
        self.content = content
    }

    private var glassAllowed: Bool {
        guard useGlass, !reduceTransparency else { return false }
        return true
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: level.radius, style: .continuous)
        Group {
            if isTappable {
                Button {
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                    onTap?()
                } label: {
                    cardContent(shape: shape)
                }
                .buttonStyle(A2PressButtonStyle())
            } else {
                cardContent(shape: shape)
            }
        }
        .onAppear {
            if useGlass, reduceTransparency {
                A2ComponentLog("GlassCard: glass disabled because Reduce Transparency is on; using MD3 surface fallback")
            }
        }
    }

    private func cardContent(shape: RoundedRectangle) -> some View {
        content()
            .padding(insets)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if glassAllowed {
                    shape
                        .fill(.regularMaterial)
                        .overlay(shape.fill(level.fill.opacity(0.55)))
                } else {
                    shape.fill(level.fill)
                }
            }
            .overlay(shape.stroke(Color.cOutlineVariant.opacity(0.7), lineWidth: 0.5))
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0 : level.shadow.opacity),
                radius: level.shadow.radius, x: 0, y: level.shadow.y
            )
            .contentShape(shape)
    }
}
