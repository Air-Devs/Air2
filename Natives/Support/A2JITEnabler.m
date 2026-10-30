//
//  A2JITEnabler.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— 启动前 JIT 使能（判据 → 申请 → 等待 → 回调）。
//
//  移植来源（老 Air，只搬机制、不搬无关代码）：
//    · tree510/Natives/DownloadViewController.m  L3891–L4100  invokeAfterJITEnabled: 完整流程
//    · tree510/Natives/JavaLauncher.m           L3000–L3050  使能器 URL 选择
//    · tree510/Natives/utils.m                  isJITEnabled / AMEJIT* 判据与等待
//
//  ★与老 Air 的差异（为什么不同，写清）★
//    1. 判据落到 A2JITEnvironment 一处（老 Air 是 utils.m 里的 AMEJITVerifyWritableJITRegion +
//       JIT26IsLikelyDebuggerKeepAttached…）：本模块不重复实现 brk 语义，只决定「什么时候问」。
//    2. 使能器不做「按偏好键选」，改按本机已安装能力探测（理由见头文件）。
//    3. 等待期用 beginBackgroundTask + 切回前台的即时探测（老 Air 同形），
//       但**挂起间隙不计入预算**（老 Air 的 ame169_waitForJITCondition 同款处理）——
//       否则用户进 StikDebug 一趟回来，120s 预算已经被墙钟吃光了。
//

#import "A2JITEnabler.h"

#import <UIKit/UIKit.h>
#import <unistd.h>
#import <stdlib.h>            // getenv（JB_ROOT_PATH）
#import <string.h>
#import <sys/sysctl.h>        // KERN_PROC / KERN_PROC_PID：调试器侧证据（见 ①'' JIT 来源认定）

#import "A2JITEnvironment.h"   // 区域验收快照（logRegionSnapshot，仅日志）
#import "A2LegacyJITGate.h"    // ★唯一判据 = 老 Air（tree510）那套，原样移植★
#import "UIKit+hook.h"         // UIWindow.mainWindow：key window 的唯一取法（不自造第二份）
#import "a2_log.h"             // native 侧判据行出口（与 Air2 的 [A2Log criterion:] 同一落点）

#pragma mark - 常量

/// ★等待期广播（定义）★：App 层据此开关后台保活（见 .h 的说明）。
NSNotificationName const A2JITEnablerWaitingDidBeginNotification =
    @"A2JITEnablerWaitingDidBeginNotification";
NSNotificationName const A2JITEnablerWaitingDidEndNotification =
    @"A2JITEnablerWaitingDidEndNotification";

/// 等待上限：对齐老 Air 的 invokeAfterJITEnabled（120s）。
static const NSTimeInterval kA2JITWaitBudget = 120.0;
/// 已经跳过一次之后的等待上限：★防死循环★ 第二次起不再跳，只给调试器一点收尾时间。
static const NSTimeInterval kA2JITRepeatWaitBudget = 8.0;
/// 轮询间隔：0.5s（老 Air 同量级；再密只是白刷 brk #0x69）。
static const NSTimeInterval kA2JITPollInterval = 0.5;
/// ★回前台强制复查的重新等待预算★：回前台时若墙钟预算已被后台时间吃光，
/// **重新给这么多秒**（★不因为「等过一次」就判死★）—— 用户可能是第二次才在
/// StikDebug 里点对，回来就应当还能被接住，而不是弹失败页。
static const NSTimeInterval kA2JITForegroundRecheckBudget = 10.0;
/// 心跳日志间隔：让真机日志能看出「还在等」而不是「卡死了」。
static const NSTimeInterval kA2JITHeartbeat = 10.0;
/// 弹窗 → 拉起使能器之间的间隔：★顺序有用★ 弹窗先落屏，再 openURL（openURL 会把我们送去
/// 后台；顺序反了弹窗根本没机会显示，用户就只看到「跳走了」）。
static const NSTimeInterval kA2JITAlertLead = 0.4;
/// 脚本名：打包阶段把 Assets/Air2JIT69.js 复制成 Air2.app/universal.js
/// （scripts/gen_xcodeproj.py 的随包阶段）。StikDebug 只认这个名字。
static NSString *const kA2JITScriptName = @"UniversalJIT26.js";

/// TrollStore 分支的等待上限：巨魔机的 JIT 是**安装时**授予的，apple-magnifier:// 只负责
/// 「让 TrollStore 再授予一次」，正常 1~3 秒内就有结论 ⇒ 不给 120s 的长窗口
/// （否则不成的巨魔机会白等到超时，正是用户报的「卡在等待」）。
static const NSTimeInterval kA2JITTrollStoreWaitBudget = 20.0;

/// 定义在 ② 使能器；此处提前声明 —— ①' 的安装源探测要用它的 `apple-magnifier://` URL 问 scheme。
static NSURL *a2jit_url_trollstore(void);

#pragma mark - 使能器种类

typedef NS_ENUM(NSInteger, A2JITEnablerTool) {
    A2JITEnablerToolNone = 0,   ///< 本机没有任何可拉起的使能器（只能人工引导）
    A2JITEnablerToolStikDebug,  ///< stikdebug://（SideStore + StikDebug 环境的常驻)
    A2JITEnablerToolTrollStore, ///< apple-magnifier://（TrollStore 2.x 的 enable-jit）
    A2JITEnablerToolSideStore,  ///< sidestore://sidejit-enable（SideJIT，<17.4 的既有形式）
    A2JITEnablerToolStikJIT,    ///< stikjit://（★会重拉 App★，仅作最后手段）
};

static NSString *a2jit_tool_name(A2JITEnablerTool tool) {
    switch (tool) {
        case A2JITEnablerToolStikDebug:  return @"StikDebug";
        case A2JITEnablerToolTrollStore: return @"TrollStore";
        case A2JITEnablerToolSideStore:  return @"SideStore";
        case A2JITEnablerToolStikJIT:    return @"stikjit";
        case A2JITEnablerToolNone:       break;
    }
    return @"(无)";
}

#pragma mark - ①' 安装源（TrollStore / SideStore / other）

//  ★为什么启动入口必须先分安装源（用户反馈 + 老 Air 的顺序）★
//  QQ 群两位测试者用的是 **TrollStore**：TrollStore 安装时就用 ldid 把内核级 JIT 权限
//  签进了 App（进程一启动就能拿到可执行页），**既不需要调试器 attach，也不需要
//  stikdebug / sidestore / stikjit 那条链**。
//  本模块原来的顺序是「stikdebug → apple-magnifier → sidestore → stikjit」，于是巨魔机：
//    · 装了 StikDebug ⇒ 被送进 stikdebug（给一个本来就有 JIT 的进程再开一次；StikDebug 还要
//      配对文件/目标 IP，多半失败，且会把用户踢到另一个 App 里）；
//    · 没装 StikDebug ⇒ 落到 apple-magnifier，但紧接着仍用「老 Air 闰门」判就绪 ——
//      那条要求「有活的调试器应答 brk #0x69」，巨魔机上根本没有调试器 ⇒ 永远不通过 ⇒
//      卡在「等待 JIT」直到 120s 超时（用户报的「卡住」）。
//  老 Air 的顺序（tree510/Natives/DownloadViewController.m L3891–L4100 `invokeAfterJITEnabled:`）
//  是**先分安装源**：
//      BOOL hasTrollStoreJIT = isTrollStoreInstall();
//      …
//      if (hasTrollStoreJIT) { apple-magnifier://… }    ← 巨魔只走自己这条（不拉 stikdebug）
//      else if (…) { stikdebug / stikjit / sidestore }  ← 其余才走外部使能器
//  本模块照这个顺序实现；判据行统一用 `[A2-JIT-SRC]` 前缀（装的是哪一版、走了哪条路，一眼可辨）。

typedef NS_ENUM(NSInteger, A2JITInstallSource) {
    A2JITInstallSourceOther      = 0,  ///< 普通侧载 / 没有可识别的工具
    A2JITInstallSourceSideStore  = 1,  ///< SideStore / StikDebug 那套（走 stikdebug 链）
    A2JITInstallSourceTrollStore = 2,  ///< TrollStore（自带内核级 JIT，不跳外部工具）
};

static NSString *a2jit_src_name(A2JITInstallSource src) {
    switch (src) {
        case A2JITInstallSourceTrollStore: return @"trollstore";
        case A2JITInstallSourceSideStore:  return @"sidestore";
        case A2JITInstallSourceOther:      break;
    }
    return @"other";
}

/// TrollStore 的磁盘标记：TrollStore 把 App 放在 `<…>/Application/<uuid>/App.app`，并在
/// **同一层**（= bundle 的上一层）放 `_TrollStore`；TrollStore Lite 用 `_TrollStoreLite`。
/// ★这是唯一权威判据★：`jb.pmap_cs.custom_trust` 这种 entitlement 普通侧载签名器也会写，
/// 既会假阳（人人都是巨魔）也会假阴（真巨魔机上值未必是 true），只能当加强证据。
static NSString *_Nullable a2jit_trollstore_marker_path(void) {
    NSArray<NSString *> *names = @[@"_TrollStore", @"_TrollStoreLite"];
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSString *parent = bundle.stringByDeletingLastPathComponent;
    for (NSString *dir in @[parent, bundle]) {   // 上一层优先；bundle 内同放法也认
        for (NSString *name in names) {
            NSString *path = [dir stringByAppendingPathComponent:name];
            if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
        }
    }
    return nil;
}

/// TrollStore 本体的安装位置。沙盒 App 常常读不到 /Applications（读不到**不算**否定证据），
/// 所以这条只作辅助证据；一旦命中就足以认定为巨魔机。
static NSString *_Nullable a2jit_trollstore_app_path(void) {
    NSArray<NSString *> *paths = @[
        @"/Applications/TrollStore.app",      @"/Applications/TrollStoreLite.app",
        @"/var/jb/Applications/TrollStore.app", @"/var/jb/Applications/TrollStoreLite.app",
    ];
    for (NSString *path in paths) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
    }
    return nil;
}

/// 某 URL 能不能被处理。★UIKit 的 canOpenURL 只在主线程问★；
/// 非主线程返回 -1（未知），绝不把「没问成」写成「没有」。
static int a2jit_can_open(NSURL *_Nullable url) {
    if (url == nil) return 0;
    if (![NSThread isMainThread]) return -1;
    return [UIApplication.sharedApplication canOpenURL:url] ? 1 : 0;
}

