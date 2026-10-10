//
//  CategoryNavView.swift
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
//  Mapping: A2NavCategory + A2CategoryNavView
//  (navWidth/selectIndex/onSelect/divisionBefore) -> NavCategory +
//  CategoryNavView (navWidth/selectedIndex/onSelect). Vertical icon-over-label
//  items, 40%-width group dividers, secondaryContainer selection. No host.
//

import SwiftUI

public struct NavCategory: Identifiable, Equatable {
    public let id = UUID()
    public var title: String
    /// SF Symbol name. Always rendered inside the item tile, never bare.
    public var symbol: String
    public var divisionBefore: Bool
    public init(title: String, symbol: String, divisionBefore: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.divisionBefore = divisionBefore
    }
}

public struct CategoryNavView: View {
    public var categories: [NavCategory]
    public var navWidth: CGFloat
    public var selectedIndex: Int
    public var onSelect: ((Int) -> Void)?

    public init(categories: [NavCategory], navWidth: CGFloat = 88, selectedIndex: Int = 0, onSelect: ((Int) -> Void)? = nil) {
        self.categories = categories
        self.navWidth = navWidth
        self.selectedIndex = selectedIndex
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: A2SpaceS) {
                ForEach(Array(categories.indices), id: \.self) { index in
                    let category = categories[index]
                    if category.divisionBefore {
                        Color.cOnSurface.opacity(0.25)
                            .frame(width: navWidth * 0.4, height: 1)
                            .padding(.vertical, A2SpaceM)
                    }
                    Button {
                        let generator = UISelectionFeedbackGenerator()
                        generator.selectionChanged()
                        withAnimation(.a2Standard) { onSelect?(index) }
                    } label: {
                        VStack(spacing: A2SpaceXS) {
                            Image(systemName: category.symbol)
                                .font(.system(size: 21, weight: .medium))
                                .frame(width: 24, height: 24)
                            Text(category.title)
                                .font(A2Type.labelSmall)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.75)
                        }
                        .foregroundStyle(index == selectedIndex ? Color.cOnSecondaryContainer : Color.cOnSurfaceVariant)
                        .frame(width: navWidth - A2SpaceS)
                        .frame(minHeight: 62)
                        .padding(.vertical, A2SpaceS)
                        .background(
                            RoundedRectangle(cornerRadius: A2RadiusM, style: .continuous)
                                .fill(index == selectedIndex ? Color.cSecondaryContainer : Color.clear)
                        )
                    }
                    .buttonStyle(A2PressButtonStyle())
                    .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                }
            }
            .padding(.vertical, A2SpaceM)
        }
        .frame(width: navWidth)
    }
}
