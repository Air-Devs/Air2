//
//  pairwire_tests.m
//  Air2 tests
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [A2-PAIRWIRE] 设备发起配对「最后一跳」的单测：
//    · accessory 侧驱动（★先收后发★的 PS-Msg01..06）—— 用假传输跑真密码学；
//    · 广告 → 连入 → 建传输 → 会话 → 交出配对文件 的整条链 —— 假广告器 + 假传输；
//    · 失败路径：超时 / 错码（含篡改）/ 乱序 / 非 TLV / 无本地网络权限 / 被挂起 / 取消 …
//
//  ★这里证的是【自洽】：与 iOS 27 真设备的互操作★未验证（本会话无真机）★。
//  运行：python3 tests/JIT/run_pairwire_tests.py
//

#import <Foundation/Foundation.h>
#import <stdio.h>
#import <math.h>

#import "a2_rppairing_pairsetup.h"
#import "a2_rppairing_pairsetup_accessory.h"
#import "a2_rppairing_pairable_host.h"
#import "a2_rppairing.h"

static int gPass = 0;
static int gFail = 0;

static void T(const char *name, BOOL cond) {
    if (cond) { printf("PASS %s\n", name); gPass++; }
    else      { printf("FAIL %s\n", name); gFail++; }
}

#pragma mark - 夹具：假字节通道

@interface A2PairWireFakeStream : NSObject <A2RPByteStream>
@end
@implementation A2PairWireFakeStream
- (BOOL)openStreamWithTimeout:(NSTimeInterval)timeout reason:(NSString **)reason error:(A2RemoteXPCErrorKind *)error {
    (void)timeout; (void)reason; (void)error; return YES;
}
- (BOOL)writeBytes:(NSData *)bytes timeout:(NSTimeInterval)timeout reason:(NSString **)reason error:(A2RemoteXPCErrorKind *)error {
    (void)bytes; (void)timeout; (void)reason; (void)error; return YES;
}
- (NSData *)readBytesWithTimeout:(NSTimeInterval)timeout reason:(NSString **)reason error:(A2RemoteXPCErrorKind *)error {
    (void)timeout; (void)reason; (void)error; return nil;
}
- (void)closeStream {}
@end

#pragma mark - 夹具：假广告器（遵守 A2RPPairSetupAccessoryListener）

@interface A2PairWireFakeListener : NSObject <A2RPPairSetupAccessoryListener>
@property (nonatomic, readwrite, copy) NSString *serviceName;
@property (nonatomic, readwrite, copy) NSString *hostName;
@property (nonatomic, readwrite) uint16_t port;
@property (nonatomic, readwrite) A2RPPairableHostFailure failure;
@property (nonatomic, readwrite, copy, nullable) NSString *failureReason;
@property (nonatomic, readwrite) BOOL systemSawService;
// —— 测试控制面 ——
@property (nonatomic, strong, nullable) id<A2RPByteStream> streamToReturn;
@property (nonatomic) A2RPPairableHostFailure injectedFailure;
@property (nonatomic) uint16_t injectedPort;
@property (nonatomic) NSTimeInterval lastBudget;
@property (nonatomic) NSUInteger advertiseCallCount;
@property (nonatomic) NSUInteger stopCallCount;
@end

@implementation A2PairWireFakeListener
- (id<A2RPByteStream>)advertiseAndWaitForDeviceWithBudget:(NSTimeInterval)budget reason:(NSString **)reason {
    self.advertiseCallCount += 1;
    self.lastBudget = budget;
    if (self.streamToReturn == nil) {
        self.failure = self.injectedFailure;
        self.failureReason = @"注入的广告/等待失败";
        self.port = 0;
        if (reason) { *reason = self.failureReason; }
        return nil;
    }
    self.failure = A2RPPairableHostFailureNone;
    self.port = self.injectedPort ?: 49152;
    self.systemSawService = YES;
    return self.streamToReturn;
}
- (void)stop { self.stopCallCount += 1; }
@end

#pragma mark - 夹具：回环传输（真跑 Host/controller 侧会话，与 accessory 对拍）

/// 把「对端（host/controller）」做成一个真的 A2RPPairSetupSession：
/// receive = 取 host 的下一条；send = 把本机消息喂给 host 校验。
@interface A2PairWireLoopbackTransport : NSObject <A2RPPairSetupMessageTransport>
@property (nonatomic, strong, nullable) A2RPPairSetupSession *hostSession;
@property (nonatomic) A2RPPairSetupTransportFailure injectedKind;
@property (nonatomic) BOOL failNextReceive;
@property (nonatomic) BOOL failNextSend;
/// 第 N 次接收（1 起）时把消息末字节翻一位（★篡改检测★）。
@property (nonatomic) NSUInteger tamperReceiveAtIndex;
@property (nonatomic, copy, nullable) NSData *cannedReceive;
@property (nonatomic, readwrite) A2RPPairSetupTransportFailure lastFailureKind;
@property (nonatomic) NSUInteger recvCount;
@property (nonatomic) NSUInteger sendCount;
@end

