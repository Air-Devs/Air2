//
//  BackgroundSettingsView.swift
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
//  Custom wallpaper (replaces A2BackgroundSettingsViewController):
//  live preview plus source picker, blur, dark overlay and right
//  fade. No gradients — image or plain theme surface only.

import SwiftUI

// TODO-MIGRATION: bind BackgroundSettingsModel to A2ThemeManager background persistence.

@MainActor
final class BackgroundSettingsModel: ObservableObject {
    @Published var hasImage = false
    @Published var blur: Double = 0
    @Published var darkOverlay: Double = 0.28
    @Published var fadeRatio: Double = 0.35

    func pickImage() {}
    func clearImage() { hasImage = false }
}

struct BackgroundSettingsView: View {
    @StateObject private var model = BackgroundSettingsModel()

    var body: some View {
        A2PageScaffold("Background") {
            previewCard.a2CardEntrance(0)
            sourceCard.a2CardEntrance(1)
            adjustCard.a2CardEntrance(2)
        }
    }

    private var previewCard: some View {
        GlassCard {
            ZStack {
                RoundedRectangle(cornerRadius: A2RadiusM)
                    .fill(Color.cSurfaceContainerLow)
                    .frame(height: 180)
                Text(model.hasImage ? "Wallpaper preview" : "Theme surface (no image)")
                    .font(A2Type.caption)
                    .foregroundStyle(.cOnSurfaceVariant)
            }
        }
    }

    private var sourceCard: some View {
        SettingsSection(title: "Source") {
            SettingsRow(symbolName: "photo.fill", title: "Choose from library", accessory: .disclosure, accessory: .disclosure) {
                model.pickImage()
            }
            if model.hasImage {
                SettingsRow(symbolName: "trash", title: "Remove wallpaper", destructive: true, accessory: .disclosure, accessory: .disclosure) {
                    model.clearImage()
                }
            }
        }
    }

    private var adjustCard: some View {
        SettingsSection(title: "Adjustments") {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                Text("Blur")
                    .font(A2Type.subtitleCard)
                Slider(value: $model.blur, in: 0 ... 100)
                    .frame(minHeight: A2MinTouchTarget)
                Text("Dark overlay (keeps cards readable)")
                    .font(A2Type.subtitleCard)
                Slider(value: $model.darkOverlay, in: 0 ... 1)
                    .frame(minHeight: A2MinTouchTarget)
                Text("Right fade (blends into the ops panel)")
                    .font(A2Type.subtitleCard)
                Slider(value: $model.fadeRatio, in: 0 ... 1)
                    .frame(minHeight: A2MinTouchTarget)
            }
        }
    }
}
