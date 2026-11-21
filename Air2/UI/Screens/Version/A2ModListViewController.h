//
//  A2ModListViewController.h
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
//  版本模组管理页 —— 某版本的 mods 目录一览。
//
//  只做三件事：列出（名/版本/作者/启用态）、开关、删除。
//  解析与开关逻辑在 Core（A2ModScanner），这里只拼装与刷新。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@class A2Version;

@interface A2ModListViewController : A2BaseViewController

- (instancetype)initWithVersion:(A2Version *)version;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
