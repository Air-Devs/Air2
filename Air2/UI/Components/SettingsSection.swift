//
//  SettingsSection.swift
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
//  Mapping: A2SettingsSection (initWithTitle:/sectionTitle/footerText/
//  addRow:/addCustomView:/rows) -> SettingsSection (title/footer/rows +
//  customContent). Positions + separators derive from row order: single row
//  .single/no-separator, else top/middle/bottom with separators above the
//  last row. 2pt row spacing. No UIKit host needed.
//

import SwiftUI

public struct SettingsSection<CustomContent: View>: View {
    public var title: String?
    public var footer: String?
    public var rows: [SettingsRowModel]
    @ViewBuilder public var customContent: () -> CustomContent

    public init(title: String? = nil, footer: String? = nil, rows: [SettingsRowModel] = [], @ViewBuilder customContent: @escaping () -> CustomContent = { EmptyView() }) {
        self.title = title
        self.footer = footer
        self.rows = rows
        self.customContent = customContent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: A2SpaceS) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(A2Type.sectionTitle)
                    .foregroundStyle(Color.cOnSurfaceVariant.opacity(0.85))
                    .padding(.horizontal, A2SpaceL)
            }
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, model in
                    SettingsRow(
                        model: model,
                        position: CardPosition.position(index: index, count: rows.count),
                        showsSeparator: rows.count > 1 && index < rows.count - 1
                    )
                }
                customContent()
            }
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(A2Type.caption)
                    .foregroundStyle(Color.cOnSurfaceVariant.opacity(0.7))
                    .padding(.horizontal, A2SpaceL)
            }
        }
    }
}
