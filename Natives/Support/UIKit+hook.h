// ============================================================================
// Natives/Support/UIKit+hook.h
// ★ Air2 最小兼容桩（COMPAT STUB）—— UIWindow(global) 声明 ★
// ----------------------------------------------------------------------------
// 来源：Amethyst 线 `Natives/UIKit+hook.h`（含大量私有 API 分类：UIDevice/UIImage/
//       UITextField/UIContextMenuInteraction…）。Air2 当前仅 a2_failbanner.m
//       需要 `UIWindow.mainWindow` 一处 ⇒ 本桩只声明该分类的这一条。
//
// ⇒ 待 Air2 引入完整 UIKit+hook 时，用真头文件/实现替换本桩。
// ============================================================================
#ifndef A2_COMPAT_UIKIT_HOOK_H
#define A2_COMPAT_UIKIT_HOOK_H

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIWindow (global)
/// 当前 key window（无则回退首个可见 window）。主线程语义。
+ (nullable UIWindow *)mainWindow;
@end

NS_ASSUME_NONNULL_END

#endif /* A2_COMPAT_UIKIT_HOOK_H */