static NSURL *_Nullable a2jit_url_sidestore_probe(void) {
    return [NSURL URLWithString:@"sidestore://sidejit-enable?pid=0"];
}

static NSURL *_Nullable a2jit_url_stikdebug_probe(void) {
    return [NSURL URLWithString:@"stikdebug://enable-jit"];
}

/// 一次安装源探测的全部取证（★探测面要宽、判定要窄★：每条证据都进日志，判定只认可靠的）。
typedef struct {
    __unsafe_unretained NSString *_Nullable marker;   ///< `_TrollStore` 标记的实际路径（nil = 没找到）
    __unsafe_unretained NSString *_Nullable appPath;  ///< TrollStore 本体路径（nil = 读不到，不构成否定）
    BOOL custTrust;               ///< `jb.pmap_cs.custom_trust`（仅加强证据）
    BOOL kernelJIT;               ///< 内核级 JIT entitlement（csops blob）
    int schemeMagnifier;          ///< apple-magnifier://（1 是 / 0 否 / -1 未问）
    int schemeSideStore;          ///< sidestore://
    int schemeStikDebug;          ///< stikdebug://
    A2JITInstallSource source;
} A2JITSourceFacts;

static A2JITSourceFacts a2jit_source_facts(void) {
    A2JITSourceFacts f = (A2JITSourceFacts){0};
    // 文件 / entitlement 在进程内不会变 ⇒ 只算一次（等待期 0.5s 一轮，别每轮都建 SecTask）。
    static BOOL sDiskComputed = NO;
    static NSString *sMarker = nil;
    static NSString *sAppPath = nil;
    static BOOL sCustTrust = NO;
    static BOOL sKernelJIT = NO;
    if (!sDiskComputed) {
        sDiskComputed = YES;
        sMarker = a2jit_trollstore_marker_path();
        sAppPath = a2jit_trollstore_app_path();
        sCustTrust = A2JITGetEntitlementValue(@"jb.pmap_cs.custom_trust");
        sKernelJIT = a2_jit_has_kernel_level();
    }
    f.marker = sMarker;
    f.appPath = sAppPath;
    f.custTrust = sCustTrust;
    f.kernelJIT = sKernelJIT;
    f.schemeMagnifier = a2jit_can_open(a2jit_url_trollstore());
    f.schemeSideStore = a2jit_can_open(a2jit_url_sidestore_probe());
    f.schemeStikDebug = a2jit_can_open(a2jit_url_stikdebug_probe());

    // 判定（★窄★）：磁盘标记 / TrollStore 本体 = 权威；光有 apple-magnifier:// 还要
    // entitlement 加强（别的工具也可能注册同名 scheme）。
    // ★结论粘住（只增不减）★：scheme 只能在主线程问，而判据也会被等待循环从后台队列调到
    //   ⇒ 后台那一次可能问不出 scheme。安装源是进程级的常量，一旦任一次探测认定为巨魔就
    //   记住，避免「主线程判 trollstore、后台判 other ⇒ 后台又落回老 Air 闰门」这种自相矛盾。
    static BOOL sStickyTrollStore = NO;
    BOOL trollStore = (f.marker != nil) || (f.appPath != nil) ||
                      (f.schemeMagnifier == 1 && f.custTrust);
    if (trollStore) sStickyTrollStore = YES;
    if (sStickyTrollStore) {
        f.source = A2JITInstallSourceTrollStore;
    } else if (f.schemeSideStore == 1 || f.schemeStikDebug == 1) {
        f.source = A2JITInstallSourceSideStore;
    } else {
        f.source = A2JITInstallSourceOther;
    }
    return f;
}

/// 安装源 + 一行带全部证据的判据（`[A2-JIT-SRC]`；进程内只打一次，免得等待期刷屏）。
static A2JITInstallSource a2jit_source(void) {
    A2JITSourceFacts f = a2jit_source_facts();
    static BOOL sLogged = NO;
    if (!sLogged) {
        sLogged = YES;
        a2_log_criterion(@"[A2-JIT-SRC] install-source=%@ marker=%@ trollstore-app=%@ cust_trust=%d "
                         @"kernel-jit=%d apple-magnifier=%d sidestore-scheme=%d stikdebug-scheme=%d "
                         @"reqDebugMapping=%d",
                         a2jit_src_name(f.source),
                         f.marker ?: @"(无)", f.appPath ?: @"(读不到/不否定)",
                         (int)f.custTrust, (int)f.kernelJIT,
                         f.schemeMagnifier, f.schemeSideStore, f.schemeStikDebug,
                         (int)A2LegacyJITGateRequiresDebugMapping());
    }
    return f.source;
}

#pragma mark - ①'' JIT 来源认定（调试器在岗 / 越狱环境）

//  ★以下是新增的两条 JIT 来源认定（排在安装源之后、使能器选择之前）★
//  背景：真机上存在「本进程其实已经能用 JIT，但既没有 TrollStore 标记、也没有使能器可拉起」
//  的机器 —— 以前它们被判「未就绪」⇒ 去拉 stikdebug/sidestore ⇒ 白等 120s 才失败：
//    (a) 调试器在岗：进程被 trace（内核 P_TRACED 置位）。JIT 是**调试器**给的，
//        再拉一个使能器纯属多余（还会把用户踢出 App）；
//    (b) 越狱环境：rootless（/var/jb）/ dpkg 系（/var/lib/dpkg）/ 环境变量显式给 JB_ROOT_PATH。
//        这类机器上 App 由越狱的 ldid 签名、自带内核级 JIT ⇒ 同样不需要使能器。
//  ★它们只决定「就绪」★：建 VM 前的闰门仍是 A2LegacyJITGateOpen（另一个出口，未改）——
//  调试器不给 brk #0x69 时那道闸门照样会拦，不会带着「没真的拿到 JIT」去建 VM。

/// getppid() 的进程名是否含 `debugserver`（**辅助证据**，读不到 / 失败都不影响主判）。
/// ★用 sysctl 而不是 proc_name★：KERN_PROC_PID 的 p_comm 免链接 libproc，且与 P_TRACED 同族接口。
static BOOL a2jit_parent_is_debugserver(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getppid()};
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return NO;
    return strstr(info.kp_proc.p_comm, "debugserver") != NULL;
}

/// (a) 进程是否被调试器 trace。
/// ★P_TRACED 的读取只有一处★：A2LegacyJITGate.m 的 `A2JIT26DebuggerAttachedViaPtrace()`
/// （sysctl KERN_PROC/KERN_PROC_PID 读 `kp_proc.p_flag`）—— 这里**转调**，不复制第二份。
/// ★不用 csops 的 CS_DEBUGGED★：它只说明「签名带了调试权限」，进程没被 trace 时也常置位。
static BOOL a2jit_src_debugger_attached(void) {
    return A2JIT26DebuggerAttachedViaPtrace() || a2jit_parent_is_debugserver();
}

/// (b) 越狱环境。
static BOOL a2jit_src_jailbreak(void) {
    if (getenv("JB_ROOT_PATH") != NULL) return YES;
    return [NSFileManager.defaultManager fileExistsAtPath:@"/var/jb"] ||
           [NSFileManager.defaultManager fileExistsAtPath:@"/var/lib/dpkg"];
}

/// 两条「直接认定可用」的来源合成一条结论：命中 ⇒ 返回可读原因（非 nil）；都不命中 ⇒ nil。
/// ★不缓存判定★：调试器可能在启动**之后**才附加（StikDebug 就是对现成进程 PT_ATTACH），
///   缓存会让晚到的 attach 永远判不出来。★只缓存日志★：等待期 0.5s 一轮，命中项不变就不再打。
static NSString *_Nullable a2jit_direct_source_reason(void) {
    NSString *reason = nil;
    NSString *hit = nil;
    if (a2jit_src_debugger_attached()) {
        hit = @"debugger";
        reason = [NSString stringWithFormat:
                  @"调试器在岗（P_TRACED，ppid=%d）⇒ 直接认定 JIT 可用", getppid()];
    } else if (a2jit_src_jailbreak()) {
        hit = @"jailbreak";
        reason = @"越狱环境（/var/jb | /var/lib/dpkg | JB_ROOT_PATH）⇒ 直接认定 JIT 可用";
    }
    static NSString *sLoggedHit = nil;   // 上次打过日志的命中项（nil = 还没打过）
    if (hit != nil && ![hit isEqualToString:sLoggedHit]) {
        sLoggedHit = hit;
        a2_log_criterion(@"[JIT-SRC] debugger|jailbreak ⇒ 直接放行（命中 %@）：%@；不拉任何外部使能器",
                         hit, reason);
    }
    return reason;
}

/// ★TrollStore 机的 JIT 就绪判定（不需要调试器）★
/// 巨魔机的 JIT 来自**安装时**由 ldid 签进 App 的内核级权限 ⇒ 判据不能是「有没有活的调试器
/// 应答 brk #0x69」（那条在巨魔机上恒假 ⇒ 能玩的环境被自己的闸门拦死）。
/// 三条证据任一成立即就绪，按证据强度降序：
///   ① 老 Air 闰门自己放行（非镜像机型直接放行；恰好有调试器在岗时的握手也算）；
///   ② 内核级 JIT entitlement（csops blob 里的 com.apple.private.cs.debugger /
///      dynamic-codesigning）—— 这正是 TrollStore 签名的产物，也是它 JIT 的来源；
///   ③ 执行式探针真的跑通一页（★真执行★；没有权限时探针自己会跳过，不会赌）。
static BOOL a2jit_trollstore_ready(NSString *_Nullable *_Nullable whyOut) {
    NSString *gateWhy = nil;
    if (A2LegacyJITGateReadyNow(&gateWhy)) {
        if (whyOut) *whyOut = [NSString stringWithFormat:@"老 Air 闰门放行（%@）", gateWhy ?: @"—"];
        return YES;
    }
    if (a2_jit_has_kernel_level()) {
        if (whyOut) *whyOut = @"内核级 JIT entitlement（com.apple.private.cs.debugger / "
                              @"dynamic-codesigning）已随 TrollStore 安装授予 ⇒ 无需调试器代映射";
        return YES;
    }
    A2JITExecProbeResult probe = a2_jit_exec_probe_anonymous();
    if (probe == A2JITExecProbeExecOK) {
        if (whyOut) *whyOut = @"exec-probe 真执行一页通过（本进程确实能执行 JIT 页）";
        return YES;
    }
    if (whyOut) *whyOut = [NSString stringWithFormat:
        @"还没拿到 JIT（内核级 entitlement=%d；exec-probe=%ld；闰门：%@）",
        (int)a2_jit_has_kernel_level(), (long)probe, gateWhy ?: @"—"];
    return NO;
}

