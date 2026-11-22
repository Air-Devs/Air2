//
//  A2AccountViewController.h
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
//  账号管理 —— 三种账号类型：
//    · Microsoft 正版登录（OAuth 设备码流程）
//    · 离线账号（仅填用户名）
//    · 第三方 Yggdrasil 认证服务器（如 LittleSkin）
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2AccountViewController : A2BaseViewController

@end

NS_ASSUME_NONNULL_END
