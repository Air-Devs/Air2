//
//  A2Trash.h
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
//  用户文件删除的唯一出口：移到系统废纸篓，而不是直接删除。
//
//  为什么不用 removeItemAtPath：删错不可逆。废纸篓可恢复
//  （“文件”App → 最近删除），废纸篓不可用时返回失败让调用方报错重试，
//  绝不降级成直接删除。
//  与 Minecraft 无关，故放在 Utils（叶子层，不反向依赖业务层）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2Trash : NSObject

/// 把路径移到系统废纸篓。路径不存在视为已删除（幂等，返回 YES）。
/// 失败返回 NO 并填 error（调用方透到 UI，不静默吞错）。
+ (BOOL)trashItemAtPath:(NSString *)path error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
