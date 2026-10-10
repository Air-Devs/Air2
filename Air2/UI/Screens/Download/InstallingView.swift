//
//  InstallingView.swift
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
//  Install progress (replaces A2InstallingViewController): ring
//  progress, current-stage detail, step checklist, cancel / retry /
//  done. The installer runs in Core; the view only observes.

import SwiftUI

// TODO-MIGRATION: observe A2GameInstaller progress callbacks from InstallingViewModel.

enum InstallPhase {
    case running, succeeded, failed(String)
}

@MainActor
final class InstallingViewModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var stageMessage = "Preparing…"
    @Published var steps: [(String, Bool)] = []
    @Published var phase: InstallPhase = .running

    func start(spec _: InstallSpec) {}
    func cancel() {}
    func retry(spec _: InstallSpec) {}
}

struct InstallingView: View {
    @ObservedObject var router: A2Router = A2Router()
    let spec: InstallSpec
    @StateObject private var model = InstallingViewModel()

    var body: some View {
        A2PageScaffold("Installing") {
            progressCard.a2CardEntrance(0)
            stepsCard.a2CardEntrance(1)
            actionCard.a2CardEntrance(2)
        }
        .onAppear { model.start(spec: spec) }
    }

    private var progressCard: some View {
        GlassCard {
            VStack(spacing: A2SpaceM) {
                RingProgress(
                    progress: CGFloat(model.progress),
                    centerText: "\(Int(model.progress * 100))%",
                    captionText: model.stageMessage
                )
                Text(model.stageMessage)
                    .font(A2Type.caption)
                    .foregroundStyle(.cOnSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var stepsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: A2SpaceXS) {
                ForEach(model.steps.indices, id: \.self) { i in
                    HStack {
                        Image(systemName: model.steps[i].1 ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.steps[i].1 ? .green : .secondary)
                        Text(model.steps[i].0)
                            .font(A2Type.subtitleCard)
                            .foregroundStyle(.cOnSurface)
                    }
                    .frame(minHeight: A2MinTouchTarget)
                }
            }
        }
    }

    private var actionCard: some View {
        GlassCard {
            switch model.phase {
            case .running:
                PrimaryButton(title: "Cancel", style: .secondary) { model.cancel() }
            case .failed(let message):
                VStack(spacing: A2SpaceS) {
                    Text(message).font(A2Type.body).foregroundStyle(.cError)
                    PrimaryButton(title: "Retry", symbolName: "arrow.clockwise") {
                        model.retry(spec: spec)
                    }
                }
            case .succeeded:
                PrimaryButton(title: "Done", symbolName: "checkmark") {
                    router.openVersions()
                }
            }
        }
    }
}
