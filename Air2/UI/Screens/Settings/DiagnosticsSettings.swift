//
//  DiagnosticsSettings.swift
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
//  Diagnostics group (replaces A2DiagnosticsSettings): session-log
//  viewer rows with size/date subtitles and an inline preview.

import SwiftUI

// TODO-MIGRATION: read session logs through the A2Log file facade in DiagnosticsSettingsModel.

struct LogFile: Hashable {
    let title: String
    let subtitle: String
}

@MainActor
final class DiagnosticsSettingsModel: ObservableObject {
    @Published var logs: [LogFile] = []
    @Published var preview: String?

    func reload() {}
    func open(_ log: LogFile) {}
}

struct DiagnosticsSettingsView: View {
    @StateObject private var model = DiagnosticsSettingsModel()

    var body: some View {
        VStack(spacing: A2CardSpacing) {
            SettingsSection(title: "Session logs", footer: "Logs are also visible under Files in the Air2 folder.") {
                if model.logs.isEmpty {
                    Text("Empty")
                        .font(A2Type.caption)
                        .foregroundStyle(.cOnSurfaceVariant)
                        .frame(minHeight: A2MinTouchTarget)
                }
                ForEach(model.logs, id: \.self) { log in
                    SettingsRow(model: SettingsRowModel(
                        symbolName: "doc.text",
                        title: log.title,
                        subtitle: log.subtitle,
                        accessory: .disclosure,
                        onTap: { model.open(log) }
                    ))
                }
            }
            if let preview = model.preview {
                GlassCard {
                    Text(String(preview.prefix(2000)))
                        .font(.body.monospaced())
                        .foregroundStyle(.cOnSurface)
                }
            }
        }
        .onAppear { model.reload() }
    }
}
