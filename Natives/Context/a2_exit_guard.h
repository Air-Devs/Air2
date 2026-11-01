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

/// ★安装拦截（判据行也在这里）★ 进「游戏运行中」窗口之前调一次：
/// 逐镜像改绑定（`dyld_dynamic_interpose`），并打三行「表值核对」+ 一行「已装」判据。
/// ★为什么不能只靠 `__DATA,__interpose` 静态段★：dyld4 在启动时只扫 **MH_DYLIB** 镜像的
/// __interpose 段（源码 `DyldRuntimeState.cpp::buildInterposingTables`：
/// `if ( !hdr->isDylib() ) continue;`），而 App 主程序是 MH_EXECUTE ⇒ 静态表在真机上不会被登记。
/// 那张表保留作「元组的唯一定义处」（replacee 由 dyld 的普通绑定解析成真地址），
/// 真正生效靠本函数逐镜像改绑定 —— 这一步也正是「拦截是否生效」的唯一判据来源。
/// 调用方（唯一）：Natives/Context/a2_launch.m —— 派发主类 main 之前（那时 libjvm 已加载）。
void a2_exit_guard_arm(void);

/// 立刻结束进程（★行为 = `exit(code)`，一字不差：调的是同一个 libSystem 原函数★）。
/// 调用方（唯一）：Air2/UI/Screens/About/A2CrashReportViewController.m 的 `restartLauncher`
/// 「重启启动器」—— 它原来直接写 `exit(0)`。
/// ★为什么必须经过这里，而不是直接写 `exit(0)`★（不是风格问题，是拦截能不能成立）：
///   ld64.lld 只要在本镜像里见过一次 `exit()` 调用，就会为 `exit` 生成本地 **stub**，并把
///   __interpose 表里「取 exit 地址」那一格直接写成 **stub 地址**；而 dyld 解析该表时，
///   replacee 那一格必须是**绑定项（bind）**——它按 bind 记录去解析真实符号地址，填成静态
///   stub 的一格会被当成空项丢掉（dyld 源码 `DyldRuntimeState.cpp` 的 forEachRebase/forEachBind
///   分支 + `if ((t.tuple.replacee == 0) || …) continue;`）⇒ `exit` 就拦不住，
///   游戏里 `System.exit(-1)` 会照旧把进程杀掉。改成走函数指针调用 ⇒ 不再生成 stub，
///   表里那一格恢复成 bind ⇒ 拦截成立。★表值是否真对得上，由 a2_exit_guard_arm 的
///   「表值核对 … 一致=1」那几行判★。
void a2_exit_guard_terminate_now(int code) __attribute__((noreturn));

#endif /* A2_EXIT_GUARD_H */
