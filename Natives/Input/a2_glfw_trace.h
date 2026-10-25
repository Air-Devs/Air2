// ============================================================================
//  Natives/Input/a2_glfw_trace.h  —— GLFW 中立层调用跟踪（★纯诊断，零业务逻辑★）
// ----------------------------------------------------------------------------
//  用途：真机「黑屏但日志停住」时，能一眼看出 MC 到底卡在哪个 GLFW 调用上、
//        在哪个线程上、进去了多久还没回来。
//
//  ★本文件只放两个 inline 工具（单调时钟 / 内核线程 id）★：
//    · 不持有状态、不读环境变量、不装钩子 —— 计数在各自的调用点用 static 局部量管；
//    · 不含任何图形后端专有名（守住 scripts/verify_ownglfw_native.py 的「渲染器解耦」）。
//
//  输出格式（判据行，真机 grep `[A2-GLFW-TRACE]` 即可）：
//    [A2-GLFW-TRACE] enter glfwCreateWindow tid=… w=… h=…
//    [A2-GLFW-TRACE] exit  glfwCreateWindow tid=… rc=… ms=…
//  「只有 enter 没有 exit」= 卡在这个调用里（这就是黑屏的卡住点）。
// ============================================================================
#ifndef A2_GLFW_TRACE_H
#define A2_GLFW_TRACE_H

#include <pthread.h>
#include <time.h>

/// 单调时钟（微秒）。只用于算差值 ⇒ 不受系统时间调整影响。
static inline long long a2_glfw_tr_us(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return (long long) ts.tv_sec * 1000000LL + (long long) (ts.tv_nsec / 1000);
}

/// 内核线程 id（Mach thread port）。用来区分：主线程 / Java 渲染线程 / pump 线程。
/// 对同一线程多次调用结果稳定 ⇒ 可跨行对照。
static inline unsigned long long a2_glfw_tr_tid(void) {
    return (unsigned long long) pthread_mach_thread_np(pthread_self());
}

/// 耗时（毫秒）。t0 为 a2_glfw_tr_us() 的返回值。
static inline long long a2_glfw_tr_ms(long long t0) {
    long long dt = a2_glfw_tr_us() - t0;
    if (dt < 0) {
        return 0;
    }
    return dt / 1000;
}

#endif /* A2_GLFW_TRACE_H */
