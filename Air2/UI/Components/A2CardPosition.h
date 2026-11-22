//
//  A2CardPosition.h
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
//  分组内元素的位置 —— 决定圆角。
//
//  参考 ZL2 的 CardPosition：一组设置行拼成一张卡，
//  首行上圆角 28、末行下圆角 28、中间各 4。
//  这样视觉上是「一张卡片里分了若干行」，而不是「一堆独立小卡片」。
//
//    ┌────────────────┐  ← 28 圆角（Top）
//    │ 第一行          │
//    ├────────────────┤  ← 4 圆角（Middle）
//    │ 第二行          │
//    ├────────────────┤  ← 4 圆角（Middle）
//    │ 第三行          │
//    └────────────────┘  ← 28 圆角（Bottom）
//

#import <UIKit/UIKit.h>
#import "A2Metrics.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2CardPosition) {
    A2CardPositionTop = 0,   ///< 分组首行
    A2CardPositionMiddle,    ///< 分组中间
    A2CardPositionBottom,    ///< 分组末行
    A2CardPositionSingle,    ///< 单独一行（四角都是大圆角）
};

/// 按位置计算需要的圆角掩码
UIKIT_EXTERN CACornerMask A2CornerMaskForPosition(A2CardPosition position);

NS_ASSUME_NONNULL_END
