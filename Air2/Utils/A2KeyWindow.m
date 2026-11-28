// ============================================================================
//  Air2/Utils/A2KeyWindow.m
//  Air2 —— key window 查找实现
// ----------------------------------------------------------------------------
//  ★为什么不用 `windows` 属性★：UIApplication.windows 同样废弃，且在多场景下返回
//  所有场景的窗口混在一起；connectedScenes → UIWindowScene.windows 是 iOS 13+ 的
//  正确口径，也是 Apple 文档给 keyWindow 的替代写法。
// ============================================================================
#import "A2KeyWindow.h"

UIWindow *A2KeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *) scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}
