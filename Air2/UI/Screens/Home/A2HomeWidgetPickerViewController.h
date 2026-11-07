//
//  A2HomeWidgetPickerViewController.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  加卡 / 换目标面板（两级下钻）。
//
//  「加卡」与「换目标」共用同一个面板（docs/HOME-DESIGN.md 借鉴点 #11）：
//  换目标时记住 replacingCardID，选中新目标后**保留原 id / 尺寸 / 坐标**，
//  这样卡片不会跳位置，用户也不会觉得「换了个目标卡就跑了」。
//
//  单例语义的卡（问候 / 日历）在 picker 里直接标「已添加」并禁用 ——
//  这是修掉参考实现「第二张问候卡永远不可编辑」那个缺口的一半
//  （另一半：卡片一律按 id 定位，不按 kind 找第一张）。
//

#import <UIKit/UIKit.h>

#import "A2BaseViewController.h"
#import "A2HomeLayout.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2HomeWidgetPickerViewController : A2BaseViewController

/// @param profile         要往里加卡的方案（用来判断「已添加」单例卡）
/// @param replacingCardID 换目标时传原卡 id；加新卡传 nil
- (instancetype)initWithProfile:(A2HomeProfile *)profile
                replacingCardID:(nullable NSString *)replacingCardID;

/// 用户选定了一张卡（新卡或换好目标的旧卡）。
@property (nonatomic, copy, nullable) void (^onPickCard)(A2HomeCard *card);

@end

NS_ASSUME_NONNULL_END
