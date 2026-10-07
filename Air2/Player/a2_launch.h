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
BOOL a2_launch_runtime_enabled(void);

/// 运行时层启动：R3 摄取旧 margv → R4 产出并注入资源路径 → 构建 JavaVMInitArgs → R2 建 VM
/// → 在 VM 内 dispatch 主类 main。返回值：
///    0  = 成功（main 正常返回）
///   -1  = R3 无法摄取（如 -jar 形态）⇒ facade **须回退旧链**（尚未建 VM）
///   -2  = 主类为空
///   -3  = 未找到 libjvm.dylib
///   -4  = R2 建 VM 失败
///   -5..-7 = 主类 main dispatch 失败（FindClass/GetStaticMethodID/执行抛异常）
/// ★ argc 为「条目计数」（含 argv[0]）；argv[0] 应是 "<javaHome>/bin/java"（R3 会丢弃）。
int a2_launch_jvm_with_argv(int argc, const char *const argv[], A2LaunchInput input);

#endif /* A2_LAUNCH_H */