#pragma mark - ①''' JIT 启动器偏好（用户可选来源：a2jit.preferredSource）

//  ★为什么要有这一档★
//  真机上「拿到 JIT」有六条互不相干的路（调试器 attach / 越狱环境的 ldid 签名 / TrollStore /
//  StikDebug / SideStore / 上面那套自动探测）。自动探测的取舍对多数人够用，但对「我明明是开着
//  调试器就能玩，它偏把我踢去 StikDebug」这类问题，用户需要一个能**钉死来源**的开关：
//  选中哪一条就只用哪一条；该来源不可用 ⇒ 直接失败并说明原因。
//  ★绝不静默回退★：静默回退正是「用户无法判断到底是谁在给我 JIT」的根源。
//
//  ★读取点唯一★：NSUserDefaults 的读取只在本文件的 `a2jit_preferred_source()` 一处。
//  调用点（三处，全是判定 / 拉起入口）：
//    ① `a2jit_ready_now()`           —— 判据按选中的来源分流（不成立即 NO + 原因）；
//    ② `a2jit_pick_enabler()`        —— 使能器只在选中的来源里挑（挑不到就 None + 原因）；
//    ③ `a2jit_start_preferred_run()` —— 非 auto 的流程守卫（不让安装源分支把来源抢走）。
//
//  ★六个取值是跨层契约★（NSUserDefaults 里存的就是它们，逐字相同）：
//    `auto` `debugger` `jailbreak` `trollstore` `stikdebug` `sidestore`
//  写入点 = `Air2/UI/Screens/Settings/A2JITSettings.m` 的「JIT 启动器」行；
//  改这六个串必须同时改那里（那边有对应的四语文案表项）。

typedef NS_ENUM(NSInteger, A2JITPreferredSource) {
    A2JITPreferredSourceAuto       = 0,  ///< 自动（★默认★ = 本模块既有行为，一行未改）
    A2JITPreferredSourceDebugger   = 1,  ///< 只用调试器 attach（lldb / Xcode）
    A2JITPreferredSourceJailbreak  = 2,  ///< 只用越狱环境（/var/jb、/var/lib/dpkg、JB_ROOT_PATH）
    A2JITPreferredSourceTrollStore = 3,  ///< 只用 TrollStore（apple-magnifier://）
    A2JITPreferredSourceStikDebug  = 4,  ///< 只用 StikDebug（stikdebug://）
    A2JITPreferredSourceSideStore  = 5,  ///< 只用 SideStore（sidestore://；不可用时才用 stikjit://）
};

/// ★键名唯一定义处★（六个取值见上面那段契约说明）。
static NSString *const kA2JITPreferredSourceKey = @"a2jit.preferredSource";

static NSString *a2jit_preferred_source_name(A2JITPreferredSource src) {
    switch (src) {
        case A2JITPreferredSourceDebugger:   return @"debugger";
        case A2JITPreferredSourceJailbreak:  return @"jailbreak";
        case A2JITPreferredSourceTrollStore: return @"trollstore";
        case A2JITPreferredSourceStikDebug:  return @"stikdebug";
        case A2JITPreferredSourceSideStore:  return @"sidestore";
        case A2JITPreferredSourceAuto:       break;
    }
    return @"auto";
}

/// ★唯一读取点★：缺键 / 空串 ⇒ auto（默认）；六个契约值以外 ⇒ 也按 auto，但如实记一行
/// （不把「用户写了个错值」悄悄当成默认值 —— 那是又一处「到底是谁在给我 JIT」的黑箱）。
/// ★不做缓存★：设置页改完即写盘，下次判定就该按新值（本进程内改也能立刻生效）。
static A2JITPreferredSource a2jit_preferred_source(void) {
    NSString *raw = [NSUserDefaults.standardUserDefaults stringForKey:kA2JITPreferredSourceKey];
    if (raw.length == 0) return A2JITPreferredSourceAuto;   // 缺省当 auto
    if ([raw isEqualToString:@"debugger"])   return A2JITPreferredSourceDebugger;
    if ([raw isEqualToString:@"jailbreak"])  return A2JITPreferredSourceJailbreak;
    if ([raw isEqualToString:@"trollstore"]) return A2JITPreferredSourceTrollStore;
    if ([raw isEqualToString:@"stikdebug"])  return A2JITPreferredSourceStikDebug;
    if ([raw isEqualToString:@"sidestore"])  return A2JITPreferredSourceSideStore;
    if ([raw isEqualToString:@"auto"])       return A2JITPreferredSourceAuto;
    static NSString *sLoggedUnknown = nil;
    if (![raw isEqualToString:sLoggedUnknown]) {
        sLoggedUnknown = raw;
        a2_log_criterion(@"[JIT-SRC] preferred=%@ ⇒ 未知取值，按 auto 处理（键 %@；合法值见 A2JITSettings）",
                         raw, kA2JITPreferredSourceKey);
    }
    return A2JITPreferredSourceAuto;
}

#pragma mark - [JIT-DETACH-STIKDEBUG] 「JIT 就绪后主动 detach + self-mmap 兜底」的生效判据

//  ★为什么要一个「总开关」而不是只看来源★
//  这两条新行为（JIT 一就绪就让调试器脱离、调试器不认 detach 就自己 mmap 一块 RWX）都会
//  **改动真实运行行为**：前者会让调试器提前撒手（后续 brk #0x69 没人应答），后者换掉
//  code cache 的来源。它们只在「用户明确选了 StikDebug 这条路」时才有意义（StikDebug
//  开完 JIT 会一直占着调试器，正是这两个动作要解决的），其他来源上照做只会平白引入
//  调试器提前脱离 / 自 map 越权的风险 ⇒ 用开关 + 来源双条件把它钉住：
//    条件① 开关（本键，默认关）  ② 来源严格 == stikdebug（走唯一读取点 a2jit_preferred_source）
//  ★不成立就完全按旧行为走★（A2JITEnvironment 里两条新逻辑一个字节都不执行）。
NSString *const A2JITLauncherEnabledKey = @"a2jit.launcherEnabled";

BOOL a2jit_detach_selfmmap_armed(void) {
    // ① 开关：缺键当 NO（不给存量装机偷偷换行为）
    id raw = [NSUserDefaults.standardUserDefaults objectForKey:A2JITLauncherEnabledKey];
    BOOL on = (raw == nil) ? NO
                           : [NSUserDefaults.standardUserDefaults boolForKey:A2JITLauncherEnabledKey];
    if (!on) return NO;
    // ② 来源：★只问 a2jit_preferred_source()★，不在这里再读一遍 a2jit.preferredSource
    return a2jit_preferred_source() == A2JITPreferredSourceStikDebug;
}

/// 每次决策一行：`[JIT-SRC] preferred=<值> ⇒ <命中/失败原因>`。
/// ★同一结论只打一次★：判据在等待期 0.5s 一轮，逐轮重打只会把日志刷成噪音
/// （与 a2jit_direct_source_reason 的「只缓存日志」同一处理）。
static void a2jit_log_decision(A2JITPreferredSource src, BOOL hit, NSString *_Nullable detail) {
    NSString *line = [NSString stringWithFormat:@"[JIT-SRC] preferred=%@ ⇒ %@：%@",
                      a2jit_preferred_source_name(src), hit ? @"命中" : @"失败", detail ?: @"—"];
    static NSString *sLastLine = nil;
    if ([line isEqualToString:sLastLine]) return;
    sLastLine = line;
    a2_log_criterion(@"%@", line);
}

/// 非 auto：本进程现在能不能建 VM —— ★只按选中的那一条来源判★（不做任何跨来源补位）。
/// 判据本身一律复用既有实现（不新造第二套）：调试器 / 越狱 = ①'' 那两条；TrollStore =
/// `a2jit_trollstore_ready`；StikDebug / SideStore = 老 Air 闰门 `A2LegacyJITGateReadyNow`
/// （它们拿到 JIT 的唯一形式就是「调试器代映射 + brk #0x69 被服务」）。
static BOOL a2jit_preferred_ready_now(A2JITPreferredSource src, NSString *_Nullable *_Nullable whyOut) {
    switch (src) {
        case A2JITPreferredSourceDebugger:
            if (a2jit_src_debugger_attached()) {
                if (whyOut) *whyOut = [NSString stringWithFormat:
                    @"调试器在岗（P_TRACED / ppid=debugserver，ppid=%d）⇒ 直接认定 JIT 可用", getppid()];
                return YES;
            }
            if (whyOut) *whyOut = @"需先用调试器附加（lldb attach / Xcode 调试）：本进程当前没有被 trace";
            return NO;

        case A2JITPreferredSourceJailbreak:
            if (a2jit_src_jailbreak()) {
                if (whyOut) *whyOut = @"越狱环境（/var/jb | /var/lib/dpkg | JB_ROOT_PATH）⇒ 直接认定 JIT 可用";
                return YES;
            }
            if (whyOut) *whyOut = @"未检测到越狱环境（/var/jb、/var/lib/dpkg、JB_ROOT_PATH 都不存在）";
            return NO;

        case A2JITPreferredSourceTrollStore:
            return a2jit_trollstore_ready(whyOut);

        case A2JITPreferredSourceStikDebug:
        case A2JITPreferredSourceSideStore:
            return A2LegacyJITGateReadyNow(whyOut);

        case A2JITPreferredSourceAuto:
            break;
    }
    // auto 不该走到这里（调用方已分流）；真走到就如实返回 NO，不假装就绪。
    if (whyOut) *whyOut = @"auto 不走「单一来源」判定";
    return NO;
}

#pragma mark - ① 判据

