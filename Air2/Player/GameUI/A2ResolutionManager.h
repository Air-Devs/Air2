//
//  A2ResolutionManager.h
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
//  A2ResolutionManager.h
//  Air2
//
//  渲染分辨率管理 —— 游戏内可调，参考 ZL2 的 RendererResolution。
//
//  ## 三种规则（与 ZL2 一致）
//
//    **Fixed**      固定规则：分辨率 = 设备原生分辨率 × 缩放系数
//    **Percentage** 百分比：用户输入百分比（如 75%）
//    **Custom**     自定义：直接指定宽 × 高像素
//
//  ZL2 的默认是 Percentage 100% —— 即原生分辨率。
//
//  ## 为什么要能调
//
//  Minecraft 的渲染开销主要来自像素填充。iPhone 的分辨率很高
//  （如 2532×1170 ≈ 300 万像素），降到 75% 就是 170 万像素，
//  帧率能提升 40% 以上，而画质的损失在小屏上几乎看不出来。
//
//  ## 怎么生效
//
//  分辨率改变需要两步：
//    1. 改 glViewport（GPU 渲染到更小的缓冲区）
//    2. 改 surface 尺寸（CAMetalLayer.drawableSize / OSMesa buffer）
//
//  第 1 步由启动核心的 GL 桥负责；第 2 步在本类里调 surface。
//  两者都要做，否则会出现「画面缩在一角」或「GPU 仍在渲染全尺寸」。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2ResolutionRule) {
    A2ResolutionRuleFixed = 0,      ///< 按比例缩放原生分辨率
    A2ResolutionRulePercentage,     ///< 用户输入百分比
    A2ResolutionRuleCustom,         ///< 自定义像素尺寸
};

extern NSNotificationName const A2ResolutionDidChangeNotification;

@interface A2ResolutionManager : NSObject

+ (instancetype)shared;

/// 当前规则
@property (nonatomic, assign) A2ResolutionRule rule;

/// Fixed / Percentage 模式的缩放比（1.0 = 100%）
@property (nonatomic, assign) CGFloat scale;

/// Custom 模式的尺寸
@property (nonatomic, assign) CGSize customSize;

/// 计算出的实际渲染分辨率
@property (nonatomic, readonly) CGSize renderSize;

/// 设备原生分辨率（物理像素）
@property (nonatomic, readonly) CGSize nativeSize;

/// 生效到某个 surface 视图（CAMetalLayer 或自定义）
- (void)applyToLayer:(CALayer *)layer;

/// 通知 GL 桥更新 viewport（由启动核心实现，见 A2ResolutionApplier）
- (void)notifyGLViewportChange;

/// 持久化
- (void)save;
- (void)load;

/// 值变化后统一入口 —— 保存 + 应用 + 发通知
- (void)commitChange;

@end

NS_ASSUME_NONNULL_END