@implementation A2PairWireLoopbackTransport

- (NSData *)receivePairingDataWithKind:(NSString *)kind timeout:(NSTimeInterval)timeout reason:(NSString **)reason {
    (void)kind; (void)timeout;
    self.recvCount += 1;
    if (self.failNextReceive) {
        self.failNextReceive = NO;
        self.lastFailureKind = self.injectedKind;
        if (reason) { *reason = @"注入的接收失败"; }
        return nil;
    }
    if (self.cannedReceive != nil) {
        NSData *d = self.cannedReceive;
        self.cannedReceive = nil;
        return d;
    }
    NSString *why = nil;
    NSData *m = [self.hostSession nextMessageWithReason:&why];
    if (m == nil) {
        if (reason) { *reason = why ?: @"主机侧无待发消息"; }
        return nil;
    }
    if (self.tamperReceiveAtIndex != 0 && self.recvCount == self.tamperReceiveAtIndex) {
        NSMutableData *bad = [m mutableCopy];
        ((uint8_t *)bad.mutableBytes)[bad.length - 1] ^= 0x01;
        m = bad;
    }
    self.lastFailureKind = A2RPPairSetupTransportFailureNone;
    return m;
}

- (BOOL)sendPairingData:(NSData *)tlv kind:(NSString *)kind startNew:(BOOL)startNewSession reason:(NSString **)reason {
    (void)kind; (void)startNewSession;
    self.sendCount += 1;
    if (self.failNextSend) {
        self.failNextSend = NO;
        self.lastFailureKind = self.injectedKind;
        if (reason) { *reason = @"注入的发送失败"; }
        return NO;
    }
    NSString *why = nil;
    BOOL ok = [self.hostSession acceptMessage:tlv reason:&why];
    if (!ok && reason) { *reason = why ?: @"主机侧拒绝"; }
    if (ok) { self.lastFailureKind = A2RPPairSetupTransportFailureNone; }
    return ok;
}

- (NSData *)exchangePairingData:(NSData *)tlv kind:(NSString *)kind startNew:(BOOL)startNewSession reason:(NSString **)reason {
    (void)tlv; (void)kind; (void)startNewSession;
    if (reason) { *reason = @"本夹具不走 exchange（accessory 侧只用收/发原语）"; }
    return nil;
}
@end

/// 实现了收/发但★不实现 lastFailureKind★（验证「不给分类就只归到 Transport」）。
@interface A2PairWireNoKindTransport : NSObject <A2RPPairSetupMessageTransport>
@property (nonatomic) BOOL failReceive;
@end
@implementation A2PairWireNoKindTransport
- (NSData *)receivePairingDataWithKind:(NSString *)kind timeout:(NSTimeInterval)timeout reason:(NSString **)reason {
    (void)kind; (void)timeout; (void)reason; return nil;
}
- (BOOL)sendPairingData:(NSData *)tlv kind:(NSString *)kind startNew:(BOOL)startNewSession reason:(NSString **)reason {
    (void)tlv; (void)kind; (void)startNewSession; (void)reason; return NO;
}
- (NSData *)exchangePairingData:(NSData *)tlv kind:(NSString *)kind startNew:(BOOL)startNewSession reason:(NSString **)reason {
    (void)tlv; (void)kind; (void)startNewSession; (void)reason; return nil;
}
@end

/// ★只有 exchange、没有 responder 原语★（必须被如实拒绝，而不是靠改 exchange 的语义硬跑）。
@interface A2PairWireExchangeOnlyTransport : NSObject <A2RPPairSetupMessageTransport>
@end
@implementation A2PairWireExchangeOnlyTransport
- (NSData *)exchangePairingData:(NSData *)tlv kind:(NSString *)kind startNew:(BOOL)startNewSession reason:(NSString **)reason {
    (void)tlv; (void)kind; (void)startNewSession; (void)reason; return nil;
}
@end

#pragma mark - 夹具：make 一个身份

static A2RPPairingIdentity *A2PairWireIdentity(NSString *name) {
    return [A2RPPairingIdentity identityWithHostName:name error:NULL];
}

/// 造一条只有 State 的 TLV（用于乱序/字段缺失类）。
static NSData *A2PairWireStateOnlyTLV(uint8_t state) {
    return A2RPTLVEncode(@[ @(A2RPTLVTypeState) ], @[ [NSData dataWithBytes:&state length:1] ]);
}

#pragma mark - 测试

