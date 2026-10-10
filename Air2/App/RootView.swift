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
//  根导航容器 —— NavigationHost 作差分推入 / 弹出 + 主页装配点。
//  横屏由 Info.plist 与 AppDelegate 的方向锁定保证，这里不再重复声明。
//  主题只消费（表面色、窗口外观），色值定义在 Theme 层。
//  页面转场动效见 NavigationHost（UIKit 宿主，默认缩放淡入）。
//  不用 NavigationStack：部署目标 iOS 15.0 无该 API。

import SwiftUI
import UIKit

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
        NavigationHostBridge(router: router)
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
}

// MARK: - NavigationHost 桥接（router.$path 差分同步）

/// 把 router.path（[A2Route]）映射到 NavigationHost 的控制器栈：
/// path 每多一项就把 A2ScreenRoot.destination 包进 UIHostingController
/// 以 scaleFade 推入；path 缩短就弹到对应深度。转场样式沿用
/// NavigationHost 默认的缩放淡入（原 ObjC A2NavigationController 关键帧语义）。
@MainActor
private struct NavigationHostBridge: UIViewControllerRepresentable {
    @ObservedObject var router: A2Router

    func makeUIViewController(context: Context) -> NavigationHost {
        let host = NavigationHost()
        let root = UIHostingController(rootView: LauncherView(router: router))
        host.setViewControllers([root], animated: false)
        return host
    }

    func updateUIViewController(_ host: NavigationHost, context: Context) {
        let wantDepth = router.path.count + 1
        let haveDepth = host.viewControllers.count
        guard wantDepth != haveDepth else { return }
        if wantDepth > haveDepth {
            // 只推入新增的尾部，避免整栈重建导致动画与状态丢失。
            for route in router.path.suffix(wantDepth - haveDepth) {
                let view = A2ScreenRoot.destination(for: route, router: router)
                let next = UIHostingController(rootView: view)
                host.pushViewController(next, transition: .scaleFade, animated: true)
            }
        } else if wantDepth <= 1 {
            host.popToRootViewController(animated: true)
        } else {
            let target = host.viewControllers[wantDepth - 1]
            host.popToViewController(target, animated: true)
        }
    }
}
