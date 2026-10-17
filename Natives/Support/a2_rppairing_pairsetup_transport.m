//
//  a2_rppairing_pairsetup_transport.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [A2-RXPC] 传输实现：Network.framework 字节通道（建连 / 被接受）+ RemoteXPC 之上的 pair-setup 传输缝。
//

#import "a2_rppairing_pairsetup_transport.h"
#import "a2_remotexpc_framing.h"
#import "a2_rppairing_pairable_host_wire.h"
#import "a2_log.h"

#import <Network/Network.h>

// ★协议一致性（条件）★：pair-setup 单提供缝定义（a2_rppairing_pairsetup.h）时，
// 本类额外声明遵守该协议。★不存在时本文件照样编译★（方法同签名，见下）。
#if __has_include("a2_rppairing_pairsetup.h")
#import "a2_rppairing_pairsetup.h"
@interface A2RPPairSetupRemoteXPCTransport () <A2RPPairSetupMessageTransport>
/// ★[A2-PAIRWIRE] 缝的可选属性★：由最近一次原语调用的 RemoteXPC 错误分类翻译而来。
@property (nonatomic, readwrite) A2RPPairSetupTransportFailure lastFailureKind;
@end
#endif

#pragma mark - §2a 可用性（如实）

BOOL A2RPPairSetupUSBPathAvailable(NSString **reason) {
    // §2a 的链路是「宿主电脑」的角色：USB → usbmuxd → lockdownd → CoreDeviceProxy（公开规格 §2a）。
    // 在 iOS App 沙盒里：
    //   ① 无法充当 USB 主机 —— 没有 USB 主机控制器权限，也拿不到 usbmuxd 的 socket；
    //   ② 拿不到 lockdownd 的进程通道（那是 host 侧 daemon 的接口）；
    //   ③ 本仓目标是【设备内自配对】（回环：本机既是设备又是可配对宿主），USB 前提根本不存在。
    // ⇒ 如实回 NO，不假装支持、也不提供半成品实现。
    if (reason) {
        *reason = @"§2a 需宿主电脑角色（USB→usbmuxd→lockdownd→CoreDeviceProxy）："
                  @"iOS App 无 USB 主机权限、拿不到 usbmuxd/lockdownd 通道；"
                  @"且本仓目标是设备内回环自配对，USB 前提不存在 ⇒ 本仓如实不支持 §2a";
    }
    return NO;
}

#pragma mark - NWConnection 之上的同步字节通道

@interface A2RPNetworkByteStream ()
@property (nonatomic) nw_connection_t connection;
@property (nonatomic, strong, nullable) id endpoint;      // nw_endpoint_t（保活）
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) BOOL opened;
@property (nonatomic) BOOL closed;
@property (nonatomic, copy, nullable) NSString *peerDescription;
@end

@implementation A2RPNetworkByteStream

+ (instancetype)streamToEndpoint:(id)endpoint reason:(NSString **)reason {
    if (endpoint == nil) {
        if (reason) {
            *reason = @"端点为 nil";
        }
        return nil;
    }
    A2RPNetworkByteStream *s = [[A2RPNetworkByteStream alloc] init];
    s.endpoint = endpoint;
    s.queue = dispatch_queue_create("a2.rxpc.stream", DISPATCH_QUEUE_SERIAL);
    return s;
}

+ (instancetype)streamOverAcceptedConnection:(id)connection {
    A2RPNetworkByteStream *s = [[A2RPNetworkByteStream alloc] init];
    s.connection = (nw_connection_t)connection;
    s.queue = dispatch_queue_create("a2.rxpc.stream.accepted", DISPATCH_QUEUE_SERIAL);
    s.opened = YES;
    s.peerDescription = @"已被接受的连接（pairable-host 被系统连入）";
    return s;
}

