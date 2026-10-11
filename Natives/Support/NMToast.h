// ============================================================================
// Natives/Support/NMToast.h
// ★ Air2 最小兼容桩（COMPAT STUB）—— 应用内非阻塞提示条（toast）声明 ★
// ----------------------------------------------------------------------------
// 来源：Amethyst 线 `Natives/NMToast.[hm]`（卡片式 toast：安全区顶部滑入、
//       自动消失、可带动作按钮）。Air2 当前仅 `a2_failbanner.m` 需要「带动作按钮 +
//       自定义时长」这一条入口 ⇒ 本桩只声明用到的那个方法。
//
// ⇒ 待 Air2 落地完整 NMToast 实现时，用真头文件/实现替换本桩（保持同名方法签名）。
// ============================================================================
#ifndef A2_COMPAT_NMTOAST_H
#define A2_COMPAT_NMTOAST_H

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NMToast : NSObject

/// 显示一条 toast，自定义停留时长与可选动作按钮（duration <= 0 用默认时长）。
/// @param actionTitle 动作按钮标题；nil 则不显示按钮
/// @param onAction    点击动作按钮的回调（主线程）
+ (void)showMessage:(NSString *)message
           duration:(NSTimeInterval)duration
        actionTitle:(nullable NSString *)actionTitle
           onAction:(nullable void (^)(void))onAction;

@end

NS_ASSUME_NONNULL_END

#endif /* A2_COMPAT_NMTOAST_H */
