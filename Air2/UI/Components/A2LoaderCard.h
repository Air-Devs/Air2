//
//  A2LoaderCard.h
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
//  加载器选择卡 —— 安装选项页里的一张可选卡。
//
//  形态参考 ZalithLauncher2 的 AddonListLayout：卡头常驻（图标方块 + 名称 +
//  状态摘要 + 展开指示），点卡头就地展开内嵌的版本列表，选中某个版本后自动收起，
//  因此「请求版本列表」与「选择版本」都发生在同一张卡里，不另开页面。
//
//  版本列表由卡自己按需拉取（首次展开才请求，避免一进页面就并发打六家 meta 服务），
//  卡因此是自洽的：调用方只要给出 MC 版本、读回选中项，不必接管加载/失败/空态。
//
//  原版（不装任何加载器）复用同一张卡，但退化为一枚不可展开的纯选项 ——
//  它没有可选的版本，也就没有展开体。
//

#import <UIKit/UIKit.h>
#import "A2ModLoaderAPI.h"

NS_ASSUME_NONNULL_BEGIN

@class A2LoaderCard;

@protocol A2LoaderCardDelegate <NSObject>

/// 卡内选中项发生变化（选了某个加载器版本，或原版卡被选中）。
/// 单选语义由调用方维护：收到回调后把其余卡拉回未选中态、收起。
- (void)loaderCardSelectionDidChange:(A2LoaderCard *)card;

@optional

/// 卡片展开（进入展开态时回调一次）。
/// 调用方若希望「同时只开一张」，在这里收起其余卡。
- (void)loaderCardDidExpand:(A2LoaderCard *)card;

@end

@interface A2LoaderCard : UIView

/// 原版卡：可选、不可展开。
- (instancetype)initAsVanilla;

/// 加载器卡：可展开选版本。
- (instancetype)initWithLoaderType:(A2ModLoaderType)type mcVersion:(NSString *)mcVersion;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<A2LoaderCardDelegate> delegate;

@property (nonatomic, assign, readonly) BOOL isVanilla;
/// 加载器类型。原版卡无意义。
@property (nonatomic, assign, readonly) A2ModLoaderType loaderType;

/// 当前是否为选中项（单选）。置 NO 会一并清掉已选版本，供调用方做互斥清理。
@property (nonatomic, assign, getter=isChosen) BOOL chosen;
/// 已选中的加载器版本；原版卡与未选中时为 nil。
@property (nonatomic, strong, readonly, nullable) A2ModLoaderVersion *selectedVersion;

/// 非空表示该卡不可用（灰显、不可展开，副标题显示该原因）。
/// 典型的两种：OptiFine 官方无自动安装接口；或拉取后发现该 MC 版本不被支持。
@property (nonatomic, copy, nullable) NSString *unavailableReason;

/// 收起展开的版本列表。
- (void)collapse;

@end

NS_ASSUME_NONNULL_END
