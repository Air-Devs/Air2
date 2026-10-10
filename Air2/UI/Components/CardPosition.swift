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
//  -> CardPosition + UnevenRoundedRectangle radii. No UIKit host needed.
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
    /// Clips to per-edge radii for grouped rows.
    func cardPositionClip(_ position: CardPosition) -> some View {
        let r = position.radii
        return clipShape(UnevenRoundedRectangle(
            topLeadingRadius: r.top, bottomLeadingRadius: r.bottom,
            bottomTrailingRadius: r.bottom, topTrailingRadius: r.top,
            style: .continuous
        ))
    }
}
