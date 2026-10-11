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
// [JIT↔VM] 启动链失败分类 / 判据行 / 用户文案（Player 纯逻辑）
#import "A2LaunchFailure.h"
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
// [JIT-DDI-1] DDI：类型 / 纯逻辑 / 本地镜像存储 / 判定合成 / 分流表
#import "A2JITDDI.h"
#import "A2JITDDIStore.h"
#import "A2JITDDIProbe.h"
#import "A2JITDDIGuidance.h"
// ★跨层镜像的运行期断言用★：直接读 Natives 的判据枚举（-I Natives/Support，不链接其实现）。
#import "A2JITEnvironment.h"
// [JIT-AUTOPAIR-2] RPPairing 握手内核（★这些是【真实现】源文件，直接编译并链接运行★）
#import "a2_rppairing.h"
// [JIT-AUTOPAIR-2] 真握手本体：pair-verify 消息机 + RSD 发现/连接
#import "a2_rppairing_verify.h"
#import "a2_rppairing_rsd.h"
// [A2-INTEGRATION] TLS-PSK 隧道门面（可替换后端 / 默认关 / 不上云）—— 真实现直接编译并链接
#import "a2_tlspsk_tunnel.h"
// [JIT-AUTOPAIR-3] pair-setup(SRP-3072)：SRP 内核 + 消息机（★真实现直接链接★）；SHA-1 仅用于核对 RFC 5054 向量
#import "a2_rppairing_srp.h"
#import "a2_rppairing_pairsetup.h"
// [JIT-AUTOPAIR-3] 配对码来源（可选项）+ 设备发起档的 6 位码会话 + 契约键
#import "A2JITPairingPinSource.h"
#import "A2JITPairingCodeSession.h"
#import "A2LaunchContract.h"
#import <CommonCrypto/CommonDigest.h>

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

/// [JIT-DDI-1] 假设备侧查询：可配置"设备侧判定 / 能力 / 调用结果"，并记录调用次数。
@interface FakeDDIDeviceQuery : NSObject <A2JITDDIDeviceQuery>
@property (nonatomic, assign) A2JITDDIVerdict deviceVerdict;
@property (nonatomic, copy) NSString *deviceEvidence;
@property (nonatomic, assign) BOOL fetchResult;
@property (nonatomic, copy) NSString *fetchReason;
@property (nonatomic, copy) NSString *mountReason;
@property (nonatomic, assign) NSInteger fetchCalls;
@property (nonatomic, assign) NSInteger mountCalls;
@end

@implementation FakeDDIDeviceQuery
- (instancetype)init {
    self = [super init];
    if (self) {
        _deviceVerdict = A2JITDDIVerdictUnknown;
        _deviceEvidence = @"fake 设备侧：不可查";
        _fetchResult = NO;
        _fetchReason = @"fake 未接入";
        _mountReason = @"fake 缺特权";
    }
    return self;
}
- (A2JITDDIVerdict)deviceDDIVerdictWithEvidence:(NSString *_Nullable *_Nullable)evidenceOut {
    if (evidenceOut) *evidenceOut = self.deviceEvidence;
    return self.deviceVerdict;
}
- (BOOL)fetchPersonalizedImageForRequirement:(A2JITDDIRequirement *)requirement
                                      reason:(NSString *_Nullable *_Nullable)reasonOut {
    (void)requirement;
    self.fetchCalls += 1;
    if (reasonOut) *reasonOut = self.fetchReason;
    return self.fetchResult;
}
- (BOOL)mountImageAtPath:(NSString *)imagePath
           trustcachePath:(nullable NSString *)trustcachePath
                  reason:(NSString *_Nullable *_Nullable)reasonOut {
    (void)imagePath;
    (void)trustcachePath;
    self.mountCalls += 1;
    if (reasonOut) *reasonOut = self.mountReason;
    return NO;
}
@end

/// 一份最小「合法 UDIF 磁盘镜像」样本（512 的整数倍 + 尾标块以 'koly' 开头）。
static NSData *UDIFSample(NSUInteger blocks) {
    if (blocks < 2) {
        blocks = 2;
    }
    NSMutableData *d = [NSMutableData dataWithLength:blocks * 512];
    uint8_t *p = (uint8_t *)d.mutableBytes;
    NSUInteger trailer = (blocks - 1) * 512;
    p[trailer + 0] = 'k';
    p[trailer + 1] = 'o';
    p[trailer + 2] = 'l';
    p[trailer + 3] = 'y';
    return d;
}

/// 写 [dir]/ddi.meta.plist（★带声明版本/构建号★，用于把 importedAt 改到过去以验「过期」）。
static void WriteDDIMeta(A2JITDDIStore *store, NSDate *importedAt) {
    NSDictionary *meta = @{ A2JITDDIStoreSourceNameKey: @"t.dmg",
                            A2JITDDIStoreImportedAtKey: importedAt,
                            A2JITDDIStoreKindKey: @"Legacy",
                            A2JITDDIStoreDeclaredOSVersionKey: @"27.2",
                            A2JITDDIStoreDeclaredBuildKey: @"24B5084k" };
    [PlistData(meta) writeToFile:store.metadataFilePath atomically:YES];
}

