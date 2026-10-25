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

#import "A2JITEnvironment.h"   // 判据（brk #0x69 / 区域验证 / 执行式探针）——唯一真相源
#import "UIKit+hook.h"         // UIWindow.mainWindow：key window 的唯一取法（不自造第二份）
#import "a2_log.h"             // native 侧判据行出口（与 Air2 的 [A2Log criterion:] 同一落点）

#pragma mark - 常量

/// 等待上限：对齐老 Air 的 invokeAfterJITEnabled（120s）。
static const NSTimeInterval kA2JITWaitBudget = 120.0;
/// 已经跳过一次之后的等待上限：★防死循环★ 第二次起不再跳，只给调试器一点收尾时间。
static const NSTimeInterval kA2JITRepeatWaitBudget = 8.0;
/// 轮询间隔：0.5s（老 Air 同量级；再密只是白刷 brk #0x69）。
static const NSTimeInterval kA2JITPollInterval = 0.5;
/// 单次区域验证预算：2.5s（A2JITEnvironment 在后台线程允许的切片量级）。
static const NSTimeInterval kA2JITVerifySlice = 2.5;
/// 心跳日志间隔：让真机日志能看出「还在等」而不是「卡死了」。
static const NSTimeInterval kA2JITHeartbeat = 10.0;
/// 弹窗 → 拉起使能器之间的间隔：★顺序有用★ 弹窗先落屏，再 openURL（openURL 会把我们送去
/// 后台；顺序反了弹窗根本没机会显示，用户就只看到「跳走了」）。
static const NSTimeInterval kA2JITAlertLead = 0.4;
/// 脚本名：打包阶段把 Assets/Air2JIT69.js 复制成 Air2.app/universal.js
/// （scripts/gen_xcodeproj.py 的随包阶段）。StikDebug 只认这个名字。
static NSString *const kA2JITScriptName = @"UniversalJIT26.js";

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

