//
//  A2JITEnvironment.m
//  Air2
//
//  实现 —— 逐条搬运自 feat/runtime-native 的 Natives/utils.m（[JIT-FLOW] /
//  [JIT-P0.1] / [JIT-P0.2] / [JIT-P0.3] / [JIT-HANG] / [JIT-ORDER]）。
//    · 复现判据语义与日志，不改判定结论；
//    · 去掉调试器/使能器 UI 适配、TrollStore 自开 JIT、下载、版本相关逻辑
//      （那些属上层或业务，不在 Natives/Support）。
//    · 每段上方标注来源行号，便于复核。
//

#import "A2JITEnvironment.h"

#import <dlfcn.h>
#import <errno.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach/vm_region.h>
#import <os/lock.h>
#import <setjmp.h>
#import <signal.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>
#import <dispatch/dispatch.h>

// ============================================================================
// 日志 —— 搬运自 jni_boot.m L94–L100 的 rt_log 思路：
//   写 stderr（main 已把 stdout/stderr dup2 进管道 → latestlog.txt），逐行带 '\n'，
//   进程若崩也能留下最后几行。
// ============================================================================
void a2_jit_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

// ============================================================================
// brk #0x69 叶子原语
//   来源：utils.m L752–L756（裸 JIT26CreateRegionLegacy）。
//   ★不改语义★：naked + 只 brk + ret；区域地址由调试器经寄存器回填。
// ============================================================================
__attribute__((noinline, optnone, naked))
void *a2_jit_brk69_create_region(size_t len) {
    asm("brk #0x69 \n"
        "ret");
}

// brk #0xf00d cmd=2 = 下发 JIT 脚本（脚本引擎注册的命令）。
//   来源：utils.m L782–L787（BreakSendJITScript）。x16=2；x0=脚本指针、x1=长度（由 ABI 传入）。
__attribute__((noinline, optnone, naked))
static void a2_jit_brk_f00d_send_script(char *script, size_t len) {
    asm("mov x16, #2 \n"
        "brk #0xf00d \n"
        "ret");
}

// ============================================================================
// [JIT-NOCRASH] SIGTRAP 安全网 —— 搬运自 utils.m L824–L948。
//   调试器未就岗时执行 brk ⇒ SIGTRAP ⇒ 进程直接死。这里在调用窗口内布一层
//   SIGTRAP handler + sigsetjmp/siglongjmp：无人应答时把「必死崩溃」转成
//   「函数返回失败」，由调用方跳过该步；调试器在岗时 brk 由调试器例外端口现场
//   服务（Mach 例外优先于信号转换），本 handler 不触发，成功路径与裸调用逐字节一致。
//   嵌套 / 可重入：裸协议函数全是叶子，安全网支持最多 A2JIT_TRAP_MAX_DEPTH 层窗口。
// ============================================================================
#define A2JIT_TRAP_MAX_DEPTH 8

static sigjmp_buf gA2JITTrapEnv;                             // 第 0 层窗口缓冲
static sigjmp_buf gA2JITTrapNestEnv[A2JIT_TRAP_MAX_DEPTH];   // 更深层窗口槽位
static volatile sig_atomic_t gA2JITTrapDepth = 0;            // 活动窗口层数（0=未布网）
static volatile sig_atomic_t gA2JITTrapArmed = 0;            // >0 即「有窗口在等 brk」

static sigjmp_buf *a2_jit_trap_slot(int depth) {
    if (depth <= 0) return &gA2JITTrapEnv;
    if (depth < A2JIT_TRAP_MAX_DEPTH) return &gA2JITTrapNestEnv[depth];
    return &gA2JITTrapNestEnv[A2JIT_TRAP_MAX_DEPTH - 1];
}

static void a2_jit_trap_catch(int sig) {
    if (!gA2JITTrapArmed || gA2JITTrapDepth <= 0) {
        signal(sig, SIG_DFL);   // 不属于本安全网：恢复默认语义原样致死，不吞异常
        raise(sig);
        return;
    }
    sigjmp_buf *env = a2_jit_trap_slot((int)gA2JITTrapDepth - 1);
    siglongjmp(*env, 1);
}