/// 把一份合法样本写到临时文件，返回其 file URL（导入走【真机同一条路】：URL）。
static NSURL *WriteTempDDIFile(NSString *name) {
    NSString *dir = TempDir();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:name];
    [UDIFSample(4) writeToFile:path atomically:YES];
    return [NSURL fileURLWithPath:path];
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
    ok(engineSrc.length > 0, @"读得到自动配对引擎 Bridge");
    ok([engineSrc containsString:@"A2RPRSDPairVerifyClient"], @"★Bridge 真调 pair-verify 客户端（真握手本体）★");
    ok([engineSrc containsString:@"A2RPRSDDiscovery"], @"★Bridge 真做 Bonjour 发现★");
    ok([engineSrc containsString:@"A2JITAutoPairingBlockerDiscoveryFailed"], @"没发现端点 ⇒ DiscoveryFailed（按步骤分类）");
    ok([engineSrc containsString:@"A2JITAutoPairingBlockerPairVerifyFailed"], @"握手失败 ⇒ PairVerifyFailed");
    ok([engineSrc containsString:@"A2JITAutoPairingBlockerWriteFailed"], @"落盘失败 ⇒ WriteFailed");
    ok([engineSrc containsString:@"pairingFileStore == nil"], @"★没注入存储 ⇒ 报 WriteFailed、不返回成功★");
    ok([engineSrc containsString:@"importData:fileData"], @"★真把配对文件写进注入的存储★");
    ok([engineSrc containsString:@"NSProcessInfo.processInfo.hostName"], @"identifier 由 hostname 派生（规格 §7）");
    ok([engineSrc containsString:@"A2RPRSDPublicTLSPSKPathSufficient"], @"★「TLS-PSK 公开路径不通」在 Bridge 里如实记录★");
    ok([engineSrc containsString:@"unknownPreconditions"], @"前置条件以「全 Unknown」为底（不谎报满足）");
    ok(![engineSrc containsString:@"#import \"A2JITEnvironment.h\""], @"Bridge 不 import Natives 判据头");
    ok([settingsSrc containsString:@"autoEngine.pairingFileStore = store"], @"★设置页把落盘目标注进引擎（有生产调用点）★");

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

    // ⑩ ★[JIT-DDI-1] 设置页接入 DDI + Bridge 骨架如实报 + 分层纪律★
    ok([settingsSrc containsString:@"A2JITDDIStore"], @"设置页接入 DDI 本地镜像存储");
    ok([settingsSrc containsString:@"A2JITLocalDDIProbe"], @"设置页接入 DDI 判定缝（真三态）");
    ok([settingsSrc containsString:@"jit.row.ddiFetch"], @"设置页有「联网取 DDI」开关行");
    ok([settingsSrc containsString:@"debug.jit_ddi_fetch"], @"开关走偏好键（★默认关★）");
    ok([settingsSrc containsString:@"runDDIFetch"], @"设置页有「联网取 DDI」的调用点");
    ok([settingsSrc containsString:@"presentDDIImportPicker"], @"设置页有 DDI 导入入口");
    ok([settingsSrc containsString:@"A2JITDDIDeviceBridge"], @"设置页注入 DDI 设备侧 Bridge（骨架）");
    ok([settingsSrc containsString:@"ddiProbe:ddiProbe"], @"设置页把 DDI 探测注入 Provider 装配");
    ok([settingsSrc containsString:@"runDDIMount"], @"设置页有「挂载 DDI」的调用点（如实失败）");

    NSString *ddiBridgeSrc = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Bridge/A2JITDDIDeviceBridge.m")
                                                      encoding:NSUTF8StringEncoding
                                                         error:NULL];
    ok(ddiBridgeSrc.length > 0, @"读得到 DDI 设备侧 Bridge");
    ok([ddiBridgeSrc containsString:@"return A2JITDDIVerdictUnknown;"], @"★骨架设备侧判定如实回 Unknown（不猜）★");
    ok([ddiBridgeSrc containsString:@"return NO;"], @"骨架能力查询如实回 NO");
    ok([ddiBridgeSrc containsString:@"fetchPersonalizedImage"], @"骨架有「联网取 DDI」调用点");
    ok([ddiBridgeSrc containsString:@"mountImageAtPath"], @"骨架有挂载调用点");
    ok([ddiBridgeSrc containsString:@"Apple"], @"★文案点名「访问 Apple 官方服务」（非「上云」）★");
    ok(![ddiBridgeSrc containsString:@"#import \"A2JITEnvironment.h\""], @"DI 骨架不 import Natives 判据头");

    // ★Player 无一处 import Bridge（含 DDI 设备侧 Bridge）★
    NSInteger ddiBridgeLeaks = 0;
    for (NSString *f in files) {
        if (![f hasSuffix:@".m"]) {
            continue;
        }
        NSString *src = [NSString stringWithContentsOfFile:[playerDir stringByAppendingPathComponent:f]
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        if ([src containsString:@"#import \"A2JITDDIDeviceBridge.h\""]) {
            ddiBridgeLeaks++;
            printf("        ★Player 越界 import DDI Bridge：%s\n", f.UTF8String);
        }
    }
    eqInt(ddiBridgeLeaks, 0, @"★Player 无一处 import DDI 设备侧 Bridge（单向分层）★");

    // ★DDI 探测实现不得 import Bridge / Natives 头★
    NSString *ddiProbeSrc = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Player/A2JITDDIProbe.m")
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
    ok(ddiProbeSrc.length > 0, @"读得到 DDI 判定合成实现");
    ok([ddiProbeSrc containsString:@"deviceDDIVerdictWithEvidence"] ||
       [ddiProbeSrc containsString:@"ddiStatus"], @"DDI 判定合成真调注入的设备侧查询");
    ok(![ddiProbeSrc containsString:@"#import \"A2JITDDIDeviceBridge.h\""], @"DDI 判定合成不 import Bridge");
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

#pragma mark - ⑭ [JIT-DDI-1] DDI 纯逻辑 + 本地镜像存储

/// 构造一份镜像值对象（测试用；字段直给，便于逐分支）。
static A2JITDDIImage *DDIImage(NSString *path, A2JITDDIKind kind, A2JITDDISource src,
                               unsigned long long size, NSDate *importedAt,
                               NSString *declaredBuild, NSString *declaredVersion) {
    return [A2JITDDIImage imageWithFilePath:path
                             trustcachePath:nil
                                       kind:kind
                                     source:src
                                   byteSize:size
                                     sha256:nil
                                 importedAt:importedAt
                              declaredBuild:declaredBuild
                          declaredOSVersion:declaredVersion];
}

static void testDDILogicAndStore(void) {
    printf("\n=== ⑭ DDI 纯逻辑 + 本地镜像存储 ===\n");

    A2JITDDIRequirement *req = [A2JITDDIRequirement requirementWithOSMajorVersion:27
                                                                    minorVersion:2
                                                                           build:@"24B5084k"];
    eqStr([req versionString], @"27.2", @"requirement versionString");
    eqStr([req displayVersion], @"27.2 (24B5084k)", @"requirement displayVersion");

    // 稳定英文名（日志可搜）
    eqStr([A2JITDDI displayNameForVerdict:A2JITDDIVerdictVersionMismatch], @"VersionMismatch", @"判定英文名稳定");
    eqStr([A2JITDDI displayNameForSource:A2JITDDISourceUserImport], @"UserImport", @"来源英文名稳定");

    // 系统构建号解析（NSProcessInfo 形态）
    eqStr([A2JITDDI buildFromOperatingSystemVersionString:@"Version 27.2 (Build 24B5084k)"],
          @"24B5084k", @"从 operatingSystemVersionString 取构建号");
    eqStr([A2JITDDI buildFromOperatingSystemVersionString:@"Version 14.5 (Build 23F79)"],
          @"23F79", @"短构建号也认");
    ok([A2JITDDI buildFromOperatingSystemVersionString:@""] == nil, @"空串取不到构建号 ⇒ nil（不猜）");

    // ---- ★版本对齐三态★ ----
    NSString *why = nil;
    NSDate *now = [NSDate date];
    A2JITDDIImage *imgBuildOK = DDIImage(@"/x/a.dmg", A2JITDDIKindPersonalized, A2JITDDISourceContainer,
                                         4096, now, @"24B5084k", @"27.2");
    A2JITDDIImage *imgBuildBad = DDIImage(@"/x/b.dmg", A2JITDDIKindPersonalized, A2JITDDISourceContainer,
                                          4096, now, @"24A1111x", @"27.2");
    A2JITDDIImage *imgVerOK = DDIImage(@"/x/c.dmg", A2JITDDIKindLegacy, A2JITDDISourceContainer,
                                       4096, now, nil, @"27.2");
    A2JITDDIImage *imgVerBad = DDIImage(@"/x/d.dmg", A2JITDDIKindLegacy, A2JITDDISourceContainer,
                                        4096, now, nil, @"26.0");
    A2JITDDIImage *imgNoDecl = DDIImage(@"/x/e.dmg", A2JITDDIKindUnknown, A2JITDDISourceContainer,
                                        4096, now, nil, nil);

    eqInt([A2JITDDI matchOfImage:imgBuildOK withRequirement:req why:&why], A2JITDDIMatchMatched,
          @"构建号一致 ⇒ Matched");
    eqInt([A2JITDDI matchOfImage:imgBuildBad withRequirement:req why:&why], A2JITDDIMatchMismatched,
          @"构建号不一致 ⇒ Mismatched");
    A2JITDDIRequirement *reqNoBuild = [A2JITDDIRequirement requirementWithOSMajorVersion:27
                                                                           minorVersion:2
                                                                                  build:nil];
    eqInt([A2JITDDI matchOfImage:imgBuildOK withRequirement:reqNoBuild why:&why], A2JITDDIMatchUnknown,
          @"★系统构建号取不到 ⇒ Unknown（不猜成匹配）★");
    eqInt([A2JITDDI matchOfImage:imgVerOK withRequirement:req why:&why], A2JITDDIMatchMatched,
          @"版本串一致 ⇒ Matched");
    eqInt([A2JITDDI matchOfImage:imgVerBad withRequirement:req why:&why], A2JITDDIMatchMismatched,
          @"版本串不一致 ⇒ Mismatched");
    eqInt([A2JITDDI matchOfImage:imgNoDecl withRequirement:req why:&why], A2JITDDIMatchUnknown,
          @"★镜像未声明版本/构建号 ⇒ Unknown（不猜）★");

    // ---- ★综合判定五态★ ----
    NSTimeInterval maxAge = [A2JITDDI defaultMaxAge];
    eqInt([A2JITDDI verdictForImage:nil withRequirement:req maxAge:maxAge now:now why:&why],
          A2JITDDIVerdictMissing, @"无镜像 ⇒ Missing（明确缺失）");
    eqInt([A2JITDDI verdictForImage:imgBuildOK withRequirement:req maxAge:3600 now:now why:&why],
          A2JITDDIVerdictPresent, @"匹配 + 新鲜 ⇒ Present");
    eqInt([A2JITDDI verdictForImage:imgBuildBad withRequirement:req maxAge:3600 now:now why:&why],
          A2JITDDIVerdictVersionMismatch, @"不匹配 ⇒ VersionMismatch");
    eqInt([A2JITDDI verdictForImage:imgNoDecl withRequirement:req maxAge:3600 now:now why:&why],
          A2JITDDIVerdictUnknown, @"★未声明 ⇒ Unknown（绝不猜成 Present）★");
    A2JITDDIImage *imgNoDate = DDIImage(@"/x/f.dmg", A2JITDDIKindPersonalized, A2JITDDISourceContainer,
                                        4096, nil, @"24B5084k", @"27.2");
    eqInt([A2JITDDI verdictForImage:imgNoDate withRequirement:req maxAge:3600 now:now why:&why],
          A2JITDDIVerdictUnknown, @"★无导入时间 ⇒ 无法判新鲜度 ⇒ Unknown★");
    A2JITDDIImage *imgOld = DDIImage(@"/x/g.dmg", A2JITDDIKindPersonalized, A2JITDDISourceContainer,
                                     4096, [NSDate dateWithTimeIntervalSinceNow:-8.0 * 24.0 * 3600.0],
                                     @"24B5084k", @"27.2");
    eqInt([A2JITDDI verdictForImage:imgOld withRequirement:req maxAge:maxAge now:now why:&why],
          A2JITDDIVerdictStale, @"超出窗口 ⇒ Stale");
    A2JITDDIImage *imgEmpty = DDIImage(@"/x/h.dmg", A2JITDDIKindUnknown, A2JITDDISourceContainer,
                                       0, now, @"24B5084k", @"27.2");
    eqInt([A2JITDDI verdictForImage:imgEmpty withRequirement:req maxAge:3600 now:now why:&why],
          A2JITDDIVerdictUnknown, @"空/不可读镜像 ⇒ Unknown");

    // ---- ★三态映射：Unknown 只由 Unknown 产生★ ----
    eqInt([A2JITDDI preconditionStateValueForVerdict:A2JITDDIVerdictPresent],
          A2JITAutoPairingPreconditionStateSatisfied, @"Present ⇒ Satisfied");
    eqInt([A2JITDDI preconditionStateValueForVerdict:A2JITDDIVerdictMissing],
          A2JITAutoPairingPreconditionStateUnsatisfied, @"Missing ⇒ Unsatisfied");
    eqInt([A2JITDDI preconditionStateValueForVerdict:A2JITDDIVerdictVersionMismatch],
          A2JITAutoPairingPreconditionStateUnsatisfied, @"VersionMismatch ⇒ Unsatisfied");
    eqInt([A2JITDDI preconditionStateValueForVerdict:A2JITDDIVerdictStale],
          A2JITAutoPairingPreconditionStateUnsatisfied, @"Stale ⇒ Unsatisfied");
    eqInt([A2JITDDI preconditionStateValueForVerdict:A2JITDDIVerdictUnknown],
          A2JITAutoPairingPreconditionStateUnknown, @"★Unknown ⇒ Unknown（不许升成满足/缺失）★");
    ok([A2JITDDI defaultMaxAge] >= 6.0 * 24.0 * 3600.0, @"默认新鲜度窗口 ≥ 6 天");

    // ---- 本地存储：校验（★走真机同一条路：URL 导入★）----
    A2JITDDIStore *store = [[A2JITDDIStore alloc] initWithDirectory:TempDir()];
    ok([store isStoreReadable], @"目录尚未创建 ⇒ 可读（= 确定没有镜像）");
    ok([store currentImage] == nil, @"空目录 ⇒ 无镜像");

    NSError *impErr = nil;
    ok([store importImageFromURL:[NSURL fileURLWithPath:@"/nonexistent/x.dmg"]
                      sourceName:@"x.dmg"
                           error:&impErr] == nil, @"不存在的文件 ⇒ 拒绝导入");
    ok(impErr != nil, @"拒绝时给出原因");

    NSString *badDir = TempDir();
    [[NSFileManager defaultManager] createDirectoryAtPath:badDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSString *badPath = [badDir stringByAppendingPathComponent:@"bad.dmg"];
    [[NSMutableData dataWithLength:1024 + 100] writeToFile:badPath atomically:YES];
    impErr = nil;
    ok([store importImageFromURL:[NSURL fileURLWithPath:badPath] sourceName:@"bad.dmg" error:&impErr] == nil,
       @"非 512 整数倍 ⇒ 拒绝导入");
    ok([impErr.localizedDescription containsString:@"磁盘镜像"], @"★拒绝理由写明「不是磁盘镜像」★");

    NSString *zeroPath = [badDir stringByAppendingPathComponent:@"zero.dmg"];
    [[NSMutableData dataWithLength:1024] writeToFile:zeroPath atomically:YES];
    ok([store importImageFromURL:[NSURL fileURLWithPath:zeroPath] sourceName:@"zero.dmg" error:NULL] == nil,
       @"尾标不是 'koly' ⇒ 拒绝导入");

    // ★合法镜像 ⇒ 导入成功（真机同一条路；声明版本/构建号来自来源文件名）★
    NSString *p = [store importImageFromURL:WriteTempDDIFile(@"DeveloperDiskImage-27.2-24B5084k.dmg")
                                 sourceName:@"DeveloperDiskImage-27.2-24B5084k.dmg"
                                      error:NULL];
    ok(p.length > 0, @"合法镜像 ⇒ 导入成功");
    A2JITDDIImage *cur = [store currentImage];
    ok(cur != nil, @"导入后 ⇒ currentImage 真探测到");
    eqStr(cur.declaredOSVersion, @"27.2", @"落盘后取到声明的版本串");
    eqStr(cur.declaredBuild, @"24B5084k", @"落盘后取到声明的构建号");
    eqInt(cur.source, A2JITDDISourceContainer, @"来源 = 容器");
    ok(cur.sha256.length == 64, @"记录 SHA-256（64 hex）");

    WriteDDIMeta(store, [NSDate dateWithTimeIntervalSinceNow:-8.0 * 24.0 * 3600.0]);
    NSString *why2 = nil;
    eqInt([A2JITDDI verdictForImage:[store currentImage]
                    withRequirement:req
                             maxAge:maxAge
                                now:[NSDate date]
                                why:&why2],
          A2JITDDIVerdictStale, @"元数据改到 8 天前 ⇒ Stale");

    ok([store currentImage] != nil, @"★过期只是「判定」，文件仍在（不删用户文件）★");

    // ★目录不可读 ⇒ isStoreReadable = NO（判定只能报「无法确认」）★
    NSString *filePath = [TempDir() stringByAppendingPathComponent:@"notadir"];
    [[NSFileManager defaultManager] createDirectoryAtPath:filePath.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    [@"x" writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    A2JITDDIStore *fileStore = [[A2JITDDIStore alloc] initWithDirectory:filePath];
    ok(![fileStore isStoreReadable], @"★目录位置是文件 ⇒ 不可读 ⇒ 只能报无法确认★");

    // 文件名里的显式声明（★只有显式声明才认；无声明 ⇒ nil，不猜★）
    eqStr([A2JITDDIStore osVersionFromFileName:@"DeveloperDiskImage-27.2-24B5084k.dmg"], @"27.2",
          @"文件名取版本串");
    eqStr([A2JITDDIStore buildFromFileName:@"DeveloperDiskImage-27.2-24B5084k.dmg"], @"24B5084k",
          @"文件名取构建号");
    ok([A2JITDDIStore buildFromFileName:@"DeveloperDiskImage.dmg"] == nil, @"无声明 ⇒ 构建号 nil（不猜）");
}

#pragma mark - ⑮ [JIT-DDI-1] DDI 判定合成 + 分流表四语 + Provider 接线

static void testDDIProbeAndGuidance(void) {
    printf("\n=== ⑮ DDI 判定合成 + 分流表（四语）+ Provider 接线 ===\n");

    A2JITDDIRequirement *req = [A2JITDDIRequirement requirementWithOSMajorVersion:27
                                                                    minorVersion:2
                                                                           build:@"24B5084k"];

    // ---- 分流表 ----
    NSArray<NSNumber *> *verdicts = [A2JITDDIGuidance allVerdicts];
    eqInt((NSInteger)verdicts.count, 5, @"5 档 DDI 判定");
    eqStr([A2JITDDI displayNameForVerdict:A2JITDDIVerdictMissing], @"Missing", @"判定英文名稳定");
    eqInt([A2JITDDIGuidance preconditionStateForVerdict:A2JITDDIVerdictPresent],
          A2JITAutoPairingPreconditionStateSatisfied, @"分流表：Present ⇒ Satisfied");
    eqInt([A2JITDDIGuidance preconditionStateForVerdict:A2JITDDIVerdictUnknown],
          A2JITAutoPairingPreconditionStateUnknown, @"★分流表：Unknown ⇒ Unknown★");
    eqInt([A2JITDDIGuidance preconditionStateForVerdict:A2JITDDIVerdictStale],
          A2JITAutoPairingPreconditionStateUnsatisfied, @"分流表：Stale ⇒ Unsatisfied");

    // 每档的 status / reason key 互不相同，且四语齐全
    NSMutableSet<NSString *> *statusKeys = [NSMutableSet set];
    NSMutableSet<NSString *> *reasonKeys = [NSMutableSet set];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSNumber *v in verdicts) {
        A2JITDDIVerdict dv = (A2JITDDIVerdict)v.integerValue;
        NSString *sk = [A2JITDDIGuidance statusKeyForVerdict:dv];
        NSString *rk = [A2JITDDIGuidance reasonKeyForVerdict:dv];
        [statusKeys addObject:sk];
        [reasonKeys addObject:rk];
        for (NSString *k in @[ sk, rk ]) {
            for (NSInteger li = A2JITLanguageZhHans; li <= A2JITLanguageJapanese; li++) {
                if ([A2JITStrings stringForKey:k language:(A2JITLanguage)li].length == 0) {
                    [missing addObject:[NSString stringWithFormat:@"%@ / %ld", k, (long)li]];
                }
            }
        }
    }
    if (missing.count) {
        printf("        缺 DDI 文案：%s\n", [[missing componentsJoinedByString:@", "] UTF8String]);
    }
    eqInt((NSInteger)statusKeys.count, 5, @"★5 档状态 key 互不相同★");
    eqInt((NSInteger)reasonKeys.count, 5, @"★5 档原因 key 互不相同★");
    eqInt((NSInteger)missing.count, 0, @"★DDI 状态/原因 key 四语齐全且非空★");

    // ★机制阻塞文案（联网取 / 挂载）四语齐全★
    NSArray<NSString *> *blockerKeys = @[
        [A2JITDDIGuidance fetchDisabledReasonKey], [A2JITDDIGuidance fetchDisabledActionKey],
        [A2JITDDIGuidance fetchUnsupportedReasonKey], [A2JITDDIGuidance fetchUnsupportedActionKey],
        [A2JITDDIGuidance mountUnavailableReasonKey], [A2JITDDIGuidance mountUnavailableActionKey],
    ];
    NSMutableArray<NSString *> *bmissing = [NSMutableArray array];
    for (NSString *k in blockerKeys) {
        for (NSInteger li = A2JITLanguageZhHans; li <= A2JITLanguageJapanese; li++) {
            if ([A2JITStrings stringForKey:k language:(A2JITLanguage)li].length == 0) {
                [bmissing addObject:k];
            }
        }
    }
    eqInt((NSInteger)bmissing.count, 0, @"★联网取 / 挂载的阻塞文案四语齐全★");

    // 「下一步动作」按判定 + 开关取值
    eqStr([A2JITDDIGuidance nextActionKeyForVerdict:A2JITDDIVerdictPresent fetchEnabled:NO],
          @"jit.ddi.next.ready", @"就位 ⇒ ready");
    eqStr([A2JITDDIGuidance nextActionKeyForVerdict:A2JITDDIVerdictMissing fetchEnabled:NO],
          @"jit.ddi.next.enableFetch", @"缺失 + 开关关 ⇒ 去开开关");
    eqStr([A2JITDDIGuidance nextActionKeyForVerdict:A2JITDDIVerdictMissing fetchEnabled:YES],
          @"jit.ddi.next.fetch", @"缺失 + 开关开 ⇒ 去联网取");
    eqStr([A2JITDDIGuidance nextActionKeyForVerdict:A2JITDDIVerdictStale fetchEnabled:YES],
          @"jit.ddi.next.reimport", @"过期 ⇒ 重新导入");
    eqStr([A2JITDDIGuidance nextActionKeyForVerdict:A2JITDDIVerdictUnknown fetchEnabled:YES],
          @"jit.ddi.next.unconfirmed", @"无法确认 ⇒ 先看取证");

    // 统一日志行
    NSString *line = [A2JITDDIGuidance logLineWithProvider:@"本地 DDI 探测"
                                                   verdict:A2JITDDIVerdictMissing
                                                  evidence:@"本地未发现 DDI 镜像"];
    ok([line hasPrefix:@"[A2JIT]"], @"DDI 日志行以 [A2JIT] 开头");
    ok([line containsString:@"ddi"], @"DDI 日志行含 ddi");
    ok([line containsString:@"verdict=Missing"], @"DDI 日志行含判定");

    // ---- 判定合成 ----
    A2JITDDIStore *emptyStore = [[A2JITDDIStore alloc] initWithDirectory:TempDir()];
    FakeDDIDeviceQuery *dev = [[FakeDDIDeviceQuery alloc] init];   // 设备侧 Unknown
    A2JITLocalDDIProbe *probeEmpty = [[A2JITLocalDDIProbe alloc] initWithStore:emptyStore
                                                                  requirement:req
                                                                  deviceQuery:dev];
    A2JITDDIStatus *st = [probeEmpty ddiStatus];
    eqInt(st.verdict, A2JITDDIVerdictMissing, @"本地无镜像 + 设备不可查 ⇒ Missing");
    ok(st.evidence.length > 0, @"判定必带取证文本");
    eqInt([probeEmpty localVerdictWithEvidence:NULL], A2JITDDIVerdictMissing, @"只跑本地那一半也 ⇒ Missing");

    // 本地有匹配镜像 ⇒ Present
    A2JITDDIStore *okStore = [[A2JITDDIStore alloc] initWithDirectory:TempDir()];
    [okStore importImageFromURL:WriteTempDDIFile(@"DeveloperDiskImage-27.2-24B5084k.dmg")
                     sourceName:@"DeveloperDiskImage-27.2-24B5084k.dmg"
                          error:NULL];
    A2JITLocalDDIProbe *probeOK = [[A2JITLocalDDIProbe alloc] initWithStore:okStore
                                                               requirement:req
                                                               deviceQuery:dev];
    A2JITDDIStatus *stOK = [probeOK ddiStatus];
    eqInt(stOK.verdict, A2JITDDIVerdictPresent, @"本地匹配 + 新鲜 ⇒ Present");
    ok(stOK.imagePath.length > 0, @"Present 带上镜像路径");

    // 本地不可用但设备侧确认有 ⇒ Present（来源 Device）
    dev.deviceVerdict = A2JITDDIVerdictPresent;
    dev.deviceEvidence = @"设备侧报告已有可用 DDI";
    A2JITDDIStore *empty2 = [[A2JITDDIStore alloc] initWithDirectory:TempDir()];
    A2JITLocalDDIProbe *probeDev = [[A2JITLocalDDIProbe alloc] initWithStore:empty2
                                                                requirement:req
                                                                deviceQuery:dev];
    A2JITDDIStatus *stDev = [probeDev ddiStatus];
    eqInt(stDev.verdict, A2JITDDIVerdictPresent, @"设备侧确认有 ⇒ Present");
    eqInt(stDev.source, A2JITDDISourceDevice, @"来源标 Device");

    // 设备侧 Unknown + 本地镜像未声明版本 ⇒ Unknown（★不许猜★）
    dev.deviceVerdict = A2JITDDIVerdictUnknown;
    dev.deviceEvidence = @"fake 设备侧：不可查";
    A2JITDDIStore *noDeclStore = [[A2JITDDIStore alloc] initWithDirectory:TempDir()];
    [noDeclStore importImageFromURL:WriteTempDDIFile(@"DeveloperDiskImage.dmg")
                         sourceName:@"DeveloperDiskImage.dmg"
                              error:NULL];
    A2JITLocalDDIProbe *probeNoDecl = [[A2JITLocalDDIProbe alloc] initWithStore:noDeclStore
                                                                   requirement:req
                                                                   deviceQuery:dev];
    A2JITDDIStatus *stNoDecl = [probeNoDecl ddiStatus];
    eqInt(stNoDecl.verdict, A2JITDDIVerdictUnknown, @"★镜像未声明版本 ⇒ Unknown（不猜成 Present）★");
    ok([stNoDecl.evidence containsString:@"无法"], @"★取证写明「无法对齐」★");

    // 目录不可读 ⇒ Unknown
    NSString *filePath = [TempDir() stringByAppendingPathComponent:@"notadir"];
    [[NSFileManager defaultManager] createDirectoryAtPath:filePath.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    [@"x" writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    A2JITDDIStore *fileStore = [[A2JITDDIStore alloc] initWithDirectory:filePath];
    A2JITLocalDDIProbe *probeBad = [[A2JITLocalDDIProbe alloc] initWithStore:fileStore
                                                                requirement:req
                                                                deviceQuery:dev];
    eqInt([probeBad ddiStatus].verdict, A2JITDDIVerdictUnknown, @"★目录不可读 ⇒ Unknown★");

    // 无设备查询（未接线）⇒ 本地结论，如实
    A2JITLocalDDIProbe *probeNoDev = [[A2JITLocalDDIProbe alloc] initWithStore:okStore
                                                                  requirement:req
                                                                  deviceQuery:nil];
    eqInt([probeNoDev ddiStatus].verdict, A2JITDDIVerdictPresent, @"无设备查询但本地已就位 ⇒ Present");
    NSString *r1 = nil;
    ok(![probeNoDev fetchPersonalizedImageWithReason:&r1], @"未接线 ⇒ 联网取 DDI 失败");
    ok([r1 containsString:@"未接线"], @"★并点名缺什么（未接线）★");
    ok(![probeNoDev mountCurrentImageWithReason:&r1], @"未接线 ⇒ 挂载不可用");
    ok([r1 containsString:@"未接线"] || [r1 containsString:@"image_mounter"], @"★挂载失败也点名原因★");

    // 接了设备侧（假）⇒ 真转发调用（不是空操作）
    dev.fetchResult = NO;
    dev.fetchReason = @"镜像来源未定";
    A2JITLocalDDIProbe *probeForward = [[A2JITLocalDDIProbe alloc] initWithStore:okStore
                                                                    requirement:req
                                                                    deviceQuery:dev];
    ok(![probeForward fetchPersonalizedImageWithReason:&r1], @"接了但机制未接入 ⇒ 仍失败");
    eqInt(dev.fetchCalls, 1, @"★真转发了调用（不是空操作）★");
    ok([r1 containsString:@"镜像来源"], @"转发回来的原因被带出");
    ok(![probeForward mountCurrentImageWithReason:&r1], @"接了但挂载未接入 ⇒ 仍失败");
    eqInt(dev.mountCalls, 1, @"★挂载也真转发了调用（不是空操作）★");

    // ---- ★Provider 接线：DDI 真三态进入前置条件★ ----
    A2JITFacts *f27 = Facts(27, 0, A2JITEnvironmentKindPlain);
    FakeAutoPairingEngine *eng = [[FakeAutoPairingEngine alloc] init];
    eng.engineAvailable = YES;
    eng.succeed = YES;
    A2JITAutoPairingPreconditions *base = [A2JITAutoPairingPreconditions
        preconditionsWithDeveloperMode:A2JITAutoPairingPreconditionStateSatisfied
                          localNetwork:A2JITAutoPairingPreconditionStateSatisfied
                          getTaskAllow:A2JITAutoPairingPreconditionStateSatisfied
                                   ddi:A2JITAutoPairingPreconditionStateUnknown];

    // 不注入 ddiProbe ⇒ DDI 保持 Unknown（行为与上一版一致，无回退）
    A2JITAutomaticPairingProvider *p0 =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:base
                                                      engine:eng
                                                       store:[[A2JITPairingFileStore alloc] initWithDirectory:TempDir()]
                                                       probe:nil];
    eqInt([p0.effectivePreconditions stateForPrecondition:A2JITAutoPairingPreconditionDDI],
          A2JITAutoPairingPreconditionStateUnknown, @"★无探测 ⇒ DDI 保持 Unknown★");
    ok(p0.ddiStatus == nil, @"无探测 ⇒ ddiStatus 为 nil");

    // 注入「缺失」探测 ⇒ DDI = Unsatisfied（真三态的「缺失」）
    FakeDDIDeviceQuery *devUnknown = [[FakeDDIDeviceQuery alloc] init];
    A2JITDDIStore *eStore = [[A2JITDDIStore alloc] initWithDirectory:TempDir()];
    A2JITLocalDDIProbe *pMissing = [[A2JITLocalDDIProbe alloc] initWithStore:eStore
                                                                 requirement:req
                                                                 deviceQuery:devUnknown];
    A2JITAutomaticPairingProvider *p1 =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:base
                                                      engine:eng
                                                    ddiProbe:pMissing
                                                       store:[[A2JITPairingFileStore alloc] initWithDirectory:TempDir()]
                                                       probe:nil];
    eqInt([p1.effectivePreconditions stateForPrecondition:A2JITAutoPairingPreconditionDDI],
          A2JITAutoPairingPreconditionStateUnsatisfied, @"★探测「缺失」⇒ DDI = Unsatisfied★");
    ok(p1.ddiStatus != nil, @"注入后 ddiStatus 非 nil");
    eqInt([[p1 firstBlockingPrecondition] integerValue], A2JITAutoPairingPreconditionDDI, @"空缺项 = DDI");
    eqStr([p1 blockingPreconditionReasonKey], @"jit.row.autopair.precondMissing", @"★缺失 ⇒ precondMissing★");
    NSError *err = nil;
    ok(![p1 preparePairingWithError:&err], @"DDI 缺失 ⇒ 取配对失败");
    eqInt(p1.lastBlocker, A2JITAutoPairingBlockerDDIMissing, @"blocker = DDIMissing");
    ok([err.localizedDescription containsString:@"DDI"], @"★错误文案点名 DDI★");
    ok([err.localizedDescription containsString:@"Missing"], @"★并带上判定名与取证（不谎报）★");

    // 注入「无法确认」探测 ⇒ DDI 保持 Unknown（★不许猜成缺失或满足★）
    A2JITDDIStore *uStore = [[A2JITDDIStore alloc] initWithDirectory:TempDir()];
    [uStore importImageFromURL:WriteTempDDIFile(@"DeveloperDiskImage.dmg")
                    sourceName:@"DeveloperDiskImage.dmg"
                         error:NULL];
    A2JITLocalDDIProbe *pUnknown = [[A2JITLocalDDIProbe alloc] initWithStore:uStore
                                                                 requirement:req
                                                                 deviceQuery:devUnknown];
    A2JITAutomaticPairingProvider *p2 =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:base
                                                      engine:eng
                                                    ddiProbe:pUnknown
                                                       store:[[A2JITPairingFileStore alloc] initWithDirectory:TempDir()]
                                                       probe:nil];
    eqInt([p2.effectivePreconditions stateForPrecondition:A2JITAutoPairingPreconditionDDI],
          A2JITAutoPairingPreconditionStateUnknown, @"★探测「无法确认」⇒ DDI = Unknown★");
    eqStr([p2 blockingPreconditionReasonKey], @"jit.row.autopair.precondUnknown",
          @"★无法确认 ⇒ precondUnknown（不说成未满足）★");
    err = nil;
    ok(![p2 preparePairingWithError:&err], @"无法确认 ⇒ 不生成（不假成功）");
    eqInt(p2.lastBlocker, A2JITAutoPairingBlockerPreconditionUnconfirmed, @"blocker = PreconditionUnconfirmed");
    ok([err.localizedDescription containsString:@"无法确认"], @"★文案「无法确认」★");

    // 注入「已就位」探测 ⇒ DDI = Satisfied（前置全绿 + 引擎接入 ⇒ 可生成 ⇒ 端到端成功）
    A2JITPairingFileStore *pfStore = [[A2JITPairingFileStore alloc] initWithDirectory:TempDir()];
    FakeAutoPairingEngine *eng2 = [[FakeAutoPairingEngine alloc] init];
    eng2.engineAvailable = YES;
    eng2.succeed = YES;
    eng2.writeFileWhenSucceed = YES;
    eng2.store = pfStore;
    A2JITLocalDDIProbe *pOK = [[A2JITLocalDDIProbe alloc] initWithStore:okStore
                                                            requirement:req
                                                            deviceQuery:devUnknown];
    A2JITAutomaticPairingProvider *p3 =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:base
                                                      engine:eng2
                                                    ddiProbe:pOK
                                                       store:pfStore
                                                       probe:nil];
    eqInt([p3.effectivePreconditions stateForPrecondition:A2JITAutoPairingPreconditionDDI],
          A2JITAutoPairingPreconditionStateSatisfied, @"★探测「已就位」⇒ DDI = Satisfied★");
    ok(p3.canGeneratePairingFile, @"前置全绿 + 引擎接入 ⇒ 可生成");
    ok([p3 preparePairingWithError:NULL], @"★端到端：DDI 就位后可生成★");

    // 交叉：预置 ddi:Unsatisfied 但探测说 Present ⇒ ★以探测为准★
    A2JITAutoPairingPreconditions *preUnsatisfied = [A2JITAutoPairingPreconditions
        preconditionsWithDeveloperMode:A2JITAutoPairingPreconditionStateSatisfied
                          localNetwork:A2JITAutoPairingPreconditionStateSatisfied
                          getTaskAllow:A2JITAutoPairingPreconditionStateSatisfied
                                   ddi:A2JITAutoPairingPreconditionStateUnsatisfied];
    A2JITAutomaticPairingProvider *p4 =
        [[A2JITAutomaticPairingProvider alloc] initWithFacts:f27
                                               preconditions:preUnsatisfied
                                                      engine:eng2
                                                    ddiProbe:pOK
                                                       store:pfStore
                                                       probe:nil];
    eqInt([p4.effectivePreconditions stateForPrecondition:A2JITAutoPairingPreconditionDDI],
          A2JITAutoPairingPreconditionStateSatisfied, @"★有探测 ⇒ 以探测为准（覆盖注入值）★");
}

#pragma mark - [JIT-AUTOPAIR-2] RPPairing 握手内核（★真实现 + RFC 向量自证★）

/// 十六进制串 → 字节（测试夹具）。
static NSData *A2RPHexData(NSString *hex) {
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned v = 0;
        sscanf([[hex substringWithRange:NSMakeRange(i, 2)] UTF8String], "%2x", &v);
        uint8_t b = (uint8_t)v;
        [d appendBytes:&b length:1];
    }
    return d;
}

