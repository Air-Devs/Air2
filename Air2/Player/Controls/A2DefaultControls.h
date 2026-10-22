//
//  A2DefaultControls.h
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
//  A2DefaultControls.h
//  Air2
//
//  Air2 自带的默认控件布局。
//
//  ## 设计依据
//
//  参考了 FCL / ZL2 / Air1 三家的默认布局，取它们的共同点：
//
//    左下（屏幕宽 0~30%）：摇杆 —— 移动
//    右下：跳跃、潜行、攻击、使用
//    右上：设置（打开悬浮球）、背包
//    左侧中：快捷菜单（切换鼠标模式、切换控件显隐）
//
//  三家都这么放，是因为这是触屏玩 PC 版 MC 的最小可用集。
//  我们没有照抄某一家的图标与配色，按 Air2 的 MD3 色板来。
//
//  ## 为什么单独一个文件
//
//  默认布局是「产品决策」，不属于控件引擎。
//  引擎（A2ControlLayout / A2ControlRenderer）应该对默认值无感。
//

#import <Foundation/Foundation.h>
#import "A2ControlLayout.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2DefaultControls : NSObject

/// 生成一套默认布局。坐标都是百分比，适配任意屏幕尺寸。
+ (A2ControlLayout *)makeLayout;

/// 把默认布局写进指定路径
+ (BOOL)installDefaultLayoutToPath:(NSString *)path error:(NSError **)error;

/// 已存在就不覆盖（首次启动时调用）
+ (BOOL)installIfNeededAtPath:(NSString *)path error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