- (BOOL)openStreamWithTimeout:(NSTimeInterval)timeout reason:(NSString **)reason error:(A2RemoteXPCErrorKind *)error {
    if (self.closed) {
        if (reason) {
            *reason = @"流已关闭";
        }
        if (error) { *error = A2RemoteXPCErrorCancelled; }
        return NO;
    }
    if (self.opened) {
        return YES;                             // 已被接受的连接：已就绪
    }
    if (self.connection == NULL) {
        if (self.endpoint == nil) {
            if (reason) {
                *reason = @"既没有端点也没有已接受的连接";
            }
            if (error) { *error = A2RemoteXPCErrorNotConnected; }
            return NO;
        }
        nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                                 NW_PARAMETERS_DEFAULT_CONFIGURATION);
        self.connection = nw_connection_create((nw_endpoint_t)self.endpoint, params);
        if (self.connection == NULL) {
            if (reason) {
                *reason = @"nw_connection_create 失败";
            }
            if (error) { *error = A2RemoteXPCErrorConnectFailed; }
            return NO;
        }
    }

    nw_connection_set_queue(self.connection, self.queue);
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block BOOL isReady = NO;
    __block BOOL isDead = NO;
    __block NSString *why = nil;
    nw_connection_set_state_changed_handler(self.connection, ^(nw_connection_state_t state, nw_error_t nwErr) {
        if (state == nw_connection_state_ready) {
            isReady = YES;
            dispatch_semaphore_signal(ready);
        } else if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
            isDead = YES;
            why = [NSString stringWithFormat:@"连接未就绪（state=%d, err=%d）",
                   (int)state, nwErr ? (int)nw_error_get_error_code(nwErr) : 0];
            dispatch_semaphore_signal(ready);
        }
    });
    nw_connection_start(self.connection);

    dispatch_time_t dl = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    dispatch_semaphore_wait(ready, dl);
    if (!isReady) {
        nw_connection_cancel(self.connection);
        self.connection = NULL;
        if (reason) {
            *reason = why ?: [NSString stringWithFormat:@"建连超时（%.1fs）", timeout];
        }
        if (error) {
            *error = isDead ? A2RemoteXPCErrorConnectFailed : A2RemoteXPCErrorConnectTimeout;
        }
        return NO;
    }
    self.opened = YES;
    nw_endpoint_t ep = (nw_endpoint_t)self.endpoint;
    const char *host = ep ? nw_endpoint_get_hostname(ep) : NULL;
    uint16_t port = ep ? nw_endpoint_get_port(ep) : 0;
    self.peerDescription = [NSString stringWithFormat:@"%s:%u", host ?: "?", (unsigned)port];
    return YES;
}

- (BOOL)writeBytes:(NSData *)bytes timeout:(NSTimeInterval)timeout reason:(NSString **)reason error:(A2RemoteXPCErrorKind *)error {
    if (!self.opened || self.connection == NULL) {
        if (reason) {
            *reason = @"流未就绪";
        }
        if (error) { *error = A2RemoteXPCErrorNotConnected; }
        return NO;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block nw_error_t sendErr = NULL;
    dispatch_data_t d = dispatch_data_create(bytes.bytes, bytes.length, self.queue,
                                             DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(self.connection, d, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
                       ^(nw_error_t e) {
        sendErr = e;
        dispatch_semaphore_signal(done);
    });
    dispatch_time_t dl = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    dispatch_semaphore_wait(done, dl);
    if (sendErr != NULL) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"写失败（err=%d）",
                       (int)nw_error_get_error_code(sendErr)];
        }
        if (error) { *error = A2RemoteXPCErrorSendFailed; }
        return NO;
    }
    return YES;
}

- (NSData *)readBytesWithTimeout:(NSTimeInterval)timeout reason:(NSString **)reason error:(A2RemoteXPCErrorKind *)error {
    if (!self.opened || self.connection == NULL) {
        if (reason) {
            *reason = @"流未就绪";
        }
        if (error) { *error = A2RemoteXPCErrorNotConnected; }
        return nil;
    }
    dispatch_semaphore_t got = dispatch_semaphore_create(0);
    __block NSData *chunk = nil;
    __block BOOL peerGone = NO;
    nw_connection_receive(self.connection, 1, 65536,
                          ^(dispatch_data_t content, nw_content_context_t ctx,
                            bool isComplete, nw_error_t e) {
        (void)ctx;
        (void)isComplete;
        if (e != NULL) {
            peerGone = YES;
        } else if (content != NULL) {
            // ★不依赖 dispatch_data ↔ NSData 桥接★：逐 region 拷出。
            NSMutableData *acc = [NSMutableData data];
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset,
                                               const void *buf, size_t size) {
                (void)region;
                (void)offset;
                [acc appendBytes:buf length:size];
                return true;
            });
            chunk = acc;
        }
        dispatch_semaphore_signal(got);
    });
    dispatch_time_t dl = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    dispatch_semaphore_wait(got, dl);
    if (chunk == nil) {
        if (peerGone) {
            if (reason) {
                *reason = @"对端关闭了连接";
            }
            if (error) { *error = A2RemoteXPCErrorPeerClosed; }
        } else {
            if (reason) {
                *reason = [NSString stringWithFormat:@"读超时（%.1fs）", timeout];
            }
            if (error) { *error = A2RemoteXPCErrorReceiveTimeout; }
        }
        return nil;
    }
    return chunk;
}