/// 字节 → 十六进制小写（测试夹具）。
static NSString *A2RPHexString(const uint8_t *bytes, size_t n) {
    NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; i < n; i++) {
        [s appendFormat:@"%02x", bytes[i]];
    }
    return s;
}

/// [JIT-AUTOPAIR-2]：X25519 / HKDF-SHA512 / 摘要 / UUIDv3 / 帧 / 信封 / 配对文件 / 完成度自检。
/// ★这些跑的是真实现（Natives/Support/a2_rppairing*.m 直接编译链接），并对 RFC 向量逐位核对★。
static void testRPPairingCore(void) {
    printf("\n-- [JIT-AUTOPAIR-2] RPPairing 握手内核 --\n");

    // ---- X25519（RFC 7748 §5.2 向量 1 + §6.1 基点向量）----
    uint8_t priv[32], pub[32], out[32];
    [A2RPHexData(@"a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4") getBytes:priv length:32];
    [A2RPHexData(@"e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c") getBytes:pub length:32];
    ok(A2RPX25519(out, priv, pub), @"X25519 标量乘调用成功");
    eqStr(A2RPHexString(out, 32),
          @"c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552",
          @"★X25519 与 RFC 7748 §5.2 向量 1 逐位相同★");
    uint8_t k9[32] = { 9 }, o9[32];
    ok(A2RPX25519(o9, k9, k9), @"X25519(9,9) 调用成功");
    eqStr(A2RPHexString(o9, 32),
          @"422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079",
          @"★X25519(9,9) 与 RFC 7748 §6.1 一致★");
    uint8_t pubDerived[32];
    ok(A2RPX25519PublicKey(pubDerived, priv), @"X25519 公钥派生成功");
    ok(memcmp(pubDerived, out, 32) != 0, @"公钥派生（对基点）与普通标量乘结果不同（不是恒等）");
    ok(!A2RPX25519(NULL, priv, pub), @"X25519 空指针 ⇒ 安全返回 NO（不崩）");

    // ---- HKDF-SHA512（与独立参考实现逐位核对）----
    uint8_t ikm[22]; memset(ikm, 0x0b, 22);
    uint8_t salt[13]; [A2RPHexData(@"000102030405060708090a0b0c") getBytes:salt length:13];
    uint8_t info[10]; [A2RPHexData(@"f0f1f2f3f4f5f6f7f8f9") getBytes:info length:10];
    uint8_t okm[42];
    ok(A2RPHKDF_SHA512(ikm, 22, salt, 13, info, 10, okm, 42), @"HKDF-SHA512 调用成功");
    eqStr(A2RPHexString(okm, 42),
          @"832390086cda71fb47625bb5ceb168e4c8e26a1a16ed34d9fc7fe92c1481579338da362cb8d9f925d7cb",
          @"★HKDF-SHA512 与独立参考逐位相同★");
    uint8_t tiny[8];
    ok(A2RPHKDF_SHA512(ikm, 22, NULL, 0, NULL, 0, tiny, 8), @"HKDF 省略盐/信息（按 RFC 用全零盐）可用");
    ok(!A2RPHKDF_SHA512(ikm, 22, salt, 13, info, 10, okm, 255 * 64 + 1),
       @"HKDF 超出 L 上限 ⇒ 返回 NO（不越界）");

    // ---- 摘要 ----
    uint8_t sha[64];
    ok(A2RPSHA512((const uint8_t *)"abc", 3, sha), @"SHA-512 调用成功");
    eqStr([A2RPHexString(sha, 64) substringToIndex:16], @"ddaf35a193617aba", @"SHA-512('abc') 前缀正确");
    uint8_t md5[16];
    ok(A2RPMD5((const uint8_t *)"abc", 3, md5), @"MD5 调用成功");
    eqStr(A2RPHexString(md5, 16), @"900150983cd24fb0d6963f7d28e17f72", @"MD5('abc') 正确");

    // ---- UUIDv3（RFC 4122 §4.3；identifier 的派生方式）----
    eqStr(A2RPPairingIdentifierForName(@"www.example.com"),
          @"5df41881-3aed-3515-88a7-2f4a814cf09e",
          @"★uuid_v3(NAMESPACE_DNS,'www.example.com') 与参考一致★");
    eqStr(A2RPPairingIdentifierForName(@"air2-rppairing"),
          @"a4ea0e44-3241-3f60-ba6c-17f089012e01",
          @"uuid_v3(NAMESPACE_DNS,'air2-rppairing') 与参考一致");
    ok(A2RPPairingIdentifierForName(@"") == nil, @"空名字 ⇒ 不产标识符（如实返回 nil）");

    // ---- 线上帧（magic + 2B 大端长度 + 载荷）----
    NSData *payload = [@"hello" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *frame = A2RPFrameEncode(payload);
    eqInt((NSInteger)frame.length, 9 + 2 + 5, @"帧长度 = magic(9)+长度(2)+载荷(5)");
    ok(memcmp(frame.bytes, "RPPairing", 9) == 0, @"★帧 magic = ASCII 'RPPairing'★");
    const uint8_t *fb = (const uint8_t *)frame.bytes;
    ok(fb[9] == 0 && fb[10] == 5, @"帧长度字段为大端 16 位");
    NSUInteger consumed = 0;
    NSData *decoded = nil;
    NSString *err = nil;
    ok(A2RPFramePop(frame, &consumed, &decoded, &err), @"FramePop 能切出一帧");
    eqInt((NSInteger)consumed, 16, @"FramePop 消费字节数正确");
    ok([decoded isEqualToData:payload], @"FramePop 载荷与原文一致（往返）");
    NSData *partial = [frame subdataWithRange:NSMakeRange(0, 12)];
    err = nil;
    ok(!A2RPFramePop(partial, &consumed, NULL, &err) && err.length > 0,
       @"不完整帧 ⇒ NO 且给出可读原因（不是静默失败）");
    uint8_t bad[11] = { 0 };
    memcpy(bad, "XXXXXxxxx", 9);
    err = nil;
    ok(!A2RPFramePop([NSData dataWithBytes:bad length:11], &consumed, NULL, &err) && err.length > 0,
       @"magic 不匹配 ⇒ NO 且给出原因");
    NSUInteger lenOut = 0;
    ok(A2RPFrameReadLength(frame, &lenOut) && lenOut == 5, @"FrameReadLength 读出 5");
    NSData *shortBuf = [frame subdataWithRange:NSMakeRange(0, 8)];
    ok(A2RPFrameReadLength(shortBuf, &lenOut) == NO, @"不足 11 字节 ⇒ FrameReadLength 返回 NO");
    ok(A2RPFrameEncode([NSMutableData dataWithLength:65536]) == nil, @"载荷超 65535 ⇒ 组帧返回 nil（不截断）");
    ok(A2RPFrameEncode(nil).length == 11, @"nil 载荷 ⇒ 空帧（11 字节）");

    // ---- 消息信封 ----
    NSDictionary *env = A2RPEnvelopePlain(@{ @"Hello": @"x" }, @"host", 7);
    eqStr(env[@"originatedBy"], @"host", @"信封 originatedBy 正确");
    eqInt([env[@"sequenceNumber"] integerValue], 7, @"信封 sequenceNumber 正确");
    ok([env[@"message"][@"plain"][@"_0"][@"Hello"] isEqualToString:@"x"], @"明文信封载荷嵌套正确（message.plain._0）");
    NSDictionary *envEnc = A2RPEnvelopeStreamEncrypted(@"AQID", @"device", 8);
    eqStr(envEnc[@"message"][@"streamEncrypted"][@"_0"], @"AQID", @"密文信封走 streamEncrypted._0（base64）");
    eqStr(envEnc[@"originatedBy"], @"device", @"密文信封 originatedBy 正确");
    NSString *frameErr = nil;
    ok(A2RPFrameEncodeEnvelope(env, &frameErr) != nil, @"信封可组帧");
    ok(A2RPFrameEncodeEnvelope(@{ @"bad": [NSDate date] }, &frameErr) == nil && frameErr.length > 0,
       @"非 JSON 信封 ⇒ 组帧失败并给原因");

    // ---- 配对文件（RpPairingFile）----
    NSData *pk = [NSData dataWithBytes:priv length:32];
    NSData *sk = [NSData dataWithBytes:pub length:32];
    NSString *ident = A2RPPairingIdentifierForName(@"Air2 (self)");
    NSData *pfData = A2RPPairingFileData(ident, pk, sk);
    ok(pfData.length > 0, @"配对文件可组装");
    NSDictionary *back = [NSPropertyListSerialization propertyListWithData:pfData options:0 format:NULL error:NULL];
    ok([back[@"identifier"] isEqualToString:ident], @"配对文件 identifier 往返一致");
    ok([back[@"public_key"] isEqualToData:pk] && [back[@"private_key"] isEqualToData:sk],
       @"配对文件 public_key/private_key 往返一致");
    ok(A2RPPairingFileData(@"", pk, sk) == nil, @"缺 identifier ⇒ 不产出文件（不假成功）");
    ok(A2RPPairingFileData(ident, [NSData data], sk) == nil, @"空公钥 ⇒ 不产出文件（不假成功）");

    // ---- ★与既有设施的交接★：把 ① 产出的字节喂给 A2PairingFile / A2JITPairingFileStore ----
    NSError *pfErr = nil;
    A2PairingFile *parsed = [A2PairingFile pairingFileWithData:pfData error:&pfErr];
    ok(parsed != nil && parsed.isValid, @"★产出的字节通过 A2PairingFile 校验（=真·合法配对文件）★");
    eqInt(parsed.format, A2PairingFileFormatRemotePairing, @"被识别为 RemotePairing 格式");
    eqStr(parsed.deviceIdentifier, ident, @"deviceIdentifier 取自 identifier");

    NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"a2rp_%d", (int)getpid()]];
    [[NSFileManager defaultManager] removeItemAtPath:tmpDir error:NULL];
    A2JITPairingFileStore *store = [[A2JITPairingFileStore alloc] initWithDirectory:tmpDir];
    NSError *impErr = nil;
    NSString *written = [store importData:pfData sourceName:@"a2rppairing-self" error:&impErr];
    ok(written.length > 0 && impErr == nil, @"★产出交给 A2JITPairingFileStore 落盘成功（与 ②导入 同一约定位置）★");
    ok(store.hasUsablePairingFile, @"落盘后可被真探测到（hasUsablePairingFile）");
    [[NSFileManager defaultManager] removeItemAtPath:tmpDir error:NULL];

    // ---- 完成度自检（★真跑原语 + 真跑 pair-verify 自握手，如实点名受阻步骤★）----
    A2RPPairingPreflight *pf = [A2RPPairingPreflight run];
    ok(pf.randomOK, @"自检：CSPRNG 可用");
    ok(pf.keyAgreementOK, @"自检：X25519 双向协商一致（运行期真跑，非查缓存）");
    ok(pf.signingOK, @"★自检：Ed25519 可用（运行期真跑：派生公钥+签名+验签，且坏签名被拒）★");
    ok(pf.streamCipherOK, @"★自检：ChaCha20-Poly1305 可用（运行期真跑：往返 + 坏 tag 被拒）★");
    ok(pf.pairVerifyOK, @"★自检：pair-verify 自手写【真跑通过】（M1→M4 消息流 + 双方密钥一致）★");
    ok([pf.pairVerifySummary containsString:@"M1..M4"], @"自握手结论带消息流尺寸（可核对真发生了）");
    eqInt(pf.firstBlockedStep, A2RPPairingBlockedStepRsdEndpoint,
          @"★首个受阻步骤 = 真 RSD 端点（本地链路已全绿）★");
    ok([pf.summary containsString:@"Ed25519"], @"自检摘要点名校验");
    ok([pf.summary containsString:@"pair-verify 自握手=通过"], @"★自检摘要如实写「自握手=通过」★");
    eqStr([A2RPPairingPreflight displayNameForBlockedStep:A2RPPairingBlockedStepPairSetup],
          @"PairSetup(SRP-3072)", @"受阻步骤诊断名稳定（pair-setup 仍未落地）");
    ok([A2RPPairingPreflight displayNameForBlockedStep:A2RPPairingBlockedStepRsdEndpoint].length > 0,
       @"受阻步骤诊断名稳定（RSD 端点）");
    ok(A2RPEd25519Available(), @"Ed25519 可用性 = YES（真自检通过）");
    ok(A2RPChaCha20Poly1305Available(), @"ChaCha20-Poly1305 可用性 = YES（真自检通过）");
    ok(A2RPHandshakeCryptoUnavailableReason().length > 0, @"原语状态说明可读（不空）");

    // ---- [JIT-AUTOPAIR-2] Bridge 真接线（源码级不变量；细则集中在 ⑪ 接线不变量）----
    NSString *bridgeEngine = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Bridge/A2JITAutoPairingEngineBridge.m")
                                                       encoding:NSUTF8StringEncoding
                                                          error:NULL];
    ok(bridgeEngine.length > 0, @"读得到自动配对引擎 Bridge");
    ok([bridgeEngine containsString:@"#import \"a2_rppairing.h\""], @"★Bridge 真接进了 Natives 的握手内核★");
    ok([bridgeEngine containsString:@"#import \"a2_rppairing_verify.h\""], @"★Bridge 接进了 pair-verify 握手本体★");
    ok([bridgeEngine containsString:@"#import \"a2_rppairing_rsd.h\""], @"★Bridge 接进了 RSD 发现/连接层★");
    ok([bridgeEngine containsString:@"[A2RPPairingPreflight run]"], @"★Bridge 真跑握手完成度自检（有调用点）★");
    ok([bridgeEngine containsString:@"security.mac.amfi.developer_mode_status"], @"Developer Mode 探测键明确");
    // ★不引入 iOS 私有 API 去读 entitlement★：允许「类型/原型声明」与注释，
    //   禁止任何**调用点**（iPhoneOS SDK 不导出 SecTask.h，但符号可从 Security.tbd 链接，
    //   所以 Bridge 里有一段 #if __has_include 保护的 extern 声明 —— 那是为了编过，不是调用）。
    __block BOOL secTaskCalled = NO;
    [bridgeEngine enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *t = [line stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceCharacterSet];
        BOOL isComment = [t hasPrefix:@"//"] || [t hasPrefix:@"/*"] || [t hasPrefix:@"*"];
        BOOL isDecl = [t hasPrefix:@"extern "];
        if (!isComment && !isDecl &&
            ([t containsString:@"SecTaskCreateFromSelf("] ||
             [t containsString:@"SecTaskCopyValueForEntitlement("])) {
            secTaskCalled = YES;
            *stop = YES;
        }
    }];
    ok(!secTaskCalled,
       @"★不引入 iOS 私有 API 去读 entitlement（只允许声明/注释，代码里没有任何调用点）★");
    ok([bridgeEngine containsString:@"iOS 无公开 API"], @"取不到的前置条件如实点名「无公开 API」");
    ok([bridgeEngine containsString:@"unknownPreconditions"], @"★仍以「全 Unknown」为底（没探测到 ≠ 已满足）★");
}


#pragma mark - ⑰ [JIT-AUTOPAIR-2] 真握手本体：TLV8 / 身份 / pair-verify / RSD / 向量自证

