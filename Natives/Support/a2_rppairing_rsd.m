//
//  a2_rppairing_rsd.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [JIT-AUTOPAIR-2] RPPairing 的发现/连接/线上消息/TLS-PSK 实现。
//  协议出处、做到哪一步、以及「公开 TLS 栈给不出设备要的 PSK 套件」的实测证据，见头文件。
//

#import "a2_rppairing_rsd.h"
#import "a2_rppairing_verify.h"
#import "a2_rppairing_crypto.h"

#import <Network/Network.h>
#import <Security/SecProtocolOptions.h>
#import <Security/SecProtocolTypes.h>

#pragma mark - 服务类型与传输路径

NSString *const A2RPRSDServiceRemotePairing = @"_remotepairing._tcp";
NSString *const A2RPRSDServiceRemoted       = @"_remoted._tcp";
NSString *const A2RPRSDServicePairableHost  = @"_remotepairing-pairable-host._tcp";

A2RPRSDTransport A2RPRSDTransportForServiceType(NSString *serviceType) {
    if ([serviceType isEqualToString:A2RPRSDServiceRemotePairing]) {
        return A2RPRSDTransportRawSocket;
    }
    if ([serviceType isEqualToString:A2RPRSDServiceRemoted]
        || [serviceType isEqualToString:A2RPRSDServicePairableHost]) {
        return A2RPRSDTransportRemoteXPC;
    }
    return A2RPRSDTransportUnknown;
}

NSString *A2RPRSDTransportName(A2RPRSDTransport transport) {
    switch (transport) {
        case A2RPRSDTransportRawSocket: return @"裸 RPPairing socket(JSON 帧)";
        case A2RPRSDTransportRemoteXPC: return @"RemoteXPC(HTTP/2+XPC)";
        default:                        return @"Unknown";
    }
}

NSArray<NSString *> *A2RPRSDDefaultServiceTypes(void) {
    // 先 2c（裸 socket，只支持 pair-verify —— 正是本单要做的），再 2b。
    return @[ A2RPRSDServiceRemotePairing, A2RPRSDServiceRemoted ];
}

#pragma mark - 流式帧读取

@interface A2RPRSDFrameReader ()
@property (nonatomic, strong) NSMutableData *buffer;
@end

@implementation A2RPRSDFrameReader

- (instancetype)init {
    self = [super init];
    if (self) {
        _buffer = [NSMutableData data];
    }
    return self;
}

- (void)appendData:(NSData *)data {
    if (data.length > 0) {
        [self.buffer appendData:data];
    }
}

- (NSUInteger)bufferedBytes {
    return self.buffer.length;
}