- (void)closeStream {
    if (self.closed) {
        return;
    }
    self.closed = YES;
    if (self.connection != NULL) {
        nw_connection_cancel(self.connection);
    }
}

@end

#pragma mark - 缝：RemoteXPC 之上的 pair-setup 传输

@interface A2RPPairSetupRemoteXPCTransport ()
@property (nonatomic, strong) A2RemoteXPCSession *session;
@property (nonatomic, copy) NSString *hostName;
@property (nonatomic, copy) NSString *originatedBy;
/// ★[A2-PAIRWIRE] 最近一次原语调用的 RemoteXPC 错误分类★（翻成缝的 lastFailureKind）。
@property (nonatomic) A2RemoteXPCErrorKind lastRemoteXPCError;
@end

@implementation A2RPPairSetupRemoteXPCTransport

+ (instancetype)transportOverByteStream:(id<A2RPByteStream>)stream
                               hostName:(NSString *)hostName
                            wireVersion:(NSUInteger)wireVersion
                                timeout:(NSTimeInterval)timeout
                                 reason:(NSString **_Nullable)reason
                                  error:(A2RemoteXPCErrorKind *)errorOut {
    // ★既有语义不变★：本方法恒以 originatedBy="host" 构造（就是它原来的行为）。
    return [self transportOverByteStream:stream
                            originatedBy:@"host"
                                hostName:hostName
                             wireVersion:wireVersion
                                 timeout:timeout
                                  reason:reason
                                   error:errorOut];
}

+ (instancetype)transportOverByteStream:(id<A2RPByteStream>)stream
                           originatedBy:(NSString *)originatedBy
                               hostName:(NSString *)hostName
                            wireVersion:(NSUInteger)wireVersion
                                timeout:(NSTimeInterval)timeout
                                 reason:(NSString **_Nullable)reason
                                  error:(A2RemoteXPCErrorKind *)errorOut {
    if (stream == nil) {
        if (reason) {
            *reason = @"字节通道为 nil";
        }
        if (errorOut) { *errorOut = A2RemoteXPCErrorNotConnected; }
        return nil;
    }
    NSString *by = originatedBy.length > 0 ? originatedBy : @"host";
    A2RemoteXPCSession *session =
        [[A2RemoteXPCSession alloc] initWithStream:stream
                               wireProtocolVersion:wireVersion
                                      originatedBy:by];
    NSString *why = nil;
    A2RemoteXPCErrorKind err = A2RemoteXPCErrorNone;
    if (![session connectAndHandshakeWithTimeout:timeout reason:&why error:&err]) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"RemoteXPC 建连/握手失败（class=%@）：%@",
                       A2RemoteXPCErrorKindName(err), why ?: @"原因未记录"];
        }
        if (errorOut) { *errorOut = err; }
        return nil;
    }
    A2RPPairSetupRemoteXPCTransport *t = [[A2RPPairSetupRemoteXPCTransport alloc] init];
    t.session = session;
    t.hostName = [hostName copy] ?: @"air2-rppairing";
    t.originatedBy = by;
    t.lastRemoteXPCError = A2RemoteXPCErrorNone;
    A2RXPCLog([NSString stringWithFormat:@"传输就绪 路径=RemoteXPC(§2a/§2b) 角色=%@ 主机名=%@ wire=%lu",
               by, t.hostName, (unsigned long)wireVersion]);
    return t;
}

- (BOOL)awaitingUserConsentObserved {
    return self.session.observedAwaitingUserConsent;
}

- (BOOL)transportObservedAwaitingUserConsent {
    return self.session.observedAwaitingUserConsent;
}

