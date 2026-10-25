//
//  A2JITImportedPairingProvider.m
//  Air2
//
//  [JIT-IMPL-2] 真实现（取代占位）：
//    ① 就绪判定 —— 真的去容器约定位置找 + 解析配对文件；
//    ② 开启     —— 真调判据内核（注入的 A2JITReadinessProbe），按 verdict 如实判成败；
//    ③ 日志     —— 每步一行 [A2JIT]（Provider / 版本档 / verdict / 取证）。
//
//  ★边界★：本类不 import 任何 Natives 头（分层纪律），也绝不自己造 brk / mmap ——
//  判据一律来自注入的 probe（真机 = Bridge/A2JITEnvironmentProbe）。
//

#import "A2JITImportedPairingProvider.h"
#import "A2JITFacts.h"
#import "A2JITPairingFileStore.h"
#import "A2JITStrategySelector.h"
#import "A2JITVerdictGuidance.h"
#import "A2JITStrings.h"

/// iOS 26 内置手动档：开启时的复验预算（有界，绝不无限等 —— 见 ADR-007）。
static const NSTimeInterval kA2JITImportedActivationBudget = 3.0;

@interface A2JITImportedPairingProvider ()
@property (nonatomic, strong) A2JITFacts *facts;
@property (nonatomic, strong) A2JITPairingFileStore *store;
@property (nonatomic, strong, nullable) id<A2JITReadinessProbe> probe;
@property (nonatomic, readwrite) A2JITReadinessVerdict lastVerdict;
@property (nonatomic, readwrite, copy, nullable) NSString *lastEvidence;
@end

@implementation A2JITImportedPairingProvider

- (instancetype)initWithFacts:(A2JITFacts *)facts {
    return [self initWithFacts:facts store:[A2JITPairingFileStore defaultStore] probe:nil];
}

- (instancetype)initWithFacts:(A2JITFacts *)facts
                        store:(A2JITPairingFileStore *)store
                        probe:(nullable id<A2JITReadinessProbe>)probe {
    NSParameterAssert(facts);
    NSParameterAssert(store);
    self = [super init];
    if (self) {
        _facts = facts;
        _store = store;
        _probe = probe;
        _lastVerdict = A2JITReadinessVerdictUnknown;
    }
    return self;
}

#pragma mark - 身份与能力

- (A2JITProviderKind)kind {
    return A2JITProviderKindImportedPairing;
}

- (NSString *)displayName {
    return @"导入配对文件";
}

- (BOOL)isAvailable {
    // 这条路径的最低系统（配对文件 + 隧道式 JIT 需 17.4+）。
    return [self.facts supportsRemoteDebugJIT];
}

- (BOOL)isPairingReady {
    // [JIT-IMPL-2] ★真探测★：容器约定位置里有一份能解析的配对文件才算就绪。
    return self.store.hasUsablePairingFile;
}

- (nullable NSString *)pairingFilePath {
    return self.store.importedFilePath;
}

#pragma mark - 判据（真调）

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

#pragma mark - 取配对

- (BOOL)preparePairingWithError:(NSError *_Nullable *_Nullable)error {
    NSString *path = self.pairingFilePath;
    // 即使是「就绪」这一支，也把当前判据与取证打出来（真机一眼看全）。
    NSLog(@"%@ | pairingFile=%@", [A2JITVerdictGuidance logLineWithProvider:self.displayName
                                                                  strategy:[A2JITStrategySelector strategyForFacts:self.facts]
                                                                   verdict:self.lastVerdict
                                                                  evidence:self.lastEvidence],
          path ?: @"(尚未导入)");

    if (self.isPairingReady) {
        return YES;
    }
    if (error) {
        *error = A2JITProviderFailureError(
            @"尚未导入可用的配对文件：请在「设置 → 运行环境 · JIT」导入 .plist / .mobiledevicepairing（本机校验）");
    }
    return NO;
}

#pragma mark - 开启 JIT

- (BOOL)activateJITWithError:(NSError *_Nullable *_Nullable)error {
    A2JITStrategy strategy = [A2JITStrategySelector strategyForFacts:self.facts];

    // iOS 17.4–25：本路径没有内置开启能力（要靠外部工具）—— 如实返回未接入，让编排层降级。
    if (![self.facts supportsBuiltInHelper]) {
        if (error) {
            *error = A2JITProviderNotImplementedError(
                @"iOS 17.4–25 没有内置开启能力：请改用外部工具（StikDebug / SideStore…）启用 JIT");
        }
        NSLog(@"[A2JIT] provider=%@ strategy=%@ 无内置开启能力 ⇒ 交由外部工具路径",
              self.displayName, [A2JITStrategySelector displayNameForStrategy:strategy]);
        return NO;
    }

    // ★真调判据★：有界复验「本进程现在能不能用 JIT」（真发 brk #0x69 + 区域取证）。
    NSString *evidence = nil;
    BOOL ok = [self refreshReadinessWithBudget:kA2JITImportedActivationBudget evidence:&evidence];
    if (ok) {
        return YES;
    }

    if (error) {
        // 失败文案★按 verdict 分流★（不写万能文案）。
        NSString *reason = [A2JITStrings stringForKey:[A2JITVerdictGuidance reasonKeyForVerdict:self.lastVerdict]];
        NSString *action = [A2JITStrings stringForKey:[A2JITVerdictGuidance actionKeyForVerdict:self.lastVerdict]];
        *error = A2JITProviderFailureError([NSString stringWithFormat:@"%@；%@%@",
                                            reason, action,
                                            evidence.length ? [NSString stringWithFormat:@"（取证：%@）", evidence] : @""]);
    }
    return NO;
}

@end
