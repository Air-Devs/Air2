//
//  DependencyContainer.swift
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
//  依赖注入装配点 —— App 层唯一的装配出口。
//
//  只做装配，不持有可变应用状态：存的都是各服务的实例引用，
//  状态归服务自己管。用方经 init 拿到实例，不直连全局。
//  因此这里不设 static shared，需要的地方各自创建一个轻量装配器。
//

import Foundation

public final class DependencyContainer {
    public let settings: A2Settings
    public let accounts: A2AccountManager

    public init(settings: A2Settings = .shared(), accounts: A2AccountManager = .shared()) {
        self.settings = settings
        self.accounts = accounts
    }

    /// 启动期目录迁移。
    /// 必须早于任何读取游戏目录的逻辑（版本扫描、主题背景等），否则会读到旧路径。
    public func performLaunchMigration() {
        A2Log.log("DependencyContainer: 目录迁移开始")
        A2GameDirMigration.migrateIfNeeded()
        A2Log.log("DependencyContainer: 目录迁移完成")
    }

    /// 启动自动登录：仅在开关打开且有当前账号时，刷新其凭据。
    /// 这里只做「续期」——离线账号无需网络，凭据类账号未过期时立即返回。
    /// 不阻塞启动：回调里只写日志，界面由账号页自己按需重读。
    public func refreshAccountForAutoLogin() {
        guard settings.autoLogin else {
            A2Log.log("DependencyContainer: 自动登录已关闭")
            return
        }
        guard let current = accounts.currentAccount else {
            A2Log.log("DependencyContainer: 自动登录跳过（无当前账号）")
            return
        }
        A2Log.log("DependencyContainer: 自动登录开始（当前账号 %@）", current.username)
        accounts.refreshCurrentAccountIfNeeded { success, error in
            if success {
                A2Log.log("DependencyContainer: 自动登录成功")
            } else {
                A2Log.log("DependencyContainer: 自动登录失败 %@", error?.localizedDescription ?? "未知错误")
            }
        }
    }
}