/// [JIT-AUTOPAIR-2]：本单的核心 —— pair-verify 握手本体的运行期自证 + 各层的真实现断言。
/// ★这里的每一条都跑【真实现】（Natives/Support/a2_rppairing* 直接编译链接），不是镜像★。
static void testRPPairingHandshakeBody(void) {
    printf("\n-- [JIT-AUTOPAIR-2] 真握手本体（TLV8 / 身份 / pair-verify / RSD）--\n");

    // ================= ① RFC 向量自证：Ed25519（RFC 8032 §7.1 TEST 1）=================
    uint8_t seed[32], pub[32], sig[64], msgEmpty[1] = { 0 };
    [A2RPHexData(@"9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60") getBytes:seed length:32];
    ok(A2RPEd25519PublicKey(pub, seed) == 1, @"Ed25519 公钥派生调用成功");
    eqStr(A2RPHexString(pub, 32),
          @"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
          @"★Ed25519 公钥与 RFC 8032 TEST 1 逐位相同★");
    ok(A2RPEd25519Sign(sig, seed, msgEmpty, 0) == 1, @"Ed25519 签名调用成功");
    eqStr(A2RPHexString(sig, 64),
          @"e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc"
          @"61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
          @"★Ed25519 签名与 RFC 8032 TEST 1 逐位相同★");
    ok(A2RPEd25519Verify(pub, msgEmpty, 0, sig) == 1, @"Ed25519 自验签通过");
    uint8_t badSig[64];
    memcpy(badSig, sig, 64);
    badSig[7] ^= 1;
    ok(A2RPEd25519Verify(pub, msgEmpty, 0, badSig) == 0, @"★坏签名被拒（不假通过）★");
    uint8_t bigS[64];
    memcpy(bigS, sig, 64);
    memset(bigS + 32, 0xFF, 32);
    ok(A2RPEd25519Verify(pub, msgEmpty, 0, bigS) == 0, @"★S≥L 被拒（RFC 8032 §5.1.7）★");

    // ================= ② RFC 向量自证：ChaCha20-Poly1305（RFC 8439 §2.8.2）=================
    uint8_t key[32], nonce[12], aad[12], pt[114], ct[114], tag[16], back[114];
    NSData *dKey = A2RPHexData(@"808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    NSData *dNonce = A2RPHexData(@"070000004041424344454647");
    NSData *dAad = A2RPHexData(@"50515253c0c1c2c3c4c5c6c7");
    NSData *dPt = A2RPHexData(
        @"4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a"
        @"204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f72207468"
        @"65206675747572652c2073756e73637265656e20776f756c642062652069742e");
    [dKey getBytes:key length:32];
    [dNonce getBytes:nonce length:12];
    [dAad getBytes:aad length:12];
    [dPt getBytes:pt length:114];
    ok(A2RPChaCha20Poly1305Seal(ct, tag, key, nonce, aad, 12, pt, 114) == 1, @"ChaCha20-Poly1305 加密调用成功");
    eqStr(A2RPHexString(tag, 16), @"1ae10b594f09e26a7e902ecbd0600691",
          @"★认证标签与 RFC 8439 §2.8.2 逐位相同★");
    eqStr([A2RPHexString(ct, 114) substringToIndex:32], @"d31a8d34648e60db7b86afbc53ef7ec2",
          @"★密文头 16 字节与 RFC 8439 §2.8.2 一致★");
    ok(A2RPChaCha20Poly1305Open(back, key, nonce, aad, 12, ct, 114, tag) == 1
       && memcmp(back, pt, 114) == 0, @"解密往返一致");
    uint8_t badTag[16];
    memcpy(badTag, tag, 16);
    badTag[0] ^= 1;
    ok(A2RPChaCha20Poly1305Open(back, key, nonce, aad, 12, ct, 114, badTag) == 0,
       @"★坏认证标签被拒（AEAD 不假通过）★");

    // ================= ③ TLV8 编解码（公开规格 §5）=================
    NSData *v1 = [@"air2-rppairing" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *tlv = A2RPTLVEncode(@[ @(A2RPTLVTypeState), @(A2RPTLVTypeIdentifier) ],
                                @[ [NSData dataWithBytes:"\x01" length:1], v1 ]);
    eqInt((NSInteger)tlv.length, 2 + 1 + 2 + (NSInteger)v1.length, @"TLV8 长度 = Σ(头 2 + 值)");
    NSString *tlvErr = nil;
    NSDictionary *decoded = A2RPTLVDecode(tlv, &tlvErr);
    eqInt(A2RPTLVStateValue(decoded), 1, @"TLV8 往返：State 值正确");
    ok([[decoded objectForKey:@(A2RPTLVTypeIdentifier)] isEqualToData:v1], @"TLV8 往返：Identifier 字节一致");
    ok(A2RPTLVValue(decoded, A2RPTLVTypeSignature) == nil, @"不存在的类型 ⇒ nil（不猜）");
    // ★>255 字节必须切成连续同型条目、解码时并回来★
    NSData *big = [NSMutableData dataWithLength:300];
    NSData *bigTlv = A2RPTLVEncode(@[ @(A2RPTLVTypeProof) ], @[ big ]);
    eqInt((NSInteger)bigTlv.length, 2 + 255 + 2 + 45, @"300 字节的值被切成 255+45 两个同型条目");
    NSDictionary *bigBack = A2RPTLVDecode(bigTlv, NULL);
    ok([[bigBack objectForKey:@(A2RPTLVTypeProof)] isEqualToData:big], @"★分片解码按规格并回原值★");
    // 截断必须报错而不是静默
    NSData *truncated = [tlv subdataWithRange:NSMakeRange(0, tlv.length - 1)];
    tlvErr = nil;
    ok(A2RPTLVDecode(truncated, &tlvErr) == nil && tlvErr.length > 0, @"★TLV 截断 ⇒ 报错（不静默）★");
    ok(A2RPTLVDecode([NSData data], NULL).count == 0, @"空数据 ⇒ 空字典");

    // ================= ④ 身份与配对文件（规格 §7）=================
    NSError *idErr = nil;
    A2RPPairingIdentity *ident = [A2RPPairingIdentity identityWithHostName:@"air2-test-host" error:&idErr];
    ok(ident != nil, @"随机 Ed25519 身份可生成");
    eqInt((NSInteger)ident.publicKey.length, 32, @"公钥 32 字节");
    eqInt((NSInteger)ident.privateKey.length, 32, @"私钥 32 字节");
    eqStr(ident.identifier, A2RPPairingIdentifierForName(@"air2-test-host"),
          @"identifier = uuid_v3(NAMESPACE_DNS, hostname)（规格 §7）");
    NSData *pfData2 = [ident pairingFileData];
    ok(pfData2.length > 0, @"配对文件可产出");
    A2PairingFile *parsed2 = [A2PairingFile pairingFileWithData:pfData2 error:NULL];
    ok(parsed2.isValid, @"★产出的配对文件通过 A2PairingFile 校验★");
    NSError *rtErr = nil;
    A2RPPairingIdentity *backIdent = [A2RPPairingIdentity identityWithPairingFileData:pfData2 error:&rtErr];
    ok(backIdent != nil && [backIdent.publicKey isEqualToData:ident.publicKey], @"配对文件往返：公钥一致");
    // ★一致性自证：私钥必须派生出公钥，否则拒绝★
    NSMutableDictionary *tamper = [[NSPropertyListSerialization propertyListWithData:pfData2
                                                                            options:NSPropertyListMutableContainers
                                                                             format:NULL error:NULL] mutableCopy];
    uint8_t bogus[32] = { 0 };
    tamper[@"private_key"] = [NSData dataWithBytes:bogus length:32];
    NSData *tamperedFile = [NSPropertyListSerialization dataWithPropertyList:tamper
                                                                     format:NSPropertyListXMLFormat_v1_0
                                                                    options:0 error:NULL];
    rtErr = nil;
    ok([A2RPPairingIdentity identityWithPairingFileData:tamperedFile error:&rtErr] == nil && rtErr != nil,
       @"★私钥与公钥不匹配的配对文件被拒（不静默接受）★");
    // 签名/验签（身份自己的 API）
    NSData *m = [@"payload" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *sg = [ident signMessage:m];
    ok(sg.length == 64, @"身份可签名（64 字节）");
    ok([A2RPPairingIdentity verifySignature:sg forMessage:m publicKey:ident.publicKey], @"身份签名可验");
    ok(![A2RPPairingIdentity verifySignature:sg
                                  forMessage:[@"payloaD" dataUsingEncoding:NSUTF8StringEncoding]
                                   publicKey:ident.publicKey], @"★消息改了 ⇒ 验签失败★");

    // ================= ⑤ pair-verify 自握手（★真密码学 + 真消息流★）=================
    A2RPPairVerifySelfTest *st = [A2RPPairVerifySelfTest runSelfTest];
    ok(st.ok, @"★pair-verify 自握手整体通过（M1→M4 + 双方密钥一致 + 篡改被拒）★");
    eqInt((NSInteger)st.messageSizes.count, 4, @"自握手真的走了 4 条消息");
    ok(st.secretsEqual, @"★双方 X25519 共享密钥一致（= TLS-PSK 的 PSK）★");
    ok(st.mainKeysCrossEqual, @"★双方 client/server 主密钥一致且两名互不相同★");
    ok(st.tamperRejected, @"★篡改 M2 的认证标签 ⇒ 被 AEAD 拒绝★");
    ok([st.summary containsString:@"M1..M4"], @"自握手结论可读（带消息流尺寸）");

    // ================= ⑥ pair-verify 消息机：非法输入必须拒（不半信）=================
    A2RPPairingIdentity *hID = [A2RPPairingIdentity identityWithHostName:@"neg-host" error:NULL];
    A2RPPairingIdentity *dID = [A2RPPairingIdentity identityWithHostName:@"neg-dev" error:NULL];
    A2RPPairingIdentity *otherID = [A2RPPairingIdentity identityWithHostName:@"neg-other" error:NULL];
    NSString *why = nil;
    A2RPPairVerifySession *h1 = [A2RPPairVerifySession sessionWithRole:A2RPPairVerifyRoleHost
                                                             identity:hID
                                                        peerPublicKey:dID.publicKey
                                                               reason:&why];
    A2RPPairVerifySession *d1 = [A2RPPairVerifySession sessionWithRole:A2RPPairVerifyRoleDevice
                                                             identity:dID
                                                        peerPublicKey:hID.publicKey
                                                               reason:&why];
    NSData *n1 = [h1 nextMessageWithReason:&why];
    ok(n1 != nil && [d1 acceptMessage:n1 reason:&why], @"负例准备：M1 正常");
    NSData *n2 = [d1 nextMessageWithReason:&why];
    // 用【另一个身份的对端公钥】的 Host 去处理 M2 ⇒ 设备签名校验必须失败
    A2RPPairVerifySession *hWrongPeer = [A2RPPairVerifySession sessionWithRole:A2RPPairVerifyRoleHost
                                                                     identity:hID
                                                                peerPublicKey:otherID.publicKey
                                                                       reason:&why];
    NSData *p1 = [hWrongPeer nextMessageWithReason:&why];
    ok(p1 != nil, @"负例：换了公钥的 Host 仍能发 M1（消息本身合法）");
    why = nil;
    ok(![hWrongPeer acceptMessage:n2 reason:&why] && why.length > 0,
       @"★对端身份不对 ⇒ 设备证明验签失败被拒（点名原因）★");
    // 顺序错：把 M2 直接喂给一个还没发过 M1 的 Host
    A2RPPairVerifySession *h2 = [A2RPPairVerifySession sessionWithRole:A2RPPairVerifyRoleHost
                                                              identity:hID
                                                         peerPublicKey:dID.publicKey
                                                                reason:&why];
    why = nil;
    ok(![h2 acceptMessage:n2 reason:&why] && [why containsString:@"顺序"],
       @"★消息流顺序错 ⇒ 被拒（点名「顺序」）★");
    // 非 TLV 垃圾
    why = nil;
    ok(![h2 acceptMessage:[@"not-a-tlv" dataUsingEncoding:NSUTF8StringEncoding] reason:&why] && why.length > 0,
       @"非 TLV8 字节 ⇒ 被拒");
    // 带 Error 的 TLV ⇒ 如实失败
    NSData *errTlv = A2RPTLVEncode(@[ @(A2RPTLVTypeState), @(A2RPTLVTypeError) ],
                                   @[ [NSData dataWithBytes:"\x02" length:1],
                                      [NSData dataWithBytes:"\x01" length:1] ]);
    why = nil;
    ok(![h2 acceptMessage:errTlv reason:&why] && [why containsString:@"ErrorResponse"],
       @"★对端 ErrorResponse ⇒ 如实失败（不当作成功）★");
    // 未建立时不得产出共享密钥
    ok(h2.sharedSecret == nil && !h2.established, @"未完成的会话不产出密钥、不报已建立");
    // 对端公钥长度不对 ⇒ 拒绝建会话
    A2RPPairVerifySession *nope = [A2RPPairVerifySession sessionWithRole:A2RPPairVerifyRoleHost
                                                               identity:hID
                                                          peerPublicKey:[NSMutableData dataWithLength:8]
                                                                 reason:&why];
    ok(nope == nil, @"★对端公钥长度不对 ⇒ 拒绝建会话（不猜）★");

    // ================= ⑦ RSD 层：服务类型 / 帧 / 信封 / PSK 口径 =================
    eqStr(A2RPRSDServiceRemotePairing, @"_remotepairing._tcp", @"服务类型常量（公开规格 §2c）");
    eqStr(A2RPRSDServiceRemoted, @"_remoted._tcp", @"服务类型常量（公开规格 §2b）");
    eqInt(A2RPRSDTransportForServiceType(A2RPRSDServiceRemotePairing), A2RPRSDTransportRawSocket,
          @"_remotepairing._tcp ⇒ 裸 socket 路径");
    eqInt(A2RPRSDTransportForServiceType(A2RPRSDServiceRemoted), A2RPRSDTransportRemoteXPC,
          @"_remoted._tcp ⇒ RemoteXPC 路径");
    eqInt(A2RPRSDTransportForServiceType(@"_unknown._tcp"), A2RPRSDTransportUnknown,
          @"★未知服务类型 ⇒ Unknown（不猜）★");
    eqInt((NSInteger)A2RPRSDDefaultServiceTypes().count, 2, @"默认发现顺序 = 先 2c 再 2b");

    // 帧读取器：分片到达不报错；magic 错才报错
    A2RPRSDFrameReader *reader = [[A2RPRSDFrameReader alloc] init];
    NSData *frameHello = A2RPFrameEncode([@"{\"a\":1}" dataUsingEncoding:NSUTF8StringEncoding]);
    [reader appendData:[frameHello subdataWithRange:NSMakeRange(0, 5)]];
    NSString *fErr = nil;
    ok([reader popFramePayloadWithError:&fErr] == nil && fErr == nil,
       @"★帧没收全 ⇒ 返回 nil 且【不】报错（等更多数据）★");
    [reader appendData:[frameHello subdataWithRange:NSMakeRange(5, frameHello.length - 5)]];
    NSData *payloadOut = [reader popFramePayloadWithError:&fErr];
    ok(payloadOut != nil
       && [[[NSString alloc] initWithData:payloadOut encoding:NSUTF8StringEncoding] isEqualToString:@"{\"a\":1}"],
       @"分片补齐后切出正确载荷");
    eqInt((NSInteger)reader.bufferedBytes, 0, @"切走后缓冲清空");
    [reader appendData:[NSData dataWithBytes:"XXXXXxxxx\x00\x01" length:11]];
    fErr = nil;
    ok([reader popFramePayloadWithError:&fErr] == nil && fErr.length > 0, @"★magic 不对 ⇒ 报错（不静默）★");

    // JSON 信封（§8 / §3）
    NSDictionary *hostOpts = A2RPRSDHostOptionsRequest(YES);
    eqInt([hostOpts[@"request"][@"_0"][@"handshake"][@"_0"][@"wireProtocolVersion"] integerValue], 19,
          @"★hostOptions 里 wireProtocolVersion = 19（规格 §1/§8）★");
    ok([hostOpts[@"request"][@"_0"][@"handshake"][@"_0"][@"hostOptions"][@"attemptPairVerify"] boolValue],
       @"hostOptions 带 attemptPairVerify（规格 §8 Step 1）");
    NSData *evTlv = [NSData dataWithBytes:"\x06\x01\x01" length:3];
    NSDictionary *ev = A2RPRSDPairingDataEvent(evTlv, @"verifyManualPairing", YES);
    NSString *whyEv = nil;
    NSData *evBack = A2RPRSDTLVFromPairingDataEvent(ev, &whyEv);
    ok([evBack isEqualToData:evTlv], @"★pairingData 事件往返（base64，规格 §3）★");
    ok([ev[@"event"][@"_0"][@"pairingData"][@"_0"][@"kind"] isEqualToString:@"verifyManualPairing"],
       @"事件 kind = verifyManualPairing");
    whyEv = nil;
    ok(A2RPRSDTLVFromPairingDataEvent(@{ @"event": @{ @"_0": @{ @"pairVerifyFailed": @{} } } }, &whyEv) == nil
       && [whyEv containsString:@"pairVerifyFailed"], @"★对端 pairVerifyFailed ⇒ 点名（回落 pair-setup）★");
    NSNumber *port = A2RPRSDListenerPortFromResponse(@{ @"createListener": @{ @"port": @"59100" } }, NULL);
    eqInt(port.integerValue, 59100, @"★createListener 端口按字符串解析（规格 §15）★");
    whyEv = nil;
    ok(A2RPRSDListenerPortFromResponse(@{ }, &whyEv) == nil && whyEv.length > 0,
       @"没端口 ⇒ 返回 nil + 原因（不猜 0）");
    ok([A2RPRSDCreateListenerRequest([NSData dataWithBytes:key length:32])[@"request"][@"_0"]
        [@"createListener"][@"transportProtocolType"] isEqualToString:@"tcp"], @"createListener 走 tcp（规格 §11）");

    // ★TLS-PSK 的如实口径★：公开 API 给不出设备要的套件（套件码仍是规格值）
    whyEv = nil;
    ok(A2RPRSDPublicTLSPSKPathSufficient(&whyEv) == NO, @"★TLS-PSK 公开路径如实回 NO（未打通）★");
    ok([whyEv containsString:@"0x00AF"], @"★理由点名设备要的套件 0x00AF★");
    eqInt(A2RPRSDCipherSuitePSKAES256CBCSHA384, 0x00AF, @"套件码常量（规格 §12）");
    eqInt(A2RPRSDCipherSuitePSKAES128CBCSHA, 0x008C, @"套件码常量（规格 §12）");

    // ================= ⑧ Info.plist：NSBonjourServices 与本仓服务清单一致（防漂移）=================
    NSString *plistSrc = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Info.plist")
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    ok(plistSrc.length > 0, @"读得到 Air2/Info.plist");
    ok([plistSrc containsString:@"NSBonjourServices"],
       @"★Info.plist 登记了 NSBonjourServices（否则发现阶段一无所获）★");
    for (NSString *svc in A2RPRSDDefaultServiceTypes()) {
        ok([plistSrc containsString:svc], ([NSString stringWithFormat:@"plist 登记了 %@", svc]));
    }
    ok([plistSrc containsString:A2RPRSDServicePairableHost], @"plist 登记了可配对宿主服务类型");
}

#pragma mark - [A2-INTEGRATION] TLS-PSK 隧道（可替换门面 + 默认关 + 不谎报 + 不上云）

/// 假后端：只为验证「门面把调用转给后端」这一件事（真后端 = mbedTLS，见 Natives/Support/a2_tlspsk_mbedtls.m）。
@interface A2TestTLSPskBackend : NSObject <A2TLSPskTunnelBackend>
@property (nonatomic, copy) NSString *name;
@end

@implementation A2TestTLSPskBackend
- (NSString *)backendName { return self.name ?: @"测试后端"; }
- (BOOL)isAvailableWithReason:(NSString **)reason { if (reason) { *reason = @""; } return YES; }
- (BOOL)connectToHost:(NSString *)host port:(uint16_t)port psk:(NSData *)psk identity:(NSString *)identity
              timeout:(NSTimeInterval)timeout reason:(NSString **)reason {
    if (reason) { *reason = @"测试后端已连"; }
    return YES;
}
- (BOOL)sendFrame:(NSData *)frame timeout:(NSTimeInterval)timeout reason:(NSString **)reason { return YES; }
- (NSData *)receiveFrameWithTimeout:(NSTimeInterval)timeout reason:(NSString **)reason {
    return [@"pong" dataUsingEncoding:NSUTF8StringEncoding];
}
- (void)close {}
@end

static void testIntegrationTLSPSK(void) {
    // ① 门面默认关（★用户拍板「默认关」★）
    A2TLSPskTunnel *t = [A2TLSPskTunnel sharedTunnel];
    ok(t != nil, @"TLS-PSK 门面可取得");
    ok(t.isEnabled == NO, @"★TLS-PSK 隧道默认关（enabled 默认 NO）★");

    // ② 未注册后端 ⇒ 如实报缺（★不谎报★）
    NSString *why = nil;
    ok([A2TLSPskTunnel isAvailableWithReason:&why] == NO, @"★无后端时可用性如实回 NO★");
    ok(why.length > 0 && [why containsString:@"未注册"], @"理由点名「未注册后端」");
    eqStr([A2TLSPskTunnel backendName], @"未注册", @"无后端时后端名如实为「未注册」");
    ok([[A2TLSPskTunnel statusLine] containsString:@"默认关"], @"状态行如实标注「默认关」");

    // ③ 开关未开 ⇒ 一律拒绝（且点名）
    NSString *r1 = nil;
    ok([t connectToHost:@"127.0.0.1" port:1234 psk:[NSData dataWithBytes:"x" length:1] identity:@""
                timeout:1.0 reason:&r1] == NO, @"★开关未开 ⇒ connect 一律拒绝★");
    ok(r1.length > 0 && [r1 containsString:@"默认关"], @"拒绝理由点名「默认关」");

    // ④ ★可替换★：换后端只走 registerBackend:（这里用假后端验证结构；真后端是 mbedTLS）
    A2TestTLSPskBackend *stub = [[A2TestTLSPskBackend alloc] init];
    stub.name = @"A2Test-mbedTLS-shaped";
    [A2TLSPskTunnel registerBackend:stub];
    eqStr([A2TLSPskTunnel backendName], @"A2Test-mbedTLS-shaped", @"★后端可替换（registerBackend: 生效）★");
    ok([A2TLSPskTunnel isAvailableWithReason:NULL] == YES, @"注册后端后可用性为 YES");

    // ⑤ ★不上云★：默认主机准入策略
    ok(A2TLSPskDefaultHostPolicy(@"127.0.0.1") == YES, @"策略放行 127.0.0.1");
    ok(A2TLSPskDefaultHostPolicy(@"localhost") == YES, @"策略放行 localhost");
    ok(A2TLSPskDefaultHostPolicy(@"192.168.3.172") == YES, @"策略放行 192.168.x");
    ok(A2TLSPskDefaultHostPolicy(@"10.1.2.3") == YES, @"策略放行 10.x");
    ok(A2TLSPskDefaultHostPolicy(@"172.20.0.1") == YES, @"策略放行 172.16-31.x");
    ok(A2TLSPskDefaultHostPolicy(@"172.40.0.1") == NO, @"策略拒绝 172.40.x（非私有段）");
    ok(A2TLSPskDefaultHostPolicy(@"iPhone-de.local") == YES, @"策略放行 .local（Bonjour）");
    ok(A2TLSPskDefaultHostPolicy(@"fe80::1") == YES, @"策略放行 fe80::（链路本地）");
    ok(A2TLSPskDefaultHostPolicy(@"github.com") == NO, @"★策略拒绝公网域名（不上云）★");
    ok(A2TLSPskDefaultHostPolicy(@"8.8.8.8") == NO, @"★策略拒绝公网 IP（不上云）★");

    // ⑥ 开关默认关的再确认：即便后端就绪，未 enabled 仍拒绝
    NSString *r2 = nil;
    ok([t connectToHost:@"10.0.0.5" port:443 psk:[NSData dataWithBytes:"x" length:1] identity:@""
                timeout:1.0 reason:&r2] == NO, @"未 enabled 时即便后端就绪也拒绝");

    // ⑦ enabled 后：不上云拦截 + PSK 空拦截 + 正常转发
    t.enabled = YES;
    NSString *r3 = nil;
    ok([t connectToHost:@"github.com" port:443 psk:[NSData dataWithBytes:"x" length:1] identity:@""
                timeout:1.0 reason:&r3] == NO, @"★enabled 后公网地址仍被拒（不上云）★");
    ok(r3.length > 0 && [r3 containsString:@"不上云"], @"拒绝理由点名「不上云」");

    NSString *r4 = nil;
    ok([t connectToHost:@"127.0.0.1" port:1 psk:[NSData data] identity:@""
                timeout:1.0 reason:&r4] == NO, @"PSK 为空 ⇒ 拒绝");
    ok(r4.length > 0 && [r4 containsString:@"PSK"], @"空 PSK 理由点名 PSK");

    NSString *r5 = nil;
    ok([t connectToHost:@"127.0.0.1" port:1 psk:[NSData dataWithBytes:"x" length:1] identity:@""
                timeout:1.0 reason:&r5] == YES, @"本地地址 + 有 PSK ⇒ 转发给后端并成功");
    eqInt((NSInteger)t.state, (NSInteger)A2TLSPskTunnelStateReady, @"成功后状态 = Ready");
    NSData *pong = [t receiveFrameWithTimeout:1.0 reason:NULL];
    ok(pong != nil && [[[NSString alloc] initWithData:pong encoding:NSUTF8StringEncoding] isEqualToString:@"pong"],
       @"收帧被转发到后端");
    [t close];
    eqInt((NSInteger)t.state, (NSInteger)A2TLSPskTunnelStateClosed, @"close 后状态 = Closed");
    t.enabled = NO;   // ★还原默认关★（不给后续/他人留「已开」假象）

    // ⑧ 源码级自证：生产接线 + 第三方链接 + Java 最后一跳
    NSString *bridgeSrc = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Bridge/A2JITAutoPairingEngineBridge.m")
                                                    encoding:NSUTF8StringEncoding error:NULL];
    ok([bridgeSrc containsString:@"A2TLSPskMbedTLSEnsureRegistered"], @"★Bridge 真注册 mbedTLS 后端（生产调用点）★");
    ok([bridgeSrc containsString:@"A2TLSPskTunnel statusLine"], @"Bridge 记 TLS-PSK 隧道如实状态行");

    NSString *genSrc = [NSString stringWithContentsOfFile:RepoPath(@"scripts/gen_xcodeproj.py")
                                                 encoding:NSUTF8StringEncoding error:NULL];
    ok([genSrc containsString:@"MBEDTLS_LDFLAGS"], @"★gen 脚本登记 mbedTLS 链接参数★");
    ok([genSrc containsString:@"-lmbedtls"] && [genSrc containsString:@"-lmbedcrypto"], @"链接 mbedtls/mbedcrypto 静态库");

    NSString *javaSrc = [NSString stringWithContentsOfFile:RepoPath(@"JavaApp/src/ownglfw/org/lwjgl/glfw/GLFW.java")
                                                  encoding:NSUTF8StringEncoding error:NULL];
    ok([javaSrc containsString:@"a2OwnGlfwDispatch"], @"★Java 最后一跳 a2OwnGlfwDispatch 已落★");
    // 签名断言语义不变，只是不再依赖 Java 源码的换行位置（原来那条子串跨了两行 ⇒ 假红）
    ok([javaSrc containsString:@"a2OwnGlfwDispatch(long window, int type"]
       && [javaSrc containsString:@"int i0, int i1,"]
       && [javaSrc containsString:@"int i2, int i3,"]
       && [javaSrc containsString:@"double d0, double d1)"],
       @"签名与 native 侧契约一致（long,int,int,int,int,int,double,double）");

    // ⑨ 随仓第三方件自证（缺一即失败；★这是「真编进来了」的静态证据★）
    NSString *mbDir = RepoPath(@"Libraries/ThirdParty/mbedtls");
    for (NSString *f in @[@"lib/libmbedtls.a", @"lib/libmbedx509.a", @"lib/libmbedcrypto.a",
                          @"include/mbedtls/ssl.h", @"LICENSE", @"NOTICE.md"]) {
        NSString *full = [mbDir stringByAppendingPathComponent:f];
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
        ok(at != nil && [at[NSFileSize] longLongValue] > 0,
           [NSString stringWithFormat:@"随仓第三方件存在且非空：%@", f]);
    }
}

#pragma mark - ⑱ [JIT↔VM] 启动链串联（①脚本 → ②JIT → ③建 VM）

/// 本单核心：**顺序 / 短路 / 单一真相源 / 接线点** 四件。
/// 造「JIT 不可用」与「建 VM 失败」两种失败，断言 ③ 不该跑时【真的没跑】。
static void testLaunchChainJitVmWiring(void) {
    printf("\n=== ⑱ [JIT↔VM] 串联：①脚本→②JIT→③建VM（顺序 / 短路 / 单一真相源）===\n");

    // ① 顺序：三步按 ①脚本 → ②JIT → ③VM 跑；成功后 stage = Done
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    A2LaunchChain *c1 = [A2LaunchChain chainWithDeliverScript:^BOOL(NSError **e) {
                [order addObject:@"script"]; return YES; }
                                                      verify:^BOOL(NSString **r) {
                [order addObject:@"verify"]; return YES; }
                                                   createJVM:^BOOL(NSError **e) {
                [order addObject:@"vm"]; return YES; }];
    ok([c1 runWithError:NULL], @"三步全成功 ⇒ run 返回 YES");
    ok([order isEqualToArray:@[@"script", @"verify", @"vm"]], @"★顺序严格 ①脚本 → ②JIT → ③VM★");
    eqInt((NSInteger)c1.stage, (NSInteger)A2LaunchChainStageDone, @"成功后 stage = Done");

    // ② ★JIT 不可用 ⇒ 拦路：③ 建 VM 完全未运行★（本单最核心的不变量）
    __block BOOL ranVerify2 = NO, ranVM2 = NO;
    A2LaunchChain *c2 = [A2LaunchChain chainWithDeliverScript:^BOOL(NSError **e) { return NO; }  // ① 故意失败
                                                      verify:^BOOL(NSString **r) {
                ranVerify2 = YES; if (r) *r = @"brk #0x69 无人服务"; return NO; }
                                                   createJVM:^BOOL(NSError **e) {
                ranVM2 = YES; return YES; }];
    NSError *err2 = nil;
    ok(![c2 runWithError:&err2], @"② 探测失败 ⇒ run 返回 NO");
    ok(ranVerify2, @"① 失败【不拦路】：仍进入 ②");
    ok(!ranVM2, @"★② 失败 ⇒ ③ 建 VM 完全未运行（绝不带病建 VM）★");
    eqInt((NSInteger)c2.stage, (NSInteger)A2LaunchChainStageVerify, @"停在 ②（stage = 唯一真相源）");
    ok(c2.failureReason.length > 0, @"② 失败有可读 failureReason");
    ok(err2 != nil, @"② 失败回填 NSError");

    // ③ ③ 建 VM 失败 ⇒ stage = CreateVM（失败定位读同一处）
    A2LaunchChain *c3 = [A2LaunchChain chainWithDeliverScript:^BOOL(NSError **e) { return YES; }
                                                      verify:^BOOL(NSString **r) { return YES; }
                                                   createJVM:^BOOL(NSError **e) {
                if (e) *e = [NSError errorWithDomain:@"t" code:-4
                                            userInfo:@{NSLocalizedDescriptionKey: @"JNI_CreateJavaVM 失败"}];
                return NO; }];
    ok(![c3 runWithError:NULL], @"③ 失败 ⇒ run 返回 NO");
    eqInt((NSInteger)c3.stage, (NSInteger)A2LaunchChainStageCreateVM, @"停在 ③（stage = CreateVM）");

    // ④ 失败分类：与「停在哪一步」一一对应（★单一实现，不在各调用点各写一套★）
    eqInt((NSInteger)[A2LaunchFailure classForChainStage:A2LaunchChainStageVerify],
          (NSInteger)A2LaunchFailureClassJITBlocked, @"② 停 ⇒ 类 = JITBlocked");
    eqInt((NSInteger)[A2LaunchFailure classForChainStage:A2LaunchChainStageCreateVM],
          (NSInteger)A2LaunchFailureClassVMFailed, @"③ 停 ⇒ 类 = VMFailed");
    eqInt((NSInteger)[A2LaunchFailure classForChainStage:A2LaunchChainStageDone],
          (NSInteger)A2LaunchFailureClassNone, @"Done ⇒ 类 = None");

    // ⑤ ② 的分流：7 档 verdict 各有专属【原因/动作】文案（不退化成一个万能句）
    NSMutableSet<NSString *> *reasons = [NSMutableSet set];
    NSMutableSet<NSString *> *actions = [NSMutableSet set];
    for (NSInteger v = A2JITReadinessVerdictUnknown; v <= A2JITReadinessVerdictNotExecutable; v++) {
        NSString *line = [A2LaunchFailure diagnosticForJITVerdict:(A2JITReadinessVerdict)v evidence:@"ev"];
        NSString *msg  = [A2LaunchFailure userMessageForJITVerdict:(A2JITReadinessVerdict)v];
        ok([line containsString:@"[A2-CHAIN] ② JIT 不可用"],
           [NSString stringWithFormat:@"verdict %ld 有判据行", (long)v]);
        NSString *reason = [A2JITStrings stringForKey:[A2JITVerdictGuidance reasonKeyForVerdict:(A2JITReadinessVerdict)v]];
        ok([msg containsString:reason], [NSString stringWithFormat:@"verdict %ld 文案含该档专属原因", (long)v]);
        [reasons addObject:reason];
        [actions addObject:[A2JITStrings stringForKey:[A2JITVerdictGuidance actionKeyForVerdict:(A2JITReadinessVerdict)v]]];
    }
    eqInt((NSInteger)reasons.count, 7, @"★7 档原因文案互不相同★");
    eqInt((NSInteger)actions.count, 7, @"★7 档动作文案互不相同（告知怎么开）★");

    // ⑥ ③ 的返回码释义（照 a2_launch.h 契约；每档非空，-4 点名 JNI_CreateJavaVM）
    for (NSNumber *rc in @[@(-1), @(-2), @(-3), @(-4), @(-5), @(-8), @(-9)]) {
        ok([A2LaunchFailure userMessageForVMFailureCode:rc.integerValue].length > 0,
           [NSString stringWithFormat:@"rc=%@ 有可读文案", rc]);
    }
    ok([[A2LaunchFailure userMessageForVMFailureCode:-4] containsString:@"JNI_CreateJavaVM"],
       @"rc=-4 点名 JNI_CreateJavaVM");

    // ⑦ ★单一真相源★ 源码级回归：启动路径不得用局部变量记 JIT 状态
    NSString *sessionSrc = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Player/A2LaunchSession.m")
                                                     encoding:NSUTF8StringEncoding error:NULL];
    ok(sessionSrc.length > 0, @"读得到 A2LaunchSession.m");
    ok(![sessionSrc containsString:@"jitExtEarlyOk"], @"★无历史误判形态（局部 BOOL 记 JIT 状态）★");
    ok([sessionSrc containsString:@"A2LaunchChain"], @"启动路径经 A2LaunchChain 编排");
    ok([sessionSrc containsString:@"runWithError:"], @"真跑链（不是只构造）");
    ok([sessionSrc containsString:@"chain.stage"], @"失败定位读 chain.stage（单一真相源）");
    ok([sessionSrc containsString:@"[A2-CHAIN] 开关=关"], @"开关【关】有判据行");
    ok([sessionSrc containsString:@"[A2-CHAIN] 开关=开"], @"开关【开】有判据行");
    ok(![sessionSrc containsString:@"a2_jit_send_script_safe"], @"★Player 不直接调 Natives 下发原语（单向分层）★");
    ok([sessionSrc containsString:@"A2JITScriptDelivery"], @"① 经 Bridge 的 A2JITScriptDelivery");
    ok([sessionSrc containsString:@"A2JITEnvironmentProbe"], @"② 经 Bridge 的 A2JITEnvironmentProbe");

    NSString *deliverSrc = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Bridge/A2JITScriptDelivery.m")
                                                     encoding:NSUTF8StringEncoding error:NULL];
    ok(deliverSrc.length > 0, @"读得到 A2JITScriptDelivery.m");
    ok([deliverSrc containsString:@"a2_jit_send_script_safe"], @"★① 真调 Natives 下发原语★");
    ok([deliverSrc containsString:@"AmethystJIT69"], @"① 下发的是随包自包含脚本");

}

