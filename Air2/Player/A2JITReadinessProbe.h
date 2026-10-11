//
//  A2JITReadinessProbe.h
//  Air2
//
//  Player —— JIT【真实能力复验】的注入缝（判据内核在 Natives/Support/A2JITEnvironment）。
//
//  ★为什么要这层缝（与 A2JITFactsSource 同源）★：
//    · 依赖严格单向 App → UI → Player → Core → Bridge → Natives（ADR-002）。
//      A2JITEnvironment 在 Natives/Support，Player 不得直接 import 它 ——
//      否则单向分层被破坏，且原本可脱离真机的纯逻辑单测会被运行期依赖（mach /
//      裸 brk / 信号安全网）拖垮。故此处只留【协议】，真实实现落在 Bridge
//      （Air2/Bridge/A2JITEnvironmentProbe），单测注入假 probe。
//    · ★判据语义一字不改★：本层只是把 Natives 已有的判据（brk #0x69 区域取证）
//      抬到 Player 能看见的位置，不新增、不弱化任何判定条件。
//
//  来源：docs/DECISIONS.md ADR-007（只认「真的试一次」）、ADR-009；
//        docs/JIT-PROVISIONING.md §1.4 铁律（环境能提供 JIT ≠ 本进程现在能用 JIT）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 区域判定分类 —— ★逐值与 Natives/Support/A2JITEnvironment.h 的
/// `A2JITRegionVerdict` 对应★（Bridge 侧用 switch 做编译期穷尽映射，
/// 单测用 A2JITEnvironment.h 直接断言数值相等）。
/// ★不要在此新增/改名语义★：每一项都必须在 A2JITEnvironment 里有出处。
typedef NS_ENUM(NSInteger, A2JITReadinessVerdict) {
    A2JITReadinessVerdictUnknown        = 0,  ///< 尚未探测
    A2JITReadinessVerdictUsable         = 1,  ///< 可用：非哨兵 + 已映射 + size>0 + max 含 X
    A2JITReadinessVerdictNotServiced    = 2,  ///< brk #0x69 无人服务（无调试器应答）⇒ 先【启用 JIT】
    A2JITReadinessVerdictLegacySentinel = 3,  ///< 回 legacy 哨兵 0xE0000069 ⇒ 需【指派 JIT 脚本】
    A2JITReadinessVerdictNoMapping      = 4,  ///< 有返回值但地址在进程内无映射
    A2JITReadinessVerdictZeroSize       = 5,  ///< 区域 size=0
    A2JITReadinessVerdictNotExecutable  = 6,  ///< max_protection 不含 EXECUTE
};

/// 【注入点】JIT 真实能力复验（无平台细节；真机实现经 Bridge 落到 Natives/Support）。
@protocol A2JITReadinessProbe <NSObject>

@required

/// ★有界「确保 JIT 已验证」★：真机实现逐字转发
/// `A2JITEnvironment.ensureVerifiedWithinBudget:reason:`（在专用后台线程 + 有界预算内
/// 发一发 `brk #0x69`，拿到真映射且 max 含 X 的区域即通过；未服务 / 超时一律判不可用）。
/// @param whyOut 可读原因 / 取证（可为 NULL 指针）。
- (BOOL)ensureJITUsableWithinBudget:(NSTimeInterval)budget
                             reason:(NSString *_Nullable *_Nullable)whyOut;

/// 最近一次区域判定分类（失败分流文案据此分流）。
- (A2JITReadinessVerdict)lastVerdict;

/// 最近一次区域取证摘要（可读；无探测记录返回 nil）。
- (nullable NSString *)lastEvidence;

@optional

/// 作废可用性缓存（用户刚开 / 关 JIT、从外部工具切回前台时调用）。
- (void)invalidateCache;

@end

NS_ASSUME_NONNULL_END
