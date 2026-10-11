//
//  a2_rppairing_pairable_host.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [A2-RXPC] iOS 27 设备发起配对：pairable-host 的通告契约（authTag/TXT）+ NWListener 真广告/真接受 + 判据行。
//

#import "a2_rppairing_pairable_host.h"
#import "a2_rppairing_pairsetup_transport.h"
#import "a2_rppairing_rsd.h"          // ★复用★服务类型常量 A2RPRSDServicePairableHost（不另造）
#import "a2_remotexpc_framing.h"
#import "a2_log.h"

#import <Network/Network.h>
#import <Security/Security.h>
#import <errno.h>

#pragma mark - SipHash-2-4（公开规格/实现口径；用公开测试向量自证）

static uint64_t A2RXpcRotl(uint64_t x, int b) {
    return (x << b) | (x >> (64 - b));
}

#define A2RXPC_SIPROUND()                              \
    do {                                               \
        v0 += v1; v1 = A2RXpcRotl(v1, 13); v1 ^= v0;   \
        v0 = A2RXpcRotl(v0, 32);                       \
        v2 += v3; v3 = A2RXpcRotl(v3, 16); v3 ^= v2;   \
        v0 += v3; v3 = A2RXpcRotl(v3, 21); v3 ^= v0;   \
        v2 += v1; v1 = A2RXpcRotl(v1, 17); v1 ^= v2;   \
        v2 = A2RXpcRotl(v2, 32);                       \
    } while (0)

uint64_t A2RPSipHash24WithKey16(const uint8_t key[A2RPPairableHostAltIRKBytes],
                                const void *bytes, size_t length) {
    uint64_t k0 = 0;
    uint64_t k1 = 0;
    for (int i = 0; i < 8; i++) {
        k0 |= ((uint64_t)key[i]) << (8 * i);
        k1 |= ((uint64_t)key[8 + i]) << (8 * i);
    }
    uint64_t v0 = 0x736f6d6570736575ULL ^ k0;
    uint64_t v1 = 0x646f72616e646f6dULL ^ k1;
    uint64_t v2 = 0x6c7967656e657261ULL ^ k0;
    uint64_t v3 = 0x7465646279746573ULL ^ k1;

    const uint8_t *p = (const uint8_t *)bytes;
    size_t n = length;
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        uint64_t m = 0;
        for (int j = 0; j < 8; j++) {
            m |= ((uint64_t)p[i + j]) << (8 * j);
        }
        v3 ^= m;
        A2RXPC_SIPROUND();
        A2RXPC_SIPROUND();
        v0 ^= m;
    }
    uint64_t last = ((uint64_t)(n & 0xff)) << 56;
    for (size_t j = 0; j + i < n; j++) {
        last |= ((uint64_t)p[i + j]) << (8 * j);
    }
    v3 ^= last;
    A2RXPC_SIPROUND();
    A2RXPC_SIPROUND();
    v0 ^= last;
    v2 ^= 0xff;
    A2RXPC_SIPROUND();
    A2RXPC_SIPROUND();
    A2RXPC_SIPROUND();
    A2RXPC_SIPROUND();
    return v0 ^ v1 ^ v2 ^ v3;
}

#undef A2RXPC_SIPROUND

NSData *A2RPPairableHostAuthTag(NSData *altIRK, NSString *serviceIdentifier) {
    if (altIRK.length != A2RPPairableHostAltIRKBytes || serviceIdentifier.length == 0) {
        return nil;
    }
    NSData *ident = [serviceIdentifier dataUsingEncoding:NSUTF8StringEncoding];
    if (ident == nil) {
        return nil;
    }
    uint64_t h = A2RPSipHash24WithKey16((const uint8_t *)altIRK.bytes, ident.bytes, ident.length);
    uint8_t le[8];
    for (int i = 0; i < 8; i++) {
        le[i] = (uint8_t)((h >> (8 * i)) & 0xFF);
    }
    uint8_t tag[6];
    for (int i = 0; i < 6; i++) {
        tag[i] = le[5 - i];                 // ★取前 6 字节并逆序★
    }
    return [NSData dataWithBytes:tag length:sizeof(tag)];
}

