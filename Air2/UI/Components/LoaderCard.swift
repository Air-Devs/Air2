//
//  LoaderCard.swift
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
//  Mapping: A2LoaderCard + A2LoaderCardDelegate
//  (initAsVanilla/initWithLoaderType:mcVersion:/chosen/selectedVersion/
//  unavailableReason/collapse/selectionDidChange/didExpand) -> LoaderKind +
//  LoaderVersion + LoaderCard.
//
//  deliberate boundary change: this View performs NO networking and imports
//  no Core API. Version fetching is injected as `loadVersions` (the owner
//  wires it to Core A2ModLoaderAPI); lazy first-expand fetch, retry, empty
//  (unsupported -> unavailable, collapsed, greyed) and failed states are all
//  preserved. Accent colors stay within primary/secondary/tertiary containers.
//  No UIKit host needed.
//

import SwiftUI

/// Mirrors A2ModLoaderType. Vanilla is a selectable non-expandable option.
public enum LoaderKind: Hashable, Equatable {
    case vanilla
    case fabric
    case quilt
    case legacyFabric
    case forge
    case neoForge
    case optiFine

    public var title: String {
        switch self {
        case .vanilla: return "Vanilla"
        case .fabric: return "Fabric"
        case .quilt: return "Quilt"
        case .legacyFabric: return "LegacyFabric"
        case .forge: return "Forge"
        case .neoForge: return "NeoForge"
        case .optiFine: return "OptiFine"
        }
    }

    public var symbol: String {
        switch self {
        case .vanilla: return "cube.fill"
        case .fabric: return "puzzlepiece.extension.fill"
        case .quilt: return "square.grid.3x3.fill"
        case .legacyFabric: return "clock.arrow.circlepath"
        case .forge: return "hammer.fill"
        case .neoForge: return "flame.fill"
        case .optiFine: return "wand.and.stars"
        }
    }
}

/// Mirrors A2ModLoaderVersion (version + stable).
public struct LoaderVersion: Identifiable, Equatable {
    public let id: String
    public var version: String
    public var stable: Bool
    public init(version: String, stable: Bool) {
        self.id = version
        self.version = version
        self.stable = stable
    }
}

private enum LoaderFetchState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

public struct LoaderCard: View {
    public var kind: LoaderKind
    public var mcVersion: String
    public var isChosen: Bool
    public var selectedVersion: LoaderVersion?
    public var unavailableReason: String?
    /// Injected fetch (owner routes to Core A2ModLoaderAPI). Never nil in
    /// production; Preview-only callers may pass a stub.
    public var loadVersions: ((LoaderKind, String) async throws -> [LoaderVersion])?
    public var onSelectionChange: (() -> Void)?
    public var onExpand: (() -> Void)?

    @State private var expanded = false
    @State private var fetchState: LoaderFetchState = .idle
    @State private var versions: [LoaderVersion] = []

    public init(
        kind: LoaderKind, mcVersion: String = "",
        isChosen: Bool = false, selectedVersion: LoaderVersion? = nil,
        unavailableReason: String? = nil,
        loadVersions: ((LoaderKind, String) async throws -> [LoaderVersion])? = nil,
        onSelectionChange: (() -> Void)? = nil, onExpand: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.mcVersion = mcVersion
        self.isChosen = isChosen
        self.selectedVersion = selectedVersion
        self.unavailableReason = unavailableReason
        self.loadVersions = loadVersions
        self.onSelectionChange = onSelectionChange
        self.onExpand = onExpand
    }

    private var unavailable: Bool { !(unavailableReason ?? "").isEmpty }

