//
//  SearchByIdView.swift
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
//  Look up a project by ID/slug (replaces A2SearchByIdViewController)
//  and jump straight to its detail page.

import SwiftUI

// TODO-MIGRATION: resolve IDs through A2ContentSource in SearchByIdViewModel.

@MainActor
final class SearchByIdViewModel: ObservableObject {
    @Published var projectID = ""
    @Published var errorMessage: String?

    var canQuery: Bool {
        !projectID.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct SearchByIdView: View {
    @ObservedObject var router: A2Router = A2Router()
    @StateObject private var model = SearchByIdViewModel()

    var body: some View {
        A2PageScaffold("Look up by ID") {
            GlassCard {
                VStack(alignment: .leading, spacing: A2SpaceM) {
                    Text("Paste a Modrinth slug or CurseForge project ID to jump to it directly.")
                        .font(A2Type.body)
                        .foregroundStyle(.cOnSurfaceVariant)
                    TextField("Project ID or slug", text: $model.projectID)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: A2MinTouchTarget)
                        .onSubmit { query() }
                    PrimaryButton(title: "Look up", symbolName: "magnifyingglass") {
                        query()
                    }
                    .disabled(!model.canQuery)
                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .font(A2Type.caption)
                            .foregroundStyle(.cError)
                    }
                }
            }
            .a2CardEntrance(0)
        }
    }

    private func query() {
        guard model.canQuery else { return }
        router.openProject(model.projectID)
    }
}
