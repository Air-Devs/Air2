//
//  A2Strings.h
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
//  纯字符串判定 —— Core 共用，与 Minecraft 无关，故放 Utils 叶子。
//
//  json 里缺字段是常态：取值前先过这里，不抛异常、不崩。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 非空字符串才取值，否则返回 nil。
FOUNDATION_EXPORT NSString * _Nullable A2NonEmptyString(id value);

NS_ASSUME_NONNULL_END
