//
//  A2CardPosition.m
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

#import "A2CardPosition.h"

CACornerMask A2CornerMaskForPosition(A2CardPosition position) {
    switch (position) {
        case A2CardPositionTop:
            // 上两角大圆角，下两角小圆角
            return kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        case A2CardPositionBottom:
            return kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        case A2CardPositionSingle:
            return kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                   kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        case A2CardPositionMiddle:
        default:
            return 0;   // 四角都是小圆角
    }
}
