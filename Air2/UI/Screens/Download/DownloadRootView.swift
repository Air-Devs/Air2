//
//  DownloadRootView.swift
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
//  Download center shell (replaces A2DownloadViewController): category
//  rail plus an inner content slot. It never renders content itself;
//  DownloadHomeView decides what each category shows.

import SwiftUI

struct DownloadRootView: View {
    @ObservedObject var router: A2Router = A2Router()
    @State private var selected: DownloadCategory = .game

    private let categories: [(DownloadCategory, String, String)] = [
        (.game, "Game", "sports.esports"),
        (.modpack, "Modpacks", "shippingbox.fill"),
        (.mod, "Mods", "puzzlepiece.extension.fill"),
        (.resourcePack, "Resources", "photo.stack.fill"),
        (.world, "Worlds", "map.fill"),
        (.shader, "Shaders", "sun.max.fill"),
    ]

    var body: some View {
        ThreeZoneScaffold(
            "Download",
            ops: {
                categoryCard.a2CardEntrance(0)
                DownloadHomeView(router: router, category: selected)
                    .a2CardEntrance(1)
            },
            wallpaper: {
                Color.cSurface
            }
        )
    }

    private var categoryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                Text("Categories")
                    .font(A2Type.caption)
                    .foregroundStyle(.cOnSurfaceVariant)
                ForEach(categories, id: \.0) { item in
                    Button(action: { selected = item.0 }) {
                        HStack {
                            Image(systemName: item.2)
                                .foregroundStyle(selected == item.0 ? .cPrimary : .secondary)
                            Text(item.1)
                                .font(A2Type.subtitleCard)
                                .foregroundStyle(.cOnSurface)
                            Spacer()
                            if selected == item.0 {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.cPrimary)
                            }
                        }
                        .frame(minHeight: A2MinTouchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
