//
//  A2LegacyJITGate.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— 老 Air（tree510）JIT 判定 / 闰门：逐段原样移植。
//  每段顶部标来源行号；★逻辑、顺序、日志文案与原实现一致★，只把符号名加 A2 前缀。
//
//  依赖说明（Air2 侧已存在的等价件，不重复实现）：
//    · 裸 `brk #0x69` 叶子 + SIGTRAP 安全网 + `brk #0xf00d` cmd=2/3
//      = Natives/Support/A2JITEnvironment.m 的
//        a2_jit_brk69_create_region_safe / a2_jit_send_script_safe /
//        a2_jit_set_detach_after_first_br（它们本身就是 tree510 utils.m L752–L948 的移植）。
//      ⇒ 这里直接转调，避免在同一进程里布第二套 SIGTRAP 窗口（两套网会互相接管）。
//    · 是否镜像设备 = A2JITEnvironment.needsDebuggerMapping（tree510 DeviceNeedsDebugJITMapping 的等价物）。
//
//  ★本单补齐的最后一段（④' 段）★：老 Air 拿到 Universal 基础脚本的握手哨兵
//  `0xE0000069`（寄存器回读形态 `0xcccccccc690000e0`）后下发 Extension 就建 VM——
//  真区在那之后才由 libjvm 自己发 brk #0x69 取得。Air2 把「真区到手」也验掉：
//  哨兵 ⇒ 下发 Extension ⇒ 有界重试 brk #0x69 ⇒ ★只认真区（size≥期望 且 可写）才放行★。
//

#import "A2LegacyJITGate.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <sys/mman.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>

#import "A2JITEnvironment.h"   // a2_jit_log / 安全网 brk 原语 / needsDebuggerMapping / 执行式探针
#import "a2_log.h"             // 判据行出口（与 A2Log criterion 同一落点）

// tree510 utils.h L182：`#define CS_DEBUGGED 0x10000000`
//   ★注意★ 内核 cs_blobs.h 里 CS_HARD 是 0x100、CS_DEBUGGED 才是 0x10000000。
//   Air2 旧代码（A2JITEnvironment.m）用的是 0x100 —— 那是 CS_HARD，判据因此恒错。
//   本移植按老 Air 的原值。
#ifndef A2CS_DEBUGGED
#define A2CS_DEBUGGED 0x10000000
#endif

// tree510 utils.m L1359–L1361：iOS SDK 不暴露 <sys/proc.h> 的 P_TRACED，自带常量。
#ifndef P_TRACED
#define P_TRACED 0x00000800 /* process is being traced by a debugger (ptrace) */
#endif

// csops 原型（tree510 utils.h L184）。内核私有调用，符号在 libsystem_kernel。
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

// ============================================================================
// ① tree510 utils.m L40–L81：getEntitlementValue
//   SecTask.h 只在 macOS SDK 提供 ⇒ 照老 Air 的做法自带原型（iOS 上符号可链接）。
// ============================================================================
extern CFTypeRef SecTaskCopyValueForEntitlement(void *task, NSString *entitlement,
                                                CFErrorRef _Nullable *error);
extern void *SecTaskCreateFromSelf(CFAllocatorRef allocator);

BOOL A2JITGetEntitlementValue(NSString *key) {
    // 本函数修两个缺陷（原实现见老 Air git 历史）：
    //  (1) use-after-free：先 CFRelease(value) 再对同一个 value 发 isKindOfClass:/
    //      boolValue ⇒ 悬垂读。改为先算后放。
    //  (2) 恒真口径：任何非 NSNumber 值（含字符串）一律当 YES。字符串改为按真值判定。
    void *secTask = SecTaskCreateFromSelf(NULL);
    if (secTask == NULL) {
        return NO;
    }
    // 只创建一次 SecTask，并以它做查询。
    CFTypeRef value = SecTaskCopyValueForEntitlement(secTask, key, nil);
    CFRelease(secTask);
    if (value == nil) {
        return NO;
    }
    BOOL result = NO;
    id obj = (__bridge id)value;
    if ([obj isKindOfClass:NSNumber.class]) {
        result = [obj boolValue];
    } else if ([obj isKindOfClass:NSString.class]) {
        NSString *s = [(NSString *)obj lowercaseString];
        result = (s.length > 0) &&
                 ![s isEqualToString:@"false"] &&
                 ![s isEqualToString:@"0"] &&
                 ![s isEqualToString:@"no"];
    } else {
        // 其余非空非布尔值（数组/字典/日期…）保持旧口径：视为已授予。
        result = YES;
    }
    CFRelease(value);
    return result;
}

// ============================================================================
// ② tree510 utils.m L279–L294：isJITEnabled
// ============================================================================
BOOL A2JITIsEnabled(BOOL checkCSFlags) {
    // 收紧 JIT 判据：JIT 能力只认**真实证据**（dynamic-codesigning entitlement /
    //   CS_DEBUGGED）。越狱【不等于】本 App 被授予 JIT。
    if (!checkCSFlags && A2JITGetEntitlementValue(@"dynamic-codesigning")) {
        return YES;
    }

    int flags = 0;
    csops(getpid(), 0, &flags, (size_t)sizeof(flags));
    return (flags & A2CS_DEBUGGED) != 0;
}

