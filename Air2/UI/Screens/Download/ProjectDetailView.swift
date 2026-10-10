//
//  ProjectDetailView.swift
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
//  Project page (replaces A2ProjectDetailViewController): header
//  info, version list, download-latest CTA, favorite toggle.
//  Row taps download directly; the list never filters versions.

import SwiftUI

// TODO-MIGRATION: bind ProjectDetailViewModel to A2ContentSource versions + A2DownloadFavorites.

struct ProjectFile: Hashable {
    let id: String
    let name: String
    let meta: String
}

@MainActor
final class ProjectDetailViewModel: ObservableObject {
    @Published var state: A2ListState = .loading
    @Published var title = ""
    @Published var summary = ""
    @Published var files: [ProjectFile] = []
    @Published var isFavorite = false

    func reload(projectID _: String) {}
    func downloadLatest() {}
    func download(_ file: ProjectFile) {}
    func toggleFavorite() { isFavorite.toggle() }
}

struct ProjectDetailView: View {
    let projectID: String
    @StateObject private var model = ProjectDetailViewModel()

    var body: some View {
        A2PageScaffold(model.title.isEmpty ? "Project" : model.title) {
            headerCard.a2CardEntrance(0)
            filesCard.a2CardEntrance(1)
        }
        .toolbar {
            Button(action: { model.toggleFavorite() }) {
                Image(systemName: model.isFavorite ? "star.fill" : "star")
                    .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
            }
        }
        .onAppear { model.reload(projectID: projectID) }
    }

    private var headerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                Text(model.summary)
                    .font(A2Type.body)
                    .foregroundStyle(.cOnSurfaceVariant)
                PrimaryButton(title: "Download latest", symbolName: "arrow.down.circle") {
                    model.downloadLatest()
                }
            }
        }
    }

    private var filesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Versions")
                    .font(A2Type.caption)
                    .foregroundStyle(.cOnSurfaceVariant)
                    .padding(.bottom, A2SpaceS)
                A2StateView(
                    state: model.state,
                    emptyTitle: "No files published",
                    emptyHint: "This project has no files for your version yet."
                ) { model.reload(projectID: projectID) }
                ForEach(model.files, id: \.self) { file in
                    Button(action: { model.download(file) }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(A2Type.subtitleCard)
                                    .foregroundStyle(.cOnSurface)
                                Text(file.meta)
                                    .font(A2Type.caption)
                                    .foregroundStyle(.cOnSurfaceVariant)
                            }
                            Spacer()
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.cPrimary)
                                .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
