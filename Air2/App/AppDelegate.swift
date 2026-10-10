//
//  AppDelegate.swift
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
//  UIKit 生命周期钩子：JIT、前后台收尾、横屏锁定。
//  只做调度和兜底，不含业务规则；需要的服务经装配器拿，不直连全局。
//

import UIKit

/// JIT 供给点。Natives/Support 层实现后注入；未注入时直跑并记录原因。
public protocol JITProvider: AnyObject {
    /// 尝试启用 JIT。返回 true 表示已生效。
    @discardableResult func enableJustInTime() -> Bool
}

@objc(A2AppDelegate)
public final class AppDelegate: NSObject, UIApplicationDelegate {
    private let container = DependencyContainer()

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// JIT 供给（默认 nil：后端尚未接入，直跑并记录原因）。
    public weak var jitProvider: (any JITProvider)?

    // MARK: - 启动

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        A2Log.logMessage("AppDelegate: didFinishLaunching 开始")
        container.performLaunchMigration()
        // 首帧前完成主题的磁盘读取，避免首次渲染在布局过程中触发 IO。
        // UIKit 保证生命周期回调在主线程，因此这里同步取用主角隔离的主题是安全的。
        MainActor.assumeIsolated {
            _ = ThemeManager.shared.scheme
            A2Log.logMessage("AppDelegate: 主题已预热")
        }
        container.refreshAccountForAutoLogin()
        attemptJustInTime(reason: "冷启动")
        A2Log.logMessage("AppDelegate: didFinishLaunching 完成")
        return true
    }

    // MARK: - 方向锁定

    /// 全应用锁定横屏。
    /// Minecraft Java 版是横屏游戏：启动器若支持竖屏，从启动器切到游戏
    /// 要旋转一次，返回时又要转回来，两次旋转都产生黑屏与内容重排。
    /// 锁横屏后全程方向恒定，也没有旋转带来的布局抖动。
    public func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .landscape
    }

    // MARK: - Scene 配置

    /// 返回 Scene 配置。
    /// 用代码显式指定，不依赖 Info.plist 的 UIApplicationSceneManifest 清单 ——
    /// 清单方式在字段不全时会静默失败（没有窗口 / 白屏 / 闪退），原因极难定位。
    /// 建窗由 SwiftUI 的 WindowGroup 负责，这里不再挂 UIKit delegate。
    public func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = nil
        return config
    }

    // MARK: - JIT

    private func attemptJustInTime(reason: String) {
        guard let provider = jitProvider else {
            A2Log.logMessage("AppDelegate: JIT 未启用（\(reason)；供给层尚未接入，直跑）")
            return
        }
        if provider.enableJustInTime() {
            A2Log.logMessage("AppDelegate: JIT 已启用（\(reason)）")
        } else {
            A2Log.logMessage("AppDelegate: JIT 启用失败（\(reason)），降级直跑")
        }
    }

    // MARK: - 前后台

    public func applicationDidEnterBackground(_ application: UIApplication) {
        A2Log.logMessage("AppDelegate: 进入后台开始")
        // 会话可能正在跑（下载、解压、日志落盘）：申请一段后台时间让收尾完成，
        // 而不是被系统直接挂起导致半截文件。
        backgroundTask = application.beginBackgroundTask(withName: "Air2.session-drain") { [weak self] in
            guard let self else { return }
            A2Log.logMessage("AppDelegate: 后台时间耗尽，结束收尾（系统回收属正常）")
            application.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
        if backgroundTask == .invalid {
            A2Log.logMessage("AppDelegate: 后台任务申请失败，直接挂起（系统配额不足属正常）")
        }
        A2Log.logMessage("AppDelegate: 进入后台完成")
    }

    public func applicationWillEnterForeground(_ application: UIApplication) {
        A2Log.logMessage("AppDelegate: 回到前台开始")
        if backgroundTask != .invalid {
            application.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        attemptJustInTime(reason: "回前台")
        A2Log.logMessage("AppDelegate: 回到前台完成")
    }
}
