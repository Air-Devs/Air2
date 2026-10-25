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
//  ★判据（方案 A，对齐老 Air）★：老 Air 拿到 Universal 基础脚本的握手哨兵
//  `0xE0000069`（寄存器回读形态 `0xcccccccc690000e0`）后下发 Extension 就建 VM——
//  真区在那之后才由 libjvm 自己发 brk #0x69 取得。所以闸门只判【握手是否完成】：
//  哨兵已识别 + Extension 已下发成功 + 至少一次 brk #0x69 被调试器服务 ⇒ 放行。
//  ★不再要求本进程先拿到 size≥64MB 的真区★ —— 闸门自己发的那发 brk 用的是固定小页长度
//  （getpagesize），64MB 是 libjvm 按 -XX:ReservedCodeCacheSize 建 VM 时才自己发的；
//  拿「探测 brk 的返回值」去要求 64MB，逻辑上永远不成立（真机 lastlog.old-6 的假失败根因）。
//  region 的 size / 期望 / 保护位一律【只打日志，不参与判定】。
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
// ④' Air2 增补：★握手（哨兵 → Extension → brk 被服务）★
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
//  ★方案 A（真机 lastlog.old-6 之后的修正）★：
//    Air2 曾在哨兵之后要求「本进程先拿到 size≥64MB 且可写的真区」才放行，真机表现是
//    「Extension 已下发 ⇒ 立刻重试 brk #0x69（期望 size≥67108864）⇒ 重试 2 次后仍未拿到
//    真区：最后一发=失败（size 小于期望）⇒ 判「JIT 未就绪」⇒ 失败页」。根因是**判据错**，不是 JIT 没开：
//    闸门自己发的那发 brk 用固定小页长度（getpagesize），而 64MB 是 libjvm 建 VM 时按
//    -XX:ReservedCodeCacheSize 自己发 brk 才要的 ⇒ 用「探测 brk 的返回值」去要求 64MB，
//    逻辑上永远不成立。故按老 Air 的口径收敛判据：
//      ① entitlement（能力声明，只进日志/原因文案，不单独放行）；
//      ② 调试器在岗（三探针）；
//      ③ 哨兵已识别 ⇒ 下发 UniversalJIT26Extension.js（把 legacyCommands[0x69] 换成真建区）；
//      ④ brk #0x69 至少有一次被调试器服务（返回值非 NULL）⇒ 握手完成 ⇒ 放行。
//    ★真正的建区与尺寸由 libjvm 建 VM 时自己发 brk 完成★；我们不拦、也不替它验收 ——
//    拿不到时由 libjvm 自己报错（它的 rc 才是结论）。region 的 size / 期望 / 保护位只打日志，
//    ★不参与任何判定★（真机日志里写「仅供参考，不参与判定」）。
//
//  ★不用 mprotect 自证可写★：真机证据（A2JITEnvironment.m ③ 的注释 / _RT_P0_2.md）——
//  对调试器交付的 JIT 页做 mprotect(RW)→mprotect(RX) 会撤掉 iOS 26+ 给它的
//  「可执行祝福」，等于把一块可用区做成废区。可写性只从 vm_region_64 的
//  当前/最大保护位读，且仅用于日志。
// ============================================================================

/// Universal 基础脚本 `P0=E0000069` 的寄存器回读形态低 32 位。
#define A2GATE_SENTINEL_LO          0x690000E0u
/// 同一哨兵的另一种字节序（脚本写进去的字面量）。
#define A2GATE_SENTINEL_LO_SWAPPED  0xE0000069u
/// 哨兵的地址高位（寄存器半填充垃圾：0xcccccccc690000e0）。
#define A2GATE_SENTINEL_HI          0xccccccccu
/// 「小到不可能是 code cache」的阈值：一页 = 16KB（arm64）。★仅用于日志档位★。
#define A2GATE_SENTINEL_MAX_BYTES   16384ull
/// 有界重试：次数与间隔（哨兵 ⇒ 下发 Extension ⇒ 再取一发做取证；★不是「等到大区」★）。
#define A2GATE_RETRY_ATTEMPTS       3
#define A2GATE_RETRY_INTERVAL_S     2.0
/// 等待循环里的限流：两次「握手探测」至少间隔（秒）。
#define A2GATE_REOBTAIN_THROTTLE_S  2.0