/// 本进程是否「被调试器 / 使能器拉起」（getppid() ≠ 1）。
/// ★★只用于防死循环，绝不用于判就绪★★：
///   被重拉起来只说明「外部注入这件事正在发生」，**不证明我们手里已经有可执行 JIT 区**。
///   以前把它当就绪 ⇒ stikjit 重拉后即使区没拿到也放行建 VM（首帧 SIGBUS）。
///   现在它只影响一件事：★要不要再跳一次★（见 ensureJITThen: 的 alreadyJumped）。
static BOOL a2jit_launched_by_debugger(void) {
    return getppid() != 1;
}

/// 判据行里 region 的验收出口（★唯一格式★）：`[A2JIT] region=… size=… (X MB) expected=… enough=0|1`。
/// 建 VM 前 / 建 VM 后 / 判据三步都走这一处 ⇒ 真机 grep `[A2JIT] region=` 即可核对「拿到的是 64MB 还是一页/没有」。
static void a2jit_log_region(const char *tag) {
    void *region = [A2JITEnvironment verifiedRegion];
    size_t got  = [A2JITEnvironment verifiedRegionBytes];
    size_t want = [A2JITEnvironment expectedRegionBytes];
    a2_jit_log("[A2JIT] region=%p size=%zu (%.2f MB) expected=%zu (%.2f MB) enough=%d "
               "debugged=%d tag=%s",
               region, got, (double)got / (1024.0 * 1024.0),
               want, (double)want / (1024.0 * 1024.0),
               (region != NULL && got >= want) ? 1 : 0,
               (int)a2_jit_is_debugged(), tag);
}

/// ★唯一判据：老 Air（tree510）那一套 —— Natives/Support/A2LegacyJITGate 原样移植★
///
/// ★已删除 Air2 自己发明的「放行优先四条」★（entitlement / CS_DEBUGGED / verifiedRegion /
/// exec-probe 任一即放行）。它们在真机上反复给出错误结论（先死后放、放行后仍闪退）：
///   · entitlement 只说明「这种装机方式**有能力**提供 JIT」，不代表本进程现在能用；
///   · Air2 那条 `CS_DEBUGGED` 读的是 `0x100`（内核里那是 `CS_HARD`），老 Air 读的是
///     `0x10000000` ⇒ 这一条恒错（永远判不出「调试器在岗」）；
///   · iOS 26+ 的 JIT 区是**建 VM 时 libjvm 自己发 `brk #0x69`** 才到手的 ⇒ 建 VM 之前
///     `verifiedRegion` 几乎永远为空；把「能力声明」当「已验证」放行 ⇒ 首帧 SIGBUS。
///
/// 现在的语义 = 老 Air 的 `AMEJITWaitReadyVerified()`（逐字搬运）：
///   · 非镜像设备（< iOS 26）⇒ 直接放行（老 Air 的闰门整块被跳过，不闸）；
///   · 镜像设备（iOS 26+）⇒ ① 调试器必须真的在岗
///     （`ppid≠1` / `P_TRACED` / 任务级 BREAKPOINT·SOFTWARE 异常端口 三探针任一）；
///     ② 且 `brk #0x69` 真的被服务过（Universal 基础脚本回的哨兵 `0x690000E0`
///     也算应答 —— 它正是老 Air 要求的值）。
/// why = 可读原因（凭哪一条放行 / 为什么不成），整段文案由 A2LegacyJITGate 给出。
static BOOL a2jit_ready_now(NSString *_Nullable *_Nullable why) {
    // ★JIT 启动器偏好（`a2jit.preferredSource`）★：选中非 auto ⇒ ★只按那一条来源判★
    //   （不成立的来源就是「本次没拿到 JIT」，由调用方出失败页并说明缺什么）；★绝不回退★。
    //   auto ⇒ 下面既有的三段顺序一字未改（这是默认行为，任何改动都是回归风险）。
    A2JITPreferredSource preferred = a2jit_preferred_source();
    if (preferred != A2JITPreferredSourceAuto) {
        NSString *preferredWhy = nil;
        BOOL preferredOK = a2jit_preferred_ready_now(preferred, &preferredWhy);
        a2jit_log_decision(preferred, preferredOK, preferredWhy);
        if (why) *why = preferredWhy;
        return preferredOK;
    }
    // ★新来源优先（[JIT-SRC]）★：调试器在岗 / 越狱环境 ⇒ 直接认定可用，
    //   ★不拉任何外部使能器★（`ensureJITThen:` 的「① 判据再确认」就走这里 ⇒ 立刻
    //   回调 YES 交回启动链，既不弹等待窗也不 openURL）。
    //   ★顺序★：这两条在前，其后才是既有的 trollstore / sidestore 分支（一行未改）。
    NSString *directWhy = a2jit_direct_source_reason();
    if (directWhy != nil) {
        if (why) *why = directWhy;
        return YES;
    }
    // ★安装源分支（[A2-JIT-SRC]）★：TrollStore 机的 JIT 不是「调试器代映射」来的
    //   ⇒ 不能用老 Air 闰门（那条要求有活的调试器应答 brk #0x69，巨魔机上恒假 ⇒
    //   会一直卡在「等待 JIT」）。其余环境（SideStore / 无工具）判据一字不改。
    if (a2jit_source() == A2JITInstallSourceTrollStore) {
        return a2jit_trollstore_ready(why);
    }
    return A2LegacyJITGateReadyNow(why);
}

#pragma mark - ② 使能器（URL 选择 + 回退顺序）

