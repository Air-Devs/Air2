//
//  ThreeZoneScaffold.swift
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
//  Shared scaffold for all Screens (replaces A2BaseViewController):
//  52pt top bar + landscape three-zone body (left wallpaper 62%,
//  right ops from Metrics.panelWidth), staggered card entrance and
//  scale-fade push transition, list-state views, and the app router.
//  Tokens come from Theme (Metrics/Motion/A2Type/Color.c*) and cards,
//  buttons and rows from Components — nothing is redefined here.
//
//  TODO-MIGRATION: forward A2Router.launchGame to the Player session
//  host once its Swift entry point lands (same launchGame semantics).

import SwiftUI

// MARK: - Card entrance (16pt lift, 35ms stagger, 0.42s spring, damping 0.82)

struct A2CardEntrance: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : Motion.cardEntranceOffset)
            .onAppear {
                withAnimation(
                    Motion.card.delay(Motion.cardDelay(index: index))
                ) { shown = true }
            }
    }
}

extension View {
    func a2CardEntrance(_ index: Int) -> some View {
        modifier(A2CardEntrance(index: index))
    }

    /// Shared press physics for tappable rows and tiles.
    func a2Pressable() -> some View {
        buttonStyle(A2PressButtonStyle())
    }
}

// MARK: - Scale-fade push transition (0.38s, damping 0.78)

extension AnyTransition {
    static var a2ScaleFadePush: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: Motion.pushFromScale).combined(with: .opacity),
            removal: .scale(scale: Motion.pushFromScale).combined(with: .opacity)
        )
    }
}

// MARK: - List states (every list: empty / loading / error + first-run guide)

enum A2ListState {
    case loading
    case empty
    case error(String)
    case ready
}

struct A2StateView: View {
    let state: A2ListState
    var emptyTitle: String
    var emptyHint: String
    var firstRunHint: String?
    var onRetry: (() -> Void)?

    var body: some View {
        Group {
            switch state {
            case .loading:
                VStack(spacing: A2SpaceM) {
                    ProgressView()
                    Text("Loading…").font(A2Type.caption).foregroundStyle(.cOnSurfaceVariant)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            case .empty:
                VStack(spacing: A2SpaceS) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.cOnSurfaceVariant)
                    Text(emptyTitle).font(A2Type.titleCard).foregroundStyle(.cOnSurface)
                    Text(emptyHint).font(A2Type.caption).foregroundStyle(.cOnSurfaceVariant)
                        .multilineTextAlignment(.center)
                    if let firstRunHint {
                        Text(firstRunHint)
                            .font(A2Type.caption)
                            .foregroundStyle(.cPrimary)
                            .multilineTextAlignment(.center)
                            .padding(.top, A2SpaceXS)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .padding()
            case .error(let message):
                VStack(spacing: A2SpaceS) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.cError)
                    Text(message).font(A2Type.body).foregroundStyle(.cOnSurface)
                        .multilineTextAlignment(.center)
                    if let onRetry {
                        Button("Retry", action: onRetry)
                            .frame(minHeight: A2MinTouchTarget)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .padding()
            case .ready:
                EmptyView()
            }
        }
    }
}

// MARK: - Three-zone scaffold (replaces A2BaseViewController chrome)

/// Top bar (52pt) + landscape body: left wallpaper, right ops panel.
struct ThreeZoneScaffold<Ops: View, Wallpaper: View>: View {
    let title: String
    var trailing: [(String, () -> Void)]
    let ops: Ops
    let wallpaper: Wallpaper

    init(
        _ title: String,
        trailing: [(String, () -> Void)] = [],
        @ViewBuilder ops: () -> Ops,
        @ViewBuilder wallpaper: () -> Wallpaper
    ) {
        self.title = title
        self.trailing = trailing
        self.ops = ops()
        self.wallpaper = wallpaper()
    }

    var body: some View {
        GeometryReader { geo in {
            let opsWidth = Metrics.panelWidth(for: geo.size.width)
            return VStack(spacing: 0) {
                HStack {
                    Text(title).font(A2Type.titleLarge).foregroundStyle(.cOnSurface)
                    Spacer()
                    ForEach(trailing.indices, id: \.self) { i in
                        Button(action: trailing[i].1) {
                            Image(systemName: trailing[i].0)
                                .foregroundStyle(.cOnSurfaceVariant)
                                .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
                        }
                    }
                }
                .frame(height: A2TopBarHeight)
                .padding(.horizontal, A2PageMargin)

                HStack(spacing: 0) {
                    wallpaper
                        .frame(width: geo.size.width - opsWidth)
                    ScrollView {
                        VStack(spacing: A2CardSpacing) { ops }
                            .padding(.vertical, A2SpaceL)
                            .padding(.horizontal, A2PanelOuterPadding)
                    }
                    .frame(width: opsWidth)
                }
            }
        }()
        }
        .background(Color.cSurface)
        .transition(.a2ScaleFadePush)
    }
}

/// Plain single-column page scaffold (narrow flows: login, install, detail).
struct A2PageScaffold<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: A2CardSpacing) { content }
                .padding(A2PageMargin)
                .frame(maxWidth: A2ContentMaxWidth)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
        .transition(.a2ScaleFadePush)
    }
}