- (NSData *)popFramePayloadWithError:(NSString **)error {
    NSUInteger need = A2RP_PAIRING_MAGIC_BYTES + A2RP_PAIRING_LENGTH_BYTES;
    if (self.buffer.length < need) {
        return nil;                        // ★不够 ≠ 出错★：等更多数据
    }
    NSUInteger declared = 0;
    if (!A2RPFrameReadLength(self.buffer, &declared)) {
        if (error) {
            *error = @"帧头 magic 不是 'RPPairing'（对端不是本协议的裸 socket？）";
        }
        return nil;
    }
    if (self.buffer.length < need + declared) {
        return nil;                        // 载荷还没收全
    }
    NSUInteger consumed = 0;
    NSData *payload = nil;
    NSString *inner = nil;
    if (!A2RPFramePop(self.buffer, &consumed, &payload, &inner)) {
        if (error) {
            *error = inner ?: @"切帧失败";
        }
        return nil;
    }
    [self.buffer replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
    return payload;
}

@end

#pragma mark - JSON 消息

NSDictionary<NSString *, id> *A2RPRSDHostOptionsRequest(BOOL attemptPairVerify) {
    return @{
        @"request": @{
            @"_0": @{
                @"handshake": @{
                    @"_0": @{
                        @"hostOptions": @{ @"attemptPairVerify": @(attemptPairVerify) },
                        @"wireProtocolVersion": @(19),      // 规格 §1：线上协议版本 19
                    }
                }
            }
        }
    };
}

NSDictionary<NSString *, id> *A2RPRSDPairingDataEvent(NSData *tlv,
                                                      NSString *kind,
                                                      BOOL startNewSession) {
    return @{
        @"event": @{
            @"_0": @{
                @"pairingData": @{
                    @"_0": @{
                        // ★规格 §3：裸 socket 这条路上二进制一律 base64 字符串★
                        @"data": [tlv base64EncodedStringWithOptions:0] ?: @"",
                        @"kind": kind ?: @"verifyManualPairing",
                        @"startNewSession": @(startNewSession),
                    }
                }
            }
        }
    };
}

NSData *_Nullable A2RPRSDTLVFromPairingDataEvent(NSDictionary<NSString *, id> *event,
                                       NSString *_Nullable *_Nullable reason) {
    if (![event isKindOfClass:[NSDictionary class]]) {
        if (reason) {
            *reason = @"对端消息不是 JSON 字典";
        }
        return nil;
    }
    id data = event[@"event"][@"_0"][@"pairingData"][@"_0"][@"data"];
    if (data == nil) {
        // 也可能是 event._0 里直接带错误（规格：pairVerifyFailed / 错误响应）
        id ev = event[@"event"][@"_0"];
        if ([ev isKindOfClass:[NSDictionary class]]) {
            if (ev[@"pairVerifyFailed"] != nil) {
                if (reason) {
                    *reason = @"对端回了 pairVerifyFailed（设备不认这个主机 ⇒ 需先做 pair-setup）";
                }
                return nil;
            }
            if (ev[@"awaitingUserConsent"] != nil) {
                if (reason) {
                    *reason = @"对端在等用户同意（设备侧信任弹窗）";
                }
                return nil;
            }
        }
        if (reason) {
            *reason = @"对端消息里没有 event._0.pairingData._0.data";
        }
        return nil;
    }
    if ([data isKindOfClass:[NSString class]]) {
        NSData *raw = [[NSData alloc] initWithBase64EncodedString:data options:0];
        if (raw == nil) {
            if (reason) {
                *reason = @"pairingData 不是合法 base64";
            }
            return nil;
        }
        return raw;
    }
    if ([data isKindOfClass:[NSData class]]) {
        return data;                       // RemoteXPC 那条路是原始字节（规格 §4）
    }
    if (reason) {
        *reason = @"pairingData 的类型既不是字符串也不是字节";
    }
    return nil;
}

NSDictionary<NSString *, id> *A2RPRSDCreateListenerRequest(NSData *encryptionKey) {
    return @{
        @"request": @{
            @"_0": @{
                @"createListener": @{
                    @"key": [encryptionKey base64EncodedStringWithOptions:0] ?: @"",
                    @"transportProtocolType": @"tcp",
                }
            }
        }
    };
}

NSNumber *_Nullable A2RPRSDListenerPortFromResponse(NSDictionary<NSString *, id> *response,
                                          NSString *_Nullable *_Nullable reason) {
    id v = response[@"createListener"][@"port"];
    if ([v isKindOfClass:[NSNumber class]]) {
        return v;
    }
    if ([v isKindOfClass:[NSString class]]) {
        // ★规格 §15：端口是字符串★（`"59100"`）
        NSInteger p = [(NSString *)v integerValue];
        if (p > 0 && p <= 65535) {
            return @(p);
        }
    }
    if (reason) {
        *reason = @"响应里没有可用的 createListener.port";
    }
    return nil;
}

#pragma mark - TLS-PSK（§12）

BOOL A2RPRSDPublicTLSPSKPathSufficient(NSString **reason) {
    // ★实测证据★：iPhoneOS26.2.sdk 的 SecProtocolOptions.h 里没有任何 PSK 套件
    //   （`grep -c tls_ciphersuite_PSK` = 0），而设备要求 0x00AF / 0x008C。
    //   `sec_protocol_options_add_pre_shared_key` 存在，但公开 API 无法把这两套套件放进 ClientHello。
    if (reason) {
        *reason = @"公开 TLS 栈给不出 §12 要求的 PSK 套件（SecProtocolOptions.h 里 tls_ciphersuite_PSK* "
                  @"为 0 项；设备要 0x00AF/0x008C）⇒ 需要按 §12 手写 TLS 1.2 PSK 客户端（独立一单的量级）";
    }
    return NO;
}

id _Nullable A2RPRSDTLSPSKParameters(NSData *psk, NSString *_Nullable *_Nullable reason) {
    if (psk.length == 0) {
        if (reason) {
            *reason = @"PSK 为空";
        }
        return nil;
    }
    __block NSString *innerReason = nil;
    __block nw_parameters_t params = nil;
    dispatch_data_t pskData = dispatch_data_create(psk.bytes, psk.length,
                                                  dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                                                  DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    // 规格 §12：PSK identity 为空
    static const uint8_t kEmpty[1] = { 0 };
    dispatch_data_t ident = dispatch_data_create(kEmpty, 0,
                                                dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    @try {
        params = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tlsOptions) {
            sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tlsOptions);
            if (sec == NULL) {
                innerReason = @"nw_tls_copy_sec_protocol_options 返回 NULL";
                return;
            }
            // ★真调用★：把 PSK 与（空）identity 装进 TLS 选项。
            sec_protocol_options_add_pre_shared_key(sec, pskData, ident);
            sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv12);
            sec_protocol_options_set_max_tls_protocol_version(sec, tls_protocol_version_TLSv12);
            // 设备要求的两个套件（若本平台的枚举里存在则一并加上；不存在就如实留着走不通的结论）。
#if defined(TLS_PSK_WITH_AES_256_CBC_SHA384) || defined(SSL_CIPHER_TLS_PSK_WITH_AES_256_CBC_SHA384)
            sec_protocol_options_append_tls_ciphersuite(sec,
                (tls_ciphersuite_t)TLS_PSK_WITH_AES_256_CBC_SHA384);
#endif
        }, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    } @catch (NSException *ex) {
        innerReason = [NSString stringWithFormat:@"构造 PSK 参数时抛异常：%@", ex.reason];
        params = nil;
    }
    if (params == nil && reason) {
        *reason = innerReason ?: @"nw_parameters_create_secure_tcp 返回 NULL";
    }
    return params;
}

