//
//  jit_logic_tests.m
//  Air2
//
//  [JIT-IMPL] 单元测试（★真实实现★：直接编译并链接 Air2/Player 下的纯逻辑源文件，
//  不是 Python 镜像）。覆盖四件：
//    · A2JITStrategySelector  —— 分级表（26/27/17.5/17.3/16-越狱/内核）与 Provider 顺序；
//    · A2PairingFile          —— 合法样本 / 缺字段 / 损坏 base64 / 空文件 / 非法字段；
//    · A2JITStateMachine      —— 合法迁移链 + 非法迁移被拒（含终态 Enabled）；
//    · A2JITFacts             —— 注入假 source 后的能力判定。
//
//  运行：python3 tests/JIT/run_jit_tests.py   （macOS：clang + Foundation）
//  输出：每例一行 PASS/FAIL，末尾统计 PASS/FAIL 计数。
//

#import <Foundation/Foundation.h>
#import <stdio.h>

#import "A2JITFacts.h"
#import "A2JITProvider.h"
#import "A2JITStateMachine.h"
#import "A2JITStrategySelector.h"
#import "A2PairingFile.h"
#import "A2JITCoordinator.h"
#import "A2LaunchChain.h"
// [JIT-IMPL-2] 本单新增：判据缝 / 分流表 / 四语文案 / 配对文件存储 / 两条真实现 Provider
#import "A2JITReadinessProbe.h"
#import "A2JITExternalToolLauncher.h"
#import "A2JITVerdictGuidance.h"
#import "A2JITStrings.h"
#import "A2JITPairingFileStore.h"
#import "A2JITImportedPairingProvider.h"
#import "A2JITExternalToolProvider.h"
#import "A2JITLocalFactsSource.h"
// [JIT-AUTOPAIR-1] 自动配对：类型 / 前置条件 / 分流表 / 真实现 Provider
#import "A2JITAutoPairing.h"
#import "A2JITAutoPairingGuidance.h"
#import "A2JITAutomaticPairingProvider.h"
// ★跨层镜像的运行期断言用★：直接读 Natives 的判据枚举（-I Natives/Support，不链接其实现）。
#import "A2JITEnvironment.h"

static int gPass = 0;
static int gFail = 0;

static void ok(BOOL cond, NSString *name) {
    if (cond) {
        gPass++;
        printf("PASS  %s\n", name.UTF8String);
    } else {
        gFail++;
        printf("FAIL  %s\n", name.UTF8String);
    }
}

static void eqInt(NSInteger got, NSInteger want, NSString *name) {
    BOOL c = (got == want);
    ok(c, name);
    if (!c) printf("        got=%ld want=%ld\n", (long)got, (long)want);
}

static void eqStr(NSString *got, NSString *want, NSString *name) {
    BOOL c = (got == want) || (got != nil && [got isEqualToString:want]);
    ok(c, name);
    if (!c) printf("        got=%s want=%s\n",
                   got ? got.UTF8String : "(nil)", want ? want.UTF8String : "(nil)");
}

#pragma mark - [JIT-IMPL-2] 测试夹具：假拉起器 / 假判据 / 仓内文件路径

/// 仓内文件的绝对路径（测试直接读源码与 Info.plist，防止「两处漂移」）。
static NSString *RepoPath(NSString *relative) {
    // …/tests/JIT/jit_logic_tests.m → …/tests → 仓根
    NSString *here = [NSString stringWithUTF8String:__FILE__];
    NSString *testsDir = [[here stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSString *root = [testsDir stringByDeletingLastPathComponent];
    return [root stringByAppendingPathComponent:relative];
}

static NSString *TempDir(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"a2jit_store_%@", NSUUID.UUID.UUIDString]];
}

/// 假拉起器：记录被拉起的 URL，按白名单回答 canOpen。
@interface FakeLauncher : NSObject <A2JITExternalToolLauncher>
@property (nonatomic, strong) NSMutableSet<NSString *> *openableSchemes;
@property (nonatomic, strong) NSMutableArray<NSURL *> *openedURLs;
@property (nonatomic, assign) BOOL openResult;
@end

@implementation FakeLauncher
- (instancetype)init {
    self = [super init];
    if (self) {
        _openableSchemes = [NSMutableSet set];
        _openedURLs = [NSMutableArray array];
        _openResult = YES;
    }
    return self;
}
- (BOOL)canOpenToolURL:(NSURL *)url { return [self.openableSchemes containsObject:url.scheme]; }
- (BOOL)openToolURL:(NSURL *)url {
    [self.openedURLs addObject:url];
    return self.openResult;
}
@end

/// 假判据：前 failTimes 次返回 NO，之后返回 YES；alwaysFail 时恒 NO。
@interface FakeProbe : NSObject <A2JITReadinessProbe>
@property (nonatomic, assign) NSInteger failTimes;
@property (nonatomic, assign) NSInteger calls;
@property (nonatomic, assign) BOOL alwaysFail;
@property (nonatomic, assign) A2JITReadinessVerdict verdict;
@property (nonatomic, copy) NSString *evidence;
@property (nonatomic, assign) NSInteger invalidateCalls;
@end

@implementation FakeProbe
- (instancetype)init {
    self = [super init];
    if (self) {
        _evidence = @"fake-evidence";
        _verdict = A2JITReadinessVerdictNotServiced;
    }
    return self;
}
- (BOOL)ensureJITUsableWithinBudget:(NSTimeInterval)budget reason:(NSString *_Nullable *_Nullable)whyOut {
    (void)budget;
    self.calls += 1;
    BOOL usable = (!self.alwaysFail && self.calls > self.failTimes);
    if (whyOut) *whyOut = self.evidence;
    return usable;
}
- (A2JITReadinessVerdict)lastVerdict {
    return self.alwaysFail ? self.verdict : A2JITReadinessVerdictUsable;
}
- (nullable NSString *)lastEvidence { return self.evidence; }
- (void)invalidateCache { self.invalidateCalls += 1; }
@end

/// [JIT-AUTOPAIR-1] 假 RPPairing 引擎：可配置「是否接入 / 是否写文件 / 失败分类」，并记录调用。
/// （前置声明：样本构造在下方定义，假引擎要先用到。）
static NSData *PlistData(NSDictionary *dict);
static NSDictionary *RemotePairingSample(void);

@interface FakeAutoPairingEngine : NSObject <A2JITAutoPairingEngine>
@property (nonatomic, assign) BOOL engineAvailable;
@property (nonatomic, assign) BOOL succeed;
@property (nonatomic, assign) BOOL writeFileWhenSucceed;
@property (nonatomic, strong) A2JITAutoPairingPreconditions *preconditions;
@property (nonatomic, assign) A2JITAutoPairingBlocker failBlocker;
@property (nonatomic, copy) NSString *failReason;
@property (nonatomic, strong, nullable) A2JITPairingFileStore *store;
@property (nonatomic, assign) NSInteger generateCalls;
@property (nonatomic, assign) NSTimeInterval lastBudget;
@end

@implementation FakeAutoPairingEngine
- (instancetype)init {
    self = [super init];
    if (self) {
        _preconditions = [A2JITAutoPairingPreconditions allSatisfiedPreconditions];
        _failBlocker = A2JITAutoPairingBlockerNone;
        _failReason = @"fake engine 失败";
    }
    return self;
}
- (BOOL)isEngineAvailable { return self.engineAvailable; }
- (A2JITAutoPairingPreconditions *)readPreconditions { return self.preconditions; }
- (BOOL)generatePairingFileWithinBudget:(NSTimeInterval)budget
                                 reason:(NSString *_Nullable *_Nullable)whyOut
                                blocker:(A2JITAutoPairingBlocker *_Nullable)blockerOut {
    self.generateCalls += 1;
    self.lastBudget = budget;
    if (!self.succeed) {
        if (whyOut) *whyOut = self.failReason;
        if (blockerOut) *blockerOut = self.failBlocker;
        return NO;
    }
    if (self.writeFileWhenSucceed && self.store) {
        // 「真实现」会写文件；这里按需写一份合法样本，方便验「成功 = 文件真在」。
        [self.store importData:PlistData(RemotePairingSample()) sourceName:@"auto-pairing.mobiledevicepairing" error:NULL];
    }
    if (whyOut) *whyOut = @"fake engine 成功";
    if (blockerOut) *blockerOut = A2JITAutoPairingBlockerNone;
    return YES;
}
@end

#pragma mark - 假的本机事实来源（验证「探测可注入」）

@interface FakeFactsSource : NSObject <A2JITFactsSource>
@property (nonatomic, assign) NSInteger major;
@property (nonatomic, assign) NSInteger minor;
@property (nonatomic, assign) NSInteger env;
@property (nonatomic, assign) BOOL pairing;
@property (nonatomic, assign) BOOL enabler;
@property (nonatomic, assign) BOOL gta;
@property (nonatomic, assign) BOOL dcs;
@end

@implementation FakeFactsSource
- (NSInteger)osMajorVersion { return self.major; }
- (NSInteger)osMinorVersion { return self.minor; }
- (A2JITEnvironmentKind)environment { return (A2JITEnvironmentKind)self.env; }
- (BOOL)hasImportedPairingFile { return self.pairing; }
- (BOOL)hasExternalEnablerInstalled { return self.enabler; }
- (BOOL)hasGetTaskAllow { return self.gta; }
- (BOOL)hasDynamicCodesigning { return self.dcs; }
@end

static A2JITFacts *Facts(NSInteger maj, NSInteger min, A2JITEnvironmentKind env) {
    return [A2JITFacts factsWithOSMajorVersion:maj
                                   minorVersion:min
                                    environment:env
                       hasImportedPairingFile:NO
                  hasExternalEnablerInstalled:NO
                               hasGetTaskAllow:NO
                         hasDynamicCodesigning:NO];
}

static A2JITFacts *FactsPairing(NSInteger maj, NSInteger min, A2JITEnvironmentKind env, BOOL pairing) {
    return [A2JITFacts factsWithOSMajorVersion:maj
                                   minorVersion:min
                                    environment:env
                       hasImportedPairingFile:pairing
                  hasExternalEnablerInstalled:NO
                               hasGetTaskAllow:NO
                         hasDynamicCodesigning:NO];
}

#pragma mark - 假的 Provider（验证编排层逐级推进 / 回退）

@interface FakeProvider : NSObject <A2JITProvider>
@property (nonatomic, assign) A2JITProviderKind kind;
@property (nonatomic, assign, getter=isAvailable) BOOL available;
@property (nonatomic, assign, getter=isPairingReady) BOOL pairingReady;
@property (nonatomic, assign) BOOL prepareResult;
@property (nonatomic, assign) BOOL activateResult;
@property (nonatomic, assign) int activateCalls;
@end

@implementation FakeProvider
- (NSString *)displayName { return @"fake"; }
- (BOOL)preparePairingWithError:(NSError *_Nullable *_Nullable)error {
    if (!self.prepareResult && error) {
        *error = A2JITProviderNotImplementedError(@"fake prepare 失败");
    }
    return self.prepareResult;
}
- (BOOL)activateJITWithError:(NSError *_Nullable *_Nullable)error {
    self.activateCalls += 1;
    if (!self.activateResult && error) {
        *error = A2JITProviderNotImplementedError(@"fake activate 失败");
    }
    return self.activateResult;
}
@end

