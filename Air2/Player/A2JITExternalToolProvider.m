//
//  A2JITExternalToolProvider.m
//  Air2
//
//  [JIT-IMPL-2] 真实现：拉起 → 有界等待 → 轮询判据 → 超时即明确失败。
//  ★无 UIKit★：拉起经注入的 A2JITExternalToolLauncher，判据经注入的
//  A2JITReadinessProbe（真机分别由 UI / Bridge 提供 ⇒ 本文件可单测）。
//

#import "A2JITExternalToolProvider.h"
#import "A2JITFacts.h"
#import "A2JITStrategySelector.h"
#import "A2JITVerdictGuidance.h"
#import "A2JITStrings.h"

#import <unistd.h>

/// 默认等待预算与轮询间隔（外部工具要在后台把 JIT 挂上，再等用户切回来）。
static const NSTimeInterval kA2JITExternalDefaultWaitBudget = 20.0;
static const NSTimeInterval kA2JITExternalDefaultPollInterval = 0.5;
/// 单次判据探测的切片上限（与 A2JITEnvironment 内部的 slice 同量级，避免一发太长）。
static const NSTimeInterval kA2JITExternalProbeSlice = 3.0;

@interface A2JITExternalToolProvider ()
@property (nonatomic, strong) A2JITFacts *facts;
@property (nonatomic, strong, nullable) id<A2JITExternalToolLauncher> launcher;
@property (nonatomic, strong, nullable) id<A2JITReadinessProbe> probe;
@property (nonatomic, readwrite) NSTimeInterval activationWaitBudget;
@property (nonatomic, readwrite) NSTimeInterval pollInterval;
@property (nonatomic, readwrite, copy, nullable) NSURL *lastLaunchedURL;
@property (nonatomic, readwrite) A2JITReadinessVerdict lastVerdict;
@property (nonatomic, readwrite, copy, nullable) NSString *lastEvidence;
@end

@implementation A2JITExternalToolProvider

#pragma mark - 登记的 scheme

+ (NSArray<NSString *> *)registeredToolSchemes {
    // 来源：docs/JIT-PROVISIONING.md §4.3-b（探测面宽：stikdebug / stikjit / sidestore / stosdebug）。
    return @[ @"stikdebug", @"stikjit", @"sidestore", @"stosdebug" ];
}

+ (nullable NSURL *)launchURLForScheme:(NSString *)scheme {
    if (scheme.length == 0) {
        return nil;
    }
    return [NSURL URLWithString:[scheme stringByAppendingString:@"://enable-jit"]];
}

#pragma mark - 装配

- (instancetype)initWithFacts:(A2JITFacts *)facts {
    return [self initWithFacts:facts launcher:nil probe:nil waitBudget:0 pollInterval:0];
}

- (instancetype)initWithFacts:(A2JITFacts *)facts
                     launcher:(nullable id<A2JITExternalToolLauncher>)launcher
                        probe:(nullable id<A2JITReadinessProbe>)probe
                   waitBudget:(NSTimeInterval)waitBudget
                 pollInterval:(NSTimeInterval)pollInterval {
    NSParameterAssert(facts);
    self = [super init];
    if (self) {
        _facts = facts;
        _launcher = launcher;
        _probe = probe;
        _activationWaitBudget = waitBudget > 0 ? waitBudget : kA2JITExternalDefaultWaitBudget;
        _pollInterval = pollInterval > 0 ? pollInterval : kA2JITExternalDefaultPollInterval;
        _lastVerdict = A2JITReadinessVerdictUnknown;
    }
    return self;
}

#pragma mark - 身份与能力

- (A2JITProviderKind)kind {
    return A2JITProviderKindExternalTool;
}

- (NSString *)displayName {
    return @"外部工具";
}

- (BOOL)isAvailable {
    // [JIT-IMPL-2] ★未安装 ⇒ 不可用★：编排层不会选中它，设置页据此置灰并写「未安装」。
    return [self.facts supportsRemoteDebugJIT] && self.facts.hasExternalEnablerInstalled;
}

- (BOOL)isPairingReady {
    // 装了外部使能器即视为「可完成配对 + 开启」—— 它自带隧道与配对能力。
    return self.facts.hasExternalEnablerInstalled;
}

- (nullable NSURL *)firstLaunchableURL {
    if (self.launcher == nil) {
        return nil;
    }
    for (NSString *scheme in [A2JITExternalToolProvider registeredToolSchemes]) {
        NSURL *url = [A2JITExternalToolProvider launchURLForScheme:scheme];
        if (url && [self.launcher canOpenToolURL:url]) {
            return url;
        }
    }
    return nil;
}

#pragma mark - 取配对

- (BOOL)preparePairingWithError:(NSError *_Nullable *_Nullable)error {
    if (self.isPairingReady) {
        NSLog(@"[A2JIT] provider=%@ 已安装 ⇒ 视为配对就绪（自带隧道/配对能力）", self.displayName);
        return YES;
    }
    if (error) {
        *error = A2JITProviderFailureError(
            @"未检测到可拉起的外部工具：请安装 StikDebug / SideStore 等，并确认其 URL scheme 已登记在白名单（LSApplicationQueriesSchemes）");
    }
    NSLog(@"[A2JIT] provider=%@ strategy=%@ 未安装 ⇒ 本路径不可用",
          self.displayName,
          [A2JITStrategySelector displayNameForStrategy:[A2JITStrategySelector strategyForFacts:self.facts]]);
    return NO;
}

