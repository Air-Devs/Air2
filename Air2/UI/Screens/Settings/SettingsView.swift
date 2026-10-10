//
//  SettingsView.swift
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
//  Settings shell (replaces A2SettingsViewController): category
//  rail (appearance / game / diagnostics) with the matching section
//  group below. Only shipped settings appear — no placeholders.

import SwiftUI

enum SettingsTab: Hashable {
    case appearance, game, diagnostics
}

struct SettingsView: View {
    @ObservedObject var router: A2Router = A2Router()
    @State private var tab: SettingsTab = .appearance

    var body: some View {
        ThreeZoneScaffold(
            "Settings",
            ops: {
                tabCard.a2CardEntrance(0)
                switch tab {
                case .appearance:
                    AppearanceSettingsView(router: router).a2CardEntrance(1)
                case .game:
                    GameSettingsView().a2CardEntrance(1)
                case .diagnostics:
                    DiagnosticsSettingsView().a2CardEntrance(1)
                }
            },
            wallpaper: {
                Color.cSurface
            }
        )
    }

    private var tabCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                settingsTabRow(.appearance, title: "Appearance", symbol: "paintpalette.fill")
                settingsTabRow(.game, title: "Game", symbol: "gamecontroller.fill")
                settingsTabRow(.diagnostics, title: "Diagnostics", symbol: "stethoscope")
            }
        }
    }

    private func settingsTabRow(_ tab: SettingsTab, title: String, symbol: String) -> some View {
        Button(action: { self.tab = tab }) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(self.tab == tab ? .cPrimary : .secondary)
                Text(title)
                    .font(A2Type.subtitleCard)
                    .foregroundStyle(.cOnSurface)
                Spacer()
                if self.tab == tab {
                    Image(systemName: "checkmark").foregroundStyle(.cPrimary)
                }
            }
            .frame(minHeight: A2MinTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
