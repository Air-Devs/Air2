//
//  CardPosition.swift
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
//  Mapping: A2CardPosition (Top/Middle/Bottom/Single) + A2CornerMaskForPosition
//  -> CardPosition + per-corner radii (iOS 15 shape, no UIKit host needed).
//

import SwiftUI

/// A row's position inside a grouped card. Only edge rows get the large
/// radius, so N rows read as one card, not N small cards.
public enum CardPosition: Equatable {
    case top
    case middle
    case bottom
    case single

    /// (topRadius, bottomRadius). Grouping frame is L6 (r28); seams stay r4.
    public var radii: (top: CGFloat, bottom: CGFloat) {
        switch self {
        case .top: return (A2RadiusXL, A2RadiusXS)
        case .middle: return (A2RadiusXS, A2RadiusXS)
        case .bottom: return (A2RadiusXS, A2RadiusXL)
        case .single: return (A2RadiusXL, A2RadiusXL)
        }
    }

    public static func position(index: Int, count: Int) -> CardPosition {
        guard count > 1 else { return .single }
        if index == 0 { return .top }
        if index == count - 1 { return .bottom }
        return .middle
    }
}

public extension View {
    /// Clips to per-edge radii for grouped rows (iOS 15: custom shape
    /// with separate top/bottom radii instead of UnevenRoundedRectangle).
    func cardPositionClip(_ position: CardPosition) -> some View {
        let r = position.radii
        return clipShape(A2EdgeRadiiShape(topRadius: r.top, bottomRadius: r.bottom))
    }
}

/// Rectangle with independent top / bottom corner radii (continuous feel).
/// Falls back to RoundedRectangle when both radii match.
public struct A2EdgeRadiiShape: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    public init(topRadius: CGFloat, bottomRadius: CGFloat) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    public func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let top = min(topRadius, limit)
        let bottom = min(bottomRadius, limit)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        p.addArc(
            center: CGPoint(x: rect.maxX - top, y: rect.minY + top),
            radius: top, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        p.addArc(
            center: CGPoint(x: rect.maxX - bottom, y: rect.maxY - bottom),
            radius: bottom, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        p.addArc(
            center: CGPoint(x: rect.minX + bottom, y: rect.maxY - bottom),
            radius: bottom, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        p.addArc(
            center: CGPoint(x: rect.minX + top, y: rect.minY + top),
            radius: top, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        p.closeSubpath()
        return p
    }
}
