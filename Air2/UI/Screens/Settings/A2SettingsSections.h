//
//  A2SettingsSections.h
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
//
//  设置页的分组构建器。
//
//  ⚠️ 只放「已经有实现」的设置项。
//
//  教训：之前我凭空编了 30 个设置项（渲染器、Java 运行时、内存分配、
//  完整性检查…），全都没有对应实现 —— 图标、开关、滑块都渲染出来了，
//  点下去什么都不会发生。这比没有设置页更糟：用户会以为功能存在。
//
//  新增设置项的前提是有真实实现。宁缺毋滥。
//

#import <UIKit/UIKit.h>
#import "A2SettingsSection.h"

NS_ASSUME_NONNULL_BEGIN

/// 外观 —— 主题、亮暗模式、自定义背景
@interface A2AppearanceSettings : NSObject
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host;
/// 资源下载来源（CurseForge API Key 配置）
+ (A2SettingsSection *)buildSourceSectionWithHost:(UIViewController *)host;
@end

/// 游戏 —— 版本隔离档位
@interface A2GameSettings : NSObject
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host;
@end

/// 游戏 —— ★内存档位（自动/手动）+ 手动堆上限预设★。
/// 持久化 = A2Settings（memoryMode / ramAllocationMB）；消费点 = Player 的启动会话
/// （自动 ⇒ 按设备可用内存动态算 -Xmx，见 A2LaunchMemory）。真机判据行 `[MEM] ceiling=… -> -Xmx…`。
@interface A2MemorySettings : NSObject
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host;
@end

/// 游戏 —— ★运行环境★：渲染器 + Java 运行时两张列表。
/// 持久化 = Air2 自己的 NSUserDefaults（键见 A2LaunchContract.h 的两个契约常量）；
/// 选中未内置项 ⇒ 启动时如实阻断（不静默回退）。接线见 docs/ARCHITECTURE.md [RENDER-SEL]/[JRE-SEL]。
@interface A2RuntimeSettings : NSObject
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host;
@end

/// 关于 —— 版本信息、开源许可、运行日志、源代码、更新检查
@interface A2AboutSettings : NSObject
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host;
@end

/// 运行环境 · 启动链 —— JIT 供给状态 + 分级策略 + 新链开关
/// （★骨架：不实现真实隧道 / 开启机制；开启会如实走到「等待开启 + 原因」★）。
@interface A2JITSettings : NSObject
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host;
@end

NS_ASSUME_NONNULL_END
