//
//  A2JITEnvironment.h
//  Air2
//
//  Natives/Support —— JIT 环境与判据（可用性 / 区域取证 / 自证 / 日志）。
//
//  职责（见 docs/ARCHITECTURE.md「Natives/ » Support/ = JIT 环境、签名处理、
//  崩溃探针、诊断日志」）：
//    · 只回答「本次进程 JIT 到底能不能用」，是建 VM 之前门禁的唯一真相源。
//    · 不感知「版本 / 账号 / 下载 / 界面」等业务概念，只回传已解析好的判据与取证。
//    · 不做任何 UI：失败提示条由上层（Player 编排）决定是否展示。
//
//  判据要点（与 feat/runtime-native 一致，逐条可追溯，见下方来源标注）：
//    · 「能力声明」≠「实际可用」：CS_DEBUGGED / entitlement / TrollStore 装机只是
//      能力声明；唯一可信的是**真的试一次**——发一发 brk #0x69 拿到【真映射且
//      max_protection 含 EXECUTE】的区域（Universal/镜像路径），或真的执行一段
//      自产指令（原生路径）。
//    · brk #0x69 是唯一会被外部调试器**同步应答**的操作：调试器在岗却不服务时会
//      永不返回 ⇒ 必须在专用后台线程 + 有界预算内发出，绝不无限等、绝不卡主线程。
//
//  来源（可追溯）：
//    · 跳转自 feat/runtime-native（分支 feat/runtime-native @ 7903e3422）
//      Natives/utils.h  L192–L308（AMEJIT* 声明块）
//      Natives/utils.m  L752–L756（裸 brk #0x69 叶子）
//      Natives/utils.m  L805–L948（[JIT-NOCRASH] SIGTRAP/sigsetjmp 安全网）
//      Natives/utils.m  L1438–L1863（[JIT-FLOW][JIT-P0.1/2/3][JIT-HANG] 判据主体）
//      Natives/utils.m  L2310–L2325（区域取证 / 判定访问器）
//      Natives/utils.m  L2479–L2584（真写入 + 真执行自证）
//      Natives/utils.m  L2646–L2694（匿名页执行式探针）
//    · 报告：D:\CTF\_RT_P0.md、D:\CTF\_RT_P0_2.md、D:\CTF\_JIT_ORDER.md
//
//  ★不移植★：调试器/使能器 UI 适配、TrollStore 自开 JIT、下载、版本相关逻辑
//  （均属上层或业务，不进 Natives/Support）。
//

#import <Foundation/Foundation.h>
#import <stddef.h>

NS_ASSUME_NONNULL_BEGIN

/// brk #0x69 区域判定的分类（搬运 self utils.h L226–L236）——
/// 供失败提示条「按取证分流」文案使用：不同失败原因对应不同用户动作，不可混为一谈。
typedef NS_ENUM(NSInteger, A2JITRegionVerdict) {
    A2JITRegionVerdictUnknown        = 0,  ///< 尚未探测
    A2JITRegionVerdictUsable         = 1,  ///< 可用：非哨兵 + 已映射 + size>0 + max 含 X
    A2JITRegionVerdictNotServiced    = 2,  ///< brk #0x69 无人服务（返回 NULL）⇒ 先【启用 JIT】
    A2JITRegionVerdictLegacySentinel = 3,  ///< 回 legacy 哨兵 0xE0000069 ⇒ 需【指派 JIT 脚本】
    A2JITRegionVerdictNoMapping      = 4,  ///< 有返回值但地址在进程内无映射（哨兵变体/垃圾）
    A2JITRegionVerdictZeroSize       = 5,  ///< 区域 size=0
    A2JITRegionVerdictNotExecutable  = 6,  ///< max_protection 不含 EXECUTE（该页永不可执行）
};

/// 区域「真写入 + 真执行」自证结果（搬运自 utils.m L1594–L1600）。
/// ★仅作日志，不参与可用性判定★（见 A2JITEnvironment.m 关于 iOS26+ RW→RX 撤销祝福的说明）。
typedef NS_ENUM(NSInteger, A2JITRegionProof) {
    A2JITRegionProofRWXOK        = 1,  ///< 映射存在 + 真写入 + 真执行成功（真·JIT 区）
    A2JITRegionProofNotWritable  = 2,  ///< 映射存在但不可写（mprotect(RW) 也被拒）
    A2JITRegionProofExecFaulted  = 3,  ///< 写了，但执行时保护失败（页不是合法 JIT mapping）
    A2JITRegionProofUnmapped     = 4,  ///< 该地址在进程内无映射（哨兵/垃圾返回值）
    A2JITRegionProofInconclusive = 5,  ///< 自证本身跑不起来
};