static void TestConstants(void) {
    T("marker 是 [A2-PAIRPIN]", [A2RPPairWireCriterionMarker isEqualToString:@"[A2-PAIRPIN]"]);
    T("phase 名 starting",
      [A2RPPairSetupAccessoryPhaseName(A2RPPairSetupAccessoryPhaseStarting) isEqualToString:@"starting"]);
    T("phase 名 cancelled",
      [A2RPPairSetupAccessoryPhaseName(A2RPPairSetupAccessoryPhaseCancelled) isEqualToString:@"cancelled"]);
    T("failure 名 WrongPin",
      [A2RPPairSetupAccessoryFailureName(A2RPPairSetupAccessoryFailureWrongPin) isEqualToString:@"WrongPin"]);
    T("failure 名 NoLocalNetworkPermission",
      [A2RPPairSetupAccessoryFailureName(A2RPPairSetupAccessoryFailureNoLocalNetworkPermission) isEqualToString:@"NoLocalNetworkPermission"]);
    T("failure 名 Suspended",
      [A2RPPairSetupAccessoryFailureName(A2RPPairSetupAccessoryFailureSuspended) isEqualToString:@"Suspended"]);
    T("failure 名 WaitTimedOut",
      [A2RPPairSetupAccessoryFailureName(A2RPPairSetupAccessoryFailureWaitTimedOut) isEqualToString:@"WaitTimedOut"]);
    T("failure 名 SessionTimedOut",
      [A2RPPairSetupAccessoryFailureName(A2RPPairSetupAccessoryFailureSessionTimedOut) isEqualToString:@"SessionTimedOut"]);
    T("failure 名 Cancelled",
      [A2RPPairSetupAccessoryFailureName(A2RPPairSetupAccessoryFailureCancelled) isEqualToString:@"Cancelled"]);
    T("default 广告名含 Air2",
      [[A2RPPairSetupAccessory defaultAdvertisedNameForHostName:@"myiPhone"] isEqualToString:@"Air2 (myiPhone)"]);
}

#pragma mark 驱动（accessory 侧，先收后发）

static void TestDriverSuccess(void) {
    A2RPPairingIdentity *acc = A2PairWireIdentity(@"acc-driver-ok");
    A2RPPairingIdentity *hst = A2PairWireIdentity(@"host-driver-ok");
    A2PairWireLoopbackTransport *t = [[A2PairWireLoopbackTransport alloc] init];
    NSString *why = nil;
    A2RPPairSetupSession *host = [A2RPPairSetupSession hostSessionWithIdentity:hst
                                                                 pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
        (void)p; return @"123456";
    } reason:&why];
    T("夹具：host 会话建成", host != nil);
    t.hostSession = host;

    NSMutableArray<NSNumber *> *steps = [NSMutableArray array];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSData *key = nil;
    A2RPPairSetupDriveFailure fail = A2RPPairSetupDriveFailureNone;
    BOOL ok = [A2RPPairSetupSession runAccessoryOverTransport:t
                                                     identity:acc
                                                          pin:@"123456"
                                                 stepObserver:^(A2RPPairSetupStep step, NSString *line) {
        [steps addObject:@(step)];
        [lines addObject:line ?: @""];
    }
                                                       reason:&why
                                                 failureKind:&fail
                                                   sessionKey:&key];
    T("全链：驱动成功", ok);
    T("全链：失败分类 None", fail == A2RPPairSetupDriveFailureNone);
    T("全链：会话密钥非空", key.length > 0);
    T("全链：双方会话密钥一致", [key isEqualToData:host.sessionKey]);
    T("全链：对端(host)也进入已建立", host.established);
    T("全链：收到 3 条", t.recvCount == 3);
    T("全链：发出 3 条", t.sendCount == 3);
    T("全链：步进回调 6 次", steps.count == 6);
    T("全链：最后一步是已建立", steps.lastObject.integerValue == A2RPPairSetupStepEstablished);
    NSUInteger stepLines = 0;
    for (NSString *l in lines) { if ([l rangeOfString:@"会话步进"].location != NSNotFound) { stepLines++; } }
    T("全链：6 条会话步进行", stepLines == 6);
}

