// ============================================================================
// Natives/Context/a2_jli_entry.h
// ★ [JLI-LAUNCH] JLI 入口的【纯逻辑】：libjli 候选/选定 + argv 组装 + 回退判定
// ----------------------------------------------------------------------------
// 背景（为什么有本模块）：
//   真机上本层原路径（dlopen libjvm → JNI_CreateJavaVM）停在
//   `[A2JVM] R4 调用 JNI_CreateJavaVM` 之后不再返回（VM 初始化里卡死）。
//   老线（树 510）★根本不用 JNI_CreateJavaVM★：它 dlopen libjli 后调 JLI_Launch —— 那是
//   HotSpot 自带的 java 启动器，内部完成「建 VM + 跑主类 main」，真机上跑通过。
//   本模块把这条验过的入口搬过来（只搬调用约定与行为，不搬老线代码）。
//
// 为什么「纯逻辑」单独成文件：
//   ① argv 组装（选项顺序 / classpath 单一来源 / 特殊字符 / 版本布局差异）与
//      「不可用时是否回退」都是**行为契约** ⇒ 必须能在 macOS 上用 clang 真编译、真运行
//      （tests/Natives/run_jli_entry_tests.py）；
//   ② 本文件不 import jni.h、不 dlopen、不写日志、不读环境变量 ⇒ 单测不需要 iOS/JRE 环境。
//   dlopen/dlsym/调用与 J1/J2/J3 判据行归 a2_jli_launch.{h,m}。
// ============================================================================
#ifndef A2_JLI_ENTRY_H
#define A2_JLI_ENTRY_H

#import <Foundation/Foundation.h>

// ----------------------------------------------------------------------------
// JLI 入口的返回码（a2_vm_launch_with_jli 用；launch facade 据此决定「继续/回退」）
// ----------------------------------------------------------------------------
typedef NS_ENUM(int, A2JLIRC) {
    /// JLI_Launch 已调用并返回（真机语义：要等主类 main 跑完才返回；`outJLIRC` 是其 rc）。
    A2JLIRCCalled       = 0,
    /// 入参非法（javaHome/主类/argv 为空）⇒ 不可用，且**不应**靠回退掩盖（同一份错参数换条路仍错）。
    A2JLIRCBadArgs      = 1,
    /// libjli 打不开（两路径都不存在或 dlopen 失败）⇒ 不可用 ⇒ 回退 JNI_CreateJavaVM。
    A2JLIRCDlopenFailed = 2,
    /// libjli 里没有 JLI_Launch 符号 ⇒ 不可用 ⇒ 回退 JNI_CreateJavaVM。
    A2JLIRCDlsymFailed  = 3,
};

/// libjli 候选路径（★版本布局差异★，顺序即优先级）：
///   ① `<javaHome>/lib/jli/libjli.dylib` —— Java 8 布局；
///   ② `<javaHome>/lib/libjli.dylib`     —— Java 9+ 布局（本包 java-21/25-openjdk 即此）。
/// javaHome 为空 ⇒ 返回空数组（不回退到进程 CWD 猜路径）。
NSArray<NSString *> *a2_jli_candidate_paths(NSString *javaHome);

/// 在候选里挑【第一个真实存在】的 libjli；都不存在 ⇒ nil。
/// 与老线口径一致：Java 8 布局存在时优先用它（老线 isJava8 判定同源）。
NSString *a2_jli_resolve_libjli(NSString *javaHome);

/// ★纯函数★组装 JLI_Launch 的 argv（顺序即语义）：
///   `[<javaHome>/bin/java, <options…>, "-cp", <classpath>, <mainClass>, <programArgs…>]`
///
/// 规则（逐条都有单测）：
///   · argv[0]：javaHome 非空 ⇒ `<javaHome>/bin/java`（多余尾斜杠先归并）；为空 ⇒ `"java"`；
///   · options：**原序保留**；空串跳过；★`-cp` / `-classpath` / `-Djava.class.path=*` / `-jar`
///     一律丢弃★ —— JLI 的 classpath 只认本函数的 `-cp <classpath>` 一处（单一来源），
///     重复注入会让「哪份 classpath 生效」变得不可判；
///   · classpath 为空 ⇒ ★不产生 `-cp` 条目★（JLI 按 java 语义用默认 classpath，而非空的 -cp）；
///   · 主类为空 ⇒ 返回 nil（拒绝组 argv：没有主类的 JLI 命令行无意义）；
///   · programArgs 按原序追加在主类之后（`-jar` / `--plan` 这类在【主类之后】的 token 属程序参数，
///     绝不丢）；
///   · 所有条目按原样搬运（空格 / `:` / 中文 / `$` `%` `"` 等特殊字符一字不改）。
NSArray<NSString *> *a2_jli_build_argv(NSString *javaHome,
                                       NSArray<NSString *> *options,
                                       NSString *classpath,
                                       NSString *mainClass,
                                       NSArray<NSString *> *programArgs);

/// 该返回码是否表示「JLI 不可用、应回退既有 JNI_CreateJavaVM 路径」。
/// 只有 dlopen / dlsym 失败算不可用；已调用（0）与入参非法（1）都不回退。
BOOL a2_jli_should_fallback(int rc);

#endif /* A2_JLI_ENTRY_H */
