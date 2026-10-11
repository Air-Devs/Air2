// ============================================================================
// Natives/Support/UIKit+hook.m
// ★ Air2 最小兼容桩（COMPAT STUB）—— UIWindow(global) 的最小实现 ★
// ----------------------------------------------------------------------------
// 只实现 UIWindow.mainWindow：取 key window，退化时取首个可见 window。
// （Amethyst 原实现还含 externalWindow 等多屏逻辑，Air2 暂不需要。）
//
// ⇒ 待 Air2 引入完整 UIKit+hook 后，用真实现替换本文件。
// ============================================================================
#import "UIKit+hook.h"

@implementation UIWindow (global)

+ (nullable UIWindow *)mainWindow {
    UIWindow *key = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (key) break;
    }
    if (key) return key;

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (!w.hidden) return w;
        }
    }
    return nil;
}

@end