// ============================================================================
// ③ tree510 utils.m L1359–L1417：调试器存活三探针
// ============================================================================

// 向内核查询当前进程是否存在活的 ptrace 关系。P_TRACED 在调试器附加的
// 整个生命周期内置位、脱离瞬间清零，是"调试器还在"的准确信号。
BOOL A2JIT26DebuggerAttachedViaPtrace(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return NO;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// 检测通过 Mach 异常端口持有本任务的调试器。lldb/debugserver 以
// ptrace(PT_ATTACH) 拿到任务端口后 PT_DETACH 但保留端口——此后 P_TRACED
// 为 0 而调试器完全存活、持续服务 EXC_BREAKPOINT（JIT26 的 brk #0x69 /
// brk #0xf00d 正是这样被服务的）。任务级 BREAKPOINT/SOFTWARE 非空
// handler 即"JIT26 调试器就位"的可靠信号。
BOOL A2JIT26DebuggerViaExceptionPorts(void) {
    exception_mask_t masks[EXC_TYPES_COUNT];
    exception_handler_t handlers[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    kern_return_t kr = task_get_exception_ports(mach_task_self(),
                                                EXC_MASK_BREAKPOINT | EXC_MASK_SOFTWARE,
                                                masks, &count, handlers, behaviors, flavors);
    if (kr != KERN_SUCCESS) {
        return NO;
    }
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (handlers[i] != MACH_PORT_NULL) {
            return YES;
        }
    }
    return NO;
}

BOOL A2JIT26IsLikelyDebuggerKeepAttached(void) {
    // 调试器 spawn 的进程 ppid != 1（launchd 为 1）。
    if (getppid() != 1) {
        return YES;
    }
    // StikJIT/SideJIT 对已运行进程按 pid 附加，ppid 恒为 1；且启用工具可能
    // 退出导致进程被重挂到 launchd（ppid 回 1）而 CS_DEBUGGED 残留——单看
    // ppid 会把完全可用的会话误判为"无调试器"。回退到活的 ptrace 标志。
    if (A2JIT26DebuggerAttachedViaPtrace()) {
        return YES;
    }
    // lldb/debugserver PT_DETACH 后 P_TRACED 回 0，但仍通过任务级异常端口
    // 服务 EXC_BREAKPOINT。把活的任务级 BREAKPOINT/SOFTWARE handler 视为
    // "调试器在岗"——它正是必须服务 brk #0x69 的实体。
    return A2JIT26DebuggerViaExceptionPorts();
}

// ============================================================================
// ④' Air2 增补：★哨兵识别 → 下发 Extension → 有界重试到真区★
// ----------------------------------------------------------------------------
//  为什么需要这一段（真机证据 lastlog-64）：
//    `[JIT-FLOW] verified: debugger serviced brk #0x69 -> JIT region
//     @0xcccccccc690000e0 (16384 bytes, writable=0)`
//  ⇒ 那个地址 / 16KB / 不可写 **不是 JIT 区**，是 Universal 基础脚本的**握手哨兵**：
//    `JIT26HandleBrk0x69` 把 x0 写成 0xE0000069（并要求调用方自己装
//    `legacyCommands[0x69]` 处理器），寄存器回读字节序翻转 = 0x690000E0，
//    高位 0xCC 是半填充垃圾。老 Air 把这当「可以下发 Extension 了」的信号，
//    ★不是★「JIT 已就绪」。Air2 之前把它当成功放行 ⇒ 没区却建 VM ⇒ 首帧 SIGBUS。
//
//  这一段把顺序固化成四步（老 Air 的握手 + Air2 的有界重试）：
//    ① 分类：哨兵 / 无映射 / 太小 / 只读 / 真区（判据见 a2gate_classify）；
//    ② 哨兵 ⇒ 下发 UniversalJIT26Extension.js（把 legacyCommands[0x69] 换成真建区）；
//    ③ 重试 brk #0x69（有界：A2GATE_RETRY_ATTEMPTS 次 × A2GATE_RETRY_INTERVAL_S 秒）；
//    ④ 只认「真区」= 非哨兵 + vm_region 有映射 + size ≥ 期望(A2JITRegionMB，默认 64MB)
//       + 可写（cur/max 含 VM_PROT_WRITE）。
//
//  ★不用 mprotect 自证可写★：真机证据（A2JITEnvironment.m ③ 的注释 / _RT_P0_2.md）——
//  对调试器交付的 JIT 页做 mprotect(RW)→mprotect(RX) 会撤掉 iOS 26+ 给它的
//  「可执行祝福」，等于把一块可用区做成废区。可写性只从 vm_region_64 的
//  当前/最大保护位读（实测真区 cur=0x5 max=0x7 ⇒ max 含 W）。
// ============================================================================

/// Universal 基础脚本 `P0=E0000069` 的寄存器回读形态低 32 位。
#define A2GATE_SENTINEL_LO          0x690000E0u
/// 同一哨兵的另一种字节序（脚本写进去的字面量）。
#define A2GATE_SENTINEL_LO_SWAPPED  0xE0000069u
/// 哨兵的地址高位（寄存器半填充垃圾：0xcccccccc690000e0）。
#define A2GATE_SENTINEL_HI          0xccccccccu
/// 「小到不可能是 code cache」的阈值：一页 = 16KB（arm64）。
#define A2GATE_SENTINEL_MAX_BYTES   16384ull
/// 有界重试：次数与间隔（老 Air 只在建 VM 前发一发；这里补上有界重试）。
#define A2GATE_RETRY_ATTEMPTS       3
#define A2GATE_RETRY_INTERVAL_S     2.0
/// 等待循环里的限流：两次「取区」尝试至少间隔（秒）。
#define A2GATE_REOBTAIN_THROTTLE_S  2.0

typedef NS_ENUM(NSInteger, A2GateRegionKind) {
    A2GateRegionKindNone      = 0,  ///< 没应答（NULL）：调试器不在岗或 Extension 未交付
    A2GateRegionKindSentinel  = 1,  ///< 握手哨兵（0x690000E0 / 0xcccccccc… / 小页且不可写）
    A2GateRegionKindUnmapped  = 2,  ///< 非哨兵但进程内无映射（垃圾返回值）
    A2GateRegionKindTooSmall  = 3,  ///< 真映射，但 size < 期望（不够当 code cache）
    A2GateRegionKindReadOnly  = 4,  ///< 真映射且够大，但没有任何写权限
    A2GateRegionKindReal      = 5,  ///< ★真区★：非哨兵 + 有映射 + size≥期望 + 可写
};

/// 一次 brk #0x69 返回值的完整取证（日志与判定都用它）。
typedef struct {
    void *addr;
    size_t wantBytes;
    unsigned long long vmSize;
    unsigned int cur;
    unsigned int max;
    BOOL mapped;
    BOOL writable;
    BOOL executable;
    const char *rule;   ///< 命中的判据短语（日志用，静态字符串）
} A2GateRegionInfo;

/// tree510 JIT26CreateRegionLegacySafe 的 expected 口径
/// （= A2JITEnvironment.expectedRegionBytes：偏好键 `A2JITRegionMB` 覆盖，未设 ⇒ 64MB）。
static size_t a2gate_want_bytes(void) {
    size_t want = [A2JITEnvironment expectedRegionBytes];
    if (want == 0) {
        want = 64u * 1024u * 1024u;
    }
    return want;
}

/// ★分类★：把 brk #0x69 的返回值判成 6 档之一。纯只读（vm_region_64），无副作用。
static A2GateRegionKind a2gate_classify(void *r, size_t want, A2GateRegionInfo *info) {
    A2GateRegionInfo local;
    if (info == NULL) info = &local;
    memset(info, 0, sizeof(*info));
    info->addr = r;
    info->wantBytes = want;
    info->rule = "";

    if (r == NULL) {
        info->rule = "没应答（NULL）";
        return A2GateRegionKindNone;
    }

    // ① 地址签名哨兵：0xcccccccc690000e0 / …690000E0 / …E0000069。
    uintptr_t v = (uintptr_t)r;
    uint32_t lo = (uint32_t)(v & 0xFFFFFFFFu);
    uint32_t hi = (uint32_t)((v >> 32) & 0xFFFFFFFFu);
    if (hi == A2GATE_SENTINEL_HI || lo == A2GATE_SENTINEL_LO ||
        lo == A2GATE_SENTINEL_LO_SWAPPED) {
        info->rule = "地址签名（0xcccccccc…/0x690000E0/0xE0000069）";
        return A2GateRegionKindSentinel;
    }

    // ② 真映射与保护位：vm_region_64 只读查询。
    size_t pageLen = (size_t)getpagesize();
    unsigned int cur = 0, maxp = 0;
    unsigned long long sz = 0;
    BOOL mapped = (a2_jit_query_region_prot(r, pageLen, &cur, &maxp, &sz) == 0);
    info->mapped = mapped;
    info->cur = cur;
    info->max = maxp;
    info->vmSize = mapped ? sz : 0;
    info->writable = mapped && (((cur | maxp) & VM_PROT_WRITE) != 0);
    info->executable = mapped && (((cur | maxp) & VM_PROT_EXECUTE) != 0);
    if (!mapped) {
        info->rule = "进程内无映射（vm_region_64 失败）";
        return A2GateRegionKindUnmapped;
    }

    // ③ 小且不可写 ⇒ 与哨兵同性质（一页占位、根本不能当 code cache）。
    if (info->vmSize <= A2GATE_SENTINEL_MAX_BYTES && !info->writable) {
        info->rule = "size<=16KB 且不可写";
        return A2GateRegionKindSentinel;
    }
    // ④ 够大才可能是 code cache。
    if (info->vmSize < (unsigned long long)want) {
        info->rule = "size < 期望";
        return A2GateRegionKindTooSmall;
    }
    if (!info->writable) {
        info->rule = "够大但无写权限";
        return A2GateRegionKindReadOnly;
    }
    info->rule = "真区（size≥期望 且 可写）";
    return A2GateRegionKindReal;
}

/// 分类档位的中文名（日志用；三种关键状态各自一眼可辨）。
static NSString *a2gate_kind_name(A2GateRegionKind k) {
    switch (k) {
        case A2GateRegionKindNone:     return @"无应答";
        case A2GateRegionKindSentinel: return @"握手哨兵";
        case A2GateRegionKindUnmapped: return @"垃圾返回（无映射）";
        case A2GateRegionKindTooSmall: return @"太小";
        case A2GateRegionKindReadOnly: return @"只读";
        case A2GateRegionKindReal:     return @"★真区★";
    }
    return @"未知";
}

/// Extension 脚本：老 Air 的脚本名是 UniversalJIT26Extension.js；Air2 随包的资源名是
/// Air2JIT69Ext.js（同一份内容，见 Assets/）。两个都认，免得包内改名后静默发不出去。
static NSString *a2gate_extension_script(void) {
    static NSString *sCached = nil;
    static BOOL sLooked = NO;
    if (sLooked) return sCached;
    sLooked = YES;
    NSArray<NSString *> *names = @[@"UniversalJIT26Extension", @"Air2JIT69Ext"];
    for (NSString *name in names) {
        NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"js"];
        if (path.length == 0) continue;
        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        if (text.length > 0) {
            sCached = text;
            a2_log_criterion(@"[JIT-FLOW] Extension script found in bundle: %@（%lu 字节）",
                             path.lastPathComponent, (unsigned long)text.length);
            return sCached;
        }
    }
    a2_log_criterion(@"[JIT-FLOW] Extension script MISSING in bundle（找过 UniversalJIT26Extension.js / "
                     @"Air2JIT69Ext.js）⇒ 无法把 legacyCommands[0x69] 换成真建区");
    return nil;
}