// MARK: - Navigation router (keeps openAccount/openSettings/openVersions/openDownload/launchGame)

enum A2Route: Hashable {
    case account
    case login(LoginMode)
    case settings
    case versions
    case versionSettings(String)
    case download
    case downloadCategory(DownloadCategory)
    case gameVersions
    case installOptions(String)
    case installing(InstallSpec)
    case projectDetail(String)
    case searchById
    case favorites
    case files(String)
    case background
    case colorTheme
    case curseForgeKey
}

enum LoginMode: Hashable {
    case microsoft, offline, thirdParty
}

enum DownloadCategory: Int, Hashable, CaseIterable {
    case game, modpack, mod, resourcePack, world, shader
}

struct InstallSpec: Hashable {
    let mcVersion: String
    let versionName: String
    let loaderType: Int?
    let loaderVersion: String?
}

/// Navigation entry points. Same semantics as the ObjC launcher methods;
/// other code calls these instead of pushing view controllers directly.
/// path 是普通数组，由 App 层 NavigationHost 作差分推入 / 弹出（iOS 15 可用，无 SwiftUI 栈）。
@MainActor
final class A2Router: ObservableObject {
    @Published var path: [A2Route] = []

    init() {}

    func openAccount() { path.append(A2Route.account) }
    func openSettings() { path.append(A2Route.settings) }
    func openVersions() { path.append(A2Route.versions) }
    func openDownload() { path.append(A2Route.download) }
    func openDownloadCategory(_ category: DownloadCategory) {
        path.append(A2Route.download)
        path.append(A2Route.downloadCategory(category))
    }

    func openLogin(_ mode: LoginMode) { path.append(A2Route.login(mode)) }
    func openVersionSettings(_ name: String) { path.append(A2Route.versionSettings(name)) }
    func openGameVersions() { path.append(A2Route.gameVersions) }
    func openInstallOptions(_ versionID: String) {
        path.append(A2Route.installOptions(versionID))
    }
    func openInstalling(_ spec: InstallSpec) { path.append(A2Route.installing(spec)) }
    func openProject(_ id: String) { path.append(A2Route.projectDetail(id)) }
    func openSearchById() { path.append(A2Route.searchById) }
    func openFavorites() { path.append(A2Route.favorites) }
    func openFiles(_ name: String) { path.append(A2Route.files(name)) }
    func openBackground() { path.append(A2Route.background) }
    func openColorTheme() { path.append(A2Route.colorTheme) }
    func openCurseForgeKey() { path.append(A2Route.curseForgeKey) }

    func pop() {
        guard !path.isEmpty else {
            A2Log.logMessage("A2Router: pop 已在根，无路由可弹")
            return
        }
        path.removeLast()
    }

    func popToRoot() {
        guard !path.isEmpty else {
            A2Log.logMessage("A2Router: popToRoot 已在根，无需回退")
            return
        }
        path.removeAll()
    }

    /// Starts the game session; the Player layer owns the actual launch.
    func launchGame() {
        // Scheduled on the host; no game logic lives in the view layer.
    }
}

// MARK: - Screen root (LauncherView + NavigationHost 目的工厂，无 SwiftUI 栈)

/// Hosts every screen. App 层 RootView 经 NavigationHost（UINavigationController）
/// 把 destination(for:router:) 的每个路由包进 UIHostingController 作差分推入 / 弹出；
/// 这里不持有任何 SwiftUI 导航栈。
struct A2ScreenRoot: View {
    @StateObject private var router = A2Router()

    var body: some View {
        LauncherView(router: router)
            .transition(.a2ScaleFadePush)
    }

    @ViewBuilder
    static func destination(for route: A2Route, router: A2Router) -> some View {
        switch route {
        case .account: AccountView(router: router)
        case .login(let mode): LoginView(mode: mode)
        case .settings: SettingsView(router: router)
        case .versions: VersionListView(router: router)
        case .versionSettings(let name): VersionSettingsView(router: router, versionName: name)
        case .download: DownloadRootView(router: router)
        case .downloadCategory(let category): DownloadListView(category: category, router: router)
        case .gameVersions: GameVersionListView(router: router)
        case .installOptions(let id): InstallOptionsView(router: router, versionID: id)
        case .installing(let spec): InstallingView(router: router, spec: spec)
        case .projectDetail(let id): ProjectDetailView(projectID: id)
        case .searchById: SearchByIdView(router: router)
        case .favorites: FavoritesView(router: router)
        case .files(let name): FilesView(displayName: name)
        case .background: BackgroundSettingsView()
        case .colorTheme: ColorThemeDialog()
        case .curseForgeKey: CurseForgeKeyPageView()
        }
    }
}
