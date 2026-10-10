//
//  FilterChip.swift
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
//  Mapping: A2FilterChip (ObjC UIControl) -> FilterChip (SwiftUI) + ChipRow.
//  Selected chips fill with the primary role; unselected chips stay on a
//  container tone with a hairline outline. Display-only chips (project tags)
//  pass isInteractive: false and get no press physics and no dimming.
//

import SwiftUI

struct FilterChip: View {
    let title: String
    var selected: Bool = false
    var isInteractive: Bool = true
    var action: () -> Void = {}

    var body: some View {
        if isInteractive {
            Button(action: action) { label }
                .buttonStyle(A2PressButtonStyle())
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        } else {
            label.accessibilityAddTraits(.isStaticText)
        }
    }

    private var label: some View {
        Text(title)
            .font(A2Type.caption)
            .lineLimit(1)
            .foregroundStyle(selected ? Color.cOnPrimary : Color.cOnSurface)
            .padding(.horizontal, A2SpaceM)
            .frame(height: 30)
            .background(
                selected ? Color.cPrimary : Color.cSurfaceContainerHigh,
                in: Capsule(style: .continuous)
            )
            .overlay {
                if !selected {
                    Capsule(style: .continuous)
                        .stroke(Color.cOutlineVariant, lineWidth: 1)
                }
            }
    }
}

/// Horizontally scrollable row of chips (single-line, no visible indicator).
struct ChipRow<Content: View>: View {
    var height: CGFloat = 30
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: A2SpaceS) {
                content()
            }
            .frame(height: height)
        }
        .frame(height: height)
    }
}