/// 下发 Extension（brk #0xf00d cmd=2）。
/// ★成功才永久缓存★：失败必须允许下次再试 —— 调试器可能是在本进程跑起来之后才 attach 的
/// （用户去 StikDebug 开 JIT 再回来），一次失败定终身会让「装好 JIT 也永远拿不到真区」。
/// 频率由调用方的限流兜底（等待循环 2s 一轮），不会打爆调试器。
static BOOL a2gate_deliver_extension(void) {
    static BOOL sDelivered = NO;
    if (sDelivered) return YES;

    NSString *script = a2gate_extension_script();
    if (script.length == 0) {
        a2_log_criterion(@"[JIT-FLOW] Extension NOT delivered: 包里没有脚本 ⇒ 无法把 "
                         @"legacyCommands[0x69] 换成真建区（哨兵会一直回）");
        return NO;
    }
    BOOL ok = a2_jit_send_script_safe(script.UTF8String, script.length);
    sDelivered = ok;
    if (ok) {
        a2_log_criterion(@"[JIT-FLOW] Extension delivered（brk #0xf00d cmd=2，%lu 字节）⇒ "
                         @"legacyCommands[0x69] 已换成真建区", (unsigned long)script.length);
    } else {
        a2_log_criterion(@"[JIT-FLOW] Extension NOT delivered（brk #0xf00d 未被服务）⇒ "
                         @"legacyCommands[0x69] 仍是回哨兵；下一轮会再试（调试器可能还没就位）");
    }
    return ok;
}