- (NSData *)exchangePairingData:(NSData *)tlv
                           kind:(NSString *)kind
                       startNew:(BOOL)startNewSession
                         reason:(NSString **)reason {
    if (self.session == nil) {
        if (reason) {
            *reason = @"传输未就绪（会话为 nil）";
        }
        self.lastRemoteXPCError = A2RemoteXPCErrorNotConnected;
        return nil;
    }
    A2RemoteXPCErrorKind err = A2RemoteXPCErrorNone;
    NSString *why = nil;
    NSData *out = [self.session exchangePairingData:tlv
                                               kind:kind
                                           startNew:startNewSession
                                             reason:&why
                                              error:&err];
    self.lastRemoteXPCError = (out != nil) ? A2RemoteXPCErrorNone : err;
    if (out == nil && reason) {
        *reason = [NSString stringWithFormat:@"交换失败（class=%@）：%@",
                   A2RemoteXPCErrorKindName(err), why ?: @"原因未记录"];
    }
    return out;
}

#pragma mark - [A2-PAIRWIRE] 响应方（accessory）原语

- (BOOL)sendPairingData:(NSData *)tlv
                   kind:(NSString *)kind
               startNew:(BOOL)startNewSession
                 reason:(NSString **)reason {
    if (self.session == nil) {
        if (reason) {
            *reason = @"传输未就绪（会话为 nil）";
        }
        self.lastRemoteXPCError = A2RemoteXPCErrorNotConnected;
        return NO;
    }
    A2RemoteXPCErrorKind err = A2RemoteXPCErrorNone;
    NSString *why = nil;
    BOOL ok = [self.session sendPairingData:tlv
                                       kind:kind
                                   startNew:startNewSession
                                     reason:&why
                                      error:&err];
    self.lastRemoteXPCError = ok ? A2RemoteXPCErrorNone : err;
    if (!ok && reason) {
        *reason = [NSString stringWithFormat:@"发送失败（class=%@）：%@",
                   A2RemoteXPCErrorKindName(err), why ?: @"原因未记录"];
    }
    return ok;
}

- (NSData *)receivePairingDataWithKind:(NSString *)kind
                               timeout:(NSTimeInterval)timeout
                                reason:(NSString **)reason {
    if (self.session == nil) {
        if (reason) {
            *reason = @"传输未就绪（会话为 nil）";
        }
        self.lastRemoteXPCError = A2RemoteXPCErrorNotConnected;
        return nil;
    }
    A2RemoteXPCErrorKind err = A2RemoteXPCErrorNone;
    NSString *why = nil;
    NSData *in = [self.session receivePairingDataWithKind:kind
                                                  timeout:timeout
                                                   reason:&why
                                                    error:&err];
    self.lastRemoteXPCError = (in != nil) ? A2RemoteXPCErrorNone : err;
    if (in == nil && reason) {
        *reason = [NSString stringWithFormat:@"接收失败（class=%@）：%@",
                   A2RemoteXPCErrorKindName(err), why ?: @"原因未记录"];
    }
    return in;
}

#if __has_include("a2_rppairing_pairsetup.h")
/// 把 RemoteXPC 的错误分类翻成缝的失败分类（★可选属性 lastFailureKind 的取值口径★）。
static A2RPPairSetupTransportFailure A2RPPWMapRemoteXPCError(A2RemoteXPCErrorKind k) {
    switch (k) {
        case A2RemoteXPCErrorNone:               return A2RPPairSetupTransportFailureNone;
        case A2RemoteXPCErrorReceiveTimeout:
        case A2RemoteXPCErrorConnectTimeout:
        case A2RemoteXPCErrorHandshakeTimeout:   return A2RPPairSetupTransportFailureTimeout;
        case A2RemoteXPCErrorPeerClosed:         return A2RPPairSetupTransportFailurePeerClosed;
        case A2RemoteXPCErrorFrameFormat:
        case A2RemoteXPCErrorXPCDecode:          return A2RPPairSetupTransportFailureFormat;
        default:                                 return A2RPPairSetupTransportFailureOther;
    }
}

- (A2RPPairSetupTransportFailure)lastFailureKind {
    return A2RPPWMapRemoteXPCError(self.lastRemoteXPCError);
}
#endif

- (void)close {
    [self.session close];
}

@end

#pragma mark - ★[A2-PAIRPIN] pairable-host 连接上的 JSON 传输★

