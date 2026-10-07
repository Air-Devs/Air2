// ============================================================================
// Natives/runtime/a2_failbanner.m
// ★ [RT-P0.1] 运行时层「失败可见反馈」实现 —— 文案唯一一处（Air2 命名：a2_*）
// ----------------------------------------------------------------------------
// 由 Natives/runtime/jni_boot.m 原样迁出（行为不变，仅改栈位与命名）：
//   · 提示条实现：rt_show_failure_toast* → a2_failbanner_*
//   · JIT 取证分流文案：原 rt_p0_boot 内联 if/else → a2_failbanner_show_jit_unavailable
//   · 阶段码映射：rt_stage_reason → a2_failbanner_stage_reason
// 日志走 a2_log.h（R7）同一 sink；本模块不写文件、不持有全局可变状态。
// ============================================================================
#import "a2_failbanner.h"
#import "a2_log.h"          // R7：结构化日志（与 jni_boot 同一 sink）

#import <UIKit/UIKit.h>     // UIWindow / UIPasteboard
#import "NMToast.h"         // 非阻塞提示条（与 [MOD-DEP] 同族）
#import "UIKit+hook.h"      // UIWindow.mainWindow

#include <dispatch/dispatch.h>

// ----------------------------------------------------------------------------
// 提示条实现 + 文案（唯一一处）
// ----------------------------------------------------------------------------
// ============================================================================
// ★ [RT-P0.1] 失败「可见反馈」（非阻塞提示条）
// ----------------------------------------------------------------------------
// 用户反馈：JVM 崩了（SIGBUS in StubRoutines::call_stub）但启动器「一点反应没有」——
// 容错是对的（App 不死、能继续用），但没有任何界面反馈是缺陷。
// ⇒ 失败时必须给一条**非阻塞**提示；但**绝不弹阻塞式模态窗**（用户要能继续正常用）。
// 复用与 [MOD-DEP]/NMToast 同族的轻量提示条：安全区顶部滑入一张卡片，
// 12s 自动消失、卡片外不拦触摸；「复制原因」把可读原因写进剪贴板（可点开/复制）。
// 注意：rt_p0_boot 在后台线程、且可能早于 key window 建立 ⇒ 这里在主线程上有界重试
// （最多 ~20s）等 App 的 key window 就绪；始终无窗口则放弃（只留日志，不影响启动）。
// ============================================================================
static NSString *const kA2FailBannerCopyTitle = @"复制原因";

static void a2_failbanner_present(NSString *message, NSString *reasonCopy, int triesLeft) {
    UIWindow *win = UIWindow.mainWindow;
    if (!win && triesLeft > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            a2_failbanner_present(message, reasonCopy, triesLeft - 1);
        });
        return;
    }
    if (!win) {
        a2_log_f(@"失败提示条无法展示：key window 未就绪（原因仅留在本日志）");
        return;
    }
    [NMToast showMessage:message duration:12.0
             actionTitle:kA2FailBannerCopyTitle
                onAction:^{
        if (reasonCopy.length) UIPasteboard.generalPasteboard.string = reasonCopy;
    }];
}

/// 展示一条「运行时自检失败」提示条（内部已派发到主线程；调用方可在任意线程调）。
static void a2_failbanner_show(NSString *reason) {
    NSString *r = reason.length ? reason : @"未知原因";
    NSString *msg = [NSString stringWithFormat:
        @"运行时自检失败：%@\n已阻止启动游戏（详见日志）", r];
    a2_log_f(@"展示失败提示条：%s", [[msg stringByReplacingOccurrencesOfString:@"\n"
                                                                     withString:@" "] UTF8String]);
    dispatch_async(dispatch_get_main_queue(), ^{
        a2_failbanner_present(msg, r, 40);   // 最多 ~20s 等 key window 就绪
    });
}