/// 唯一判据：★放行优先★ —— 下面四条**任一成立**即认为「现在可以建 VM」。
///
///   ① `entitlement`：内核级 JIT（TrollStore / 越狱装机：`dynamic-codesigning` /
///      `com.apple.private.cs.debugger`）⇒ 进程天生有 JIT，直接认（零探测、零延迟）；
///   ② `debugger-attached`：`CS_DEBUGGED`（有位调试器 attach 着本进程）⇒ 它会应答
///      `brk #0x69`，**包括 libjvm 建 VM 时自己发的那一发**；
///   ③ `verified-region`：`verifiedRegion != NULL`（本进程此前真拿到过调试器交付的、
///      已映射且 max_protection 含 EXECUTE 的区）；
///   ④ `exec-probe`：非镜像设备（< iOS 26）的匿名页执行式探针**真的跑过**
///      （mmap → 写指令 → RX → 真 call 并核对返回值）。镜像设备这一条恒不成立。
///
/// ★为什么改成「任一即放行」（2026-10-25 真机：StikDebug 里开完 JIT 后启动不再往下走）★
///   上一版把 ③ 当成**唯一**就绪来源（要求 `verifiedRegion != NULL`），是**真死锁**：
///   iOS 26+ 的 JIT 区是**建 VM 时 libjvm 自己发 `brk #0x69`** 才由调试器交付的
///   ⇒ 建 VM **之前**本进程永远不会有 `verifiedRegion` ⇒ 判据永远否 ⇒ 永不放行。
///   真机日志停在这两行之间（用户看到的「开完 JIT 也不继续」）：
///   ```
///   [A2-JIT-ENABLER] 判据 ready=0：没有可写 JIT 区（brk #0x69 未拿到区；…）⇒ 不放行建 VM
///   [A2-JIT-ENABLER] 已拿到 JIT ⇔ 始终不出现
///   ```
///
/// ★上一版的正确教训仍然保留★
///   · `getppid()≠1`（被使能器重拉）**仍然不算就绪** —— 它只影响「要不要再跳一次」，
///     见 ensureJITThen: 的 alreadyJumped；以前把它当就绪 ⇒ 没拿到区也建 VM（首帧 SIGBUS）。
///   · 「凭 ② 放行」**不等于**「区域已验证」：日志必须写清放行依据
///     （`ready=1(原因: debugger-attached)`），绝不把 ② 写成 ③。
///   · ④ 也不能当成 ①：它不来自 entitlement，得真执行过才算。
static BOOL a2jit_ready_now(NSString *_Nullable *_Nullable why) {
    // ① 内核级 entitlement：装机自带 JIT ⇒ 直接认（不看 brk，不引入任何延迟）。
    if (a2_jit_has_kernel_level()) {
        if (why) *why = @"entitlement（TrollStore / 越狱内核级 JIT）";
        return YES;
    }

    // ② 调试器已 attach（CS_DEBUGGED）⇒ 建 VM 的那发 brk 一定有人应答 ⇒ 放行。
    //    ★实时查 csops、不缓存★：调试器是在本进程跑起来之后才 attach 的；
    //    缓存一次「没 attach」就会把等待流程锁死（这正是本轮要修的死锁之一）。
    if (a2_jit_is_debugged()) {
        if (why) *why = @"debugger-attached（CS_DEBUGGED：调试器在岗 ⇒ brk #0x69 有人应答）";
        return YES;
    }

    // ③ 此前已经真拿到过区（那发 brk 被服务过）⇒ 认，并打出验收行。
    if ([A2JITEnvironment verifiedRegion] != NULL) {
        a2jit_log_region("gate-cached-region");
        if (why) {
            *why = [NSString stringWithFormat:
                @"verified-region（本进程已拿到可写 JIT 区 %p，size=%zu / 期望 %zu）",
                [A2JITEnvironment verifiedRegion], [A2JITEnvironment verifiedRegionBytes],
                [A2JITEnvironment expectedRegionBytes]];
        }
        return YES;
    }

    // ④ 非镜像设备（< iOS 26）：执行式探针真的跑过 ⇒ 同性质的真凭据。
    if (![A2JITEnvironment needsDebuggerMapping] && [A2JITEnvironment execProofObtained]) {
        if (why) *why = @"exec-probe（非镜像路径：真 mmap + 写指令 + 真执行通过）";
        return YES;
    }

    // 四条都不成立 ⇒ 有界取一次（唯一能把「未就绪」变成「就绪」的动作）：
    //   · 镜像设备：发一发有界 brk #0x69（拿到区 ⇒ ③ 成立；也能顺手完成 detach 时机判断）；
    //   · 非镜像设备：A2JITEnvironment 内部走执行式探针。
    NSString *envWhy = nil;
    (void)[A2JITEnvironment ensureVerifiedWithinBudget:kA2JITVerifySlice reason:&envWhy];
    a2jit_log_region("gate-probe");
    if ([A2JITEnvironment verifiedRegion] != NULL) {
        if (why) {
            *why = [NSString stringWithFormat:
                @"verified-region（刚发 brk #0x69 拿到可写 JIT 区 %p，size=%zu / 期望 %zu）",
                [A2JITEnvironment verifiedRegion], [A2JITEnvironment verifiedRegionBytes],
                [A2JITEnvironment expectedRegionBytes]];
        }
        return YES;
    }
    // 取区期间调试器可能刚好 attach 上（用户从 StikDebug 切回来的那一瞬间）⇒ 再判一次。
    if (a2_jit_is_debugged()) {
        if (why) *why = @"debugger-attached（CS_DEBUGGED：取区后复查，调试器在岗 ⇒ brk 有人应答）";
        return YES;
    }
    if (![A2JITEnvironment needsDebuggerMapping] && [A2JITEnvironment execProofObtained]) {
        if (why) *why = @"exec-probe（非镜像路径：取区后复查，真执行通过）";
        return YES;
    }

    // ★四条都不成立 ⇒ 才拒绝★：给可读原因（不闪退；调用方据此出失败页 / 进入等待申请流程）。
    if (why) {
        BOOL mirror = [A2JITEnvironment needsDebuggerMapping];
        *why = [NSString stringWithFormat:
            @"四条判据都不成立：entitlement=0 / CS_DEBUGGED=0 / verifiedRegion=NULL / "
            @"exec-probe=%@（%@）⇒ 不放行建 VM",
            mirror ? @"不适用(镜像设备)" : @"未通过",
            envWhy.length > 0 ? envWhy : @"无取证"];
    }
    return NO;
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
static A2JITEnablerTool a2jit_pick_enabler(NSURL *_Nullable *_Nullable urlOut) {
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
@property (nonatomic, assign) BOOL enablerLaunched;          // ★one-shot★ 使能器只拉起一次
@property (nonatomic, assign) BOOL armedAutoLaunch;          // 是否置过「重挂后自动继续」标记
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, strong) UIAlertController *alert;
@property (nonatomic, strong) id activeObserver;
@property (nonatomic, copy) NSString *lastWhy;              // 最近一次判据原因（失败页用）

- (void)addCompletion:(void (^)(BOOL))block;
- (void)finishWithOK:(BOOL)ok reason:(NSString *)reason;
- (void)startWaitingWithBudget:(NSTimeInterval)budget
                          tool:(A2JITEnablerTool)tool
                    enablerURL:(NSURL *_Nullable)url;
- (void)openEnablerURL:(NSURL *)url tool:(A2JITEnablerTool)tool;
- (void)scheduleNextTick;
- (void)tick;

@end

/// ★在途的那一次★（同一时刻最多一个；并发调用挂到同一次等待上）。
static A2JITEnablerRun *gA2JITRun = nil;
/// ★防死循环的第二条铁律★：本进程是否已经**尝试过**一次跳转（拉起请求发出前置位；
/// 有效失败不影响它 —— 「试过就不再试」才是断环的关键）。
static BOOL gA2JITJumpedThisProcess = NO;
/// 最近一次失败原因（给 lastFailureReason 读）。
static NSString *gA2JITLastFailure = nil;

@implementation A2JITEnablerRun

- (instancetype)init {
    self = [super init];
    if (self) {
        _completions = [NSMutableArray array];
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

    if (self.activeObserver != nil) {
        [NSNotificationCenter.defaultCenter removeObserver:self.activeObserver];
        self.activeObserver = nil;
    }
    if (self.alert != nil) {
        UIAlertController *alert = self.alert;
        self.alert = nil;
        [alert dismissViewControllerAnimated:YES completion:nil];
    }
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
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
    } else {
        message = [NSString stringWithFormat:
            @"已让 %@ 为 Air2 开启 JIT。\n请按它的提示完成授权，然后回到 Air2 —— 拿到 JIT 会自动继续启动。\n（最多等 %.0f 秒）",
            a2jit_tool_name(tool), budget];
    }
    UIViewController *top = UIWindow.mainWindow.rootViewController;
    while (top.presentedViewController != nil) top = top.presentedViewController;
    if (top != nil) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"正在等待 JIT"
                                                                      message:message
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
        a2_log_criterion(@"[A2-JIT-ENABLER] 已弹出「正在等待 JIT」⇒ 本次启动停在这里（不建 VM）");
    } else {
        // 没有窗口（例如从后台/headless 进入）⇒ 只落日志，等待照跑。
        a2_log_criterion(@"[A2-JIT-ENABLER] 没有可展示的窗口 ⇒ 只等不提示（本次启动同样不往下走）");
    }

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

    // 回到前台 = 用户从使能器切换回来 ⇒ 立刻补一发判据（不必等下一个 0.5s 节拍）。
    self.activeObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        (void)note;
        A2JITEnablerRun *run = weakSelf;
        if (run == nil || run.finished) return;
        a2_log_criterion(@"[A2-JIT-ENABLER] 已回到前台 ⇒ 立刻复查 JIT");
        [run tick];
    }];

    [self scheduleNextTick];
}