#pragma mark - 配对文件样本构造

static NSData *PlistData(NSDictionary *dict) {
    return [NSPropertyListSerialization dataWithPropertyList:dict
                                                      format:NSPropertyListXMLFormat_v1_0
                                                     options:0
                                                       error:NULL];
}

static NSData *Base64Wrapped(NSData *data) {
    return [[data base64EncodedStringWithOptions:0] dataUsingEncoding:NSUTF8StringEncoding];
}

static NSDictionary *RemotePairingSample(void) {
    return @{ @"identifier": @"00008030-001A2B3C4D5E6F70",
              @"public_key": [@"PUBKEY0123456789ABCDEF0123456789" dataUsingEncoding:NSUTF8StringEncoding],
              @"private_key": [@"PRIVKEY9876543210FEDCBA9876543210" dataUsingEncoding:NSUTF8StringEncoding] };
}

static NSDictionary *LockdownSample(void) {
    NSData *cert = [@"-----CERT-----" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *key = [@"-----KEY-----" dataUsingEncoding:NSUTF8StringEncoding];
    return @{ @"DeviceCertificate": cert,
              @"HostCertificate": cert,
              @"HostPrivateKey": key,
              @"RootCertificate": cert,
              @"HostID": @"HOST-UUID-0001",
              @"SystemBUID": @"BUID-0002",
              @"UDID": @"udid-lockdown-123" };
}

#pragma mark - ① 分级策略

static void testStrategy(void) {
    printf("\n=== ① 分级策略（A2JITStrategySelector）===\n");

    ok([A2JITStrategySelector strategyForFacts:Facts(26, 0, A2JITEnvironmentKindPlain)]
       == A2JITStrategyBuiltInManual, @"iOS 26 → 内置手动");
    ok([A2JITStrategySelector strategyForFacts:Facts(27, 0, A2JITEnvironmentKindPlain)]
       == A2JITStrategyAutomatic, @"iOS 27 → 自动");
    ok([A2JITStrategySelector strategyForFacts:Facts(17, 5, A2JITEnvironmentKindPlain)]
       == A2JITStrategyImportedExternal, @"iOS 17.5 → 导入 + 外部");
    ok([A2JITStrategySelector strategyForFacts:Facts(18, 2, A2JITEnvironmentKindPlain)]
       == A2JITStrategyImportedExternal, @"iOS 18.2 → 导入 + 外部");
    ok([A2JITStrategySelector strategyForFacts:Facts(17, 3, A2JITEnvironmentKindPlain)]
       == A2JITStrategyUnavailable, @"iOS 17.3（纯签名）→ 不可用");
    ok([A2JITStrategySelector strategyForFacts:Facts(16, 5, A2JITEnvironmentKindPlain)]
       == A2JITStrategyKernel, @"iOS 16.5（纯签名）→ 内核档");
    ok([A2JITStrategySelector strategyForFacts:Facts(16, 5, A2JITEnvironmentKindJailbroken)]
       == A2JITStrategyKernel, @"iOS 16.5（越狱）→ 内核级");
    ok([A2JITStrategySelector strategyForFacts:Facts(26, 0, A2JITEnvironmentKindTrollStore)]
       == A2JITStrategyKernel, @"iOS 26（TrollStore）→ 内核级优先");

    // 失败原因
    eqInt([A2JITStrategySelector decisionForFacts:Facts(17, 3, A2JITEnvironmentKindPlain)].failureReason,
          A2JITFailureReasonSystemTooOld, @"17.3 原因 = SystemTooOld");
    eqInt([A2JITStrategySelector decisionForFacts:Facts(16, 5, A2JITEnvironmentKindPlain)].failureReason,
          A2JITFailureReasonKernelJITUnavailable, @"16.5 纯签名 原因 = KernelJITUnavailable");
    eqInt([A2JITStrategySelector decisionForFacts:Facts(16, 5, A2JITEnvironmentKindJailbroken)].failureReason,
          A2JITFailureReasonNone, @"16.5 越狱 原因 = None");
    eqInt([A2JITStrategySelector decisionForFacts:Facts(26, 0, A2JITEnvironmentKindPlain)].failureReason,
          A2JITFailureReasonNone, @"26 原因 = None");

    // 策略 ↔ decision 一致
    eqInt([A2JITStrategySelector strategyForFacts:Facts(26, 0, A2JITEnvironmentKindPlain)],
          [A2JITStrategySelector decisionForFacts:Facts(26, 0, A2JITEnvironmentKindPlain)].strategy,
          @"strategyForFacts 与 decision 一致");

    // Provider 顺序
    NSArray<NSNumber *> *automatic = [A2JITStrategySelector orderedProviderKindsForStrategy:A2JITStrategyAutomatic];
    eqInt((NSInteger)automatic.count, 3, @"自动档 顺序含 3 条");
    eqInt(automatic.firstObject.integerValue, A2JITProviderKindAutomaticPairing, @"自动档 首选 = 自动配对");

    NSArray<NSNumber *> *manual = [A2JITStrategySelector orderedProviderKindsForStrategy:A2JITStrategyBuiltInManual];
    eqInt((NSInteger)manual.count, 2, @"26 手动档 顺序含 2 条");
    eqInt(manual.firstObject.integerValue, A2JITProviderKindImportedPairing, @"26 手动档 首选 = 导入");
    ok(![manual containsObject:@(A2JITProviderKindAutomaticPairing)], @"★26 手动档 不含自动配对★");

    NSArray<NSNumber *> *kernel = [A2JITStrategySelector orderedProviderKindsForStrategy:A2JITStrategyKernel];
    eqInt((NSInteger)kernel.count, 1, @"内核档 只有 1 条");
    eqInt(kernel.firstObject.integerValue, A2JITProviderKindKernel, @"内核档 = 内核");

    eqInt((NSInteger)[A2JITStrategySelector orderedProviderKindsForStrategy:A2JITStrategyUnavailable].count,
          0, @"不可用档 = 空顺序");
    ok([A2JITStrategySelector displayNameForStrategy:A2JITStrategyBuiltInManual].length > 0,
       @"策略展示名非空");
}

#pragma mark - ② 配对文件

static void testPairingFile(void) {
    printf("\n=== ② 配对文件（A2PairingFile）===\n");

    NSError *err = nil;

    // 合法：RemotePairing（原始 XML plist）
    err = nil;
    A2PairingFile *rp = [A2PairingFile pairingFileWithData:PlistData(RemotePairingSample()) error:&err];
    ok(rp != nil, @"RP 合法样本（原始 plist）解析成功");
    eqInt(rp.format, A2PairingFileFormatRemotePairing, @"RP 格式识别 = RemotePairing");
    eqStr(rp.deviceIdentifier, @"00008030-001A2B3C4D5E6F70", @"RP 设备标识 = identifier");
    ok(rp.isValid, @"RP isValid = YES");

    // 合法：RemotePairing（base64 包裹）
    err = nil;
    A2PairingFile *rpB64 = [A2PairingFile pairingFileWithData:Base64Wrapped(PlistData(RemotePairingSample()))
                                                        error:&err];
    ok(rpB64 != nil, @"RP 合法样本（base64 包裹）解析成功");
    eqInt(rpB64.format, A2PairingFileFormatRemotePairing, @"base64 包裹 格式 = RemotePairing");

    // 合法：Lockdown PairRecord
    err = nil;
    A2PairingFile *lk = [A2PairingFile pairingFileWithData:PlistData(LockdownSample()) error:&err];
    ok(lk != nil, @"Lockdown 合法样本解析成功");
    eqInt(lk.format, A2PairingFileFormatLockdownPairRecord, @"Lockdown 格式识别");
    eqStr(lk.deviceIdentifier, @"udid-lockdown-123", @"Lockdown 设备标识 = UDID");

    // 缺字段：RP 少 private_key
    err = nil;
    NSDictionary *missing = @{ @"identifier": @"X",
                               @"public_key": [@"P" dataUsingEncoding:NSUTF8StringEncoding] };
    A2PairingFile *bad = [A2PairingFile pairingFileWithData:PlistData(missing) error:&err];
    ok(bad == nil, @"缺字段 → 解析失败");
    eqInt(err.code, A2PairingFileErrorMissingFields, @"缺字段 错误码 = MissingFields");
    ok([err.localizedDescription containsString:@"private_key"], @"缺字段 文案点名 private_key");

    // 非法字段：private_key 类型错（字符串而非 data）
    err = nil;
    NSDictionary *invalid = @{ @"identifier": @"X",
                               @"public_key": [@"P" dataUsingEncoding:NSUTF8StringEncoding],
                               @"private_key": @"" };
    A2PairingFile *inv = [A2PairingFile pairingFileWithData:PlistData(invalid) error:&err];
    ok(inv == nil, @"字段非法 → 解析失败");
    eqInt(err.code, A2PairingFileErrorInvalidField, @"非法字段 错误码 = InvalidField");

    // 损坏 base64
    err = nil;
    NSData *brokenB64 = [@"!!!not*valid*base64###" dataUsingEncoding:NSUTF8StringEncoding];
    A2PairingFile *b64 = [A2PairingFile pairingFileWithData:brokenB64 error:&err];
    ok(b64 == nil, @"损坏 base64 → 解析失败");
    eqInt(err.code, A2PairingFileErrorMalformedBase64, @"损坏 base64 错误码 = MalformedBase64");

    // 空文件
    err = nil;
    A2PairingFile *empty = [A2PairingFile pairingFileWithData:[NSData data] error:&err];
    ok(empty == nil, @"空文件 → 解析失败");
    eqInt(err.code, A2PairingFileErrorEmpty, @"空文件 错误码 = Empty");

    // 仅空白
    err = nil;
    NSData *blank = [@"   \n\t  " dataUsingEncoding:NSUTF8StringEncoding];
    A2PairingFile *ws = [A2PairingFile pairingFileWithData:blank error:&err];
    ok(ws == nil, @"空白文件 → 解析失败");
    eqInt(err.code, A2PairingFileErrorEmpty, @"空白文件 错误码 = Empty");

    // 非 plist
    err = nil;
    NSData *junk = [@"<这不是 plist>" dataUsingEncoding:NSUTF8StringEncoding];
    A2PairingFile *np = [A2PairingFile pairingFileWithData:junk error:&err];
    ok(np == nil, @"非 plist → 解析失败");
    eqInt(err.code, A2PairingFileErrorNotPropertyList, @"非 plist 错误码 = NotPropertyList");

    // 必填字段表
    eqInt((NSInteger)[A2PairingFile requiredFieldsForFormat:A2PairingFileFormatRemotePairing].count, 3,
          @"RP 必填 = 3 项");
    eqInt((NSInteger)[A2PairingFile requiredFieldsForFormat:A2PairingFileFormatLockdownPairRecord].count, 6,
          @"Lockdown 必填 = 6 项");
}

#pragma mark - ③ 状态机

static void testStateMachine(void) {
    printf("\n=== ③ 状态机（A2JITStateMachine）===\n");

    // 合法迁移链
    A2JITStateMachine *m = [[A2JITStateMachine alloc] initWithState:A2JITStateUnavailable];
    ok([m transitionTo:A2JITStateWaitingPairing reason:A2JITFailureReasonPairingMissing detail:@"待配对"],
       @"Unavailable → WaitingPairing 合法");
    eqInt(m.state, A2JITStateWaitingPairing, @"状态 = WaitingPairing");
    ok([m transitionTo:A2JITStatePaired reason:A2JITFailureReasonNone detail:@"已配对"],
       @"WaitingPairing → Paired 合法");
    ok([m transitionTo:A2JITStateWaitingActivation reason:A2JITFailureReasonNone detail:@"开启中"],
       @"Paired → WaitingActivation 合法");
    ok([m transitionTo:A2JITStateEnabled reason:A2JITFailureReasonNone detail:@"已启用"],
       @"WaitingActivation → Enabled 合法");
    eqInt(m.state, A2JITStateEnabled, @"状态 = Enabled");

    // 终态 Enabled 不可离开
    ok(![m transitionTo:A2JITStateUnavailable reason:A2JITFailureReasonNoProvider detail:@""],
       @"★Enabled → Unavailable 被拒★");
    ok(![m transitionTo:A2JITStatePaired reason:A2JITFailureReasonNone detail:@""],
       @"★Enabled → Paired 被拒★");
    eqInt(m.state, A2JITStateEnabled, @"被拒后状态仍为 Enabled");

    // 非法跳跃
    A2JITStateMachine *m2 = [[A2JITStateMachine alloc] initWithState:A2JITStateUnavailable];
    ok(![m2 transitionTo:A2JITStateWaitingActivation reason:A2JITFailureReasonNone detail:@""],
       @"★Unavailable → WaitingActivation 被拒★");
    ok(![m2 transitionTo:A2JITStateEnabled reason:A2JITFailureReasonNone detail:@""],
       @"★Unavailable → Enabled 被拒★");
    eqInt(m2.state, A2JITStateUnavailable, @"被拒后仍为 Unavailable");

    A2JITStateMachine *m3 = [[A2JITStateMachine alloc] initWithState:A2JITStateWaitingPairing];
    ok(![m3 transitionTo:A2JITStateEnabled reason:A2JITFailureReasonNone detail:@""],
       @"★WaitingPairing → Enabled 被拒★");

    // 纯判定
    ok([A2JITStateMachine canTransitionFrom:A2JITStateWaitingPairing to:A2JITStatePaired], @"Pairing→Paired 合法");
    ok(![A2JITStateMachine canTransitionFrom:A2JITStateWaitingPairing to:A2JITStateEnabled], @"Pairing→Enabled 非法");
    ok(![A2JITStateMachine canTransitionFrom:A2JITStatePaired to:A2JITStateEnabled], @"Paired→Enabled 非法");
    ok([A2JITStateMachine canTransitionFrom:A2JITStateWaitingActivation to:A2JITStateEnabled], @"Activation→Enabled 合法");
    ok([A2JITStateMachine canTransitionFrom:A2JITStateEnabled to:A2JITStateEnabled], @"自迁移恒合法");
    ok(![A2JITStateMachine canTransitionFrom:A2JITStateEnabled to:A2JITStatePaired], @"Enabled→Paired 非法");

    // 自迁移更新原因（开启失败停留 WaitingActivation）
    A2JITStateMachine *m4 = [[A2JITStateMachine alloc] initWithState:A2JITStateWaitingActivation];
    ok([m4 transitionTo:A2JITStateWaitingActivation reason:A2JITFailureReasonActivationFailed detail:@"重试"],
       @"自迁移（停留 WaitingActivation）合法");
    eqInt(m4.state, A2JITStateWaitingActivation, @"自迁移后状态不变");
    eqInt(m4.failureReason, A2JITFailureReasonActivationFailed, @"自迁移更新原因");

    ok([A2JITStateMachine displayNameForState:A2JITStateEnabled].length > 0, @"状态展示名非空");
    ok([A2JITStateMachine displayNameForFailureReason:A2JITFailureReasonNoProvider].length > 0, @"原因展示名非空");
}

#pragma mark - ④ 事实探测（注入假 source）

static void testFactsProbe(void) {
    printf("\n=== ④ 事实探测（A2JITFacts + 注入 source）===\n");

    FakeFactsSource *s = [[FakeFactsSource alloc] init];
    s.major = 26; s.minor = 0; s.env = A2JITEnvironmentKindPlain;
    A2JITFacts *f26 = [A2JITFacts factsWithSource:s];
    eqInt(f26.osMajorVersion, 26, @"注入 source → major = 26");
    eqInt(f26.osMinorVersion, 0, @"注入 source → minor = 0");
    ok(f26.supportsBuiltInHelper, @"26 supportsBuiltInHelper = YES");
    ok(!f26.supportsAutomaticPairing, @"26 supportsAutomaticPairing = NO");
    ok(f26.supportsRemoteDebugJIT, @"26 supportsRemoteDebugJIT = YES");
    ok(!f26.hasKernelJITEnvironment, @"26 纯签名 hasKernelJITEnvironment = NO");

    s.major = 27; s.minor = 0;
    A2JITFacts *f27 = [A2JITFacts factsWithSource:s];
    ok(f27.supportsAutomaticPairing, @"27 supportsAutomaticPairing = YES");

    s.major = 17; s.minor = 3;
    ok(![A2JITFacts factsWithSource:s].supportsRemoteDebugJIT, @"17.3 supportsRemoteDebugJIT = NO");
    s.minor = 4;
    ok([A2JITFacts factsWithSource:s].supportsRemoteDebugJIT, @"17.4 supportsRemoteDebugJIT = YES");

    s.major = 16; s.minor = 5; s.env = A2JITEnvironmentKindJailbroken;
    ok([A2JITFacts factsWithSource:s].hasKernelJITEnvironment, @"16.5 越狱 hasKernelJITEnvironment = YES");

    s.env = A2JITEnvironmentKindPlain; s.dcs = YES;
    ok([A2JITFacts factsWithSource:s].hasKernelJITEnvironment, @"dynamic-codesigning → 内核环境 = YES");

    // 文件/工具字段透传
    s.dcs = NO; s.pairing = YES; s.enabler = YES; s.gta = YES;
    A2JITFacts *f = [A2JITFacts factsWithSource:s];
    ok(f.hasImportedPairingFile, @"配对文件透传 = YES");
    ok(f.hasExternalEnablerInstalled, @"外部工具透传 = YES");
    ok(f.hasGetTaskAllow, @"get-task-allow 透传 = YES");
    ok([[f description] containsString:@"iOS 16"], @"description 含版本");
}

#pragma mark - ⑤ 编排（Coordinator 端到端状态推进）

static void testCoordinator(void) {
    printf("\n=== ⑤ 编排端到端（A2JITCoordinator + 假 Provider）===\n");

    // iOS 26 + 已导入配对，导入 Provider 可用且就绪 ⇒ Paired → enableJIT → Enabled
    FakeProvider *imp = [[FakeProvider alloc] init];
    imp.kind = A2JITProviderKindImportedPairing;
    imp.available = YES;
    imp.pairingReady = YES;
    imp.prepareResult = YES;
    imp.activateResult = YES;
    A2JITCoordinator *co = [[A2JITCoordinator alloc] initWithFacts:FactsPairing(26, 0, A2JITEnvironmentKindPlain, YES)
                                                        providers:@[ imp ]];
    eqInt(co.strategy, A2JITStrategyBuiltInManual, @"策略 = 内置手动");
    eqInt(co.state, A2JITStatePaired, @"26 + 已导入配对 → Paired");
    ok(co.hasActiveProvider, @"hasActiveProvider = YES");
    ok([co enableJITWithError:NULL], @"enableJIT 成功");
    eqInt(co.state, A2JITStateEnabled, @"→ Enabled");
    ok(co.readyToRunGame, @"readyToRunGame = YES");
    eqInt(imp.activateCalls, 1, @"activateJIT 被调用 1 次");

    // 17.3 纯签名 ⇒ 不可用（无 Provider 被尝试）
    FakeProvider *imp2 = [[FakeProvider alloc] init];
    imp2.kind = A2JITProviderKindImportedPairing;
    imp2.available = YES;
    A2JITCoordinator *co2 = [[A2JITCoordinator alloc] initWithFacts:FactsPairing(17, 3, A2JITEnvironmentKindPlain, YES)
                                                        providers:@[ imp2 ]];
    eqInt(co2.state, A2JITStateUnavailable, @"17.3 → Unavailable");
    eqInt(co2.failureReason, A2JITFailureReasonSystemTooOld, @"17.3 原因 = SystemTooOld");
    ok(!co2.readyToRunGame, @"readyToRunGame = NO");

    // 26 + 无配对文件 ⇒ WaitingPairing；取配对失败 ⇒ 停留并报原因
    FakeProvider *imp3 = [[FakeProvider alloc] init];
    imp3.kind = A2JITProviderKindImportedPairing;
    imp3.available = YES;
    imp3.pairingReady = NO;
    imp3.prepareResult = NO;
    A2JITCoordinator *co3 = [[A2JITCoordinator alloc] initWithFacts:FactsPairing(26, 0, A2JITEnvironmentKindPlain, NO)
                                                        providers:@[ imp3 ]];
    eqInt(co3.state, A2JITStateWaitingPairing, @"26 + 无配对 → WaitingPairing");
    eqInt(co3.failureReason, A2JITFailureReasonPairingMissing, @"原因 = PairingMissing");
    ok(![co3 acquirePairingWithError:NULL], @"取配对失败 → NO");
    eqInt(co3.state, A2JITStateWaitingPairing, @"失败后仍 WaitingPairing");

    // 开启失败 ⇒ 停留 WaitingActivation + ActivationFailed（不回退未配对）
    FakeProvider *imp4 = [[FakeProvider alloc] init];
    imp4.kind = A2JITProviderKindImportedPairing;
    imp4.available = YES;
    imp4.pairingReady = YES;
    imp4.activateResult = NO;
    A2JITCoordinator *co4 = [[A2JITCoordinator alloc] initWithFacts:FactsPairing(26, 0, A2JITEnvironmentKindPlain, YES)
                                                        providers:@[ imp4 ]];
    eqInt(co4.state, A2JITStatePaired, @"就绪 → Paired");
    ok(![co4 enableJITWithError:NULL], @"开启失败 → NO");
    eqInt(co4.state, A2JITStateWaitingActivation, @"失败后停留 WaitingActivation");
    eqInt(co4.failureReason, A2JITFailureReasonActivationFailed, @"原因 = ActivationFailed");

    // 「先 JIT 后启 JVM」钩子：未就绪 ⇒ 阻止启动链
    __block BOOL ranDeliver = NO, ranVerify = NO, ranVM = NO;
    A2LaunchChain *chain = [A2LaunchChain chainWithDeliverScript:^BOOL(NSError **e) { ranDeliver = YES; return YES; }
                                                          verify:^BOOL(NSString **r) { ranVerify = YES; return YES; }
                                                       createJVM:^BOOL(NSError **e) { ranVM = YES; return YES; }];
    ok(![co3 prepareJITThenRunLaunchChain:chain error:NULL], @"未就绪 → 钩子返回 NO");
    ok(!ranDeliver && !ranVerify && !ranVM, @"★未就绪时启动链完全未运行★");

    // 就绪 ⇒ 钩子放行启动链
    FakeProvider *imp5 = [[FakeProvider alloc] init];
    imp5.kind = A2JITProviderKindImportedPairing;
    imp5.available = YES;
    imp5.pairingReady = YES;
    imp5.activateResult = YES;
    A2JITCoordinator *co5 = [[A2JITCoordinator alloc] initWithFacts:FactsPairing(26, 0, A2JITEnvironmentKindPlain, YES)
                                                        providers:@[ imp5 ]];
    ok([co5 prepareJITThenRunLaunchChain:chain error:NULL], @"已启用 → 钩子放行并跑启动链");
    ok(ranDeliver && ranVerify && ranVM, @"启动链三步都跑到");
}

#pragma mark - ⑥ [JIT-IMPL-2] 判据分流（A2JITVerdictGuidance）

static void testVerdictGuidance(void) {
    printf("\n=== ⑥ 判据分流（A2JITVerdictGuidance：7 档不混为一谈）===\n");

    ok([A2JITVerdictGuidance isUsable:A2JITReadinessVerdictUsable], @"Usable → isUsable = YES");
    ok(![A2JITVerdictGuidance isUsable:A2JITReadinessVerdictNotServiced], @"NotServiced → isUsable = NO");
    ok(![A2JITVerdictGuidance isUsable:A2JITReadinessVerdictLegacySentinel], @"LegacySentinel → isUsable = NO");
    ok(![A2JITVerdictGuidance isUsable:A2JITReadinessVerdictNotExecutable], @"NotExecutable → isUsable = NO");

    eqInt([A2JITVerdictGuidance failureReasonForVerdict:A2JITReadinessVerdictUsable],
          A2JITFailureReasonNone, @"Usable → 状态机原因 None");
    eqInt([A2JITVerdictGuidance failureReasonForVerdict:A2JITReadinessVerdictNotServiced],
          A2JITFailureReasonActivationFailed, @"NotServiced → ActivationFailed");
    eqInt([A2JITVerdictGuidance failureReasonForVerdict:A2JITReadinessVerdictLegacySentinel],
          A2JITFailureReasonActivationFailed, @"LegacySentinel → ActivationFailed");

    // ★原因 / 动作 key 必须一档一个★（否则「四种原因四种动作」退化成万能文案）
    NSMutableSet<NSString *> *reasonKeys = [NSMutableSet set];
    NSMutableSet<NSString *> *actionKeys = [NSMutableSet set];
    for (NSInteger v = A2JITReadinessVerdictUnknown; v <= A2JITReadinessVerdictNotExecutable; v++) {
        NSString *rk = [A2JITVerdictGuidance reasonKeyForVerdict:(A2JITReadinessVerdict)v];
        NSString *ak = [A2JITVerdictGuidance actionKeyForVerdict:(A2JITReadinessVerdict)v];
        ok(rk.length > 0, [NSString stringWithFormat:@"verdict %ld 有原因 key", (long)v]);
        ok(ak.length > 0, [NSString stringWithFormat:@"verdict %ld 有动作 key", (long)v]);
        [reasonKeys addObject:rk];
        [actionKeys addObject:ak];
    }
    eqInt((NSInteger)reasonKeys.count, 7, @"★7 档原因 key 互不相同★");
    eqInt((NSInteger)actionKeys.count, 7, @"★7 档动作 key 互不相同★");

    ok([A2JITVerdictGuidance diagnosticForVerdict:A2JITReadinessVerdictLegacySentinel].length > 0,
       @"诊断短语非空");
    ok([[A2JITVerdictGuidance displayNameForVerdict:A2JITReadinessVerdictNoMapping] isEqualToString:@"NoMapping"],
       @"英文名稳定（日志可搜）");

    // 默认可见日志行：Provider / 档位 / verdict / 取证
    NSString *line = [A2JITVerdictGuidance logLineWithProvider:@"外部工具"
                                                     strategy:A2JITStrategyBuiltInManual
                                                      verdict:A2JITReadinessVerdictNotServiced
                                                     evidence:@"brk #0x69 未服务"];
    ok([line hasPrefix:@"[A2JIT]"], @"日志行以 [A2JIT] 开头");
    ok([line containsString:@"provider=外部工具"], @"日志行含 Provider 名");
    ok([line containsString:@"verdict=NotServiced"], @"日志行含 verdict");
    ok([line containsString:@"brk #0x69 未服务"], @"日志行含取证摘要");
}

#pragma mark - ⑦ [JIT-IMPL-2] 四语文案（A2JITStrings）

static void testStrings(void) {
    printf("\n=== ⑦ 四语文案（A2JITStrings：zh-Hans / zh-Hant / en / ja）===\n");

    NSArray<NSString *> *codes = [A2JITStrings allLanguageCodes];
    eqInt((NSInteger)codes.count, 4, @"四门语言");
    ok([codes containsObject:@"zh-Hans"] && [codes containsObject:@"zh-Hant"] &&
       [codes containsObject:@"en"] && [codes containsObject:@"ja"], @"语言代码齐备");

    NSArray<NSString *> *keys = [A2JITStrings allKeys];
    ok(keys.count >= 30, @"文案 key 数量 >= 30");

    // ★四语齐全★：每个 key × 每门语言都必须非空
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *key in keys) {
        for (NSInteger li = A2JITLanguageZhHans; li <= A2JITLanguageJapanese; li++) {
            NSString *s = [A2JITStrings stringForKey:key language:(A2JITLanguage)li];
            if (s.length == 0) {
                [missing addObject:[NSString stringWithFormat:@"%@ / %@", key,
                                    [A2JITStrings codeForLanguage:(A2JITLanguage)li]]];
            }
        }
    }
    if (missing.count) {
        printf("        缺文案：%s\n", [[missing componentsJoinedByString:@", "] UTF8String]);
    }
    eqInt((NSInteger)missing.count, 0, @"★每个 key 在四语里都存在且非空★");

    // 判据分流用的 14 个 key 必须都在表里
    for (NSInteger v = A2JITReadinessVerdictUnknown; v <= A2JITReadinessVerdictNotExecutable; v++) {
        NSString *rk = [A2JITVerdictGuidance reasonKeyForVerdict:(A2JITReadinessVerdict)v];
        NSString *ak = [A2JITVerdictGuidance actionKeyForVerdict:(A2JITReadinessVerdict)v];
        ok([keys containsObject:rk], [NSString stringWithFormat:@"表里有原因 key：%@", rk]);
        ok([keys containsObject:ak], [NSString stringWithFormat:@"表里有动作 key：%@", ak]);
    }

    // 简体下 7 档原因文案必须互不相同（按 verdict 分流，不是同句复用）
    NSMutableSet<NSString *> *zhReasons = [NSMutableSet set];
    for (NSInteger v = A2JITReadinessVerdictUnknown; v <= A2JITReadinessVerdictNotExecutable; v++) {
        [zhReasons addObject:[A2JITStrings stringForKey:[A2JITVerdictGuidance reasonKeyForVerdict:(A2JITReadinessVerdict)v]
                                              language:A2JITLanguageZhHans]];
    }
    eqInt((NSInteger)zhReasons.count, 7, @"★简体：7 档原因文案互不相同★");

    ok([A2JITStrings stringForKey:@"jit.row.status"].length > 0, @"按系统语言取文案非空");
    ok([[A2JITStrings stringForKey:@"no.such.key"] isEqualToString:@"no.such.key"], @"缺 key 回退为 key 本身（不返回空串）");
    ok([A2JITStrings stringForKey:@"jit.row.status" language:A2JITLanguageJapanese].length > 0, @"指定语言取文案");
    eqStr([A2JITStrings codeForLanguage:A2JITLanguageZhHant], @"zh-Hant", @"codeForLanguage 映射");
    eqStr([A2JITStrings displayNameForLanguage:A2JITLanguageEnglish], @"en", @"displayNameForLanguage 映射");
}