static void TestDriverFailures(void) {
    A2RPPairingIdentity *acc = A2PairWireIdentity(@"acc-fail");
    A2RPPairingIdentity *hst = A2PairWireIdentity(@"host-fail");
    NSString *why = nil;
    A2RPPairSetupDriveFailure fail;

    // ① transport = nil
    fail = A2RPPairSetupDriveFailureNone;
    T("失败：nil 传输被拒",
      ![A2RPPairSetupSession runAccessoryOverTransport:nil identity:acc pin:@"123456"
                                          stepObserver:nil reason:&why failureKind:&fail sessionKey:NULL]
      && fail == A2RPPairSetupDriveFailureTransport);

    // ② 只有 exchange、没有 responder 原语
    A2PairWireExchangeOnlyTransport *exOnly = [[A2PairWireExchangeOnlyTransport alloc] init];
    fail = A2RPPairSetupDriveFailureNone;
    T("失败：缺 responder 原语被如实拒绝",
      ![A2RPPairSetupSession runAccessoryOverTransport:exOnly identity:acc pin:@"123456"
                                          stepObserver:nil reason:&why failureKind:&fail sessionKey:NULL]
      && fail == A2RPPairSetupDriveFailureTransport);

    // ③ 空码
    A2PairWireLoopbackTransport *t0 = [[A2PairWireLoopbackTransport alloc] init];
    t0.hostSession = [A2RPPairSetupSession hostSessionWithIdentity:hst pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
        (void)p; return @"123456";
    } reason:&why];
    fail = A2RPPairSetupDriveFailureNone;
    T("失败：空码 ⇒ PinMissing",
      ![A2RPPairSetupSession runAccessoryOverTransport:t0 identity:acc pin:@""
                                          stepObserver:nil reason:&why failureKind:&fail sessionKey:NULL]
      && fail == A2RPPairSetupDriveFailurePinMissing);

    // ④ 错码（本方码 ≠ 对端码）⇒ 对端证明 M1 不过
    A2RPPairingIdentity *hst4 = A2PairWireIdentity(@"host-wrongpin");
    A2PairWireLoopbackTransport *t4 = [[A2PairWireLoopbackTransport alloc] init];
    t4.hostSession = [A2RPPairSetupSession hostSessionWithIdentity:hst4 pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
        (void)p; return @"654321";
    } reason:&why];
    fail = A2RPPairSetupDriveFailureNone;
    T("失败：错码 ⇒ PeerRejected",
      ![A2RPPairSetupSession runAccessoryOverTransport:t4 identity:acc pin:@"123456"
                                          stepObserver:nil reason:&why failureKind:&fail sessionKey:NULL]
      && fail == A2RPPairSetupDriveFailurePeerRejected);

    // ⑤ 篡改对端第 2 条（PS-Msg03 的 M1）⇒ 同样归到「码不对/被篡改」
    A2RPPairingIdentity *hst5 = A2PairWireIdentity(@"host-tamper");
    A2PairWireLoopbackTransport *t5 = [[A2PairWireLoopbackTransport alloc] init];
    t5.hostSession = [A2RPPairSetupSession hostSessionWithIdentity:hst5 pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
        (void)p; return @"123456";
    } reason:&why];
    t5.tamperReceiveAtIndex = 2;
    fail = A2RPPairSetupDriveFailureNone;
    T("失败：篡改 Msg03 ⇒ PeerRejected",
      ![A2RPPairSetupSession runAccessoryOverTransport:t5 identity:acc pin:@"123456"
                                          stepObserver:nil reason:&why failureKind:&fail sessionKey:NULL]
      && fail == A2RPPairSetupDriveFailurePeerRejected);

    // ⑥ 乱序（第 1 条就是 State=3）
    A2PairWireLoopbackTransport *t6 = [[A2PairWireLoopbackTransport alloc] init];
    t6.hostSession = [A2RPPairSetupSession hostSessionWithIdentity:hst5 pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
        (void)p; return @"123456";
    } reason:&why];
    t6.cannedReceive = A2PairWireStateOnlyTLV(3);
    fail = A2RPPairSetupDriveFailureNone;
    T("失败：乱序 ⇒ Protocol",
      ![A2RPPairSetupSession runAccessoryOverTransport:t6 identity:acc pin:@"123456"
                                          stepObserver:nil reason:&why failureKind:&fail sessionKey:NULL]
      && fail == A2RPPairSetupDriveFailureProtocol);

    // ⑦ 非 TLV
    A2PairWireLoopbackTransport *t7 = [[A2PairWireLoopbackTransport alloc] init];
    t7.hostSession = [A2RPPairSetupSession hostSessionWithIdentity:hst5 pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
        (void)p; return @"123456";
    } reason:&why];
    const uint8_t junk[2] = { 0xFF, 0x00 };
    t7.cannedReceive = [NSData dataWithBytes:junk length:2];
    fail = A2RPPairSetupDriveFailureNone;
    T("失败：非 TLV ⇒ Protocol",
      ![A2RPPairSetupSession runAccessoryOverTransport:t7 identity:acc pin:@"123456"
                                          stepObserver:nil reason:&why failureKind:&fail sessionKey:NULL]
      && fail == A2RPPairSetupDriveFailureProtocol);

    // ⑧ 接收超时（传输给了 lastFailureKind=Timeout）
    A2PairWireLoopbackTransport *t8 = [[A2PairWireLoopbackTransport alloc] init];
    t8.hostSession = [A2RPPairSetupSession hostSessionWithIdentity:hst5 pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
        (void)p; return @"123456";
    } reason:&why];
    t8.failNextReceive = YES;
    t8.injectedKind = A2RPPairSetupTransportFailureTimeout;
    fail = A2RPPairSetupDriveFailureNone;
    T("失败：接收超时 ⇒ TransportTimeout",
      ![A2RPPairSetupSession runAccessoryOverTransport:t8 identity:acc pin:@"123456"
                                          stepObserver:nil reason:&why failureKind:&fail sessionKey:NULL]
      && fail == A2RPPairSetupDriveFailureTransportTimeout);

    // ⑨ 接收格式错
    t8.failNextReceive = YES;
    t8.injectedKind = A2RPPairSetupTransportFailureFormat;
    fail = A2RPPairSetupDriveFailureNone;
    T("失败：接收格式错 ⇒ Protocol",
      ![A2RPPairSetupSession runAccessoryOverTransport:t8 identity:acc pin:@"123456"
                                          stepObserver:nil reason:&why failureKind:&fail sessionKey:NULL]
      && fail == A2RPPairSetupDriveFailureProtocol);

    // ⑩ 不回 lastFailureKind 的传输 ⇒ 只归到 Transport（不假装知道是超时）
    A2PairWireNoKindTransport *noKind = [[A2PairWireNoKindTransport alloc] init];
    fail = A2RPPairSetupDriveFailureNone;
    T("失败：无 lastFailureKind ⇒ Transport",
      ![A2RPPairSetupSession runAccessoryOverTransport:noKind identity:acc pin:@"123456"
                                          stepObserver:nil reason:&why failureKind:&fail sessionKey:NULL]
      && fail == A2RPPairSetupDriveFailureTransport);

    // ⑪ 发送失败
    A2RPPairingIdentity *hst11 = A2PairWireIdentity(@"host-sendfail");
    A2PairWireLoopbackTransport *t11 = [[A2PairWireLoopbackTransport alloc] init];
    t11.hostSession = [A2RPPairSetupSession hostSessionWithIdentity:hst11 pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
        (void)p; return @"123456";
    } reason:&why];
    t11.failNextSend = YES;
    t11.injectedKind = A2RPPairSetupTransportFailureOther;
    fail = A2RPPairSetupDriveFailureNone;
    T("失败：发送失败 ⇒ Transport",
      ![A2RPPairSetupSession runAccessoryOverTransport:t11 identity:acc pin:@"123456"
                                          stepObserver:nil reason:&why failureKind:&fail sessionKey:NULL]
      && fail == A2RPPairSetupDriveFailureTransport);
}

