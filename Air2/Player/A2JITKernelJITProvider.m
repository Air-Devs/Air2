//
//  A2JITKernelJITProvider.m
//  Air2
//
//  [JIT-IMPL-2] 真调判据（复验），★不做启用★：
//    · isAvailable / isPairingReady 仍是能力判定（越狱 / TrollStore / dynamic-codesigning）；
//    · activateJITWithError: 改为真调注入的 A2JITReadinessProbe，按 verdict 如实回答
//      「本进程现在能不能用 JIT」——这才是 ADR-007 要的就绪判据（真能力，不是声明）。
//

#import "A2JITKernelJITProvider.h"
#import "A2JITFacts.h"
#import "A2JITStrategySelector.h"
#import "A2JITVerdictGuidance.h"
#import "A2JITStrings.h"

/// 复验预算（有界，绝不无限等）。
static const NSTimeInterval kA2JITKernelVerifyBudget = 3.0;

@interface A2JITKernelJITProvider ()
@property (nonatomic, strong) A2JITFacts *facts;
@property (nonatomic, strong, nullable) id<A2JITReadinessProbe> probe;
@property (nonatomic, readwrite) A2JITReadinessVerdict lastVerdict;
@property (nonatomic, readwrite, copy, nullable) NSString *lastEvidence;
@end

@implementation A2JITKernelJITProvider

- (instancetype)initWithFacts:(A2JITFacts *)facts {
    return [self initWithFacts:facts probe:nil];
}

- (instancetype)initWithFacts:(A2JITFacts *)facts
                        probe:(nullable id<A2JITReadinessProbe>)probe {
    NSParameterAssert(facts);
    self = [super init];
    if (self) {
        _facts = facts;
        _probe = probe;
        _lastVerdict = A2JITReadinessVerdictUnknown;
    }
    return self;
}

- (A2JITProviderKind)kind {
    return A2JITProviderKindKernel;
}

- (NSString *)displayName {
    return @"内核级 JIT";
}

- (BOOL)isAvailable {
    return [self.facts hasKernelJITEnvironment];
}

- (BOOL)isPairingReady {
    // 内核级路径不需要配对文件 / 隧道：环境具备即视为「配对就绪」。
    return self.isAvailable;
}

- (BOOL)refreshReadinessWithBudget:(NSTimeInterval)budget
                          evidence:(NSString *_Nullable *_Nullable)evidenceOut {
    if (self.probe == nil) {
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

- (BOOL)preparePairingWithError:(NSError *_Nullable *_Nullable)error {
    NSLog(@"[A2JIT] provider=%@ strategy=%@ 内核档无需配对文件（仅取配对）",
          self.displayName,
          [A2JITStrategySelector displayNameForStrategy:[A2JITStrategySelector strategyForFacts:self.facts]]);
    if (self.isAvailable) {
        return YES;
    }
    if (error) {
        *error = A2JITProviderFailureError(
            @"本机不具备内核级 JIT 环境（需越狱 / TrollStore / dynamic-codesigning）");
    }
    return NO;
}

- (BOOL)activateJITWithError:(NSError *_Nullable *_Nullable)error {
    A2JITStrategy strategy = [A2JITStrategySelector strategyForFacts:self.facts];

    if (!self.isAvailable) {
        if (error) {
            *error = A2JITProviderFailureError(@"本机不具备内核级 JIT 环境（越狱 / TrollStore / dynamic-codesigning）");
        }
        NSLog(@"%@", [A2JITVerdictGuidance logLineWithProvider:self.displayName
                                                     strategy:strategy
                                                      verdict:self.lastVerdict
                                                     evidence:@"环境不具备（未越狱 / 非巨魔 / 无 dynamic-codesigning）"]);
        return NO;
    }

    // ★真调判据★：越狱/巨魔只说明【环境能提供】，这里回答的是【本进程现在能不能用】。
    NSString *evidence = nil;
    if ([self refreshReadinessWithBudget:kA2JITKernelVerifyBudget evidence:&evidence]) {
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

@end
