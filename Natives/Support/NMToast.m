// ============================================================================
// Natives/Support/NMToast.m
// ★ Air2 最小兼容桩（COMPAT STUB）—— NMToast 的空实现 ★
// ----------------------------------------------------------------------------
// 真实卡片式 toast（滑入 / 自动消失 / 动作按钮）尚未搬入 Air2。
// 本桩保证链接期符号存在，并在被调用时把「本应显示的内容」写进启动日志
// （a2_log），行为对用户可见面为零 —— 符合 P1「先编过、再逐步接真实现」。
//
// ⇒ 待 Air2 落地真 NMToast（Natives/Support）后，用真实现替换本文件。
// ============================================================================
#import "NMToast.h"
#import "a2_log.h"

@implementation NMToast

+ (void)showMessage:(NSString *)message
           duration:(NSTimeInterval)duration
        actionTitle:(nullable NSString *)actionTitle
           onAction:(nullable void (^)(void))onAction {
    (void)duration;
    (void)actionTitle;
    (void)onAction;
    // 桩：只记录，不弹任何 UI（避免在无 key window 的早期阶段引入风险）。
    a2_log_f(@"[NMToast-STUB] toast 未实现，内容仅记录：%s", message.UTF8String ?: "");
}

@end
