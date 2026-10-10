//
//  SegmentedControl.swift
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
//  Mapping: A2SegmentedControl (initWithTitles:/selectedIndex/onSegmentChange)
//  -> SegmentedControl (titles/selection binding/onChange). Outlined capsule,
//  secondaryContainer selection, 48pt height. No UIKit host needed.
//

import SwiftUI

public struct SegmentedControl: View {
    public var titles: [String]
    @Binding public var selection: Int
    public var onChange: ((Int) -> Void)?

    public init(titles: [String], selection: Binding<Int>, onChange: ((Int) -> Void)? = nil) {
        self.titles = titles
        self._selection = selection
        self.onChange = onChange
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Button {
                    guard index != selection else { return }
                    let generator = UISelectionFeedbackGenerator()
                    generator.selectionChanged()
                    withAnimation(.a2Standard) { selection = index }
                    onChange?(index)
                } label: {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(index == selection ? Color.cOnSecondaryContainer : Color.cOnSurfaceVariant)
                        .frame(maxWidth: .infinity, minHeight: A2MinTouchTarget)
                        .background(
                            Capsule(style: .continuous)
                                .fill(index == selection ? Color.cSecondaryContainer : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == selection ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .frame(height: 48)
        .background(Capsule(style: .continuous).stroke(Color.cOutline, lineWidth: 1))
    }
}
