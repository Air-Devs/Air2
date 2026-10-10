//
//  AccountView.swift
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
//  Account management (replaces A2AccountViewController): account
//  list card, add-account section (Microsoft / offline / auth server),
//  auto-login row. Full empty/loading/error states.

import SwiftUI

// TODO-MIGRATION: bind AccountViewModel to A2AccountManager (accounts/currentAccount/select).

@MainActor
final class AccountViewModel: ObservableObject {
    @Published var state: A2ListState = .loading
    @Published var accounts: [AccountRowData] = []
    @Published var autoLogin = true

    func reload() {
        // Scheduled Core read; view only triggers.
        Task { @MainActor in
            self.state = self.accounts.isEmpty ? .empty : .ready
        }
    }

    func select(_ account: AccountRowData) {}
    func refresh(_ account: AccountRowData) {}
    func remove(_ account: AccountRowData) {}
}

struct AccountView: View {
    @ObservedObject var router: A2Router = A2Router()
    @StateObject private var model = AccountViewModel()

    var body: some View {
        A2PageScaffold("Accounts") {
            GlassCard {
                VStack(alignment: .leading, spacing: A2SpaceS) {
                    Text("Accounts")
                        .font(A2Type.caption)
                        .foregroundStyle(.cOnSurfaceVariant)
                    A2StateView(
                        state: model.state,
                        emptyTitle: "No accounts yet",
                        emptyHint: "Add a Microsoft, offline, or auth-server account to start playing.",
                        firstRunHint: "First run: pick Microsoft if you own the game."
                    ) { model.reload() }
                    ForEach(model.accounts, id: \.self) { account in
                        AccountRowView(account: account, actions: RowBridge(model: model, router: router))
                    }
                }
            }
            .a2CardEntrance(0)

            SettingsSection(title: "Add account") {
                SettingsRow(symbolName: "person.badge.key.fill", title: "Microsoft login", accessory: .disclosure, accessory: .disclosure) {
                    router.openLogin(.microsoft)
                }
                SettingsRow(symbolName: "person.fill", title: "Offline account", accessory: .disclosure, accessory: .disclosure) {
                    router.openLogin(.offline)
                }
                SettingsRow(symbolName: "server.rack", title: "Auth server (Yggdrasil)") {
                    router.openLogin(.thirdParty)
                }
            }
            .a2CardEntrance(1)

            SettingsSection(title: "Session") {
                Toggle("Auto login at launch", isOn: $model.autoLogin)
                    .font(A2Type.subtitleCard)
                    .frame(minHeight: A2MinTouchTarget)
            }
            .a2CardEntrance(2)
        }
        .onAppear { model.reload() }
    }

    private struct RowBridge: AccountRowActions {
        let model: AccountViewModel
        let router: A2Router
        func select(_ account: AccountRowData) { model.select(account) }
        func refresh(_ account: AccountRowData) { model.refresh(account) }
        func showMore(_ account: AccountRowData) { model.remove(account) }
    }
}
