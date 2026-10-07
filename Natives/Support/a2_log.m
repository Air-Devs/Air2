// ============================================================================
// Natives/runtime/a2_log.m
// ★ [RT-P1] R7 —— 结构化日志（实现；无状态）
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.6
// ============================================================================
#import "a2_log.h"

#include <stdio.h>
#include <stdarg.h>

// 统一写 stderr：main.m 的 init_redirectStdio 已把 stdout/stderr dup2 到管道
// （→ latestlog.txt）。stderr 无缓冲，每行显式 '\n' + fflush ⇒ 进程若在下一行前崩掉，
// 最后一条事件也已落盘。flockfile/funlockfile 提供每行原子性（多线程上报不交错）。
static void a2_emit(const char *prefix, const char *body) {
    flockfile(stderr);
    fputs(prefix, stderr);
    fputs(body, stderr);
    fputc('\n', stderr);
    fflush(stderr);
    funlockfile(stderr);
}

static void a2_emit_v(const char *prefix, NSString *fmt, va_list ap) {
    char body[2048];
    const char *cfmt = fmt.UTF8String;
    vsnprintf(body, sizeof(body), cfmt ? cfmt : "", ap);   // 有界化，日志本身不越界
    a2_emit(prefix, body);
}

void a2_log_line(NSString *message) {
    const char *s = message.UTF8String;
    a2_emit("[RT] ", s ? s : "");
}

void a2_log_f(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    a2_emit_v("[RT] ", fmt, ap);
    va_end(ap);
}

NSString *a2_stage_name(A2Stage stage) {
    switch (stage) {
        case A2StageArgsReady:         return @"阶段5 参数/资源就绪";
        case A2StageJVMStarting:       return @"阶段6 创建 JVM";
        case A2StageWaitingFirstFrame: return @"阶段7 等待游戏画面";
        case A2StageCompleted:         return @"完成";
        default:                       return [NSString stringWithFormat:@"阶段%ld", (long)stage];
    }
}

void a2_progress_enter(A2Stage stage) {
    NSString *line = [NSString stringWithFormat:@"[LAUNCH-PROGRESS] 阶段 %ld/8：%@",
                      (long)stage, a2_stage_name(stage)];
    a2_emit("", line.UTF8String ?: "");
}

void a2_progress_fail(A2Stage stage, NSString *reason) {
    NSString *line = [NSString stringWithFormat:@"[LAUNCH-PROGRESS] 阶段 %ld FAILED：%@（%@）",
                      (long)stage, a2_stage_name(stage),
                      (reason.length ? reason : @"未提供原因")];
    a2_emit("", line.UTF8String ?: "");
}

void a2_log_fatal(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    a2_emit_v("[RT] FATAL: ", fmt, ap);
    va_end(ap);
}
