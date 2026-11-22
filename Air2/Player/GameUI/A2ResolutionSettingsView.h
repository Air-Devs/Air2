//
//  A2ResolutionSettingsView.h
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
//
//  A2ResolutionSettingsView.h
//  Air2
//
//  分辨率设置 —— 设置页与游戏内悬浮球**共用同一个视图**。
//
//  ## 为什么共用
//
//  ZL2 里分辨率设置出现在两个地方：
//    · 设置 → 渲染 → 分辨率规则
//    · 游戏内悬浮球 → 右栏 → 分辨率
//  两处调的是同一份配置（A2ResolutionManager），只是入口不同。
//
//  在 Compose 里它们复用了同一个 Composable；
//  iOS 上我们同样做一个可嵌入的 UIView，两边都 addSubview 它。
//  这样不会出现「两处逻辑不一致」的经典问题。
//
//  ## 三组控件
//
//    规则选择（分段）：固定 / 百分比 / 自定义
//    缩放滑块（百分比模式）：50% ~ 100%
//    自定义尺寸（自定义模式）：宽 × 高 输入框
//
//  切换规则时，不适用的控件会隐藏 —— 而不是置灰。
//  置灰会让用户以为是不可用，实际是「当前模式不需要」。
//

#import <UIKit/UIKit.h>
#import "A2ResolutionManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2ResolutionSettingsView : UIView

/// 紧凑模式：游戏内悬浮球用，减少间距、隐藏说明文字
@property (nonatomic, assign) BOOL compact;

/// 值变化回调（外部可用来同步自己的显示）
@property (nonatomic, copy, nullable) void (^onChange)(void);

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