#pragma mark - ⑲ [JIT-AUTOPAIR-3] pair-setup（SRP-3072 消息机 PS-Msg01..06）

/// 大写十六进制（本文件的 A2RPHexString 是小写；⑲ 的向量来自 RFC/独立参考，用大写便于对拍）。
static NSString *A2RPTestHexUpper(const uint8_t *b, size_t n) {
    return [A2RPHexString(b, n) uppercaseString];
}

/// 单字节 NSData（TLV 值用）。
static NSData *A2RPTestOneByte(uint8_t b) {
    return [NSData dataWithBytes:&b length:1];
}
/// 16 个 0 字节（构造非法 B/A 用）。
static const uint8_t *A2RPTestZeroBytes(void) {
    static const uint8_t z[16] = { 0 };
    return z;
}

/// RFC 5054 §Appendix A 的 1024-bit 群（供公开测试向量核对；★逐字符照抄 RFC★）。
static const char *const kA2TestPSPrime1024 =
    "EEAF0AB9ADB38DD69C33F80AFA8FC5E86072618775FF3C0B9EA2314C9C256576D674DF7496EA81D3"
    "383B4813D692C6E0E0D5D8E250B98BE48E495C1D6089DAD15DC7D7B46154D6B6CE8EF4AD69B15D49"
    "82559B297BCF1885C529F566660E57EC68EDBC3C05726CC02FD4CBF4976EAA9AFD5138FE8376435B"
    "9FC61D2FC0EB06E3";

/// RFC 5054 §Appendix A 的 3072-bit 群（★逐字符照抄 RFC；用来核对本仓常量未被改坏★）。
static const char *const kA2TestPSPrime3072 =
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22"
    "514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6"
    "F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3D"
    "C2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB"
    "9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B"
    "2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA05101572"
    "8E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F"
    "85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D876027"
    "33EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFC"
    "E0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF";

/// SHA-1 摘要（★只用于核对 RFC 5054 §Appendix B 的公开向量 —— 生产 SRP 用 SHA-512★）。
static int A2TestPSSHA1(const uint8_t *in, size_t inLen, uint8_t *out) {
    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);
    if (inLen > 0 && in != NULL) { CC_SHA1_Update(&ctx, in, (CC_LONG)inLen); }
    CC_SHA1_Final(out, &ctx);
    return 1;
}

static A2RPSRPGroup A2TestPSGroup1024(void) {
    A2RPSRPGroup g = { kA2TestPSPrime1024, 2, 128 };
    return g;
}

/// 把 3072 群 N 的十六进制转成 384 字节（构造非法 B=N 用）。
static NSData *A2TestPSPrime3072Data(void) {
    NSMutableData *d = [NSMutableData dataWithCapacity:384];
    for (size_t i = 0; i < 384; i++) {
        char pair[3] = { kA2TestPSPrime3072[2 * i], kA2TestPSPrime3072[2 * i + 1], 0 };
        unsigned v = 0;
        sscanf(pair, "%2x", &v);
        uint8_t byte = (uint8_t)v;
        [d appendBytes:&byte length:1];
    }
    return d;
}

/// 建一对 Host/Device 会话（配对码 123456）。失败即两者为 nil。
static void A2TestPSMakePair(A2RPPairingIdentity *hid, A2RPPairingIdentity *did,
                             A2RPPairSetupSession **outH, A2RPPairSetupSession **outD) {
    NSString *w = nil;
    A2RPPairSetupPinProvider pin123 = ^NSString *(A2RPPairSetupPinPrompt p) { (void)p; return @"123456"; };
    *outH = [A2RPPairSetupSession hostSessionWithIdentity:hid pinProvider:pin123 reason:&w];
    *outD = [A2RPPairSetupSession deviceSessionWithIdentity:did pin:@"123456" reason:&w];
}

/// 推进到 Host 该发 Msg03（= 已交换 Msg01/Msg02）。失败 ⇒ nil。
static NSData *A2TestPSAdvanceToMsg03(A2RPPairSetupSession *h, A2RPPairSetupSession *d, NSString **why) {
    NSData *m1 = [h nextMessageWithReason:why];
    if (m1 == nil || ![d acceptMessage:m1 reason:why]) { return nil; }
    NSData *m2 = [d nextMessageWithReason:why];
    if (m2 == nil || ![h acceptMessage:m2 reason:why]) { return nil; }
    return [h nextMessageWithReason:why];
}

/// 进程内「设备」传输：把 TLV 喂给一个 device 会话并取回下一条。
@interface A2TestPSDeviceTransport : NSObject <A2RPPairSetupMessageTransport>
@property (nonatomic, strong) A2RPPairSetupSession *device;
@property (nonatomic) NSInteger exchanges;
@property (nonatomic) BOOL observedAwaitingConsent;
@end

@implementation A2TestPSDeviceTransport
- (NSData *)exchangePairingData:(NSData *)tlv kind:(NSString *)kind
                       startNew:(BOOL)startNewSession reason:(NSString **)reason {
    (void)kind; (void)startNewSession;
    self.exchanges++;
    if (![self.device acceptMessage:tlv reason:reason]) { return nil; }
    return [self.device nextMessageWithReason:reason];
}
- (BOOL)transportObservedAwaitingUserConsent { return self.observedAwaitingConsent; }
@end