#pragma mark - 发现

@interface A2RPRSDDiscovery ()
@property (nonatomic, copy) NSArray<NSString *> *serviceTypes;
@property (nonatomic, strong) NSMutableArray<NSString *> *found;
@property (nonatomic) dispatch_semaphore_t sem;
@property (nonatomic, strong) id discoveredEndpoint;   // nw_endpoint_t
@property (nonatomic, strong) NSMutableArray *browsers; // nw_browser_t（保活）
@property (nonatomic) BOOL stopped;
@end

@implementation A2RPRSDDiscovery

- (instancetype)initWithServiceTypes:(NSArray<NSString *> *)serviceTypes {
    self = [super init];
    if (self) {
        _serviceTypes = [serviceTypes copy] ?: @[];
        _found = [NSMutableArray array];
        _sem = dispatch_semaphore_create(0);
        _browsers = [NSMutableArray array];
    }
    return self;
}

+ (NSString *)describeEndpoint:(id)endpoint {
    nw_endpoint_t ep = (nw_endpoint_t)endpoint;
    if (ep == nil) {
        return @"(nil)";
    }
    const char *host = nw_endpoint_get_hostname(ep);
    uint16_t port = nw_endpoint_get_port(ep);
    const char *type = nw_endpoint_get_type(ep) == nw_endpoint_type_bonjour_service
                     ? nw_endpoint_get_bonjour_service_name(ep) : NULL;
    if (type != NULL) {
        return [NSString stringWithFormat:@"%s.%s（Bonjour）", type,
                nw_endpoint_get_bonjour_service_type(ep) ?: ""];
    }
    return [NSString stringWithFormat:@"%s:%u", host ?: "?", (unsigned)port];
}

