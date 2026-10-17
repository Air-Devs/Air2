// ============================================================================
// Natives/runtime/a2_launch.h
// ★ [RT-P1] facade —— 自研 runtime 层对外入口（launchJVM 可切到本层）
//                      （Air2 命名：A2*/a2_*）
// ----------------------------------------------------------------------------
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.3/§3.4/§3.6 + §4（JavaLauncher 退化为 facade）
//
// 单一职责：本文件【只做启动编排】—— 把 R3/R4/R7/R2 串起来并 dispatch 主类 main。
//   不实现参数拼装/路径拼装/日志/VM 加载（分别归 R3/R4/R7/R2）。
//
// 开关（显式边界）：
//   · `RT_P1_RUNTIME=1`   —— 是否切到 runtime 层（读于 a2_launch_runtime_enabled；默认关 ⇒ 旧链）。
//                           真机侧载不可依赖 env ⇒ 亦接受标志文件 $POJAV_HOME/rt_p1_runtime.enable。
//   · `RT_CP_FORM`        —— classpath 形态 A/B（读于本文件边界，显式传给 R3；见 §3.3）。
//   · `RT_VM_STRICT=1`    —— ignoreUnrecognized 收紧为 NO（读于本文件边界）。
//   · `RT_P1_VERBOSE=1`   —— ★[RT-P1I] 逐项细节日志（verbose 桶，默认关）；读于本文件边界。
//                           亦接受设置项 debug.rt_p1_verbose（设置 → 调试）。默认关 ⇒ 正常启动安静。
//   · `RT_P1_STRICT=1`    —— ★[RT-STRICT] 严格回退门（**优先级最高**，读于 a2_launch_strict_enabled）：
//                           ① 强制切到 runtime 链（覆盖 RT_P1_RUNTIME=0/未置）；② 禁止任何回退旧链——
//                           本该回退处直接阻断启动并输出取证（原因 + 文件:行号 + 关键变量值）。
//                           默认关（=保留“回退旧链”安全网，仅打默认可见告警 + 计数）。
//                           亦接受设置项 debug.rt_p1_strict（设置 → 调试；见 PLPreferences.m 注册）。
//   ★ 环境变量只在 facade 边界读一次 → 显式传给下层；下层不读环境、不靠全局状态隐式决定行为。★
//
// 依赖：a2_log(R7) / a2_argbuilder(R3) / a2_resourcepaths(R4) / a2_vmloader(R2) —— 均为 a2_* +
//   系统框架，1:1 可移植。
// ============================================================================
#ifndef A2_LAUNCH_H
#define A2_LAUNCH_H

#import <Foundation/Foundation.h>

// ----------------------------------------------------------------------------
// 输入：facade（launchJVM）在切换点已有的量；可空项由 R4 自行补全或跳过。
// ----------------------------------------------------------------------------
typedef struct {
    NSString *javaHome;           ///< 选中 JRE home（非空）
    NSString *gameDir;            ///< 实例游戏目录 → -Duser.dir
    NSString *userHome;           ///< POJAV_HOME → -Duser.home
    NSString *tmpDir;             ///< 实例 tmp → -Djava.io.tmpdir
    NSString *frameworksPath;     ///< <bundle>/Frameworks（空 ⇒ R4 由 bundlePath 推）
    NSString *librariesPath;      ///< <...>/libraries
    NSString *lwjglDir;           ///< <libraries>/lwjgl-<ver>
    NSString *frontJar;           ///< launchJar 时 classpath 最前的 jar
} A2LaunchInput;

/// facade 开关：环境变量 `RT_P1_RUNTIME=1`（真机侧载另接受标志文件 `$POJAV_HOME/rt_p1_runtime.enable`）
/// 时为真（默认假 ⇒ 走旧链，行为不变）。
/// ★[RT-STRICT] 若 `RT_P1_STRICT=1`（或设置项 debug.rt_p1_strict）⇒ 本函数恒为真（严格模式强制切链）。
BOOL a2_launch_runtime_enabled(void);

/// ★[RT-STRICT] 严格回退门开关（优先级最高）。真值来源：env `RT_P1_STRICT=1` > 设置项
/// `debug.rt_p1_strict`。为真时：强制 runtime 链 + 禁止任何回退旧链（见 a2_fallback_gate）。
BOOL a2_launch_strict_enabled(void);