#if __has_include("a2_rppairing_pairsetup.h")

/// 一帧最多跳过的无关帧数（防止对端用无意义事件把我们锁死在循环里）。
#define A2RPPW_MAX_SKIPPED_FRAMES 8

/// 从 TLV8 里读出 State（0x06）；读不到 ⇒ -1。★只读前若干条目，不做完整解码★。
static int A2RPPWStateOfTLV(NSData *tlv) {
    if (tlv.length < 3) {
        return -1;
    }
    const uint8_t *b = (const uint8_t *)tlv.bytes;
    NSUInteger n = tlv.length;
    NSUInteger i = 0;
    while (i + 2 <= n) {
        uint8_t type = b[i];
        uint8_t len = b[i + 1];
        if (i + 2 + (NSUInteger)len > n) {
            break;
        }
        if (type == 0x06 && len >= 1) {
            return (int)b[i + 2];
        }
        i += 2 + (NSUInteger)len;
    }
    return -1;
}

@interface A2RPPairSetupPairableHostJSONTransport () <A2RPPairSetupMessageTransport>
@property (nonatomic, strong, nullable) id<A2RPByteStream> stream;
@property (nonatomic, copy) NSString *hostName;
/// 已收但尚未消费的字节（底层 read 是「能读多少读多少」⇒ 必须自己攒帧）。
@property (nonatomic, strong) NSMutableData *rxBuffer;
/// 已解出、但当前调用用不上的信封载荷（例如握手前就到了的 M1）。
@property (nonatomic, strong) NSMutableArray<id> *pendingValues;
/// 本侧自己的发送序号（对端另有自己的；错开是正常的）。
@property (nonatomic) NSUInteger txSequenceNumber;
@property (nonatomic, readwrite) BOOL handshakeCompleted;
@property (nonatomic, readwrite, copy, nullable) NSData *firstBytes;
@property (nonatomic) BOOL sawAnyBytes;
@property (nonatomic, copy, nullable) NSArray<NSString *> *txtKeys;
@property (nonatomic, copy) NSString *advertisedName;
@property (nonatomic, copy) NSString *model;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic) NSUInteger wireVersion;
@property (nonatomic, readwrite) A2RPPairSetupTransportFailure lastFailureKind;
@end

@implementation A2RPPairSetupPairableHostJSONTransport

+ (instancetype)transportWithStream:(id<A2RPByteStream>)stream hostName:(NSString *)hostName {
    if (stream == nil) {
        return nil;
    }
    A2RPPairSetupPairableHostJSONTransport *t = [[self alloc] init];
    t.stream = stream;
    t.hostName = [hostName copy] ?: @"air2-rppairing";
    t.rxBuffer = [NSMutableData data];
    t.pendingValues = [NSMutableArray array];
    t.txSequenceNumber = 0;
    t.advertisedName = @"Air2";
    t.model = @"Mac17,7";
    t.identifier = @"";
    t.wireVersion = 26;
    t.lastFailureKind = A2RPPairSetupTransportFailureNone;
    return t;
}

#pragma mark 判据行

/// 打一行 `[A2-PAIRPIN] stage=… txKeys=… firstBytes=… m2=ok|fail reason=…`
/// ★这是本单要求的机器判据★：真机日志里一眼看出卡在哪一步
/// （`firstBytes=` 若不是 `525050616972696E67`=`RPPairing` ⇒ 根本不是这条线）。
- (void)logStage:(NSString *)stage m2Sent:(BOOL)m2Sent reason:(NSString *)reason {
    a2_log_criterion(@"%@", A2RPPHWCriterionLine(stage, self.txtKeys, self.firstBytes, m2Sent, reason));
}

#pragma mark 读写

/// 把整帧写出。失败 ⇒ 分类 + reason。
- (BOOL)writeFrame:(NSData *)frame reason:(NSString **)reason {
    if (self.stream == nil) {
        self.lastFailureKind = A2RPPairSetupTransportFailurePeerClosed;
        if (reason) { *reason = @"字节通道已释放"; }
        return NO;
    }
    NSString *why = nil;
    A2RemoteXPCErrorKind err = A2RemoteXPCErrorNone;
    if (![self.stream writeBytes:frame timeout:10.0 reason:&why error:&err]) {
        self.lastFailureKind = A2RPPairSetupTransportFailurePeerClosed;
        if (reason) { *reason = why ?: @"写帧失败"; }
        return NO;
    }
    return YES;
}