- (void)stop {
    if (self.stopped) {
        return;
    }
    self.stopped = YES;
    for (id b in self.browsers) {
        nw_browser_cancel((nw_browser_t)b);
    }
    [self.browsers removeAllObjects];
}

- (id)waitForEndpointWithTimeout:(NSTimeInterval)budget reason:(NSString **)reason {
    if (self.serviceTypes.count == 0) {
        if (reason) {
            *reason = @"没有配置任何 Bonjour 服务类型";
        }
        return nil;
    }
    dispatch_queue_t q = dispatch_queue_create("a2.rppairing.discovery", DISPATCH_QUEUE_SERIAL);
    __weak __typeof__(self) weakSelf = self;

    for (NSString *svc in self.serviceTypes) {
        // ★服务类型必须先在 Info.plist 的 NSBonjourServices 里登记★，否则系统不给结果。
        nw_browse_descriptor_t desc =
            nw_browse_descriptor_create_bonjour_service(svc.UTF8String, NULL);
        if (desc == NULL) {
            continue;
        }
        // ★本 SDK 的签名是 nw_browser_create(descriptor, parameters)★，回调另用 setter 装。
        nw_browser_t browser = nw_browser_create(desc, NULL);
        if (browser == NULL) {
            continue;
        }
        // ★本 SDK 的回调签名 = (old_result, new_result, batch_complete)★
        nw_browser_set_browse_results_changed_handler(browser, ^(nw_browse_result_t oldResult,
                                                                nw_browse_result_t newResult,
                                                                bool batchComplete) {
            (void)oldResult;
            (void)batchComplete;
            __typeof__(self) strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.stopped) {
                return;
            }
            nw_endpoint_t ep = nw_browse_result_copy_endpoint(newResult);
            if (ep == NULL) {
                return;
            }
            @synchronized (strongSelf) {
                NSString *d = [A2RPRSDDiscovery describeEndpoint:(id)ep];
                if (![strongSelf.found containsObject:d]) {
                    [strongSelf.found addObject:d];
                }
                if (strongSelf.discoveredEndpoint == nil) {
                    strongSelf.discoveredEndpoint = (id)ep;
                    dispatch_semaphore_signal(strongSelf.sem);
                }
            }
        });
        if (browser == NULL) {
            continue;
        }
        nw_browser_set_queue(browser, q);
        nw_browser_start(browser);
        [self.browsers addObject:(id)browser];
    }

    if (self.browsers.count == 0) {
        if (reason) {
            *reason = @"所有服务类型都建不出 NWBrowser（描述符非法？）";
        }
        return nil;
    }

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(budget * NSEC_PER_SEC));
    long waited = dispatch_semaphore_wait(self.sem, deadline);
    id ep = self.discoveredEndpoint;
    [self stop];
    if (ep == nil) {
        if (reason) {
            *reason = [NSString stringWithFormat:
                       @"在 %.1fs 内没发现任何 RSD 端点（服务类型：%@）——"
                       @"设备侧未开本地网络/未起 remoted/未登记 NSBonjourServices/未走 LocalDevVPN 都会这样",
                       budget, [self.serviceTypes componentsJoinedByString:@", "]];
        }
        return nil;
    }
    (void)waited;
    return ep;
}

@end

#pragma mark - 连接 + pair-verify

@implementation A2RPRSDPairVerifyClient