#pragma mark 整条链（广告 → 连入 → 建传输 → 会话 → 交出配对文件）

static void TestChainSuccess(void) {
    A2PairWireFakeListener *listener = [[A2PairWireFakeListener alloc] init];
    listener.streamToReturn = [[A2PairWireFakeStream alloc] init];
    A2PairWireLoopbackTransport *loop = [[A2PairWireLoopbackTransport alloc] init];

    __block NSString *capturedIdentifier = nil;
    A2RPPairSetupAccessoryListenerFactory lf = ^id<A2RPPairSetupAccessoryListener>(NSString *name,
                                                                                  NSString *model,
                                                                                  NSString *identifier,
                                                                                  NSData *altIRK) {
        capturedIdentifier = identifier;
        listener.serviceName = identifier.length > 30 ? [identifier substringToIndex:30] : identifier;
        listener.hostName = @"air2-test.local.";
        return listener;
    };
    A2RPPairSetupAccessoryTransportFactory tf = ^id<A2RPPairSetupMessageTransport>(id<A2RPByteStream> stream,
                                                                                   NSString *hostName,
                                                                                   NSString **reason) {
        (void)stream; (void)hostName; (void)reason;
        NSString *w = nil;
        loop.hostSession = [A2RPPairSetupSession hostSessionWithIdentity:A2PairWireIdentity(@"host-chain")
                                                            pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
            (void)p; return @"135790";
        } reason:&w];
        return loop.hostSession != nil ? loop : nil;
    };

    NSMutableArray<NSNumber *> *phases = [NSMutableArray array];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    A2RPPairSetupAccessoryRun *run =
        [A2RPPairSetupAccessory runWithHostName:@"testiPhone"
                                            pin:@"135790"
                                         budget:10.0
                                listenerFactory:lf
                               transportFactory:tf
                                       observer:^(A2RPPairSetupAccessoryPhase phase, A2RPPairSetupStep step, NSString *line) {
        (void)step;
        [phases addObject:@(phase)];
        [lines addObject:line ?: @""];
    }
                                    isCancelled:nil];

    T("链：成功", run.succeeded);
    T("链：failure None", run.failure == A2RPPairSetupAccessoryFailureNone);
    T("链：配对文件非空", run.pairingFileData.length > 0);
    T("链：identifier 与广告一致", run.identifier.length > 0 && [run.identifier isEqualToString:capturedIdentifier]);
    T("链：已广告（端口非 0）", run.advertised && run.port != 0);
    T("链：已连入", run.connected);
    T("链：走到已建立", run.lastStep == A2RPPairSetupStepEstablished);
    T("链：detail 含「配对成功」", [run.detail rangeOfString:@"配对成功"].location != NSNotFound);
    T("链：authTag 是 6 字节的 base64",
      run.authTagBase64.length > 0
      && [[[NSData alloc] initWithBase64EncodedString:run.authTagBase64 options:0] length] == 6);
    T("链：广告等过一次", listener.advertiseCallCount == 1);
    T("链：广告预算按 0.9 切分", fabs(listener.lastBudget - 9.0) < 0.001);
    T("链：观察者收到 starting", [phases containsObject:@(A2RPPairSetupAccessoryPhaseStarting)]);
    T("链：观察者收到 advertising", [phases containsObject:@(A2RPPairSetupAccessoryPhaseAdvertising)]);
    T("链：观察者收到 connected", [phases containsObject:@(A2RPPairSetupAccessoryPhaseConnected)]);
    T("链：观察者收到 verifying", [phases containsObject:@(A2RPPairSetupAccessoryPhaseVerifying)]);
    T("链：观察者收到 succeeded", [phases containsObject:@(A2RPPairSetupAccessoryPhaseSucceeded)]);
    NSUInteger advLine = 0, connLine = 0, okLine = 0;
    for (NSString *l in lines) {
        if ([l rangeOfString:@"_remotepairing-pairable-host._tcp"].location != NSNotFound
            && [l rangeOfString:@"authTag="].location != NSNotFound) { advLine++; }
        if ([l rangeOfString:@"★被连入★"].location != NSNotFound) { connLine++; }
        if ([l rangeOfString:@"★配对成功★"].location != NSNotFound) { okLine++; }
    }
    T("链：广告判据行含服务名+authTag", advLine >= 1);
    T("链：被连入判据行", connLine == 1);
    T("链：成功判据行", okLine == 1);
}

