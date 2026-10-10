//
//  CardTitleBar.swift
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
//  Mapping: A2CardTitleBar (title/subtitle/accessoryButton: UIButton?) ->
//  CardTitleBar (title/subtitle/accessory label+action; no UIKit host).
//

import SwiftUI

/// Card header: translucent high-container strip + title + optional action.
/// The action is a visible button, never a hidden gesture.
public struct CardTitleBar: View {
    public var title: String
    public var subtitle: String?
    public var accessoryTitle: String?
    public var onAccessoryTap: (() -> Void)?

    public init(title: String, subtitle: String? = nil, accessoryTitle: String? = nil, onAccessoryTap: (() -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.accessoryTitle = accessoryTitle
        self.onAccessoryTap = onAccessoryTap
    }

    public var body: some View {
        HStack(spacing: A2SpaceS) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(A2Type.titleCard)
                    .foregroundStyle(Color.cOnSurface)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(A2Type.subtitleCard)
                        .foregroundStyle(Color.cOnSurfaceVariant)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: A2SpaceS)
            if let accessoryTitle, let onAccessoryTap {
                Button(accessoryTitle, action: onAccessoryTap)
                    .font(A2Type.button)
                    .foregroundStyle(Color.cPrimary)
                    .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
            }
        }
        .padding(.horizontal, A2SpaceL)
        .frame(minHeight: A2MinTouchTarget)
        .background(Color.cSurfaceContainerHigh.opacity(0.55))
    }
}
