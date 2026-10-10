//
//  GameSettings.swift
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
//  Game group (replaces A2GameSettings): global version isolation
//  mode. Resource files stay shared in every mode; only mods follow
//  the isolation setting.

import SwiftUI

// TODO-MIGRATION: persist GameSettingsModel.mode through A2Settings.versionIsolationMode.

@MainActor
final class GameSettingsModel: ObservableObject {
    @Published var mode = 1
    let modeNames = ["Shared", "Mods only", "Full"]

    var modeSubtitle: String {
        switch mode {
        case 0: return "Every version shares one game directory"
        case 2: return "Each version keeps everything separate"
        default: return "Only modded versions stay separate"
        }
    }
}

struct GameSettingsView: View {
    @StateObject private var model = GameSettingsModel()

    var body: some View {
        SettingsSection(title: "Version isolation", footer: "Resource files are always shared; only mods follow this setting.") {
            ForEach([0, 1, 2], id: \.self) { mode in
                Button(action: { model.mode = mode }) {
                    HStack {
                        Text(model.modeNames[mode])
                            .font(A2Type.subtitleCard)
                            .foregroundStyle(.cOnSurface)
                        Spacer()
                        if model.mode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.cPrimary)
                        }
                    }
                    .frame(minHeight: A2MinTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(model.modeSubtitle)
                .font(A2Type.caption)
                .foregroundStyle(.cOnSurfaceVariant)
        }
    }
}
