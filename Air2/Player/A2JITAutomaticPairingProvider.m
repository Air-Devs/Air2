//
//  A2JITAutomaticPairingProvider.m
//  Air2
//
//  [JIT-AUTOPAIR-1] 真实现（取代占位）：
//    ① 能力检测 —— iOS ≥ 27；
//    ② 前置条件 —— Developer Mode / 本地网络 / get-task-allow / DDI（三态，缺失/未确认分得清）；
//    ③ 就绪判定 —— ★真去容器约定位置找 + 解析 + 判新鲜度★；
//    ④ 取配对   —— 前置齐 + 引擎接入 ⇒ ★有界★尝试生成；缺什么报什么，★绝不假成功★；
//    ⑤ 开启 JIT —— 真调判据内核（注入的 A2JITReadinessProbe），按 verdict 如实判成败。
//
//  ★边界★：本类不 import 任何 Natives 头（分层纪律），也不自己发 Bonjour / 建隧道 ——
//  机制一律来自注入的 A2JITAutoPairingEngine（真机 = Bridge → Natives）。
//

#import "A2JITAutomaticPairingProvider.h"
#import "A2JITFacts.h"
#import "A2JITPairingFileStore.h"
#import "A2JITStrategySelector.h"
#import "A2JITAutoPairingGuidance.h"
#import "A2JITVerdictGuidance.h"
#import "A2JITStrings.h"
#import "A2JITDDI.h"          // [JIT-DDI-1] DDI 判定（类型 / 纯逻辑）
#import "A2JITDDIProbe.h"     // [JIT-DDI-1] DDI 判定缝
#import "A2JITDDIGuidance.h"  // [JIT-DDI-1] 判定 → 前置条件三态

/// 默认生成预算与新鲜度窗口（有界；见 docs/JIT-PROVISIONING.md §5 风险 3「7 天重签」）。
static const NSTimeInterval kA2JITAutoPairingDefaultBudget = 45.0;
static const NSTimeInterval kA2JITAutoPairingFileMaxAge    = 7.0 * 24.0 * 60.0 * 60.0;
/// 生成配对后的 JIT 复验预算（与 ②导入 同口径）。
static const NSTimeInterval kA2JITAutoPairingActivationBudget = 3.0;

/// 前置条件 → blocker（未满足时）。
static A2JITAutoPairingBlocker A2BlockerForPrecondition(A2JITAutoPairingPrecondition precondition) {
    switch (precondition) {
        case A2JITAutoPairingPreconditionDeveloperMode: return A2JITAutoPairingBlockerDeveloperModeOff;
        case A2JITAutoPairingPreconditionLocalNetwork:  return A2JITAutoPairingBlockerLocalNetworkDenied;
        case A2JITAutoPairingPreconditionGetTaskAllow:  return A2JITAutoPairingBlockerGetTaskAllowMissing;
        case A2JITAutoPairingPreconditionDDI:           return A2JITAutoPairingBlockerDDIMissing;
        default:                                        return A2JITAutoPairingBlockerPreconditionUnconfirmed;
    }
}

/// blocker → 步骤落点（供日志 / UI 指出失败发生在链路哪一环）。
static A2JITAutoPairingStep A2StepForBlocker(A2JITAutoPairingBlocker blocker) {
    switch (blocker) {
        case A2JITAutoPairingBlockerDiscoveryFailed:  return A2JITAutoPairingStepDiscovery;
        case A2JITAutoPairingBlockerRSDConnectFailed: return A2JITAutoPairingStepRSDConnect;
        case A2JITAutoPairingBlockerPairVerifyFailed: return A2JITAutoPairingStepPairVerify;
        case A2JITAutoPairingBlockerTunnelFailed:     return A2JITAutoPairingStepTunnel;
        case A2JITAutoPairingBlockerWriteFailed:      return A2JITAutoPairingStepWriteFile;
        default:                                      return A2JITAutoPairingStepIdle;
    }
}

