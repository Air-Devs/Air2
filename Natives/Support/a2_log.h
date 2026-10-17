// ============================================================================
// Natives/runtime/a2_log.h
// ★ [RT-P1] R7 —— 结构化日志 / 阶段进度 / fatal 记录（Air2 命名：a2_*）
// ----------------------------------------------------------------------------
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.6（崩溃容错与日志）+ §2（阶段 5→6→7→完成）
//
// 单一职责：本模块【只做日志/阶段事件】。
//   · 不持有任何全局可变状态（无阶段游标、无钩子、无单例）—— 阶段由调用方显式传入；
//   · 不读环境变量、不感知业务；不 install 信号处理器（由 facade 复用既有链路）。
//
// 输出：stderr（main.m 已把 stderr 重定向到 latestlog.txt，无缓冲、逐行 flush），
//   前缀 `[RT]`（结构化事件）/ `[LAUNCH-PROGRESS]`（阶段流）。供真机判据 grep。
//
// ★判据行的统一出口：a2_log_criterion★（与上面的 [RT] 事件区分）
//   · 一条判据行同时送两处：① 控制台（stderr）② App 会话日志文件。
//   · ② 的落点由宿主注入（`a2_log_set_sink`）—— App 层把 A2Log 的
//     `a2_log_session_sink` 接上，落进 Documents/lastlog.txt（也就是「运行日志」页读的那份）。
//     本模块【不】认识 A2Log（分层：Natives 只依赖 Libraries），故用注入而不是反向 include。
//   · 没注入 sink 时（单测 / 无宿主）只进控制台 —— 行为与从前一致，不会丢判据行。
// ============================================================================
#ifndef A2_LOG_H
#define A2_LOG_H

#import <Foundation/Foundation.h>

// 阶段模型：对齐 §2 启动链与 §5-P1 判据（阶段 5→6→7→完成）。
// 前置阶段 1~4（环境/JIT/渲染器/运行环境）由既有 AmeLaunchProgress 覆盖，本层不重复定义。
typedef NS_ENUM(NSInteger, A2Stage) {
    A2StageArgsReady         = 5,  // 阶段5：参数/资源路径已备齐（R3/R4 完成）
    A2StageJVMStarting       = 6,  // 阶段6：创建 JVM（JNI_CreateJavaVM 即将/已接管）
    A2StageWaitingFirstFrame = 7,  // 阶段7：等待游戏画面（主类 main 已派发）
    A2StageCompleted         = 8,  // 完成
};

/// 一条结构化事件（`[RT] ` 前缀）。message 为已成型文本（勿塞换行）。
void a2_log_line(NSString *message);

/// 带 C 风格格式的结构化事件（`fmt` 用 %s/%d/%p；传 NSString 用 `.UTF8String`）。
void a2_log_f(NSString *fmt, ...);

/// 逐项细节事件（verbose 桶，前缀 `[RT-V] `）：仅当 verbose 为真时输出。
/// verbose 由调用方【显式传入】（边界读一次 → 显式下传）—— 本模块仍无状态、不读环境、不读偏好。
void a2_log_detail(BOOL verbose, NSString *fmt, ...);

#pragma mark - 判据行统一出口（[A2-PAIRPIN] / [RXPC] / [FRAME] / [MEM]）

/// ★native 侧判据行统一出口★。一条判据行同时送：
///   ① 控制台：stderr（逐行 flush；App 的 main() 已把它归档进 Documents/latestlog.txt）
///   ② App 会话日志文件：由 `a2_log_set_sink` 注入的落点（Documents/lastlog.txt，
///      「运行日志」页读的那一份）——★与 Air2 侧的 `[A2Log criterion:]` 同一个落点★。
///
/// ⚠️与 a2_log_f 的区别：本函数用 ObjC 格式（认 `%@`），a2_log_f 走 vsnprintf（只认 `%s`）。
/// 不叠 `[RT] ` 前缀 —— 判据行自带行首标记（如 `[RXPC] `），前缀只会让 grep 多绕一层。
void a2_log_criterion(NSString *fmt, ...);

/// 注入「会话日志文件」落点（签名：收一行 UTF-8 文本）。
/// 由 App 装配点（Air2/App/main.m）在启动早期调用一次：`a2_log_set_sink(a2_log_session_sink);`
/// 传 NULL 取消注入（此后判据行只进控制台）。未注入时行为与注入前一致。
void a2_log_set_sink(void (* _Nullable sink)(const char *utf8Line));

/// `[LAUNCH-PROGRESS] 阶段 <stage>/8：<名>`。阶段由调用方显式给出（幂等、无内部游标）。
void a2_progress_enter(A2Stage stage);

/// `[LAUNCH-PROGRESS] 阶段 <stage> FAILED：<名>（<reason>）`。绝不致死。
void a2_progress_fail(A2Stage stage, NSString *reason);

/// 阶段可读名（供日志/对照）。
NSString *a2_stage_name(A2Stage stage);

/// 记一条 fatal：`[RT] FATAL: …`。本函数只落日志；转发到宿主崩溃通道由调用方
/// （facade/a2_launch）显式调用既有 `AMEJITAppendCrashNote` 完成 —— 不在此处藏钩子。
void a2_log_fatal(NSString *fmt, ...);

/// ★[RT-STRICT] 严格回退告警事件（前缀 `[RT-STRICT] `，**默认可见**、独立于 verbose）。
/// 与 a2_log_f 不同：前缀行首即为 `[RT-STRICT]`（不再叠 `[RT] `），便于真机判据一眼分辨
/// 「回退旧链」这类异常安全网事件。仍无状态、不读环境（严格与否由调用方显式判定）。
void a2_log_strict(NSString *fmt, ...);

#endif /* A2_LOG_H */
