//
//  A2RenderScaleCatalog.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Core/Renderer —— ★渲染分辨率倍率（render scale）的候选表与校验★。
//
//  单一职责：只回答「有哪几档 / 哪一档是默认 / 这个值受不受支持 / 存进来的字符串该归一成哪一档」。
//    · 不做持久化（写点 = UI 设置行；读点 = Player 启动会话，键见 `A2LaunchContract.h`）；
//    · 不知道任何渲染后端（倍率是**中立数值**，与谁画这一帧无关）；
//    · 不取四语文案（Core 在 Player 之下，不能反向依赖）—— 百分比文案语言中立，本类直接给。
//
//  ★为什么单列一类（不散在两处）★：UI（写）与 Player（读）都要用到
//  「哪几档 / 默认哪档 / 合法性」这一份知识；写成两份字面量就是同一知识的两份拷贝
//  （见 A2LaunchSession.m 对「手拼同一对路径」的同类收敛）。这里只放一份。
//
//  ★调用点★：
//    · `Air2/UI/Screens/Settings/A2RuntimeSettings.m`（渲染分辨率行的候选表 + 显示值）
//    · `Air2/Player/A2LaunchSession.m`（把偏好值归一成受支持的一档，交给启动链）
//    · `tests/Runtime/`（候选表 / 默认档 / 归一化的单测）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 渲染分辨率倍率候选表（★稳定顺序：升序★；起始三档 0.5 / 0.75 / 1.0）。
/// 值语义：drawable 像素 = 表面像素 × 倍率；逻辑尺寸（点）不变。
@interface A2RenderScaleCatalog : NSObject

/// 全部候选（升序；元素为 NSNumber）。
+ (NSArray<NSNumber *> *)allScales;

/// 默认档（1.0 = 原生像素）。
+ (double)defaultScale;

/// 是否为受支持的一档（按数值容差比较，避免浮点字面量相等判断）。
+ (BOOL)isSupportedScale:(double)scale;

/// 把持久化字符串归一化成受支持的一档。
/// 未设置（nil/空）/ 非数值 / 超范围 ⇒ 默认档（★不猜中间值、不四舍五入到最近档★）。
+ (double)normalizedScaleForStoredString:(nullable NSString *)stored;

/// 展示用百分比文案（语言中立；如 "50%" / "75%" / "100%"）。
+ (NSString *)displayPercentForScale:(double)scale;

@end

NS_ASSUME_NONNULL_END