NSData *A2RPPairableHostFreshAltIRK(void) {
    uint8_t buf[A2RPPairableHostAltIRKBytes];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(buf), buf) != errSecSuccess) {
        return nil;
    }
    return [NSData dataWithBytes:buf length:sizeof(buf)];
}

NSString *A2RPPairableHostServiceName(NSString *identifier) {
    NSString *s = identifier ?: @"";
    if (s.length > A2RPPairableHostServiceNameMaxLength) {
        return [s substringToIndex:A2RPPairableHostServiceNameMaxLength];
    }
    return s;
}

NSDictionary<NSString *, NSString *> *A2RPPairableHostTXTRecords(NSString *name,
                                                                 NSString *model,
                                                                 NSString *identifier,
                                                                 NSData *altIRK) {
    NSData *tag = A2RPPairableHostAuthTag(altIRK, identifier);
    NSString *authTagB64 = tag != nil ? [tag base64EncodedStringWithOptions:0] : @"";
    return @{
        @"name":       name ?: @"",
        @"identifier": identifier ?: @"",
        @"authTag":    authTagB64,
        @"model":      model ?: @"",
        @"flags":      @"1",
        @"ver":        [NSString stringWithFormat:@"%d", A2RPPairableHostWireProtocolVersion],
        @"minVer":     @"17",
    };
}

NSString *A2RPPairableHostFailureName(A2RPPairableHostFailure failure) {
    switch (failure) {
        case A2RPPairableHostFailureNone:                      return @"None";
        case A2RPPairableHostFailureNoLocalNetworkPermission:  return @"NoLocalNetworkPermission";
        case A2RPPairableHostFailureSuspended:                 return @"Suspended";
        case A2RPPairableHostFailureTimedOut:                  return @"TimedOut";
        case A2RPPairableHostFailureKeyRotated:                return @"KeyRotated";
        case A2RPPairableHostFailurePublishFailed:             return @"PublishFailed";
        case A2RPPairableHostFailureAcceptFailed:              return @"AcceptFailed";
    }
    return [NSString stringWithFormat:@"Unknown(%ld)", (long)failure];
}

#pragma mark - 通告器

@interface A2RPPairableHostAdvertiser ()
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *model;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSData *altIRK;
@property (nonatomic) nw_listener_t listener;
@property (nonatomic, strong, nullable) id acceptedConnection;   // nw_connection_t（保活）
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) BOOL advertising;
@property (nonatomic) uint16_t port;
@property (nonatomic) BOOL systemSawService;
@property (nonatomic) BOOL observedWaitingState;
@property (nonatomic) A2RPPairableHostFailure failure;
@property (nonatomic, copy, nullable) NSString *failureReason;
@property (nonatomic, copy) NSString *serviceName;
@property (nonatomic, copy) NSString *hostName;
@end

@implementation A2RPPairableHostAdvertiser

