//
//  DownloadListView.swift
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
//  Resource list with search, filter chips and sort
//  (replaces A2DownloadListViewController). One page serves game,
//  mod, shader, resource-pack, modpack and world categories.

import SwiftUI

// TODO-MIGRATION: bind DownloadListViewModel to A2ContentSource search (Modrinth/CurseForge).

struct ContentProject: Hashable {
    let id: String
    let title: String
    let subtitle: String
    let downloadsText: String
}

@MainActor
final class DownloadListViewModel: ObservableObject {
    @Published var state: A2ListState = .loading
    @Published var projects: [ContentProject] = []
    @Published var query = ""
    @Published var selectedFilter = 0
    @Published var platformModrinth = true

    func reload() {}
    func loadMore() {}
}

struct DownloadListView: View {
    let category: DownloadCategory
    @StateObject private var model = DownloadListViewModel()

    private var title: String {
        switch category {
        case .game: return "Game"
        case .modpack: return "Modpacks"
        case .mod: return "Mods"
        case .resourcePack: return "Resource packs"
        case .world: return "Worlds"
        case .shader: return "Shaders"
        }
    }

    var body: some View {
        A2PageScaffold(title) {
            searchCard.a2CardEntrance(0)
            listCard.a2CardEntrance(1)
        }
        .onAppear { model.reload() }
    }

    private var searchCard: some View {
        GlassCard {
            VStack(spacing: A2SpaceS) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.cOnSurfaceVariant)
                    TextField("Search", text: $model.query)
                        .frame(minHeight: A2MinTouchTarget)
                        .onSubmit { model.reload() }
                }
                Picker("Source", selection: $model.platformModrinth) {
                    Text("Modrinth").tag(true)
                    Text("CurseForge").tag(false)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var listCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                A2StateView(
                    state: model.state,
                    emptyTitle: "No results",
                    emptyHint: "Try a different keyword or source.",
                    firstRunHint: "First run: Modrinth works without any setup."
                ) { model.reload() }
                ForEach(model.projects, id: \.self) { project in
                    NavigationLink(value: A2Route.projectDetail(project.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.title)
                                    .font(A2Type.subtitleCard)
                                    .foregroundStyle(.cOnSurface)
                                Text(project.subtitle)
                                    .font(A2Type.caption)
                                    .foregroundStyle(.cOnSurfaceVariant)
                            }
                            Spacer()
                            Text(project.downloadsText)
                                .font(A2Type.caption)
                                .foregroundStyle(.cOnSurfaceVariant)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.cOutline)
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
