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

#pragma mark - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("A2 JIT 纯逻辑单元测试\n");
        printf("（直接链接 Air2/Player 真实实现，非镜像）\n");

        testStrategy();
        testPairingFile();
        testStateMachine();
        testFactsProbe();

        printf("\n----------------------------------------\n");
        printf("TOTAL pass=%d fail=%d\n", gPass, gFail);
        printf("----------------------------------------\n");
    }
    return gFail == 0 ? 0 : 1;
}