// 进入窗口：安装 handler、登记本层槽位。返回本层索引；<0 = 深度超限无法布网，
// 调用方【必须】据此直接降级，绝不能再调用裸 brk 函数。
static int a2_jit_trap_push(struct sigaction *oldsa, sigjmp_buf **outEnv) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = a2_jit_trap_catch;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    if (oldsa) memset(oldsa, 0, sizeof(*oldsa));   // 失败也不回装垃圾
    sigaction(SIGTRAP, &sa, oldsa);

    int idx = (int)gA2JITTrapDepth;
    if (idx < 0 || idx >= A2JIT_TRAP_MAX_DEPTH) {
        sigaction(SIGTRAP, oldsa, NULL);           // 回滚，保持环境原样
        if (outEnv) *outEnv = NULL;
        return -1;
    }
    if (outEnv) *outEnv = a2_jit_trap_slot(idx);
    gA2JITTrapDepth = (sig_atomic_t)(idx + 1);
    gA2JITTrapArmed = 1;
    return idx;
}

// 退出窗口：把 depth 回退到本层（处理「从 handler 跳回时更内层已被解开」），恢复原处置。
static void a2_jit_trap_pop(int idx, struct sigaction *oldsa) {
    if (idx >= 0 && (int)gA2JITTrapDepth > idx) {
        gA2JITTrapDepth = (sig_atomic_t)idx;
    }
    if (gA2JITTrapDepth <= 0) {
        gA2JITTrapArmed = 0;
    }
    sigaction(SIGTRAP, oldsa, NULL);
}

void *a2_jit_brk69_create_region_safe(size_t len) {
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = a2_jit_trap_push(&oldsa, &env);
    if (idx < 0) {
        a2_jit_log("[A2JIT] brk #0x69 skipped: trap-window depth overflow -- degrade");
        return NULL;
    }
    void *result = NULL;
    if (sigsetjmp(*env, 1) == 0) {
        result = a2_jit_brk69_create_region(len);
    } else {
        a2_jit_log("[A2JIT] brk #0x69 NOT serviced (no debugger) -- degraded, returning NULL");
        result = NULL;
    }
    a2_jit_trap_pop(idx, &oldsa);
    return result;
}

BOOL a2_jit_send_script_safe(const char *utf8, size_t len) {
    if (utf8 == NULL || len == 0) {
        a2_jit_log("[A2JIT] send_script skipped: empty script");
        return NO;
    }
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = a2_jit_trap_push(&oldsa, &env);
    if (idx < 0) {
        a2_jit_log("[A2JIT] send_script skipped: trap-window depth overflow -- degrade");
        return NO;
    }
    BOOL ok = NO;
    if (sigsetjmp(*env, 1) == 0) {
        a2_jit_brk_f00d_send_script((char *)utf8, len);   // brk #0xf00d cmd=2
        ok = YES;
    } else {
        a2_jit_log("[A2JIT] brk #0xf00d(cmd=2 send script) NOT serviced -- degraded");
        ok = NO;
    }
    a2_jit_trap_pop(idx, &oldsa);
    return ok;
}

// ============================================================================
// 区域查询 —— 搬运自 utils.m L1609–L1636（ameJITQueryRegionProt）。
//   ★iOS SDK 的 <mach/mach_vm.h> 是不可用的 #error 桩★，故用 vm_region_64
//   （<mach/vm_map.h>）。只读、无副作用，拿到「这到底是不是一块真映射、能不能写/执行」。
// ============================================================================
int a2_jit_query_region_prot(void *addr, size_t len,
                             unsigned int *curOut, unsigned int *maxOut,
                             unsigned long long *sizeOut) {
    if (addr == NULL) return -1;
    vm_address_t a = (vm_address_t)(uintptr_t)addr;
    vm_size_t sz = 0;
    vm_region_basic_info_data_64_t info;
    memset(&info, 0, sizeof(info));
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &a, &sz,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &count, &obj);
    if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
    (void)len;
    if (kr != KERN_SUCCESS) {
        if (curOut) *curOut = 0;
        if (maxOut) *maxOut = 0;
        if (sizeOut) *sizeOut = 0;
        a2_jit_log("[A2JIT] vm_region_64(%p) kr=%d (%s) -- address has NO mapping",
                   addr, kr, mach_error_string(kr));
        return -1;
    }
    if (curOut) *curOut = info.protection;
    if (maxOut) *maxOut = info.max_protection;
    if (sizeOut) *sizeOut = (unsigned long long)sz;
    return 0;
}

// ============================================================================
// 「真写入 + 真执行」自证基础设施 —— 搬运自 utils.m L2479–L2503。
//   探针指令 arm64: mov x0,#42 ; ret；x86_64: mov eax,42 ; ret。
// ============================================================================
#define A2JIT_PROBE_RETVAL 42