#pragma mark - 开启 JIT（拉起 + 有界等待 + 轮询判据）

- (BOOL)activateJITWithError:(NSError *_Nullable *_Nullable)error {
    A2JITStrategy strategy = [A2JITStrategySelector strategyForFacts:self.facts];

    if (!self.facts.hasExternalEnablerInstalled) {
        if (error) {
            *error = A2JITProviderFailureError(@"外部工具未安装：请在设备上安装 StikDebug / SideStore 等使能器");
        }
        NSLog(@"[A2JIT] provider=%@ 未安装 ⇒ 不尝试拉起", self.displayName);
        return NO;
    }
    if (self.launcher == nil || self.probe == nil) {
        if (error) {
            *error = A2JITProviderFailureError(@"外部工具拉起器或判据内核未注入（装配缺失）—— 不假装成功");
        }
        NSLog(@"[A2JIT] provider=%@ 装配缺失：launcher=%@ probe=%@",
              self.displayName, self.launcher ? @"有" : @"无", self.probe ? @"有" : @"无");
        return NO;
    }

    // 主线程上跑会把「有界等待」变成卡界面 ⇒ 收紧预算并明确告警（调用方应改到后台队列）。
    NSTimeInterval budget = self.activationWaitBudget;
    if ([NSThread isMainThread]) {
        budget = MIN(budget, 1.5);
        NSLog(@"[A2JIT] provider=%@ ★在主线程做有界等待★：预算收紧到 %.1fs（调用方应改到后台队列）",
              self.displayName, budget);
    }

    NSURL *url = [self firstLaunchableURL];
    if (url == nil) {
        if (error) {
            *error = A2JITProviderFailureError(
                @"已安装外部工具但无可拉起的 URL scheme：请确认 Info.plist 的 LSApplicationQueriesSchemes 已登记 stikdebug / stikjit / sidestore / stosdebug");
        }
        NSLog(@"[A2JIT] provider=%@ 无可拉起 scheme（登记表：%@）",
              self.displayName, [[A2JITExternalToolProvider registeredToolSchemes] componentsJoinedByString:@","]);
        return NO;
    }

    // 从外部工具切回前台后缓存可能还是旧的 ⇒ 先作废再开始等。
    if ([self.probe respondsToSelector:@selector(invalidateCache)]) {
        [self.probe invalidateCache];
    }

    NSDate *t0 = [NSDate date];
    self.lastLaunchedURL = url;
    BOOL opened = [self.launcher openToolURL:url];
    NSLog(@"[A2JIT] provider=%@ strategy=%@ launch=%@ opened=%d waitBudget=%.1fs poll=%.2fs",
          self.displayName, [A2JITStrategySelector displayNameForStrategy:strategy],
          url.absoluteString, (int)opened, budget, self.pollInterval);
    if (!opened) {
        if (error) {
            *error = A2JITProviderFailureError(
                [NSString stringWithFormat:@"拉起外部工具失败：%@", url.absoluteString]);
        }
        return NO;
    }

    // ---- 有界等待 + 轮询判据（★超时即失败，绝不无限等★）----
    while (YES) {
        NSTimeInterval remaining = budget - (-[t0 timeIntervalSinceNow]);
        if (remaining <= 0) {
            break;
        }
        NSString *why = nil;
        NSTimeInterval slice = MIN(kA2JITExternalProbeSlice, remaining);
        if ([self.probe ensureJITUsableWithinBudget:slice reason:&why]) {
            self.lastVerdict = [self.probe lastVerdict];
            self.lastEvidence = [self.probe lastEvidence] ?: why;
            NSLog(@"%@ elapsed=%.2fs",
                  [A2JITVerdictGuidance logLineWithProvider:self.displayName
                                                   strategy:strategy
                                                    verdict:self.lastVerdict
                                                   evidence:self.lastEvidence],
                  -[t0 timeIntervalSinceNow]);
            return YES;
        }
        self.lastVerdict = [self.probe lastVerdict];
        self.lastEvidence = [self.probe lastEvidence] ?: why;
        usleep((useconds_t)(self.pollInterval * 1000000.0));
    }

    // 超时：如实报失败 + 给出最后一发的判据/取证（便于真机定位）。
    NSTimeInterval waited = -[t0 timeIntervalSinceNow];
    NSLog(@"%@ 超时 elapsed=%.2fs（未在预算内检测到 JIT 可用）",
          [A2JITVerdictGuidance logLineWithProvider:self.displayName
                                            strategy:strategy
                                             verdict:self.lastVerdict
                                            evidence:self.lastEvidence],
          waited);
    if (error) {
        NSString *reason = [A2JITStrings stringForKey:[A2JITVerdictGuidance reasonKeyForVerdict:self.lastVerdict]];
        NSString *action = [A2JITStrings stringForKey:[A2JITVerdictGuidance actionKeyForVerdict:self.lastVerdict]];
        *error = A2JITProviderFailureError(
            [NSString stringWithFormat:@"等待外部工具超时（%.0f 秒未检测到 JIT 可用）：%@；%@%@",
             waited, reason, action,
             self.lastEvidence.length ? [NSString stringWithFormat:@"（取证：%@）", self.lastEvidence] : @""]);
    }
    return NO;
}

@end