/// 攒够一帧并交出 JSON 负载（★不含 magic/长度★）。
- (NSData *)takeFramePayloadWithTimeout:(NSTimeInterval)timeout reason:(NSString **)reason {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(0.1, timeout)];
    for (;;) {
        if (self.rxBuffer.length >= 11) {
            NSUInteger need = 0;
            NSString *hwhy = nil;
            if (!A2RPPHWDecodeFrameHeader(self.rxBuffer, &need, &hwhy)) {
                self.lastFailureKind = A2RPPairSetupTransportFailureFormat;
                if (reason) { *reason = hwhy ?: @"帧头不符"; }
                return nil;
            }
            if (self.rxBuffer.length >= 11 + need) {
                NSData *payload = [self.rxBuffer subdataWithRange:NSMakeRange(11, need)];
                [self.rxBuffer replaceBytesInRange:NSMakeRange(0, 11 + need) withBytes:NULL length:0];
                return payload;
            }
        }
        NSTimeInterval remain = [deadline timeIntervalSinceNow];
        if (remain <= 0) {
            self.lastFailureKind = A2RPPairSetupTransportFailureTimeout;
            if (reason) { *reason = [NSString stringWithFormat:@"等帧超时（已有 %lu 字节）",
                                      (unsigned long)self.rxBuffer.length]; }
            return nil;
        }
        NSString *why = nil;
        A2RemoteXPCErrorKind err = A2RemoteXPCErrorNone;
        NSData *chunk = [self.stream readBytesWithTimeout:remain reason:&why error:&err];
        if (chunk.length == 0) {
            self.lastFailureKind = (err == A2RemoteXPCErrorReceiveTimeout)
                ? A2RPPairSetupTransportFailureTimeout
                : A2RPPairSetupTransportFailurePeerClosed;
            if (reason) { *reason = why ?: @"读不到数据"; }
            return nil;
        }
        if (!self.sawAnyBytes) {
            self.sawAnyBytes = YES;
            self.firstBytes = chunk;                 // ★只留第一段，判据行用★
        }
        [self.rxBuffer appendData:chunk];
    }
}

/// 读一帧并解信封；返回整条信封，*outPlain 取 `message.plain._0`。
- (NSDictionary *)readEnvelopeWithTimeout:(NSTimeInterval)timeout
                                   plain:(id *)outPlain
                                  reason:(NSString **)reason {
    NSData *payload = [self takeFramePayloadWithTimeout:timeout reason:reason];
    if (payload == nil) {
        return nil;
    }
    NSString *why = nil;
    id plain = nil;
    NSDictionary *env = A2RPPHWDecodeEnvelope(payload, &plain, &why);
    if (env == nil) {
        self.lastFailureKind = A2RPPairSetupTransportFailureFormat;
        if (reason) { *reason = why ?: @"信封不是合法 JSON"; }
        return nil;
    }
    if (outPlain) {
        *outPlain = plain;
    }
    return env;
}

/// 回握手响应（★`allowsPinlessPairing=NO` 就在这里声明★）。
- (BOOL)answerHandshakeRequest:(id)plain reason:(NSString **)reason {
    if (A2RPPHWHandshakeWantsPairVerify(plain)) {
        self.lastFailureKind = A2RPPairSetupTransportFailureOther;
        if (reason) {
            *reason = @"设备握手请求里 hostOptions.attemptPairVerify=true —— "
                      @"本侧只支持设备发起的 pair-setup，不支持 pair-verify（不假装能继续）";
        }
        [self logStage:@"handshake" m2Sent:NO reason:@"device-requested-pair-verify(unsupported)"];
        return NO;
    }
    NSDictionary *response = A2RPPHWHandshakeResponse(self.advertisedName, self.model,
                                                     self.identifier, @"", self.wireVersion);
    NSString *why = nil;
    NSData *json = A2RPPHWEncodeEnvelope(response, A2RPPHWOriginatedByAccessory,
                                         self.txSequenceNumber, &why);
    if (json == nil) {
        self.lastFailureKind = A2RPPairSetupTransportFailureFormat;
        if (reason) { *reason = why ?: @"握手响应序列化失败"; }
        return NO;
    }
    NSData *frame = A2RPPHWEncodeFrame(json, &why);
    if (frame == nil) {
        self.lastFailureKind = A2RPPairSetupTransportFailureFormat;
        if (reason) { *reason = why ?: @"握手响应装帧失败"; }
        return NO;
    }
    if (![self writeFrame:frame reason:reason]) {
        [self logStage:@"handshake" m2Sent:NO reason:@"write-handshake-response-failed"];
        return NO;
    }
    self.txSequenceNumber += 1;
    [self logStage:@"handshake" m2Sent:NO
           reason:[NSString stringWithFormat:
                   @"handshake-response-sent(seq=%lu, allowsPairSetup=YES, allowsPinlessPairing=NO)…"
                   @"下一步等设备 M1", (unsigned long)(self.txSequenceNumber - 1)]];
    return YES;
}

