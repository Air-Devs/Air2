//
//  TrackedTextField.h
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
#import <UIKit/UIKit.h>

#include "jni.h"

@interface TrackedTextField : UITextField

@property(nonatomic, copy) void(^sendChar)(jchar codepoint);
@property(nonatomic, copy) void(^sendCharMods)(jchar codepoint, int mods);
@property(nonatomic, copy) void(^sendKey)(int key, int scancode, int action, int mods);
// SDL/IME 侧临时 resign 要求导致标准键盘意外关闭的防护（Amethyst-JP 同款思路）。
// 置位时忽略非显式的 resign；SurfaceViewController 在显式键盘开关处临时清零。

@property(nonatomic, assign) BOOL preventUnexpectedResign;
@end
