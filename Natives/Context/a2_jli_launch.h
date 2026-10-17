// ============================================================================
// Natives/Context/a2_jli_launch.h
// ★ [JLI-LAUNCH] R2 的第二种入口：dlopen(libjli) → dlsym(JLI_Launch) → 调用
// ----------------------------------------------------------------------------
// 为什么要有这条入口（真机病象的直接对策）：
//   dlopen(libjvm) + JNI_CreateJavaVM 在真机上停在 `[A2JVM] R4 调用 JNI_CreateJavaVM`
//   之后再无 R5（不返回）。老线（树 510）从不这么建 VM：它 dlopen libjli 后调
//   JLI_Launch —— HotSpot 自带启动器，内部完成「建 VM + 跑主类 main」，真机验过。
//   本文件只搬**调用约定**（dlopen 哪个路径、argv 怎么排、14 个实参怎么给、
//   字符串要活到返回、调前复位信号处理器），不搬老线代码。
//
// 单一职责：本文件【只做 libjli 的加载与 JLI_Launch 调用 + J1/J2/J3 判据行】。
//   argv 怎么排属纯逻辑（a2_jli_entry）；开关/回退决策属 facade（a2_launch）。
//
// ★调用语义（判读日志前必读）★
//   JLI_Launch 是「启动器主循环」：它建 VM、跑主类 main，★要等 main 结束/进程退出才返回★。
//   所以 `J3 JLI_Launch 返回` 只在游戏退出时出现 —— 线上没看到 J3 并不等于卡死；
//   真机判据是：J1 ok → J2 已调用 →（游戏真起来时）MC 自己打到 stderr 的行。
// ============================================================================
#ifndef A2_JLI_LAUNCH_H
#define A2_JLI_LAUNCH_H

#import <Foundation/Foundation.h>
#import "a2_jli_entry.h"   // A2JLIRC / a2_jli_build_argv / a2_jli_resolve_libjli

/// 以 JLI_Launch 入口启动 JVM 并跑主类 main（★进程内、同线程、阻塞到 main 结束★）。
///
/// @param javaHome   选定 JRE home（非空；libjli 由 a2_jli_resolve_libjli 在其内定位）
/// @param argv       已组装好的 JLI 命令行（a2_jli_build_argv 的产物；首项为 `<home>/bin/java`）
/// @param classpath  仅用于 J2 判据行的 classpathLen（可为空串；不再二次注入）
/// @param mainClass  仅用于 J2 判据行（可为空串）
/// @param outJLIRC   非 NULL 时回填 JLI_Launch 的返回码（仅当返回 A2JLIRCCalled 有意义）
///
/// @return A2JLIRC：
///   A2JLIRCCalled(0)        = JLI_Launch 已调用并返回（★outJLIRC = 其 rc★）
///   A2JLIRCBadArgs(1)       = 入参非法（javaHome / argv / 主类为空）⇒ 未 dlopen
///   A2JLIRCDlopenFailed(2)  = libjli 两路径都不存在或 dlopen 失败 ⇒ 未调用
///   A2JLIRCDlsymFailed(3)   = libjli 内缺 JLI_Launch 符号 ⇒ 未调用
/// 2/3 即「JLI 不可用」⇒ 调用方按 a2_jli_should_fallback 回退既有 JNI_CreateJavaVM 路径。
int a2_vm_launch_with_jli(NSString *javaHome,
                          NSArray<NSString *> *argv,
                          NSString *classpath,
                          NSString *mainClass,
                          int *outJLIRC);

#endif /* A2_JLI_LAUNCH_H */
