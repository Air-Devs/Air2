//
//  A2PluginCriticalConfirmFlow.h
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
//  critical 权限的三次确认（PLUGIN-SECURITY §3.3）。
//
//  ## 三步各是什么
//
//    1. 这个权限能做什么   —— 人话后果 + 定义 + 允许的操作 + 不能做什么 + 风险级/阶段
//    2. 允许之后可能造成的危害 —— 至少两个具体场景 + 「不确定就取消」
//    3. 最终确认          —— 权限 id / 插件名 / 包哈希前 8 位 / 已授权的其它高危项
//                            + 「授权后，插件可以在你不知情的情况下执行上述操作」
//    第 3 步的**主按钮是「不授权」**（默认高亮）；「我已知晓，授权」是次要按钮且受倒计时约束。
//
//  ## 计时硬规则（§3.3 那张表）
//
//  · 计时源是 `CACurrentMediaTime`（单调时钟），不是 wall clock —— 改系统时间不影响；
//  · App 进后台 ⇒ 计时停止；回前台重新计满 5 秒（不允许「后台等 5 秒再回来点」）；
//  · 旋转 / 分屏不重置计时，只保证按钮可达（页面本来就在滚动容器里）；
//  · 不接受任何自动化触发：没有 URL Scheme、没有快捷键、没有绕过开关。
//
//  ## 为什么每项独立跑三步，而不是打包
//
//  §3.3 明确禁止把多个 critical 打包成一次确认：「确认了 A」不等于「知道 B 也能干这个」。
//  所以本类是**一项一次**的，调用方（授权页）对每一项各起一个流程。
//
//  ## 保留
//
//  流程对象由调用方持有（授权页的 `activeFlow`）：页面只持弱引用，
//  调用方在 completion 里把它置空 —— 不用「页面反向 hold 流程」这种隐式生命周期。

#import <UIKit/UIKit.h>

#import "A2PluginPermissionStore.h"

@class A2PluginManifest;

NS_ASSUME_NONNULL_BEGIN

/// 三步走完的结果。`granted == NO` 且 `error == nil` 表示用户在某一 cancel 了（不是失败）。
typedef void (^A2PluginCriticalConfirmResult)(BOOL granted, NSError *_Nullable error);

@interface A2PluginCriticalConfirmFlow : NSObject

/// @param manifest 当前安装/更新这一版的 manifest（人话名称、主版本号都从它来）
/// @param store    授权写入口（第 3 步确认后才写 registry）
/// @param packageHash 第 3 步要复述的包哈希（前 8 位）；传 nil 时显示「（未提供）」
- (instancetype)initWithManifest:(A2PluginManifest *)manifest
                           store:(A2PluginPermissionStore *)store
                     packageHash:(nullable NSString *)packageHash NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, strong, readonly) A2PluginManifest *manifest;
@property (nonatomic, strong, readonly) A2PluginPermissionStore *store;

/// 对**一项** critical 权限跑完三步。presenter 必须是当前最前面的视图控制器。
/// completion 一定会被调用一次（授予成功 / 用户取消 / 写盘失败）。
- (void)runForPermission:(NSString *)permissionId
                    from:(UIViewController *)presenter
              completion:(nullable A2PluginCriticalConfirmResult)completion;

@end

NS_ASSUME_NONNULL_END
