//
//  VersionRowView.swift
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
//  One version row (replaces A2VersionRowView): icon, name, meta,
//  current radio indicator, pin / settings / more actions.
//  Invalid versions dim their actions instead of hiding them.

import SwiftUI

struct VersionRowData: Hashable {
    let name: String
    let meta: String
    let isCurrent: Bool
    let isPinned: Bool
    let isValid: Bool
}

protocol VersionRowActions {
    func select(_ version: VersionRowData)
    func togglePin(_ version: VersionRowData)
    func openSettings(_ version: VersionRowData)
    func showMore(_ version: VersionRowData)
}

struct VersionRowView: View {
    let version: VersionRowData
    let actions: VersionRowActions

    var body: some View {
        Button(action: { actions.select(version) }) {
            HStack(spacing: A2SpaceM) {
                Image(systemName: "cube.fill")
                    .foregroundStyle(version.isValid ? .cPrimary : .secondary)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(version.name)
                        .font(A2Type.subtitleCard)
                        .foregroundStyle(.cOnSurface)
                    Text(version.meta)
                        .font(A2Type.caption)
                        .foregroundStyle(.cOnSurfaceVariant)
                }
                Spacer()
                if version.isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.cPrimary)
                }
                Button(action: { actions.togglePin(version) }) {
                    Image(systemName: version.isPinned ? "pin.fill" : "pin")
                        .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
                        .foregroundStyle(.cOnSurfaceVariant)
                }
                .buttonStyle(.plain)
                .disabled(!version.isValid)
                Button(action: { actions.openSettings(version) }) {
                    Image(systemName: "gearshape")
                        .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
                        .foregroundStyle(.cOnSurfaceVariant)
                }
                .buttonStyle(.plain)
                .disabled(!version.isValid)
                Button(action: { actions.showMore(version) }) {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
                        .foregroundStyle(.cOnSurfaceVariant)
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: A2MinTouchTarget)
            .contentShape(Rectangle())
            .opacity(version.isValid ? 1 : 0.6)
        }
        .buttonStyle(.plain)
    }
}