#if defined(__arm64__) || defined(__aarch64__)
static const uint32_t kA2JITProbeCode[] = { 0xD2800540u, 0xD65F03C0u };
#elif defined(__x86_64__)
static const uint8_t  kA2JITProbeCode[] = { 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
#else
static const uint8_t  kA2JITProbeCode[] = { 0 };
#endif

static sigjmp_buf gA2JITExecProbeEnv;
static volatile sig_atomic_t gA2JITExecProbeArmed = 0;

// 探针安全网：只在探针窗口内接管 SIGBUS/SIGSEGV；窗口外原样致死（绝不吞别人的崩溃）。
static void a2_jit_exec_probe_handler(int sig) {
    if (!gA2JITExecProbeArmed) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    gA2JITExecProbeArmed = 0;
    siglongjmp(gA2JITExecProbeEnv, 1);
}

// ============================================================================
// 区域自证 —— 搬运自 utils.m L2509–L2584（ameJITProveRegionRWX）。
//   ① mach_vm_region 确认有映射；② mprotect(RW)（被拒 ⇒ NotWritable）；③ 写真指令 + 回读；
//   ④ mprotect(RX)；⑤ 真的 call 并核对返回值。取指保护失败由安全网接住 ⇒ ExecFaulted。
//   ★调用方须知道：本自证在 iOS26+ 常返回 Inconclusive★（RW→RX 会撤销调试器对该页的
//   可执行祝福），故本层【只把它当日志】，不作为可用性判据（见 ensureVerifiedWithinBudget）。
// ============================================================================
A2JITRegionProof a2_jit_prove_region_rwx(void *addr, size_t len,
                                         int *mprotectRcOut, int *errnoOut) {
    if (mprotectRcOut) *mprotectRcOut = -999;
    if (errnoOut) *errnoOut = 0;
    if (addr == NULL || len < sizeof(kA2JITProbeCode)) return A2JITRegionProofInconclusive;

    // ① 无映射直接判否（别拿垃圾地址去 mprotect）。
    unsigned int c0 = 0, m0 = 0;
    unsigned long long s0 = 0;
    if (a2_jit_query_region_prot(addr, len, &c0, &m0, &s0) != 0) {
        return A2JITRegionProofUnmapped;
    }

    // ② 弄成可写；被拒 ⇒ 就是「拿不到可写 code cache」的 JVM 崩溃形态。
    errno = 0;
    int mr = mprotect(addr, len, PROT_READ | PROT_WRITE);
    int me = errno;
    if (mprotectRcOut) *mprotectRcOut = mr;
    if (errnoOut) *errnoOut = me;
    if (mr != 0) {
        a2_jit_log("[A2JIT] region @%p mprotect(RW) DENIED errno=%d(%s) (cur=0x%x max=0x%x) => NOT writable",
                   addr, me, strerror(me), c0, m0);
        return A2JITRegionProofNotWritable;
    }

    // ③ 真写入探针指令 + 真回读（排除「写入被优化 / 没落地」）。
    memcpy(addr, kA2JITProbeCode, sizeof(kA2JITProbeCode));
    sys_icache_invalidate(addr, len);
#if defined(__arm64__) || defined(__aarch64__)
    uint32_t rb0 = 0;
    memcpy(&rb0, addr, sizeof(uint32_t));
    if (rb0 != kA2JITProbeCode[0]) {
        a2_jit_log("[A2JIT] self-proof: region @%p memcpy WRITE DID NOT LAND (wrote 0x%08x readback 0x%08x) -- 写入被优化/未落地",
                   addr, kA2JITProbeCode[0], rb0);
    }
#endif

    // ④ 标 RX。失败 ⇒ Inconclusive（多为 iOS26+ RW→RX 撤销了调试器对该页的可执行祝福）。
    errno = 0;
    if (mprotect(addr, len, PROT_READ | PROT_EXEC) != 0) {
        int rxErrno = errno;
        a2_jit_log("[A2JIT] self-proof: region @%p mprotect(RX) FAILED errno=%d(%s) after RW toggle "
                   "(cur0=0x%x max0=0x%x) => proof=5(inconclusive) 的直接原因（自证局限，非区域不可用）",
                   addr, rxErrno, strerror(rxErrno), c0, m0);
        return A2JITRegionProofInconclusive;
    }

    // ⑤ 真执行（同一套安全网；保存/恢复原处置）。
    struct sigaction sa, oldBus, oldSegv;
    memset(&sa, 0, sizeof(sa));
    memset(&oldBus, 0, sizeof(oldBus));
    memset(&oldSegv, 0, sizeof(oldSegv));
    sa.sa_handler = a2_jit_exec_probe_handler;
    sa.sa_flags = SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS, &sa, &oldBus);
    sigaction(SIGSEGV, &sa, &oldSegv);

    gA2JITExecProbeArmed = 1;
    volatile int got = -1;
    volatile A2JITRegionProof res = A2JITRegionProofExecFaulted;
    if (sigsetjmp(gA2JITExecProbeEnv, 1) == 0) {
        int (*volatile fn)(void) = (int (*)(void))addr;
        got = fn();
        res = (got == A2JIT_PROBE_RETVAL) ? A2JITRegionProofRWXOK : A2JITRegionProofExecFaulted;
    }
    gA2JITExecProbeArmed = 0;
    sigaction(SIGBUS, &oldBus, NULL);
    sigaction(SIGSEGV, &oldSegv, NULL);
    if (res != A2JITRegionProofRWXOK) {
        a2_jit_log("[A2JIT] region @%p mprotect(RX) ok BUT executing our written instruction faulted "
                   "(ret=%d) -- page is NOT a real executable JIT mapping (would SIGBUS for JVM)", addr, got);
    }
    return (A2JITRegionProof)res;
}

