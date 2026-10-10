//
//  LoginView.swift
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
//  Single login page (replaces A2LoginViewController). One page per
//  mode: Microsoft shows device-code + polling, the others show a
//  form. Filled button is the only submit path.

import SwiftUI

// TODO-MIGRATION: bind LoginViewModel to A2MicrosoftAuth/A2YggdrasilAuth completion handlers.

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var username = ""
    @Published var password = ""
    @Published var serverURL = ""
    @Published var deviceCode = ""
    @Published var verificationURL = ""
    @Published var isBusy = false
    @Published var errorMessage: String?

    var offlineNameError: String? {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Name cannot be empty." }
        if trimmed.count < 3 || trimmed.count > 16 { return "Use 3–16 characters." }
        return nil
    }

    func beginMicrosoftLogin() {}
    func copyDeviceCode() {}
    func openVerificationPage() {}
    func performLogin(mode _: LoginMode) {}
}

struct LoginView: View {
    let mode: LoginMode
    @StateObject private var model = LoginViewModel()
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch mode {
        case .microsoft: return "Microsoft login"
        case .offline: return "Offline login"
        case .thirdParty: return "Auth server login"
        }
    }

    var body: some View {
        A2PageScaffold(title) {
            if mode == .microsoft {
                microsoftCard.a2CardEntrance(0)
            } else {
                formCard.a2CardEntrance(0)
            }
            if let errorMessage = model.errorMessage {
                A2StateView(
                    state: .error(errorMessage),
                    emptyTitle: "",
                    emptyHint: ""
                ) { model.errorMessage = nil }
            }
        }
        .onAppear { if mode == .microsoft { model.beginMicrosoftLogin() } }
    }

    private var microsoftCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: A2SpaceM) {
                Text("Enter this code on your other device, then wait here.")
                    .font(A2Type.body)
                    .foregroundStyle(.cOnSurfaceVariant)
                HStack {
                    Text(model.deviceCode.isEmpty ? "—" : model.deviceCode)
                        .font(.title3.monospaced())
                    Spacer()
                    Button(action: model.copyDeviceCode) {
                        Image(systemName: "doc.on.doc")
                            .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
                    }
                }
                PrimaryButton(title: "Open verification page", style: .secondary) {
                    model.openVerificationPage()
                }
                if model.isBusy { ProgressView().frame(maxWidth: .infinity) }
                Text("First run: keep this page open until the browser step finishes.")
                    .font(A2Type.caption)
                    .foregroundStyle(.cOnSurfaceVariant)
            }
        }
    }

    private var formCard: some View {
        GlassCard {
            VStack(spacing: A2SpaceM) {
                TextField("Username", text: $model.username)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: A2MinTouchTarget)
                if mode == .thirdParty {
                    SecureField("Password", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: A2MinTouchTarget)
                    TextField("Auth server URL", text: $model.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: A2MinTouchTarget)
                }
                if let nameError = model.offlineNameError, mode == .offline, !model.username.isEmpty {
                    Text(nameError).font(A2Type.caption).foregroundStyle(.cError)
                }
                PrimaryButton(title: "Log in", symbolName: "person.badge.key.fill") {
                    model.performLogin(mode: mode)
                }
                .disabled(model.isBusy)
            }
        }
    }
}