- (void)scheduleNextTick {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kA2JITPollInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf tick];
    });
}

- (void)tick {
    if (self.finished) return;

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    // ★挂起间隙豁免★：用户进 StikDebug 一趟，进程可能被挂起几十秒；墙钟不能白吃预算。
    NSTimeInterval gap = now - self.lastTick;
    if (gap > 2.0) {
        self.deadline += gap;
        a2_log_criterion(@"[A2-JIT-ENABLER] 挂起间隙 %.0fs 不计入等待预算", gap);
    }
    self.lastTick = now;

    if (now >= self.deadline) {
        NSString *why = self.lastWhy.length > 0 ? self.lastWhy : @"判据始终未通过";
        [self finishWithOK:NO reason:[NSString stringWithFormat:@"等待 JIT 超时；最后一次判据：%@", why]];
        return;
    }
    if (now - self.lastHeartbeat >= kA2JITHeartbeat) {
        self.lastHeartbeat = now;
        a2_log_criterion(@"[A2-JIT-ENABLER] 仍在等待 JIT（剩余 %.0fs）", self.deadline - now);
    }
    if (self.probeInFlight) {   // 上一发还没回来（brk 最坏 2.5s）⇒ 不叠加
        [self scheduleNextTick];
        return;
    }

    self.probeInFlight = YES;
    __weak typeof(self) weakSelf = self;
    // 判据要发 brk #0x69（可能阻塞）⇒ 必须在后台队列；结果回主线程收尾。
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *why = nil;
        BOOL ok = a2jit_ready_now(&why);
        dispatch_async(dispatch_get_main_queue(), ^{
            A2JITEnablerRun *run = weakSelf;
            if (run == nil || run.finished) return;
            run.probeInFlight = NO;
            if (ok) {
                [run finishWithOK:YES reason:(why ?: @"判据通过")];
                return;
            }
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
    NSString *why = nil;
    BOOL ok = a2jit_ready_now(&why);
    // ★判据行的固定格式★：`判据 ready=0|1(原因: <放行依据>)（ppid=…）`。
    //   `ready=1(原因: …)` 里的文案就是「凭哪一条放行」——四条判据各有自己的 tag
    //   （entitlement / debugger-attached / verified-region / exec-probe），
    //   ★绝不把 debugger-attached 写成「已验证」★（真机自证要能按这一行分辨）。
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
    //    现在它不再能当就绪（就绪只认 entitlement / verifiedRegion）⇒ 改在这里断环：
    //    允许它把剩余预算用来等区，但绝不再拉起第二个使能器。
    BOOL alreadyJumped = gA2JITJumpedThisProcess || a2jit_launched_by_debugger();
    NSTimeInterval budget = alreadyJumped ? kA2JITRepeatWaitBudget : kA2JITWaitBudget;

    if (alreadyJumped) {
        a2_log_criterion(@"[A2-JIT-ENABLER] 本进程已跳转过一次 ⇒ 不再跳转，只短等待 %.0fs"
                         @"（本次启动已终止，不建 VM）", budget);
        [run startWaitingWithBudget:budget tool:A2JITEnablerToolNone enablerURL:nil];
        return;
    }

    NSURL *url = nil;
    A2JITEnablerTool tool = a2jit_pick_enabler(&url);
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