@interface A2JITAutomaticPairingProvider ()
@property (nonatomic, strong) A2JITFacts *facts;
@property (nonatomic, strong) A2JITAutoPairingPreconditions *preconditions;
@property (nonatomic, strong, nullable) id<A2JITAutoPairingEngine> engine;
@property (nonatomic, strong) A2JITPairingFileStore *store;
@property (nonatomic, strong, nullable) id<A2JITReadinessProbe> probe;
@property (nonatomic, readwrite) NSTimeInterval generationBudget;
@property (nonatomic, readwrite) NSTimeInterval pairingFileMaxAge;
@property (nonatomic, readwrite) A2JITAutoPairingStep lastStep;
@property (nonatomic, readwrite) A2JITAutoPairingBlocker lastBlocker;
@property (nonatomic, readwrite) A2JITReadinessVerdict lastVerdict;
@property (nonatomic, readwrite, copy, nullable) NSString *lastEvidence;

/// [JIT-DDI-1] DDI 那一项的取证（仅 DDI 且有探测时返回；供「缺什么报什么」更具体）。
- (nullable NSString *)ddiEvidenceForPrecondition:(A2JITAutoPairingPrecondition)precondition;
@end

@implementation A2JITAutomaticPairingProvider

+ (NSTimeInterval)defaultGenerationBudget {
    return kA2JITAutoPairingDefaultBudget;
}

+ (NSTimeInterval)defaultPairingFileMaxAge {
    return kA2JITAutoPairingFileMaxAge;
}

#pragma mark - 装配

- (instancetype)initWithFacts:(A2JITFacts *)facts {
    // 兼容旧装配：前置条件未知 + 无引擎 ⇒ 后面会【如实】报「未确认 / 未接入」，不假装成功。
    return [self initWithFacts:facts preconditions:nil engine:nil ddiProbe:nil store:nil probe:nil];
}

- (instancetype)initWithFacts:(A2JITFacts *)facts
                preconditions:(nullable A2JITAutoPairingPreconditions *)preconditions
                       engine:(nullable id<A2JITAutoPairingEngine>)engine
                        store:(nullable A2JITPairingFileStore *)store
                        probe:(nullable id<A2JITReadinessProbe>)probe {
    return [self initWithFacts:facts
                 preconditions:preconditions
                        engine:engine
                      ddiProbe:nil
                         store:store
                         probe:probe];
}

- (instancetype)initWithFacts:(A2JITFacts *)facts
                preconditions:(nullable A2JITAutoPairingPreconditions *)preconditions
                       engine:(nullable id<A2JITAutoPairingEngine>)engine
                     ddiProbe:(nullable id<A2JITDDIProbe>)ddiProbe
                        store:(nullable A2JITPairingFileStore *)store
                        probe:(nullable id<A2JITReadinessProbe>)probe {
    NSParameterAssert(facts);
    self = [super init];
    if (self) {
        _facts = facts;
        _preconditions = preconditions ?: [A2JITAutoPairingPreconditions unknownPreconditions];
        _engine = engine;
        _ddiProbe = ddiProbe;
        _store = store ?: [A2JITPairingFileStore defaultStore];
        _probe = probe;
        _generationBudget = kA2JITAutoPairingDefaultBudget;
        _pairingFileMaxAge = kA2JITAutoPairingFileMaxAge;
        _lastStep = A2JITAutoPairingStepIdle;
        _lastBlocker = A2JITAutoPairingBlockerNone;
        _lastVerdict = A2JITReadinessVerdictUnknown;
    }
    return self;
}

#pragma mark - [JIT-DDI-1] DDI 前置条件的真三态

- (nullable A2JITDDIStatus *)ddiStatus {
    return self.ddiProbe ? [self.ddiProbe ddiStatus] : nil;
}

- (A2JITAutoPairingPreconditions *)effectivePreconditions {
    A2JITAutoPairingPreconditions *base = self.preconditions;
    // ★未注入探测 ⇒ 沿用注入值（通常是 Unknown）★：绝不因「没探测到」就当成满足。
    if (self.ddiProbe == nil) {
        return base;
    }
    A2JITDDIStatus *st = [self.ddiProbe ddiStatus];
    if (st == nil) {
        return base;
    }
    A2JITAutoPairingPreconditionState ddiState =
        [A2JITDDIGuidance preconditionStateForVerdict:st.verdict];
    return [A2JITAutoPairingPreconditions
            preconditionsWithDeveloperMode:[base stateForPrecondition:A2JITAutoPairingPreconditionDeveloperMode]
                              localNetwork:[base stateForPrecondition:A2JITAutoPairingPreconditionLocalNetwork]
                              getTaskAllow:[base stateForPrecondition:A2JITAutoPairingPreconditionGetTaskAllow]
                                       ddi:ddiState];
}

