//
//  GameVersionListView.swift
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
//  Game version picker, step one (replaces
//  A2GameVersionListViewController): type filter chips, search,
//  manifest list. Selecting a row opens the install-options step.

import SwiftUI

// TODO-MIGRATION: bind GameVersionListViewModel to A2DownloadManifest remote versions.

struct RemoteGameVersion: Hashable {
    let id: String
    let typeLabel: String
}

@MainActor
final class GameVersionListViewModel: ObservableObject {
    @Published var state: A2ListState = .loading
    @Published var versions: [RemoteGameVersion] = []
    @Published var query = ""
    @Published var selectedType = 0
    let types = ["Release", "Snapshot", "Beta", "Alpha"]

    var visible: [RemoteGameVersion] {
        versions.filter {
            query.isEmpty || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    func reload() {}
}

struct GameVersionListView: View {
    @ObservedObject var router: A2Router = A2Router()
    @StateObject private var model = GameVersionListViewModel()

    var body: some View {
        A2PageScaffold("Install version") {
            filterCard.a2CardEntrance(0)
            listCard.a2CardEntrance(1)
        }
        .onAppear { model.reload() }
    }

    private var filterCard: some View {
        GlassCard {
            VStack(spacing: A2SpaceS) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.cOnSurfaceVariant)
                    TextField("Filter versions", text: $model.query)
                        .frame(minHeight: A2MinTouchTarget)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: A2SpaceS) {
                        ForEach(model.types.indices, id: \.self) { i in
                            Button(action: { model.selectedType = i }) {
                                Text(model.types[i])
                                    .font(A2Type.caption)
                                    .padding(.horizontal, A2SpaceM)
                                    .frame(minHeight: A2MinTouchTarget)
                                    .background(
                                        model.selectedType == i ? Color.cPrimary : Color.cSecondaryContainer,
                                        in: Capsule()
                                    )
                                    .foregroundStyle(model.selectedType == i ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var listCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                A2StateView(
                    state: model.state,
                    emptyTitle: "No versions found",
                    emptyHint: "The manifest may still be loading, or the filter is too narrow.",
                    firstRunHint: "First run: pick the newest Release."
                ) { model.reload() }
                ForEach(model.visible, id: \.self) { version in
                    Button(action: { router.openInstallOptions(version.id) }) {
                        HStack {
                            Image(systemName: "cube.fill")
                                .foregroundStyle(.cPrimary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(version.id)
                                    .font(A2Type.subtitleCard)
                                    .foregroundStyle(.cOnSurface)
                                Text(version.typeLabel)
                                    .font(A2Type.caption)
                                    .foregroundStyle(.cOnSurfaceVariant)
                            }
                            Spacer()
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
