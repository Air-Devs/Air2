//
//  AccountRowView.swift
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
//  One account row (replaces A2AccountRowView): 46pt avatar, name,
//  type label, current radio indicator, refresh/more actions.
//  Callbacks stay protocol-decoupled; the row owns no Core types.

import SwiftUI

struct AccountRowData: Hashable {
    let id: String
    let name: String
    let typeLabel: String
    let isCurrent: Bool
    let refreshable: Bool
}

protocol AccountRowActions {
    func select(_ account: AccountRowData)
    func refresh(_ account: AccountRowData)
    func showMore(_ account: AccountRowData)
}

struct AccountRowView: View {
    let account: AccountRowData
    let actions: AccountRowActions

    var body: some View {
        Button(action: { actions.select(account) }) {
            HStack(spacing: A2SpaceM) {
                // Avatar: skin head when available, initial letter otherwise.
                SkinHeadView(
                    fallbackText: String(account.name.prefix(1)),
                    size: 46
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(A2Type.subtitleCard)
                        .foregroundStyle(.cOnSurface)
                    Text(account.typeLabel)
                        .font(A2Type.caption)
                        .foregroundStyle(.cOnSurfaceVariant)
                }
                Spacer()
                if account.isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.cPrimary)
                }
                if account.refreshable {
                    Button(action: { actions.refresh(account) }) {
                        Image(systemName: "arrow.clockwise")
                            .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
                    }
                    .buttonStyle(.plain)
                }
                Button(action: { actions.showMore(account) }) {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, A2SpaceXS)
            .frame(minHeight: A2MinTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