// ============================================================================
// 匿名页执行式探针 —— 搬运自 utils.m L2648–L2694（AMEDeviceProbeJITExecCapability）。
//   ★这是「原生 JIT 真能力」的可信判据★：mprotect(PROT_EXEC) 成功 ≠ 该页真的可执行
//   （mprotect 只过权限这层；真正的判定在【取指】时由内核 + PPL/code-signing 复核）。
// ============================================================================
A2JITExecProbeResult a2_jit_exec_probe_anonymous(void) {
    size_t pg = (size_t)getpagesize();
    // 与 HotSpot code cache 同型的映射：匿名 + 私有 + 先 RW。
    void *p = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        a2_jit_log("[A2JIT] exec-probe: mmap(RW anon) failed: %s", strerror(errno));
        return A2JITExecProbeMprotectFailed;
    }
    memcpy(p, kA2JITProbeCode, sizeof(kA2JITProbeCode));
    sys_icache_invalidate(p, pg);   // arm64 上写代码后必须做
    if (mprotect(p, pg, PROT_READ | PROT_EXEC) != 0) {
        int e = errno;
        munmap(p, pg);
        a2_jit_log("[A2JIT] exec-probe: mprotect(RX) denied: %s -- no native JIT permission", strerror(e));
        return A2JITExecProbeMprotectFailed;
    }

    struct sigaction sa, oldBus, oldSegv;
    memset(&sa, 0, sizeof(sa));
    memset(&oldBus, 0, sizeof(oldBus));
    memset(&oldSegv, 0, sizeof(oldSegv));
    sa.sa_handler = a2_jit_exec_probe_handler;
    sa.sa_flags = SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS, &sa, &oldBus);
    sigaction(SIGSEGV, &sa, &oldSegv);

    gA2JITExecProbeArmed = 1;
    volatile int got = -1;
    volatile A2JITExecProbeResult res = A2JITExecProbeExecFaulted;
    if (sigsetjmp(gA2JITExecProbeEnv, 1) == 0) {
        int (*volatile fn)(void) = (int (*)(void))p;
        got = fn();
        res = (got == A2JIT_PROBE_RETVAL) ? A2JITExecProbeExecOK : A2JITExecProbeExecFaulted;
    } else {
        res = A2JITExecProbeExecFaulted;
    }
    gA2JITExecProbeArmed = 0;
    sigaction(SIGBUS, &oldBus, NULL);
    sigaction(SIGSEGV, &oldSegv, NULL);
    munmap(p, pg);

    if (res != A2JITExecProbeExecOK) {
        a2_jit_log("[A2JIT] exec-probe: mprotect(RX) returned 0 BUT executing the page faulted (ret=%d) "
                   "-- anonymous *permission* OK, real *execution* NOT (missing JIT entitlement / CS_DEBUGGED / "
                   "debugger-mapped RX). This is the KERN_PROTECTION_FAILURE/SIGBUS seen before.", got);
    }
    return (A2JITExecProbeResult)res;
}

