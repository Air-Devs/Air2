//
//  A2SkinHeadView.h
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
//  账号头像：优先显示玩家皮肤的「头」，取不到皮肤时退回占位文字。
//
//  之前的头像是用户名首字母，但首字母看不出是谁 —— 换成皮肤头更直观。
//  皮肤文件路径由外部注入（Core 的 A2Wardrobe 负责按需下载），
//  本组件只做裁剪与展示，不联网。
//
//  尺寸自适应：放在 46pt 或 64pt 的方框里都能用，
//  内部按方框高度算圆角与占位字号。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2SkinHeadView : UIView

/// 本地皮肤文件路径（64x64 或 64x32 的 PNG）。
/// 为空、文件不存在或不是标准材质时，退回显示 fallbackText。
@property (nonatomic, copy, nullable) NSString *skinPath;

/// 无皮肤时的占位文字，取首字母大写显示（未登录可传 @"+"）。
@property (nonatomic, copy, nullable) NSString *fallbackText;

@end

NS_ASSUME_NONNULL_END
