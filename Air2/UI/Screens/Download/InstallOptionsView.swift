//
//  InstallOptionsView.swift
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
//  Install step two (replaces A2GameInstallOptionsViewController):
//  custom version name plus loader picker, then start install.

import SwiftUI

// TODO-MIGRATION: bind InstallOptionsViewModel to A2ModLoaderAPI loader version lookup.

@MainActor
final class InstallOptionsViewModel: ObservableObject {
    @Published var versionName = ""
    @Published var loader: String = "Vanilla"
    @Published var nameError: String?
    let loaders = ["Vanilla", "Fabric", "Quilt", "Forge", "NeoForge"]

    func validate() {
        let trimmed = versionName.trimmingCharacters(in: .whitespaces)
        nameError = trimmed.isEmpty ? "Give this install a name." : nil
    }
}

struct InstallOptionsView: View {
    @ObservedObject var router: A2Router = A2Router()
    let versionID: String
    @StateObject private var model = InstallOptionsViewModel()

    var body: some View {
        A2PageScaffold(versionID) {
            nameCard.a2CardEntrance(0)
            loaderCard.a2CardEntrance(1)
            actionCard.a2CardEntrance(2)
        }
        .onAppear { model.versionName = versionID }
    }

    private var nameCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                Text("Version name")
                    .font(A2Type.caption)
                    .foregroundStyle(.cOnSurfaceVariant)
                TextField("e.g. 1.21.5-fabric", text: $model.versionName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: A2MinTouchTarget)
                    .onChange(of: model.versionName) { model.validate() }
                if let nameError = model.nameError {
                    Text(nameError).font(A2Type.caption).foregroundStyle(.cError)
                }
            }
        }
    }

    private var loaderCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                Text("Mod loader")
                    .font(A2Type.caption)
                    .foregroundStyle(.cOnSurfaceVariant)
                ForEach(model.loaders, id: \.self) { loader in
                    Button(action: { model.loader = loader }) {
                        HStack {
                            Text(loader)
                                .font(A2Type.subtitleCard)
                                .foregroundStyle(.cOnSurface)
                            Spacer()
                            if model.loader == loader {
                                Image(systemName: "checkmark.circle.fill")
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

    private var actionCard: some View {
        GlassCard {
            PrimaryButton(title: "Start install", symbolName: "arrow.down.circle") {
                model.validate()
                guard model.nameError == nil else { return }
                router.openInstalling(InstallSpec(
                    mcVersion: versionID,
                    versionName: model.versionName,
                    loaderType: nil,
                    loaderVersion: nil
                ))
            }
        }
    }
}
