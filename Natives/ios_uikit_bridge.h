#pragma once
#import <UIKit/UIKit.h>
#include "jni.h"

#define CLIPBOARD_COPY 2000
#define CLIPBOARD_PASTE 2001

UIViewController* tmpRootVC;

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
