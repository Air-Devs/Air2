//
//  A2JITCoordinator.m
//  Air2
//
//  JIT 供给编排实现。★只做状态推进与优先级判定，不含平台/网络细节★。
//  所有真正的动作（生成 / 导入 / 开启）都委托给注入的 A2JITProvider。
//  [JIT-IMPL] 状态迁移委托给 A2JITStateMachine（纯逻辑）：非法迁移被拒、状态不回退到已启用之外。
//

#import "A2JITCoordinator.h"
#import "A2JITFacts.h"
#import "A2JITStrategySelector.h"
#import "A2JITAutomaticPairingProvider.h"
#import "A2JITImportedPairingProvider.h"
#import "A2JITExternalToolProvider.h"
#import "A2JITKernelJITProvider.h"
#import "A2JITReadinessProbe.h"
#import "A2JITExternalToolLauncher.h"
#import "A2JITPairingFileStore.h"
#import "A2LaunchChain.h"

static NSString *const A2JITCoordinatorErrorDomain = @"A2JITCoordinatorError";

@interface A2JITCoordinator ()

@property (nonatomic, strong) A2JITFacts *facts;
@property (nonatomic, copy) NSArray<id<A2JITProvider>> *providers;
@property (nonatomic, strong) NSDictionary<NSNumber *, id<A2JITProvider>> *providersByKind;

/// [JIT-IMPL] 纯状态机（状态 / 原因 / 说明的唯一真相源）。
@property (nonatomic, strong) A2JITStateMachine *machine;

@property (nonatomic, readwrite) A2JITStrategy strategy;
@property (nonatomic, readwrite) BOOL hasActiveProvider;
@property (nonatomic, readwrite) A2JITProviderKind activeProviderKind;

- (void)settle:(A2JITState)state detail:(NSString *)detail reason:(A2JITFailureReason)reason;
- (void)evaluateStrategy;
- (NSArray<id<A2JITProvider>> *)orderedAvailableProviders;
- (nullable id<A2JITProvider>)firstAvailableProvider;
- (A2JITFailureReason)reasonForPairingFailureOfKind:(A2JITProviderKind)kind;
- (BOOL)failWithReason:(A2JITFailureReason)reason
                 error:(NSError *_Nullable *_Nullable)error
               message:(NSString *)message;

@end

@implementation A2JITCoordinator

#pragma mark - 对外的只读转发（状态机是唯一真相源）

- (A2JITState)state {
    return self.machine.state;
}

- (A2JITFailureReason)failureReason {
    return self.machine.failureReason;
}

- (NSString *)statusDetail {
    return self.machine.statusDetail;
}

#pragma mark - 装配

- (instancetype)initWithFacts:(A2JITFacts *)facts
                    providers:(NSArray<id<A2JITProvider>> *)providers {
    NSParameterAssert(facts);
    NSParameterAssert(providers);
    self = [super init];
    if (self) {
        _facts = facts;
        _providers = [providers copy];

        NSMutableDictionary<NSNumber *, id<A2JITProvider>> *byKind = [NSMutableDictionary dictionary];
        for (id<A2JITProvider> provider in providers) {
            byKind[@(provider.kind)] = provider;
        }
        _providersByKind = [byKind copy];

        _machine = [[A2JITStateMachine alloc] initWithState:A2JITStateUnavailable];
        _strategy = A2JITStrategyUnavailable;
        _hasActiveProvider = NO;
        _activeProviderKind = A2JITProviderKindImportedPairing;

        [self refreshState];
    }
    return self;
}

+ (NSArray<id<A2JITProvider>> *)defaultProvidersWithFacts:(A2JITFacts *)facts {
    // 不注入机制依赖：能力检测与就绪判定照常，开启会如实失败（不假装成功）。
    return [self providersWithFacts:facts probe:nil launcher:nil pairingFileStore:nil];
}

+ (NSArray<id<A2JITProvider>> *)providersWithFacts:(A2JITFacts *)facts
                                             probe:(nullable id<A2JITReadinessProbe>)probe
                                          launcher:(nullable id<A2JITExternalToolLauncher>)launcher
                                 pairingFileStore:(nullable A2JITPairingFileStore *)store {
    // [JIT-AUTOPAIR-1] 旧签名等价于「不注入自动配对前置/引擎」⇒ ① 会如实报未确认/未接入。
    return [self providersWithFacts:facts
                      preconditions:nil
                             engine:nil
                              probe:probe
                           launcher:launcher
                  pairingFileStore:store];
}