/// 真区缓存：一旦确认就留驻复用（每次重发 brk 都是几十 MB 的分配）。
static void *gA2GateRealRegion = NULL;
static size_t gA2GateRealRegionBytes = 0;
static NSTimeInterval gA2GateLastObtainAttempt = 0;
static int gA2GateObtainAttempts = 0;
/// 本进程是否曾见过握手哨兵（复用真区时仍要如实回答「见没见过」）。
static BOOL gA2GateSawSentinel = NO;

/// ★取真区★：唯一入口。返回最终分类；info 回填取证；sawSentinel/extDelivered 回填过程事实。
///   throttle=YES ⇒ 等待循环用（两次尝试至少间隔 A2GATE_REOBTAIN_THROTTLE_S，防每 0.5s 打一发 brk）；
///   throttle=NO  ⇒ 建 VM 前的一次性闰门用（绝不因为限流而误拦）。
///   attempts=2 且 interval=0 ⇒ 「Extension 刚装好就立刻再探一发」（哨兵 → 真区的常见路径）；
///   attempts=3 且 interval=2 ⇒ 建 VM 前的有界重试（本单要求）。
static A2GateRegionKind a2gate_obtain_real_region(size_t want,
                                                  int attempts,
                                                  NSTimeInterval interval,
                                                  BOOL throttle,
                                                  A2GateRegionInfo *info,
                                                  BOOL *sawSentinelOut,
                                                  BOOL *extDeliveredOut) {
    if (sawSentinelOut) *sawSentinelOut = NO;
    if (extDeliveredOut) *extDeliveredOut = NO;
    if (attempts < 1) attempts = 1;

    // ⓪ 复用：已确认的真区只要还在映射里就直接用，不再发 brk。
    if (gA2GateRealRegion != NULL) {
        A2GateRegionInfo cached;
        if (a2gate_classify(gA2GateRealRegion, want, &cached) == A2GateRegionKindReal) {
            if (info) *info = cached;
            // 「见没见过哨兵」如实回答；Extension 是否已下发由 a2gate_deliver_extension 自己记账
            // （调用方若需要仍会问到它，已下发则直接回 YES，不会重复发）。
            if (sawSentinelOut) *sawSentinelOut = gA2GateSawSentinel;
            if (extDeliveredOut) *extDeliveredOut = NO;
            a2_jit_log("[A2JIT] 复用已确认的真区 %p（size=%llu ≥ want=%zu，不再重发 brk #0x69）",
                       gA2GateRealRegion, cached.vmSize, want);
            return A2GateRegionKindReal;
        }
        a2_jit_log("[A2JIT] 缓存的真区 %p 已失效（%s）⇒ 重新取", gA2GateRealRegion, cached.rule);
        gA2GateRealRegion = NULL;
        gA2GateRealRegionBytes = 0;
    }

    // ① 限流：等待循环 0.5s 一轮，不限流会每轮发一发 brk。
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (throttle && gA2GateLastObtainAttempt > 0 &&
        (now - gA2GateLastObtainAttempt) < A2GATE_REOBTAIN_THROTTLE_S) {
        if (info) {
            memset(info, 0, sizeof(*info));
            info->wantBytes = want;
            info->rule = "限流中（距上次取区不足 2s）";
        }
        return A2GateRegionKindNone;
    }
    gA2GateLastObtainAttempt = now;
    gA2GateObtainAttempts++;

    A2GateRegionInfo cur;
    memset(&cur, 0, sizeof(cur));
    cur.wantBytes = want;
    cur.rule = "未探测";
    A2GateRegionKind kind = A2GateRegionKindNone;
    BOOL sawSentinel = NO;
    BOOL extensionTried = NO;

    for (int i = 0; i < attempts; i++) {
        if (i > 0 && interval > 0) {
            [NSThread sleepForTimeInterval:interval];   // 有界重试的间隔
        }
        // ← tree510 JIT26CreateRegionLegacySafe(len)：brk #0x69；无人服务返回 NULL 不致死。
        void *r = a2_jit_brk69_create_region_safe(want);
        kind = a2gate_classify(r, want, &cur);

        // ★三种关键状态各打一行，真机 grep 一眼可辨★
        if (kind == A2GateRegionKindReal) {
            a2_log_criterion(@"[JIT-FLOW] ★真区★ confirmed: brk #0x69 -> %p (size=%llu bytes ≥ 期望=%zu, "
                             @"cur=0x%x max=0x%x writable=%d executable=%d) -- real JIT region"
                             @"（第 %d/%d 发，先见过哨兵=%d）",
                             r, cur.vmSize, want, cur.cur, cur.max,
                             (int)cur.writable, (int)cur.executable, i + 1, attempts, (int)sawSentinel);
            gA2GateRealRegion = r;
            gA2GateRealRegionBytes = (size_t)cur.vmSize;
            if (info) *info = cur;
            if (sawSentinelOut) *sawSentinelOut = sawSentinel;
            if (extDeliveredOut) *extDeliveredOut = extensionTried;
            return A2GateRegionKindReal;
        }
        if (kind == A2GateRegionKindSentinel) {
            sawSentinel = YES;
            gA2GateSawSentinel = YES;
            a2_log_criterion(@"[JIT-FLOW] 哨兵 handshake detected（第 %d/%d 发）: brk #0x69 -> %p "
                             @"(size=%llu cur=0x%x max=0x%x writable=%d, 判据=%s) "
                             @"⇒ 这是 Universal 基础脚本的握手哨兵，★不是 JIT 区★",
                             i + 1, attempts, r, cur.vmSize, cur.cur, cur.max,
                             (int)cur.writable, cur.rule);
        } else if (kind == A2GateRegionKindNone) {
            a2_log_criterion(@"[JIT-FLOW] brk #0x69 无应答（第 %d/%d 发）: NULL "
                             @"(调试器在岗=%d traced=%d exn=%d) —— 本进程没有拿到区",
                             i + 1, attempts,
                             (int)A2JIT26IsLikelyDebuggerKeepAttached(),
                             (int)A2JIT26DebuggerAttachedViaPtrace(),
                             (int)A2JIT26DebuggerViaExceptionPorts());
        } else {
            a2_log_criterion(@"[JIT-FLOW] 非真区（第 %d/%d 发）: brk #0x69 -> %p "
                             @"(size=%llu 期望=%zu cur=0x%x max=0x%x writable=%d, 判据=%s)",
                             i + 1, attempts, r, cur.vmSize, want, cur.cur, cur.max,
                             (int)cur.writable, cur.rule);
        }

        // ② 哨兵 / 非真区 ⇒ 下发 Extension（把 legacyCommands[0x69] 换成真建区），
        //    下一个 brk 才会由调试器真建区并回真地址。★只发一次★。
        //    NULL（无人应答）时不下发：cmd=2 走的也是 brk #0xf00d，没人服务只会再失败一次。
        if (!extensionTried && kind != A2GateRegionKindNone) {
            extensionTried = YES;
            if (a2gate_deliver_extension()) {
                a2_log_criterion(@"[JIT-FLOW] Extension 已下发 ⇒ 立刻重试 brk #0x69"
                                 @"（期望拿到 size≥%zu 且可写的真区）", want);
            }
        }
    }

    // ③ 重试用尽仍是哨兵/小页/无应答 ⇒ 未就绪（调用方不得建 VM）。
    if (info) *info = cur;
    if (sawSentinelOut) *sawSentinelOut = sawSentinel;
    if (extDeliveredOut) *extDeliveredOut = extensionTried;
    a2_log_criterion(@"[JIT-FLOW] 重试 %d 次后仍未拿到真区：最后一发=%s（%s）⇒ ★JIT 未就绪★"
                     @"（本进程第 %d 次取区）",
                     attempts, a2gate_kind_name(kind).UTF8String, cur.rule, gA2GateObtainAttempts);
    return kind;
}

