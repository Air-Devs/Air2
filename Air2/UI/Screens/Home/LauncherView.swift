//
//  LauncherView.swift
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
//  Home screen (replaces A2LauncherViewController). Layout fidelity
//  baseline: right panel holds three cards (account, version, recent)
//  with a breathing spacer; tag-tint accents map to semantic roles.
//  No shortcut grid here — it duplicated the top-bar entries.

import SwiftUI

// TODO-MIGRATION: bind LauncherViewModel to A2AccountManager/A2VersionManager observations.

struct LauncherAccount: Hashable {
    let name: String
    let typeLabel: String
}

struct LauncherVersion: Hashable {
    let name: String
    let meta: String
}

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var account: LauncherAccount?
    @Published var currentVersion: LauncherVersion?
    @Published var recentVersions: [LauncherVersion] = []

    /// Refreshes cards from Core singletons; scheduled, never blocking the view.
    func reload() {
        // Reads A2AccountManager.shared / A2VersionManager.shared (see file header).
    }
}

struct LauncherView: View {
    @ObservedObject var router: A2Router = A2Router()
    @StateObject private var model = LauncherViewModel()

    var body: some View {
        ThreeZoneScaffold(
            "Air2",
            trailing: [
                ("person.crop.circle", router.openAccount),
                ("arrow.down.circle", router.openDownload),
                ("gearshape", router.openSettings),
            ],
            ops: {
                accountCard.a2CardEntrance(0)
                versionCard.a2CardEntrance(1)
                recentCard.a2CardEntrance(2)
            },
            wallpaper: {
                BackgroundView()
            }
        )
        .onAppear { model.reload() }
    }

    // MARK: - Account card (taps through to account management)

    private var accountCard: some View {
        Button(action: router.openAccount) {
            GlassCard {
                HStack(spacing: A2SpaceM) {
                    SkinHeadView(
                        fallbackText: String(model.account?.name.prefix(1) ?? "?"),
                        size: 46
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.account?.name ?? "No account")
                            .font(A2Type.titleCard)
                    .foregroundStyle(.cOnSurface)
                        Text(model.account?.typeLabel ?? "Add one to get started")
                            .font(A2Type.caption)
                            .foregroundStyle(.cOnSurfaceVariant)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cOutline)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Version card (current version + Filled launch CTA)

    private var versionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                HStack(spacing: A2SpaceM) {
                    Image(systemName: "cube.fill")
                        .foregroundStyle(.cPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.currentVersion?.name ?? "No version installed")
                            .font(A2Type.titleCard)
                            .foregroundStyle(.cOnSurface)
                        Text(model.currentVersion?.meta ?? "Install one from Download")
                            .font(A2Type.caption)
                            .foregroundStyle(.cOnSurfaceVariant)
                    }
                    Spacer()
                    Button(action: { router.openVersionSettings(model.currentVersion?.name ?? "") }) {
                        Image(systemName: "gearshape")
                            .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
                    }
                }
                PrimaryButton(title: "Launch Game", symbolName: "play.fill") {
                    router.launchGame()
                }
                Button(action: router.openVersions) {
                    Text("Version settings")
                        .font(A2Type.caption)
                        .foregroundStyle(.cPrimary)
                        .frame(minHeight: A2MinTouchTarget)
                }
            }
        }
    }

    // MARK: - Recent card (recently played versions)

    private var recentCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                Text("Recently played")
                    .font(A2Type.caption)
                    .foregroundStyle(.cOnSurfaceVariant)
                if model.recentVersions.isEmpty {
                    Text("Versions you play will show up here.")
                        .font(A2Type.caption)
                        .foregroundStyle(.cOnSurfaceVariant)
                } else {
                    ForEach(model.recentVersions, id: \.self) { version in
                        Button(action: router.openVersions) {
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundStyle(.cPrimary)
                                Text(version.name)
                                    .font(A2Type.subtitleCard)
                                    .foregroundStyle(.cOnSurface)
                                Spacer()
                            }
                            .frame(minHeight: A2MinTouchTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