#pragma mark - 身份与能力

- (A2JITProviderKind)kind {
    return A2JITProviderKindAutomaticPairing;
}

- (NSString *)displayName {
    return @"设备内自动配对";
}

- (BOOL)isAvailable {
    // 仅 iOS 27+ 有用户可见的设备内自动配对（iOS 18–26.7 仍需配对文件 + PC）。
    return [self.facts supportsAutomaticPairing];
}

- (nullable NSString *)pairingFilePath {
    return self.store.importedFilePath;
}

#pragma mark - 就绪判定（真探测 + 新鲜度）

- (BOOL)hasFreshUsablePairingFile {
    // ★真去容器里找 + 解析★（不是查缓存、不是恒 NO）。
    if (!self.store.hasUsablePairingFile) {
        return NO;
    }
    NSDictionary<NSString *, id> *meta = self.store.importedMetadata;
    NSDate *importedAt = meta[A2JITPairingFileStoreImportedAtKey];
    if (![importedAt isKindOfClass:NSDate.class]) {
        // 无法判新鲜度：★不谎报「过期」，也不谎报「刚生成」★——按可用处理并明确记录。
        NSLog(@"[A2JIT] autopair: 配对文件无导入时间元数据（无法判新鲜度）⇒ 按可用处理，记录以备核查");
        return YES;
    }
    NSTimeInterval age = -[importedAt timeIntervalSinceNow];
    if (age < 0) {
        age = 0;   // 时钟回拨：按「刚生成」处理，不因此判过期
    }
    if (age > self.pairingFileMaxAge) {
        NSLog(@"[A2JIT] autopair: 配对文件已过期 age=%.0fs > max=%.0fs",
              age, self.pairingFileMaxAge);
        return NO;
    }
    return YES;
}

- (BOOL)isPairingReady {
    return [self hasFreshUsablePairingFile];
}

- (BOOL)canGeneratePairingFile {
    // ★用生效的前置条件★（DDI 那一项在有探测时以探测结果为准；无探测时沿用注入值）。
    return [self effectivePreconditions].allSatisfied && (self.engine != nil) && [self.engine isEngineAvailable];
}

- (nullable NSNumber *)firstBlockingPrecondition {
    A2JITAutoPairingPreconditions *pc = [self effectivePreconditions];
    NSNumber *unsatisfied = [pc firstUnsatisfiedPrecondition];
    if (unsatisfied) {
        return unsatisfied;
    }
    return [pc firstUnconfirmedPrecondition];
}

- (nullable NSString *)blockingPreconditionReasonKey {
    // ★三态要分清★：明确未满足 ⇒「未满足」；仅无法确认 ⇒「未确认」（不把 Unknown 说成未满足）。
    A2JITAutoPairingPreconditions *pc = [self effectivePreconditions];
    if ([pc firstUnsatisfiedPrecondition]) {
        return @"jit.row.autopair.precondMissing";
    }
    if ([pc firstUnconfirmedPrecondition]) {
        return @"jit.row.autopair.precondUnknown";
    }
    return nil;
}

#pragma mark - 小工具

- (void)logStep:(A2JITAutoPairingStep)step
        blocker:(A2JITAutoPairingBlocker)blocker
       evidence:(nullable NSString *)evidence {
    NSLog(@"%@", [A2JITAutoPairingGuidance logLineWithProvider:self.displayName
                                                          step:step
                                                       blocker:blocker
                                                      evidence:evidence]);
}

