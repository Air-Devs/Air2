// ============================================================================
//  Natives/Renderer/a2_gl_error_shim.m
//  Air2 —— ★MobileGlues 的 glGetError 保护（安装 / 待办 / JIT 就绪后重试）★
// ----------------------------------------------------------------------------
//  真机证据（1.20.1 + MG 2.0.16 + java-21，lastlog-101）：
//      #  SIGBUS (0xa) at pc=0x0000000125b8e4e4, pid=1687, tid=5123
//      # C  [libmobileglues.dylib+0x3e4e4]  glGetError+0x0
//  同一份日志里【一条 [A2-MG-SHIM] 也没有】——两个原因叠加：
//    ① 本模块过去只用 NSLog（走 Apple 统一日志，*不*进 stderr ⇒ 不进 lastlog.txt）；
//    ② 第一次调用发生在 `a2_gl_bridge_attach` ④（建 VM 之前），那时 mprotect(RWX) 必然
//       EACCES=13（iOS 26 禁 RWX、JIT 区还没建）⇒ 补丁从未真正生效。
//  本版两件事一起修：① 全部结论走 a2_log_f（stderr → lastlog.txt），入口先打
//  `install 开始 handle=…`；② 改不动时记「待办」+ 起一个有界看门狗，JIT 区一出现就装上。
//
//  做法（不拦 dlsym —— iOS 没有 dlvsym，拦了拿不回真正的 dlsym）：
//    MG 加载后，直接把它 glGetError 的头两条指令改写成
//        mov w0, #0     (0x52800000)   ← 返回 GL_NO_ERROR
//        ret            (0xD65F03C0)
//    glGetError 只用于诊断，恒返回 0 不影响渲染正确性；改完再调用绝不会崩。
//
//  改代码页的两条路（按侵入性排序，任一成功即写）：
//    ① mprotect(RWX)      —— JIT 就绪后可用；JIT 之前 EACCES(13)（iOS 26 禁 RWX）。
//    ② vm_protect(… COPY) —— 调试器下断点用的同一招：把代码页**私有化**后写，
//                            不要求 JIT 区，只要求进程可被调试（get-task-allow，即已开 JIT 的包）。
//  两条都失败 ⇒ 保持原样（宁可不修，不能写坏）+ 记待办，交给看门狗/上层在 JIT 就绪后重试。
// ============================================================================

#import "a2_gl_error_shim.h"
#import "a2_log.h"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/vm_param.h>
#include <mach/vm_prot.h>
#include <libkern/OSCacheControl.h>
#include <unistd.h>

/// 看门狗总时限 / 步长：建 VM 可能 10~60 秒（真机 lastlog-101 的 [JIT26] 区在建 VM 里才建），
/// 留 3 分钟余量；250ms 一次 ⇒ 一次 mprotect 的成本可以忽略。
static const NSTimeInterval kA2GlErrorShimWatchdogSeconds = 180.0;
static const useconds_t     kA2GlErrorShimWatchdogStepUS  = 250 * 1000;
/// 每这么多次尝试打一行「进行中」（避免刷爆日志；成功/放弃各打一行）。
static const NSUInteger     kA2GlErrorShimWatchdogReportEvery = 20;

/// 待办句柄（NULL = 无待办）。装上后清空 ⇒ 重试幂等。
static void *gPendingHandle = NULL;
/// 是否已生效（= glGetError 已是 `mov w0,#0; ret`）。
static BOOL  gPatched = NO;
/// 看门狗是否在跑（单实例；跑完/装上后清零，允许再次起）。
static BOOL  gWatchdogRunning = NO;
/// 互斥：install 来自主线程（attach / 改绑），retry / 看门狗来自其它线程。
static pthread_mutex_t gShimLock = PTHREAD_MUTEX_INITIALIZER;

/// 把 `page` 这一页改成「可写 + 可执行」。成功返回所用手段名（供日志），失败返回 NULL。
/// ★必须先试 mprotect、失败再试 vm_protect(COPY)★：前者零副作用（JIT 就绪后即成功），
/// 后者会让该页私有化（调试器断点同款做法），只有在真正需要时才用。
/// `quiet` = 看门狗轮询用：失败不打日志（成功一定打）。
static const char *a2_gl_error_shim_make_page_writable(void *page, size_t size, BOOL quiet) {
    if (mprotect(page, size, PROT_READ | PROT_WRITE | PROT_EXEC) == 0) {
        return "mprotect-RWX";
    }
    const int mprotectErrno = errno;

    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)size, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE | VM_PROT_COPY);
    if (!quiet) {
        a2_log_f(@"[A2-MG-SHIM] 改代码页：mprotect(RWX) 失败 errno=%d ⇒ 试 vm_protect(COPY) kr=%d",
                 mprotectErrno, (int)kr);
    }
    return (kr == KERN_SUCCESS) ? "vm_protect-COPY" : NULL;
}