/// brk #0x69 返回值的★日志档位★（a2gate_classify 的产物）。
///   ★只让真机 grep 时一眼分清「见到了什么」，一律不参与放行判定★ ——
///   判定只看「这一发有没有被服务」（NULL 之外都算服务过），见 a2gate_handshake。
typedef NS_ENUM(NSInteger, A2GateRegionKind) {
    A2GateRegionKindNone     = 0,  ///< 没应答（NULL）：调试器不在岗 / 没指派脚本 ⇒ ★未服务★
    A2GateRegionKindSentinel = 1,  ///< 握手哨兵（0x690000E0 / 0xcccccccc… / 小页且不可写）
    A2GateRegionKindUnmapped = 2,  ///< 非哨兵但进程内无映射（垃圾返回值）
    A2GateRegionKindSmall    = 3,  ///< 有映射，但 size 小于期望（★仅日志：闸门发的是小页 brk★）
    A2GateRegionKindReadOnly = 4,  ///< 有映射且够大，但没有写权限（★仅日志★）
    A2GateRegionKindMapped   = 5,  ///< 非哨兵 + 进程内有映射（真指针；尺寸/保护位仅进日志）
};

/// 一次 brk #0x69 返回值的完整取证（★日志用★）。
typedef struct {
    void *addr;
    size_t wantBytes;
    unsigned long long vmSize;
    unsigned int cur;
    unsigned int max;
    BOOL mapped;
    BOOL writable;
    BOOL executable;
    const char *rule;   ///< 命中的档位短语（日志用，静态字符串）
} A2GateRegionInfo;

/// tree510 JIT26CreateRegionLegacySafe 的 expected 口径
/// （= A2JITEnvironment.expectedRegionBytes：偏好键 `A2JITRegionMB` 覆盖，未设 ⇒ 64MB）。
/// ★方案 A：这个值只用于日志对照★ —— 闸门自己不发这么大（发 getpagesize），更不拿它当判据。
static size_t a2gate_expect_bytes(void) {
    size_t want = [A2JITEnvironment expectedRegionBytes];
    if (want == 0) {
        want = 64u * 1024u * 1024u;
    }
    return want;
}

/// ★取证★：把 brk #0x69 的返回值判成 6 档之一。纯只读（vm_region_64），无副作用。
///   ★档位只决定日志文案，不决定放行★；放行只看 a2gate_handshake 的 ready。
static A2GateRegionKind a2gate_classify(void *r, size_t expect, A2GateRegionInfo *info) {
    A2GateRegionInfo local;
    if (info == NULL) info = &local;
    memset(info, 0, sizeof(*info));
    info->addr = r;
    info->wantBytes = expect;
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

    // ② 真映射与保护位：vm_region_64 只读查询（结果只进日志）。
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
    // ④ 尺寸/保护位只影响日志档位 —— ★不再有任何「size 小于期望 ⇒ 未就绪」的判定★。
    if (info->vmSize < (unsigned long long)expect) {
        info->rule = "映射小于期望值（仅日志，不参与判定）";
        return A2GateRegionKindSmall;
    }
    if (!info->writable) {
        info->rule = "无写权限（仅日志，不参与判定）";
        return A2GateRegionKindReadOnly;
    }
    info->rule = "非哨兵 + 有映射（真指针）";
    return A2GateRegionKindMapped;
}