/// [JIT-DDI-1] DDI 项的取证：只有 DDI 那一项、且注入了探测时才有（其余项返回 nil）。
- (nullable NSString *)ddiEvidenceForPrecondition:(A2JITAutoPairingPrecondition)precondition {
    if (precondition != A2JITAutoPairingPreconditionDDI) {
        return nil;
    }
    A2JITDDIStatus *st = [self ddiStatus];
    if (st == nil) {
        return nil;
    }
    // 带上判定名，便于把「无法确认」与「缺失」在日志里一眼分清。
    return [NSString stringWithFormat:@"%@｜%@",
            [A2JITDDI displayNameForVerdict:st.verdict], st.evidence];
}

#pragma mark - 取配对（前置检查 → 有界生成）

- (BOOL)preparePairingWithError:(NSError *_Nullable *_Nullable)error {
    self.lastStep = A2JITAutoPairingStepIdle;
    self.lastBlocker = A2JITAutoPairingBlockerNone;
    self.lastEvidence = nil;

    A2JITStrategy strategy = [A2JITStrategySelector strategyForFacts:self.facts];

    // ---- ① 已经就绪（新鲜文件在手）⇒ 无需生成 ----
    if ([self isPairingReady]) {
        [self logStep:A2JITAutoPairingStepDone blocker:A2JITAutoPairingBlockerNone
             evidence:[NSString stringWithFormat:@"已有新鲜配对文件 path=%@", self.pairingFilePath ?: @"?"]];
        return YES;
    }

    // ---- ② 有文件但已过期 ⇒ 如实报「过期」，不谎报可用 ----
    if (self.store.hasUsablePairingFile) {
        self.lastBlocker = A2JITAutoPairingBlockerStalePairingFile;
        [self logStep:A2JITAutoPairingStepWriteFile blocker:self.lastBlocker
             evidence:[NSString stringWithFormat:@"配对文件存在但已过期（窗口 %.0f 秒）", self.pairingFileMaxAge]];
        if (error) {
            *error = A2JITProviderFailureError([self messageForBlocker:self.lastBlocker detail:nil]);
        }
        return NO;
    }

    // ---- ③ 能力：非 iOS 27+ ⇒ 本路径不适用 ----
    if (![self.facts supportsAutomaticPairing]) {
        self.lastBlocker = A2JITAutoPairingBlockerSystemTooOld;
        [self logStep:A2JITAutoPairingStepIdle blocker:self.lastBlocker
             evidence:[NSString stringWithFormat:@"iOS %ld（本路径需 27+）",
                       (long)self.facts.osMajorVersion]];
        if (error) {
            *error = A2JITProviderFailureError([self messageForBlocker:self.lastBlocker
                                                                detail:[A2JITStrategySelector displayNameForStrategy:strategy]]);
        }
        return NO;
    }

    // ---- ④ 前置条件：缺什么报什么（未满足优先，其次未确认）----
    // ★用生效的前置条件★：DDI 那一项在有 ddiProbe 时是【真三态】（已就位 / 缺失 / 无法确认）。
    A2JITAutoPairingPreconditions *pcStates = [self effectivePreconditions];
    NSNumber *unsatisfied = [pcStates firstUnsatisfiedPrecondition];
    if (unsatisfied) {
        A2JITAutoPairingPrecondition pc = (A2JITAutoPairingPrecondition)unsatisfied.integerValue;
        self.lastBlocker = A2BlockerForPrecondition(pc);
        NSString *name = [A2JITStrings stringForKey:[A2JITAutoPairingGuidance nameKeyForPrecondition:pc]];
        NSString *ddiEv = [self ddiEvidenceForPrecondition:pc];
        NSString *detail = ddiEv.length ? [NSString stringWithFormat:@"%@（%@）", name, ddiEv] : name;
        [self logStep:A2JITAutoPairingStepIdle blocker:self.lastBlocker evidence:detail];
        if (error) {
            *error = A2JITProviderFailureError([self messageForBlocker:self.lastBlocker detail:detail]);
        }
        return NO;
    }
    NSNumber *unconfirmed = [pcStates firstUnconfirmedPrecondition];
    if (unconfirmed) {
        A2JITAutoPairingPrecondition pc = (A2JITAutoPairingPrecondition)unconfirmed.integerValue;
        self.lastBlocker = A2JITAutoPairingBlockerPreconditionUnconfirmed;
        NSString *name = [A2JITStrings stringForKey:[A2JITAutoPairingGuidance nameKeyForPrecondition:pc]];
        NSString *stateName = [A2JITStrings stringForKey:[A2JITAutoPairingGuidance stateKeyForPreconditionState:
                                                          A2JITAutoPairingPreconditionStateUnknown]];
        NSString *ddiEv = [self ddiEvidenceForPrecondition:pc];
        NSString *detail = [NSString stringWithFormat:@"%@（%@）%@", name, stateName,
                            ddiEv.length ? [NSString stringWithFormat:@"：%@", ddiEv] : @""];
        [self logStep:A2JITAutoPairingStepIdle blocker:self.lastBlocker evidence:detail];
        if (error) {
            *error = A2JITProviderFailureError([self messageForBlocker:self.lastBlocker detail:detail]);
        }
        return NO;
    }

    // ---- ⑤ 引擎：未接入 ⇒ 如实报「未接入」（与「真实执行失败」分开）----
    if (self.engine == nil || ![self.engine isEngineAvailable]) {
        self.lastBlocker = A2JITAutoPairingBlockerEngineUnavailable;
        [self logStep:A2JITAutoPairingStepIdle blocker:self.lastBlocker
             evidence:@"RPPairing 引擎未接入（Bridge → Natives 尚未落地）⇒ 交回编排层降级到 ②导入"];
        if (error) {
            *error = A2JITProviderNotImplementedError(@
                "设备内自动配对尚未接入：RPPairing（RSD + pair-verify + TLS-PSK）属下一阶段"
                "（见 docs/JIT-PROVISIONING.md §4.2）；本机可先用「导入配对文件」路径");
        }
        return NO;
    }

    // ---- ⑥ 有界生成（★绝不在主线程长时间等待★）----
    NSTimeInterval budget = self.generationBudget;
    if ([NSThread isMainThread]) {
        budget = MIN(budget, 1.5);
        NSLog(@"[A2JIT] autopair ★在主线程做有界等待★：预算收紧到 %.1fs（调用方应改到后台队列）", budget);
    }

    self.lastStep = A2JITAutoPairingStepDiscovery;
    NSString *why = nil;
    A2JITAutoPairingBlocker reported = A2JITAutoPairingBlockerNone;
    NSLog(@"[A2JIT] autopair 开始生成 budget=%.1fs preconditions=%@", budget, [self effectivePreconditions]);
    BOOL ok = [self.engine generatePairingFileWithinBudget:budget reason:&why blocker:&reported];
    self.lastEvidence = why;

    if (!ok) {
        if (reported == A2JITAutoPairingBlockerNone) {
            // 引擎没说原因：★不假装成功，也不假装「未接入」★——归到「写文件」这一步并注明。
            reported = A2JITAutoPairingBlockerWriteFailed;
            NSLog(@"[A2JIT] autopair 引擎未给出失败分类 ⇒ 归为 %@",
                  [A2JITAutoPairingGuidance displayNameForBlocker:reported]);
        }
        self.lastBlocker = reported;
        self.lastStep = A2StepForBlocker(reported);
        [self logStep:self.lastStep blocker:reported evidence:why];
        if (error) {
            *error = A2JITProviderFailureError([self messageForBlocker:reported detail:why]);
        }
        return NO;
    }

    // ---- ⑦ 成功 = 容器约定位置【真的】有一份可用且新鲜的文件（★不凭引擎一面之词★）----
    self.lastStep = A2JITAutoPairingStepWriteFile;
    if (![self isPairingReady]) {
        self.lastBlocker = A2JITAutoPairingBlockerWriteFailed;
        self.lastStep = A2JITAutoPairingStepWriteFile;
        [self logStep:self.lastStep blocker:self.lastBlocker
             evidence:@"引擎报告成功但容器约定位置没有可用配对文件"];
        if (error) {
            *error = A2JITProviderFailureError(@
                "自动配对引擎报告成功，但容器约定位置没有可解析的配对文件 —— 不视为成功（不谎报）");
        }
        return NO;
    }

    self.lastStep = A2JITAutoPairingStepDone;
    self.lastBlocker = A2JITAutoPairingBlockerNone;
    [self logStep:A2JITAutoPairingStepDone blocker:A2JITAutoPairingBlockerNone
         evidence:[NSString stringWithFormat:@"自动配对完成 path=%@", self.pairingFilePath ?: @"?"]];
    return YES;
}