#pragma mark - ⑧ [JIT-IMPL-2] 配对文件导入 / 落盘 / 记录

static void testPairingFileStore(void) {
    printf("\n=== ⑧ 配对文件导入（A2JITPairingFileStore：校验 → 落盘 → 记录）===\n");

    NSString *dir = TempDir();
    A2JITPairingFileStore *store = [[A2JITPairingFileStore alloc] initWithDirectory:dir];

    ok(!store.hasUsablePairingFile, @"空目录 → 未就绪");
    ok(store.importedFilePath == nil, @"空目录 → 无路径");
    ok(store.importedMetadata == nil, @"空目录 → 无元数据");

    NSData *good = PlistData(RemotePairingSample());
    NSError *err = nil;
    NSString *path = [store importData:good sourceName:@"StikDebug-pairing.mobiledevicepairing" error:&err];
    ok(path != nil, @"合法配对文件导入成功");
    ok([NSFileManager.defaultManager fileExistsAtPath:path], @"文件真的落盘了");
    eqStr([path lastPathComponent], @"pairingFile.plist", @"落盘用约定文件名");
    ok(store.hasUsablePairingFile, @"导入后 → 就绪（真的解析了一遍）");

    NSDictionary<NSString *, id> *meta = store.importedMetadata;
    ok(meta != nil, @"写了元数据");
    eqStr(meta[A2JITPairingFileStoreSourceNameKey], @"StikDebug-pairing.mobiledevicepairing", @"元数据：来源文件名");
    ok([meta[A2JITPairingFileStoreImportedAtKey] isKindOfClass:NSDate.class], @"元数据：导入时间");
    eqStr(meta[A2JITPairingFileStoreChecksumKey], [A2JITPairingFileStore sha256HexOfData:good], @"元数据：SHA-256");
    eqInt([meta[A2JITPairingFileStoreByteSizeKey] integerValue], (NSInteger)good.length, @"元数据：字节数");
    eqStr(meta[A2JITPairingFileStoreFormatKey], @"RemotePairing", @"元数据：格式");
    eqStr(meta[A2JITPairingFileStoreDeviceIdentifierKey], @"00008030-001A2B3C4D5E6F70", @"元数据：设备标识");

    // SHA-256 已知向量（防止「写了个假的校验和」）
    NSData *abc = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
    eqStr([A2JITPairingFileStore sha256HexOfData:abc],
          @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", @"SHA-256(abc) 已知向量");
    ok([A2JITPairingFileStore sha256HexOfData:[NSData data]] == nil, @"空数据 → SHA-256 = nil");

    // 垃圾 / 空文件必须被拒（且不破坏已导入的那份）
    err = nil;
    ok([store importData:[@"<not a pairing file>" dataUsingEncoding:NSUTF8StringEncoding]
              sourceName:@"junk.txt"
                   error:&err] == nil, @"垃圾文件被拒");
    eqInt(err.code, A2JITPairingFileStoreErrorInvalidPairingFile, @"垃圾文件错误码 = InvalidPairingFile");
    err = nil;
    ok([store importData:[NSData data] sourceName:nil error:&err] == nil, @"空文件被拒");
    eqInt(err.code, A2JITPairingFileStoreErrorInvalidPairingFile, @"空文件错误码");
    ok(store.hasUsablePairingFile, @"被拒后，原来导入的那份仍在");

    // 移除（「重试」用）
    err = nil;
    ok([store removeImportedPairingFileWithError:&err], @"移除成功");
    ok(!store.hasUsablePairingFile, @"移除后 → 未就绪");
    ok(![NSFileManager.defaultManager fileExistsAtPath:path], @"文件真的删了");

    // ★约定位置必须与事实探测的候选表一致★（否则「导入了但探测说没有」）
    BOOL inCandidates = NO;
    for (NSString *p in [A2JITLocalFactsSource candidatePairingFilePaths]) {
        if ([p hasSuffix:@"Application Support/Pairing/pairingFile.plist"]) {
            inCandidates = YES;
        }
    }
    ok(inCandidates, @"★约定目录 + 文件名落在 A2JITLocalFactsSource 候选表里★");
    ok([[A2JITPairingFileStore defaultDirectory] hasSuffix:@"Application Support/Pairing"],
       @"默认目录 = Library/Application Support/Pairing");
}

#pragma mark - ⑨ [JIT-IMPL-2] 外部工具：拉起 + 有界等待 + 轮询判据

static A2JITFacts *FactsEnabler(NSInteger maj, NSInteger min, BOOL installed) {
    return [A2JITFacts factsWithOSMajorVersion:maj
                                  minorVersion:min
                                   environment:A2JITEnvironmentKindPlain
                      hasImportedPairingFile:NO
                 hasExternalEnablerInstalled:installed
                              hasGetTaskAllow:NO
                        hasDynamicCodesigning:NO];
}

static void testExternalToolProvider(void) {
    printf("\n=== ⑨ 外部工具（A2JITExternalToolProvider：拉起 → 有界等待 → 轮询判据）===\n");

    // ---- ① 未安装：整条路径不可用（不展示 / 置灰 + 写「未安装」）----
    FakeLauncher *l0 = [[FakeLauncher alloc] init];
    A2JITExternalToolProvider *p0 =
        [[A2JITExternalToolProvider alloc] initWithFacts:FactsEnabler(18, 0, NO)
                                                launcher:l0
                                                   probe:[[FakeProbe alloc] init]
                                              waitBudget:0.2
                                            pollInterval:0.02];
    ok(!p0.isAvailable, @"未安装 → isAvailable = NO（编排层不选它）");
    ok(!p0.isPairingReady, @"未安装 → isPairingReady = NO");
    NSError *err = nil;
    ok(![p0 activateJITWithError:&err], @"未安装 → 开启失败");
    ok([err.localizedDescription containsString:@"未安装"], @"错误文案点名「未安装」");
    eqInt((NSInteger)l0.openedURLs.count, 0, @"未安装 → ★不尝试拉起★");

    // ---- ② 已安装 + 前两发判据未通过、第三发通过 ⇒ 成功 ----
    FakeLauncher *l1 = [[FakeLauncher alloc] init];
    [l1.openableSchemes addObject:@"stikdebug"];
    FakeProbe *probe1 = [[FakeProbe alloc] init];
    probe1.failTimes = 2;
    A2JITExternalToolProvider *p1 =
        [[A2JITExternalToolProvider alloc] initWithFacts:FactsEnabler(18, 2, YES)
                                                launcher:l1
                                                   probe:probe1
                                              waitBudget:5.0
                                            pollInterval:0.01];
    ok(p1.isAvailable, @"已安装 → isAvailable = YES");
    eqStr(p1.firstLaunchableURL.absoluteString, @"stikdebug://enable-jit", @"首选拉起 URL = stikdebug://enable-jit");
    err = nil;
    ok([p1 activateJITWithError:&err], @"轮询到判据通过 → 开启成功");
    eqInt((NSInteger)l1.openedURLs.count, 1, @"只拉起一次");
    eqStr(l1.openedURLs.firstObject.absoluteString, @"stikdebug://enable-jit", @"拉起的 URL 正确");
    eqInt(probe1.calls, 3, @"★轮询判据 3 次（前两发未通过）★");
    ok(probe1.invalidateCalls >= 1, @"拉起前先作废判据缓存（从外部工具切回前台）");
    eqInt(p1.lastVerdict, A2JITReadinessVerdictUsable, @"成功后 verdict = Usable");

    // ---- ③ 恒不可用 ⇒ 超时即失败（★有界，不无限等★）----
    FakeLauncher *l2 = [[FakeLauncher alloc] init];
    [l2.openableSchemes addObject:@"sidestore"];
    FakeProbe *probe2 = [[FakeProbe alloc] init];
    probe2.alwaysFail = YES;
    probe2.verdict = A2JITReadinessVerdictLegacySentinel;
    probe2.evidence = @"brk #0x69 返回 legacy 哨兵 0xE0000069";
    A2JITExternalToolProvider *p2 =
        [[A2JITExternalToolProvider alloc] initWithFacts:FactsEnabler(17, 5, YES)
                                                launcher:l2
                                                   probe:probe2
                                              waitBudget:0.15
                                            pollInterval:0.02];
    NSDate *t0 = [NSDate date];
    err = nil;
    ok(![p2 activateJITWithError:&err], @"恒不可用 → 开启失败");
    NSTimeInterval spent = -[t0 timeIntervalSinceNow];
    ok(spent < 1.0, @"★有界等待：耗时 < 1s（超时即失败）★");
    ok(spent >= 0.10, @"确实等过一段预算（不是立即返回）");
    ok([err.localizedDescription containsString:@"超时"], @"错误文案点名「超时」");
    ok([err.localizedDescription containsString:@"0xE0000069"], @"★失败文案按 verdict 分流（legacy 哨兵）★");
    eqInt(p2.lastVerdict, A2JITReadinessVerdictLegacySentinel, @"记录最后 verdict");
    ok([p2.lastEvidence containsString:@"0xE0000069"], @"记录最后取证");

    // ---- ④ 装了但 scheme 打不开（白名单没登记）----
    FakeLauncher *l3 = [[FakeLauncher alloc] init];   // openableSchemes 为空
    A2JITExternalToolProvider *p3 =
        [[A2JITExternalToolProvider alloc] initWithFacts:FactsEnabler(18, 0, YES)
                                                launcher:l3
                                                   probe:[[FakeProbe alloc] init]
                                              waitBudget:0.2
                                            pollInterval:0.02];
    ok(p3.firstLaunchableURL == nil, @"都打不开时 firstLaunchableURL = nil");
    err = nil;
    ok(![p3 activateJITWithError:&err], @"无可拉起 scheme → 失败");
    ok([err.localizedDescription containsString:@"LSApplicationQueriesSchemes"], @"错误文案指向白名单");

    // ---- ⑤ 拉起请求本身失败 ----
    FakeLauncher *l4 = [[FakeLauncher alloc] init];
    [l4.openableSchemes addObject:@"stikdebug"];
    l4.openResult = NO;
    A2JITExternalToolProvider *p4 =
        [[A2JITExternalToolProvider alloc] initWithFacts:FactsEnabler(18, 0, YES)
                                                launcher:l4
                                                   probe:[[FakeProbe alloc] init]
                                              waitBudget:0.2
                                            pollInterval:0.02];
    err = nil;
    ok(![p4 activateJITWithError:&err], @"拉起失败 → 开启失败");
    ok([err.localizedDescription containsString:@"拉起"], @"错误文案点名拉起失败");

    // ---- ⑥ 装配缺失（无判据内核）⇒ ★不假装成功★ ----
    A2JITExternalToolProvider *p5 =
        [[A2JITExternalToolProvider alloc] initWithFacts:FactsEnabler(18, 0, YES)
                                                launcher:[[FakeLauncher alloc] init]
                                                   probe:nil
                                              waitBudget:0.2
                                            pollInterval:0.02];
    err = nil;
    ok(![p5 activateJITWithError:&err], @"无判据内核 → 开启失败（不假装成功）");
    ok([err.localizedDescription containsString:@"未注入"], @"文案说明装配缺失");

    // ---- ⑦ 取配对：已安装即就绪 ----
    err = nil;
    ok([p1 preparePairingWithError:&err], @"已安装 → 取配对成功");
    err = nil;
    ok(![p0 preparePairingWithError:&err], @"未安装 → 取配对失败");

    // 默认预算/轮询可读（设置页据此提示「最多等 N 秒」）
    A2JITExternalToolProvider *pDefault =
        [[A2JITExternalToolProvider alloc] initWithFacts:FactsEnabler(18, 0, YES) launcher:nil probe:nil waitBudget:0 pollInterval:0];
    ok(pDefault.activationWaitBudget >= 10.0, @"默认等待预算合理（>=10s）");
    ok(pDefault.pollInterval > 0, @"默认轮询间隔 > 0");
}

#pragma mark - ⑩ [JIT-IMPL-2] 导入配对：就绪真探测 + 真调判据

static void testImportedPairingProvider(void) {
    printf("\n=== ⑩ 导入配对（A2JITImportedPairingProvider：真探测 + 真调判据）===\n");

    NSString *dir = TempDir();
    A2JITPairingFileStore *store = [[A2JITPairingFileStore alloc] initWithDirectory:dir];
    A2JITFacts *f26 = [A2JITFacts factsWithOSMajorVersion:26 minorVersion:0
                                              environment:A2JITEnvironmentKindPlain
                                 hasImportedPairingFile:NO
                            hasExternalEnablerInstalled:NO
                                         hasGetTaskAllow:NO
                                   hasDynamicCodesigning:NO];

    FakeProbe *probe = [[FakeProbe alloc] init];   // failTimes = 0 ⇒ 首次即通过
    A2JITImportedPairingProvider *p =
        [[A2JITImportedPairingProvider alloc] initWithFacts:f26 store:store probe:probe];
    eqInt(p.kind, A2JITProviderKindImportedPairing, @"kind = 导入配对");
    ok(p.isAvailable, @"iOS 26 → isAvailable = YES（17.4+ 路径）");
    ok(!p.isPairingReady, @"未导入 → 未就绪（★真探测，不是恒 NO 也不是恒 YES★）");
    ok(p.pairingFilePath == nil, @"未导入 → 无路径");
    eqInt(p.lastVerdict, A2JITReadinessVerdictUnknown, @"初始 verdict = Unknown");

    NSError *err = nil;
    ok(![p preparePairingWithError:&err], @"无文件 → 取配对失败");
    ok([err.localizedDescription containsString:@"导入"], @"失败文案指向「导入」");

    NSString *path = [store importData:PlistData(RemotePairingSample()) sourceName:@"from-StikDebug.plist" error:&err];
    ok(path != nil, @"导入配对文件成功");
    ok(p.isPairingReady, @"导入后 → 就绪（★真的去容器里找 + 解析★）");
    eqStr(p.pairingFilePath, path, @"路径来自 A2JITPairingFileStore");
    ok([p preparePairingWithError:&err], @"就绪 → 取配对成功");

    // ★真调判据：判据未通过 ⇒ 失败，且文案按 verdict 分流★
    FakeProbe *probeFail = [[FakeProbe alloc] init];
    probeFail.alwaysFail = YES;
    probeFail.verdict = A2JITReadinessVerdictNotServiced;
    probeFail.evidence = @"brk #0x69 未被服务（无调试器应答）";
    A2JITImportedPairingProvider *pFail =
        [[A2JITImportedPairingProvider alloc] initWithFacts:f26 store:store probe:probeFail];
    err = nil;
    ok(![pFail activateJITWithError:&err], @"判据未通过 → 开启失败");
    eqInt(pFail.lastVerdict, A2JITReadinessVerdictNotServiced, @"记录 verdict = NotServiced");
    eqStr(pFail.lastEvidence, @"brk #0x69 未被服务（无调试器应答）", @"记录取证");
    ok([err.localizedDescription containsString:@"brk #0x69"], @"★失败文案按 verdict 分流★");
    ok(probeFail.calls >= 1, @"★真的调了判据内核（ensureJITUsableWithinBudget）★");

    // 判据通过 ⇒ 成功
    err = nil;
    ok([p activateJITWithError:&err], @"判据通过 → 开启成功");
    eqInt(p.lastVerdict, A2JITReadinessVerdictUsable, @"verdict = Usable");
    ok(probe.calls >= 1, @"判据被调用");

    // 未注入判据 ⇒ ★如实失败，不假装成功★
    A2JITImportedPairingProvider *pNil =
        [[A2JITImportedPairingProvider alloc] initWithFacts:f26 store:store probe:nil];
    err = nil;
    ok(![pNil activateJITWithError:&err], @"无判据内核 → 开启失败（不假装成功）");

    // iOS 17.5（无内置 helper）⇒ 归一为「交给外部工具」
    A2JITFacts *f175 = [A2JITFacts factsWithOSMajorVersion:17 minorVersion:5
                                               environment:A2JITEnvironmentKindPlain
                                  hasImportedPairingFile:YES
                             hasExternalEnablerInstalled:NO
                                          hasGetTaskAllow:NO
                                    hasDynamicCodesigning:NO];
    A2JITImportedPairingProvider *p175 =
        [[A2JITImportedPairingProvider alloc] initWithFacts:f175 store:store probe:probe];
    err = nil;
    ok(![p175 activateJITWithError:&err], @"17.5 无内置开启 → 失败");
    ok([err.localizedDescription containsString:@"外部工具"], @"文案指向外部工具");
}

#pragma mark - ⑪ [JIT-IMPL-2] 接线不变量（跨层镜像 / 白名单 / 分层纪律）

static void testWiringInvariants(void) {
    printf("\n=== ⑪ 接线不变量（镜像 / 白名单 / 分层 / 真调证据）===\n");

    // ① A2JITReadinessVerdict 必须与 A2JITRegionVerdict 逐值相等
    //   （编译期另有 Bridge 里的 _Static_assert 兜底；这里再跑一遍运行期断言）
    eqInt((NSInteger)A2JITReadinessVerdictUnknown,        (NSInteger)A2JITRegionVerdictUnknown,        @"镜像：Unknown");
    eqInt((NSInteger)A2JITReadinessVerdictUsable,         (NSInteger)A2JITRegionVerdictUsable,         @"镜像：Usable");
    eqInt((NSInteger)A2JITReadinessVerdictNotServiced,    (NSInteger)A2JITRegionVerdictNotServiced,    @"镜像：NotServiced");
    eqInt((NSInteger)A2JITReadinessVerdictLegacySentinel, (NSInteger)A2JITRegionVerdictLegacySentinel, @"镜像：LegacySentinel");
    eqInt((NSInteger)A2JITReadinessVerdictNoMapping,      (NSInteger)A2JITRegionVerdictNoMapping,      @"镜像：NoMapping");
    eqInt((NSInteger)A2JITReadinessVerdictZeroSize,       (NSInteger)A2JITRegionVerdictZeroSize,       @"镜像：ZeroSize");
    eqInt((NSInteger)A2JITReadinessVerdictNotExecutable,  (NSInteger)A2JITRegionVerdictNotExecutable,  @"镜像：NotExecutable");

    // ② 登记的 scheme 必须与 Info.plist 白名单一致（两处同源，防漂移）
    NSData *plistData = [NSData dataWithContentsOfFile:RepoPath(@"Air2/Info.plist")];
    ok(plistData.length > 0, @"读得到 Air2/Info.plist");
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:plistData
                                                                   options:0
                                                                    format:NULL
                                                                     error:NULL];
    NSArray<NSString *> *whitelist = plist[@"LSApplicationQueriesSchemes"];
    NSArray<NSString *> *registered = [A2JITExternalToolProvider registeredToolSchemes];
    ok(whitelist.count > 0, @"Info.plist 有 LSApplicationQueriesSchemes");
    eqInt((NSInteger)whitelist.count, (NSInteger)registered.count, @"白名单条数 = 登记条数");
    for (NSString *scheme in registered) {
        ok([whitelist containsObject:scheme],
           [NSString stringWithFormat:@"Info.plist 已登记 scheme：%@", scheme]);
    }

    // ③ 分层纪律：Player 的 .m 一处都不得 import Natives 判据头（只能经 Bridge）
    NSString *playerDir = RepoPath(@"Air2/Player");
    NSArray<NSString *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:playerDir error:NULL];
    NSInteger leaks = 0;
    NSInteger implCount = 0;
    for (NSString *f in files) {
        if (![f hasSuffix:@".m"]) {
            continue;
        }
        implCount++;
        NSString *src = [NSString stringWithContentsOfFile:[playerDir stringByAppendingPathComponent:f]
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        if ([src containsString:@"#import \"A2JITEnvironment.h\""]) {
            leaks++;
            printf("        ★Player 越界 import：%s\n", f.UTF8String);
        }
    }
    ok(implCount >= 10, @"扫到 Player 的多个 .m 文件");
    eqInt(leaks, 0, @"★Player 无一处 import Natives 判据头（单向分层）★");

    // ④ Bridge 才是「真调判据」的落点：必须 import 判据头并真的调用它
    NSString *bridgeSrc = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Bridge/A2JITEnvironmentProbe.m")
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    ok(bridgeSrc.length > 0, @"读得到 Bridge 的 probe 实现");
    ok([bridgeSrc containsString:@"#import \"A2JITEnvironment.h\""], @"Bridge probe import 判据头");
    ok([bridgeSrc containsString:@"[A2JITEnvironment ensureVerifiedWithinBudget:"],
       @"★Bridge 真的调了 A2JITEnvironment.ensureVerifiedWithinBudget:（真调判据）★");
    ok([bridgeSrc containsString:@"lastRegionVerdict"], @"Bridge 读真 verdict");
    ok([bridgeSrc containsString:@"regionEvidence"], @"Bridge 读取证文本");

    // ⑤ 设置页接线（源码级断言：文案 / 选择器 / 判据内核都真的接上了）
    NSString *settingsSrc = [NSString stringWithContentsOfFile:RepoPath(@"Air2/UI/Screens/Settings/A2JITSettings.m")
                                                      encoding:NSUTF8StringEncoding
                                                         error:NULL];
    ok(settingsSrc.length > 0, @"读得到设置页实现");
    ok([settingsSrc containsString:@"UIDocumentPickerViewController"], @"设置页接入系统文档选择器");
    ok([settingsSrc containsString:@"A2JITEnvironmentProbe"], @"设置页注入真判据内核");
    ok([settingsSrc containsString:@"A2JITStrings"], @"设置页使用四语文案表");
    ok([settingsSrc containsString:@"dispatch_get_global_queue"], @"开启动作在后台队列（不卡界面）");

    // ⑥ [JIT-AUTOPAIR-1] 设置页接入自动配对（推荐 + 一键开展 + 引擎注入）
    ok([settingsSrc containsString:@"A2JITAutoPairingEngineBridge"], @"设置页注入自动配对引擎（Bridge）");
    ok([settingsSrc containsString:@"jit.row.autopair"], @"设置页使用自动配对行文案");
    ok([settingsSrc containsString:@"runAutoPair"], @"设置页有「一键开展自动配对」");
    ok([settingsSrc containsString:@"acquirePairingWithError"], @"开展走编排层取配对");

    // ⑦ Bridge 骨架必须★如实报未接入★（源码级：防「假成功」）
    NSString *engineSrc = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Bridge/A2JITAutoPairingEngineBridge.m")
                                                    encoding:NSUTF8StringEncoding
                                                       error:NULL];
    ok(engineSrc.length > 0, @"读得到自动配对引擎骨架");
    ok([engineSrc containsString:@"return NO;"], @"骨架 isEngineAvailable 返回 NO");
    ok([engineSrc containsString:@"unknownPreconditions"], @"骨架读前置 ⇒ 全 Unknown（不谎报满足）");
    ok([engineSrc containsString:@"A2JITAutoPairingBlockerEngineUnavailable"], @"骨架生成失败分类 = EngineUnavailable");
    ok(![engineSrc containsString:@"#import \"A2JITEnvironment.h\""], @"骨架不 import Natives 判据头");

    // ⑧ ★Provider 侧不得 import Bridge（单向分层：Bridge 在下）★
    NSInteger bridgeLeaks = 0;
    for (NSString *f in files) {
        if (![f hasSuffix:@".m"]) {
            continue;
        }
        NSString *src = [NSString stringWithContentsOfFile:[playerDir stringByAppendingPathComponent:f]
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        if ([src containsString:@"#import \"A2JITAutoPairingEngineBridge.h\""]) {
            bridgeLeaks++;
            printf("        ★Player 越界 import Bridge：%s\n", f.UTF8String);
        }
    }
    eqInt(bridgeLeaks, 0, @"★Player 无一处 import Bridge（单向分层）★");

    // ⑨ ★「不谎报」回归：Provider 源码必须含「引擎成功但无文件 ⇒ 失败」的判据★
    NSString *autoSrc = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Player/A2JITAutomaticPairingProvider.m")
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    ok(autoSrc.length > 0, @"读得到自动配对 Provider 实现");
    ok([autoSrc containsString:@"hasFreshUsablePairingFile"], @"就绪判据 = 新鲜可用文件");
    ok([autoSrc containsString:@"A2JITProviderNotImplementedError"], @"引擎未接入 ⇒ NotImplemented（与真失败分开）");
    ok([autoSrc containsString:@"不视为成功"], @"★引擎报成功但无文件 ⇒ 不视为成功（不谎报）★");
}