#pragma mark beginSession

- (BOOL)beginSessionWithName:(NSString *)name
                       model:(NSString *)model
                  identifier:(NSString *)identifier
                 wireVersion:(NSUInteger)wireVersion
                     txtKeys:(NSArray<NSString *> *)txtKeys
                     timeout:(NSTimeInterval)timeout
                      reason:(NSString **)reason {
    self.advertisedName = name.length > 0 ? name : self.advertisedName;
    self.model = model.length > 0 ? model : self.model;
    self.identifier = identifier ?: @"";
    self.wireVersion = wireVersion;
    self.txtKeys = txtKeys;

    if (self.stream == nil || ![self.stream openStreamWithTimeout:timeout reason:reason error:NULL]) {
        self.lastFailureKind = A2RPPairSetupTransportFailurePeerClosed;
        [self logStage:@"handshake" m2Sent:NO reason:@"stream-not-open"];
        return NO;
    }

    id plain = nil;
    NSString *why = nil;
    NSDictionary *env = [self readEnvelopeWithTimeout:timeout plain:&plain reason:&why];
    if (env == nil) {
        // ★最常见的失败就在这里★：对端第一段字节不是 `RPPairing`（例如它等 RemoteXPC 前导）。
        [self logStage:@"handshake" m2Sent:NO
               reason:[NSString stringWithFormat:@"no-handshake-frame(%@)", why ?: @"原因未记录"]];
        if (reason) { *reason = why ?: @"收不到握手请求帧"; }
        return NO;
    }

    if (A2RPPHWIsHandshakeRequest(plain)) {
        if (![self answerHandshakeRequest:plain reason:reason]) {
            return NO;
        }
    } else if (A2RPPHWIsPairingDataEvent(plain)) {
        // 有的实现对端省掉握手直接发 M1 ⇒ 别丢，留给第一次 receive。
        [self.pendingValues addObject:plain];
        [self logStage:@"handshake" m2Sent:NO
               reason:@"no-handshake-request(m1-kept, 对端直接进入 pair-setup)"];
    } else {
        self.lastFailureKind = A2RPPairSetupTransportFailureFormat;
        [self logStage:@"handshake" m2Sent:NO reason:@"first-frame-neither-handshake-nor-pairingData"];
        if (reason) { *reason = @"对端第一帧既不是握手请求也不是 pairingData"; }
        return NO;
    }
    self.handshakeCompleted = YES;
    return YES;
}

#pragma mark 缝原语