+ (nullable A2RPPairingIdentity *)pairVerifyWithEndpoint:(id)endpoint
                                           localIdentity:(A2RPPairingIdentity *)localIdentity
                                         devicePublicKey:(NSData *)devicePublicKey
                                                 timeout:(NSTimeInterval)timeout
                                                  reason:(NSString **)reason {
    if (endpoint == nil) {
        if (reason) {
            *reason = @"端点为 nil";
        }
        return nil;
    }
    if (localIdentity == nil) {
        if (reason) {
            *reason = @"缺本方身份（Ed25519 密钥对 + identifier）";
        }
        return nil;
    }

    // 这是「连到设备」的那条路：裸 RPPairing socket **不做 TLS**（TLS-PSK 只用在后续隧道上）。
    nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                             NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_connection_t conn = nw_connection_create((nw_endpoint_t)endpoint, params);
    if (conn == NULL) {
        if (reason) {
            *reason = @"nw_connection_create 失败";
        }
        return nil;
    }
    dispatch_queue_t q = dispatch_queue_create("a2.rppairing.verify", DISPATCH_QUEUE_SERIAL);
    nw_connection_set_queue(conn, q);

    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block BOOL connected = NO;
    __block NSString *failReason = nil;
    nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state, nw_error_t error) {
        if (state == nw_connection_state_ready) {
            connected = YES;
            dispatch_semaphore_signal(ready);
        } else if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
            failReason = [NSString stringWithFormat:@"连接未就绪（state=%d, err=%d）",
                          (int)state, error ? (int)nw_error_get_error_code(error) : 0];
            dispatch_semaphore_signal(ready);
        }
    });
    nw_connection_start(conn);

    dispatch_time_t dl = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    dispatch_semaphore_wait(ready, dl);
    if (!connected) {
        nw_connection_cancel(conn);
        if (reason) {
            *reason = failReason ?: [NSString stringWithFormat:@"连接超时（%.1fs）", timeout];
        }
        return nil;
    }

    // ---- 收 / 发 两条同步原语（都带超时；不用网络回调套回调，避免死锁）----
    __block NSData *rxPayload = nil;
    __block NSString *rxError = nil;
    A2RPRSDFrameReader *reader = [[A2RPRSDFrameReader alloc] init];

    BOOL (^receiveFrame)(NSTimeInterval) = ^BOOL(NSTimeInterval budget) {
        NSData *payload = [reader popFramePayloadWithError:&rxError];
        if (payload != nil) {
            rxPayload = payload;
            return YES;
        }
        if (rxError != nil) {
            return NO;
        }
        dispatch_semaphore_t got = dispatch_semaphore_create(0);
        __block NSData *chunk = nil;
        __block BOOL connGone = NO;
        nw_connection_receive_message(conn, ^(dispatch_data_t content, nw_content_context_t ctx,
                                              bool isComplete, nw_error_t error) {
            (void)ctx; (void)isComplete;
            if (error != NULL) {
                connGone = YES;
            } else if (content != NULL) {
                // ★不依赖 dispatch_data ↔ NSData 的桥接★：逐 region 拷出来（跨平台行为确定）。
                NSMutableData *acc = [NSMutableData data];
                dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset,
                                                   const void *buf, size_t size) {
                    (void)region; (void)offset;
                    [acc appendBytes:buf length:size];
                    return true;
                });
                chunk = acc;
            }
            dispatch_semaphore_signal(got);
        });
        dispatch_time_t d2 = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(budget * NSEC_PER_SEC));
        dispatch_semaphore_wait(got, d2);
        if (chunk == nil) {
            rxError = connGone ? @"对端关闭了连接（本单要求：先做 hostOptions 再 pair-verify）"
                               : [NSString stringWithFormat:@"收消息超时（%.1fs）", budget];
            return NO;
        }
        [reader appendData:chunk];
        NSData *p = [reader popFramePayloadWithError:&rxError];
        if (p == nil) {
            if (rxError == nil) {
                rxError = @"收到的帧还不完整（分片？本仓对小消息不做重组等待）";
            }
            return NO;
        }
        rxPayload = p;
        return YES;
    };

    // ★帧载荷是 JSON 字节★（规格 §3）：先 JSON 解码再交给下面的语义函数。
    __block NSString *jsonError = nil;
    NSDictionary *(^decodeFrame)(void) = ^NSDictionary *{
        if (rxPayload == nil) {
            jsonError = @"没有收到任何载荷";
            return nil;
        }
        NSError *e = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:rxPayload options:0 error:&e];
        if (![obj isKindOfClass:[NSDictionary class]]) {
            jsonError = [NSString stringWithFormat:@"载荷不是 JSON 对象：%@",
                         e.localizedDescription ?: @"(非法 JSON)"];
            return nil;
        }
        return obj;
    };

    __block NSString *txError = nil;
    BOOL (^sendFrame)(NSDictionary *) = ^BOOL(NSDictionary *envelope) {
        NSString *encErr = nil;
        NSData *frame = A2RPFrameEncodeEnvelope(envelope, &encErr);
        if (frame == nil) {
            txError = encErr ?: @"组帧失败";
            return NO;
        }
        dispatch_semaphore_t sent = dispatch_semaphore_create(0);
        __block nw_error_t sendErr = NULL;
        dispatch_data_t d = dispatch_data_create(frame.bytes, frame.length, q, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        nw_connection_send(conn, d, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
                           ^(nw_error_t error) {
            sendErr = error;
            dispatch_semaphore_signal(sent);
        });
        dispatch_time_t d3 = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC));
        dispatch_semaphore_wait(sent, d3);
        if (sendErr != NULL) {
            txError = [NSString stringWithFormat:@"发送失败（err=%d）", (int)nw_error_get_error_code(sendErr)];
            return NO;
        }
        return YES;
    };

    A2RPPairingIdentity *result = nil;
    NSString *localWhy = nil;

    do {
        // §8 Step 1：hostOptions
        if (!sendFrame(A2RPRSDHostOptionsRequest(YES))) { localWhy = txError; break; }
        if (!receiveFrame(timeout)) { localWhy = rxError; break; }
        NSDictionary *hostResp = decodeFrame();
        if (hostResp == nil) { localWhy = jsonError; break; }

        // §8 Step 2：M1
        A2RPPairVerifySession *session =
            [A2RPPairVerifySession sessionWithRole:A2RPPairVerifyRoleHost
                                          identity:localIdentity
                                     peerPublicKey:devicePublicKey
                                            reason:&localWhy];
        if (session == nil) { break; }
        NSData *m1 = [session nextMessageWithReason:&localWhy];
        if (m1 == nil || !sendFrame(A2RPRSDPairingDataEvent(m1, @"verifyManualPairing", YES))) {
            localWhy = localWhy ?: txError;
            break;
        }

        // §8 Step 3：M2
        if (!receiveFrame(timeout)) { localWhy = rxError; break; }
        NSString *tlvErr = nil;
        NSDictionary *m2msg = decodeFrame();
        NSData *m2 = m2msg ? A2RPRSDTLVFromPairingDataEvent(m2msg, &tlvErr) : nil;
        if (m2 == nil || ![session acceptMessage:m2 reason:&localWhy]) {
            localWhy = localWhy ?: (tlvErr ?: jsonError);
            break;
        }

        // §8 Step 7：M3
        NSData *m3 = [session nextMessageWithReason:&localWhy];
        if (m3 == nil || !sendFrame(A2RPRSDPairingDataEvent(m3, @"verifyManualPairing", NO))) {
            localWhy = localWhy ?: txError;
            break;
        }

        // §8 Step 8：M4
        if (!receiveFrame(timeout)) { localWhy = rxError; break; }
        NSDictionary *m4msg = decodeFrame();
        NSData *m4 = m4msg ? A2RPRSDTLVFromPairingDataEvent(m4msg, &tlvErr) : nil;
        if (m4 == nil || ![session acceptMessage:m4 reason:&localWhy]) {
            localWhy = localWhy ?: (tlvErr ?: jsonError);
            break;
        }
        if (!session.established) {
            localWhy = @"对端未进入已建立状态";
            break;
        }

        // ★规格 §7★：配对记录里的签名密钥在成功握手后取【新的】值 ⇒ 这里产出新身份。
        NSError *idErr = nil;
        NSString *hostName = localIdentity.identifier ?: @"air2-rppairing";
        result = [A2RPPairingIdentity identityWithHostName:hostName error:&idErr];
        if (result == nil) {
            localWhy = [NSString stringWithFormat:@"握手成功但新身份生成失败：%@",
                        idErr.localizedDescription ?: @"未知"];
        }
    } while (0);

    nw_connection_cancel(conn);
    if (result == nil && reason) {
        *reason = localWhy ?: @"pair-verify 未完成（原因未记录）";
    }
    return result;
}

@end
