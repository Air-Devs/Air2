//
//  RootView.swift
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
//  根导航容器 —— 路由栈 + 主页 + 全部分支页面的装配点。
//  横屏由 Info.plist 与 AppDelegate 的方向锁定保证，这里不再重复声明。
//  主题只消费（表面色、窗口外观），色值定义在 Theme 层。
//  页面转场动效见 NavigationHost（UIKit 宿主）与 AnyTransition.a2ScaleFadePush。
//

import SwiftUI

@MainActor
struct RootView: View {
    let container: DependencyContainer

    @ObservedObject private var theme: ThemeManager
    @StateObject private var router: A2Router
    @Environment(\.scenePhase) private var scenePhase
    @State private var didLogFirstAppearance = false

    init(container: DependencyContainer) {
        self.container = container
        _theme = ObservedObject(wrappedValue: ThemeManager.shared)
        _router = StateObject(wrappedValue: A2Router())
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            LauncherView(router: router)
                .navigationDestination(for: A2Route.self) { route in
                    destination(for: route)
                }
        }
        .background(theme.scheme.surface)
        .onAppear {
            // SwiftUI 按主题状态声明式渲染，不存在「先取色后改样式」问题；
            // 这里只同步窗口外观（亮 / 暗 / 跟随系统）并记录启动完成。
            theme.applyAppearance(to: keyWindow())
            guard !didLogFirstAppearance else { return }
            didLogFirstAppearance = true
            A2Log.logMessage("RootView: 根视图已上屏，启动流程完成")
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            // 回到前台时同步窗口外观，走和「用户手动切主题」同一条路径。
            theme.applyAppearance(to: keyWindow())
        }
    }

    private func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let key = scene.windows.first(where: \.isKeyWindow) { return key }
        }
        return scenes.flatMap(\.windows).first
    }

    // MARK: - 路由装配

    @ViewBuilder
    private func destination(for route: A2Route) -> some View {
        switch route {
        case .account:
            AccountView(router: router)
        case .login(let mode):
            LoginView(mode: mode)
        case .settings:
            SettingsView(router: router)
        case .versions:
            VersionListView(router: router)
        case .versionSettings(let name):
            VersionSettingsView(router: router, versionName: name)
        case .download:
            DownloadRootView(router: router)
        case .downloadCategory(let category):
            DownloadListView(category: category)
        case .gameVersions:
            GameVersionListView(router: router)
        case .installOptions(let versionID):
            InstallOptionsView(router: router, versionID: versionID)
        case .installing(let spec):
            InstallingView(router: router, spec: spec)
        case .projectDetail(let identifier):
            ProjectDetailView(projectID: identifier)
        case .searchById:
            SearchByIdView(router: router)
        case .favorites:
            FavoritesView(router: router)
        case .files(let name):
            FilesView(displayName: name)
        case .background:
            BackgroundSettingsView()
        case .colorTheme:
            ColorThemeDialog(onConfirm: nil)
        case .curseForgeKey:
            CurseForgeKeyPageView()
        }
    }
}