/// 阶段码 → 可读原因（供失败提示条 / 日志）。
static NSString *a2_failbanner_stage_reason(int rc) {
    switch (rc) {
        case 1:  return @"R1 未找到 libjvm.dylib（无可用 JRE）";
        case 2:  return @"R2 dlopen(libjvm) 失败";
        case 3:  return @"R2 dlsym(JNI_CreateJavaVM) 失败";
        case 4:  return @"JNI_CreateJavaVM 失败（rc=JNI_ERR，多为 JIT/内存）";
        case 5:  return @"DefineClass(HelloWorld) 失败";
        case 6:  return @"GetStaticMethodID(HelloWorld.main) 失败";
        case 7:  return @"HelloWorld.main 抛异常";
        case 10: return @"JIT 不可用（未通过执行式/brk 自检）";
        default: return [NSString stringWithFormat:@"未知阶段 rc=%d", rc];
    }
}

/// 可见反馈：阶段码 → 可读原因。任意线程可调。
void a2_failbanner_show_stage_failure(int stageRc) {
    a2_failbanner_show(a2_failbanner_stage_reason(stageRc));
}

// ============================================================================
// JIT 取证分流 → 可见文案
// ============================================================================
void a2_failbanner_show_jit_unavailable(AMEJITRegionVerdict verdict,
                                        NSString *why,
                                        NSString *evidence) {
        // ★ [JIT-P0.3] 提示条文案按【取证分流】—— 别把两类完全不同的失败说成同一句：
        //   · 哨兵 / 无应答 ⇒ 用户侧的开启方式问题（该去【指派 JIT 脚本】/【启用 JIT】）；
        //   · 调试器已交付地址但区域不可用 ⇒ **如实报取证**（不是用户没装脚本，别误导）。
        NSString *toastReason = nil;
        if (verdict == AMEJITRegionVerdictLegacySentinel) {
            a2_log_f(@"判据分流=legacy-sentinel（brk #0x69 回 0xE0000069）⇒ 提示用户【指派 JIT 脚本】");
            a2_log_f(@"需要的 JIT 开启方式：用 JIT 使能器（StikDebug 等）给本 App 启用 JIT，并"
                     @"【指派 Universal JIT 脚本】（StikDebug 里长按 Amethyst → Assign Script → 选 "
                     @"Amethyst 目录下的 AmethystJIT69.js）。否则 brk #0x69 只会回 legacy 哨兵 "
                     @"0xE0000069，JVM 的 code cache 就拿不到内存，必然 SIGBUS。");
            toastReason = @"未检测到 JIT 脚本交付（brk #0x69 回 legacy 哨兵 0xE0000069）。\n"
                          @"请在 JIT 使能器里给 Amethyst 指派 JIT 脚本：StikDebug 长按 Amethyst → "
                          @"Assign Script → 选 Amethyst 目录下的 AmethystJIT69.js";
        } else if (verdict == AMEJITRegionVerdictNotServiced) {
            a2_log_f(@"判据分流=not-serviced（brk #0x69 无人应答）⇒ 提示用户【先启用 JIT】");
            toastReason = @"未检测到应答的 JIT 调试器（brk #0x69 无人服务）。\n"
                          @"请先用 JIT 使能器（StikDebug 等）给 Amethyst 启用 JIT，再回启动器启动";
        } else if (verdict == AMEJITRegionVerdictNoMapping || verdict == AMEJITRegionVerdictZeroSize ||
                   verdict == AMEJITRegionVerdictNotExecutable) {
            a2_log_f(@"判据分流=delivered-but-unusable（调试器已交付地址，但区域无效）⇒ 如实报取证");
            toastReason = [NSString stringWithFormat:@"JIT 区已交付但不可用。\n取证：%@",
                           evidence.length ? evidence : (why ?: @"未知")];
        } else {
            a2_log_f(@"判据分流=other ⇒ 如实报取证");
            toastReason = [NSString stringWithFormat:@"JIT 未真正可用（%@）%@",
                           why ?: @"未验证",
                           evidence.length ? [NSString stringWithFormat:@"\n取证：%@", evidence] : @""];
        }
        a2_failbanner_show(toastReason);
}
