//
//  FavoritesView.swift
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
//  Starred projects (replaces A2FavoritesViewController) with swipe
//  to remove. Tapping a row re-opens the project detail page.

import SwiftUI

// TODO-MIGRATION: bind FavoritesViewModel to A2DownloadFavorites store.

struct FavoriteProject: Hashable {
    let id: String
    let title: String
    let subtitle: String
}

@MainActor
final class FavoritesViewModel: ObservableObject {
    @Published var state: A2ListState = .loading
    @Published var favorites: [FavoriteProject] = []

    func reload() {}
    func remove(_ favorite: FavoriteProject) {}
}

struct FavoritesView: View {
    @ObservedObject var router: A2Router = A2Router()
    @StateObject private var model = FavoritesViewModel()

    var body: some View {
        A2PageScaffold("Favorites") {
            GlassCard {
                VStack(alignment: .leading, spacing: 0) {
                    A2StateView(
                        state: model.state,
                        emptyTitle: "No favorites yet",
                        emptyHint: "Star a project to pin it here.",
                        firstRunHint: "First run: open any project and tap the star."
                    ) { model.reload() }
                    ForEach(model.favorites, id: \.self) { favorite in
                        HStack {
                            Button(action: {
                                router.openProject(favorite.id)
                            }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(favorite.title)
                                        .font(A2Type.subtitleCard)
                                        .foregroundStyle(.cOnSurface)
                                    Text(favorite.subtitle)
                                        .font(A2Type.caption)
                                        .foregroundStyle(.cOnSurfaceVariant)
                                }
                                Spacer()
                            }
                            .buttonStyle(.plain)
                            Button(action: { model.remove(favorite) }) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.cError)
                                    .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
                            }
                        }
                        .frame(minHeight: A2MinTouchTarget)
                    }
                }
            }
            .a2CardEntrance(0)
        }
        .onAppear { model.reload() }
    }
}
