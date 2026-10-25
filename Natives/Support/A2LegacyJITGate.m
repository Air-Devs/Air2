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
// ④ tree510 utils.m L1437–L1497：真能力判据
// ============================================================================
static void *gA2AmeJITVerifiedRegion = NULL;
static BOOL   gA2AmeJITVerified = NO;
static NSTimeInterval gA2AmeJITLastVerifyAttempt = 0;
static int    gA2AmeJITVerifyAttempts = 0;

// 主动申请并（尽力）写入一块 JIT 区，作为「真能力」判据。失败限流 2s
// （等待循环 200ms 一轮，若不限流会每轮发一次 brk）。
BOOL A2AMEJITVerifyWritableJITRegion(void) {
    if (gA2AmeJITVerified) {
        return YES;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (gA2AmeJITLastVerifyAttempt > 0 && (now - gA2AmeJITLastVerifyAttempt) < 2.0) {
        return NO;
    }
    gA2AmeJITLastVerifyAttempt = now;
    gA2AmeJITVerifyAttempts++;

    size_t len = (size_t)getpagesize();
    // ← tree510 JIT26CreateRegionLegacySafe(len)：brk #0x69；无人服务时返回 NULL 不致死。
    void *r = a2_jit_brk69_create_region_safe(len);
    if (r == NULL) {
        a2_log_criterion(@"[JIT-FLOW] false-positive guard triggered (#%d): brk #0x69 NOT serviced -- "
                         @"NOT counting JIT as enabled (isJITEnabled=%d keepAttached=%d traced=%d exn=%d)",
                         gA2AmeJITVerifyAttempts, A2JITIsEnabled(NO),
                         A2JIT26IsLikelyDebuggerKeepAttached(),
                         A2JIT26DebuggerAttachedViaPtrace(), A2JIT26DebuggerViaExceptionPorts());
        return NO;
    }
    // 尽力证明可写：先把这一段改成可写再写读，随后恢复 RX。mprotect 失败也不否决——
    // 「调试器服务了 brk #0x69 并返回了映射」本身已是权威信号。
    // ★Universal 基础脚本回的是哨兵 0x690000E0（不是一个真地址）⇒ mprotect 必然失败、
    //   于是不会去写它；这一支在老 Air 里同样是「不否决」。★
    BOOL writable = NO;
    if (mprotect(r, len, PROT_READ | PROT_WRITE) == 0) {
        volatile unsigned char *p = (volatile unsigned char *)r;
        p[0] = 0xA5;
        p[len - 1] = 0x5A;
        writable = (p[0] == 0xA5 && p[len - 1] == 0x5A);
        // 恢复为可执行的 JIT 区，避免影响调试器/脚本对该区的后续用途。
        mprotect(r, len, PROT_READ | PROT_EXEC);
    }
    gA2AmeJITVerifiedRegion = r;   // 留驻（只一页），供后续复用/诊断
    gA2AmeJITVerified = YES;
    a2_log_criterion(@"[JIT-FLOW] verified: debugger serviced brk #0x69 -> JIT region @%p (%zu bytes, "
                     @"writable=%d) -- real JIT capability confirmed", r, len, (int)writable);
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
    // 镜像设备：唯一判据 = 老 Air 的 AMEJITWaitReadyVerified
    //   （调试器在岗 + brk #0x69 真的被服务）。
    if (A2AMEJITWaitReadyVerified()) {
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:
                @"brk #0x69 已被服务（老 Air 判据通过）：region=%p isJITEnabled=%d "
                @"keepAttached=%d traced=%d exn=%d",
                gA2AmeJITVerifiedRegion, A2JITIsEnabled(NO),
                A2JIT26IsLikelyDebuggerKeepAttached(),
                A2JIT26DebuggerAttachedViaPtrace(), A2JIT26DebuggerViaExceptionPorts()];
        }
        return YES;
    }
    if (whyOut) {
        if (!A2JIT26IsLikelyDebuggerKeepAttached()) {
            *whyOut = [NSString stringWithFormat:
                @"没有活的调试器在岗（老 Air 三探针全否：ppid=%d traced=%d exn=%d；isJITEnabled=%d）"
                @"⇒ brk #0x69 无人应答，不能建 VM",
                getppid(), A2JIT26DebuggerAttachedViaPtrace(), A2JIT26DebuggerViaExceptionPorts(),
                A2JITIsEnabled(NO)];
        } else {
            *whyOut = [NSString stringWithFormat:
                @"调试器在岗但 brk #0x69 未被服务（老 Air AMEJITVerifyWritableJITRegion=NO；traced=%d "
                @"exn=%d）⇒ JIT 并未真正开启，不能建 VM",
                A2JIT26DebuggerAttachedViaPtrace(), A2JIT26DebuggerViaExceptionPorts()];
        }
    }
    return NO;
}

