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

@MainActor
final class CurseForgePromptModel: ObservableObject {
    @Published var key = ""
    @Published var isValidating = false
    @Published var errorMessage: String?

    /// 先把候选 Key 写进 CurseForge 客户端再探一次真实请求；通过才留下，
    /// 失败则把旧 Key 写回去，保证「取消 / 校验失败」都不改变现状。
    func save() async -> Bool {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            errorMessage = "请先粘贴 API Key"
            return false
        }
        let previous = A2CurseForgeAPI.shared().apiKey
        isValidating = true
        errorMessage = nil
        A2CurseForgeAPI.setAPIKey(candidate)

        let result: (valid: Bool, error: Error?) = await withCheckedContinuation { continuation in
            A2CurseForgeAPI.shared().validateKey(completion: { valid, error in
                continuation.resume(returning: (valid, error))
            })
        }
        isValidating = false

        if result.valid {
            A2ComponentLog("curseforge-key: 校验通过并保存")
            return true
        }
        A2CurseForgeAPI.setAPIKey(previous)
        errorMessage = result.error?.localizedDescription ?? "Key 无效，请到 console.curseforge.com 确认后重试"
        A2ComponentLog("curseforge-key: 校验失败，已回滚旧 Key（\(errorMessage ?? "")）")
        return false
    }
}

struct CurseForgePromptSheet: View {
    @StateObject private var model = CurseForgePromptModel()
    @Environment(\.dismiss) private var dismiss
    var onSaved: (() -> Void)?
    var onCancel: (() -> Void)?

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
                Button("Cancel") {
                    onCancel?()
                    dismiss()
                }
                .frame(minHeight: A2MinTouchTarget)
            }
        }
    }
}
