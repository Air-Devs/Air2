//
//  ColorThemeDialog.swift
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
//  Color-theme dialog (replaces A2ColorThemeDialog): palette-style
//  picker plus a seed-color wheel. Confirm applies both at once.

import SwiftUI

// TODO-MIGRATION: apply ColorThemeModel choices via A2ThemeManager (selectedKind/paletteStyle/customSeedColor).

@MainActor
final class ColorThemeModel: ObservableObject {
    @Published var seed = Color.cPrimary
    @Published var style = 0
    let styles = ["TonalSpot", "Neutral", "Vibrant", "Expressive"]
}

struct ColorThemeDialog: View {
    @StateObject private var model = ColorThemeModel()
    @Environment(\.dismiss) private var dismiss
    var onConfirm: ((Color, Int) -> Void)?

    var body: some View {
        A2PageScaffold("Color theme") {
            GlassCard {
                VStack(alignment: .leading, spacing: A2SpaceS) {
                    Text("Seed color")
                        .font(A2Type.caption)
                        .foregroundStyle(.cOnSurfaceVariant)
                    ColorPicker("Seed", selection: $model.seed)
                        .frame(minHeight: A2MinTouchTarget)
                }
            }
            .a2CardEntrance(0)
            SettingsSection(title: "Palette style") {
                ForEach(model.styles.indices, id: \.self) { i in
                    Button(action: { model.style = i }) {
                        HStack {
                            Text(model.styles[i])
                                .font(A2Type.subtitleCard)
                                .foregroundStyle(.cOnSurface)
                            Spacer()
                            if model.style == i {
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
            .a2CardEntrance(1)
            GlassCard {
                HStack(spacing: A2SpaceM) {
                    PrimaryButton(title: "Cancel", style: .secondary) { dismiss() }
                    PrimaryButton(title: "Confirm") {
                        onConfirm?(model.seed, model.style)
                        dismiss()
                    }
                }
            }
            .a2CardEntrance(2)
        }
    }
}