/// 按手段还原页保护（尽力而为：还原失败不改变「已写入」这一事实，但要如实记一行）。
static void a2_gl_error_shim_restore_page(void *page, size_t size, const char *how, BOOL quiet) {
    if (how != NULL && strcmp(how, "mprotect-RWX") == 0) {
        if (mprotect(page, size, PROT_READ | PROT_EXEC) != 0 && !quiet) {
            a2_log_f(@"[A2-MG-SHIM] 还原页保护(RX) 失败 errno=%d（补丁已写入，仅保护位不同）", errno);
        }
        return;
    }
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)size, FALSE,
                                  VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS && !quiet) {
        a2_log_f(@"[A2-MG-SHIM] 还原页保护(RX) 失败 kr=%d（补丁已写入，仅保护位不同）", (int)kr);
    }
}

/// 真正改写一页内的 glGetError（安装与重试共用）。`phase` 只进日志（安装 / 延迟安装）。
static A2GlErrorShimResult a2_gl_error_shim_patch(void *handle, const char *phase, BOOL quiet) {
    void *sym = dlsym(handle, "glGetError");
    if (sym == NULL) {
        if (!quiet) {
            a2_log_f(@"[A2-MG-SHIM] %s：handle=%p 里没有 glGetError 导出 ⇒ 跳过（无需保护）", phase, handle);
        }
        return A2GlErrorShimNotApplicable;
    }

    void *page = (void *)((uintptr_t)sym & ~(uintptr_t)(PAGE_SIZE - 1));
    const char *how = a2_gl_error_shim_make_page_writable(page, (size_t)PAGE_SIZE, quiet);
    if (how == NULL) {
        if (!quiet) {
            a2_log_f(@"[A2-MG-SHIM] %s：代码页不可写 page=%p sym=%p ⇒ 本次不改写（保持原样）",
                     phase, page, sym);
        }
        return A2GlErrorShimPending;
    }

    uint32_t *code = (uint32_t *)sym;
    code[0] = 0x52800000u;   // mov w0, #0
    code[1] = 0xD65F03C0u;   // ret
    sys_icache_invalidate(sym, 8);

    const BOOL wrote = (code[0] == 0x52800000u && code[1] == 0xD65F03C0u);
    a2_gl_error_shim_restore_page(page, (size_t)PAGE_SIZE, how, quiet);

    a2_log_f(@"[A2-MG-SHIM] patched=%d（%s）sym=%p page=%p bytes=%08x %08x",
             (int)wrote, how, sym, page, code[0], code[1]);
    return wrote ? A2GlErrorShimPatched : A2GlErrorShimPending;
}

/// 把「已装上」这一事实落进状态（幂等）。
static void a2_gl_error_shim_mark_patched(void) {
    pthread_mutex_lock(&gShimLock);
    gPatched = YES;
    gPendingHandle = NULL;
    pthread_mutex_unlock(&gShimLock);
}

/// 看门狗循环：有界、静默重试，装上即退出。
static void a2_gl_error_shim_watchdog_loop(void) {
    NSDate *t0 = [NSDate date];
    NSUInteger tries = 0;
    while (YES) {
        usleep(kA2GlErrorShimWatchdogStepUS);
        tries++;

        pthread_mutex_lock(&gShimLock);
        const BOOL patched = gPatched;
        void *pending = gPendingHandle;
        pthread_mutex_unlock(&gShimLock);
        if (patched || pending == NULL) break;

        const NSTimeInterval elapsed = -[t0 timeIntervalSinceNow];
        if (elapsed > kA2GlErrorShimWatchdogSeconds) {
            a2_log_f(@"[A2-MG-SHIM] 延迟安装放弃：%.1fs 内 %lu 次尝试都改不动代码页"
                     @"（JIT 区/调试授权未给到）⇒ glGetError 保持原样", elapsed, (unsigned long)tries);
            break;
        }

        if (a2_gl_error_shim_patch(pending, "延迟安装(看门狗)", YES) == A2GlErrorShimPatched) {
            a2_gl_error_shim_mark_patched();
            a2_log_f(@"[A2-MG-SHIM] 延迟安装成功 handle=%p（第 %lu 次尝试，t=%.2fs）patched=1",
                     pending, (unsigned long)tries, elapsed);
            break;
        }
        if (tries % kA2GlErrorShimWatchdogReportEvery == 0) {
            a2_log_f(@"[A2-MG-SHIM] 延迟安装进行中：t=%.1fs 尝试=%lu（代码页仍不可写）",
                     elapsed, (unsigned long)tries);
        }
    }

    pthread_mutex_lock(&gShimLock);
    gWatchdogRunning = NO;
    pthread_mutex_unlock(&gShimLock);
}

