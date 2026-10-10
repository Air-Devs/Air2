//
//  DownloadHomeView.swift
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
//  Category content (replaces A2DownloadHomeViewController): source
//  row, game section, 2x2 resource grid, by-ID lookup, favorites.

import SwiftUI

// TODO-MIGRATION: read preferred platform from A2Settings.preferredContentPlatform.

struct DownloadHomeView: View {
    @ObservedObject var router: A2Router = A2Router()
    var category: DownloadCategory
    @State private var useModrinth = true

    var body: some View {
        VStack(spacing: A2CardSpacing) {
            sourceRow
            if category == .game {
                gameSection
            } else {
                resourceGrid
            }
            lookupSection
            favoritesSection
        }
    }

    private var sourceRow: some View {
        GlassCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Source")
                        .font(A2Type.caption)
                        .foregroundStyle(.cOnSurfaceVariant)
                    Text(useModrinth ? "Modrinth — no key needed" : "CurseForge — API key required")
                        .font(A2Type.subtitleCard)
                        .foregroundStyle(.cOnSurface)
                }
                Spacer()
                Picker("Source", selection: $useModrinth) {
                    Text("Modrinth").tag(true)
                    Text("CurseForge").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
    }

    private var gameSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                Text("Install a new Minecraft version")
                    .font(A2Type.titleCard)
                    .foregroundStyle(.cOnSurface)
                Text("Pick a release, then choose a loader.")
                    .font(A2Type.caption)
                    .foregroundStyle(.cOnSurfaceVariant)
                PrimaryButton(title: "Browse game versions", symbolName: "cube.fill") {
                    router.openGameVersions()
                }
            }
        }
    }

    /// 2x2 quick grid. This is the one place the spec grants a grid.
    private var resourceGrid: some View {
        let items: [(String, String, DownloadCategory)] = [
            ("Mods", "puzzlepiece.extension.fill", .mod),
            ("Resources", "photo.stack.fill", .resourcePack),
            ("Worlds", "map.fill", .world),
            ("Shaders", "sun.max.fill", .shader),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: A2CardSpacing) {
            ForEach(items, id: \.0) { item in
                Button(action: { router.openDownloadCategory(item.2) }) {
                    VStack(spacing: A2SpaceXS) {
                        Image(systemName: item.1)
                            .font(.title2)
                            .foregroundStyle(.cPrimary)
                        Text(item.0)
                            .font(A2Type.subtitleCard)
                            .foregroundStyle(.cOnSurface)
                    }
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .background(
                        Color.cSurfaceContainerLow,
                        in: RoundedRectangle(cornerRadius: A2RadiusM)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var lookupSection: some View {
        GlassCard {
            SettingsRow(symbolName: "number", title: "Look up by ID", subtitle: "Jump straight to a project", accessory: .disclosure, accessory: .disclosure) {
                router.openSearchById()
            }
        }
    }

    private var favoritesSection: some View {
        GlassCard {
            SettingsRow(symbolName: "star.fill", title: "Favorites", subtitle: "Your starred projects", accessory: .disclosure, accessory: .disclosure) {
                router.openFavorites()
            }
        }
    }
}