static void TestChainAdvertiseFailures(void) {
    A2RPPairSetupAccessoryListenerFactory lf = ^id<A2RPPairSetupAccessoryListener>(NSString *name,
                                                                                  NSString *model,
                                                                                  NSString *identifier,
                                                                                  NSData *altIRK) {
        (void)name; (void)model; (void)identifier; (void)altIRK;
        return [[A2PairWireFakeListener alloc] init];   // streamToReturn 为 nil ⇒ 模拟「没人连入」
    };
    A2RPPairSetupAccessoryTransportFactory tf = ^id<A2RPPairSetupMessageTransport>(id<A2RPByteStream> s,
                                                                                   NSString *h,
                                                                                   NSString **r) {
        (void)s; (void)h; (void)r; return nil;
    };

    // ★按通告器的失败分类如实分流（不写万能文案）★
    const A2RPPairableHostFailure cases[] = {
        A2RPPairableHostFailureNoLocalNetworkPermission,
        A2RPPairableHostFailureSuspended,
        A2RPPairableHostFailureTimedOut,
        A2RPPairableHostFailurePublishFailed,
        A2RPPairableHostFailureAcceptFailed,
    };
    const A2RPPairSetupAccessoryFailure expect[] = {
        A2RPPairSetupAccessoryFailureNoLocalNetworkPermission,
        A2RPPairSetupAccessoryFailureSuspended,
        A2RPPairSetupAccessoryFailureWaitTimedOut,
        A2RPPairSetupAccessoryFailurePublishFailed,
        A2RPPairSetupAccessoryFailureAcceptFailed,
    };
    const char *names[] = {
        "链失败：无本地网络权限", "链失败：被挂起", "链失败：等待超时",
        "链失败：发布失败", "链失败：取不出字节通道",
    };
    for (int i = 0; i < 5; i++) {
        A2PairWireFakeListener *ls = [[A2PairWireFakeListener alloc] init];
        ls.injectedFailure = cases[i];
        A2RPPairSetupAccessoryListenerFactory lf2 = ^id<A2RPPairSetupAccessoryListener>(NSString *n2,
                                                                                        NSString *m2,
                                                                                        NSString *id2,
                                                                                        NSData *k2) {
            (void)n2; (void)m2; (void)id2; (void)k2;
            return ls;
        };
        A2RPPairSetupAccessoryRun *run = [A2RPPairSetupAccessory runWithHostName:@"t"
                                                                             pin:@"123456"
                                                                          budget:5.0
                                                                 listenerFactory:lf2
                                                                transportFactory:tf
                                                                        observer:nil
                                                                     isCancelled:nil];
        T(names[i], run.failure == expect[i] && !run.succeeded && run.pairingFileData == nil);
    }

    // 未连入（stream=nil 且分类 None）⇒ PublishFailed（不谎报成成功）
    A2PairWireFakeListener *ls2 = [[A2PairWireFakeListener alloc] init];
    ls2.injectedFailure = A2RPPairableHostFailureNone;
    A2RPPairSetupAccessoryListenerFactory lf3 = ^id<A2RPPairSetupAccessoryListener>(NSString *n3,
                                                                                    NSString *m3,
                                                                                    NSString *id3,
                                                                                    NSData *k3) {
        (void)n3; (void)m3; (void)id3; (void)k3; return ls2;
    };
    A2RPPairSetupAccessoryRun *r3 = [A2RPPairSetupAccessory runWithHostName:@"t" pin:@"123456" budget:5.0
                                                            listenerFactory:lf3 transportFactory:tf
                                                                    observer:nil isCancelled:nil];
    T("链失败：没连入且分类 None ⇒ PublishFailed", r3.failure == A2RPPairSetupAccessoryFailurePublishFailed);
    T("链失败：没连入 ⇒ 未连入/未广告", !r3.connected && !r3.advertised);
}

