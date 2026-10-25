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
/// ★对外★（非 static）：GL 桥取宿主表面用的是**同一份判定** —— 26.3 走 SDL 窗口栈时，
/// `keyWindow` 是启动器自己的窗口，而真正的画面窗是 SDL 后建的、层级更高的那个
/// （见 Natives/Input/a2_glfw_window.m 的注释）。两处各写一份必然漂移，所以只留这一份。
UIWindow *a2_top_visible_window(void) {
    UIWindow *top = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.isHidden || w.alpha < 0.01 || w.bounds.size.width <= 1) continue;
        if (top == nil || w.windowLevel >= top.windowLevel) top = w;
    }
    return top ?: UIApplication.sharedApplication.keyWindow;
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