// ============================================================================
// 可用性判据主体 —— 搬运自 utils.m L1438–L1863。
// ============================================================================

static void *gA2JITVerifiedRegion = NULL;
static BOOL   gA2JITVerified = NO;
static NSTimeInterval gA2JITLastVerifyAttempt = 0;
static int    gA2JITVerifyAttempts = 0;
static A2JITRegionVerdict gA2JITRegionVerdict = A2JITRegionVerdictUnknown;
static NSString *gA2JITRegionEvidence = nil;

// [JIT-HANG] 全局 in-flight 守卫：同一时刻只允许一发 brk 在途。
static os_unfair_lock gA2JITBrkLock = OS_UNFAIR_LOCK_INIT;
static volatile int   gA2JITBrkInFlight = 0;

// ★镜像/Universal 路径判据（DeviceNeedsDebugJITMapping 的等价实现）★
//   来源：utils.m L3075–L3080 的「能力判定」语义（去掉了对偏好/强制开关的依赖）。
//   iOS 26+ 上非 Java 8 的 VM 走 MirrorMappedCodeCache：code cache 的 RX 内存必须由
//   在场调试器经 brk #0x69 分配交付；不加这层判据会走普通 mmap(RW)+mprotect(RX)，
//   在无 dynamic-codesigning 的机器上取指保护失败 ⇒ StubRoutines::call_stub SIGBUS。
//   ★存疑★：原实现综合 iOS26 + FORCE_MIRRORED(TXM) 两个 flag；此处先用运行时主版本
//   判断，待 A2 环境检测（Core）回填后替换。
static BOOL a2_jit_device_needs_debug_mapping(void) {
    static int sInited = 0;
    static BOOL sNeeds = NO;
    if (!sInited) {
        NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
        sNeeds = (v.majorVersion >= 26);
        sInited = 1;
        a2_jit_log("[A2JIT] device_needs_debug_mapping = %d (iOS major=%ld)",
                   (int)sNeeds, (long)v.majorVersion);
    }
    return sNeeds;
}

// [JIT-HANG] 在后台线程发一发 brk #0x69，最多等 deadlineSec；返回区域指针或 NULL。
//   来源：utils.m L1532–L1579（ameJITBrk69Bounded）。原实现在发 brk 前会幂等下发
//   UniversalJIT26Extension.js（[JIT-ORDER]）——★本层不代发脚本★：脚本下发是上层
//   编排的职责（Player 步骤①，见 Air2/Player/A2LaunchChain.h），本层只负责探测。
static void *a2_jit_brk69_bounded(NSTimeInterval deadlineSec, const char *why) {
    const char *caller = [NSThread isMainThread] ? "main" : "bg";

    os_unfair_lock_lock(&gA2JITBrkLock);
    if (gA2JITBrkInFlight) {
        os_unfair_lock_unlock(&gA2JITBrkLock);
        a2_jit_log("[A2JIT] %s: a previous brk #0x69 is still in flight/hung -- refusing to stack "
                   "another (fast-fail, caller=%s)", why, caller);
        return NULL;
    }
    gA2JITBrkInFlight = 1;
    os_unfair_lock_unlock(&gA2JITBrkLock);

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block void *res = NULL;
    NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
    NSThread *worker = [[NSThread alloc] initWithBlock:^{
        res = a2_jit_brk69_create_region_safe((size_t)getpagesize());
        os_unfair_lock_lock(&gA2JITBrkLock);
        gA2JITBrkInFlight = 0;   // 已返回 ⇒ 允许下一发
        os_unfair_lock_unlock(&gA2JITBrkLock);
        dispatch_semaphore_signal(sem);
    }];
    worker.name = @"a2jit-brk69";
    worker.threadPriority = 0.9;
    [worker start];

    long wr = dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadlineSec * NSEC_PER_SEC)));
    NSTimeInterval elapsed = [NSDate date].timeIntervalSince1970 - t0;
    if (wr != 0) {
        // 超时 = 调试器端口在岗却不服务 ⇒ 放弃这一发（线程会一直卡在 brk 里，但不再拖住调用方）。
        a2_jit_log("[A2JIT] %s: brk #0x69 did NOT return within %.2fs (caller=%s) -- debugger exception "
                   "port attached but not servicing; treating JIT as NOT usable (stuck thread abandoned)",
                   why, deadlineSec, caller);
        return NULL;
    }
    a2_jit_log("[A2JIT] %s: brk #0x69 returned in %.3fs (caller=%s) -> %p",
               why, elapsed, caller, res);
    return res;
}