+ (NSArray<id<A2JITProvider>> *)providersWithFacts:(A2JITFacts *)facts
                                      preconditions:(nullable A2JITAutoPairingPreconditions *)preconditions
                                             engine:(nullable id<A2JITAutoPairingEngine>)engine
                                              probe:(nullable id<A2JITReadinessProbe>)probe
                                           launcher:(nullable id<A2JITExternalToolLauncher>)launcher
                                  pairingFileStore:(nullable A2JITPairingFileStore *)store {
    NSParameterAssert(facts);
    // ★[JIT-IMPL-2]★ 判据内核（probe）同时注入 ② 导入 / ③ 外部 / ④ 内核三条路径：
    // 它们都要靠 A2JITEnvironment 的真实判据说话，而不是靠「能力声明」。
    // ★[JIT-AUTOPAIR-1]★ ① 自动配对另注入前置条件与 RPPairing 引擎（真机 = Bridge → Natives）。
    A2JITPairingFileStore *fileStore = store ?: [A2JITPairingFileStore defaultStore];
    return @[ [[A2JITAutomaticPairingProvider alloc] initWithFacts:facts
                                                     preconditions:preconditions
                                                            engine:engine
                                                             store:fileStore
                                                             probe:probe],
              [[A2JITImportedPairingProvider alloc] initWithFacts:facts store:fileStore probe:probe],
              [[A2JITExternalToolProvider alloc] initWithFacts:facts
                                                      launcher:launcher
                                                         probe:probe
                                                    waitBudget:0
                                                  pollInterval:0],
              [[A2JITKernelJITProvider alloc] initWithFacts:facts probe:probe] ];
}

- (BOOL)readyToRunGame {
    return self.state == A2JITStateEnabled;
}

#pragma mark - 状态推进

- (void)settle:(A2JITState)state detail:(NSString *)detail reason:(A2JITFailureReason)reason {
    // [JIT-IMPL] 先过状态机：非法迁移被拒（状态不变），并留下日志便于回溯。
    BOOL moved = [self.machine transitionTo:state reason:reason detail:detail];
    if (!moved) {
        NSLog(@"[A2JIT] 非法状态迁移被拒: %@ -> %@（保持 %@）",
              [A2JITStateMachine displayNameForState:self.machine.state],
              [A2JITStateMachine displayNameForState:state],
              [A2JITStateMachine displayNameForState:self.machine.state]);
        return;
    }
    NSLog(@"[A2JIT] state=%@ reason=%@ strategy=%@ %@",
          [A2JITStateMachine displayNameForState:self.machine.state],
          [A2JITStateMachine displayNameForFailureReason:self.machine.failureReason],
          [A2JITStrategySelector displayNameForStrategy:self.strategy],
          self.machine.statusDetail);
}

- (void)evaluateStrategy {
    self.strategy = [A2JITStrategySelector strategyForFacts:self.facts];
}

/// 策略内【可用】的 Provider，按优先级排序（用于选路与逐级回退）。
- (NSArray<id<A2JITProvider>> *)orderedAvailableProviders {
    NSMutableArray<id<A2JITProvider>> *out = [NSMutableArray array];
    NSArray<NSNumber *> *ordered = [A2JITStrategySelector orderedProviderKindsForStrategy:self.strategy];
    for (NSNumber *kind in ordered) {
        id<A2JITProvider> provider = self.providersByKind[kind];
        if (provider && provider.isAvailable) {
            [out addObject:provider];
        }
    }
    return [out copy];
}

- (id<A2JITProvider>)firstAvailableProvider {
    return [self orderedAvailableProviders].firstObject;
}

- (void)refreshState {
    // 已启用是终态：JIT 一旦拿到不会撤销，不因一次探测抖动把状态复位。
    if (self.state == A2JITStateEnabled) {
        return;
    }

    [self evaluateStrategy];

    if (self.strategy == A2JITStrategyUnavailable) {
        self.hasActiveProvider = NO;
        [self settle:A2JITStateUnavailable
              detail:@"系统版本不支持远程调试式 JIT（需 iOS 17.4+；iOS 16- 需越狱 / TrollStore）"
              reason:A2JITFailureReasonSystemTooOld];
        return;
    }

    id<A2JITProvider> provider = [self firstAvailableProvider];
    if (!provider) {
        self.hasActiveProvider = NO;
        [self settle:A2JITStateUnavailable
              detail:@"本机没有可用的 JIT 取得路径（检查签名能力 / 外部工具 / 配对文件）"
              reason:A2JITFailureReasonNoProvider];
        return;
    }

    self.hasActiveProvider = YES;
    self.activeProviderKind = provider.kind;

    // ★[JIT-IMPL-2] 状态机 ↔ 真实事件对齐★：每轮评估都留一行「选了哪条路、档位、就绪否」。
    NSLog(@"[A2JIT] 选中取得路径=%@(kind=%ld) 档位=%@ 配对就绪=%d",
          provider.displayName, (long)provider.kind,
          [A2JITStrategySelector displayNameForStrategy:self.strategy],
          (int)provider.isPairingReady);

    if (!provider.isPairingReady) {
        [self settle:A2JITStateWaitingPairing
              detail:[NSString stringWithFormat:@"等待配对材料（%@）", provider.displayName]
              reason:A2JITFailureReasonPairingMissing];
        return;
    }

    [self settle:A2JITStatePaired
          detail:[NSString stringWithFormat:@"已配对（%@），等待开启 JIT", provider.displayName]
          reason:A2JITFailureReasonNone];
}