/// 百分号转义：bundle-id 里可能有点与横线，Query 允许集已覆盖；这里统一走一遍，
/// 避免以后出现奇怪字符时 URL 变成 nil（nil 会被 canOpenURL 当成「没装」）。
static NSString *a2jit_pct(NSString *s) {
    return [s stringByAddingPercentEncodingWithAllowedCharacters:
            NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";
}

static NSString *a2jit_bundle_id(void) {
    return NSBundle.mainBundle.bundleIdentifier ?: @"";
}

/// stikdebug://enable-jit?bundle-id=&pid=&script-name=UniversalJIT26.js
/// ★参数名一字不差★（老 Air JavaLauncher.m 的 stikdebug 分支；我们此前写成
/// bundle_id/script/return 时 StikDebug 不认）。用 script-name 指向包内脚本，
/// 不内联 base64 —— 只有注册了 stikdebug:// 的 StikDebug 版本支持这条。
static NSURL *a2jit_url_stikdebug(void) {
    return [NSURL URLWithString:[NSString stringWithFormat:
        @"stikdebug://enable-jit?bundle-id=%@&pid=%d&script-name=%@",
        a2jit_pct(a2jit_bundle_id()), (int)getpid(), a2jit_pct(kA2JITScriptName)]];
}

/// apple-magnifier://enable-jit?bundle-id=（TrollStore 2.0.12+ 的 JIT 入口）
static NSURL *a2jit_url_trollstore(void) {
    return [NSURL URLWithString:[NSString stringWithFormat:
        @"apple-magnifier://enable-jit?bundle-id=%@", a2jit_pct(a2jit_bundle_id())]];
}

/// sidestore://sidejit-enable?pid=（SideJIT；与老 Air <17.4 分支同形）
static NSURL *a2jit_url_sidestore(void) {
    return [NSURL URLWithString:[NSString stringWithFormat:
        @"sidestore://sidejit-enable?pid=%d", (int)getpid()]];
}

/// stikjit://enable-jit?bundle-id=&pid=&script-data=<base64>
/// ★最后手段★：这条会**重新拉起 App**（老 Air 的 @available(iOS 17.4) 分支）。
/// 重拉后的新进程 ppid≠1 ⇒ 判据第一条直接认，不会二次跳转（死循环由此断开）。
static NSURL *a2jit_url_stikjit(void) {
    NSString *scriptData = @"";
    NSData *script = [NSData dataWithContentsOfFile:
        [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Air2JIT69.js"]];
    if (script.length > 0) {
        scriptData = [@"&script-data=" stringByAppendingString:
                      [script base64EncodedStringWithOptions:0]];
    }
    return [NSURL URLWithString:[NSString stringWithFormat:
        @"stikjit://enable-jit?bundle-id=%@&pid=%d%@",
        a2jit_pct(a2jit_bundle_id()), (int)getpid(), scriptData]];
}

/// ★回退顺序就是这里的数组顺序★（为什么是这个顺序，不是随便排的）：
///   1. stikdebug —— SideStore+StikDebug 环境的主力，**不重拉进程**，参数最完整；
///   2. apple-magnifier —— TrollStore 装机自带 JIT，同样不重拉；
///   3. sidestore —— SideJIT 老形式，同样不重拉（iOS 17.0–17.3 唯一可用的一条）；
///   4. stikjit —— **会重拉 App**，用户会被踢出启动流程，故放最后。
/// 全部 canOpenURL=NO ⇒ None：不白等 120s，直接给可读原因（老 Air 的 MissingTool 同款处理）。
///
/// ★JIT 启动器偏好（`a2jit.preferredSource`）★：用户钉死来源时★只在选中的那条里挑★，
/// 挑不到就 None + `whyOut`（★不回退到别的来源★）；auto 走下面的既有数组顺序（一字未改）。
static A2JITEnablerTool a2jit_pick_enabler(NSURL *_Nullable *_Nullable urlOut,
                                          NSString *_Nullable *_Nullable whyOut) {
    if (urlOut) *urlOut = nil;
    if (whyOut) *whyOut = nil;

    A2JITPreferredSource preferred = a2jit_preferred_source();
    if (preferred != A2JITPreferredSourceAuto) {
        // 该来源下允许的候选（最多两条：sidestore 档的 sidestore:// + stikjit:// 属同一家）。
        NSURL *candidates[2] = { nil, nil };
        A2JITEnablerTool tools[2] = { A2JITEnablerToolNone, A2JITEnablerToolNone };
        switch (preferred) {
            case A2JITPreferredSourceTrollStore:
                candidates[0] = a2jit_url_trollstore();
                tools[0] = A2JITEnablerToolTrollStore;
                break;
            case A2JITPreferredSourceStikDebug:
                candidates[0] = a2jit_url_stikdebug();
                tools[0] = A2JITEnablerToolStikDebug;
                break;
            case A2JITPreferredSourceSideStore:
                candidates[0] = a2jit_url_sidestore();
                tools[0] = A2JITEnablerToolSideStore;
                candidates[1] = a2jit_url_stikjit();
                tools[1] = A2JITEnablerToolStikJIT;
                break;
            case A2JITPreferredSourceDebugger:
            case A2JITPreferredSourceJailbreak:
            case A2JITPreferredSourceAuto:
                break;   // 调试器 / 越狱没有「可拉起的使能器」（JIT 不是外部工具给的）
        }
        for (size_t i = 0; i < sizeof(tools) / sizeof(tools[0]); i++) {
            NSURL *url = candidates[i];
            if (url == nil || tools[i] == A2JITEnablerToolNone) continue;
            if (a2jit_can_open(url) == 1) {
                if (urlOut) *urlOut = url;
                return tools[i];
            }
        }
        if (whyOut) {
            if (preferred == A2JITPreferredSourceDebugger || preferred == A2JITPreferredSourceJailbreak) {
                *whyOut = [NSString stringWithFormat:
                    @"所选 JIT 启动器＝%@ 不靠外部工具 ⇒ %@",
                    a2jit_preferred_source_name(preferred),
                    preferred == A2JITPreferredSourceDebugger
                        ? @"需先用调试器附加（本进程未被 trace）"
                        : @"未检测到越狱环境"];
            } else {
                *whyOut = [NSString stringWithFormat:
                    @"所选 JIT 启动器＝%@ 在本机打不开（未安装，或它的 URL scheme 未被处理）；"
                    @"★按所选来源如实失败，不回退到其它工具★",
                    a2jit_preferred_source_name(preferred)];
            }
        }
        return A2JITEnablerToolNone;
    }

    NSURL *(*builders[])(void) = { a2jit_url_stikdebug, a2jit_url_trollstore,
                                   a2jit_url_sidestore, a2jit_url_stikjit };
    A2JITEnablerTool tools[] = { A2JITEnablerToolStikDebug, A2JITEnablerToolTrollStore,
                                 A2JITEnablerToolSideStore, A2JITEnablerToolStikJIT };
    for (size_t i = 0; i < sizeof(tools) / sizeof(tools[0]); i++) {
        NSURL *url = builders[i]();
        if (url == nil) continue;
        // canOpenURL 必须带 Info.plist 的 LSApplicationQueriesSchemes 白名单
        // （stikdebug / stikjit / sidestore / stosdebug / apple-magnifier 已登记）。
        if ([UIApplication.sharedApplication canOpenURL:url]) {
            if (urlOut) *urlOut = url;
            return tools[i];
        }
    }
    if (urlOut) *urlOut = nil;
    return A2JITEnablerToolNone;
}

#pragma mark - ③ 等待（本进程单次在途）

/// 一次「申请 + 等待」的状态。用对象承载（而不是散落的文件级变量），
/// 生命周期 = 从 ensureJITThen: 到回调；收尾时一次性撤销 observer / 弹窗 / 后台断言。
@interface A2JITEnablerRun : NSObject

@property (nonatomic, strong) NSMutableArray<void (^)(BOOL)> *completions;
@property (nonatomic, assign) NSTimeInterval deadline;      // 绝对时刻（timeIntervalSince1970）
@property (nonatomic, assign) NSTimeInterval lastTick;
@property (nonatomic, assign) NSTimeInterval lastHeartbeat;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL probeInFlight;           // 上一发探针还没回来 ⇒ 本轮跳过
@property (nonatomic, assign) NSUInteger probeGeneration;       // 在途探针的代号（0 = 没有在途）
@property (nonatomic, assign) BOOL enablerLaunched;          // ★one-shot★ 使能器只拉起一次
@property (nonatomic, assign) BOOL armedAutoLaunch;          // 是否置过「重挂后自动继续」标记
@property (nonatomic, assign) BOOL inBackground;            // ★后台期间只保活：不复查、不烧预算★
@property (nonatomic, assign) NSUInteger foregroundRechecks;   // 回前台强制复查的次数（判据行用）
@property (nonatomic, assign) BOOL foregroundRecheckPending;   // 这次复查就是「回前台」来的
@property (nonatomic, assign) BOOL waitingBroadcasted;          // 已广播「开始等」⇒ 收尾时才广播「结束」
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, strong) UIAlertController *alert;
@property (nonatomic, strong) NSMutableArray<id> *observers;   // 前台/后台切换的观察者（收尾一次撤销）
@property (nonatomic, copy) NSString *lastWhy;              // 最近一次判据原因（失败页用）

- (void)addCompletion:(void (^)(BOOL))block;
- (void)finishWithOK:(BOOL)ok reason:(NSString *)reason;
- (void)startWaitingWithBudget:(NSTimeInterval)budget
                          tool:(A2JITEnablerTool)tool
                    enablerURL:(NSURL *_Nullable)url;
- (void)openEnablerURL:(NSURL *)url tool:(A2JITEnablerTool)tool;
- (void)scheduleNextTick;
- (void)tickForced:(BOOL)forced;
- (void)enterBackground;
- (void)foregroundRecheck;

@end

/// ★在途的那一次★（同一时刻最多一个；并发调用挂到同一次等待上）。
static A2JITEnablerRun *gA2JITRun = nil;
/// ★防死循环的第二条铁律★：本进程是否已经**尝试过**一次跳转（拉起请求发出前置位；
/// 有效失败不影响它 —— 「试过就不再试」才是断环的关键）。
static BOOL gA2JITJumpedThisProcess = NO;
/// 最近一次失败原因（给 lastFailureReason 读）。
static NSString *gA2JITLastFailure = nil;

#pragma mark - ②' 非 auto 的申请通道（钉死来源，不回退）

/// ★`ensureJITThen:` 的偏好分岔★：非 auto ⇒ 只走选中的那一条来源。
/// 由 `ensureJITThen:` 在「判据再确认」失败之后、安装源分支之前调用。
///
/// 返回值：YES = 已接管本次申请（要么已用可读原因收尾，要么已起等待并 return）；
///         NO  = 用户选的是 auto ⇒ 调用方继续跑既有流程（★auto 一字未改★）。
///
/// 语义（★钉死来源 = 不回退★）：
///   · debugger / jailbreak：这两种来源没有可拉起的使能器 ⇒ 判据不成即失败，原因里直接写
///     「需先用调试器附加」/「未检测到越狱环境」（★不落到 stikdebug 去白等 120s★）；
///   · trollstore / stikdebug / sidestore：只拉起该来源的 URL（sidestore 档允许 stikjit，
///     两者同属 SideStore 那一家）；打不开 ⇒ 直接失败并点名（★不回退到 stikdebug★）。
static BOOL a2jit_start_preferred_run(A2JITEnablerRun *run,
                                      BOOL alreadyJumped,
                                      NSString *_Nullable judgeWhy) {
    A2JITPreferredSource preferred = a2jit_preferred_source();
    if (preferred == A2JITPreferredSourceAuto) return NO;

    NSString *name = a2jit_preferred_source_name(preferred);
    NSString *why = judgeWhy.length > 0 ? judgeWhy : @"判据未通过";

    // ① 调试器 / 越狱：判据不成立就没有下一步可做（闸门只认「调试器真的在岗」）。
    //    ★决策行已在 a2jit_ready_now 里打过（同一结论去重）★，这里只负责收尾。
    if (preferred == A2JITPreferredSourceDebugger || preferred == A2JITPreferredSourceJailbreak) {
        [run finishWithOK:NO reason:[NSString stringWithFormat:@"所选 JIT 启动器＝%@：%@", name, why]];
        return YES;
    }

    // ② 同一进程只请求一次（铁律②）：已请求过 ⇒ 只短等，不再拉起第二个使能器。
    if (alreadyJumped) {
        a2_log_criterion(@"[JIT-SRC] preferred=%@ ⇒ 本进程已请求过一次（ppid=%d）⇒ 不再拉起，"
                         @"只短等 %.0fs；%@", name, getppid(), kA2JITRepeatWaitBudget, why);
        [run startWaitingWithBudget:kA2JITRepeatWaitBudget tool:A2JITEnablerToolNone enablerURL:nil];
        return YES;
    }

    // ③ 只在选中的来源里挑 URL（挑不到 ⇒ None + 原因，不回退）。
    NSURL *url = nil;
    NSString *pickWhy = nil;
    A2JITEnablerTool tool = a2jit_pick_enabler(&url, &pickWhy);
    if (tool == A2JITEnablerToolNone) {
        NSString *reason = pickWhy.length > 0 ? pickWhy
            : [NSString stringWithFormat:@"所选 JIT 启动器＝%@ 不可用", name];
        a2jit_log_decision(preferred, NO, reason);
        [run finishWithOK:NO reason:reason];
        return YES;
    }

    // ④ 预算按来源给：巨魔的 JIT 是安装时授予的（秒级），其余要用户去使能器里点（120s）。
    NSTimeInterval budget = (tool == A2JITEnablerToolTrollStore) ? kA2JITTrollStoreWaitBudget
                                                                 : kA2JITWaitBudget;
    a2jit_log_decision(preferred, YES,
                       [NSString stringWithFormat:@"拉起 %@：%@", a2jit_tool_name(tool), url.absoluteString]);
    gA2JITJumpedThisProcess = YES;
    [run startWaitingWithBudget:budget tool:tool enablerURL:url];
    return YES;
}

@implementation A2JITEnablerRun

- (instancetype)init {
    self = [super init];
    if (self) {
        _completions = [NSMutableArray array];
        _observers = [NSMutableArray array];
        _bgTask = UIBackgroundTaskInvalid;
    }
    return self;
}

- (void)addCompletion:(void (^)(BOOL))block {
    if (block) [self.completions addObject:[block copy]];
}

- (void)finishWithOK:(BOOL)ok reason:(NSString *)reason {
    if (self.finished) return;   // 幂等：超时 / 取消 / 成功 只认第一次
    self.finished = YES;
    self.probeInFlight = NO;
    gA2JITLastFailure = ok ? nil : (reason.length > 0 ? reason : @"未拿到 JIT");
    // 本进程活着走到收尾 ⇒ 那次「重挂后自动继续」标记不再有用（重拉没发生 / 已经继续过了）。
    // 不清会把「下次冷启动自动起游戏」留成一颗雷。
    if (self.armedAutoLaunch) {
        self.armedAutoLaunch = NO;
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"A2AutoLaunchAfterJIT"];
        [NSUserDefaults.standardUserDefaults synchronize];
    }

    // ★撤销前台/后台观察者★（一次等待的全部观察者都在这里收尾，避免下一次等待叠两套）
    for (id token in self.observers) {
        [NSNotificationCenter.defaultCenter removeObserver:token];
    }
    [self.observers removeAllObjects];
    if (self.alert != nil) {
        UIAlertController *alert = self.alert;
        self.alert = nil;
        // ★照老 Air：先撤等待 UI，再启动游戏★（无动画，立即消失，避免动画期间已进链）
        [alert dismissViewControllerAnimated:NO completion:nil];
    }
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }

    // ★广播「等待结束」⇒ 上层停保活★（拿到 JIT / 超时 / 取消 / 使能器打不开，四个出口都过这里）。
    //   必须先于完成回调发出：回调里会重新进入启动链（建 VM + 起游戏），音频保活不该跟着进去。
    //   ★只在真的广播过「开始等」时才发★：`ensureJITThen:` 的「一开始就绪」短路没有开过保活，
    //   那时发一条「结束」只会让上层白跑一次 Stop() 并打一条误导性的判据行。
    if (self.waitingBroadcasted) {
        self.waitingBroadcasted = NO;
        [NSNotificationCenter.defaultCenter postNotificationName:A2JITEnablerWaitingDidEndNotification
                                                          object:self];
    }

    NSArray<void (^)(BOOL)> *blocks = [self.completions copy];
    [self.completions removeAllObjects];
    if (gA2JITRun == self) gA2JITRun = nil;

    a2_log_criterion(@"[A2-JIT-ENABLER] %@（%@）",
                     ok ? @"已拿到 JIT ⇒ 交回启动链" : @"没拿到 JIT ⇒ 回调失败，不建 VM", reason);
    for (void (^block)(BOOL) in blocks) block(ok);
}