/// 档位的中文名（日志用；关键状态各自一眼可辨）。
static NSString *a2gate_kind_name(A2GateRegionKind k) {
    switch (k) {
        case A2GateRegionKindNone:     return @"无应答（未服务）";
        case A2GateRegionKindSentinel: return @"握手哨兵";
        case A2GateRegionKindUnmapped: return @"垃圾返回（无映射）";
        case A2GateRegionKindSmall:    return @"映射偏小（仅日志）";
        case A2GateRegionKindReadOnly: return @"只读（仅日志）";
        case A2GateRegionKindMapped:   return @"真指针（有映射）";
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

/// ── 进程级握手结论（老 Air 的 `static void *result` 记忆语义）──
///   握手成功一次就留驻：之后每次问「就绪没」不再重发 brk（每发一发都是调试器侧的一次分配）。
static BOOL gA2GateHandshakeDone = NO;
/// 本进程是否曾见过握手哨兵 / Extension 是否下发成功（「凭哪条放行」的取证）。
static BOOL gA2GateSawSentinel = NO;
static BOOL gA2GateExtDelivered = NO;
/// 最近一次被服务的那发 brk 的取证（★只用于日志★：不复用、不 munmap、不参与判定）。
static A2GateRegionInfo gA2GateLastInfo;
static NSTimeInterval gA2GateLastAttempt = 0;
static int gA2GateAttempts = 0;

/// 一次握手（哨兵 → Extension → brk 被服务）的全部取证。★判定只看 ready★。
typedef struct {
    BOOL ready;         ///< ★放行判据★：serviced && (非哨兵 || Extension 已下发成功)
    BOOL serviced;      ///< 至少一发 brk #0x69 被调试器服务（返回值非 NULL）
    BOOL sawSentinel;   ///< 见过 Universal 基础脚本的握手哨兵
    BOOL extTried;      ///< 尝试过下发 Extension
    BOOL extDelivered;  ///< Extension 下发成功（brk #0xf00d cmd=2 被服务）
    int  brks;          ///< 本次实际发了几发 brk
    A2GateRegionKind kind;   ///< 最后一发的档位（★仅日志★）
    A2GateRegionInfo info;   ///< 最后一发的取证（★仅日志★）
} A2GateHandshake;

/// ★握手★：唯一入口，★放行判据就是它的 ready★。
///   probeLen = 闸门向调试器讨的字节数（老 Air 口径 = getpagesize()）；
///   expect   = 期望大小，★只为日志对照★（64MB 是 libjvm 建 VM 时自己发 brk 才要的，闸门不要求）；
///   throttle=YES ⇒ 等待循环用（两次探测至少间隔 A2GATE_REOBTAIN_THROTTLE_S，防每 0.5s 打一发 brk）；
///   throttle=NO  ⇒ 建 VM 前的一次性闰门用（绝不因为限流而误拦）。
static BOOL a2gate_handshake(size_t probeLen, size_t expect,
                             int attempts, NSTimeInterval interval, BOOL throttle,
                             A2GateHandshake *hs) {
    A2GateHandshake local;
    if (hs == NULL) hs = &local;
    memset(hs, 0, sizeof(*hs));
    hs->kind = A2GateRegionKindNone;
    hs->info.rule = "未探测";
    hs->info.wantBytes = expect;
    if (attempts < 1) attempts = 1;

    // ⓪ 本进程已握手成功过 ⇒ 直接放行（不再重发 brk）。
    if (gA2GateHandshakeDone) {
        hs->ready = YES;
        hs->serviced = YES;
        hs->sawSentinel = gA2GateSawSentinel;
        hs->extTried = hs->extDelivered = gA2GateExtDelivered;
        hs->kind = A2GateRegionKindMapped;
        hs->info = gA2GateLastInfo;
        hs->info.wantBytes = expect;
        if (hs->info.rule == NULL) hs->info.rule = "（本进程此前已完成握手）";
        a2_log_criterion(@"[JIT-FLOW] 握手此前已完成（本进程）⇒ 直接放行；region size=%llu"
                         @"（期望 %zu，仅供参考，不参与判定）",
                         hs->info.vmSize, expect);
        return YES;
    }

    // ① 限流：等待循环 0.5s 一轮，不限流会每轮发一发 brk。
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (throttle && gA2GateLastAttempt > 0 &&
        (now - gA2GateLastAttempt) < A2GATE_REOBTAIN_THROTTLE_S) {
        hs->info.rule = "限流中（距上次探测不足 2s）";
        return NO;
    }
    gA2GateLastAttempt = now;
    gA2GateAttempts++;

    for (int i = 0; i < attempts; i++) {
        if (i > 0 && interval > 0) {
            [NSThread sleepForTimeInterval:interval];   // 有界重试的间隔
        }
        // ← tree510 JIT26CreateRegionLegacySafe(len)：brk #0x69；无人服务返回 NULL 不致死。
        void *r = a2_jit_brk69_create_region_safe(probeLen);
        hs->brks = i + 1;
        hs->kind = a2gate_classify(r, expect, &hs->info);

        if (hs->kind == A2GateRegionKindNone) {
            // 没人服务（调试器不在岗 / 没指派脚本）：cmd=2 走的也是 brk #0xf00d，同样不会有人应答
            // ⇒ 这一轮不下发 Extension，下一轮再试（调试器可能刚 attach）。
            a2_log_criterion(@"[JIT-FLOW] brk #0x69 无应答（第 %d/%d 发）: NULL "
                             @"(调试器在岗=%d traced=%d exn=%d) —— 这一发没被服务",
                             i + 1, attempts,
                             (int)A2JIT26IsLikelyDebuggerKeepAttached(),
                             (int)A2JIT26DebuggerAttachedViaPtrace(),
                             (int)A2JIT26DebuggerViaExceptionPorts());
            continue;
        }

        // ★brk 被调试器服务了★：NULL 之外的任何应答都算（哨兵 / 一页 / 只读 / 大区）。
        //   数值（size / 期望 / 保护位）只进日志，★不参与判定★。
        hs->serviced = YES;
        gA2GateLastInfo = hs->info;
        if (hs->kind == A2GateRegionKindSentinel) {
            hs->sawSentinel = YES;
            gA2GateSawSentinel = YES;
            a2_log_criterion(@"[JIT-FLOW] 哨兵 handshake detected（第 %d/%d 发）: brk #0x69 -> %p "
                             @"(size=%llu cur=0x%x max=0x%x writable=%d, 档位=%s) "
                             @"⇒ Universal 基础脚本的握手哨兵，★不是 JIT 区★"
                             @"（真区由 libjvm 建 VM 时自己发 brk 取）",
                             i + 1, attempts, r, hs->info.vmSize, hs->info.cur, hs->info.max,
                             (int)hs->info.writable, hs->info.rule);
        } else {
            a2_log_criterion(@"[JIT-FLOW] brk #0x69 已被服务（第 %d/%d 发）: -> %p "
                             @"(size=%llu 期望=%zu cur=0x%x max=0x%x writable=%d executable=%d, "
                             @"档位=%s) -- serviced；region 数值仅供参考，不参与判定",
                             i + 1, attempts, r, hs->info.vmSize, expect,
                             hs->info.cur, hs->info.max,
                             (int)hs->info.writable, (int)hs->info.executable, hs->info.rule);
        }

        // ② Extension：哨兵必须下发（老 Air 的握手）；非哨兵也尽力补发一次（legacy 脚本判别要用）。
        //    ★整次握手只发一次★。
        if (!hs->extTried) {
            hs->extTried = YES;
            hs->extDelivered = a2gate_deliver_extension();
            if (hs->extDelivered) {
                a2_log_criterion(@"[JIT-FLOW] Extension 已下发 ⇒ 再发一发 brk #0x69 做取证"
                                 @"（region size 仅供参考，不参与判定；真区由 libjvm 建 VM 时自己取）");
            }
        }

        // ③ ★判定★：非哨兵（已服务）⇒ 握手完成；哨兵 ⇒ 必须 Extension 也下发成功。
        if (hs->serviced && (!hs->sawSentinel || hs->extDelivered)) {
            // 哨兵刚被 Extension 换成真建区、且这次探测本身不等待（interval=0）⇒ 顺手再探一发只为
            // 取证 region 数值（免费）；其余情况（尤其建 VM 前的闰门，interval=2s）直接收尾 ——
            // 不为日志多等一个间隔。
            BOOL wantForensics = (hs->kind == A2GateRegionKindSentinel &&
                                  (i + 1) < attempts && interval <= 0.0);
            if (!wantForensics) break;
        }
    }

    // ④ 收尾判定：★只看「有没有被服务」+「哨兵那条路 Extension 有没有下发成功」★。
    //    size / 期望 / 保护位一律不参与（见 ④' 段：闸门发的是小页 brk，64MB 归 libjvm）。
    hs->ready = hs->serviced && (!hs->sawSentinel || hs->extDelivered);
    gA2GateExtDelivered = hs->extDelivered;
    if (hs->ready) {
        gA2GateHandshakeDone = YES;
        a2_log_criterion(@"[JIT-FLOW] 握手完成（哨兵+Extension）⇒ 放行；region size=%llu"
                         @"（期望 %zu，仅供参考，不参与判定；见过哨兵=%d 第 %d 次探测 %d 发）",
                         hs->info.vmSize, expect, (int)hs->sawSentinel,
                         gA2GateAttempts, hs->brks);
    } else {
        a2_log_criterion(@"[JIT-FLOW] 握手未完成（第 %d 次探测，%d 发）：最后一发=%s（%s）；"
                         @"见过哨兵=%d；Extension 下发=%d ⇒ 未就绪（不建 VM）",
                         gA2GateAttempts, hs->brks,
                         a2gate_kind_name(hs->kind).UTF8String, hs->info.rule,
                         (int)hs->sawSentinel, (int)hs->extDelivered);
    }
    return hs->ready;
}

// ============================================================================
// ④ tree510 utils.m L1437–L1497：真能力判据
//   ★判据（方案 A）= 握手完成★：调试器在岗 + brk #0x69 被服务 + 哨兵那条路 Extension 已下发。
//   ★不再要求「本进程先拿到 size≥期望(64MB) 的真区」★（理由见 ④' 段：那发探测 brk 只有一页，
//   64MB 是 libjvm 建 VM 时自己发的；拿探测结果要求 64MB 永远不成立）。
// ============================================================================
static void *gA2AmeJITVerifiedRegion = NULL;   ///< 最近一次被服务的那发 brk 的地址（★仅日志/原因文案★）
static BOOL   gA2AmeJITVerified = NO;
static NSTimeInterval gA2AmeJITLastVerifyAttempt = 0;
static int    gA2AmeJITVerifyAttempts = 0;

// 发 brk #0x69 确认「已被服务」，并完成哨兵 → Extension 的握手。
//   老 Air 的这条判据只要求「调试器应答了」（哨兵也算应答）；方案 A 与它一致，
//   region 的 size / 保护位只记录供诊断（★不参与判定★）。
//   等待循环 0.5s 一轮 ⇒ 单发 + 2s 限流（限流在 a2gate_handshake 里）。
BOOL A2AMEJITVerifyJITHandshake(void) {
    if (gA2AmeJITVerified) {
        return YES;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (gA2AmeJITLastVerifyAttempt > 0 &&
        (now - gA2AmeJITLastVerifyAttempt) < A2GATE_REOBTAIN_THROTTLE_S) {
        return NO;
    }
    gA2AmeJITLastVerifyAttempt = now;
    gA2AmeJITVerifyAttempts++;

    size_t probe = (size_t)getpagesize();      // 老 Air 口径：闸门只讨一页
    size_t expect = a2gate_expect_bytes();     // 仅日志对照
    A2GateHandshake hs;
    // ★attempts=2 + interval=0★：拿到哨兵时先装 Extension，然后**立刻**再探一发做取证 ——
    //   不让调用方（启动链 ② 的 verify）先失败一次。
    BOOL ready = a2gate_handshake(probe, expect, 2, 0.0, YES, &hs);

    if (!ready) {
        a2_log_criterion(@"[JIT-FLOW] 握手未完成（#%d）：%s（%s）-- 不把 JIT 记为已就绪"
                         @"（isJITEnabled=%d keepAttached=%d traced=%d exn=%d）",
                         gA2AmeJITVerifyAttempts, a2gate_kind_name(hs.kind).UTF8String, hs.info.rule,
                         (int)A2JITIsEnabled(NO), (int)A2JIT26IsLikelyDebuggerKeepAttached(),
                         (int)A2JIT26DebuggerAttachedViaPtrace(), (int)A2JIT26DebuggerViaExceptionPorts());
        return NO;
    }
    gA2AmeJITVerifiedRegion = hs.info.addr;
    gA2AmeJITVerified = YES;
    a2_log_criterion(@"[JIT-FLOW] 握手完成（哨兵+Extension）⇒ 放行；region size=%llu"
                     @"（期望 %zu，仅供参考，不参与判定）-- JIT handshake ok (%p)",
                     hs.info.vmSize, expect, hs.info.addr);
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
    // ★四条件顺序（不退回「只看 CS_DEBUGGED 就放行」）★
    //   ① entitlement（能力声明）：只进 reason / 日志，★不单独放行★；
    //   ② 调试器在岗（三探针）—— 没有它 brk #0x69 一定无人应答；
    //   ③④ 哨兵/Extension 握手 + brk 被服务（A2AMEJITVerifyJITHandshake 内按此顺序）。
    if (!A2JIT26IsLikelyDebuggerKeepAttached()) {
        return NO;
    }
    return A2AMEJITVerifyJITHandshake();
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
    // 镜像设备：唯一判据 = 老 Air 的 AMEJITWaitReadyVerified
    //   ★方案 A：只要握手完成（哨兵 + Extension + brk 被服务）就放行★，
    //   不要求本进程先拿到 64MB 真区（那由 libjvm 建 VM 时自己发 brk 取）。
    if (A2AMEJITWaitReadyVerified()) {
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:
                @"握手完成（哨兵+Extension）⇒ 放行（region=%p，size=%zu 仅供参考；isJITEnabled=%d "
                @"keepAttached=%d traced=%d exn=%d）",
                gA2AmeJITVerifiedRegion, (size_t)gA2GateLastInfo.vmSize,
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
                @"调试器在岗，但握手没完成（哨兵/Extension 或 brk #0x69 没被服务）："
                @"Extension 下发=%d（traced=%d exn=%d，第 %d 次探测）"
                @"⇒ JIT 并未真正就绪，不能建 VM",
                (int)gA2GateExtDelivered, (int)A2JIT26DebuggerAttachedViaPtrace(),
                (int)A2JIT26DebuggerViaExceptionPorts(), gA2AmeJITVerifyAttempts];
        }
    }
    return NO;
}

// ============================================================================
// ⑤ tree510 JavaLauncher.m L1384–L1544：建 JVM 之前的闰门
//   ★方案 A（对齐老 Air）★：老 Air 走到「拿到哨兵 ⇒ 下发 Extension」就放行建 VM ——
//   真区在那之后由 libjvm 自己发 brk #0x69 取得。★这里不再要求 64MB 真区★（见 ④' 段）。
// ============================================================================
A2LegacyJITGateOutcome A2LegacyJITGateOpen(NSString *_Nullable *_Nullable whyOut) {
    // tree510：`BOOL requiresDebugJITMapping = DeviceNeedsDebugJITMapping();`
    //          `if (requiresDebugJITMapping) { … }`  —— 非镜像设备整块跳过。
    if (!A2LegacyJITGateRequiresDebugMapping()) {
        a2_log_criterion(@"[A2-JIT-GATE] requiresDebugJITMapping=0 ⇒ 不建区、不下发 Extension"
                         @"（老 Air 同分支：直接进建 VM）");
        return A2LegacyJITGateOutcomeOpen;
    }

    // tree510（逐字）：`JIT26CreateRegionLegacySafe(getpagesize())` —— ★闸门只讨一页★。
    //   64MB 的真区是 libjvm 建 VM 时按 -XX:ReservedCodeCacheSize 自己发的，闸门不替它要。
    size_t probe = (size_t)getpagesize();
    size_t expect = a2gate_expect_bytes();    // 仅日志对照（A2JITRegionMB，默认 64MB）
    a2_log_criterion(@"[A2-JIT-GATE] 建 VM 前闰门开始：握手探测（brk #0x69 讨 %zu 字节 = 一页；"
                     @"期望值 %zu 仅作日志参考；有界 %d 发 × %.0fs）",
                     probe, expect, A2GATE_RETRY_ATTEMPTS, A2GATE_RETRY_INTERVAL_S);

    A2GateHandshake hs;
    BOOL ready = a2gate_handshake(probe, expect, A2GATE_RETRY_ATTEMPTS,
                                  A2GATE_RETRY_INTERVAL_S, NO, &hs);

    if (!ready) {
        // ★不拦真正的建区★：这里拦的只有「握手没成」（调试器没服务 / Extension 没下发）。
        if (!hs.serviced) {
            // tree510 原文：JIT26CreateRegionLegacy returned NULL -- JIT26 debugger not servicing brk
            a2_log_criterion(@"[JIT26] JIT26CreateRegionLegacy returned NULL -- JIT26 debugger not "
                             @"servicing brk; requesting JIT and waiting before aborting launch");
        }
        a2_log_criterion(@"[A2-JIT-GATE] 握手未完成 ⇒ 不建 VM：最后一发=%s（%s）；"
                         @"见过哨兵=%d；Extension 下发=%d（老 Air 同分支：showDialog + return 1）",
                         a2gate_kind_name(hs.kind).UTF8String, hs.info.rule,
                         (int)hs.sawSentinel, (int)hs.extDelivered);
        if (whyOut) {
            if (!hs.serviced) {
                *whyOut = @"brk #0x69 无人应答（调试器不在岗，或没给 Air2 指派 UniversalJIT26 脚本）"
                          @"—— 握手没开始，不能建 VM";
            } else {
                *whyOut = [NSString stringWithFormat:
                    @"已见到 Universal 基础脚本的握手哨兵 0x690000E0，但 Extension 没下发成功"
                    @"（%@）—— 请确认 StikDebug 已给 Air2 指派 UniversalJIT26 脚本（含 Extension）",
                    hs.extTried ? @"brk #0xf00d cmd=2 未被服务，或包里缺 Extension 脚本"
                                : @"未尝试"];
            }
        }
        return hs.sawSentinel ? A2LegacyJITGateOutcomeSentinelOnly
                              : A2LegacyJITGateOutcomeNoRegion;
    }

    // ★若这一路上没见过哨兵★（第一发就是真指针）⇒ 不是「Universal 基础脚本 + Extension」这条链
    //   交付的（多半是设备上装的老 legacy 脚本，只服务一次断点）。尽力补发一次 Extension，
    //   让后续 brk #0x69 也走真建区；补发不成功 = 老 Air 的 LegacyScript 分支
    //   （提示换 Universal 脚本并中止，不建 VM）。
    if (!hs.sawSentinel && !hs.extDelivered) {
        a2_log_criterion(@"[A2-JIT-GATE] brk #0x69 直接回了真指针 %p（没经过哨兵）且 Extension 下发失败 "
                         @"⇒ 设备上装的是 legacy 脚本；老 Air 同分支：提示改用 Universal JIT 脚本并"
                         @"中止启动（不建 VM）", hs.info.addr);
        if (whyOut) {
            *whyOut = @"设备上装的是 legacy JIT 脚本（brk #0x69 直接回真指针、Extension 收不到）"
                      @"—— 请改用 UniversalJIT26 脚本后重试";
        }
        return A2LegacyJITGateOutcomeLegacyScript;
    }

    // 到这里 == 老 Air 的成功分支（哨兵 + Extension 已下发）★握手完成★：
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

    a2_log_criterion(@"[A2-JIT-GATE] 握手完成（哨兵+Extension）⇒ 放行；region size=%llu"
                     @"（期望 %zu，仅供参考，不参与判定）★放行 ⇒ 可以建 VM★"
                     @"（region=%p；哨兵先现=%d；Extension 已下发=%d；SetDetachAfterFirstBr(%d)）",
                     hs.info.vmSize, expect, hs.info.addr,
                     (int)hs.sawSentinel, (int)hs.extDelivered,
                     jit26AlwaysAttached ? 0 : 1);
    if (whyOut) {
        *whyOut = [NSString stringWithFormat:
            @"JIT 已就绪（握手完成：哨兵 %@ + UniversalJIT26Extension 已下发 + brk #0x69 被服务；"
            @"region=%p size=%llu 仅供参考 —— 真区由 libjvm 建 VM 时自己取）",
            hs.sawSentinel ? @"已识别" : @"未出现（直接回真指针）",
            hs.info.addr, hs.info.vmSize];
    }
    return A2LegacyJITGateOutcomeOpen;
}