static void TestChainTransportAndInputFailures(void) {
    A2PairWireFakeListener *ls = [[A2PairWireFakeListener alloc] init];
    ls.streamToReturn = [[A2PairWireFakeStream alloc] init];
    A2RPPairSetupAccessoryListenerFactory lf = ^id<A2RPPairSetupAccessoryListener>(NSString *n,
                                                                                  NSString *m,
                                                                                  NSString *i,
                                                                                  NSData *k) {
        (void)n; (void)m; (void)i; (void)k; return ls;
    };
    A2RPPairSetupAccessoryTransportFactory nilTf = ^id<A2RPPairSetupMessageTransport>(id<A2RPByteStream> s,
                                                                                      NSString *h,
                                                                                      NSString **r) {
        (void)s; (void)h; if (r) { *r = @"注入：传输未建成"; } return nil;
    };
    A2RPPairSetupAccessoryRun *r = [A2RPPairSetupAccessory runWithHostName:@"t" pin:@"123456" budget:5.0
                                                          listenerFactory:lf transportFactory:nilTf
                                                                  observer:nil isCancelled:nil];
    T("链失败：建传输失败 ⇒ TransportFailed", r.failure == A2RPPairSetupAccessoryFailureTransportFailed);
    T("链失败：建传输失败 ⇒ 已连入但无文件", r.connected && r.pairingFileData == nil);

    // 主机名为空 ⇒ 拒绝起广告
    A2RPPairSetupAccessoryRun *r2 = [A2RPPairSetupAccessory runWithHostName:@"" pin:@"123456" budget:5.0
                                                            listenerFactory:lf transportFactory:nilTf
                                                                    observer:nil isCancelled:nil];
    T("链失败：主机名为空 ⇒ PublishFailed", r2.failure == A2RPPairSetupAccessoryFailurePublishFailed);

    // 未注入工厂 ⇒ 拒绝
    A2RPPairSetupAccessoryRun *r3 = [A2RPPairSetupAccessory runWithHostName:@"t" pin:@"123456" budget:5.0
                                                            listenerFactory:nil transportFactory:nil
                                                                    observer:nil isCancelled:nil];
    T("链失败：未注入工厂 ⇒ PublishFailed", r3.failure == A2RPPairSetupAccessoryFailurePublishFailed);
}

static void TestChainWrongPinThroughChain(void) {
    A2PairWireFakeListener *ls = [[A2PairWireFakeListener alloc] init];
    ls.streamToReturn = [[A2PairWireFakeStream alloc] init];
    A2PairWireLoopbackTransport *loop = [[A2PairWireLoopbackTransport alloc] init];
    NSString *w = nil;
    loop.hostSession = [A2RPPairSetupSession hostSessionWithIdentity:A2PairWireIdentity(@"host-chain-wrong")
                                                        pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
        (void)p; return @"999999";   // 用户在设备上输错
    } reason:&w];

    A2RPPairSetupAccessoryRun *run =
        [A2RPPairSetupAccessory runWithHostName:@"t" pin:@"123456" budget:5.0
                                listenerFactory:^id<A2RPPairSetupAccessoryListener>(NSString *n, NSString *m,
                                                                                    NSString *i, NSData *k) {
        (void)n; (void)m; (void)i; (void)k; return ls;
    }
                               transportFactory:^id<A2RPPairSetupMessageTransport>(id<A2RPByteStream> s, NSString *h,
                                                                                   NSString **r) {
        (void)s; (void)h; (void)r; return loop;
    }
                                       observer:nil isCancelled:nil];
    T("链失败：输错码 ⇒ WrongPin", run.failure == A2RPPairSetupAccessoryFailureWrongPin);
    T("链失败：输错码 ⇒ 无配对文件", run.pairingFileData == nil && !run.succeeded);
    T("链失败：输错码 ⇒ detail 点名 class=WrongPin",
      [run.detail rangeOfString:@"WrongPin"].location != NSNotFound);
}

static void TestChainTimeoutThroughChain(void) {
    A2PairWireFakeListener *ls = [[A2PairWireFakeListener alloc] init];
    ls.streamToReturn = [[A2PairWireFakeStream alloc] init];
    A2PairWireLoopbackTransport *loop = [[A2PairWireLoopbackTransport alloc] init];
    NSString *w = nil;
    loop.hostSession = [A2RPPairSetupSession hostSessionWithIdentity:A2PairWireIdentity(@"host-chain-timeout")
                                                        pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
        (void)p; return @"123456";
    } reason:&w];
    loop.failNextReceive = YES;
    loop.injectedKind = A2RPPairSetupTransportFailureTimeout;

    A2RPPairSetupAccessoryRun *run =
        [A2RPPairSetupAccessory runWithHostName:@"t" pin:@"123456" budget:5.0
                                listenerFactory:^id<A2RPPairSetupAccessoryListener>(NSString *n, NSString *m,
                                                                                    NSString *i, NSData *k) {
        (void)n; (void)m; (void)i; (void)k; return ls;
    }
                               transportFactory:^id<A2RPPairSetupMessageTransport>(id<A2RPByteStream> s, NSString *h,
                                                                                   NSString **r) {
        (void)s; (void)h; (void)r; return loop;
    }
                                       observer:nil isCancelled:nil];
    T("链失败：会话中途超时 ⇒ SessionTimedOut", run.failure == A2RPPairSetupAccessoryFailureSessionTimedOut);
}