#pragma mark - ⑫ [JIT-AUTOPAIR-1] 自动配对 Provider（能力 + 前置 + 新鲜度 + 有界生成）

static void testAutomaticPairingProvider(void) {
    printf("\n=== ⑫ 自动配对（A2JITAutomaticPairingProvider：真探测 + 前置 + 有界生成）===\n");

    A2JITFacts *f26 = Facts(26, 0, A2JITEnvironmentKindPlain);
    A2JITFacts *f27 = Facts(27, 0, A2JITEnvironmentKindPlain);

    // ---- ① 能力检测：仅 iOS 27+（真判据，不是恒 YES/NO）----
    A2JITAutomaticPairingProvider *p26 = [[A2JITAutomaticPairingProvider alloc] initWithFacts:f26];
    eqInt(p26.kind, A2JITProviderKindAutomaticPairing, @"kind = 自动配对");
    ok(!p26.isAvailable, @"iOS 26 → isAvailable = NO（自动配对仅 27+）");
    A2JITAutomaticPairingProvider *p27 = [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27];
    ok(p27.isAvailable, @"iOS 27 → isAvailable = YES");
    ok(!p27.isPairingReady, @"27 无文件 → 未就绪（★真探测，不是恒 YES★）");

    // ---- ② 非 27 上取配对 ⇒ 如实报 SystemTooOld ----
    NSError *err = nil;
    ok(![p26 preparePairingWithError:&err], @"26 → 取配对失败");
    eqInt(p26.lastBlocker, A2JITAutoPairingBlockerSystemTooOld, @"26 → blocker = SystemTooOld");

    // ---- ③ 27 + 前置全 Unknown（默认）⇒ ★如实报「无法确认」，绝不假成功★ ----
    eqInt(p27.lastBlocker, A2JITAutoPairingBlockerNone, @"初始 lastBlocker = None");
    ok(!p27.canGeneratePairingFile, @"前置未知 → 不能生成");
    err = nil;
    ok(![p27 preparePairingWithError:&err], @"前置未确认 → 取配对失败（不假成功）");
    eqInt(p27.lastBlocker, A2JITAutoPairingBlockerPreconditionUnconfirmed, @"blocker = PreconditionUnconfirmed");
    ok([err.localizedDescription containsString:@"无法确认"], @"★错误文案点名「无法确认」★");

    // ---- ④ 27 + 前置【明确未满足】(Developer Mode) ⇒ 精确报缺哪项 + 不发起生成 ----
    FakeAutoPairingEngine *engineDev = [[FakeAutoPairingEngine alloc] init];
    engineDev.engineAvailable = YES;
    engineDev.succeed = YES;
    engineDev.preconditions = [A2JITAutoPairingPreconditions
        preconditionsWithDeveloperMode:A2JITAutoPairingPreconditionStateUnsatisfied
                          localNetwork:A2JITAutoPairingPreconditionStateSatisfied
                          getTaskAllow:A2JITAutoPairingPreconditionStateSatisfied
                                   ddi:A2JITAutoPairingPreconditionStateSatisfied];
    A2JITAutomaticPairingProvider *pDev =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:engineDev.preconditions
                                                      engine:engineDev
                                                       store:[[A2JITPairingFileStore alloc] initWithDirectory:TempDir()]
                                                       probe:nil];
    err = nil;
    ok(![pDev preparePairingWithError:&err], @"前置未满足 → 取配对失败");
    eqInt(pDev.lastBlocker, A2JITAutoPairingBlockerDeveloperModeOff, @"blocker = DeveloperModeOff");
    ok([err.localizedDescription containsString:@"Developer Mode"], @"★错误文案点名缺失项★");
    eqInt(engineDev.generateCalls, 0, @"★前置未过 ⇒ 不发起生成（不白跑网络）★");
    eqInt([[pDev firstBlockingPrecondition] integerValue],
          A2JITAutoPairingPreconditionDeveloperMode, @"firstBlockingPrecondition = DeveloperMode");

    // ---- ⑤ 27 + 前置齐 + 引擎【未接入】⇒ blocker = EngineUnavailable（NotImplemented，code=1）----
    FakeAutoPairingEngine *engineOff = [[FakeAutoPairingEngine alloc] init];
    engineOff.engineAvailable = NO;
    engineOff.preconditions = [A2JITAutoPairingPreconditions allSatisfiedPreconditions];
    A2JITAutomaticPairingProvider *pOff =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:engineOff.preconditions
                                                      engine:engineOff
                                                       store:[[A2JITPairingFileStore alloc] initWithDirectory:TempDir()]
                                                       probe:nil];
    err = nil;
    ok(![pOff preparePairingWithError:&err], @"引擎未接入 → 取配对失败");
    eqInt(pOff.lastBlocker, A2JITAutoPairingBlockerEngineUnavailable, @"blocker = EngineUnavailable");
    eqInt(err.code, 1, @"★「未接入」用 A2JITProviderNotImplementedError（code=1）★");
    ok(!pOff.canGeneratePairingFile, @"引擎未接入 → 不能生成");

    // ---- ⑤b ★「未确认」不得说成「未满足」：前置 reason key 三态分得清★ ----
    eqStr([pDev blockingPreconditionReasonKey], @"jit.row.autopair.precondMissing",
          @"明确未满足 → precondMissing key");
    eqStr([p27 blockingPreconditionReasonKey], @"jit.row.autopair.precondUnknown",
          @"★仅未确认 → precondUnknown key（不谎报为未满足）★");
    ok([pOff blockingPreconditionReasonKey] == nil, @"前置全满足 → 无前置 reason key");

    // ---- ⑥ 27 + 前置齐 + 引擎接入 +【真写文件】⇒ 成功且就绪 ----
    A2JITPairingFileStore *storeOK = [[A2JITPairingFileStore alloc] initWithDirectory:TempDir()];
    FakeAutoPairingEngine *engineOK = [[FakeAutoPairingEngine alloc] init];
    engineOK.engineAvailable = YES;
    engineOK.succeed = YES;
    engineOK.writeFileWhenSucceed = YES;
    engineOK.store = storeOK;
    A2JITAutomaticPairingProvider *pOK =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:[A2JITAutoPairingPreconditions allSatisfiedPreconditions]
                                                      engine:engineOK
                                                       store:storeOK
                                                       probe:nil];
    ok(pOK.canGeneratePairingFile, @"前置齐 + 引擎接入 → 可生成");
    ok(!pOK.isPairingReady, @"生成前 → 未就绪");
    err = nil;
    ok([pOK preparePairingWithError:&err], @"生成成功 → 取配对成功");
    eqInt(pOK.lastStep, A2JITAutoPairingStepDone, @"lastStep = Done");
    ok(pOK.isPairingReady, @"★生成后 → 就绪（真的解析了容器里的文件）★");
    ok(pOK.pairingFilePath.length > 0, @"有配对文件路径");
    eqInt(engineOK.generateCalls, 1, @"引擎被调用 1 次");
    ok(engineOK.lastBudget > 0, @"★生成有界（预算 > 0）★");
    ok(pOK.generationBudget >= 10.0, @"默认生成预算合理（>=10s）");

    // ---- ⑦ 引擎「报成功但没写文件」⇒ ★不视为成功（不谎报）★ ----
    FakeAutoPairingEngine *engineLiar = [[FakeAutoPairingEngine alloc] init];
    engineLiar.engineAvailable = YES;
    engineLiar.succeed = YES;
    engineLiar.writeFileWhenSucceed = NO;   // 报成功但不落盘
    engineLiar.preconditions = [A2JITAutoPairingPreconditions allSatisfiedPreconditions];
    A2JITAutomaticPairingProvider *pLiar =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:engineLiar.preconditions
                                                      engine:engineLiar
                                                       store:[[A2JITPairingFileStore alloc] initWithDirectory:TempDir()]
                                                       probe:nil];
    err = nil;
    ok(![pLiar preparePairingWithError:&err], @"引擎报成功但无文件 → 失败");
    eqInt(pLiar.lastBlocker, A2JITAutoPairingBlockerWriteFailed, @"blocker = WriteFailed（不谎报）");

    // ---- ⑧ 引擎真失败 + 分类 ⇒ 按分类上报（含步骤落点）----
    FakeAutoPairingEngine *engineTunnel = [[FakeAutoPairingEngine alloc] init];
    engineTunnel.engineAvailable = YES;
    engineTunnel.succeed = NO;
    engineTunnel.failBlocker = A2JITAutoPairingBlockerTunnelFailed;
    engineTunnel.failReason = @"PSK 握手超时";
    engineTunnel.preconditions = [A2JITAutoPairingPreconditions allSatisfiedPreconditions];
    A2JITAutomaticPairingProvider *pTunnel =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:engineTunnel.preconditions
                                                      engine:engineTunnel
                                                       store:[[A2JITPairingFileStore alloc] initWithDirectory:TempDir()]
                                                       probe:nil];
    err = nil;
    ok(![pTunnel preparePairingWithError:&err], @"引擎失败 → 取配对失败");
    eqInt(pTunnel.lastBlocker, A2JITAutoPairingBlockerTunnelFailed, @"blocker = TunnelFailed");
    eqInt(pTunnel.lastStep, A2JITAutoPairingStepTunnel, @"★步骤落点 = Tunnel★");
    ok([err.localizedDescription containsString:@"TLS-PSK"], @"★失败文案按分类分流（TLS-PSK）★");

    // ---- ⑨ 配对文件【过期】⇒ StalePairingFile ----
    A2JITPairingFileStore *staleStore = [[A2JITPairingFileStore alloc] initWithDirectory:TempDir()];
    [staleStore importData:PlistData(RemotePairingSample()) sourceName:@"old.plist" error:NULL];
    NSDictionary *staleMeta = @{
        A2JITPairingFileStoreSourceNameKey: @"old.plist",
        A2JITPairingFileStoreImportedAtKey: [NSDate dateWithTimeIntervalSinceNow:-8.0 * 24.0 * 3600.0],
        A2JITPairingFileStoreFormatKey: @"RemotePairing",
    };
    [PlistData(staleMeta) writeToFile:staleStore.metadataFilePath atomically:YES];
    A2JITAutomaticPairingProvider *pStale =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:[A2JITAutoPairingPreconditions allSatisfiedPreconditions]
                                                      engine:engineOK
                                                       store:staleStore
                                                       probe:nil];
    ok(!pStale.isPairingReady, @"★过期文件 → 未就绪（新鲜度窗口默认 7 天）★");
    err = nil;
    ok(![pStale preparePairingWithError:&err], @"过期 → 取配对失败");
    eqInt(pStale.lastBlocker, A2JITAutoPairingBlockerStalePairingFile, @"blocker = StalePairingFile");
    ok(pStale.pairingFileMaxAge >= 6.0 * 24.0 * 3600.0, @"新鲜度窗口 >= 6 天");

    // ---- ⑩ 开启 JIT：真调判据（复用假 probe）+ 未注入判据不假装成功 ----
    FakeProbe *probeOK = [[FakeProbe alloc] init];
    A2JITAutomaticPairingProvider *pAct =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:[A2JITAutoPairingPreconditions allSatisfiedPreconditions]
                                                      engine:engineOK
                                                       store:storeOK
                                                       probe:probeOK];
    err = nil;
    ok([pAct activateJITWithError:&err], @"判据通过 → 开启成功");
    eqInt(pAct.lastVerdict, A2JITReadinessVerdictUsable, @"verdict = Usable");
    ok(probeOK.calls >= 1, @"★真调了判据内核★");

    FakeProbe *probeFail = [[FakeProbe alloc] init];
    probeFail.alwaysFail = YES;
    probeFail.verdict = A2JITReadinessVerdictNotServiced;
    probeFail.evidence = @"brk #0x69 未被服务（无调试器应答）";
    A2JITAutomaticPairingProvider *pActFail =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:[A2JITAutoPairingPreconditions allSatisfiedPreconditions]
                                                      engine:engineOK
                                                       store:storeOK
                                                       probe:probeFail];
    err = nil;
    ok(![pActFail activateJITWithError:&err], @"判据未过 → 开启失败");
    eqInt(pActFail.lastVerdict, A2JITReadinessVerdictNotServiced, @"verdict = NotServiced");
    ok([err.localizedDescription containsString:@"brk #0x69"], @"★失败文案按 verdict 分流★");

    A2JITAutomaticPairingProvider *pNoProbe =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:[A2JITAutoPairingPreconditions allSatisfiedPreconditions]
                                                      engine:engineOK
                                                       store:storeOK
                                                       probe:nil];
    err = nil;
    ok(![pNoProbe activateJITWithError:&err], @"无判据内核 → 开启失败（不假装成功）");

    // ---- ⑪ 旧签名兼容：只给事实 ⇒ 前置未知 + 引擎未接入（如实）----
    A2JITAutomaticPairingProvider *pLegacy = [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27];
    ok(!pLegacy.canGeneratePairingFile, @"旧签名 → 不能生成（前置未知 + 无引擎）");
    err = nil;
    ok(![pLegacy preparePairingWithError:&err], @"旧签名 → 取配对失败（不假成功）");
}

