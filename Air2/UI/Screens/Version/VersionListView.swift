//
//  VersionListView.swift
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
//  Installed versions (replaces A2VersionListViewController): game
//  directory switcher, version list with select / pin / rename /
//  delete, plus a cleanup action for unused game files.

import SwiftUI

// TODO-MIGRATION: bind VersionListViewModel to A2VersionManager (versions/select/delete/rename).

@MainActor
final class VersionListViewModel: ObservableObject {
    @Published var state: A2ListState = .loading
    @Published var versions: [VersionRowData] = []
    @Published var directories = ["Default"]
    @Published var selectedDirectory = 0

    func reload() {}
    func select(_ version: VersionRowData) {}
    func togglePin(_ version: VersionRowData) {}
    func rename(_ version: VersionRowData, to _: String) {}
    func remove(_ version: VersionRowData) {}
    func cleanup() {}
}

struct VersionListView: View {
    @ObservedObject var router: A2Router = A2Router()
    @StateObject private var model = VersionListViewModel()

    var body: some View {
        A2PageScaffold("Versions") {
            directoryCard.a2CardEntrance(0)
            versionsCard.a2CardEntrance(1)
        }
        .toolbar {
            Button(action: { router.openGameVersions() }) {
                Image(systemName: "plus")
                    .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
            }
        }
        .onAppear { model.reload() }
    }

    private var directoryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                Text("Game directory")
                    .font(A2Type.caption)
                    .foregroundStyle(.cOnSurfaceVariant)
                Picker("Directory", selection: $model.selectedDirectory) {
                    ForEach(model.directories.indices, id: \.self) { i in
                        Text(model.directories[i]).tag(i)
                    }
                }
                .pickerStyle(.segmented)
                HStack(spacing: A2SpaceM) {
                    PrimaryButton(title: "Clean up", style: .secondary) { model.cleanup() }
                }
            }
        }
    }

    private var versionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                A2StateView(
                    state: model.state,
                    emptyTitle: "No versions installed",
                    emptyHint: "Install your first version to start playing.",
                    firstRunHint: "First run: tap + and pick the newest Release."
                ) { model.reload() }
                ForEach(model.versions, id: \.self) { version in
                    VersionRowView(version: version, actions: RowBridge(model: model, router: router))
                }
            }
        }
    }

    private struct RowBridge: VersionRowActions {
        let model: VersionListViewModel
        let router: A2Router
        func select(_ version: VersionRowData) { Task { @MainActor in model.select(version) } }
        func togglePin(_ version: VersionRowData) { Task { @MainActor in model.togglePin(version) } }
        func openSettings(_ version: VersionRowData) {
            Task { @MainActor in router.openVersionSettings(version.name) }
        }
        func showMore(_ version: VersionRowData) { Task { @MainActor in model.remove(version) } }
    }
}