static void TestChainCancellation(void) {
    A2PairWireFakeListener *ls = [[A2PairWireFakeListener alloc] init];
    ls.streamToReturn = [[A2PairWireFakeStream alloc] init];
    A2RPPairSetupAccessoryListenerFactory lf = ^id<A2RPPairSetupAccessoryListener>(NSString *n, NSString *m,
                                                                                  NSString *i, NSData *k) {
        (void)n; (void)m; (void)i; (void)k; return ls;
    };
    A2RPPairSetupAccessoryTransportFactory tf = ^id<A2RPPairSetupMessageTransport>(id<A2RPByteStream> s, NSString *h,
                                                                                   NSString **r) {
        (void)s; (void)h; (void)r; return nil;
    };

    // ① 一开始就取消
    A2RPPairSetupAccessoryRun *r1 = [A2RPPairSetupAccessory runWithHostName:@"t" pin:@"123456" budget:5.0
                                                           listenerFactory:lf transportFactory:tf
                                                                   observer:nil isCancelled:^BOOL { return YES; }];
    T("取消：立即取消 ⇒ Cancelled", r1.failure == A2RPPairSetupAccessoryFailureCancelled);
    T("取消：立即取消 ⇒ 没起广告", ls.advertiseCallCount == 0);

    // ② 广告之后取消（第 2 次轮询点）
    __block int polls = 0;
    A2RPPairSetupAccessoryRun *r2 = [A2RPPairSetupAccessory runWithHostName:@"t" pin:@"123456" budget:5.0
                                                           listenerFactory:lf transportFactory:tf
                                                                   observer:nil isCancelled:^BOOL {
        polls += 1;
        return polls >= 2;   // 第 1 次（进广告前）不取消，第 2 次（连入后）取消
    }];
    T("取消：连入后取消 ⇒ Cancelled", r2.failure == A2RPPairSetupAccessoryFailureCancelled);
    T("取消：连入后取消 ⇒ 已连入且已退订传输", r2.connected && r2.pairingFileData == nil);
    T("取消：广告确实起过", ls.advertiseCallCount == 2);
}

static void TestChainFileBearingRunFields(void) {
    // 成功一轮的 identifier 必须能与 A2RPPairingIdentity 的配对文件互相对上（同一份字节）。
    A2PairWireFakeListener *ls = [[A2PairWireFakeListener alloc] init];
    ls.streamToReturn = [[A2PairWireFakeStream alloc] init];
    A2PairWireLoopbackTransport *loop = [[A2PairWireLoopbackTransport alloc] init];
    NSString *w = nil;
    loop.hostSession = [A2RPPairSetupSession hostSessionWithIdentity:A2PairWireIdentity(@"host-fields")
                                                        pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
        (void)p; return @"246810";
    } reason:&w];
    A2RPPairSetupAccessoryRun *run =
        [A2RPPairSetupAccessory runWithHostName:@"fieldsHost" pin:@"246810" budget:5.0
                                listenerFactory:^id<A2RPPairSetupAccessoryListener>(NSString *n, NSString *m,
                                                                                    NSString *i, NSData *k) {
        (void)n; (void)m; (void)i; (void)k; return ls;
    }
                               transportFactory:^id<A2RPPairSetupMessageTransport>(id<A2RPByteStream> s, NSString *h,
                                                                                   NSString **r) {
        (void)s; (void)h; (void)r; return loop;
    }
                                       observer:nil isCancelled:nil];
    T("字段：serviceName 是 identifier 截到 ≤30",
      run.serviceName.length > 0 && run.serviceName.length <= 30);
    T("字段：advertisedName 是 Air2 (fieldsHost)",
      [run.advertisedName isEqualToString:@"Air2 (fieldsHost)"]);
    T("字段：hostName 原样带回", [run.hostName isEqualToString:@"fieldsHost"]);
    T("字段：成功那轮 lastStep=Established", run.lastStep == A2RPPairSetupStepEstablished);
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        TestConstants();
        TestDriverSuccess();
        TestDriverFailures();
        TestChainSuccess();
        TestChainAdvertiseFailures();
        TestChainTransportAndInputFailures();
        TestChainWrongPinThroughChain();
        TestChainTimeoutThroughChain();
        TestChainCancellation();
        TestChainFileBearingRunFields();
    }
    printf("\nTOTAL pass=%d fail=%d\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
}