/// ★[RT-NOAGENT] P2 第一步开关：**不注入 javaagent**（默认关）。真值来源（边界读一次）：
///   env `RT_NO_AGENT=1` ⇒ 开；`=0` ⇒ 关（显式否决其余来源）；
///   未置 ⇒ 标志文件 `$POJAV_HOME/rt_no_agent.enable` 存在 ⇒ 开；
///   否则 ⇒ 设置项 `debug.rt_no_agent`（设置 → 调试；见 PLPreferences.m 注册）。
/// 为真且运行时链生效时，本层在构建 JavaVMInitArgs **之前**移除全部 `-javaagent:*`
/// （含 agent 专属 `-Dmetallum.mc.version=`），其余参数/资源/主类一律不变。
/// 目的：当场量出「没 agent 这条链差哪一步」= P2 路线图首图。
/// ★ 本开关只在 runtime 链（a2_launch_jvm_with_argv）生效——旧链（pJLI_Launch）不经本层，
///   故其 margv 里的 -javaagent 照原样携带；要一并禁掉请用 `RT_P1_STRICT=1` 强制切链。
BOOL a2_launch_no_agent_enabled(void);

/// ★[RT-STRICT] 回退门：facade 在【唯一回退点】（新链返回可回退码、即将 pJLI_Launch）调用一次。
///   · 非严格（默认）：以【默认可见】级别打高亮告警
///       `[RT-STRICT] FALLBACK -> 旧链: 原因=… 源=文件:行号 回退计数=N 取证=…`
///     并返回 0（允许回退 —— 保留安全网）。计数器为进程内自增（同一次启动多次回退可见 #N）。
///   · 严格（RT_P1_STRICT=1）：打 `[RT-STRICT] BLOCK 禁止回退旧链…` + 取证（原因 + 文件:行号 +
///     关键变量值），返回 1（**禁止回退**：facade 必须阻断启动，绝不进旧链）。
/// reason/loc/details 均为 UTF-8 C 串（可空，空则记 "(未提供)"）。
int a2_fallback_gate(const char *reason, const char *loc, const char *details);

/// 运行时层启动：R3 摄取旧 margv → R4 产出并注入资源路径 → ★JLI_Launch 入口（默认）★
/// → JLI 不可用时才回退 JNI_CreateJavaVM（建 VM 后在本层 dispatch 主类 main）。返回值：
///    0  = 成功（JLI 走到 main 结束并 rc=0；或回退路径下主类 main 正常返回）
///   -1  = R3 判定 jarMode（`-jar` 落在主类之前的 JLI 选项区）⇒ facade **须回退旧链**（尚未建 VM）
///         ★[RT-STRICT] 严格模式下不回退：facade 经 a2_fallback_gate 判定后阻断启动。
///   -8  = R3 摄取失败（未解析出主类 / 参数不足）⇒ facade **须回退旧链**（尚未建 VM）
///         ★[RT-STRICT] 同上：严格模式下阻断而非回退。
///   -2  = 主类为空
///   -3  = 未找到 libjvm.dylib（仅回退路径；JLI 入口不需要它）
///   -4  = R2 建 VM 失败（仅回退路径）
///   -9  = ★[VS-GAP][G6] classpath 与 R3 摄取不一致（版本/路径漂移）⇒ **阻断启动**（不得回退）
///   -13 = ★[JLI-LAUNCH] JLI_Launch 已返回但 rc≠0（主类/启动器异常退出）
///   -14 = ★[JLI-LAUNCH] JLI 入口入参非法（javaHome/主类/argv 为空）⇒ 不启动、也不回退
///   （★返回码分配★：-10/-11/-12 已被渲染器 / JRE 档位 / GL 桥的阻断码占用，本单取 -13/-14）
///   -5..-7 = 主类 main dispatch 失败（FindClass/GetStaticMethodID/执行抛异常；仅回退路径）
/// ★ argc 为「条目计数」（含 argv[0]）；argv[0] 应是 "<javaHome>/bin/java"（R3 会丢弃）。
/// ★ 主类之后出现的 `-jar` 不是 JLI 选项（是传给主类的程序参数）⇒ 归 R3 程序参数，不再是 jarMode。
int a2_launch_jvm_with_argv(int argc, const char *const argv[], A2LaunchInput input);

#endif /* A2_LAUNCH_H */
