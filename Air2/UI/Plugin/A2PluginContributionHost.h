//
//  A2PluginContributionHost.h
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
//  插件贡献点的**宿主装配处 + 渲染入口**（P2 第二步：接线到界面）。
//
//  ## 为什么要有这一层
//
//  第一步（`A2PluginContribution`）只产出两样东西：校验过的贡献集、纯内存注册表。
//  它不知道「谁读」也「谁画」。接线时有三个坑，本类一次解决：
//
//   ① **一份注册表**。安装器写、七处插入点读，必须是**同一个实例** ——
//      各页各 new 一份的话，「停用 / 卸载 ⇒ 插入点立刻不画」只在安装器那一份里成立，
//      界面上会继续显示已经不存在的东西。
//   ② **一条线程边界**。安装在后台线程（要等 10 次确认），插入点全在主线程。
//      串行化放在注册表内部（见 `A2PluginContribution.h` 不变量 4），本类只负责
//      「装配一次、以后都拿同一个」。
//   ③ **component → 视图的映射只有一份**。`PLUGIN-COMPAT.md` 2.3 的叶子组件由这里落到
//      UIKit；某处插入点画不出某个 component 时**不画 + 记一行判据**，不伪造、也不崩。
//
//  ## 七个插入点（一处一行判据日志）
//
//    slot                    | 位置            | 宿主
//    ------------------------+-----------------+----------------------------------
//    home.toolbar.action     | 主页顶栏右侧    | A2LauncherViewController
//    home.card.badge         | 主页主卡右上角  | A2LauncherViewController
//    versions.list.badge     | 版本列表项右侧  | A2VersionListViewController → A2VersionRowView
//    version.detail.header   | 版本详情标题卡  | A2VersionSettingsViewController
//    settings.section        | 设置页附加分区  | A2SettingsViewController
//    home.section            | 主页卡片区下方  | A2LauncherViewController
//    launch.overlay          | 启动遮罩内      | A2LaunchOverlay
//
//  判据行格式（每处插入点**每次渲染一行**，用于「插件没生效」的分诊）：
//
//    [A2-PLUGIN-UI] <slot> 渲染 N 条（跳过 M 条：原因）
//
//  ## 边界（不要越）
//
//  · 只**新增**视图或可选行，不改原页面的布局结构与视觉；未装插件时七处一行都不加。
//  · P2 没有运行时：按钮点了只能如实说「需要 P3 运行时」，不能假装执行了动作。
//  · 本类不碰磁盘（磁盘事实来源仍是 `A2PluginRegistry`），也不解析 manifest。
//

#import <UIKit/UIKit.h>

#import "A2PluginContribution.h"

@class A2PluginInstaller;
@class A2PluginRegistry;
@class A2SettingsSection;

NS_ASSUME_NONNULL_BEGIN

@interface A2PluginContributionHost : NSObject

#pragma mark - 装配（全进程各一份）

/// 包注册表（`Plugins/registry.json`）—— **磁盘**上的唯一事实来源。
/// 插件管理页、设置页的「已安装 N 个」都读它；不要各页自己 `initWithPluginsDirectory:`。
+ (A2PluginRegistry *)packageRegistry;

/// 贡献点注册表 —— 安装器写、七处插入点读的是**同一个**实例。
/// 只读用途（诊断 / 断言）；要往里面写请走 `installer`。
+ (A2PluginContributionRegistry *)contributionRegistry;

/// 安装器（已接上上面那个贡献点注册表）。插件管理页用它做安装 / 启停 / 卸载。
+ (A2PluginInstaller *)installer;

/// 装配一次（幂等）：建三件套 + Phase A 建表（把「已装且已启用」的插件贡献接回注册表）。
/// 启动早期由 `A2AppDelegate` 调一次；其余入口也会懒调，绝不会看到「装了一半」的状态。
+ (void)assembleIfNeeded;

#pragma mark - 读（七处插入点的唯一入口）

/// 某处插入点该画的条目：容量已截断（`A2PluginSlotCapacity`）+ 该位置画不出的 component
/// 已剔除，并记一行判据日志。返回的数组可能为空（未装插件 / 全被跳过）。
///
/// 顺序即 `(priority ↑, layer ↑, pluginId ↑, declarationIndex ↑)` —— 排序键只有注册表一处实现。
+ (NSArray<A2PluginSlotContribution *> *)entriesForSlot:(NSString *)slot;

#pragma mark - 画（component → UIKit，映射见 PLUGIN-COMPAT 2.3）

/// 徽标 / 短文本 / 纯图标 → 一个小视图（胶囊底 + 单行文本，或纯图标）。
/// 供：主页卡片徽标、版本列表徽标、版本详情头、启动遮罩。
/// @param onDarkSurface 深底（启动遮罩）上要用亮色文字；浅色主题的语义色画在遮罩上会看不清。
/// @return 画不出时返回 nil（调用方跳过即可，不要自己补一个假视图）
+ (nullable UIView *)badgeForEntry:(A2PluginSlotContribution *)entry onDarkSurface:(BOOL)onDarkSurface;

/// 工具栏按钮（`button.primary` / `button.secondary` / `icon.glyph`）。
/// 最小点击区 44×44，与顶栏既有三个入口同尺寸。
/// @param handler 点击回调（P2 没有动作运行时，宿主应如实提示「需要 P3」）
+ (nullable UIButton *)actionButtonForEntry:(A2PluginSlotContribution *)entry
                                    handler:(nullable void (^)(A2PluginSlotContribution *entry))handler;

/// 整块分区（`settings.section` / `home.section`）：**一个插件一张卡**，行由 component 决定
/// （`list.row` / `switch.toggle` / `text.label` / `text.caption` / `divider` / `spacer`）。
/// @return 没有可画的条目时返回空数组（调用方不要加空卡）
+ (NSArray<A2SettingsSection *> *)sectionsForEntries:(NSArray<A2PluginSlotContribution *> *)entries;

@end

NS_ASSUME_NONNULL_END
