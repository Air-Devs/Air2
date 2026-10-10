//
//  FilesView.swift
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
//  Version game-directory browser (replaces A2FilesViewController):
//  directory drilling, rename / delete with swipe actions, inline
//  text preview. All file work goes through the view model; the
//  view never stitches paths.

import SwiftUI

// TODO-MIGRATION: bind FilesViewModel to A2GameFiles scoped file facade.

struct BrowserEntry: Hashable {
    let name: String
    let isDirectory: Bool
    let sizeText: String
}

@MainActor
final class FilesViewModel: ObservableObject {
    @Published var state: A2ListState = .loading
    @Published var entries: [BrowserEntry] = []
    @Published var previewText: String?

    func reload() {}
    func enter(_ entry: BrowserEntry) {}
    func goUp() {}
    func createDirectory(named _: String) {}
    func rename(_ entry: BrowserEntry, to _: String) {}
    func delete(_ entry: BrowserEntry) {}
}

struct FilesView: View {
    let displayName: String
    @StateObject private var model = FilesViewModel()
    @State private var pendingName = ""
    @State private var showingCreator = false

    var body: some View {
        A2PageScaffold(displayName.isEmpty ? "Files" : displayName) {
            GlassCard {
                VStack(alignment: .leading, spacing: 0) {
                    A2StateView(
                        state: model.state,
                        emptyTitle: "Empty folder",
                        emptyHint: "Nothing here yet. Game files will appear as you play."
                    ) { model.reload() }
                    ForEach(model.entries, id: \.self) { entry in
                        Button(action: { model.enter(entry) }) {
                            HStack {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                                    .foregroundStyle(.cPrimary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .font(A2Type.subtitleCard)
                                        .foregroundStyle(.cOnSurface)
                                    if !entry.isDirectory {
                                        Text(entry.sizeText)
                                            .font(A2Type.caption)
                                            .foregroundStyle(.cOnSurfaceVariant)
                                    }
                                }
                                Spacer()
                                if entry.isDirectory {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.cOutline)
                                }
                            }
                            .frame(minHeight: A2MinTouchTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { model.delete(entry) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .a2CardEntrance(0)
            if let previewText = model.previewText {
                GlassCard {
                    Text(previewText)
                        .font(.body.monospaced())
                        .foregroundStyle(.cOnSurface)
                }
                .a2CardEntrance(1)
            }
        }
        .toolbar {
            Button(action: { showingCreator = true }) {
                Image(systemName: "plus")
                    .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
            }
        }
        .alert("New folder", isPresented: $showingCreator) {
            TextField("Name", text: $pendingName)
            Button("Create") { model.createDirectory(named: pendingName) }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { model.reload() }
    }
}
