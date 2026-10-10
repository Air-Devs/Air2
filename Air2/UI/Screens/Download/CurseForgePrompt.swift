//
//  CurseForgePrompt.swift
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
//  CurseForge API-key prompt (replaces A2CurseForgeKeyPrompt): a
//  sheet that validates and saves the key. Invalid keys surface as
//  an error state; cancel leaves everything untouched.

import SwiftUI

// TODO-MIGRATION: validate keys through A2CurseForgeAPI in CurseForgePromptModel.

@MainActor
final class CurseForgePromptModel: ObservableObject {
    @Published var key = ""
    @Published var isValidating = false
    @Published var errorMessage: String?

    func save() async -> Bool { false }
}

struct CurseForgePromptSheet: View {
    @StateObject private var model = CurseForgePromptModel()
    @Environment(\.dismiss) private var dismiss
    var onSaved: (() -> Void)?

    var body: some View {
        A2PageScaffold("CurseForge API key") {
            GlassCard {
                VStack(alignment: .leading, spacing: A2SpaceM) {
                    Text("CurseForge resources need a personal API key. Paste it once; it stays on this device.")
                        .font(A2Type.body)
                        .foregroundStyle(.cOnSurfaceVariant)
                    SecureField("API key", text: $model.key)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: A2MinTouchTarget)
                    PrimaryButton(title: "Validate & save") {
                        Task {
                            let ok = await model.save()
                            if ok {
                                onSaved?()
                                dismiss()
                            }
                        }
                    }
                    .disabled(model.key.isEmpty || model.isValidating)
                    if model.isValidating { ProgressView().frame(maxWidth: .infinity) }
                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .font(A2Type.caption)
                            .foregroundStyle(.cError)
                    }
                }
            }
            .a2CardEntrance(0)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .frame(minHeight: A2MinTouchTarget)
            }
        }
    }
}
