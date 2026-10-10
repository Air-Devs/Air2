//
//  QuickActionCard.swift
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
//  Mapping: A2QuickActionCard : A2GlassCard
//  (title/symbolName/onSelect) -> QuickActionCard.
//  L4 bento tile (r12, medium shadow, press). Tile size is caller-driven so
//  grids vary; equal-size grids are fake Bento and banned.
//

import SwiftUI

public struct QuickActionCard: View {
    public var title: String
    public var symbolName: String
    /// Caller-chosen tile size. Vary across siblings for a real Bento rhythm.
    public var tileSize: CGSize
    public var onSelect: (() -> Void)?

    public init(title: String, symbolName: String, tileSize: CGSize = CGSize(width: 104, height: 96), onSelect: (() -> Void)? = nil) {
        self.title = title
        self.symbolName = symbolName
        self.tileSize = tileSize
        self.onSelect = onSelect
    }

    public var body: some View {
        GlassCard(level: .l4, insets: EdgeInsets(top: A2SpaceS, leading: A2SpaceS, bottom: A2SpaceS, trailing: A2SpaceS), isTappable: true, onTap: onSelect) {
            VStack(spacing: A2SpaceS) {
                A2Symbol(symbolName, pointSize: 21)
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(A2Type.caption)
                    .foregroundStyle(Color.cOnSurface)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: tileSize.width, height: tileSize.height)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
    }
}