/// 起看门狗（单实例）。★为什么不是「等某个回调」★：真机 lastlog-101 里 JIT 的**大区**
/// 是 libjvm 建 VM 时才向调试器讨的（`[JIT26] Got JIT mapping …`），进程内没有任何
/// 「区已就绪」的通知点；而 `[A2JITEnvironment verifiedRegion]` 在本线一直是 NULL
/// （gate 走的是老闸门 A2LegacyJITGate）。⇒ 用「按时间重试、成功即停」这种可证伪的做法，
/// 不做「假设某个回调会来」的等待。
static void a2_gl_error_shim_start_watchdog(void) {
    pthread_mutex_lock(&gShimLock);
    const BOOL already = gWatchdogRunning;
    if (!already) gWatchdogRunning = YES;
    pthread_mutex_unlock(&gShimLock);
    if (already) return;

    a2_log_f(@"[A2-MG-SHIM] 起看门狗：每 %.0fms 试一次，最长 %.0fs（JIT 区一出现就装上）",
             (double)kA2GlErrorShimWatchdogStepUS / 1000.0, kA2GlErrorShimWatchdogSeconds);
    NSThread *worker = [[NSThread alloc] initWithBlock:^{
        a2_gl_error_shim_watchdog_loop();
    }];
    worker.name = @"a2-mg-shim-retry";
    worker.qualityOfService = NSQualityOfServiceUtility;
    [worker start];
}

A2GlErrorShimResult a2_gl_error_shim_install_for_handle(void *handle) {
    a2_log_f(@"[A2-MG-SHIM] install 开始 handle=%p patched=%d pending=%p",
             handle, (int)gPatched, gPendingHandle);

    if (handle == NULL) {
        a2_log_f(@"[A2-MG-SHIM] handle 为空 ⇒ 不安装（调用方未给出后端本体句柄）");
        return A2GlErrorShimNotApplicable;
    }

    pthread_mutex_lock(&gShimLock);
    const BOOL patched = gPatched;
    pthread_mutex_unlock(&gShimLock);
    if (patched) {
        a2_log_f(@"[A2-MG-SHIM] 已生效 ⇒ 幂等跳过（不重复改写）");
        return A2GlErrorShimPatched;
    }

    const A2GlErrorShimResult r = a2_gl_error_shim_patch(handle, "安装", NO);
    if (r == A2GlErrorShimPatched) {
        a2_gl_error_shim_mark_patched();
    } else if (r == A2GlErrorShimPending) {
        pthread_mutex_lock(&gShimLock);
        gPendingHandle = handle;
        pthread_mutex_unlock(&gShimLock);
        a2_log_f(@"[A2-MG-SHIM] ★记待办★ JIT 尚未就绪（代码页不可写）⇒ 看门狗 + "
                 @"a2_gl_error_shim_retry_pending() 会在 JIT 就绪后重试");
        a2_gl_error_shim_start_watchdog();
    }
    return r;
}

A2GlErrorShimResult a2_gl_error_shim_retry_pending(void) {
    pthread_mutex_lock(&gShimLock);
    const BOOL patched = gPatched;
    void *pending = gPendingHandle;
    pthread_mutex_unlock(&gShimLock);
    if (patched) {
        return A2GlErrorShimPatched;
    }
    if (pending == NULL) {
        return A2GlErrorShimNotApplicable;   // 没有待办 ⇒ 静默（不刷日志）
    }

    a2_log_f(@"[A2-MG-SHIM] 延迟安装：JIT 就绪后重试 handle=%p", pending);
    const A2GlErrorShimResult r = a2_gl_error_shim_patch(pending, "延迟安装", NO);
    if (r == A2GlErrorShimPatched) {
        a2_gl_error_shim_mark_patched();
        a2_log_f(@"[A2-MG-SHIM] 延迟安装成功 handle=%p patched=1（glGetError 恒返回 GL_NO_ERROR）", pending);
        return r;
    }
    if (r == A2GlErrorShimPending) {
        a2_log_f(@"[A2-MG-SHIM] 延迟安装仍失败 ⇒ 待办保留，看门狗继续（不每轮刷日志）");
        a2_gl_error_shim_start_watchdog();
    } else {
        // NotApplicable = 这个库里没有 glGetError ⇒ 清掉待办，不必再试。
        pthread_mutex_lock(&gShimLock);
        gPendingHandle = NULL;
        pthread_mutex_unlock(&gShimLock);
    }
    return r;
}