// ============================================================================
// ④ tree510 utils.m L1437–L1497：真能力判据（★判据改为「真区」，见 ④' 段★）
// ============================================================================
static void *gA2AmeJITVerifiedRegion = NULL;
static BOOL   gA2AmeJITVerified = NO;
static NSTimeInterval gA2AmeJITLastVerifyAttempt = 0;
static int    gA2AmeJITVerifyAttempts = 0;

// 向调试器讨一块 JIT 区并★验收它是不是真区★。
//   老 Air 的这条判据只要求「调试器应答了」（含哨兵）；Air2 补上「应答的内容必须是
//   真区」——只拿到哨兵 ⇒ 未就绪（保持等待、不建 VM），见 ④' 段。
//   等待循环 0.5s 一轮 ⇒ 单发 + 2s 限流（限流在 a2gate_obtain_real_region 里）。
BOOL A2AMEJITVerifyWritableJITRegion(void) {
    if (gA2AmeJITVerified && gA2AmeJITVerifiedRegion != NULL) {
        return YES;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (gA2AmeJITLastVerifyAttempt > 0 &&
        (now - gA2AmeJITLastVerifyAttempt) < A2GATE_REOBTAIN_THROTTLE_S) {
        return NO;
    }
    gA2AmeJITLastVerifyAttempt = now;
    gA2AmeJITVerifyAttempts++;

    size_t want = a2gate_want_bytes();
    A2GateRegionInfo info;
    BOOL sawSentinel = NO, extDelivered = NO;
    // ★attempts=2 + interval=0★：拿到哨兵时先装 Extension，然后**立刻**再探一发 ——
    //   这是「哨兵 → 真区」最常见的路径，不能让调用方（启动链 ② 的 verify）先失败一次。
    A2GateRegionKind kind = a2gate_obtain_real_region(want, 2, 0.0, YES,
                                                      &info, &sawSentinel, &extDelivered);

    if (kind != A2GateRegionKindReal) {
        a2_log_criterion(@"[JIT-FLOW] false-positive guard triggered (#%d): brk #0x69 没有交付真区"
                         @"（%s：%s）-- NOT counting JIT as ready (isJITEnabled=%d keepAttached=%d "
                         @"traced=%d exn=%d)",
                         gA2AmeJITVerifyAttempts, a2gate_kind_name(kind).UTF8String, info.rule,
                         (int)A2JITIsEnabled(NO), (int)A2JIT26IsLikelyDebuggerKeepAttached(),
                         (int)A2JIT26DebuggerAttachedViaPtrace(), (int)A2JIT26DebuggerViaExceptionPorts());
        return NO;
    }
    gA2AmeJITVerifiedRegion = info.addr;
    gA2AmeJITVerified = YES;
    a2_log_criterion(@"[JIT-FLOW] verified: brk #0x69 -> 真区 @%p（size=%llu ≥ 期望=%zu, cur=0x%x "
                     @"max=0x%x, writable=1）-- real JIT capability confirmed",
                     info.addr, info.vmSize, want, info.cur, info.max);
    return YES;
}

// 两型 mapping 的执行式探针（tree510 AMEJITBothMappingKindsExecutable 的等价物）。
//   Air2 侧同一实现已存在于 A2JITEnvironment（a2_jit_exec_probe_anonymous）：
//   真 mmap + 写一条指令 + mprotect(RX) + 真执行 + 回读。
//   ★差异（安全，不改结论口径）★：Air2 的探针在没有 CS_DEBUGGED 时返回 Skipped
//   （真机实测：无权限设备上执行自产页会被内核 SIGKILL-CODESIGNING）⇒ 这里把
//   Skipped 当作「未通过」。
static BOOL A2AMEJITBothMappingKindsExecutable(void) {
    if (a2_jit_exec_probe_anonymous() == A2JITExecProbeExecOK) {
        return YES;
    }
    // 第二次：与 HotSpot 文件背衬映射同型的 COW 探针在 Air2 尚未移植；老 Air 要求
    // 两型都通过。缺第二型 ⇒ 按老 Air 的「两型都要」口径判否（保守，不放行）。
    return NO;
}

BOOL A2AMEJITWaitReadyVerified(void) {
    if (!A2LegacyJITGateRequiresDebugMapping()) {
        return A2AMEJITBothMappingKindsExecutable();
    }
    if (!A2JIT26IsLikelyDebuggerKeepAttached()) {
        return NO;
    }
    return A2AMEJITVerifyWritableJITRegion();
}

// ============================================================================
// tree510 utils.m L2495–L2500：DeviceNeedsDebugJITMapping（Air2 等价物）
// ============================================================================
BOOL A2LegacyJITGateRequiresDebugMapping(void) {
    return [A2JITEnvironment needsDebuggerMapping];
}

BOOL A2LegacyJITGateReadyNow(NSString *_Nullable *_Nullable whyOut) {
    // 非镜像设备：老 Air 的闰门整块被跳过（`if (requiresDebugJITMapping) {…}`）
    // ⇒ 不闸。这与「有 JIT 时直接建 VM」的老行为逐字一致。
    if (!A2LegacyJITGateRequiresDebugMapping()) {
        if (whyOut) *whyOut = @"非镜像设备（<iOS 26）：老 Air 的 JIT 闰门整块跳过 ⇒ 直接放行";
        return YES;
    }
    // 镜像设备：唯一判据 = 老 Air 的 AMEJITWaitReadyVerified ★严格化为「拿到真区」★
    //   （调试器在岗 + brk #0x69 交付的必须是真区，哨兵不算）。
    if (A2AMEJITWaitReadyVerified()) {
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:
                @"brk #0x69 已交付真区（region=%p，size=%zu ≥ 期望=%zu 且可写）：isJITEnabled=%d "
                @"keepAttached=%d traced=%d exn=%d",
                gA2AmeJITVerifiedRegion, gA2GateRealRegionBytes, a2gate_want_bytes(),
                (int)A2JITIsEnabled(NO), (int)A2JIT26IsLikelyDebuggerKeepAttached(),
                (int)A2JIT26DebuggerAttachedViaPtrace(), (int)A2JIT26DebuggerViaExceptionPorts()];
        }
        return YES;
    }
    if (whyOut) {
        if (!A2JIT26IsLikelyDebuggerKeepAttached()) {
            *whyOut = [NSString stringWithFormat:
                @"没有活的调试器在岗（老 Air 三探针全否：ppid=%d traced=%d exn=%d；isJITEnabled=%d）"
                @"⇒ brk #0x69 无人应答，不能建 VM",
                getppid(), (int)A2JIT26DebuggerAttachedViaPtrace(),
                (int)A2JIT26DebuggerViaExceptionPorts(), (int)A2JITIsEnabled(NO)];
        } else {
            *whyOut = [NSString stringWithFormat:
                @"调试器在岗，但 brk #0x69 只回【握手哨兵 0x690000E0 / 一页不可写】或没应答："
                @"还没有交付 size≥%zu 且可写的真 JIT 区（traced=%d exn=%d，第 %d 次探测）"
                @"⇒ JIT 并未真正就绪，不能建 VM",
                a2gate_want_bytes(), (int)A2JIT26DebuggerAttachedViaPtrace(),
                (int)A2JIT26DebuggerViaExceptionPorts(), gA2AmeJITVerifyAttempts];
        }
    }
    return NO;
}