/// 「正在等待 JIT」弹窗 + 保活 + 轮询起点。
///
/// ★顺序（照老 Air 的 invokeAfterJITEnabled，一步都不能换）★
///   ① 先把弹窗放上屏幕（animated:NO ⇒ 同一帧可见，不等动画）；
///   ② 本次启动到此为止 —— 调用方（启动闸门）在调用 `ensureJITThen:` 之后已 return，
///      这里不做任何「继续启动」的事，也绝不建 VM；
///   ③ 之后（kA2JITAlertLead 秒）才 openURL 拉起使能器；
///   ④ 再进入 0.5s 轮询。
/// 反过来做过（先 openURL 再弹窗）：openURL 立刻把本进程送后台，弹窗没机会显示，
/// 用户只看到「App 跳走了又回来」，日志里也没有任何「在等什么」的证据。
///
/// ★失败页不在这里★：本弹窗只解释「正在等」，拿不到 JIT 之后由上层出失败页。
- (void)startWaitingWithBudget:(NSTimeInterval)budget
                          tool:(A2JITEnablerTool)tool
                    enablerURL:(NSURL *_Nullable)url {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    self.deadline = now + budget;
    self.lastTick = now;
    self.lastHeartbeat = now;

    NSString *message = nil;
    if (tool == A2JITEnablerToolNone || url == nil) {
        // 已经跳过一次（防死循环）⇒ 不再拉起任何东西，只解释「在等什么」。
        message = [NSString stringWithFormat:
            @"本进程已经拉起过一次 JIT 使能器。\n请确认它已为 Air2 开启 JIT，然后回到 Air2 —— 拿到 JIT 会自动继续启动。\n（最多再等 %.0f 秒）",
            budget];
    } else if (tool == A2JITEnablerToolTrollStore) {
        // ★巨魔机专用文案★：不引导用户「去 StikDebug」（他们不需要，也不该被引向一个
        //   多半用不了的工具）。TrollStore 若没把 URL Scheme 打开，apple-magnifier:// 打不开，
        //   这里把「该去哪儿开」说清楚。
        message = [NSString stringWithFormat:
            @"已让 TrollStore 重新为 Air2 授予 JIT。\n若 TrollStore 弹出设置页，请确认已为本 App 启用 JIT"
            @"（必要时在 TrollStore 设置里打开 URL Scheme），然后回到 Air2 —— 拿到 JIT 会自动继续启动。\n"
            @"（最多等 %.0f 秒）", budget];
    } else {
        message = [NSString stringWithFormat:
            @"已让 %@ 为 Air2 开启 JIT。\n请按它的提示完成授权，然后回到 Air2 —— 拿到 JIT 会自动继续启动。\n（最多等 %.0f 秒）",
            a2jit_tool_name(tool), budget];
    }
    UIViewController *top = UIWindow.mainWindow.rootViewController;
    while (top.presentedViewController != nil) top = top.presentedViewController;
    // ★绝不弹空壳★：标题与正文都必须有内容。
    //   此前这里是 `message:@""` —— 上面精心拼好的说明文字被整段丢掉，
    //   用户在屏幕上只看到一个「取消」大按钮、正文全空的窗口，既不知道在等什么，
    //   也不知道要做什么。本弹窗会盖在当前最上层页面（含安装/进度页）之上，
    //   所以「安装页冒出空壳弹窗」的真身就是这里。
    NSString *alertTitle = @"等待 JIT";
    NSString *alertMessage = message.length ? message
        : @"正在等待 JIT 生效。\n请按提示为 Air2 开启 JIT，拿到后会自动继续启动。\n（点「取消」可中止本次启动）";
    if (alertTitle.length == 0 && alertMessage.length == 0) {
        // 兜底：两个都空就不弹（宁可只落日志，也不给一个只有取消按钮的空窗）。
        a2_log_criterion(@"[A2-JIT-ENABLER] 等待窗标题与正文都为空 ⇒ 不弹窗，只等（本次启动同样停在这里）");
    } else if (top != nil) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:alertTitle
                                                                      message:alertMessage
                                                               preferredStyle:UIAlertControllerStyleAlert];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                 style:UIAlertActionStyleCancel
                                               handler:^(UIAlertAction *action) {
            (void)action;
            [weakSelf finishWithOK:NO reason:@"用户取消了等待"];
        }]];
        self.alert = alert;
        // ★animated:NO★ 等的是「弹窗已落屏」这件事本身，不是动画。
        [top presentViewController:alert animated:NO completion:nil];
        a2_log_criterion(@"[A2-JIT-ENABLER] 已弹出「等待 JIT」（title=%@；正文 %lu 字）"
                         @"⇒ 本次启动停在这里（不建 VM）",
                         alertTitle, (unsigned long)alertMessage.length);
    } else {
        // 没有窗口（例如从后台/headless 进入）⇒ 只落日志，等待照跑。
        a2_log_criterion(@"[A2-JIT-ENABLER] 没有可展示的窗口 ⇒ 只等不提示（本次启动同样不往下走）");
    }

    // ★保活（本单）★：等待窗一上屏就广播「开始等 JIT」，由 App 层（A2AppDelegate 的观察者）
    //   拉起 A2PairingKeepAlive（静音音频 + 后台继续任务）。
    //   为什么必须在这里开：紧接着（kA2JITAlertLead 秒后）就 openURL 送去使能器，本进程随即进
    //   后台；没有保活 ⇒ 进程被挂起 ⇒ 0.5s 轮询与「回前台继续」都停在挂起那一刻（真机症状：
    //   开完 JIT 回来卡死）。★分层★：Natives 不认识 App 层的保活件，只发广播（见 .h）。
    a2_log_criterion(@"[A2-JIT-ENABLER] 等待 JIT 开始（保活开）⇒ 轮询 %.1fs/次，预算 %.0fs"
                     @"（★后台期间不烧预算、不复查★；回前台强制立即复查一次）",
                     kA2JITPollInterval, budget);
    self.waitingBroadcasted = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:A2JITEnablerWaitingDidBeginNotification
                                                      object:self];

    // ★② → ③ 的接缝★ 弹窗先上屏，再拉起使能器；one-shot（openEnablerURL 内再挡一次）。
    if (url != nil) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kA2JITAlertLead * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            A2JITEnablerRun *run = weakSelf;
            if (run == nil || run.finished || run.enablerLaunched) return;
            [run openEnablerURL:url tool:tool];
        });
    }

    // 后台断言：切到使能器之后 iOS 会挂起本进程，等待循环必须尽量活到回来那一刻
    // （老 Air 同款 beginBackgroundTask；到点被回收也不算失败——回来时还有前台探测）。
    __weak typeof(self) weakSelf = self;
    self.bgTask = [UIApplication.sharedApplication
        beginBackgroundTaskWithName:@"a2-jit-enable"
                 expirationHandler:^{
        A2JITEnablerRun *run = weakSelf;
        if (run == nil) return;
        a2_log_criterion(@"[A2-JIT-ENABLER] 后台断言到期（仍在等 JIT，回来后继续判据）");
        if (run.bgTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:run.bgTask];
            run.bgTask = UIBackgroundTaskInvalid;
        }
    }];

    // ★前台/后台切换（本单）★ —— 这是「开完 JIT 回来卡死」的正面修复：
    //   · 回前台（UIApplicationDidBecomeActive）⇒ ★强制立即复查一次★：
    //       不看挂起前的定时器（挂起期间 dispatch_after 全停），也不信任在途探针（它可能
    //       卡在被挂起的那一刻）。已就绪 ⇒ 直接继续启动；未就绪 ⇒ 重新进入等待（判死是不可能的，
    //       预算用光也重新给 kA2JITForegroundRecheckBudget）。
    //   · 切走（WillResignActive / DidEnterBackground）⇒ 只保活：不复查、不烧预算。
    //   观察者一律在收尾（finishWithOK:）里撤销，下一次等待重新注册，绝不叠两套。
    A2JITEnablerRun *__weak weakRun = self;
    void (^addObserver)(NSNotificationName, void (^)(void)) =
        ^(NSNotificationName name, void (^body)(void)) {
            id token = [NSNotificationCenter.defaultCenter
                addObserverForName:name
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                (void)note;
                A2JITEnablerRun *run = weakRun;
                if (run == nil || run.finished) return;
                body();
            }];
            [self.observers addObject:token];
        };
    addObserver(UIApplicationDidBecomeActiveNotification, ^{ [weakRun foregroundRecheck]; });
    addObserver(UIApplicationWillResignActiveNotification, ^{ [weakRun enterBackground]; });
    addObserver(UIApplicationDidEnterBackgroundNotification, ^{ [weakRun enterBackground]; });

    [self scheduleNextTick];
}