#pragma mark - 开启 JIT（真调判据内核）

- (BOOL)refreshReadinessWithBudget:(NSTimeInterval)budget
                          evidence:(NSString *_Nullable *_Nullable)evidenceOut {
    if (self.probe == nil) {
        // ★不假装成功★：判据内核没接线就如实说 Unknown。
        self.lastVerdict = A2JITReadinessVerdictUnknown;
        self.lastEvidence = nil;
        if (evidenceOut) {
            *evidenceOut = nil;
        }
        NSLog(@"%@", [A2JITVerdictGuidance logLineWithProvider:self.displayName
                                                     strategy:[A2JITStrategySelector strategyForFacts:self.facts]
                                                      verdict:A2JITReadinessVerdictUnknown
                                                     evidence:@"判据内核未注入（Bridge 未接线）"]);
        return NO;
    }
    NSString *why = nil;
    BOOL ok = [self.probe ensureJITUsableWithinBudget:budget reason:&why];
    self.lastVerdict = [self.probe lastVerdict];
    self.lastEvidence = [self.probe lastEvidence] ?: why;
    if (evidenceOut) {
        *evidenceOut = self.lastEvidence;
    }
    NSLog(@"%@", [A2JITVerdictGuidance logLineWithProvider:self.displayName
                                                 strategy:[A2JITStrategySelector strategyForFacts:self.facts]
                                                  verdict:self.lastVerdict
                                                 evidence:self.lastEvidence]);
    return ok;
}