#pragma mark - 取得配对

- (BOOL)acquirePairingWithError:(NSError *_Nullable *_Nullable)error {
    [self refreshState];

    if (self.state == A2JITStatePaired || self.state == A2JITStateEnabled) {
        return YES;
    }
    if (self.state != A2JITStateWaitingPairing) {
        return [self failWithReason:self.failureReason error:error message:self.statusDetail];
    }

    // 按策略内的优先级逐条尝试；任一条成功即推进，全部失败才报「最后一条」的原因。
    A2JITFailureReason lastReason = A2JITFailureReasonPairingMissing;
    NSError *lastErr = nil;
    for (id<A2JITProvider> provider in [self orderedAvailableProviders]) {
        NSError *prepareErr = nil;
        if ([provider preparePairingWithError:&prepareErr]) {
            [self refreshState];
            return YES;
        }
        lastReason = [self reasonForPairingFailureOfKind:provider.kind];
        lastErr = prepareErr;
        NSLog(@"[A2JIT] 取配对未成功（%@）: %@",
              provider.displayName, prepareErr.localizedDescription ?: @"(无详情)");
    }

    NSString *message = lastErr.localizedDescription ?: @"取得配对材料失败";
    return [self failWithReason:lastReason error:error message:message];
}

- (A2JITFailureReason)reasonForPairingFailureOfKind:(A2JITProviderKind)kind {
    switch (kind) {
        case A2JITProviderKindAutomaticPairing: return A2JITFailureReasonAutoPairingNotBuilt;
        case A2JITProviderKindExternalTool:     return A2JITFailureReasonExternalToolMissing;
        case A2JITProviderKindKernel:           return A2JITFailureReasonKernelJITUnavailable;
        case A2JITProviderKindImportedPairing:
        default:                                return A2JITFailureReasonPairingMissing;
    }
}

#pragma mark - 开启 JIT

- (BOOL)enableJITWithError:(NSError *_Nullable *_Nullable)error {
    if (self.state == A2JITStateEnabled) {
        return YES;
    }
    if (self.state != A2JITStatePaired) {
        [self refreshState];
    }
    if (self.state == A2JITStateEnabled) {
        return YES;
    }
    if (self.state != A2JITStatePaired) {
        return [self failWithReason:self.failureReason error:error message:self.statusDetail];
    }

    [self settle:A2JITStateWaitingActivation detail:@"正在开启 JIT…" reason:A2JITFailureReasonNone];

    // 按优先级逐条尝试（只试【配对材料已就绪】的那些）。
    NSError *lastErr = nil;
    for (id<A2JITProvider> provider in [self orderedAvailableProviders]) {
        if (!provider.isPairingReady) {
            continue;
        }
        NSError *activateErr = nil;
        if ([provider activateJITWithError:&activateErr]) {
            [self settle:A2JITStateEnabled
                  detail:[NSString stringWithFormat:@"JIT 已启用（%@）", provider.displayName]
                  reason:A2JITFailureReasonNone];
            return YES;
        }
        lastErr = activateErr;
        NSLog(@"[A2JIT] 开启 JIT 未成功（%@）: %@",
              provider.displayName, activateErr.localizedDescription ?: @"(无详情)");
    }

    // 开启失败不回退到「未配对」——配对材料仍在，只是本次没成。
    NSString *message = lastErr.localizedDescription ?: @"开启 JIT 失败（无可用路径）";
    [self settle:A2JITStateWaitingActivation detail:message reason:A2JITFailureReasonActivationFailed];
    if (error) {
        *error = lastErr;
    }
    return NO;
}

#pragma mark - 「先 JIT 后启 JVM」钩子

- (BOOL)prepareJITThenRunLaunchChain:(A2LaunchChain *)chain
                               error:(NSError *_Nullable *_Nullable)error {
    NSParameterAssert(chain);

    if (!self.readyToRunGame) {
        [self enableJITWithError:NULL];
    }

    if (!self.readyToRunGame) {
        NSLog(@"[A2JIT] JIT 未就绪，已阻止启动链（绝不带病建 VM）: %@", self.statusDetail);
        if (error) {
            *error = [NSError errorWithDomain:A2JITCoordinatorErrorDomain
                                         code:self.failureReason
                                     userInfo:@{ NSLocalizedDescriptionKey: self.statusDetail }];
        }
        return NO;
    }

    NSLog(@"[A2JIT] JIT 已启用，交给启动链（先 JIT 后启 JVM）");
    return [chain runWithError:error];
}

#pragma mark - 错误

- (BOOL)failWithReason:(A2JITFailureReason)reason
                 error:(NSError *_Nullable *_Nullable)error
               message:(NSString *)message {
    [self settle:self.state detail:message reason:reason];
    if (error) {
        *error = [NSError errorWithDomain:A2JITCoordinatorErrorDomain
                                     code:reason
                                 userInfo:@{ NSLocalizedDescriptionKey: message }];
    }
    return NO;
}

@end