// ============================================================================
// ⑤ tree510 JavaLauncher.m L1384–L1544：建 JVM 之前的闰门
//   ★Air2 增补★：老 Air 走到「拿到哨兵 ⇒ 下发 Extension」就放行；这里再补上
//   「有界重试到真区」，★只认真区才放行★（见 ④' 段）。
// ============================================================================
A2LegacyJITGateOutcome A2LegacyJITGateOpen(NSString *_Nullable *_Nullable whyOut) {
    // tree510：`BOOL requiresDebugJITMapping = DeviceNeedsDebugJITMapping();`
    //          `if (requiresDebugJITMapping) { … }`  —— 非镜像设备整块跳过。
    if (!A2LegacyJITGateRequiresDebugMapping()) {
        a2_log_criterion(@"[A2-JIT-GATE] requiresDebugJITMapping=0 ⇒ 不建区、不下发 Extension"
                         @"（老 Air 同分支：直接进建 VM）");
        return A2LegacyJITGateOutcomeOpen;
    }

    size_t want = a2gate_want_bytes();
    a2_log_criterion(@"[A2-JIT-GATE] 建 VM 前闰门开始：向调试器讨 %zu 字节（%.0f MB）的 JIT 区"
                     @"（有界重试 %d 次 × %.0fs；★哨兵不算成功★）",
                     want, (double)want / (1024.0 * 1024.0),
                     A2GATE_RETRY_ATTEMPTS, A2GATE_RETRY_INTERVAL_S);

    // tree510（逐字，含 static 缓存语义）：
    //     static void *result;
    //     if(!result) result = JIT26CreateRegionLegacySafe(getpagesize());
    // → ★Air2 改为「复用已确认的真区 / 有界重试到真区」★（缓存也在 obtain 里）。
    A2GateRegionInfo info;
    BOOL sawSentinel = NO, extDelivered = NO;
    A2GateRegionKind kind = a2gate_obtain_real_region(want, A2GATE_RETRY_ATTEMPTS,
                                                      A2GATE_RETRY_INTERVAL_S, NO,
                                                      &info, &sawSentinel, &extDelivered);

    // ③ ★只认真区才放行★ —— 哨兵 / 小页 / 无应答一律未就绪，调用方不得建 VM。
    if (kind != A2GateRegionKindReal) {
        if (kind == A2GateRegionKindNone) {
            // tree510 原文：JIT26CreateRegionLegacy returned NULL -- JIT26 debugger not servicing brk
            a2_log_criterion(@"[JIT26] JIT26CreateRegionLegacy returned NULL -- JIT26 debugger not "
                             @"servicing brk; requesting JIT and waiting before aborting launch");
        }
        a2_log_criterion(@"[A2-JIT-GATE] ★未就绪 ⇒ 不建 VM★：最后一发=%s（%s）；"
                         @"见过哨兵=%d；Extension 下发=%d（老 Air 同分支：showDialog + return 1）",
                         a2gate_kind_name(kind).UTF8String, info.rule,
                         (int)sawSentinel, (int)extDelivered);
        if (whyOut) {
            NSString *base = [NSString stringWithFormat:
                @"brk #0x69 没有交付真 JIT 区（%s：%s）",
                a2gate_kind_name(kind).UTF8String, info.rule];
            if (kind == A2GateRegionKindNone) {
                *whyOut = [base stringByAppendingString:
                    @"。调试器不在应答状态（或没给它指派 UniversalJIT26 脚本）"];
            } else if (kind == A2GateRegionKindSentinel) {
                *whyOut = [NSString stringWithFormat:
                    @"%@。★只拿到 Universal 基础脚本的握手哨兵 0x690000E0（不是 JIT 区）★：Extension %@；"
                    @"请确认 StikDebug 已给 Air2 指派 UniversalJIT26 脚本（Extension 装好后同一发 brk "
                    @"才会真建区）",
                    base, extDelivered ? @"已下发但仍只回哨兵" : @"下发失败"];
            } else {
                *whyOut = [NSString stringWithFormat:
                    @"%@。期望 ≥%zu 字节（%.0f MB）且可写；实得 %llu 字节 cur=0x%x max=0x%x"
                    @"（偏好键 A2JITRegionMB 可调小期望值）",
                    base, want, (double)want / (1024.0 * 1024.0), info.vmSize, info.cur, info.max];
            }
        }
        return (kind == A2GateRegionKindSentinel) ? A2LegacyJITGateOutcomeSentinelOnly
                                                  : A2LegacyJITGateOutcomeNoRegion;
    }

    // 真区到手。★若这一路上没见过哨兵★（第一发就是真区）⇒ 不是「Universal 基础脚本 +
    //   Extension」这条链交付的（多半是设备上装的老 legacy 脚本，只服务一次断点）。
    //   尽力补发一次 Extension，让后续 brk #0x69 也走真建区；补发不成功 = 老 Air 的
    //   LegacyScript 分支（提示换 Universal 脚本并中止，不建 VM）。
    if (!sawSentinel && !extDelivered) {
        if (!a2gate_deliver_extension()) {
            void *legacy = info.addr;
            munmap(legacy, (size_t)getpagesize());
            gA2GateRealRegion = NULL;
            gA2GateRealRegionBytes = 0;
            a2_log_criterion(@"[A2-JIT-GATE] brk #0x69 直接回了真指针 %p（没经过哨兵）且 Extension 下发失败 "
                             @"⇒ 设备上装的是 legacy 脚本；老 Air 同分支：提示改用 Universal JIT 脚本并"
                             @"中止启动（不建 VM）", legacy);
            if (whyOut) {
                *whyOut = @"设备上装的是 legacy JIT 脚本（brk #0x69 直接回真指针、Extension 收不到）"
                          @"—— 请改用 UniversalJIT26 脚本后重试";
            }
            return A2LegacyJITGateOutcomeLegacyScript;
        }
    }

    // 到这里 == 老 Air 的成功分支（哨兵 + Extension 已下发）★且多验了一步「真区」★：
    // 设 detachAfterFirstBr + 清 BAD_ACCESS 异常端口。
    BOOL jit26AlwaysAttached =
        [NSUserDefaults.standardUserDefaults boolForKey:@"A2JITAlwaysAttached"];
    if (!a2_jit_set_detach_after_first_br(!jit26AlwaysAttached)) {
        a2_log_criterion(@"[JIT26] [JIT-NOCRASH] SetDetachAfterFirstBr NOT applied -- "
                         @"continuing in degraded mode");
    }
    // tree510：`// make sure we don't get stuck in EXC_BAD_ACCESS`
    //          `task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);`
    task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0,
                             EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);

    a2_log_criterion(@"[A2-JIT-GATE] ★放行 ⇒ 可以建 VM★（真区 %p：size=%llu ≥ 期望=%zu 且可写；"
                     @"哨兵先现=%d；Extension 已下发=%d；SetDetachAfterFirstBr(%d)）",
                     info.addr, info.vmSize, want, (int)sawSentinel, (int)extDelivered,
                     jit26AlwaysAttached ? 0 : 1);
    if (whyOut) {
        *whyOut = [NSString stringWithFormat:
            @"JIT 已就绪（老 Air 闰门 + Air2 真区验收：brk #0x69 交付 %p，size=%llu ≥ 期望=%zu 且可写；"
            @"UniversalJIT26Extension 已下发）", info.addr, info.vmSize, want];
    }
    return A2LegacyJITGateOutcomeOpen;
}
