//
//  ios_uikit_bridge.h
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
#pragma once
#import <UIKit/UIKit.h>
#include "jni.h"

#define CLIPBOARD_COPY 2000
#define CLIPBOARD_PASTE 2001

extern UIViewController* tmpRootVC;

void showDialog(NSString* title, NSString* message);
jstring UIKit_accessClipboard(JNIEnv* env, jint action, jstring copySrc);
void UIKit_launchMinecraftSurfaceVC(UIWindow *window, NSDictionary *metadata);
void UIKit_returnToSplitView();
void launchInitialViewController(UIWindow *window);

// ★ [GAME-LANDSCAPE] 游戏方向锁（幂等、成对）。
//   进：用户点「启动游戏」那一刻（含加载中）⇒ 支持方向收窄为【仅横屏】并主动转到横屏；
//   出：回启动器 / 启动失败 / 启动取消 / 游戏曲面销毁 ⇒ 逐字恢复启动器原方向（竖屏 + 横屏）。
//   多处入口可重复调用；重复进/出均无副作用（幂等）。状态读写只在主线程发生。
void AmeGameLandscapeLockEnter(void);
void AmeGameLandscapeLockExit(void);
BOOL AmeGameLandscapeLockActive(void);

void AWTInputBridge_sendKey(int keycode);
