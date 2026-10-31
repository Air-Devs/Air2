//
//  A2PluginPermissionSheet.h
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
//  插件授权页（PLUGIN-SECURITY §3.2 / §3.2.1）。
//
//  ## 页面长什么样
//
//    插件信息   名字 / id · 版本 / 作者（自述）/ 包哈希（点开看完整值）
//               底部一行：Air2 不验证作者身份，哈希只能证明「包没变」
//    申请的权限  按后果分 5 组，**组默认折叠**：
//                 ▸ 改游戏文件   3 项 · 含 2 项高危
//                 ▸ 联网         0 项 → 整组隐藏
//                 ...
//    点开一组 → 每项一行：人话名称 + §9 人话后果整句 + 状态
//
//  ## 为什么「按后果分组」是硬要求
//
//  24 项权限平铺成一列时，用户看到的是一串 id，只能从头点到尾；按后果分成
//  固定 5 组后，每组的标题本身就是结论（「改游戏文件」），折叠态就能回答
//  「这个插件大概能干什么」。组顺序固定、不按风险重排 —— 用户第二次打开时
//  位置必须一致，否则他会以为自己看错了。
//
//  ## 授权粒度
//
//  分组**只影响展示**：低/中逐项开关；critical 逐项走三次确认
//  （`A2PluginCriticalConfirmFlow`），不提供「整组授权」「一键全给」。
//  本页不写任何授权文案 —— 后果整句、风险级、阶段全部来自
//  `A2PluginPermissionStore` 的目录静态表，避免 UI 与文档各写一份。
//
//  ## 入口
//
//  `+presentForManifest:…` 是安装完成后的接线点：安装器（`A2PluginInstaller`）
//  返回 `A2PluginInstallResult` 之后，由调用方（导入流程 / 插件管理页）用它弹出本页。
//  本单不改安装器 —— 它现在返回的 `entry` 已经带着安装期默认授予的低/中权限。

#import <UIKit/UIKit.h>

#import "A2BaseViewController.h"
#import "A2PluginPermissionStore.h"

@class A2PluginManifest;

NS_ASSUME_NONNULL_BEGIN

@interface A2PluginPermissionSheet : A2BaseViewController

/// @param manifest 当前这一版 manifest（申请集、名字、主版本号都从它来）
/// @param store    授权读写入口
/// @param packageHash 本次安装的内容哈希；用于「包哈希」展示与 approvedHashes 取证
- (instancetype)initWithManifest:(A2PluginManifest *)manifest
                           store:(A2PluginPermissionStore *)store
                     packageHash:(nullable NSString *)packageHash NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, strong, readonly) A2PluginManifest *manifest;
@property (nonatomic, strong, readonly) A2PluginPermissionStore *store;
@property (nonatomic, copy, readonly, nullable) NSString *packageHash;

/// 宿主里程碑。默认 `A2PluginMilestoneP1`：本单所处的阶段还没有任何权限对应的 API 面，
/// 因此每一项都会显示「当前版本不可用」并禁用开关（§3.2 规则 5：不会授予）。
/// 装配处按当前宿主实际能力传入（P3a 起才有启动类权限可用）。
@property (nonatomic, assign) A2PluginMilestone hostMilestone;

/// 安装 / 更新完成后的接线入口。
/// @param completion 返回**当前**已授予的全部权限 id（不是本次增量）——
///                   调用方用它决定管理页要不要标「功能受限」
+ (instancetype)presentForManifest:(A2PluginManifest *)manifest
                             store:(A2PluginPermissionStore *)store
                       packageHash:(nullable NSString *)packageHash
                     hostMilestone:(A2PluginMilestone)hostMilestone
                fromViewController:(UIViewController *)presenter
                        completion:(nullable void (^)(NSArray<NSString *> *grantedPermissions))
                                       completion;

@end

NS_ASSUME_NONNULL_END
