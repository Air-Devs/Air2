// ============================================================================
//  Natives/Input/a2_controls_overlay.m
//  Air2 —— ★SDL 版（26.3+）的控件覆盖层★
// ----------------------------------------------------------------------------
//  问题：26.3 走 SDL 窗口栈，我们那条「GLFW 建窗时顺带把控件加到宿主视图」的路径
//        根本不会执行 ⇒ 整份日志没有任何 [A2-CONTROLS]，控件压根没被创建。
//
//  做法：启动后台链之后，主动在主窗口上建一层控件（window 句柄传 0：不向 GLFW 派发，
//        事件统一走 a2_sdl_input 的 SDL 镜像），并每 2 秒重挂一次（SDL 之后会再建/换
//        窗口，把我们的层压下去）。
//
//  幂等：宿主视图里已经存在 A2GameControlsView 就直接返回，不会出现第二层。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "A2GameControlsView.h"

static __weak A2GameControlsView *gA2SdlControls = nil;
static BOOL gA2SdlControlsScheduled = NO;

/// 在 view 树里找现成的控件层（避免重复创建）
static A2GameControlsView *a2_find_controls(UIView *root) {
    if (root == nil) return nil;
    if ([root isKindOfClass:[A2GameControlsView class]]) return (A2GameControlsView *)root;
    for (UIView *sub in root.subviews) {
        A2GameControlsView *hit = a2_find_controls(sub);
        if (hit != nil) return hit;
    }
    return nil;
}

/// 当前最顶层的可见窗口（SDL 的窗口通常也是普通 UIWindow）
/// ★控件覆盖层专用★：把控件层挂到「所有窗口里最高的那一层」，才不会被后建的画面窗压住。
/// ★GL 宿主表面不用这个★ —— 层级高 ≠ 在画面上：真机（1.20.1 + MobileGlues）它选中了一个
/// level=0 的辅助窗，上下文全绿、帧回调连发、屏幕纯黑（见下面的 a2_main_window）。
UIWindow *a2_top_visible_window(void) {
    UIWindow *top = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.isHidden || w.alpha < 0.01 || w.bounds.size.width <= 1) continue;
        if (top == nil || w.windowLevel >= top.windowLevel) top = w;
    }
    return top ?: UIApplication.sharedApplication.keyWindow;
}

/// ★主窗口★（★GL 宿主表面专用口径★）—— drawable 必须挂在真正被合成到屏幕上的那个窗口上。
/// 优先级（逐级回落，每一级都如实可查）：
///   ① 前台活跃 UIWindowScene 的 keyWindow
///   ② 该 scene 的 windows 里 isKeyWindow 的那一个
///   ③ 全量窗口里 isKeyWindow 的那一个
///   ④ 兜底：现有「最顶层可见窗口」（若连 keyWindow 都没有，就只能用它，不假装挑到了主窗口）
/// ★为什么不是「最顶层可见窗口」★：那个口径按 windowLevel 取高，会选到层级更高但不在
///   画面栈里的辅助窗（真机日志：level=0、bounds=874x402、实现回报的 drawable 也只有
///   874x402 ⇒ 帧都画进了被遮住/未上屏的那层）。MC 侧的 GLFW 画面窗本身就是 keyWindow
///   （Natives/Input/a2_glfw_window.m 复用它并把层级抬到 StatusBar+1），所以主窗口才是它。
UIWindow *a2_main_window(void) {
    UIWindowScene *activeScene = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            activeScene = (UIWindowScene *)scene;
            break;
        }
    }
    // ① 前台活跃 scene 的 keyWindow（`UIWindowScene.keyWindow` 是 iOS 15+ 才有 ⇒ 加版本守卫，
    //    14.x 落到 ② 的 `isKeyWindow` 扫描 —— 两者语义相同，不是降级替代）
    if (@available(iOS 15.0, *)) {
        if (activeScene.keyWindow != nil) return activeScene.keyWindow;
    }
    for (UIWindow *w in activeScene.windows) {                        // ②
        if (w.isKeyWindow) return w;
    }
    for (UIWindow *w in UIApplication.sharedApplication.windows) {    // ③
        if (w.isKeyWindow) return w;
    }
    return a2_top_visible_window();                                   // ④
}

static UIWindow *a2_top_window(void) {
    return a2_top_visible_window();
}

static void a2_sdl_controls_tick(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ a2_sdl_controls_tick(); });
        return;
    }
    UIWindow *top = a2_top_window();
    UIView *host = top.rootViewController.view ?: top;
    if (host == nil) return;

    A2GameControlsView *cv = gA2SdlControls;
    if (cv == nil) cv = a2_find_controls(host);
    if (cv == nil) {
        cv = [[A2GameControlsView alloc] initWithWindowHandle:0];
        // 事件走 SDL 镜像：把 window 置 0 后，GLFW 那条路自然会空转
        cv.frame = host.bounds;
        cv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        gA2SdlControls = cv;
        NSLog(@"[A2-CONTROLS] SDL 版控件层已创建（host=%@ bounds=%.0fx%.0f）",
              NSStringFromClass(host.class), host.bounds.size.width, host.bounds.size.height);
    }
    if (cv.superview != host) {
        cv.frame = host.bounds;
        [cv removeFromSuperview];
        [host addSubview:cv];
        NSLog(@"[A2-CONTROLS] SDL 版控件层已挂到 %@", NSStringFromClass(host.class));
    }
    [host bringSubviewToFront:cv];
}

/// 启动后台链之后调用一次：立刻建，并在 1s/3s/6s/10s 重挂（SDL 窗口可能出现得晚）
void a2_controls_overlay_start_for_sdl(void) {
    if (gA2SdlControlsScheduled) return;
    gA2SdlControlsScheduled = YES;

    dispatch_async(dispatch_get_main_queue(), ^{ a2_sdl_controls_tick(); });
    for (NSNumber *delay in @[@1.0, @3.0, @6.0, @10.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ a2_sdl_controls_tick(); });
    }
}