#pragma mark - ⑬ [JIT-AUTOPAIR-1] 自动配对分流表 + 四语

static void testAutoPairingGuidance(void) {
    printf("\n=== ⑬ 自动配对分流表（A2JITAutoPairingGuidance + 四语）===\n");

    NSArray<NSNumber *> *blockers = [A2JITAutoPairingGuidance allBlockers];
    eqInt((NSInteger)blockers.count, 14, @"14 个 blocker（None + 13 类失败）");
    eqStr([A2JITAutoPairingGuidance displayNameForBlocker:A2JITAutoPairingBlockerDeveloperModeOff],
          @"DeveloperModeOff", @"blocker 英文名稳定（日志可搜）");
    eqStr([A2JITAutoPairingGuidance displayNameForStep:A2JITAutoPairingStepPairVerify],
          @"PairVerify", @"步骤英文名稳定");

    // ★映射到【现有】A2JITFailureReason 体系（不扩枚举）★
    eqInt([A2JITAutoPairingGuidance failureReasonForBlocker:A2JITAutoPairingBlockerNone],
          A2JITFailureReasonNone, @"None → None");
    eqInt([A2JITAutoPairingGuidance failureReasonForBlocker:A2JITAutoPairingBlockerSystemTooOld],
          A2JITFailureReasonSystemTooOld, @"SystemTooOld → SystemTooOld");
    eqInt([A2JITAutoPairingGuidance failureReasonForBlocker:A2JITAutoPairingBlockerEngineUnavailable],
          A2JITFailureReasonAutoPairingNotBuilt, @"EngineUnavailable → AutoPairingNotBuilt");
    eqInt([A2JITAutoPairingGuidance failureReasonForBlocker:A2JITAutoPairingBlockerTunnelFailed],
          A2JITFailureReasonTunnelUnreachable, @"TunnelFailed → TunnelUnreachable");
    eqInt([A2JITAutoPairingGuidance failureReasonForBlocker:A2JITAutoPairingBlockerDeveloperModeOff],
          A2JITFailureReasonPairingMissing, @"DeveloperModeOff → PairingMissing");

    // ★原因 / 动作 key 一档一个★
    NSMutableSet<NSString *> *reasonKeys = [NSMutableSet set];
    NSMutableSet<NSString *> *actionKeys = [NSMutableSet set];
    for (NSNumber *b in blockers) {
        NSString *rk = [A2JITAutoPairingGuidance reasonKeyForBlocker:(A2JITAutoPairingBlocker)b.integerValue];
        NSString *ak = [A2JITAutoPairingGuidance actionKeyForBlocker:(A2JITAutoPairingBlocker)b.integerValue];
        ok(rk.length > 0, [NSString stringWithFormat:@"blocker %ld 有原因 key", (long)b.integerValue]);
        ok(ak.length > 0, [NSString stringWithFormat:@"blocker %ld 有动作 key", (long)b.integerValue]);
        [reasonKeys addObject:rk];
        [actionKeys addObject:ak];
    }
    eqInt((NSInteger)reasonKeys.count, 14, @"★14 档原因 key 互不相同★");
    eqInt((NSInteger)actionKeys.count, 14, @"★14 档动作 key 互不相同★");

    // ★四语齐全★：每个 blocker 的原因/动作 key × 4 语都非空
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSNumber *b in blockers) {
        A2JITAutoPairingBlocker blk = (A2JITAutoPairingBlocker)b.integerValue;
        NSArray<NSString *> *keys = @[ [A2JITAutoPairingGuidance reasonKeyForBlocker:blk],
                                       [A2JITAutoPairingGuidance actionKeyForBlocker:blk] ];
        for (NSString *k in keys) {
            for (NSInteger li = A2JITLanguageZhHans; li <= A2JITLanguageJapanese; li++) {
                if ([A2JITStrings stringForKey:k language:(A2JITLanguage)li].length == 0) {
                    [missing addObject:[NSString stringWithFormat:@"%@ / %ld", k, (long)li]];
                }
            }
        }
    }
    if (missing.count) {
        printf("        缺文案：%s\n", [[missing componentsJoinedByString:@", "] UTF8String]);
    }
    eqInt((NSInteger)missing.count, 0, @"★每个 blocker 的原因/动作 key 在四语里都存在且非空★");

    // 前置条件名 key × 4 语
    NSMutableArray<NSString *> *pmissing = [NSMutableArray array];
    for (NSInteger pc = A2JITAutoPairingPreconditionDeveloperMode;
         pc <= A2JITAutoPairingPreconditionDDI; pc++) {
        NSString *k = [A2JITAutoPairingGuidance nameKeyForPrecondition:(A2JITAutoPairingPrecondition)pc];
        for (NSInteger li = A2JITLanguageZhHans; li <= A2JITLanguageJapanese; li++) {
            if ([A2JITStrings stringForKey:k language:(A2JITLanguage)li].length == 0) {
                [pmissing addObject:k];
            }
        }
    }
    if (pmissing.count) {
        printf("        缺前置文案：%s\n", [[pmissing componentsJoinedByString:@", "] UTF8String]);
    }
    eqInt((NSInteger)pmissing.count, 0, @"★前置条件名 key 四语齐全★");

    // 判定态 key：三种态四语非空且互不相同（Unknown ≠ Unsatisfied，三态分得清）
    NSMutableSet<NSString *> *stateKeys = [NSMutableSet set];
    for (NSInteger st = A2JITAutoPairingPreconditionStateUnknown;
         st <= A2JITAutoPairingPreconditionStateUnsatisfied; st++) {
        NSString *k = [A2JITAutoPairingGuidance stateKeyForPreconditionState:(A2JITAutoPairingPreconditionState)st];
        [stateKeys addObject:k];
        for (NSInteger li = A2JITLanguageZhHans; li <= A2JITLanguageJapanese; li++) {
            ok([A2JITStrings stringForKey:k language:(A2JITLanguage)li].length > 0,
               [NSString stringWithFormat:@"判定态 %ld 的 key 四语非空", (long)st]);
        }
    }
    eqInt((NSInteger)stateKeys.count, 3, @"三种判定态 key 互不相同");

    // 前置条件值对象：三态语义（Unknown ≠ 已满足；未满足优先于未确认）
    eqInt(A2JITAutoPairingPreconditionCount, 4, @"前置条件共 4 项");
    A2JITAutoPairingPreconditions *allSat = [A2JITAutoPairingPreconditions allSatisfiedPreconditions];
    ok(allSat.allSatisfied, @"allSatisfiedPreconditions → 全满足");
    ok(allSat.firstUnsatisfiedPrecondition == nil, @"全满足 → 无未满足项");
    ok(allSat.firstUnconfirmedPrecondition == nil, @"全满足 → 无未确认项");
    A2JITAutoPairingPreconditions *unk = [A2JITAutoPairingPreconditions unknownPreconditions];
    ok(!unk.allSatisfied, @"★Unknown ≠ 满足（全未知不算全满足）★");
    eqInt([[unk firstUnconfirmedPrecondition] integerValue],
          A2JITAutoPairingPreconditionDeveloperMode, @"首个未确认 = DeveloperMode");
    ok(unk.firstUnsatisfiedPrecondition == nil, @"★Unknown 不算「未满足」（三态分得清）★");
    A2JITAutoPairingPreconditions *mix = [A2JITAutoPairingPreconditions
        preconditionsWithDeveloperMode:A2JITAutoPairingPreconditionStateSatisfied
                          localNetwork:A2JITAutoPairingPreconditionStateSatisfied
                          getTaskAllow:A2JITAutoPairingPreconditionStateUnsatisfied
                                   ddi:A2JITAutoPairingPreconditionStateUnknown];
    eqInt([[mix firstUnsatisfiedPrecondition] integerValue],
          A2JITAutoPairingPreconditionGetTaskAllow, @"未满足优先于未确认");
    eqInt([mix stateForPrecondition:A2JITAutoPairingPreconditionDDI],
          A2JITAutoPairingPreconditionStateUnknown, @"按项取判定态");

    // 统一日志行
    NSString *line = [A2JITAutoPairingGuidance logLineWithProvider:@"设备内自动配对"
                                                             step:A2JITAutoPairingStepTunnel
                                                          blocker:A2JITAutoPairingBlockerTunnelFailed
                                                         evidence:@"PSK 握手超时"];
    ok([line hasPrefix:@"[A2JIT]"], @"日志行以 [A2JIT] 开头");
    ok([line containsString:@"autopair"], @"日志行含 autopair");
    ok([line containsString:@"blocker=TunnelFailed"], @"日志行含 blocker");
    ok([line containsString:@"step=Tunnel"], @"日志行含步骤");
}

#pragma mark - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("A2 JIT 纯逻辑单元测试\n");
        printf("（直接链接 Air2/Player 真实实现，非镜像）\n");

        testStrategy();
        testPairingFile();
        testStateMachine();
        testFactsProbe();
        testCoordinator();
        testVerdictGuidance();
        testStrings();
        testPairingFileStore();
        testExternalToolProvider();
        testImportedPairingProvider();
        testAutomaticPairingProvider();
        testAutoPairingGuidance();
        testWiringInvariants();

        printf("\n----------------------------------------\n");
        printf("TOTAL pass=%d fail=%d\n", gPass, gFail);
        printf("----------------------------------------\n");
    }
    return gFail == 0 ? 0 : 1;
}