/// 匿名页执行式探针结果（搬运自 utils.m L2646–L2648）。
typedef NS_ENUM(NSInteger, A2JITExecProbeResult) {
    A2JITExecProbeExecOK         = 1,  ///< 真执行成功
    A2JITExecProbeMprotectFailed = 2,  ///< mprotect(RX) 被拒（无 JIT 权限）
    A2JITExecProbeExecFaulted    = 3,
    A2JITExecProbeSkipped        = 4,  ///< 无 JIT 权限/无 CS_DEBUGGED ⇒ 不做执行式自证（不崩，交 JVM 实测）  ///< mprotect 过了但取指保护失败（假阳性，db76cfb）
};

/**
 * A2JITEnvironment —— JIT 环境与判据（无业务、无 UI）。
 *
 * 典型用法（上层编排 / Context 建 VM 之前）：
 * @code
 *   NSString *why = nil;
 *   if (![A2JITEnvironment ensureVerifiedWithinBudget:3.0 reason:&why]) {
 *       // 优雅失败：绝不调 JNI_CreateJavaVM（否则首帧 JIT 取指 SIGBUS）
 *       NSLog(@"JIT 不可用: %@ 取证=%@", why, [A2JITEnvironment regionEvidence]);
 *   }
 * @endcode
 */
@interface A2JITEnvironment : NSObject

/// ★[JIT-P0.1] 有界「确保 JIT 已验证」：在专用后台线程 + 有界预算内发一发 brk #0x69，
/// 拿到【真映射且 max 含 X】的区域即通过；未服务 / 超时一律判不可用。
/// 调用方应保证不在主线程（若在主线程会自动收紧预算并顺带 kick 一发后台探测）。
/// @param whyOut 可读原因 / 取证（可为 NULL）。
+ (BOOL)ensureVerifiedWithinBudget:(NSTimeInterval)budget
                            reason:(NSString *_Nullable *_Nullable)whyOut;

/// ★[JIT-P0.1] 发起一次后台有界探测（不等待、不阻塞调用方；同一时刻一发在途）。
+ (void)kickBackgroundVerify;

/// ★[JIT-FLOW] 内联验证一次（成功一次即缓存；失败限流 2s）。主线程 1.5s / 后台 3.0s 预算。
+ (BOOL)verifyWritableRegion;

/// 等待就绪谓词：非镜像路径用匿名页执行式自证；镜像 / Universal 路径用 brk 区域验证。
+ (BOOL)waitReadyVerified;

/// ★非镜像路径（iOS < 26）的真凭据★：匿名页执行式探针**真的跑过**
/// （mmap → 写一条真指令 → mprotect(RX) → 真的 call 并核对返回值）。
/// 它与 `verifiedRegion` 是同一性质的东西 ——「本进程现在**真的能执行**自产代码」——
/// 而不是 entitlement / CS_DEBUGGED 那种「能力声明」。镜像设备（iOS 26+）恒返回 NO：
/// 那种口径只认 brk #0x69 交付的区（没有区的声明/attach 一律不算）。
+ (BOOL)execProofObtained;

/// 已通过验证的 JIT 区指针（未验证过返回 NULL）。供诊断 / 复用。
+ (void *_Nullable)verifiedRegion;

/// 调试器实际交付的 region 字节数（`vm_region_64` 读到的 size；未验证过返回 0）。
/// 与 `verifiedRegion` 配对使用 —— 真机验收要能一眼看出「拿到的是 64MB 还是一页」。
+ (size_t)verifiedRegionBytes;

/// 期望的 JIT 区字节数（偏好键 `A2JITRegionMB` 覆盖，未设 ⇒ 64MB）。
+ (size_t)expectedRegionBytes;

/// 最近一次区域取证摘要（可读；无探测记录返回 nil）。
+ (NSString *_Nullable)regionEvidence;

/// ★镜像路径判据★ 本机是否**必须由调试器代映射** code cache（iOS 26+：TXM / 硬化运行时）。
///
/// 为什么把它暴露出来：本机上「能力声明」（`dynamic-codesigning` entitlement）**不等于**
/// 「现在能用」——iOS 26+ 的自产代码必须有调试器经 `brk #0x69` 交付的可执行区，否则首帧
/// 取指就 SIGBUS。启动闸门需要一个地方问「这台机器是不是这种口径」，答案只在本文件
/// (`a2_jit_device_needs_debug_mapping`) 一处计算，不要在上层照抄 OS 版本判断。
+ (BOOL)needsDebuggerMapping;