// 判定 brk 返回值的性质并（成功时）落 verified/verifiedRegion。
//   来源：utils.m L1649–L1758（ameJITVerifyRegionBounded）。
static BOOL a2_jit_verify_region_bounded(NSTimeInterval deadline, const char *why) {
    size_t len = (size_t)getpagesize();
    gA2JITVerifyAttempts++;
    void *r = a2_jit_brk69_bounded(deadline, why);   // 无人服务/超时返回 NULL 不致死
    if (r == NULL) {
        a2_jit_log("[A2JIT] false-positive guard triggered (#%d, why=%s): brk #0x69 NOT serviced -- "
                   "NOT counting JIT as enabled", gA2JITVerifyAttempts, why);
        gA2JITRegionEvidence = @"brk #0x69 未被服务（无调试器应答）—— 返回 NULL";
        gA2JITRegionVerdict = A2JITRegionVerdictNotServiced;
        return NO;
    }

    // ① 挡掉 legacy 通道的哨兵 / 显然垃圾的返回值。
    //    新版 Universal 脚本已废弃 legacy brk #0x69：应答 0xE0000069（“请指派 Universal JIT 脚本”）。
    //    寄存器回读形态实测为 0xcccccccc690000e0（高字节 0xCC 是半填充垃圾、低 32 位是哨兵字节序翻转）。
    uintptr_t rv = (uintptr_t)r;
    uint32_t rvLo = (uint32_t)(rv & 0xFFFFFFFFu);
    BOOL legacySentinel = (rv == 0x00000000E0000069ULL) ||
                          (rvLo == 0xE0000069u) ||
                          (rvLo == 0x690000E0u) ||
                          ((rv >> 56) == 0xCCu);
    if (legacySentinel) {
        a2_jit_log("[A2JIT] brk #0x69 returned the LEGACY-SCRIPT sentinel %p (0xE0000069 = "
                   "'legacy script removed -- assign the Universal JIT script') -- NOT a region; NOT usable", r);
        gA2JITRegionEvidence = [NSString stringWithFormat:
            @"brk #0x69 返回 legacy 哨兵值 %p（0xE0000069=“legacy 脚本已废弃，请改用/指派 Universal JIT 脚本”）—— 不是有效区域", r];
        gA2JITRegionVerdict = A2JITRegionVerdictLegacySentinel;
        return NO;
    }

    // ② vm_region_64：读真实映射与 page 保护。
    unsigned int cur = 0, maxp = 0;
    unsigned long long rsz = 0;
    BOOL mapped = (a2_jit_query_region_prot(r, len, &cur, &maxp, &rsz) == 0);
    BOOL w = mapped && (((cur & VM_PROT_WRITE) != 0) || ((maxp & VM_PROT_WRITE) != 0));
    BOOL x = mapped && (((cur & VM_PROT_EXECUTE) != 0) || ((maxp & VM_PROT_EXECUTE) != 0));
    a2_jit_log("[A2JIT] brk #0x69 region @%p: mapped=%d cur=0x%x max=0x%x size=%llu => writable=%d executable=%d (why=%s)",
               r, mapped, cur, maxp, rsz, w, x, why);
    if (!mapped) {
        a2_jit_log("[A2JIT] NOT usable: brk #0x69 返回的地址在进程内【无映射】—— JVM 的 code cache 拿不到内存");
        gA2JITRegionEvidence = [NSString stringWithFormat:
            @"brk #0x69 返回地址 %p 在进程内无映射（vm_region_64 失败）—— 不是有效 JIT 区", r];
        gA2JITRegionVerdict = A2JITRegionVerdictNoMapping;
        return NO;
    }

    // ③ 判定依据：region 属性即判据；write+exec 自证降为【只作日志】。
    //    真机实证（2026-10-07，见 _RT_P0_2.md）：用 AmethystJIT69.js 后调试器已交付【真 JIT 区】
    //    （mapped=1 cur=0x5 max=0x7 size=16384），可直接作 JVM 的 code cache。而自证常报
    //    proof=5(inconclusive)：先 mprotect(RW) 再 mprotect(RX) 会撤销 iOS26+ 对调试器交付页的
    //    「可执行祝福」⇒ 第二步失败。这是**自证手法自身的局限**，不是「区域不可用」。
    //    ★判定：非哨兵 + mapped=1 + size>0 + max 含 X ⇒ usable★；真正不可用仅限
    //    未映射 / 哨兵 / max 无 X / size=0。
    BOOL maxHasW = (maxp & VM_PROT_WRITE)   != 0;
    BOOL maxHasX = (maxp & VM_PROT_EXECUTE) != 0;
    if (rsz == 0) {
        a2_jit_log("[A2JIT] NOT usable: region @%p size=0（无有效长度）", r);
        gA2JITRegionEvidence = [NSString stringWithFormat:
            @"brk #0x69 返回区域 %p 的 size=0 —— 不是有效 JIT 区", r];
        gA2JITRegionVerdict = A2JITRegionVerdictZeroSize;
        return NO;
    }
    if (!maxHasX) {
        a2_jit_log("[A2JIT] NOT usable: region @%p max=0x%x 不含 EXECUTE（该页永远不可执行）", r, maxp);
        gA2JITRegionEvidence = [NSString stringWithFormat:
            @"brk #0x69 返回区域 %p max=0x%x 不含可执行位（max 无 X）—— 不是有效 JIT 区", r, maxp];
        gA2JITRegionVerdict = A2JITRegionVerdictNotExecutable;
        return NO;
    }

    // 轻量自证（best-effort）—— ★只作日志，任何结果都【不否决】判定★。
    int mr = -999, mErrno = 0;
    A2JITRegionProof proof = a2_jit_prove_region_rwx(r, len, &mr, &mErrno);
    a2_jit_log("[A2JIT] region @%p write+exec self-proof (ADVISORY ONLY): mprotect(RW)=%d errno=%d(%s) "
               "proof=%ld (1=RWX-OK 2=not-writable 3=exec-faulted 4=unmapped 5=inconclusive) "
               "-- proof=5 属自证局限，不得当失败",
               r, mr, mErrno, strerror(mErrno), (long)proof);
    if (proof == A2JITRegionProofInconclusive) {
        a2_jit_log("[A2JIT] self-proof INCONCLUSIVE —— 多为 iOS26+ 的 RW→RX 撤销了调试器对该页的可执行祝福"
                   "（详见上面 mprotect(RX) errno）。★仅日志，不改判定★");
    }
    // 尽力恢复【原】保护视图（本区仅用于诊断；JVM 用自己的 brk 请求另一块区）。
    unsigned int restore = cur & (VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (restore == 0) restore = VM_PROT_READ | VM_PROT_EXECUTE;
    mprotect(r, len, (int)restore);

    const char *maxStr = (maxHasW && maxHasX) ? "RWX" : (maxHasX ? "RX" : "R");
    a2_jit_log("[A2JIT] verdict=usable(max=%s,mapped=%d,size=%llu,proof=%ld) -- 非哨兵+已映射+size>0+max含X",
               maxStr, mapped, rsz, (long)proof);
    gA2JITVerifiedRegion = r;   // 留驻（只一页），供后续复用/诊断
    gA2JITVerified = YES;
    gA2JITRegionVerdict = A2JITRegionVerdictUsable;
    a2_jit_log("[A2JIT] verified: JIT region @%p (%zu bytes) usable as JVM code cache "
               "(cur=0x%x max=0x%x max含W=%d max含X=%d 自证proof=%ld 仅参考; why=%s)",
               r, len, cur, maxp, maxHasW, maxHasX, (long)proof, why);
    gA2JITRegionEvidence = [NSString stringWithFormat:
        @"已验证可用 [addr=%p mapped=1 cur=0x%x max=0x%x size=%llu max含W=%d max含X=%d 自证proof=%ld(仅参考)]",
        r, cur, maxp, rsz, maxHasW, maxHasX, (long)proof];
    return YES;
}

// ★[JIT-P0.1] 后台有界探测（不阻塞调用方；启动器入口用）。
static os_unfair_lock gA2JITEnsureKickLock = OS_UNFAIR_LOCK_INIT;
static int gA2JITEnsureKickInflight = 0;

@implementation A2JITEnvironment

+ (BOOL)verifyWritableRegion {
    if (gA2JITVerified) {
        return YES;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (gA2JITLastVerifyAttempt > 0 && (now - gA2JITLastVerifyAttempt) < 2.0) {
        return NO;   // 限流：等待循环里每轮都会调到这个函数
    }
    gA2JITLastVerifyAttempt = now;

    NSTimeInterval deadline = [NSThread isMainThread] ? 1.5 : 3.0;   // [JIT-HANG]
    return a2_jit_verify_region_bounded(deadline, "A2JITEnvironment.verifyWritableRegion");
}

+ (BOOL)ensureVerifiedWithinBudget:(NSTimeInterval)budget reason:(NSString **)whyOut {
    if (gA2JITVerified) {
        if (whyOut) *whyOut = gA2JITRegionEvidence ?: @"already verified (verifiedRegion non-null)";
        return YES;
    }

    // 非镜像路径：JVM 直接执行自产代码 ⇒ 唯一可信判据 = 匿名页执行式探针真跑过。
    if (!a2_jit_device_needs_debug_mapping()) {
        A2JITExecProbeResult pr = a2_jit_exec_probe_anonymous();
        BOOL ok = (pr == A2JITExecProbeExecOK);
        if (whyOut) *whyOut = ok ? @"exec-probe(map+write+exec+readback) OK"
                                 : @"exec-probe FAILED (declared capability is NOT usable right now)";
        return ok;
    }

    // 镜像/Universal：JIT 只能由在场调试器代映射 ⇒ 真的发一发有界 brk #0x69。
    if (budget <= 0) budget = 1.0;
    if ([NSThread isMainThread]) {
        // UI 纪律：默认路径不在主线程；万一被主线程调到，收紧预算并同时后台补发一发。
        [self kickBackgroundVerify];
        if (budget > 1.0) budget = 1.0;
    }

    NSDate *t0 = [NSDate date];
    for (;;) {
        if (gA2JITVerified) {
            if (whyOut) *whyOut = gA2JITRegionEvidence ?: @"verified JIT region (brk #0x69 serviced)";
            return YES;
        }
        NSTimeInterval remaining = budget + [t0 timeIntervalSinceNow];   // 过去为负
        if (remaining <= 0) break;
        // 上一发 brk 仍在途（例如入口发起的后台探测）⇒ 等它落地再判，绝不叠加。
        if (gA2JITBrkInFlight) {
            usleep(50 * 1000);
            continue;
        }
        NSTimeInterval slice = remaining < 3.0 ? remaining : 3.0;
        if (a2_jit_verify_region_bounded(slice, "A2JITEnvironment.ensureVerifiedWithinBudget")) {
            if (whyOut) *whyOut = gA2JITRegionEvidence ?: @"verified JIT region (brk #0x69 serviced)";
            return YES;
        }
        break;   // brk 明确未被服务 ⇒ 不再叠加（避免多个卡死的 brk 线程）
    }
    if (whyOut) *whyOut = gA2JITRegionEvidence ?: @"brk #0x69 NOT serviced within budget -- JIT not verified";
    a2_jit_log("[A2JIT] ensureVerifiedWithinBudget: NOT verified within %.2fs budget (mirror=%d) -- JVM creation will be blocked",
               -[t0 timeIntervalSinceNow], a2_jit_device_needs_debug_mapping());
    return NO;
}

+ (void)kickBackgroundVerify {
    if (gA2JITVerified) return;
    os_unfair_lock_lock(&gA2JITEnsureKickLock);
    if (gA2JITEnsureKickInflight) { os_unfair_lock_unlock(&gA2JITEnsureKickLock); return; }
    gA2JITEnsureKickInflight = 1;
    os_unfair_lock_unlock(&gA2JITEnsureKickLock);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        (void)[A2JITEnvironment ensureVerifiedWithinBudget:3.0 reason:NULL];
        os_unfair_lock_lock(&gA2JITEnsureKickLock);
        gA2JITEnsureKickInflight = 0;
        os_unfair_lock_unlock(&gA2JITEnsureKickLock);
    });
}

+ (BOOL)waitReadyVerified {
    if (!a2_jit_device_needs_debug_mapping()) {
        return (a2_jit_exec_probe_anonymous() == A2JITExecProbeExecOK);
    }
    return [self verifyWritableRegion];
}

+ (void *)verifiedRegion {
    return gA2JITVerifiedRegion;
}

+ (NSString *)regionEvidence {
    return gA2JITRegionEvidence;
}

+ (A2JITRegionVerdict)lastRegionVerdict {
    return gA2JITRegionVerdict;
}

+ (void)invalidateCache {
    gA2JITVerified = NO;
    gA2JITVerifiedRegion = NULL;
    gA2JITLastVerifyAttempt = 0;
    gA2JITRegionVerdict = A2JITRegionVerdictUnknown;
    a2_jit_log("[A2JIT] usability cache invalidated (JIT toggled / returned to foreground)");
}

@end