#pragma mark - 后台 / 回前台

/// 切走（将要 / 已经进后台）：只保活，不复查、不烧等待预算。
- (void)enterBackground {
    if (self.finished || self.inBackground) return;
    self.inBackground = YES;
    self.lastTick = [NSDate date].timeIntervalSince1970;
    a2_log_criterion(@"[A2-JIT-ENABLER] 进后台（保活中）⇒ 暂停复查、暂停等待预算；"
                     @"回前台会强制立即复查一次（拿到 JIT 才继续启动）");
}

/// ★回前台 ⇒ 强制立即复查一次★（本单的核心改动）。
///
/// 为什么不能只靠定时器：挂起期间 dispatch_after / 主队列全部冻结，回来时「下一次 tick」的
/// 时间点可能早就过了 —— 老实现只会等下一个 0.5s 节拍（甚至因为 probeInFlight 卡在挂起那一刻
/// 而永远不再发起新的探针），用户看到的就是「开完 JIT 回来卡死」。
- (void)foregroundRecheck {
    if (self.finished) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSTimeInterval away = now - self.lastTick;
    BOOL wasBackground = self.inBackground;
    self.inBackground = NO;
    self.lastTick = now;
    self.foregroundRechecks += 1;
    self.foregroundRecheckPending = YES;
    a2_log_criterion(@"[A2-JIT-ENABLER] 回前台 ⇒ 立即复查 JIT（第 %lu 次；离开 %.0fs；"
                     @"后台标志=%d）★不看挂起前的定时器、不信任在途探针★",
                     (unsigned long)self.foregroundRechecks, away > 0 ? away : 0,
                     (int)wasBackground);
    [self tickForced:YES];
}

- (void)scheduleNextTick {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kA2JITPollInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf tickForced:NO];
    });
}

/// 一轮判据。`forced=YES` ⇒ ★回前台强制复查★：不看定时器节奏、作废在途探针、预算用光也重给。
- (void)tickForced:(BOOL)forced {
    if (self.finished) return;

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;

    // ★后台期间：只保活，不复查、不烧预算★
    //   · 不复查：拿到 JIT 的下一步是「建 VM + 起游戏」，那必须在前台发生（首帧要可见）；
    //     在后台跑等于把用户扔进一个看不见的黑屏。
    //   · 不烧预算：用户去 StikDebug 那一趟可能几分钟，墙钟不该算进「等 JIT 的耐心」。
    if (self.inBackground) {
        self.lastTick = now;
        if (now - self.lastHeartbeat >= kA2JITHeartbeat) {
            self.lastHeartbeat = now;
            a2_log_criterion(@"[A2-JIT-ENABLER] 在后台等 JIT（保活中，不复查；回前台会强制立即复查）");
        }
        [self scheduleNextTick];
        return;
    }

    // ★挂起间隙豁免★：保活失效时进程仍可能被挂起几十秒；墙钟不能白吃预算
    //   （老 Air 的 ame169_waitForJITCondition 同款处理）。
    NSTimeInterval gap = now - self.lastTick;
    if (gap > 2.0) {
        self.deadline += gap;
        a2_log_criterion(@"[A2-JIT-ENABLER] 挂起间隙 %.0fs 不计入等待预算", gap);
    }
    self.lastTick = now;

    if (now >= self.deadline) {
        if (!forced) {
            NSString *why = self.lastWhy.length > 0 ? self.lastWhy : @"判据始终未通过";
            [self finishWithOK:NO reason:[NSString stringWithFormat:@"等待 JIT 超时；最后一次判据：%@", why]];
            return;
        }
        // ★回前台不是「判死」的时机★：预算多半是被后台那段时间吃掉的 ⇒ 重新进入等待。
        //   这就是「不要只等一次就判死」：回来时总还有一次机会，第二次点对了也能被接住。
        self.deadline = now + kA2JITForegroundRecheckBudget;
        a2_log_criterion(@"[A2-JIT-ENABLER] 回前台时等待预算已用光 ⇒ 重新进入等待 %.0fs"
                         @"（★不判死★，接着复查）", kA2JITForegroundRecheckBudget);
    }
    if (now - self.lastHeartbeat >= kA2JITHeartbeat) {
        self.lastHeartbeat = now;
        a2_log_criterion(@"[A2-JIT-ENABLER] 仍在等待 JIT（剩余 %.0fs）", self.deadline - now);
    }
    if (self.probeInFlight) {
        if (!forced) {   // 上一发还没回来（brk 最坏 2.5s）⇒ 不叠加
            [self scheduleNextTick];
            return;
        }
        // ★回前台强制复查：在途那发可能卡在被挂起的那一刻，永不回来 ⇒ 作废它、重新发★
        a2_log_criterion(@"[A2-JIT-ENABLER] 回前台强制复查：作废挂起前在途的那一发探针"
                         @"（№%lu 的结果不再采纳）", (unsigned long)self.probeGeneration);
    }

    self.probeGeneration += 1;
    NSUInteger gen = self.probeGeneration;
    self.probeInFlight = YES;
    __weak typeof(self) weakSelf = self;
    // 判据要发 brk #0x69（可能阻塞）⇒ 必须在后台队列；结果回主线程收尾。
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *why = nil;
        BOOL ok = a2jit_ready_now(&why);
        dispatch_async(dispatch_get_main_queue(), ^{
            A2JITEnablerRun *run = weakSelf;
            if (run == nil || run.finished) return;
            if (gen != run.probeGeneration) return;   // 过期结果（已被回前台复查接管）⇒ 丢弃
            run.probeInFlight = NO;
            if (ok) {
                if (run.foregroundRecheckPending) {
                    run.foregroundRecheckPending = NO;
                    a2_log_criterion(@"[A2-JIT-ENABLER] 回前台复查：握手完成（哨兵+Extension）⇒ 继续启动"
                                     @"（沿用同一次请求的 completion / 启动参数，不重新排队）");
                }
                [run finishWithOK:YES reason:(why ?: @"判据通过")];
                return;
            }
            run.foregroundRecheckPending = NO;
            run.lastWhy = why;
            [run scheduleNextTick];
        });
    });
}

/// 拉起使能器（必须在主线程）。失败 ⇒ 立刻回调 NO（不白等 120s）。
- (void)openEnablerURL:(NSURL *)url tool:(A2JITEnablerTool)tool {
    // ★one-shot★ 同一次等待里使能器只拉起一次（弹窗回调 / 重入 / 前台通知都不该再发一条）。
    if (self.enablerLaunched) return;
    self.enablerLaunched = YES;
    a2_log_criterion(@"[A2-JIT-ENABLER] 弹窗已就位 ⇒ 现在拉起使能器 %@：%@",
                     a2jit_tool_name(tool), url.absoluteString);
    // ★只有 stikjit 会重拉本进程★：新进程里没有这次等待的上下文，于是置「重挂后自动继续」
    //   标记，由读点（Air2/App/A2AppDelegate.m）在下次 didFinishLaunching 认出并自动起游戏。
    //   其余使能器（stikdebug / apple-magnifier / sidestore）都在本进程内 attach，
    //   不需要这个标记（也不需要用户再点一次——本模块的等待就活在本进程里）。
    if (tool == A2JITEnablerToolStikJIT) {
        self.armedAutoLaunch = YES;
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"A2AutoLaunchAfterJIT"];
        [NSUserDefaults.standardUserDefaults synchronize];
    }
    __weak typeof(self) weakSelf = self;
    [UIApplication.sharedApplication openURL:url
                                     options:@{}
                           completionHandler:^(BOOL success) {
        if (success) return;
        A2JITEnablerRun *run = weakSelf;
        if (run == nil || run.finished) return;
        a2_log_criterion(@"[A2-JIT-ENABLER] %@ 打不开（scheme 未处理 / 目标 App 未安装）",
                         a2jit_tool_name(tool));
        [run finishWithOK:NO
                   reason:[NSString stringWithFormat:
                           @"%@ 打不开（未安装，或它的 URL scheme 未被处理）", a2jit_tool_name(tool)]];
    }];
}

@end

#pragma mark - 对外接口

@implementation A2JITEnabler

+ (BOOL)isJITReadyNow {
    return [self isJITReadyNowWithReason:NULL];
}

+ (BOOL)isJITReadyNowWithReason:(NSString *_Nullable *_Nullable)whyOut {
    NSString *why = nil;
    BOOL ok = a2jit_ready_now(&why);
    if (whyOut) *whyOut = why;
    // ★判据行的固定格式★：`判据 ready=0|1(原因: <放行依据>)（ppid=…）`。
    //   `ready=1(原因: …)` 里的文案就是「凭哪一条放行」—— 文案由 A2LegacyJITGate 给
    //   （brk #0x69 已被服务 / 非镜像设备直接放行），★绝不把「调试器在岗」写成「已验证」★。
    a2_log_criterion(@"[A2-JIT-ENABLER] 判据 ready=%d(原因: %@)（ppid=%d）",
                     (int)ok, why ?: @"—", getppid());
    return ok;
}

+ (void)logRegionSnapshot:(NSString *)tag {
    // 建 VM 前 / 建 VM 后各打一次：`[A2JIT] region=… size=… expected=… enough=… tag=…`。
    //   ★拿不到区不是错误★（iOS 26+ 的区是 libjvm 建 VM 时自己发 brk 取的）——
    //   这一行只是让真机能看清「我们这发 brk 拿到了什么」，如实打印，不拦路。
    a2jit_log_region(tag.length > 0 ? tag.UTF8String : "snapshot");
}

