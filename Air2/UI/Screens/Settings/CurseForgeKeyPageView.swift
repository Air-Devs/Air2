//
//  CurseForgeKeyPageView.swift
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
//  Key management page (replaces A2CurseForgeKeyPageViewController).
//  Entry point only — paste / validate / clear all live here.

import SwiftUI

// TODO-MIGRATION: persist CurseForgeKeyPageModel.key through the Keychain-backed CurseForge store.

@MainActor
final class CurseForgeKeyPageModel: ObservableObject {
    @Published var key = ""
    @Published var statusText = "Not set — CurseForge unavailable"
    @Published var isBusy = false
    @Published var notice: String?

    func save() {}
    func clear() {
        key = ""
        statusText = "Not set — CurseForge unavailable"
    }
}

struct CurseForgeKeyPageView: View {
    @StateObject private var model = CurseForgeKeyPageModel()

    var body: some View {
        A2PageScaffold("CurseForge API key") {
            GlassCard {
                VStack(alignment: .leading, spacing: A2SpaceM) {
                    Text("Status: \(model.statusText)")
                        .font(A2Type.subtitleCard)
                        .foregroundStyle(.cOnSurface)
                    SecureField("Paste API key", text: $model.key)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: A2MinTouchTarget)
                    PrimaryButton(title: "Validate & save", symbolName: "checkmark.seal") {
                        model.save()
                    }
                    .disabled(model.key.isEmpty || model.isBusy)
                    if model.isBusy { ProgressView().frame(maxWidth: .infinity) }
                    if let notice = model.notice {
                        Text(notice)
                            .font(A2Type.caption)
                            .foregroundStyle(.cOnSurfaceVariant)
                    }
                    Button(action: { model.clear() }) {
                        Text("Clear key")
                            .foregroundStyle(.cError)
                            .frame(minHeight: A2MinTouchTarget)
                    }
                }
            }
            .a2CardEntrance(0)
        }
    }
}
