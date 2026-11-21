//
//  A2MultiplayerViewController.h
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
//  A2MultiplayerViewController.h
//  Air2
//
//  联机页 —— 对照 ZL2 的 MultiplayerScreen（Terracotta / 陶瓦联机）。
//
//  布局（与 ZL2 截图一致）：
//    ┌──────────────────────┬────────────────────────┐
//    │ [用户须知][房主教程]   │ 启用多人联机      [开关] │
//    │ [房客教程]            │ 自定义节点       [开关] │
//    ├──────────────────────┤ 分享联机核心日志        │
//    │                      │ 关于 EasyTier          │
//    │  说明文字（可滚动）     │                        │
//    └──────────────────────┴────────────────────────┘
//
//  左侧是三段说明文档（自实现，不从网络拉），右侧是设置项。
//  入场动画：两侧从外向内滑入（对应 ZL2 的 AnimatedRow）。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2MultiplayerViewController : A2BaseViewController

@end

NS_ASSUME_NONNULL_END
