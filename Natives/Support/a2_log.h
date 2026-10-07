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

/// `[LAUNCH-PROGRESS] 阶段 <stage>/8：<名>`。阶段由调用方显式给出（幂等、无内部游标）。
void a2_progress_enter(A2Stage stage);

/// `[LAUNCH-PROGRESS] 阶段 <stage> FAILED：<名>（<reason>）`。绝不致死。
void a2_progress_fail(A2Stage stage, NSString *reason);

/// 阶段可读名（供日志/对照）。
NSString *a2_stage_name(A2Stage stage);

/// 记一条 fatal：`[RT] FATAL: …`。本函数只落日志；转发到宿主崩溃通道由调用方
/// （facade/a2_launch）显式调用既有 `AMEJITAppendCrashNote` 完成 —— 不在此处藏钩子。
void a2_log_fatal(NSString *fmt, ...);

#endif /* A2_LOG_H */
