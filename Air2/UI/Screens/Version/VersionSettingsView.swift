//
//  VersionSettingsView.swift
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
//  Per-version settings (replaces A2VersionSettingsViewController):
//  isolation, folders, launch args, rename, delete. The footer
//  always states where each folder currently lives.

import SwiftUI

// TODO-MIGRATION: bind VersionSettingsViewModel to A2VersionIsolation per-version config.

@MainActor
final class VersionSettingsViewModel: ObservableObject {
    @Published var isValid = true
    @Published var isolationSummary = ""
    @Published var gameDirectory = ""
    @Published var folders: [(String, String, String)] = []
    @Published var jvmArgs = ""
    @Published var gameArgs = ""
    @Published var skipIntegrityCheck = false

    func reload(versionName _: String) {}
    func browseFiles() {}
    func rename(to _: String) {}
    func remove() {}
}

struct VersionSettingsView: View {
    @ObservedObject var router: A2Router = A2Router()
    let versionName: String
    @StateObject private var model = VersionSettingsViewModel()
    @State private var showingRename = false
    @State private var showingDelete = false
    @State private var draftName = ""

    var body: some View {
        A2PageScaffold(versionName) {
            headerCard.a2CardEntrance(0)
            isolationCard.a2CardEntrance(1)
            foldersCard.a2CardEntrance(2)
            launchCard.a2CardEntrance(3)
            dangerCard.a2CardEntrance(4)
        }
        .onAppear { model.reload(versionName: versionName) }
    }

    private var headerCard: some View {
        GlassCard {
            HStack {
                Image(systemName: "cube.fill")
                    .font(.title)
                    .foregroundStyle(.cPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(versionName)
                        .font(A2Type.titleCard)
                        .foregroundStyle(.cOnSurface)
                    Text(model.isValid ? "Version files look good" : "Version files are damaged")
                        .font(A2Type.caption)
                        .foregroundStyle(model.isValid ? .green : .red)
                }
            }
        }
    }

    private var isolationCard: some View {
        SettingsSection(title: "Isolation", footer: "Isolation follows the global setting in Settings → Game.") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current game directory")
                        .font(A2Type.subtitleCard)
                        .foregroundStyle(.cOnSurface)
                    Text(model.gameDirectory)
                        .font(A2Type.caption)
                        .foregroundStyle(.cOnSurfaceVariant)
                }
                Spacer()
            }
            .frame(minHeight: A2MinTouchTarget)
        }
    }

    private var foldersCard: some View {
        SettingsSection(title: "Version folders") {
            ForEach(model.folders.indices, id: \.self) { i in
                SettingsRow(symbolName: model.folders[i].1,
                    title: model.folders[i].0,
                    subtitle: model.folders[i].2
                , accessory: .disclosure) { model.browseFiles() }
            }
            SettingsRow(symbolName: "folder.fill", title: "Browse version files", accessory: .disclosure, accessory: .disclosure) {
                router.path.append(A2Route.files(versionName))
            }
        }
    }

    private var launchCard: some View {
        SettingsSection(title: "Launch") {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                Text("JVM arguments")
                    .font(A2Type.subtitleCard)
                TextField("Follow global", text: $model.jvmArgs)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: A2MinTouchTarget)
                Text("Game arguments")
                    .font(A2Type.subtitleCard)
                TextField("Follow global", text: $model.gameArgs)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: A2MinTouchTarget)
                Toggle("Skip integrity check", isOn: $model.skipIntegrityCheck)
                    .font(A2Type.subtitleCard)
                    .frame(minHeight: A2MinTouchTarget)
            }
        }
    }

    private var dangerCard: some View {
        SettingsSection(title: "Danger zone") {
            SettingsRow(symbolName: "square.and.pencil", title: "Rename version", accessory: .disclosure, accessory: .disclosure) {
                draftName = versionName
                showingRename = true
            }
            SettingsRow(symbolName: "trash", title: "Delete this version", destructive: true, accessory: .disclosure, accessory: .disclosure) {
                showingDelete = true
            }
        }
        .alert("Rename version", isPresented: $showingRename) {
            TextField("Name", text: $draftName)
            Button("Confirm") { model.rename(to: draftName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete \(versionName)?", isPresented: $showingDelete) {
            Button("Delete", role: .destructive) { model.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all version files and cannot be undone.")
        }
    }
}