#pragma mark ⑲a SRP 数学：公开向量逐位核对 + 负例

static void testPairSetupSRPMath(void) {
    printf("\n-- [JIT-AUTOPAIR-3] SRP 数学（RFC 5054 公开向量 + 3072/SHA-512 交叉向量）--\n");
    NSString *why = nil;

    // ===== ① RFC 5054 §Appendix B：1024-bit / SHA-1 完整向量（来源：RFC 5054 Appendix B）=====
    uint8_t salt[16] = { 0 };
    uint8_t a[32] = { 0 };
    uint8_t b[32] = { 0 };
    [A2RPHexData(@"BEB25379D1A8581EB5A727673A2441EE") getBytes:salt length:16];
    [A2RPHexData(@"60975527035CF2AD1989806F0407210BC81EDC04E2762A56AFD529DDDA2D4393") getBytes:a length:32];
    [A2RPHexData(@"E487CB59D31AC550471E81F00F6928E01DDA08E974A004F49E61F5D105284D20") getBytes:b length:32];
    A2RPSRPGroup g1024 = A2TestPSGroup1024();
    A2RPSRPClient *c1 = A2RPSRPClientCreate(&g1024, A2TestPSSHA1, 20,
                                            (const uint8_t *)"alice", 5,
                                            (const uint8_t *)"password123", 11, a, 32, &why);
    A2RPSRPServer *s1 = A2RPSRPServerCreate(&g1024, A2TestPSSHA1, 20,
                                            (const uint8_t *)"alice", 5,
                                            (const uint8_t *)"password123", 11, salt, 16, b, 32, &why);
    ok(c1 != NULL && s1 != NULL, @"RFC5054 向量：可建 SRP 客户端/服务端（SHA-1/1024）");
    if (c1 && s1) {
        size_t bn = 0;
        const uint8_t *B1 = A2RPSRPServerPublicB(s1, &bn);
        ok(A2RPSRPClientComputeKey(c1, salt, 16, B1, bn, &why), @"RFC5054 向量：客户端算密钥成功");
        A2RPSRPTrace t1; memset(&t1, 0, sizeof(t1));
        A2RPSRPClientTrace(c1, &t1);
        size_t vn = 0;
        const uint8_t *v1 = A2RPSRPServerVerifier(s1, &vn);
        // ★以下 7 条与 RFC 5054 §Appendix B 逐位相同★
        eqStr(A2RPTestHexUpper(t1.k, t1.kLen),
              @"7556AA045AEF2CDD07ABAF0F665C3E818913186F", @"★RFC5054 k 逐位相同★");
        eqStr(A2RPTestHexUpper(t1.x, t1.xLen),
              @"94B7555AABE9127CC58CCF4993DB6CF84D16C124", @"★RFC5054 x 逐位相同★");
        eqStr(A2RPTestHexUpper(v1, vn),
              @"7E273DE8696FFC4F4E337D05B4B375BEB0DDE1569E8FA00A9886D8129BADA1F1822223CA1A605B530E379BA4729FDC59F105B4787E5186F5C671085A1447B52A48CF1970B4FB6F8400BBF4CEBFBB168152E08AB5EA53D15C1AFF87B2B9DA6E04E058AD51CC72BFC9033B564E26480D78E955A5E29E7AB245DB2BE315E2099AFB",
              @"★RFC5054 v 逐位相同★");
        size_t an = 0;
        const uint8_t *A1 = A2RPSRPClientPublicA(c1, &an);
        eqStr(A2RPTestHexUpper(A1, an),
              @"61D5E490F6F1B79547B0704C436F523DD0E560F0C64115BB72557EC44352E8903211C04692272D8B2D1A5358A2CF1B6E0BFCF99F921530EC8E39356179EAE45E42BA92AEACED825171E1E8B9AF6D9C03E1327F44BE087EF06530E69F66615261EEF54073CA11CF5858F0EDFDFE15EFEAB349EF5D76988A3672FAC47B0769447B",
              @"★RFC5054 A 逐位相同★");
        eqStr(A2RPTestHexUpper(B1, bn),
              @"BD0C61512C692C0CB6D041FA01BB152D4916A1E77AF46AE105393011BAF38964DC46A0670DD125B95A981652236F99D9B681CBF87837EC996C6DA04453728610D0C6DDB58B318885D7D82C7F8DEB75CE7BD4FBAA37089E6F9C6059F388838E7A00030B331EB76840910440B1B27AAEAEEB4012B7D7665238A8E3FB004B117B58",
              @"★RFC5054 B 逐位相同★");
        eqStr(A2RPTestHexUpper(t1.u, t1.uLen),
              @"CE38B9593487DA98554ED47D70A7AE5F462EF019", @"★RFC5054 u 逐位相同★");
        eqStr(A2RPTestHexUpper(t1.S, t1.sLen),
              @"B0DC82BABCF30674AE450C0287745E7990A3381F63B387AAF271A10D233861E359B48220F7C4693C9AE12B0A6F67809F0876E2D013800D6C41BB59B6D5979B5C00A172B4A2A5903A0BDCAF8A709585EB2AFAFA8F3499B200210DCC1F10EB33943CD67FC88A2F39A4BE5BEC4EC0A3212DC346D7E474B29EDE8A469FFECA686E5A",
              @"★RFC5054 S(premaster) 逐位相同★");
        ok(A2RPSRPServerComputeKey(s1, A1, an, &why) && A2RPSRPServerVerifyM1(s1, t1.M1, t1.m1Len),
           @"RFC5054 向量：服务端校验客户端 M1 通过（同一份实现自洽）");
    }
    A2RPSRPClientFree(c1);
    A2RPSRPServerFree(s1);

    // ===== ② 3072-bit 群常量（RFC 5054 §Appendix A）=====
    const A2RPSRPGroup *g3072 = A2RPSRPGroup3072();
    ok(g3072 != NULL && g3072->primeHex != NULL, @"3072 群可取");
    eqInt((NSInteger)strlen(g3072->primeHex), 768, @"N 的十六进制长度 = 768（384 字节 / 3072 位）");
    ok(strcmp(g3072->primeHex, kA2TestPSPrime3072) == 0, @"★N 与 RFC 5054 §App.A 3072-bit 值逐字符相同★");
    eqInt((NSInteger)g3072->generator, 5, @"★生成元 g = 5（RFC 5054 §App.A 3072-bit 群）★");
    eqInt((NSInteger)g3072->primeBytes, 384, @"primeBytes = 384");
    eqInt((NSInteger)A2RPSRPSHA512DigestLength(), 64, @"生产摘要 = SHA-512（64 字节）");

    // ===== ③ 3072/SHA-512 交叉向量：固定 (salt, a, b, I, P)，对本仓实现逐位核对 =====
    //  向量来源：与本仓无关的独立 Python(stdlib hashlib+pow) 参考实现；该参考自身已对上 RFC 5054 §App.B。
    uint8_t salt2[16] = { 0 };
    [A2RPHexData(@"00112233445566778899AABBCCDDEEFF") getBytes:salt2 length:16];
    uint8_t a2[32] = { 0 }, b2[32] = { 0 };
    memset(a2 + 3, 0x11, 29);
    memset(b2 + 3, 0x22, 29);
    A2RPSRPClient *c2 = A2RPSRPClientCreate(g3072, A2RPSRPHashSHA512(), 64,
                                            (const uint8_t *)"Pair-Setup", 10,
                                            (const uint8_t *)"123456", 6, a2, 32, &why);
    A2RPSRPServer *s2 = A2RPSRPServerCreate(g3072, A2RPSRPHashSHA512(), 64,
                                            (const uint8_t *)"Pair-Setup", 10,
                                            (const uint8_t *)"123456", 6, salt2, 16, b2, 32, &why);
    ok(c2 != NULL && s2 != NULL, @"3072/SHA-512：可建 SRP 客户端/服务端");
    if (c2 && s2) {
        size_t bn = 0;
        const uint8_t *B2 = A2RPSRPServerPublicB(s2, &bn);
        ok(A2RPSRPClientComputeKey(c2, salt2, 16, B2, bn, &why), @"3072/SHA-512：客户端算密钥成功");
        A2RPSRPTrace t2; memset(&t2, 0, sizeof(t2));
        A2RPSRPClientTrace(c2, &t2);
        size_t an = 0;
        const uint8_t *A2p = A2RPSRPClientPublicA(c2, &an);
        eqStr(A2RPTestHexUpper(t2.k, t2.kLen),
              @"A9C2E2559BF0EBB53F0CBBF62282906BEDE7F2182F00678211FBD5BDE5B285033A4993503B87397F9BE5EC02080FEDBC0835587AD039060879B8621E8C3659E0",
              @"3072 k 与独立参考逐位相同");
        eqStr(A2RPTestHexUpper(t2.x, t2.xLen),
              @"7EE207B859273D34D83F7EF1A9E5FED45848C7CCD9D99E2768D7CE096C05018AC8B97FFC2B32B953E75F37F013E2C3B726B2440ADB52FBAC6168EA89DEA25F6E",
              @"3072 x 与独立参考逐位相同");
        eqStr(A2RPTestHexUpper(t2.u, t2.uLen),
              @"9EB3569F09F8B04F80F71B9E312A8B62A2D532BE14F246D2F1124DF88435E84FDBEA05A706E0FDFD38D11AB0B7581CA1F6C8E95D0360E28D77322671C1C15DD7",
              @"3072 u 与独立参考逐位相同");
        eqStr(A2RPTestHexUpper(A2p, an),
              @"4B8E8F271694B4805DB6AD0EDD32FC7DFF5B886F1EE6FD6C016DA4185C005FE70BD0D875924B460982D859B348B78987156165EC72D7B9F4DD225DB118FAC05CA6F34D696EEE02445AE3A1EFA123CB3946B5D24D7D3299935B4C9AAB0CED433A9C398ED4F53C603253F37FBB34E23E2CA3CFAD674F7D3998AC4A4447D455A5BA918B37BD088D27C3028E512563549572435F7F5E29B7F51A40158E51C66CBFE324ACE0DF171435E21B0EE8228704BA50047DFFB6FEC4ADB73C97A8EDC147AC1DA28990E5924A6E3EABBD12734AB481258A25FFC0E8DE107C05F5140C4C71574B502A3EE6FF58BECB98393658299E3F17902BD7DB92FA782787E5798262330820AA98538916E46E24603774EB8E2A0A3F5FA573F3E197AC081641DC0BCF68307C929B74215C7491B63E32F845AFF7CD3D3440379A929092D3534A4ED93ADD3D490ABED63FB3394BC2B06F39505354BE30B1B27BE39DD8A968C6B9D1E9C201987042D43426FD1801A2C02CD3D6BCB362A0CC2A78718355DFE9DD766BF130C6EE5C",
              @"3072 A 与独立参考逐位相同");
        eqStr(A2RPTestHexUpper(B2, bn),
              @"5DA1C76D4FB7F0C663624DDF867B1A9476CE8C26837BF852E8C6E79F963ECF39F8C3E956A8EC2EA4961AF7F900566D72E837D489006D25D389F4088BB50E93235D04E427549C89CF8688A07A380E40733D27C9FA51EF7AF400448B24DBD9C8C23CB688C296D813C27576210AE0E418B80D87B0A1B5A86824C095B528B9E726199DA38E4815014F59D46447CBAFCC468821D09D4D5BD492808659ABD398DA70ABBEE3657B4FC28E948B46700E1F4AF6A0F0A616D6DAE5D4E7E8D3EC458F97616FC9BC60778E74FE5EACBC22CEFC572CC8B508FDC80F59ABB1654E18CAA29D8F3EC0CC173BDA15A5E7645CBDB83E2C3FF71DD71ECE7C22562F7D3A51E864153DACD3D98C6C5AB642004DF46D5DB6F50B751AB87C8A06259E6F9B8DFB2DE5D0233FCC5B56F169A07F55BF9647F76D6DCCBE434E80A4374F37D87E1FBBEB4F074703AFD603BE6F5F9D93536D2411002760BECCB0AAAD701A86493B976953FB6A01970F9501B7A543562C4BF43A47E1079D6C42B038FAAE39DED1A3CFE482FB8BD6FE",
              @"3072 B 与独立参考逐位相同");
        eqStr(A2RPTestHexUpper(t2.S, t2.sLen),
              @"66D918CFFA25BECE138DB06CBFF5F795DB86AF3054AC96BD92A942C7A81614EB0908520C3AA00C02F12889E85BFDBAAC7CC8C05C3871C1031D2CC219BEC5CB717FD9ABB9D04AA5A7ECC4AD2D04727B410C25BCA2D11ACC4583A73030DC417C996CAA399824B8E7A685AB5C2B63B52FC9FE030982CDEAA3E5A45542559D75085E11D85C0854CC3E3F1E10931D24433CF2C84D85832401AA24EB727CE2E1243732A9B76AD793F2212B2BCAB4CC04760EDCABCA45A6BC2DC03F0F3D364E453E860D056A2D5D1946CDF8845E21C3CC219A59A23FEF77AA2332690D2A0F9297A861107933847C394C10CF3DE8D4FB2F61890BA7F02659FF6802E045188F8117C4978F7AFAB75D60FAE15CF6A0DE8479612DBDE3A19D47E60455DA1E641A24CBECA0B7F95531DEAF1ED60F232A8EAFF7D900D3D736C80B1DE64FE919AAE62CEAD73B90ECD060686DDF5049BAA6826DE046DC4820035AF40FD8B6CE1B28763C1901FC87BDC2DE274443FFDFB93A402AAD76C32CBE00C5EA4EAE393C9ABEEBE05732E2BE",
              @"3072 S(premaster) 与独立参考逐位相同");
        eqStr(A2RPTestHexUpper(t2.K, t2.keyLen),
              @"770ABD54FE495F462686FF14A669000EA23C852E98836FBB855D1BE6913EAFED64CD8990E3C62C967321E597D825D5283D79613853A8F7D3421A32614949196A",
              @"3072 K = H(S) 与独立参考逐位相同");
        eqStr(A2RPTestHexUpper(t2.M1, t2.m1Len),
              @"20331513B11C334F75480B40EF7864D798AD53CA51925D011A83E791DA42A98452127E9624ED822CA59F56C7039233C1DC91F5656F40EA76A9175DC999DC968C",
              @"3072 M1 与独立参考逐位相同");
        ok(A2RPSRPServerComputeKey(s2, A2p, an, &why) && A2RPSRPServerVerifyM1(s2, t2.M1, t2.m1Len),
           @"3072 服务端校验 M1 通过");
        size_t m2n = 0;
        const uint8_t *m2 = A2RPSRPServerProofM2(s2, &m2n);
        eqStr(A2RPTestHexUpper(m2, m2n),
              @"065D0E75DDD3EF8AE6E045BC218525C93B034A9262566C3ADEACA6A67F6B0EA5A13C387CFD3384FF24CF372D3BFDD20830914777BCC57B2D5A7B738D47202493",
              @"3072 M2 与独立参考逐位相同");
        ok(A2RPSRPClientVerifyM2(c2, m2, m2n), @"3072 客户端校验 M2 通过");
        size_t ck = 0, sk = 0;
        const uint8_t *ckp = A2RPSRPClientSessionKey(c2, &ck);
        const uint8_t *skp = A2RPSRPServerSessionKey(s2, &sk);
        ok(ck == sk && ck > 0 && memcmp(ckp, skp, ck) == 0, @"3072 双方会话密钥一致");
    }
    A2RPSRPClientFree(c2);
    A2RPSRPServerFree(s2);

    // ===== ④ SRP 负例：非法值一律拒绝 =====
    uint8_t aBad[16] = { 0 };
    A2RPSRPClient *cn = A2RPSRPClientCreate(g3072, A2RPSRPHashSHA512(), 64,
                                            (const uint8_t *)"Pair-Setup", 10,
                                            (const uint8_t *)"123456", 6, aBad, 16, &why);
    ok(cn != NULL, @"负例准备：客户端可建");
    uint8_t saltZ[16] = { 0 };
    uint8_t zero8[8] = { 0 };
    why = nil;
    ok(!A2RPSRPClientComputeKey(cn, saltZ, 16, zero8, 8, &why) && why.length > 0,
       @"★B = 0 ⇒ 拒绝（点名原因）★");
    why = nil;
    NSData *nData = A2TestPSPrime3072Data();
    ok(!A2RPSRPClientComputeKey(cn, saltZ, 16, nData.bytes, 384, &why) && why.length > 0,
       @"★B = N ⇒ 拒绝（B >= N）★");
    why = nil;
    ok(!A2RPSRPClientComputeKey(cn, NULL, 0, zero8, 8, &why), @"盐为空 ⇒ 拒绝");
    A2RPSRPServer *sn = A2RPSRPServerCreate(g3072, A2RPSRPHashSHA512(), 64,
                                            (const uint8_t *)"Pair-Setup", 10,
                                            (const uint8_t *)"123456", 6, saltZ, 16, aBad, 16, &why);
    ok(sn != NULL, @"负例准备：服务端可建");
    why = nil;
    ok(!A2RPSRPServerComputeKey(sn, zero8, 8, &why) && why.length > 0,
       @"★A = 0 ⇒ 拒绝（点名原因）★");
    A2RPSRPClientFree(cn);
    A2RPSRPServerFree(sn);
    ok(A2RPSRPClientCreate(g3072, A2RPSRPHashSHA512(), 64,
                           (const uint8_t *)"I", 1, (const uint8_t *)"P", 1, NULL, 0, &why) == NULL,
       @"a 为空 ⇒ 建客户端失败（不猜）");
    ok(A2RPSRPClientCreate(g3072, A2RPSRPHashSHA512(), 7,
                           (const uint8_t *)"I", 1, (const uint8_t *)"P", 1, aBad, 16, &why) == NULL,
       @"不支持的摘要长度 ⇒ 建客户端失败");
}

#pragma mark ⑲b 消息流：PS-Msg01..06 真跑完 + 负例

