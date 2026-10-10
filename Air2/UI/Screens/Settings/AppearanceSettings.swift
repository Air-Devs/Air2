//
//  AppearanceSettings.swift
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
//  Appearance + source groups (replaces A2AppearanceSettings):
//  color theme, light/dark mode, custom background, content source,
//  CurseForge key, mirror switch and priority.

import SwiftUI

// TODO-MIGRATION: bind AppearanceSettingsView to A2ThemeManager + A2Settings keys.

@MainActor
final class AppearanceSettingsModel: ObservableObject {
    @Published var themeName = "Embermire"
    @Published var modeName = "System"
    @Published var backgroundSummary = "Theme surface"
    @Published var hasCurseForgeKey = false
    @Published var mirrorEnabled = true
    @Published var priorityName = "Official first"

    func cycleMode() {}
    func cyclePriority() { priorityName = priorityName == "Official first" ? "Mirror first" : "Official first" }
    func clearKey() { hasCurseForgeKey = false }
}

struct AppearanceSettingsView: View {
    @ObservedObject var router: A2Router = A2Router()
    @StateObject private var model = AppearanceSettingsModel()
    @State private var showingKeyPrompt = false

    var body: some View {
        VStack(spacing: A2CardSpacing) {
            SettingsSection(title: "Appearance") {
                SettingsRow(symbolName: "paintpalette.fill",
                    title: "Color theme",
                    subtitle: "Seed color drives the whole palette",
                    valueText: model.themeName
                , accessory: .disclosure) { router.path.append(A2Route.colorTheme) }
                SettingsRow(symbolName: "circle.lefthalf.filled",
                    title: "Appearance mode",
                    valueText: model.modeName
                , accessory: .disclosure) { model.cycleMode() }
                SettingsRow(symbolName: "photo.fill",
                    title: "Custom background",
                    subtitle: model.backgroundSummary
                , accessory: .disclosure) { router.path.append(A2Route.background) }
            }
            SettingsSection(title: "Content sources", footer: "Modrinth needs no setup. CurseForge needs an API key.") {
                SettingsRow(symbolName: "flame.fill",
                    title: "CurseForge API key",
                    subtitle: model.hasCurseForgeKey ? "Set" : "Not set — CurseForge unavailable",
                    valueText: model.hasCurseForgeKey ? "Set" : "Missing"
                , accessory: .disclosure) { router.path.append(A2Route.curseForgeKey) }
                Toggle("Use mirror downloads", isOn: $model.mirrorEnabled)
                    .font(A2Type.subtitleCard)
                    .frame(minHeight: A2MinTouchTarget)
                SettingsRow(symbolName: "arrow.up.arrow.down",
                    title: "Mirror priority",
                    valueText: model.priorityName
                , accessory: .disclosure) { model.cyclePriority() }
                if model.hasCurseForgeKey {
                    SettingsRow(symbolName: "trash",
                        title: "Clear key",
                        destructive: true
                    , accessory: .disclosure) { model.clearKey() }
                }
            }
        }
        .sheet(isPresented: $showingKeyPrompt) {
            CurseForgePromptSheet()
        }
    }
}