    public var body: some View {
        GlassCard(level: .l2, insets: EdgeInsets(top: A2SpaceS, leading: A2SpaceM, bottom: A2SpaceS, trailing: A2SpaceM)) {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                header
                if expanded, !unavailable {
                    bodyContent
                }
            }
        }
        .opacity(unavailable ? 0.55 : 1.0)
    }

    private var header: some View {
        Button {
            headerTapped()
        } label: {
            HStack(spacing: A2SpaceM) {
                A2Symbol(kind.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(A2Type.titleCard)
                        .foregroundStyle(unavailable ? Color.cOnSurfaceVariant : Color.cOnSurface)
                    Text(summaryText)
                        .font(A2Type.caption)
                        .foregroundStyle(isChosen && !unavailable ? Color.cPrimary : Color.cOnSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: A2SpaceS)
                trailingIcon
            }
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(A2PressButtonStyle())
        .disabled(unavailable)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var trailingIcon: some View {
        if unavailable {
            EmptyView()
        } else if kind != .vanilla, expanded {
            Image(systemName: "chevron.up").foregroundStyle(Color.cOnSurfaceVariant)
        } else if isChosen {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.cPrimary)
        } else if kind == .vanilla {
            Image(systemName: "circle").foregroundStyle(Color.cOnSurfaceVariant)
        } else {
            Image(systemName: "chevron.down").foregroundStyle(Color.cOnSurfaceVariant)
        }
    }

    private var summaryText: String {
        if let unavailableReason, !unavailableReason.isEmpty { return unavailableReason }
        if kind == .vanilla { return "No loader installed" }
        if isChosen, let selectedVersion { return "Selected \(selectedVersion.version)" }
        switch fetchState {
        case .loading: return "Fetching versions..."
        case let .failed(message): return message
        case .idle, .loaded: return "Tap to choose a version"
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch fetchState {
        case .idle, .loading:
            HStack(spacing: A2SpaceS) {
                ProgressView()
                Text("Fetching versions...")
                    .font(A2Type.caption)
                    .foregroundStyle(Color.cOnSurfaceVariant)
            }
            .padding(A2SpaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { await fetch() }
        case let .failed(message):
            VStack(alignment: .leading, spacing: A2SpaceS) {
                Text(message).font(A2Type.caption).foregroundStyle(Color.cOnSurfaceVariant)
                Button("Retry") { Task { await fetch() } }
                    .font(A2Type.button)
                    .foregroundStyle(Color.cPrimary)
                    .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
            }
            .padding(A2SpaceS)
        case .loaded:
            if versions.isEmpty {
                Text("No versions available")
                    .font(A2Type.caption)
                    .foregroundStyle(Color.cOnSurfaceVariant)
                    .padding(A2SpaceS)
            } else {
                VStack(spacing: 0) {
                    ForEach(versions) { version in
                        let selected = selectedVersion?.version == version.version
                        Button {
                            onSelectionChange?()
                        } label: {
                            HStack(spacing: A2SpaceS) {
                                Text(version.version)
                                    .font(A2Type.body)
                                    .foregroundStyle(selected ? Color.cPrimary : Color.cOnSurface)
                                Text(version.stable ? "Stable" : "Preview")
                                    .font(A2Type.caption)
                                    .foregroundStyle(Color.cOnSurfaceVariant)
                                Spacer()
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Color.cPrimary)
                                }
                            }
                            .frame(height: 46)
                            .padding(.horizontal, A2SpaceM)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxHeight: 256)
            }
        }
    }

    private func headerTapped() {
        if kind == .vanilla {
            A2ComponentLog("LoaderCard: vanilla chosen")
            onSelectionChange?()
            return
        }
        guard !unavailable else { return }
        withAnimation(.a2Standard) { expanded.toggle() }
        if expanded { onExpand?() }
    }

    private func fetch() async {
        guard let loadVersions else {
            A2ComponentLog("LoaderCard \(kind.title): no version provider injected; staying idle (owner must wire Core A2ModLoaderAPI)")
            return
        }
        guard fetchState != .loading else { return }
        fetchState = .loading
        do {
            let result = try await loadVersions(kind, mcVersion)
            versions = result
            fetchState = .loaded
            if result.isEmpty {
                A2ComponentLog("LoaderCard \(kind.title) has no versions for \(mcVersion); marking unavailable")
            } else {
                A2ComponentLog("LoaderCard \(kind.title): loaded \(result.count) versions")
            }
        } catch {
            fetchState = .failed("Failed to fetch versions. Check connection and retry.")
            A2ComponentLog("LoaderCard \(kind.title): version fetch failed because \(error.localizedDescription)")
        }
    }
}