static void testPairSetupMessageFlow(void) {
    printf("\n-- [JIT-AUTOPAIR-3] pair-setup 消息流（PS-Msg01..06 + 负例）--\n");
    NSError *e = nil;
    A2RPPairingIdentity *hid = [A2RPPairingIdentity identityWithHostName:@"ps-flow-host" error:&e];
    A2RPPairingIdentity *did = [A2RPPairingIdentity identityWithHostName:@"ps-flow-dev" error:&e];
    ok(hid != nil && did != nil, @"测试身份可生成");

    // ===== 自测（进程内全链路 + 篡改/错码负例）=====
    A2RPPairSetupSelfTest *st = [A2RPPairSetupSelfTest runSelfTest];
    ok(st.ok, @"★pair-setup 自握手整体通过（PS-Msg01..06 + 双方密钥一致）★");
    eqInt((NSInteger)st.messageSizes.count, 6, @"自握手真的走了 6 条消息");
    ok(st.sessionKeysEqual, @"★双方 SRP 会话密钥一致★");
    ok(st.tamperRejected, @"★篡改 Msg03(M1) ⇒ 被拒★");
    ok(st.wrongPinRejected, @"★配对码不一致 ⇒ 设备拒绝★");
    ok([st.summary containsString:@"PS-Msg01..06"], @"自握手结论可读（带消息流尺寸）");

    // ===== 逐条消息语义 =====
    NSString *why = nil;
    A2RPPairSetupSession *h = nil, *d = nil;
    A2TestPSMakePair(hid, did, &h, &d);
    ok(h != nil && d != nil, @"Host/Device 会话可建");
    NSData *m1 = [h nextMessageWithReason:&why];
    ok(m1.length > 0 && A2RPTLVStateValue(A2RPTLVDecode(m1, NULL)) == 1, @"Msg01 State=1");
    ok(A2RPTLVValue(A2RPTLVDecode(m1, NULL), A2RPTLVTypeMethod).length == 1, @"Msg01 含 Method");
    ok([d acceptMessage:m1 reason:&why], @"Device 接受 Msg01");
    NSData *m2 = [d nextMessageWithReason:&why];
    NSDictionary *mm2 = A2RPTLVDecode(m2, NULL);
    ok(A2RPTLVStateValue(mm2) == 2, @"Msg02 State=2");
    ok(A2RPTLVValue(mm2, A2RPTLVTypePublicKey).length > 0
       && A2RPTLVValue(mm2, A2RPTLVTypeSalt).length > 0, @"Msg02 含 Salt + PublicKey(B)");
    ok([h acceptMessage:m2 reason:&why], @"Host 接受 Msg02（SRP 参数）");
    NSData *m3 = [h nextMessageWithReason:&why];
    NSDictionary *mm3 = A2RPTLVDecode(m3, NULL);
    ok(A2RPTLVStateValue(mm3) == 3, @"Msg03 State=3");
    ok(A2RPTLVValue(mm3, A2RPTLVTypePublicKey).length == 384, @"Msg03 的 A = 384 字节（3072 位）");
    ok(A2RPTLVValue(mm3, A2RPTLVTypeProof).length == 64, @"Msg03 的 M1 = 64 字节（SHA-512）");
    ok([d acceptMessage:m3 reason:&why], @"Device 接受 Msg03（校验 A 与 M1）");
    NSData *m4 = [d nextMessageWithReason:&why];
    ok(A2RPTLVStateValue(A2RPTLVDecode(m4, NULL)) == 4, @"Msg04 State=4");
    ok([h acceptMessage:m4 reason:&why], @"Host 接受 Msg04（校验 M2）");
    NSData *m5 = [h nextMessageWithReason:&why];
    NSDictionary *mm5 = A2RPTLVDecode(m5, NULL);
    ok(A2RPTLVStateValue(mm5) == 5, @"Msg05 State=5");
    ok(A2RPTLVValue(mm5, A2RPTLVTypeEncryptedData).length > 16, @"Msg05 含 EncryptedData");
    ok([d acceptMessage:m5 reason:&why], @"Device 接受 Msg05（解密 + 验控制器签名）");
    ok(d.peerIdentifier.length > 0, @"Device 解出控制器 identifier");
    NSData *m6 = [d nextMessageWithReason:&why];
    ok(A2RPTLVStateValue(A2RPTLVDecode(m6, NULL)) == 6, @"Msg06 State=6");
    ok([h acceptMessage:m6 reason:&why], @"Host 接受 Msg06");
    ok(h.established && d.established, @"双方进入已建立");
    ok([h.sessionKey isEqualToData:d.sessionKey] && h.sessionKey.length == 64,
       @"★双方会话密钥一致且 64 字节★");
    ok(h.peerIdentifier.length > 0 && h.peerPublicKey.length == 32, @"Host 存下设备记录（identifier + 公钥）");
    ok([h nextMessageWithReason:&why] == nil, @"已建立后无待发消息（如实返回 nil）");

    // ===== 负例：篡改 / 顺序 / 垃圾 / ErrorResponse / 配对码 =====

    // (1) Msg02 的 B 非法（0）⇒ Host 拒绝
    {
        A2RPPairSetupSession *hx = nil, *dx = nil;
        A2TestPSMakePair(hid, did, &hx, &dx);
        NSString *w = nil;
        NSData *x1 = [hx nextMessageWithReason:&w];
        [dx acceptMessage:x1 reason:&w];
        NSData *x2 = [dx nextMessageWithReason:&w];
        NSData *saltV = A2RPTLVValue(A2RPTLVDecode(x2, NULL), A2RPTLVTypeSalt);
        NSData *badM2 = A2RPTLVEncode(@[ @(A2RPTLVTypeState), @(A2RPTLVTypePublicKey), @(A2RPTLVTypeSalt) ],
                                      @[ A2RPTestOneByte(0x02),
                                         [NSData dataWithBytes:A2RPTestZeroBytes() length:8],
                                         saltV ]);
        w = nil;
        ok(![hx acceptMessage:badM2 reason:&w] && w.length > 0, @"★Msg02 的 B 非法(0) ⇒ Host 拒绝★");
    }
    // (2) 篡改 Msg03 的 M1 ⇒ Device 拒绝
    {
        A2RPPairSetupSession *hx = nil, *dx = nil;
        A2TestPSMakePair(hid, did, &hx, &dx);
        NSString *w = nil;
        NSData *x3 = A2TestPSAdvanceToMsg03(hx, dx, &w);
        NSMutableData *bad = [x3 mutableCopy];
        ((uint8_t *)bad.mutableBytes)[bad.length - 1] ^= 0x01;
        w = nil;
        ok(![dx acceptMessage:bad reason:&w] && w.length > 0, @"★篡改 Msg03(M1) ⇒ Device 拒绝★");
    }
    // (3) 篡改 Msg03 的 A ⇒ Device 拒绝
    {
        A2RPPairSetupSession *hx = nil, *dx = nil;
        A2TestPSMakePair(hid, did, &hx, &dx);
        NSString *w = nil;
        NSData *x3 = A2TestPSAdvanceToMsg03(hx, dx, &w);
        NSMutableData *bad = [x3 mutableCopy];
        ((uint8_t *)bad.mutableBytes)[5] ^= 0x01;
        w = nil;
        ok(![dx acceptMessage:bad reason:&w], @"★篡改 Msg03(A) ⇒ Device 拒绝★");
    }
    // (4) 篡改 Msg04 的 M2 ⇒ Host 拒绝
    {
        A2RPPairSetupSession *hx = nil, *dx = nil;
        A2TestPSMakePair(hid, did, &hx, &dx);
        NSString *w = nil;
        NSData *x3 = A2TestPSAdvanceToMsg03(hx, dx, &w);
        [dx acceptMessage:x3 reason:&w];
        NSData *x4 = [dx nextMessageWithReason:&w];
        NSMutableData *bad = [x4 mutableCopy];
        ((uint8_t *)bad.mutableBytes)[bad.length - 1] ^= 0x01;
        w = nil;
        ok(![hx acceptMessage:bad reason:&w] && [w containsString:@"M2"], @"★篡改 Msg04(M2) ⇒ Host 拒绝★");
    }
    // (5) 篡改 Msg05 密文 ⇒ Device 拒绝（AEAD）
    {
        A2RPPairSetupSession *hx = nil, *dx = nil;
        A2TestPSMakePair(hid, did, &hx, &dx);
        NSString *w = nil;
        NSData *x3 = A2TestPSAdvanceToMsg03(hx, dx, &w);
        [dx acceptMessage:x3 reason:&w];
        NSData *x4 = [dx nextMessageWithReason:&w];
        [hx acceptMessage:x4 reason:&w];
        NSData *x5 = [hx nextMessageWithReason:&w];
        NSMutableData *bad = [x5 mutableCopy];
        ((uint8_t *)bad.mutableBytes)[8] ^= 0x01;
        w = nil;
        ok(![dx acceptMessage:bad reason:&w] && w.length > 0, @"★篡改 Msg05 密文 ⇒ Device 拒绝（AEAD）★");
    }
    // (6) 篡改 Msg06 密文 ⇒ Host 拒绝
    {
        A2RPPairSetupSession *hx = nil, *dx = nil;
        A2TestPSMakePair(hid, did, &hx, &dx);
        NSString *w = nil;
        NSData *x3 = A2TestPSAdvanceToMsg03(hx, dx, &w);
        [dx acceptMessage:x3 reason:&w];
        NSData *x4 = [dx nextMessageWithReason:&w];
        [hx acceptMessage:x4 reason:&w];
        NSData *x5 = [hx nextMessageWithReason:&w];
        [dx acceptMessage:x5 reason:&w];
        NSData *x6 = [dx nextMessageWithReason:&w];
        NSMutableData *bad = [x6 mutableCopy];
        ((uint8_t *)bad.mutableBytes)[bad.length - 1] ^= 0x01;
        w = nil;
        ok(![hx acceptMessage:bad reason:&w], @"★篡改 Msg06 密文 ⇒ Host 拒绝★");
    }
    // (7) 顺序错：把 Msg03 直接喂给还没收到 Msg01 的 Device
    {
        A2RPPairSetupSession *hx = nil, *dx = nil;
        A2TestPSMakePair(hid, did, &hx, &dx);
        NSString *w = nil;
        NSData *x3 = A2TestPSAdvanceToMsg03(hx, dx, &w);
        A2RPPairSetupSession *fresh = [A2RPPairSetupSession deviceSessionWithIdentity:did
                                                                                  pin:@"123456" reason:&w];
        w = nil;
        ok(![fresh acceptMessage:x3 reason:&w] && [w containsString:@"顺序"],
           @"★消息流顺序错 ⇒ 拒绝（点名「顺序」）★");
    }
    // (8) 非 TLV 垃圾
    {
        A2RPPairSetupSession *hx = nil, *dx = nil;
        A2TestPSMakePair(hid, did, &hx, &dx);
        NSString *w = nil;
        ok(![dx acceptMessage:[@"not-a-tlv" dataUsingEncoding:NSUTF8StringEncoding] reason:&w] && w.length > 0,
           @"非 TLV8 字节 ⇒ 被拒");
    }
    // (9) 对端 ErrorResponse
    {
        A2RPPairSetupSession *hx = nil, *dx = nil;
        A2TestPSMakePair(hid, did, &hx, &dx);
        NSString *w = nil;
        NSData *errTlv = A2RPTLVEncode(@[ @(A2RPTLVTypeState), @(A2RPTLVTypeError) ],
                                       @[ A2RPTestOneByte(0x02), A2RPTestOneByte(0x01) ]);
        ok(![hx acceptMessage:errTlv reason:&w] && [w containsString:@"ErrorResponse"],
           @"★对端 ErrorResponse ⇒ 如实失败★");
    }
    // (10) 配对码取到空码 ⇒ Host 拒绝
    {
        NSString *w = nil;
        A2RPPairSetupSession *hx = [A2RPPairSetupSession hostSessionWithIdentity:hid
                                                                    pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
            (void)p; return @"";
        } reason:&w];
        A2RPPairSetupSession *dx = [A2RPPairSetupSession deviceSessionWithIdentity:did pin:@"123456" reason:&w];
        NSData *x1 = [hx nextMessageWithReason:&w];
        [dx acceptMessage:x1 reason:&w];
        NSData *x2 = [dx nextMessageWithReason:&w];
        w = nil;
        ok(![hx acceptMessage:x2 reason:&w] && [w containsString:@"配对码"],
           @"★配对码来源未注入 / 空码 ⇒ 如实拒绝（点名）★");
    }
    // (11) 会话构造侧的拒绝
    {
        NSString *w = nil;
        ok([A2RPPairSetupSession hostSessionWithIdentity:hid pinProvider:nil reason:&w] == nil,
           @"Host 会话：未注入配对码来源 ⇒ 拒绝建会话");
        w = nil;
        ok([A2RPPairSetupSession deviceSessionWithIdentity:did pin:@"" reason:&w] == nil,
           @"Device 会话：空配对码 ⇒ 拒绝建会话");
        w = nil;
        ok([A2RPPairSetupSession hostSessionWithIdentity:nil pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
            (void)p; return @"1";
        } reason:&w] == nil, @"Host 会话：身份缺失 ⇒ 拒绝建会话");
    }
    // (12) Device 侧：M1 对不上（Host 用错码）
    {
        A2RPPairingIdentity *h2 = [A2RPPairingIdentity identityWithHostName:@"ps-wrongpin-h" error:NULL];
        A2RPPairingIdentity *d2 = [A2RPPairingIdentity identityWithHostName:@"ps-wrongpin-d" error:NULL];
        NSString *w = nil;
        A2RPPairSetupSession *hx = [A2RPPairSetupSession hostSessionWithIdentity:h2
                                                                    pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
            (void)p; return @"000000";
        } reason:&w];
        A2RPPairSetupSession *dx = [A2RPPairSetupSession deviceSessionWithIdentity:d2 pin:@"123456" reason:&w];
        NSData *x3 = A2TestPSAdvanceToMsg03(hx, dx, &w);
        w = nil;
        ok(![dx acceptMessage:x3 reason:&w] && [w containsString:@"M1"],
           @"★配对码不一致 ⇒ M1 校验失败被拒（点名 M1）★");
    }

    // ===== 传输缝驱动（注入假传输）=====
    {
        NSString *w = nil;
        A2RPPairingIdentity *h3 = [A2RPPairingIdentity identityWithHostName:@"ps-transport-h" error:NULL];
        A2RPPairingIdentity *d3 = [A2RPPairingIdentity identityWithHostName:@"ps-transport-d" error:NULL];
        A2RPPairSetupSession *dev = [A2RPPairSetupSession deviceSessionWithIdentity:d3 pin:@"000000" reason:&w];
        A2TestPSDeviceTransport *tr = [A2TestPSDeviceTransport new];
        tr.device = dev;
        __block NSInteger promptSeen = -1;
        NSData *key = nil;
        BOOL okRun = [A2RPPairSetupSession runHostOverTransport:tr identity:h3
                                                     pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
            promptSeen = p; return @"000000";
        } reason:&w sessionKey:&key];
        ok(okRun, @"★注入传输 ⇒ Host 跑完 pair-setup 成功★");
        eqInt((NSInteger)tr.exchanges, 3, @"传输层恰好交换 3 次（Msg01/03/05）");
        eqInt((NSInteger)key.length, 64, @"回填的会话密钥 64 字节");
        ok(dev.established, @"对端（设备）也进入已建立");
        ok(promptSeen == A2RPPairSetupPinPromptOnDevice, @"取码场景默认 OnDevice");
        ok([[h3 pairingFileData] length] > 0, @"Host 身份可产出配对文件字节");

        NSString *w2 = nil;
        ok(![A2RPPairSetupSession runHostOverTransport:nil identity:h3
                                           pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
            (void)p; return @"1";
        } reason:&w2 sessionKey:NULL] && w2.length > 0, @"★未注入传输 ⇒ 如实拒绝（点名）★");

        NSString *w3 = nil;
        A2RPPairSetupSession *dev2 = [A2RPPairSetupSession deviceSessionWithIdentity:d3 pin:@"000000" reason:&w3];
        A2TestPSDeviceTransport *tr2 = [A2TestPSDeviceTransport new];
        tr2.device = dev2;
        tr2.observedAwaitingConsent = YES;
        __block NSInteger prompt2 = -1;
        (void)[A2RPPairSetupSession runHostOverTransport:tr2 identity:h3
                                             pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
            prompt2 = p; return @"000000";
        } reason:&w3 sessionKey:NULL];
        ok(prompt2 == A2RPPairSetupPinPromptAwaitingConsent, @"传输报到 awaiting consent ⇒ 取码场景用 AwaitingConsent");
    }
}

#pragma mark ⑲c 接线：预检真跑 + Bridge 真调 + 诚实口径

static void testPairSetupWiring(void) {
    printf("\n-- [JIT-AUTOPAIR-3] 接线（预检 / Bridge 真调 / 诚实口径）--\n");
    A2RPPairingPreflight *pf = [A2RPPairingPreflight run];
    ok(pf.pairSetupOK, @"★自检：pair-setup 自手写【真跑通过】★");
    ok([pf.pairSetupSummary containsString:@"pair-setup"], @"pair-setup 自检摘要可读");
    ok([pf.summary containsString:@"pair-setup 自握手=通过"], @"★总摘要如实写「pair-setup 自握手=通过」★");
    eqInt((NSInteger)pf.firstBlockedStep, (NSInteger)A2RPPairingBlockedStepRsdEndpoint,
          @"本地全绿后首阻步骤仍是 RSD 端点（pair-setup 已不再是「未落地」）");
    eqStr([A2RPPairingPreflight displayNameForBlockedStep:A2RPPairingBlockedStepPairSetup],
          @"PairSetup(SRP-3072)", @"pair-setup 受阻步骤诊断名稳定");
    ok(pf.pairVerifyOK, @"pair-verify 自握手仍通过（未回退）");

    // Bridge 源码级不变量（生产接线点）
    NSString *bridge = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Bridge/A2JITAutoPairingEngineBridge.m")
                                                 encoding:NSUTF8StringEncoding error:NULL];
    ok(bridge.length > 0, @"读得到自动配对引擎 Bridge");
    ok([bridge containsString:@"A2RPPairSetupSession"], @"★Bridge 真接进 pair-setup 消息机★");
    ok([bridge containsString:@"[A2RPPairSetupSession runHostOverTransport:"],
       @"★Bridge 真调 pair-setup 驱动（谁调它：generatePairingFileWithinBudget:）★");
    ok([bridge containsString:@"pairSetupTransport"], @"Bridge 有 pair-setup 传输注入缝");
    ok([bridge containsString:@"pairSetupPinProvider"], @"Bridge 有配对码注入缝");
    ok([bridge containsString:@"pair-setup 传输未注入"], @"★未注入传输时如实点名（不谎报）★");
    ok([bridge containsString:@"RemoteXPC"], @"★Bridge 如实点名真机需 RemoteXPC 传输★");

    NSString *bh = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Bridge/A2JITAutoPairingEngineBridge.h")
                                             encoding:NSUTF8StringEncoding error:NULL];
    ok([bh containsString:@"A2RPPairSetupMessageTransport"], @"Bridge 头暴露 pair-setup 传输缝");
    ok([bh containsString:@"pairSetupPinProvider"], @"Bridge 头暴露配对码注入缝");

    // 测试入口已收录新源文件
    NSString *runner = [NSString stringWithContentsOfFile:RepoPath(@"tests/JIT/run_jit_tests.py")
                                                 encoding:NSUTF8StringEncoding error:NULL];
    ok([runner containsString:@"a2_rppairing_srp.m"], @"测试入口收录 a2_rppairing_srp.m");
    ok([runner containsString:@"a2_rppairing_pairsetup.m"], @"测试入口收录 a2_rppairing_pairsetup.m");
    ok([runner containsString:@"mbedtls"], @"测试入口登记 mbedtls 头/库搜索路径");
}

#pragma mark ⑲d 配对码来源（可选项表 + 解析）+ 设备发起档的 6 位码会话

