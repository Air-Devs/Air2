// ============================================================================
// Natives/runtime/a2_log.m
// ★ [RT-P1] R7 —— 结构化日志（实现；无状态）
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.6
// ============================================================================
#import "a2_log.h"

#include <stdio.h>
#include <stdarg.h>

// 统一写 stderr：App 的 main() 早期调 [A2Log archiveStderr]（Air2/Utils/A2Log.m），
// 那里用 dup2 把 stderr 直接接到 Documents/latestlog.txt（无缓冲、带大小上限）。
// stderr 每行显式 '\n' + fflush ⇒ 进程若在下一行前崩掉，最后一条事件也已落盘。
// flockfile/funlockfile 提供每行原子性（多线程上报不交错）。
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

// 逐项细节日志：仅当 verbose 为真时输出（前缀 [RT-V] 便于与默认行区分/过滤）。
// verbose 由调用方显式给出 —— 本模块不读环境、不读偏好、无全局状态（同 R7 单一职责）。
void a2_log_detail(BOOL verbose, NSString *fmt, ...) {
    if (!verbose) return;
    va_list ap;
    va_start(ap, fmt);
    a2_emit_v("[RT-V] ", fmt, ap);
    va_end(ap);
}

// ----------------------------------------------------------------------------
// 判据行统一出口
// ----------------------------------------------------------------------------
// 会话日志文件的落点（由宿主注入）。★只有一个函数指针、只在启动早期被写一次★
// （main() 里，早于任何线程起来跑判据行），所以读侧不需要加锁：
// 写 happens-before 后续线程的创建。
// 未注入（NULL）⇒ 判据行只进控制台；单测/无宿主环境因此不需要任何桩件。
static void (*gCriterionSink)(const char *) = NULL;

void a2_log_set_sink(void (*sink)(const char *utf8Line)) {
    gCriterionSink = sink;
}

void a2_log_criterion(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    // 与 a2_log_f 不同：这里用 ObjC 格式（%@ 可用），因为判据行里常有对象字段。
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    const char *utf8 = line.UTF8String ?: "";
    a2_emit("", utf8);                      // ① 控制台（复用本模块的单行 + 立即 flush 口径）
    void (*sink)(const char *) = gCriterionSink;
    if (sink != NULL) { sink(utf8); }        // ② App 会话日志文件（宿主注入；未注入则跳过）
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

// ★[RT-STRICT] 回退告警：行首前缀即 `[RT-STRICT] `（不再叠 `[RT] `）⇒ 真机判据可一眼分辨。
// 默认可见（不受 verbose / 开关影响）——回退旧链属异常安全网事件，必须始终留痕。
void a2_log_strict(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    a2_emit_v("[RT-STRICT] ", fmt, ap);
    va_end(ap);
}