- (NSData *)receivePairingDataWithKind:(NSString *)kind
                               timeout:(NSTimeInterval)timeout
                                reason:(NSString **)reason {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(0.1, timeout)];
    for (NSUInteger guard = 0; guard < A2RPPW_MAX_SKIPPED_FRAMES; guard++) {
        id plain = nil;
        if (self.pendingValues.count > 0) {
            plain = self.pendingValues.firstObject;
            [self.pendingValues removeObjectAtIndex:0];
        } else {
            NSTimeInterval remain = [deadline timeIntervalSinceNow];
            if (remain <= 0) {
                self.lastFailureKind = A2RPPairSetupTransportFailureTimeout;
                if (reason) { *reason = @"等 pairingData 超时"; }
                return nil;
            }
            NSString *why = nil;
            if ([self readEnvelopeWithTimeout:remain plain:&plain reason:&why] == nil) {
                if (reason) { *reason = why ?: @"收帧失败"; }
                return nil;
            }
        }

        if (A2RPPHWIsPairingDataEvent(plain)) {
            NSString *why = nil;
            NSString *evKind = nil;
            NSData *tlv = A2RPPHWPairingDataFromEvent(plain, &evKind, &why);
            if (tlv == nil) {
                self.lastFailureKind = A2RPPairSetupTransportFailureFormat;
                if (reason) { *reason = why ?: @"pairingData 负载不可解"; }
                return nil;
            }
            int state = A2RPPWStateOfTLV(tlv);
            if (state > 0 && (state % 2) == 1) {
                [self logStage:[NSString stringWithFormat:@"m%d", state] m2Sent:NO
                       reason:[NSString stringWithFormat:@"recv-M%d(tlv=%luB, kind=%@)",
                               state, (unsigned long)tlv.length, evKind ?: kind ?: @"?"]];
            }
            return tlv;
        }

        if (A2RPPHWIsHandshakeRequest(plain)) {
            NSString *why = nil;
            if (![self answerHandshakeRequest:plain reason:&why]) {
                if (reason) { *reason = why ?: @"重复握手请求处理失败"; }
                return nil;
            }
            continue;
        }

        A2RXPCLog([NSString stringWithFormat:@"[A2-PAIRPIN] 跳过一帧无关事件（%lu 字节 JSON）",
                   (unsigned long)[[plain description] length]]);
    }
    self.lastFailureKind = A2RPPairSetupTransportFailureFormat;
    if (reason) { *reason = @"连续无关帧过多，放弃（不无限空转）"; }
    return nil;
}

- (BOOL)sendPairingData:(NSData *)tlv
                   kind:(NSString *)kind
               startNew:(BOOL)startNewSession
                 reason:(NSString **)reason {
    if (tlv.length == 0) {
        self.lastFailureKind = A2RPPairSetupTransportFailureFormat;
        if (reason) { *reason = @"待发 pairingData 为空"; }
        return NO;
    }
    NSDictionary *value = A2RPPHWEncodePairingDataEvent([tlv base64EncodedStringWithOptions:0],
                                                       kind, startNewSession);
    NSString *why = nil;
    NSData *json = A2RPPHWEncodeEnvelope(value, A2RPPHWOriginatedByAccessory,
                                         self.txSequenceNumber, &why);
    if (json == nil) {
        self.lastFailureKind = A2RPPairSetupTransportFailureFormat;
        if (reason) { *reason = why ?: @"pairingData 信封序列化失败"; }
        return NO;
    }
    NSData *frame = A2RPPHWEncodeFrame(json, &why);
    if (frame == nil) {
        self.lastFailureKind = A2RPPairSetupTransportFailureFormat;
        if (reason) { *reason = why ?: @"pairingData 装帧失败"; }
        return NO;
    }
    if (![self writeFrame:frame reason:reason]) {
        [self logStage:@"send" m2Sent:NO reason:@"write-pairingData-failed"];
        return NO;
    }
    self.txSequenceNumber += 1;

    int state = A2RPPWStateOfTLV(tlv);
    if (state > 0 && (state % 2) == 0) {
        BOOL isM2 = (state == 2);
        NSString *sentWhy = isM2
            ? @"sent-M2(state=2, salt+B)——设备收到这一帧之后才弹「输 6 位码」"
            : [NSString stringWithFormat:@"sent-M%d(tlv=%luB)", state, (unsigned long)tlv.length];
        [self logStage:[NSString stringWithFormat:@"m%d", state] m2Sent:isM2 reason:sentWhy];
    }
    return YES;
}

- (NSData *)exchangePairingData:(NSData *)tlv
                           kind:(NSString *)kind
                       startNew:(BOOL)startNewSession
                         reason:(NSString **)reason {
    if (![self sendPairingData:tlv kind:kind startNew:startNewSession reason:reason]) {
        return nil;
    }
    return [self receivePairingDataWithKind:kind timeout:30.0 reason:reason];
}

- (BOOL)transportObservedAwaitingUserConsent {
    return NO;   // 设备发起配对没有「等设备同意」这一段（那是 Host 侧先行配对的语义）
}

- (void)close {
    [self.stream closeStream];
    self.stream = nil;
}

@end

#endif  // __has_include("a2_rppairing_pairsetup.h") —— [A2-PAIRPIN] JSON 传输