- (instancetype)initWithName:(NSString *)name
                       model:(NSString *)model
                  identifier:(NSString *)identifier
                      altIRK:(NSData *)altIRK {
    self = [super init];
    if (self) {
        _name = [name copy] ?: @"Air2";
        _model = [model copy] ?: @"Mac17,7";
        _identifier = [identifier copy] ?: @"";
        _altIRK = [altIRK copy] ?: [NSData data];
        _serviceName = A2RPPairableHostServiceName(_identifier);
        NSString *prefix = _identifier.length >= 8 ? [_identifier substringToIndex:8] : _identifier;
        _hostName = [NSString stringWithFormat:@"air2-%@.local.", prefix];
        _queue = dispatch_queue_create("a2.rppairing.pairablehost", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (id<A2RPByteStream>)advertiseAndWaitForDeviceWithBudget:(NSTimeInterval)budget
                                                   reason:(NSString **)reason {
    if (self.altIRK.length != A2RPPairableHostAltIRKBytes) {
        if (reason) {
            *reason = @"altIRK 不是 16 字节 ⇒ 无法计算 authTag，拒绝广告";
        }
        self.failure = A2RPPairableHostFailurePublishFailed;
        self.failureReason = *reason;
        return nil;
    }
    if (self.identifier.length == 0) {
        if (reason) {
            *reason = @"identifier 为空 ⇒ 无法作为服务标识，拒绝广告";
        }
        self.failure = A2RPPairableHostFailurePublishFailed;
        self.failureReason = *reason;
        return nil;
    }

    NSDictionary<NSString *, NSString *> *txt =
        A2RPPairableHostTXTRecords(self.name, self.model, self.identifier, self.altIRK);

    nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                             NW_PARAMETERS_DEFAULT_CONFIGURATION);
    self.listener = nw_listener_create(params);
    if (self.listener == NULL) {
        if (reason) {
            *reason = @"nw_listener_create 失败";
        }
        self.failure = A2RPPairableHostFailurePublishFailed;
        self.failureReason = *reason;
        return nil;
    }

    nw_txt_record_t txtRec = nw_txt_record_create_dictionary();
    for (NSString *k in txt) {
        NSData *v = [txt[k] dataUsingEncoding:NSUTF8StringEncoding];
        nw_txt_record_set_key(txtRec, k.UTF8String, v.bytes, v.length);
    }
    nw_advertise_descriptor_t ad =
        nw_advertise_descriptor_create_bonjour_service(self.serviceName.UTF8String,
                                                       A2RPRSDServicePairableHost.UTF8String,
                                                       NULL);
    nw_advertise_descriptor_set_txt_record_object(ad, txtRec);
    nw_listener_set_advertise_descriptor(self.listener, ad);
    nw_listener_set_queue(self.listener, self.queue);

    dispatch_semaphore_t stateSem = dispatch_semaphore_create(0);
    __block BOOL stateReady = NO;
    __block BOOL stateFailed = NO;
    __block nw_error_t stateError = NULL;
    __weak __typeof__(self) weakSelf = self;
    nw_listener_set_state_changed_handler(self.listener, ^(nw_listener_state_t state, nw_error_t e) {
        __typeof__(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (state == nw_listener_state_ready) {
            stateReady = YES;
            dispatch_semaphore_signal(stateSem);
        } else if (state == nw_listener_state_waiting) {
            strongSelf.observedWaitingState = YES;           // 路径不可用/被挂起的可观察信号
        } else if (state == nw_listener_state_failed) {
            stateFailed = YES;
            stateError = e;
            dispatch_semaphore_signal(stateSem);
        }
    });

    dispatch_semaphore_t connSem = dispatch_semaphore_create(0);
    nw_listener_set_new_connection_handler(self.listener, ^(nw_connection_t conn) {
        __typeof__(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            nw_connection_cancel(conn);
            return;
        }
        if (strongSelf.acceptedConnection == nil) {
            strongSelf.acceptedConnection = (id)conn;
            dispatch_semaphore_signal(connSem);
        } else {
            nw_connection_cancel(conn);                      // 只接受第一条
        }
    });

    nw_listener_start(self.listener);

    // ① 等「已广告」（给一小段固定预算，避免把全部预算耗在发布上）
    NSTimeInterval publishBudget = MIN(10.0, MAX(2.0, budget * 0.2));
    dispatch_time_t pubDl = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(publishBudget * NSEC_PER_SEC));
    dispatch_semaphore_wait(stateSem, pubDl);

    if (stateFailed) {
        int code = stateError ? (int)nw_error_get_error_code(stateError) : 0;
        int dom = stateError ? (int)nw_error_get_error_domain(stateError) : 0;
        self.failure = (code == EACCES || code == EPERM)
            ? A2RPPairableHostFailureNoLocalNetworkPermission
            : A2RPPairableHostFailurePublishFailed;
        self.failureReason = [NSString stringWithFormat:
                              @"listener 发布失败（domain=%d, err=%d）——"
                              @"本地网络权限被拒会走到这里；"
                              @"另：被侧载器改过 bundle id 时权限会失效", dom, code];
        self.advertising = NO;
        A2RXPCLog([NSString stringWithFormat:
                   @"advertise 失败 class=%@ 服务=%@ 主机名=%@ 原因=%@",
                   A2RPPairableHostFailureName(self.failure), A2RPRSDServicePairableHost,
                   self.hostName, self.failureReason]);
        if (reason) {
            *reason = self.failureReason;
        }
        nw_listener_cancel(self.listener);
        self.listener = NULL;
        return nil;
    }
    if (!stateReady) {
        // 既没 ready 也没 failed：超时兜底，如实分类
        self.failure = A2RPPairableHostFailurePublishFailed;
        self.failureReason = [NSString stringWithFormat:@"listener 在 %.1fs 内既未就绪也未失败", publishBudget];
        self.advertising = NO;
        A2RXPCLog([NSString stringWithFormat:@"advertise 失败 class=PublishFailed（%@）", self.failureReason]);
        if (reason) {
            *reason = self.failureReason;
        }
        nw_listener_cancel(self.listener);
        self.listener = NULL;
        return nil;
    }

    self.advertising = YES;
    self.port = nw_listener_get_port(self.listener);
    A2RXPCLog([NSString stringWithFormat:
               @"advertise 成功 服务=%@ 实例名=%@ 主机名=%@ 端口=%u 名字=%@ 型号=%@ 协议版本=%d authTag=%@",
               A2RPRSDServicePairableHost, self.serviceName, self.hostName, (unsigned)self.port,
               self.name, self.model, A2RPPairableHostWireProtocolVersion, txt[@"authTag"]]);

    // ② 等系统「看见」并连入
    dispatch_time_t connDl = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(budget * NSEC_PER_SEC));
    dispatch_semaphore_wait(connSem, connDl);

    if (self.acceptedConnection == nil) {
        self.failure = self.observedWaitingState ? A2RPPairableHostFailureSuspended
                                                 : A2RPPairableHostFailureTimedOut;
        self.failureReason = [NSString stringWithFormat:
                              @"%.1fs 内没有连接被接受（等待态=%@）——"
                              @"① 权限未给/被拒 ② App 被挂起（后台窗口约 30s）③ 用户没在设置里点配对 "
                              @"④ 服务未被系统发现", budget, self.observedWaitingState ? @"是" : @"否"];
        A2RXPCLog([NSString stringWithFormat:@"advertise 未等到连入 class=%@ 原因=%@",
                   A2RPPairableHostFailureName(self.failure), self.failureReason]);
        if (reason) {
            *reason = self.failureReason;
        }
        nw_listener_cancel(self.listener);
        self.listener = NULL;
        return nil;
    }

    self.systemSawService = YES;
    A2RXPCLog(@"被系统连入（设置里「与 XXX 配对」的入口已被使用）");
    nw_listener_cancel(self.listener);
    self.listener = NULL;

    A2RPNetworkByteStream *stream =
        [A2RPNetworkByteStream streamOverAcceptedConnection:self.acceptedConnection];
    if (stream == nil) {
        self.failure = A2RPPairableHostFailureAcceptFailed;
        self.failureReason = @"接受了连接但构造字节通道失败";
        A2RXPCLog([NSString stringWithFormat:@"accept 失败 class=AcceptFailed（%@）", self.failureReason]);
        if (reason) {
            *reason = self.failureReason;
        }
        return nil;
    }
    // ★密钥轮换提示★：本次配对用的是【本次生成】的主机密钥 ⇒ 旧配对记录作废（非错误）。
    A2RXPCLog([NSString stringWithFormat:@"会话步进：已接受连入，主机密钥 identifier=%@（★本次新生成 ⇒ 旧配对记录作废）★",
               self.identifier]);
    return stream;
}

- (void)stop {
    if (self.listener != NULL) {
        nw_listener_cancel(self.listener);
        self.listener = NULL;
    }
    self.advertising = NO;
}

@end

#pragma mark - 判据行：整层就绪度（★生产调用点★）

void A2RXPCReportLayerReadiness(void) {
    // ---- ① 传输路径盘点（哪条支持 pair-setup）----
    NSString *usbWhy = nil;
    BOOL usbOK = A2RPPairSetupUSBPathAvailable(&usbWhy);
    A2RXPCLog([NSString stringWithFormat:@"路径盘点 §2c=%@（pair-verify only） §2b=%@ §2a=%@（%@）",
               A2RPRSDServiceRemotePairing, A2RPRSDServiceRemoted,
               usbOK ? @"可用" : @"不支持", usbWhy ?: @""]);
    A2RXPCLog([NSString stringWithFormat:@"路径盘点 pairable-host=%@（设备发起；本机当 accessory；协议版本 %d）",
               A2RPRSDServicePairableHost, A2RPPairableHostWireProtocolVersion]);

    // ---- ② 有界自证：帧往返 ----
    A2RXPCFrame *f = [[A2RXPCFrame alloc] init];
    f.type = A2RXPCFrameTypeData;
    f.flags = 0;
    f.streamID = A2RXPC_STREAM_ROOT;
    f.payload = [NSData dataWithBytes:"\x01\x02\x03" length:3];
    NSString *why = nil;
    NSData *encoded = A2RXPCEncodeFrame(f, &why);
    A2RXPCFrame *back = nil;
    NSUInteger consumed = 0;
    NSString *dwhy = nil;
    BOOL okFrame = encoded != nil
        && A2RXPCDecodeFrame(encoded, &consumed, &back, &dwhy)
        && back.streamID == A2RXPC_STREAM_ROOT
        && [back.payload isEqualToData:f.payload];
    A2RXPCLog([NSString stringWithFormat:@"自证 帧往返=%@", okFrame ? @"PASS" : @"FAIL"]);

    // ---- ③ 有界自证：HPACK 往返 ----
    NSArray *hdr = @[ @[ @":method", @"POST" ], @[ @":scheme", @"http" ], @[ @":path", @"/" ] ];
    NSString *hwhy = nil;
    NSData *hblock = A2RXPCEncodeHeaderBlock(hdr, &hwhy);
    NSString *hdwhy = nil;
    NSArray *hback = hblock != nil ? A2RXPCDecodeHeaderBlock(hblock, &hdwhy) : nil;
    BOOL okHpack = hback != nil && hback.count == hdr.count;
    A2RXPCLog([NSString stringWithFormat:@"自证 HPACK 往返=%@（%lu 字节）",
               okHpack ? @"PASS" : @"FAIL", (unsigned long)hblock.length]);

    // ---- ④ 有界自证：XPC 值往返 ----
    NSDictionary *xpcValue = @{ @"mangledTypeName": @"RemotePairing.ControlChannelMessageEnvelope",
                                @"value": @{ @"sequenceNumber": @(7),
                                             @"originatedBy": @"host",
                                             @"data": [NSData dataWithBytes:"\xAA\xBB" length:2] } };
    NSString *xwhy = nil;
    NSData *xblob = A2RXPCEncodeXPCValue(xpcValue, &xwhy);
    NSString *xdwhy = nil;
    id xback = xblob != nil ? A2RXPCDecodeXPCValue(xblob, NULL, &xdwhy) : nil;
    BOOL okXPC = [xback isEqual:xpcValue];
    A2RXPCLog([NSString stringWithFormat:@"自证 XPC 往返=%@（%lu 字节）",
               okXPC ? @"PASS" : @"FAIL", (unsigned long)xblob.length]);

    // ---- ⑤ 有界自证：pairable-host 通告契约（authTag 公开测试向量）----
    NSData *vectorIRK = [[NSData alloc] initWithBase64EncodedString:@"Mgp6ZGPzXM2ku9br46vsiw==" options:0];
    NSData *vectorTag = A2RPPairableHostAuthTag(vectorIRK, @"2BE6E510-0325-4365-923E-B14C6F57DB3A");
    BOOL okTag = [[vectorTag base64EncodedStringWithOptions:0] isEqualToString:@"kXjlTr2l"];
    A2RXPCLog([NSString stringWithFormat:@"自证 authTag 公开向量=%@（得 %@）",
               okTag ? @"PASS" : @"FAIL",
               vectorTag != nil ? [vectorTag base64EncodedStringWithOptions:0] : @"«nil»"]);

    NSDictionary *txt = A2RPPairableHostTXTRecords(@"Air2", @"Mac17,7",
                                                   @"2BE6E510-0325-4365-923E-B14C6F57DB3A",
                                                   vectorIRK);
    A2RXPCLog([NSString stringWithFormat:@"自证 TXT 键=%@（%lu 项）",
               [[txt.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","],
               (unsigned long)txt.count]);
}