+ (BOOL)openLegacyGateBeforeVMBuild:(NSString *_Nullable *_Nullable)whyOut {
    // ★安装源分支（[A2-JIT-SRC]）★：TrollStore 机的 JIT 是安装时由 ldid 授予的内核级权限，
    //   全程没有调试器参与 ⇒ 老 Air 的闰门（发 brk #0x69 要求**调试器**应答，还要
    //   SetDetachAfterFirstBr / 清 BAD_ACCESS 异常端口）在巨魔机上必然失败。
    //   照老 Air 的 invokeAfterJITEnabled: 口径（hasTrollStoreJIT 那条不经过闰门）：
    //   巨魔机只要本进程「确实能用 JIT」就放行建 VM；判不出来时仍落回闰门（如实中止，
    //   不带着可疑状态建 VM）。
    if (a2jit_source() == A2JITInstallSourceTrollStore) {
        NSString *tsWhy = nil;
        if (a2jit_trollstore_ready(&tsWhy)) {
            a2_log_criterion(@"[A2-JIT-SRC] gate=skip(trollstore-native-jit) ⇒ 不跑老 Air 闰门、"
                             @"直接允许建 VM（%@）", tsWhy ?: @"—");
            if (whyOut) *whyOut = tsWhy ?: @"TrollStore 内核级 JIT 已就绪";
            return YES;
        }
        a2_log_criterion(@"[A2-JIT-SRC] gate=legacy（TrollStore 但本进程仍没拿到 JIT：%@）"
                         @"⇒ 继续跑老 Air 闰门，失败即如实中止、不建 VM", tsWhy ?: @"—");
    }
    // ★逐字转调老 Air 的闰门（Natives/Support/A2LegacyJITGate ⑤）★：
    //   本层只负责把「结论 → BOOL + 可读原因」翻成上层能用的形状，
    //   判定条件、顺序、日志全在 A2LegacyJITGate 里，一处都不在这里复制。
    NSString *why = nil;
    A2LegacyJITGateOutcome outcome = A2LegacyJITGateOpen(&why);
    if (whyOut) *whyOut = why;
    if (outcome == A2LegacyJITGateOutcomeOpen) {
        return YES;
    }
    // ★未放行 ⇒ 绝不建 VM★：把老 Air 的 `return 1` 分支翻成可读原因交给上层失败页。
    a2_log_criterion(@"[A2-JIT-GATE] 未放行（outcome=%ld）⇒ 中止启动、不建 VM：%@",
                     (long)outcome, why ?: @"—");
    return NO;
}

+ (void)ensureJITThen:(void (^)(BOOL))done {
    if (done == nil) return;
    // 要 canOpenURL / 弹窗 / beginBackgroundTask ⇒ 一律落主线程语义。
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ensureJITThen:done];
        });
        return;
    }

    // 已在申请中 ⇒ 挂到同一次等待上（同一个 tap 重复触发、或 UI 重入都不会二次跳转）。
    if (gA2JITRun != nil) {
        a2_log_criterion(@"[A2-JIT-ENABLER] 已有申请在途 ⇒ 本次回调挂到同一次等待");
        [gA2JITRun addCompletion:done];
        return;
    }

    A2JITEnablerRun *run = [A2JITEnablerRun new];
    [run addCompletion:done];
    gA2JITRun = run;

    // ① 判据再确认（调用方刚问过；这里防竞态：例如刚从使能器切回的瞬间判据已翻转）。
    NSString *why = nil;
    if (a2jit_ready_now(&why)) {
        [run finishWithOK:YES reason:(why ?: @"判据通过")];
        return;
    }
    a2_log_criterion(@"[A2-JIT-ENABLER] 未就绪 ⇒ 中止启动（不建 VM）：%@（ppid=%d jumped=%d）",
                     why ?: @"—", getppid(), (int)gA2JITJumpedThisProcess);

    // ② 申请：★同一进程只跳一次★（铁律 ②）。已跳过的第二轮只做短等待：
    //    调试器可能正在收尾，再跳一次就会「跳转 ↔ 重拉」无限循环。
    //    ★ppid≠1 也算「已经跳过一次」★：这说明本进程是被使能器重拉起来的（stikjit 那条路），
    //    再跳一次就是「重拉 → 再跳」的环路。旧实现靠把 ppid≠1 当成就绪来回避这个环，
    //    现在它不再能当就绪（就绪只认老 Air 的 AMEJITWaitReadyVerified）⇒ 改在这里断环：
    //    允许它把剩余预算用来等区，但绝不再拉起第二个使能器。
    BOOL alreadyJumped = gA2JITJumpedThisProcess || a2jit_launched_by_debugger();
    NSTimeInterval budget = alreadyJumped ? kA2JITRepeatWaitBudget : kA2JITWaitBudget;

    // ═════════════════════════════════════════════════════════════════════════
    // ★JIT 启动器偏好（`a2jit.preferredSource`）★ —— 用户钉死来源时只走那一条
    // -------------------------------------------------------------------------
    //  放在「安装源分支」之前：用户既然点名了来源，就不许安装源探测（TrollStore / SideStore）
    //  把来源改掉；该来源不可用 ⇒ 直接失败并说明原因（★不静默回退到 stikdebug★）。
    //  auto ⇒ 返回 NO，下面的既有流程一字未改（默认行为零风险）。
    // ═════════════════════════════════════════════════════════════════════════
    if (a2jit_start_preferred_run(run, alreadyJumped, why)) {
        return;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ★安装源分支（[A2-JIT-SRC]）★ —— TrollStore 机只走 TrollStore 自己的 JIT
    // -------------------------------------------------------------------------
    //  顺序照老 Air 的 invokeAfterJITEnabled:（DownloadViewController.m L3891–L4100）：
    //  先判安装源，巨魔机（hasTrollStoreJIT）就**只**用 apple-magnifier://，绝不拉
    //  stikdebug / stikjit / sidestore —— 那三条是给「装不上 TrollStore」的环境用的。
    //  为什么巨魔机不需要跳转：TrollStore 安装时已用 ldid 把内核级 JIT 签进 App，
    //  进程一启动就有 JIT ⇒ 先判「本进程现在能不能真的执行 JIT 页」：
    //    · 已就绪 ⇒ 直接继续启动（★不跳、不等待★，这就是「拿到就启动」）；
    //    · 还没就绪 ⇒ 用 apple-magnifier:// 让 TrollStore 再授予一次，**短等** 20s
    //      （巨魔是秒级动作，给 120s 只会变成用户眼里的「卡住」）。
    // ═════════════════════════════════════════════════════════════════════════
    if (a2jit_source() == A2JITInstallSourceTrollStore) {
        NSString *tsWhy = nil;
        if (a2jit_trollstore_ready(&tsWhy)) {
            a2_log_criterion(@"[A2-JIT-SRC] source=trollstore path=trollstore-native "
                             @"⇒ 巨魔机自带的 JIT 已可用（%@）★不跳 stikdebug、不弹等待窗★，直接继续启动",
                             tsWhy ?: @"—");
            [run finishWithOK:YES reason:(tsWhy ?: @"TrollStore 内核级 JIT 已就绪")];
            return;
        }
        if (alreadyJumped) {
            // 同一进程只请求一次（断「跳转 ↔ 重拉」的环）；这里只给调试器/巨魔一点收尾时间。
            a2_log_criterion(@"[A2-JIT-SRC] source=trollstore path=trollstore-wait-only "
                             @"⇒ 本进程已请求过一次（ppid=%d）⇒ 不再拉起，只短等 %.0fs；%@",
                             getppid(), kA2JITRepeatWaitBudget, tsWhy ?: @"—");
            [run startWaitingWithBudget:kA2JITRepeatWaitBudget
                                   tool:A2JITEnablerToolNone enablerURL:nil];
            return;
        }
        NSURL *tsURL = a2jit_url_trollstore();
        int tsCanOpen = a2jit_can_open(tsURL);
        a2_log_criterion(@"[A2-JIT-SRC] source=trollstore path=trollstore-request "
                         @"⇒ 还没就绪（%@）⇒ 只拉起 apple-magnifier://（canOpen=%d），"
                         @"★不拉 stikdebug/stikjit/sidestore★，短等 %.0fs",
                         tsWhy ?: @"—", tsCanOpen, kA2JITTrollStoreWaitBudget);
        if (tsURL == nil || tsCanOpen == 0) {
            [run finishWithOK:NO
                       reason:@"TrollStore 的 JIT 入口（apple-magnifier://）打不开 —— "
                               @"请在 TrollStore 设置里打开 URL Scheme，或确认本 App 是用 TrollStore 安装的"];
            return;
        }
        gA2JITJumpedThisProcess = YES;
        [run startWaitingWithBudget:kA2JITTrollStoreWaitBudget
                               tool:A2JITEnablerToolTrollStore
                         enablerURL:tsURL];
        return;
    }
    a2_log_criterion(@"[A2-JIT-SRC] source=%@ path=sidestore-chain（stikdebug → sidestore → stikjit，"
                     @"保持既有顺序与 120s 等待窗）", a2jit_src_name(a2jit_source()));

    if (alreadyJumped) {
        a2_log_criterion(@"[A2-JIT-ENABLER] 本进程已跳转过一次 ⇒ 不再跳转，只短等待 %.0fs"
                         @"（本次启动已终止，不建 VM）", budget);
        [run startWaitingWithBudget:budget tool:A2JITEnablerToolNone enablerURL:nil];
        return;
    }

    NSURL *url = nil;
    // ★走的是 auto★（非 auto 已在上面 a2jit_start_preferred_run 里接管）⇒ 不需要来源原因。
    A2JITEnablerTool tool = a2jit_pick_enabler(&url, NULL);
    if (tool == A2JITEnablerToolNone) {
        // 一个都打不开：不白等 120s（老 Air 的 MissingTool 分支同款），立刻给可读原因。
        [run finishWithOK:NO
                   reason:@"没有可用的 JIT 使能器（StikDebug / TrollStore / SideStore 都打不开）。"
                           "请安装 StikDebug 并为 Air2 开启 JIT 后重试"];
        return;
    }

    gA2JITJumpedThisProcess = YES;
    // ★①→④ 全在 startWaitingWithBudget 里按顺序做完★：弹窗先上屏 → 再 openURL → 再轮询。
    //   这里只把「要不要拉起哪一条」的决定传进去，不再自己 dispatch（上轮的写法是
    //   startWaiting 里 present 动画还没走完就排队 openURL，弹窗可能根本看不到）。
    [run startWaitingWithBudget:budget tool:tool enablerURL:url];
}

+ (NSString *)lastFailureReason {
    return gA2JITLastFailure;
}

@end