// ============================================================================
// ⑤ tree510 JavaLauncher.m L1384–L1544：建 JVM 之前的闰门
// ============================================================================
A2LegacyJITGateOutcome A2LegacyJITGateOpen(NSString *_Nullable *_Nullable whyOut) {
    // tree510：`BOOL requiresDebugJITMapping = DeviceNeedsDebugJITMapping();`
    //          `if (requiresDebugJITMapping) { … }`  —— 非镜像设备整块跳过。
    if (!A2LegacyJITGateRequiresDebugMapping()) {
        a2_log_criterion(@"[A2-JIT-GATE] requiresDebugJITMapping=0 ⇒ 不建区、不下发 Extension"
                         @"（老 Air 同分支：直接进建 VM）");
        return A2LegacyJITGateOutcomeOpen;
    }

    // tree510（逐字，含 static 缓存语义）：
    //     static void *result;
    //     if(!result) result = JIT26CreateRegionLegacySafe(getpagesize());
    static void *result;
    if (!result) result = a2_jit_brk69_create_region_safe((size_t)getpagesize());

    if (result == NULL) {
        // tree510 原文：JIT26CreateRegionLegacy returned NULL -- JIT26 debugger not servicing brk
        a2_log_criterion(@"[JIT26] JIT26CreateRegionLegacy returned NULL -- JIT26 debugger not "
                         @"servicing brk; requesting JIT and waiting before aborting launch");
        a2_log_criterion(@"[A2-JIT-GATE] ★未就绪 ⇒ 不建 VM★（老 Air 同分支：showDialog + return 1）");
        if (whyOut) {
            *whyOut = @"JIT 调试器没有应答 brk #0x69（本进程没有拿到 JIT）";
        }
        return A2LegacyJITGateOutcomeNoRegion;
    }

    // tree510：`if ((uint32_t)result != 0x690000E0) { munmap(...); …legacy 脚本提示…; return 1; }`
    //   ★这正是 Universal 基础脚本的哨兵（0xE0000069 的字节序翻转）——拿到它才说明
    //     设备上装的是 Universal 脚本、可以继续下发 Extension。★
    if ((uint32_t)(uintptr_t)result != 0x690000E0u) {
        void *legacy = result;
        munmap(legacy, (size_t)getpagesize());
        result = NULL;   // 老 Air 未清；清掉只为让下次重新发 brk（不改变任何判定结果）
        a2_log_criterion(@"[A2-JIT-GATE] brk #0x69 返回真实地址 %p（不是 Universal 脚本的哨兵 "
                         @"0x690000E0）⇒ 设备上装的是 legacy 脚本；老 Air 同分支：提示改用 "
                         @"Universal JIT 脚本并中止启动（不建 VM）", legacy);
        if (whyOut) {
            *whyOut = @"设备上装的是 legacy JIT 脚本（brk #0x69 回了真指针而非 Universal 哨兵）"
                      @"—— 请改用 UniversalJIT26 脚本后重试";
        }
        return A2LegacyJITGateOutcomeLegacyScript;
    }

    // 到这里 == 老 Air 的成功分支：下发 UniversalJIT26Extension.js（把
    // legacyCommands[0x69] 换成真建区）+ 设 detachAfterFirstBr + 清 BAD_ACCESS 异常端口。
    BOOL jit26AlwaysAttached =
        [NSUserDefaults.standardUserDefaults boolForKey:@"A2JITAlwaysAttached"];
    NSString *extPath = [NSBundle.mainBundle pathForResource:@"UniversalJIT26Extension" ofType:@"js"];
    NSString *extScript = extPath.length ? [NSString stringWithContentsOfFile:extPath
                                                                    encoding:NSUTF8StringEncoding
                                                                       error:nil]
                                         : nil;
    if (!a2_jit_send_script_safe(extScript.UTF8String, extScript.length)) {
        a2_log_criterion(@"[JIT26] [JIT-NOCRASH] UniversalJIT26 script NOT delivered "
                         @"(brk #0xf00d unanswered) -- continuing in degraded mode");
    }
    if (!a2_jit_set_detach_after_first_br(!jit26AlwaysAttached)) {
        a2_log_criterion(@"[JIT26] [JIT-NOCRASH] SetDetachAfterFirstBr NOT applied -- "
                         @"continuing in degraded mode");
    }
    // tree510：`// make sure we don't get stuck in EXC_BAD_ACCESS`
    //          `task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);`
    task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0,
                             EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);

    a2_log_criterion(@"[A2-JIT-GATE] ★放行 ⇒ 可以建 VM★（老 Air 同分支：哨兵 0x690000E0 + "
                     @"Extension 已下发 + SetDetachAfterFirstBr(%d)）", jit26AlwaysAttached ? 0 : 1);
    if (whyOut) {
        *whyOut = @"JIT 已就绪（老 Air 闰门：brk #0x69 应答 + UniversalJIT26Extension 已下发）";
    }
    return A2LegacyJITGateOutcomeOpen;
}
