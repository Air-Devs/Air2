//
//  A2JITLauncher.h
//  Air2
//
//  JIT 启用门禁 —— 移植自 Air1 的 invokeAfterJITEnabled:
//  （LauncherRightPanelViewController.m:1419-1660，242 行）
//
//  ## 为什么必须要有这一层
//
//  HotSpot 在 iOS 上需要 JIT（可写可执行内存）。没有 JIT 时它退化成
//  纯解释器 —— MC 26.3 在解释器下的表现不是「慢」，而是**看起来完全卡死**
//  （几分钟不动一帧）。
//
//  Air1 在拉起 SurfaceViewController 之前一定会先过这道门：
//      [self invokeAfterJITEnabled:^{ launchGame(); }];
//
//  Air2 之前直接拉起，于是没有 JIT 的机器上就是：
//    JVM 起来了 → 解释器跑 MC → 永远出不了画面 → 用户看到黑屏/卡死
//
//  ## 门禁逻辑（与 Air1 等价）
//
//    1. 已经能用（isJITEnabled）→ 直接放行
//    2. 越狱原生路径（AMEJailbreakNativeJITPathApplies + Ready）→ 放行
//    3. 配了外部使能器（StikDebug / SideStore / TrollStore…）→ 唤起并等待
//    4. 都没有 → 弹失败提示，**不进入游戏**
//       （比进去黑屏好得多：至少用户知道问题在哪）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2JITState) {
    A2JITStateReady = 0,        ///< JIT 可用
    A2JITStateWaiting,          ///< 已唤起外部使能器，等待中
    A2JITStateUnavailable,      ///< 无法获取 JIT
};

@interface A2JITLauncher : NSObject

/// 当前 JIT 状态（同步、不弹窗）
+ (A2JITState)currentState;

/// 门禁：JIT 就绪时在主线程执行 handler；否则弹提示并返回 NO。
///
/// @param host     用于弹提示的视图控制器
/// @param handler  就绪后要执行的启动动作（在主线程）
/// @param canRetry handler 为 nil 时只做检测
+ (void)gatedByJITInViewController:(UIViewController *)host
                            onReady:(void (^)(void))handler;

/// 供 UI 展示的一句话状态
+ (NSString *)statusDescription;

@end

NS_ASSUME_NONNULL_END