- (BOOL)activateJITWithError:(NSError *_Nullable *_Nullable)error {
    // iOS 17.4–25 没有内置开启能力（本路径也不适用）—— 如实返回未接入，让编排层降级。
    if (![self.facts supportsBuiltInHelper]) {
        if (error) {
            *error = A2JITProviderNotImplementedError(
                @"iOS 17.4–25 没有内置开启能力：请改用外部工具（StikDebug / SideStore…）启用 JIT");
        }
        return NO;
    }

    if (![self isPairingReady]) {
        if (error) {
            *error = A2JITProviderFailureError(@"配对材料未就绪：请先完成自动配对（或导入配对文件）");
        }
        return NO;
    }

    NSString *evidence = nil;
    if ([self refreshReadinessWithBudget:kA2JITAutoPairingActivationBudget evidence:&evidence]) {
        return YES;
    }
    if (error) {
        NSString *reason = [A2JITStrings stringForKey:[A2JITVerdictGuidance reasonKeyForVerdict:self.lastVerdict]];
        NSString *action = [A2JITStrings stringForKey:[A2JITVerdictGuidance actionKeyForVerdict:self.lastVerdict]];
        *error = A2JITProviderFailureError([NSString stringWithFormat:@"%@；%@%@",
                                            reason, action,
                                            evidence.length ? [NSString stringWithFormat:@"（取证：%@）", evidence] : @""]);
    }
    return NO;
}

- (NSString *)userActionHint {
    return @"iOS 27+：开启 Developer Mode 并授予本地网络权限后，点「开始自动配对」在本机生成配对文件";
}

#pragma mark - 文案

/// blocker 的本地化原因 + 下一步动作（★按分类分流★，不写万能文案）。
- (NSString *)messageForBlocker:(A2JITAutoPairingBlocker)blocker detail:(nullable NSString *)detail {
    NSString *reason = [A2JITStrings stringForKey:[A2JITAutoPairingGuidance reasonKeyForBlocker:blocker]];
    NSString *action = [A2JITStrings stringForKey:[A2JITAutoPairingGuidance actionKeyForBlocker:blocker]];
    return [NSString stringWithFormat:@"%@；%@%@", reason, action,
            detail.length ? [NSString stringWithFormat:@"（%@）", detail] : @""];
}

@end
