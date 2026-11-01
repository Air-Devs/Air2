// ============================================================================
// Natives/Context/a2_exit_guard.h
// ★[A2-EXIT-GUARD] 进程级退出拦截（exit / _exit / abort）—— 声明
// ----------------------------------------------------------------------------
// 为什么需要（缺口）：游戏崩溃时多半走 `System.exit(-1)` / `abort()` 直接把进程杀掉，
//   没有「返回值」可判 ⇒ a2_launch.m 的「主类 main 返回」通知点根本走不到 ⇒
//   崩溃遮罩不弹，用户看到的是闪退。
//   本层在 dyld interpose 层拦下这三个进程出口：★游戏运行中 + 退出码非 0★ 时
//   **不真退出**，改为广播 A2GameExitedNotification（与「main 返回」同一口径的
//   notification / userInfo），由 App 层（A2AppDelegate）照既有逻辑弹「游戏崩溃了」。
//   ★不拦到时行为一字不变★：非运行期 / 退出码 0 ⇒ 原样转调原函数。
//
// 谁调它（新增符号的调用点，唯一）：
//   · 写点：Natives/Context/a2_launch.m 的 a2_launch_jvm_with_argv ——「派发主类 main」
//     前把 gA2GameRunning 置 1，main 返回后置 0。
//   · 读点：Natives/Context/a2_exit_guard.m 的三个替换函数（拦截判据）。
// ============================================================================
#ifndef A2_EXIT_GUARD_H
#define A2_EXIT_GUARD_H

#import <Foundation/Foundation.h>
#include <signal.h>   // sig_atomic_t

/// 游戏是否正在运行（主类 main 已派发、尚未返回）。0 = 没在跑（启动链里 / 已经退出）。
/// ★volatile sig_atomic_t★：写点（派发线程）与读点（可能任意 JVM 线程）不同线程，
/// 要的就是「每次现读」，不许编译器把它缓存到寄存器里。
extern volatile sig_atomic_t gA2GameRunning;

/// 游戏退出广播名（★native 侧唯一定义处★，定义在 a2_exit_guard.m）。
/// 发出点两处：a2_launch.m（主类 main 返回 ⇒ mrc）、a2_exit_guard.m（exit/abort 拦截 ⇒ 实际退出码）。
/// 唯一消费方：Air2/App/A2AppDelegate.m 的观察者（按同名 notification 收，读 userInfo[@"code"]）。
extern NSString *const a2_exit_guard_exited_notification_name;

#endif /* A2_EXIT_GUARD_H */
