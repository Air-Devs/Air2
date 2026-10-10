//
//  Air2App.swift
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
//  应用入口（SwiftUI）。
//
//  启动顺序只有三步，且顺序不可换：
//    1. 崩溃兜底注册 —— 之后任何一行崩溃都能留下线索；
//    2. 日志轮转 —— 必须早于任何业务日志，否则上轮日志会被本轮内容污染；
//    3. 界面装配 —— 装配器在此创建一次，向下注入，不经过全局可变状态。
//

import SwiftUI

@main
struct Air2App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let container = DependencyContainer()

    init() {
        CrashGuard.install()
        A2Log.startSession()
        A2Log.log("Air2App: 进入启动流程")
    }

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
        }
    }
}