static void testPairSetupPinSource(void) {
    printf("\n-- [JIT-AUTOPAIR-3] 配对码来源（可选项 / 解析 / 6 位码会话 / 接线）--\n");

    // ===== ① 候选表：★照列不误，未实现的也入表★ =====
    NSArray<A2JITPairingPinSourceItem *> *items = [A2JITPairingPinSourceCatalog allItems];
    eqInt((NSInteger)items.count, 4, @"候选档 4 个（信任弹窗 / 设备发起 / 已有记录 / 屏显码）");
    eqStr(items[0].identifier, @"trustDialog", @"档 0 = 信任弹窗");
    eqStr(items[1].identifier, @"deviceInitiated", @"档 1 = 设备发起");
    eqStr(items[2].identifier, @"existingRecord", @"档 2 = 已有配对记录");
    eqStr(items[3].identifier, @"onScreenCode", @"档 3 = 设备屏显码");
    eqInt((NSInteger)items[0].mode, (NSInteger)A2JITPairingPinModeTrustDialog, @"档 0 模式正确");
    eqInt((NSInteger)items[1].mode, (NSInteger)A2JITPairingPinModeDeviceInitiated, @"档 1 模式正确");
    eqInt((NSInteger)items[2].mode, (NSInteger)A2JITPairingPinModeExistingRecord, @"档 2 模式正确");
    eqInt((NSInteger)items[3].mode, (NSInteger)A2JITPairingPinModeOnScreenCode, @"档 3 模式正确");
    ok(items[0].implemented && items[1].implemented && items[2].implemented,
       @"前三档已实现");
    ok(!items[3].implemented, @"★设备屏显码档照列但标记「未实现」★");
    eqStr([A2JITPairingPinSourceCatalog defaultIdentifier], @"deviceInitiated",
          @"主推 = 设备发起档（iOS 27）");
    eqInt([A2JITPairingPinSourceCatalog modeForIdentifier:@""],
          A2JITPairingPinModeUnselected, @"空标识 ⇒ Unselected");
    eqInt([A2JITPairingPinSourceCatalog modeForIdentifier:@"nope"],
          A2JITPairingPinModeUnknown, @"不认识的标识 ⇒ Unknown");
    ok([A2JITPairingPinSourceCatalog itemForIdentifier:@"onScreenCode"] != nil, @"按标识可取到候选项");

    // ===== ② 解析：选择项 → 配对码 / 或「该走哪条路」=====
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *saved = [d stringForKey:A2SelectedPairingPinSourcePrefKey];

    [d removeObjectForKey:A2SelectedPairingPinSourcePrefKey];
    eqInt([A2JITPairingPinResolver selectedMode], A2JITPairingPinModeUnselected, @"键缺失 ⇒ 未选择");
    ok([[A2JITPairingPinResolver criterionLine] hasPrefix:@"[A2-PAIRPIN] source="],
       @"判据行带 [A2-PAIRPIN] source= 前缀");
    ok([[A2JITPairingPinResolver criterionLine] containsString:@"mode="], @"判据行含 mode=");
    {
        NSString *why = nil;
        NSString *pin = [A2JITPairingPinResolver resolvedPinForDisplayedCode:nil reason:&why];
        ok(pin == nil && [why containsString:@"未选择"],
           @"★未选择 ⇒ 拒绝并点名（不静默回退）★");
    }

    [d setObject:@"trustDialog" forKey:A2SelectedPairingPinSourcePrefKey];
    eqInt([A2JITPairingPinResolver selectedMode], A2JITPairingPinModeTrustDialog, @"选中信任弹窗档");
    {
        NSString *why = nil;
        NSString *pin = [A2JITPairingPinResolver resolvedPinForDisplayedCode:nil reason:&why];
        eqStr(pin, @"000000", @"★信任弹窗档 ⇒ 固定码 000000（协议事实）★");
    }

    [d setObject:@"deviceInitiated" forKey:A2SelectedPairingPinSourcePrefKey];
    {
        NSString *why = nil;
        eqStr([A2JITPairingPinResolver resolvedPinForDisplayedCode:@"123456" reason:&why], @"123456",
              @"设备发起档 ⇒ 用本机显示的 6 位码");
        why = nil;
        ok([A2JITPairingPinResolver resolvedPinForDisplayedCode:@"12 456" reason:&why] == nil
           && why.length > 0, @"★非 6 位数字的码 ⇒ 拒绝★");
        why = nil;
        ok([A2JITPairingPinResolver resolvedPinForDisplayedCode:nil reason:&why] == nil
           && why.length > 0, @"★还没生成码 ⇒ 拒绝并点名★");
    }

    [d setObject:@"existingRecord" forKey:A2SelectedPairingPinSourcePrefKey];
    {
        NSString *why = nil;
        ok([A2JITPairingPinResolver resolvedPinForDisplayedCode:@"123456" reason:&why] == nil
           && [why containsString:@"pair-verify"], @"★已有记录档 ⇒ 不取码，走 pair-verify 快路径★");
    }

    [d setObject:@"onScreenCode" forKey:A2SelectedPairingPinSourcePrefKey];
    {
        NSString *why = nil;
        ok([A2JITPairingPinResolver resolvedPinForDisplayedCode:@"123456" reason:&why] == nil
           && [why containsString:@"未实现"], @"★屏显码档未实现 ⇒ 选中即拒绝并点名★");
    }

    [d setObject:@"garbage" forKey:A2SelectedPairingPinSourcePrefKey];
    {
        NSString *why = nil;
        ok([A2JITPairingPinResolver selectedMode] == A2JITPairingPinModeUnknown
           && [A2JITPairingPinResolver resolvedPinForDisplayedCode:nil reason:&why] == nil
           && why.length > 0, @"★不认识的偏好值 ⇒ 拒绝（不猜）★");
    }

    // 复原（不给后续/他人留「已选择」假象）
    if (saved) { [d setObject:saved forKey:A2SelectedPairingPinSourcePrefKey]; }
    else { [d removeObjectForKey:A2SelectedPairingPinSourcePrefKey]; }

    // ===== ③ 设备发起档的 6 位码会话：生成 / 持久化 / 作废 / 判据行 =====
    A2JITPairingCodeSession *cs = [A2JITPairingCodeSession sharedSession];
    NSError *err = nil;
    ok(![cs beginDeviceInitiatedWithHostName:@"" error:&err] && err != nil,
       @"★主机名为空 ⇒ 不生成码（不猜主机名）★");
    err = nil;
    ok([cs beginDeviceInitiatedWithHostName:@"Air2 (test)" error:&err],
       @"设备发起档：生成 6 位码成功");
    eqInt((NSInteger)cs.code.length, 6, @"码是 6 位");
    {
        BOOL allDigits = YES;
        for (NSUInteger i = 0; i < cs.code.length; i++) {
            unichar c = [cs.code characterAtIndex:i];
            if (c < '0' || c > '9') { allDigits = NO; }
        }
        ok(allDigits, @"★码是 6 位纯数字（可在系统设置里输入）★");
    }
    eqInt((NSInteger)cs.state, (NSInteger)A2JITPairingCodeStateAdvertising, @"状态=广告中");
    eqStr(cs.hostName, @"Air2 (test)", @"主机名可认出（用户要在系统设置里选它）");
    ok([[A2JITPairingCodeSession criterionLineForState:cs.state host:cs.hostName code:cs.code detail:nil]
        hasPrefix:@"[A2-PAIRPIN] state="], @"判据行带 [A2-PAIRPIN] state= 前缀");
    eqStr([A2JITPairingCodeSession stateName:A2JITPairingCodeStateVerifying], @"verifying",
          @"状态英文名稳定（日志可搜）");
    eqStr([A2JITPairingCodeSession pairableHostServiceType], @"_remotepairing-pairable-host._tcp",
          @"广告服务类型（与 Natives/Info.plist 一致）");

    // ★持久化：切到系统设置再回来仍能读到同一个码★
    A2JITPairingCodeSession *restored = [A2JITPairingCodeSession restoredFromDefaults];
    ok(restored != nil && [restored.code isEqualToString:cs.code]
       && [restored.hostName isEqualToString:cs.hostName],
       @"★切后台/去系统设置后仍能读到【同一个】码（已持久化）★");

    [cs advanceToState:A2JITPairingCodeStateVerifying detail:@"设备已连入并提交码"];
    eqInt((NSInteger)[A2JITPairingCodeSession restoredFromDefaults].state,
          (NSInteger)A2JITPairingCodeStateVerifying, @"状态推进也持久化");
    [cs advanceToState:A2JITPairingCodeStateFailed detail:@"M1 校验失败（码不对）"];
    ok([[A2JITPairingCodeSession restoredFromDefaults].lastDetail containsString:@"码不对"],
       @"★失败原因如实持久化（用户可见）★");
    [cs endPairing];
    ok(cs.code.length == 0 && [A2JITPairingCodeSession restoredFromDefaults] == nil,
       @"★作废后清掉显示的码（不留一个已经不能用的码）★");

    // ===== ④ Info.plist 与本档的服务类型一致（防漂移）=====
    NSString *plistSrc = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Info.plist")
                                                   encoding:NSUTF8StringEncoding error:NULL];
    ok([plistSrc containsString:[A2JITPairingCodeSession pairableHostServiceType]],
       @"★Info.plist 登记了可配对主机服务类型（否则设备发现不到我们）★");

    // ===== ⑤ 用户可见入口 + 接线（源码级不变量）=====
    NSString *settings = [NSString stringWithContentsOfFile:RepoPath(@"Air2/UI/Screens/Settings/A2JITSettings.m")
                                                   encoding:NSUTF8StringEncoding error:NULL];
    ok(settings.length > 0, @"读得到 JIT 设置页");
    ok([settings containsString:@"jit.row.pairpin"], @"★设置页有「配对码来源」行★");
    ok([settings containsString:@"A2SelectedPairingPinSourcePrefKey"], @"★设置页是偏好键的写入点★");
    ok([settings containsString:@"A2JITPairingPinResolver"], @"★设置页真的用解析器（选择项生效）★");
    ok([settings containsString:@"beginDeviceInitiatedWithHostName"], @"★设置页会生成并显示 6 位码★");
    ok([settings containsString:@"UIPasteboard"], @"★码行可复制（UIPasteboard）★");
    ok([settings containsString:@"pairSetupPinProvider"], @"★用户可见选项 → 解析 → 喂 Natives 缝★");
    ok([settings containsString:@"隐私与安全性"] || [settings containsString:@"jit.pairpin.instruction"],
       @"设置页给了「去系统设置输入码」的指引（两种入口都提到）");

    NSString *contract = [NSString stringWithContentsOfFile:RepoPath(@"Air2/Utils/A2LaunchContract.m")
                                                   encoding:NSUTF8StringEncoding error:NULL];
    ok([contract containsString:@"A2SelectedPairingPinSource"], @"契约常量里登记了配对码来源偏好键");

    // 四语齐全（新 key × 4 语言）
    NSArray<NSString *> *pairpinKeys = @[ @"jit.row.pairpin", @"jit.pairpin.mode.trust",
                                          @"jit.pairpin.mode.device", @"jit.pairpin.mode.existing",
                                          @"jit.pairpin.mode.onscreen", @"jit.pairpin.unsupported",
                                          @"jit.pairpin.notselected", @"jit.pairpin.row.code",
                                          @"jit.pairpin.instruction", @"jit.pairpin.row.copy",
                                          @"jit.pairpin.toast.selected", @"jit.pairpin.cancel" ];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *k in pairpinKeys) {
        for (NSInteger li = A2JITLanguageZhHans; li <= A2JITLanguageJapanese; li++) {
            if ([A2JITStrings stringForKey:k language:(A2JITLanguage)li].length == 0) {
                [missing addObject:[NSString stringWithFormat:@"%@/%ld", k, (long)li]];
            }
        }
    }
    if (missing.count) { printf("        缺文案：%s\n", [[missing componentsJoinedByString:@","] UTF8String]); }
    eqInt((NSInteger)missing.count, 0, @"★配对码来源的新文案四语齐全★");
}

#pragma mark - ⑳ [JIT↔VM] 各档 verdict 全跑一遍（5 档供给路径 × 判据行 × 建 VM 决策）

/// 本单验收：把【五个供给档】各自的判据真跑一遍，断言三件事一致 ——
///   ① ② 的结论（verdict / enable）⇒ ③ 建 VM 究竟被放行还是被拦下；
///   ② 判据行 `[A2-JITVM] step=verify verdict=… enable=0/1 reason=… evidence=…`；
///   ③ 用户文案按本档分流（★未就绪 ≠ 失败，绝不是一句万能文案★）。
///
/// 五档与 docs/JIT-PROVISIONING.md 的分级表同源。★A2LaunchChain 不感知版本★ ——
/// 档位只决定「本机此刻是哪种判据」，链路只认判据（这正是分层要的效果）：
///   · iOS26 手动档   ：内置手动（导入配对 → 连 LocalDevVPN → 内置开启）—— 未开启 ⇒ 0x69 无人服务；
///   · iOS27 自动档   ：设备内自动配对（自研 RPPairing）—— 已启用；
///   · 导入配对文件档 ：iOS 17.4–25 导入配对 + 外部工具 —— base 脚本只回 legacy 哨兵（需指派脚本）；
///   · 内核档         ：越狱 / TrollStore / dynamic-codesigning —— 直启；
///   · 未就绪档       ：尚未探测（还没配对 / 刚装完）—— Unknown。
static void testJitVmTierVerdictMatrix(void) {
    printf("\n=== ⑲ [JIT↔VM] 各档 verdict（5 档供给路径 × 判据行 × 建 VM 决策）===\n");

    //           档名                 本档判据                              期望 enable   本档取证
    NSArray<NSArray *> *tiers = @[
        @[ @"iOS26 手动档",   @(A2JITReadinessVerdictNotServiced),    @(NO),
           @"brk #0x69 未被服务（无调试器应答）" ],
        @[ @"iOS27 自动档",   @(A2JITReadinessVerdictUsable),         @(YES),
           @"配对材料就绪 + 区域已映射且 max 含 X" ],
        @[ @"导入配对文件档", @(A2JITReadinessVerdictLegacySentinel),  @(NO),
           @"base 脚本回 legacy 哨兵 0xE0000069（脚本未接管）" ],
        @[ @"内核档",         @(A2JITReadinessVerdictUsable),         @(YES),
           @"内核级 JIT 直启（无外部调试器应答）" ],
        @[ @"未就绪档",       @(A2JITReadinessVerdictUnknown),        @(NO),
           @"尚未探测" ],
    ];

    NSMutableArray<NSString *> *blockedVerdictNames = [NSMutableArray array];
    NSMutableArray<NSString *> *blockedReasons = [NSMutableArray array];

    for (NSArray *tier in tiers) {
        NSString *tierName = tier[0];
        A2JITReadinessVerdict verdict = (A2JITReadinessVerdict)[tier[1] integerValue];
        BOOL expectEnable = [tier[2] boolValue];
        NSString *evidence = tier[3];

        // 假判据（真机由 Bridge 的 A2JITEnvironmentProbe 注入；这里注入假实现，语义一字不改）。
        FakeProbe *probe = [[FakeProbe alloc] init];
        probe.alwaysFail = !expectEnable;
        probe.verdict = verdict;
        probe.evidence = evidence;

        __block BOOL ranVM = NO;
        __block NSString *line = nil;
        A2LaunchChain *chain = [A2LaunchChain
            chainWithDeliverScript:^BOOL(NSError **e) { (void)e; return YES; }
                          verify:^BOOL(NSString **r) {
                BOOL ok2 = [probe ensureJITUsableWithinBudget:3.0 reason:r];
                line = [A2LaunchFailure jitvmLineWithStep:@"verify"
                                                  verdict:probe.lastVerdict
                                                enableJIT:ok2
                                               reasonText:nil
                                                 evidence:probe.lastEvidence];
                return ok2;
            }
                       createJVM:^BOOL(NSError **e) { (void)e; ranVM = YES; return YES; }];

        NSError *err = nil;
        BOOL ran = [chain runWithError:&err];

        eqInt(ran, expectEnable ? 1 : 0, [NSString stringWithFormat:@"%@：② 放行/拦下与档位一致", tierName]);
        eqInt(ranVM, expectEnable ? 1 : 0,
              [NSString stringWithFormat:@"★%@：JIT 不可用时 ③ 建 VM %@★", tierName,
               expectEnable ? @"运行" : @"完全未运行"]);
        ok(line != nil, [NSString stringWithFormat:@"%@：有 [A2-JITVM] 判据行", tierName]);
        ok([line hasPrefix:@"[A2-JITVM] step=verify verdict="],
           [NSString stringWithFormat:@"%@：判据行形状固定", tierName]);
        ok([line containsString:[NSString stringWithFormat:@"enable=%d", expectEnable ? 1 : 0]],
           [NSString stringWithFormat:@"★%@：判据行 enable=%d★", tierName, expectEnable ? 1 : 0]);
        ok([line containsString:[NSString stringWithFormat:@"verdict=%@(%ld)",
              [A2JITVerdictGuidance displayNameForVerdict:probe.lastVerdict], (long)probe.lastVerdict]],
           [NSString stringWithFormat:@"%@：判据行带本档 verdict 名与值", tierName]);
        ok([line containsString:evidence], [NSString stringWithFormat:@"%@：判据行带本档取证", tierName]);

        if (expectEnable) {
            eqInt(chain.stage, A2LaunchChainStageDone, [NSString stringWithFormat:@"%@：放行后 stage=Done", tierName]);
        } else {
            eqInt(chain.stage, A2LaunchChainStageVerify, [NSString stringWithFormat:@"%@：拦下后停在 ②", tierName]);
            eqInt(err != nil ? 1 : 0, 1, [NSString stringWithFormat:@"%@：拦下时回填 NSError", tierName]);
            // 用户文案按本档分流（★不是一句万能文案★）
            NSString *msg = [A2LaunchFailure userMessageForJITVerdict:probe.lastVerdict];
            NSString *tierReason = [A2JITStrings stringForKey:
                                    [A2JITVerdictGuidance reasonKeyForVerdict:probe.lastVerdict]];
            ok([msg containsString:tierReason],
               [NSString stringWithFormat:@"%@：用户文案含本档专属原因", tierName]);
            [blockedVerdictNames addObject:[A2JITVerdictGuidance displayNameForVerdict:probe.lastVerdict]];
            [blockedReasons addObject:[A2JITVerdictGuidance diagnosticForVerdict:probe.lastVerdict]];
            ok([line containsString:blockedReasons.lastObject],
               [NSString stringWithFormat:@"%@：判据行 reason 与本档判据一致", tierName]);
        }
    }

    // ★「未就绪路径」与「失败路径」必须分得开★：三条拦下路径的 verdict 名 / 判据短语两两不同。
    eqInt((NSInteger)[NSSet setWithArray:blockedVerdictNames].count, 3,
          @"★三条拦下路径的 verdict 名互不相同（Unknown / NotServiced / LegacySentinel）★");
    eqInt((NSInteger)[NSSet setWithArray:blockedReasons].count, 3,
          @"★三条拦下路径的判据短语互不相同（未就绪 ≠ 失败）★");
    ok([blockedVerdictNames containsObject:@"Unknown"], @"未就绪路径 verdict = Unknown（不是失败档）");
    ok([blockedVerdictNames containsObject:@"NotServiced"], @"失败路径含 NotServiced");
    ok([blockedVerdictNames containsObject:@"LegacySentinel"], @"失败路径含 LegacySentinel");

    // 判据行构造器：7 档全覆盖、形状一致（★enable 仅 Usable 为 1★）
    for (NSInteger v = A2JITReadinessVerdictUnknown; v <= A2JITReadinessVerdictNotExecutable; v++) {
        A2JITReadinessVerdict vv = (A2JITReadinessVerdict)v;
        NSString *l = [A2LaunchFailure jitvmLineWithStep:@"verify" verdict:vv
                                               enableJIT:[A2JITVerdictGuidance isUsable:vv]
                                              reasonText:nil evidence:@"ev"];
        ok([l hasPrefix:@"[A2-JITVM] step=verify verdict="],
           [NSString stringWithFormat:@"判据行前缀固定（verdict %ld）", (long)v]);
        ok([l containsString:[NSString stringWithFormat:@"enable=%d",
                              [A2JITVerdictGuidance isUsable:vv] ? 1 : 0]],
           [NSString stringWithFormat:@"★enable 仅 Usable=1（verdict %ld）★", (long)v]);
    }

    // 非判据步（script / vm / gate）的自述覆盖生效
    NSString *gateLine = [A2LaunchFailure jitvmLineWithStep:@"gate"
                                                    verdict:A2JITReadinessVerdictUnknown
                                                  enableJIT:NO
                                                 reasonText:@"自研启动链未启用（开关=关）"
                                                   evidence:nil];
    ok([gateLine containsString:@"step=gate"] && [gateLine containsString:@"enable=0"]
       && [gateLine containsString:@"开关=关"], @"gate 步判据行自述覆盖生效（未就绪路径点名开关）");
}

#pragma mark - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("A2 JIT 纯逻辑单元测试\n");
        printf("（直接链接 Air2/Player 真实实现，非镜像）\n");

    testJitVmTierVerdictMatrix();
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
        testDDILogicAndStore();
        testDDIProbeAndGuidance();
        testRPPairingCore();
        testRPPairingHandshakeBody();
        testPairSetupSRPMath();
        testPairSetupMessageFlow();
        testPairSetupWiring();
        testPairSetupPinSource();
        testIntegrationTLSPSK();
        testLaunchChainJitVmWiring();
        testWiringInvariants();

        printf("\n----------------------------------------\n");
        printf("TOTAL pass=%d fail=%d\n", gPass, gFail);
        printf("----------------------------------------\n");
    }
    return gFail == 0 ? 0 : 1;
}