/// 最近一次区域判定分类（供失败分流）。
+ (A2JITRegionVerdict)lastRegionVerdict;

/// 作废可用性缓存（用户刚开 / 关 JIT、从外部工具切回前台时调用）。
+ (void)invalidateCache;

@end

// ============================================================================
// C 叶子原语（前缀 a2_jit_）—— 无 Objective-C 对象，崩溃路径安全（只读/裸 asm）。
// ============================================================================

/// 裸 brk #0x69（BreakGetJITMapping）：由外部调试器代映射一块 W+X 内存并回填地址。
/// ★无安全网★：调试器未就岗时必死；仅供内部 / 测试，生产路径请用 ..._safe 变体。
void *_Nullable a2_jit_brk69_create_region(size_t len);

/// 带 SIGTRAP 安全网的 brk #0x69：无人应答返回 NULL（不致死）。
void *_Nullable a2_jit_brk69_create_region_safe(size_t len);

/// 带安全网的「下发 JIT 脚本」（brk #0xf00d cmd=2）：把脚本交给脚本引擎，用于把
/// legacyCommands[0x69] 从「回哨兵」改成「真建区」（[JIT-ORDER]）。失败返回 NO，不致死。
BOOL a2_jit_send_script_safe(const char *utf8, size_t len);

/// 带安全网的「首个 brk 之后脱离」（brk #0xf00d cmd=3，= 老 Air JIT26SetDetachAfterFirstBr）。
/// 无人应答时返回 NO（降级），不致死。
BOOL a2_jit_set_detach_after_first_br(BOOL detach);

/// 统一诊断日志（前缀 [A2JIT]；写 stderr，随 stdout/stderr 重定向进 latestlog.txt）。
void a2_jit_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

/// 查询地址的 mach 映射与 page 保护（vm_region_64）。
/// @return 0=成功（回填 cur/max/size）；-1=该地址在进程内无映射。
int a2_jit_query_region_prot(void *addr, size_t len,
                             unsigned int *_Nullable curOut,
                             unsigned int *_Nullable maxOut,
                             unsigned long long *_Nullable sizeOut);

/// 「真写入 + 真执行」自证：写一条真指令 → mprotect(RX) → 真的调用它并核对返回值。
A2JITRegionProof a2_jit_prove_region_rwx(void *addr, size_t len,
                                         int *_Nullable mprotectRcOut,
                                         int *_Nullable errnoOut);

/// 匿名页执行式探针（与 HotSpot code cache 同型：匿名 + 私有 + 先 RW）：
/// 真 mmap → 写一条真指令 → RX → 真的执行。★这是「原生 JIT 真能力」的可信判据★。
A2JITExecProbeResult a2_jit_exec_probe_anonymous(void);

/// 本进程是否具备「内核级 JIT」：**只认 entitlement**（TrollStore / 越狱装机带来的
/// `dynamic-codesigning` / `com.apple.private.cs.debugger`）。
/// ★CS_DEBUGGED 不算内核级 JIT★——它只说明有位调试器 attach 着、能应答 brk，
/// 不说明本进程已经拿到可执行区。要看 CS_DEBUGGED 请用 a2_jit_is_debugged()（独立的判据来源）。
BOOL a2_jit_has_kernel_level(void);

/// 本进程此刻是否处于 `CS_DEBUGGED`（有位调试器 attach 着本进程）。
///
/// 语义（2026-10-25 真机修正后的一等判据）：
///   · 它是「放行优先」判据④条里的一条 —— 调试器在岗 ⇒ 它会应答 brk #0x69，
///     包括 **libjvm 建 VM 时自己发出的那一发**。
///   · 它**不是**「已验证 JIT 区」：调用方日志必须写清「凭哪一条放行」
///     （例如 `ready=1(原因: debugger-attached)`），不得凭它声称「区域已验证」。
///   · ★每次实时查 csops，不缓存★：调试器是在进程跑起来之后才 attach 的，
///     缓存一次「没 attach」会把整个等待流程锁死（历史缺陷）。
BOOL a2_jit_is_debugged(void);

NS_ASSUME_NONNULL_END
