//
//  A2PluginListViewController.h
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
//  插件管理页（PLUGIN-SECURITY 3.5 / P0-V2-CHANGELOG 第五节第 4 条「最小管理页」）。
//
//  ## 页面长什么样
//
//    已安装
//      [icon] 插件名                              [开关]
//             v1.0.0 · 从本地文件导入（hello.air2plugin）
//      ...
//    导入插件…
//
//  点一行 → 详情页（同一个 .m 里的 A2PluginDetailViewController）：
//    这个插件   id / 版本 / 作者（自述）/ 安装时间 / 包哈希前 8 位
//    来源       只写事实（见下），详细文件名点开看完整值
//    权限       按 ③ 的 5 组分组，每项标「已授权 / 未授权 / 当前版本不可用」
//    操作       启用 / 禁用、重新审查权限、卸载（内置插件置灰 + 原因）
//
//  ## 来源为什么只有一行字
//
//  ADR-024：来源**只陈述事实**，不做好坏判断、不挂徽标、不加颜色。
//  所以这里只有「从本地文件导入（x.air2plugin）」这类句子，没有「可信 / 未知来源」，
//  也没有按来源排序或分组 —— 那都会变成隐性的评价。
//
//  ## 启用为什么可能先弹授权页
//
//  启用前要确认「申请的权限是否都还授权着」。只要有一项没授权（用户自己关掉的低/中项、
//  从未确认过的 critical 项），就先打开 ③ 的授权页让用户过一遍；用户关掉授权页之后
//  仍按他的意思启用 —— 与安装页同一口径：一项都不授权也能装、也能启用，只是功能受限。
//  安装目录里的 manifest.json 读不出来时**不启用**并说明原因：那时连「这个插件要什么」
//  都不知道，先让它跑起来等于把授权页绕过去。
//
//  ## 已知缺口（不在本单范围）
//
//  - 开关 / 卸载都属于「用户动过插件配置」，PLUGIN-SECURITY 3.4 补充规则 7 要求
//    registry 的 `userSeq + 1`。`userSeq` 在 A2PluginRegistry 里只有 readonly 属性、
//    没有自增入口（与 ③ 同一个缺口），本页不假造。
//  - 诊断字段（最近 stage / suspectCount / tampered）来自 boot marker 那一单，
//    registry 里还没有对应字段，本页不编。

#import <UIKit/UIKit.h>

#import "A2BaseViewController.h"
#import "A2PluginPermissionStore.h"

@class A2PluginInstaller;
@class A2PluginRegistry;

NS_ASSUME_NONNULL_BEGIN

@interface A2PluginListViewController : A2BaseViewController

/// @param registry  注册表（事实来源）
/// @param installer 安装器：卸载、导入、内置插件集合、读取已安装的 manifest
- (instancetype)initWithRegistry:(A2PluginRegistry *)registry
                       installer:(A2PluginInstaller *)installer NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// 设置页的构造点：P1 还没有插件运行时装配处（Phase A 未接注册表），
/// 所以由本类按默认目录建一套 registry + installer。装配处落地后改在这里注入，
/// 调用方（A2SettingsViewController）不需要跟着改。
+ (instancetype)defaultController;

/// 宿主里程碑，透传给 ③ 的授权页（决定哪些权限显示「当前版本不可用」）。
/// 默认 `A2PluginMilestoneP1`：本阶段还没有任何权限对应的 API 面。
@property (nonatomic, assign) A2PluginMilestone hostMilestone;

@end

NS_ASSUME_NONNULL_END
