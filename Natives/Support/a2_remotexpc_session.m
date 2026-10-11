//
//  a2_remotexpc_session.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [A2-RXPC] RemoteXPC 会话实现：初始化握手 + pairingData 交换 + 超时/错误分类。
//

#import "a2_remotexpc_session.h"
#import "a2_remotexpc_framing.h"
#import "a2_log.h"

NSString *A2RemoteXPCErrorKindName(A2RemoteXPCErrorKind kind) {
    switch (kind) {
        case A2RemoteXPCErrorNone:            return @"None";
        case A2RemoteXPCErrorNotConnected:    return @"NotConnected";
        case A2RemoteXPCErrorConnectFailed:   return @"ConnectFailed";
        case A2RemoteXPCErrorConnectTimeout:  return @"ConnectTimeout";
        case A2RemoteXPCErrorHandshakeFailed: return @"HandshakeFailed";
        case A2RemoteXPCErrorHandshakeTimeout:return @"HandshakeTimeout";
        case A2RemoteXPCErrorSendFailed:      return @"SendFailed";
        case A2RemoteXPCErrorReceiveTimeout:  return @"ReceiveTimeout";
        case A2RemoteXPCErrorFrameFormat:     return @"FrameFormat";
        case A2RemoteXPCErrorPeerClosed:      return @"PeerClosed";
        case A2RemoteXPCErrorXPCDecode:       return @"XPCDecode";
        case A2RemoteXPCErrorUnsupported:     return @"Unsupported";
        case A2RemoteXPCErrorCancelled:       return @"Cancelled";
    }
    return [NSString stringWithFormat:@"Unknown(%ld)", (long)kind];
}

static void A2RXPCRecordError(A2RemoteXPCErrorKind *out, A2RemoteXPCErrorKind kind) {
    if (out) {
        *out = kind;
    }
}

#pragma mark - 内存字节通道（单测/自证）

@interface A2RemoteXPCInMemoryStream ()
@property (nonatomic, strong) NSMutableArray<NSData *> *reads;
@property (nonatomic, strong) NSMutableData *written;
@property (nonatomic) NSUInteger writeCount;
@property (nonatomic) BOOL opened;
@property (nonatomic) BOOL closed;
@end

@implementation A2RemoteXPCInMemoryStream

- (instancetype)init {
    self = [super init];
    if (self) {
        _reads = [NSMutableArray array];
        _written = [NSMutableData data];
    }
    return self;
}

- (void)enqueueReadChunk:(NSData *)chunk {
    if (chunk) {
        [self.reads addObject:chunk];
    }
}

- (NSData *)writtenBytes {
    return [self.written copy];
}

- (BOOL)openStreamWithTimeout:(NSTimeInterval)timeout reason:(NSString **)reason error:(A2RemoteXPCErrorKind *)error {
    (void)timeout;
    if (self.failOnOpen) {
        if (reason) {
            *reason = @"内存流：按脚本在建连阶段失败";
        }
        A2RXPCRecordError(error, A2RemoteXPCErrorConnectFailed);
        return NO;
    }
    self.opened = YES;
    return YES;
}

- (BOOL)writeBytes:(NSData *)bytes timeout:(NSTimeInterval)timeout reason:(NSString **)reason error:(A2RemoteXPCErrorKind *)error {
    (void)timeout;
    self.writeCount += 1;
    if (self.failOnWriteAtIndex != 0 && self.writeCount == self.failOnWriteAtIndex) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"内存流：按脚本在第 %lu 次写失败",
                       (unsigned long)self.writeCount];
        }
        A2RXPCRecordError(error, A2RemoteXPCErrorSendFailed);
        return NO;
    }
    [self.written appendData:bytes];
    return YES;
}

- (NSData *)readBytesWithTimeout:(NSTimeInterval)timeout reason:(NSString **)reason error:(A2RemoteXPCErrorKind *)error {
    (void)timeout;
    if (self.reads.count > 0) {
        NSData *chunk = self.reads.firstObject;
        [self.reads removeObjectAtIndex:0];
        return chunk;
    }
    if (self.peerClosed) {
        if (reason) {
            *reason = @"内存流：按脚本视为对端已关闭";
        }
        A2RXPCRecordError(error, A2RemoteXPCErrorPeerClosed);
        return nil;
    }
    if (reason) {
        *reason = @"内存流：队列已空，按脚本视为超时";
    }
    A2RXPCRecordError(error, A2RemoteXPCErrorReceiveTimeout);
    return nil;
}

- (void)closeStream {
    self.closed = YES;
}

@end

#pragma mark - 会话

@interface A2RemoteXPCSession ()
@property (nonatomic, strong) id<A2RPByteStream> stream;
@property (nonatomic) NSUInteger wireProtocolVersion;
@property (nonatomic, copy) NSString *originatedBy;
@property (nonatomic) BOOL handshakeComplete;
@property (nonatomic) NSUInteger sequenceNumber;
@property (nonatomic) BOOL observedAwaitingUserConsent;
@property (nonatomic, strong) A2RXPCFrameReader *reader;
@property (nonatomic) uint64_t nextMessageID;
@end

@implementation A2RemoteXPCSession

- (instancetype)initWithStream:(id<A2RPByteStream>)stream
           wireProtocolVersion:(NSUInteger)wireProtocolVersion
                  originatedBy:(NSString *)originatedBy {
    self = [super init];
    if (self) {
        _stream = stream;
        _wireProtocolVersion = wireProtocolVersion;
        _originatedBy = [originatedBy copy] ?: @"host";
        _reader = [[A2RXPCFrameReader alloc] init];
        _nextMessageID = 1;
        _exchangeTimeout = 30.0;
    }
    return self;
}

- (void)close {
    [self.stream closeStream];
}

#pragma mark - 握手

- (BOOL)sendFrameType:(uint8_t)type
                flags:(uint8_t)flags
             streamID:(uint32_t)streamID
              payload:(NSData *)payload
              timeout:(NSTimeInterval)timeout
               reason:(NSString **)reason
                error:(A2RemoteXPCErrorKind *)error {
    A2RXPCFrame *f = [[A2RXPCFrame alloc] init];
    f.type = type;
    f.flags = flags;
    f.streamID = streamID;
    f.payload = payload ?: [NSData data];
    NSString *why = nil;
    NSData *bytes = A2RXPCEncodeFrame(f, &why);
    if (bytes == nil) {
        if (reason) {
            *reason = why ?: @"组帧失败";
        }
        A2RXPCRecordError(error, A2RemoteXPCErrorFrameFormat);
        return NO;
    }
    if (![self.stream writeBytes:bytes timeout:timeout reason:reason error:error]) {
        return NO;
    }
    A2RXPCLog([NSString stringWithFormat:@"tx frame type=%u flags=0x%02X stream=%u bytes=%lu",
               (unsigned)type, (unsigned)flags, (unsigned)streamID, (unsigned long)bytes.length]);
    return YES;
}

/// 发一条 XPC 消息（包成 DATA 帧）。flags/streamID 由调用方给。
- (BOOL)sendXPCMessage:(id)value
                 flags:(uint32_t)xpcFlags
              streamID:(uint32_t)streamID
            frameFlags:(uint8_t)frameFlags
               timeout:(NSTimeInterval)timeout
                reason:(NSString **)reason
                 error:(A2RemoteXPCErrorKind *)error {
    NSString *why = nil;
    NSData *body = A2RXPCEncodeXPCValue(value, &why);
    if (body == nil) {
        if (reason) {
            *reason = why ?: @"XPC 载荷编码失败";
        }
        A2RXPCRecordError(error, A2RemoteXPCErrorFrameFormat);
        return NO;
    }
    A2RXPCXPCMessage *m = [[A2RXPCXPCMessage alloc] init];
    m.flags = xpcFlags;
    m.messageID = self.nextMessageID++;
    m.body = body;
    NSData *wire = A2RXPCEncodeXPCMessage(m, &why);
    if (wire == nil) {
        if (reason) {
            *reason = why ?: @"XPC 消息编码失败";
        }
        A2RXPCRecordError(error, A2RemoteXPCErrorFrameFormat);
        return NO;
    }
    return [self sendFrameType:A2RXPCFrameTypeData
                         flags:frameFlags
                      streamID:streamID
                       payload:wire
                       timeout:timeout
                        reason:reason
                         error:error];
}

- (BOOL)connectAndHandshakeWithTimeout:(NSTimeInterval)timeout reason:(NSString **)reason error:(A2RemoteXPCErrorKind *)error {
    if (self.stream == nil) {
        if (reason) {
            *reason = @"没有注入字节通道";
        }
        A2RXPCRecordError(error, A2RemoteXPCErrorNotConnected);
        return NO;
    }
    A2RXPCLog([NSString stringWithFormat:@"connect 开始（路径=RemoteXPC，wireProtocolVersion=%lu，originatedBy=%@，超时=%.1fs）",
               (unsigned long)self.wireProtocolVersion, self.originatedBy, timeout]);

    if (![self.stream openStreamWithTimeout:timeout reason:reason error:error]) {
        A2RXPCLog([NSString stringWithFormat:@"connect 失败 class=%@ 原因=%@",
                   A2RemoteXPCErrorKindName(error ? *error : A2RemoteXPCErrorNone),
                   reason ? (*reason ?: @"(无)") : @"(未取)"]);
        return NO;
    }
    A2RXPCLog(@"connect 成功（字节通道已就绪）");

    // ---- 公开规格 §4 的初始化序列（真发）----
    NSData *preface = A2RXPCConnectionPreface();
    if (![self.stream writeBytes:preface timeout:timeout reason:reason error:error]) {
        A2RXPCLog([NSString stringWithFormat:@"握手失败 class=%@（写连接前导）",
                   A2RemoteXPCErrorKindName(error ? *error : A2RemoteXPCErrorNone)]);
        A2RXPCRecordError(error, A2RemoteXPCErrorHandshakeFailed);
        return NO;
    }

    // 1. SETTINGS：MaxConcurrentStreams=100，InitialWindowSize=1048576
    NSMutableData *settings = [NSMutableData data];
    uint16_t id1 = 3; uint32_t v1 = 100;
    uint8_t b1[6] = { (uint8_t)(id1 >> 8), (uint8_t)(id1 & 0xFF),
                      (uint8_t)(v1 >> 24), (uint8_t)(v1 >> 16), (uint8_t)(v1 >> 8), (uint8_t)(v1 & 0xFF) };
    [settings appendBytes:b1 length:6];
    uint16_t id2 = 4; uint32_t v2 = 1048576;
    uint8_t b2[6] = { (uint8_t)(id2 >> 8), (uint8_t)(id2 & 0xFF),
                      (uint8_t)(v2 >> 24), (uint8_t)(v2 >> 16), (uint8_t)(v2 >> 8), (uint8_t)(v2 & 0xFF) };
    [settings appendBytes:b2 length:6];
    if (![self sendFrameType:A2RXPCFrameTypeSettings flags:0 streamID:0 payload:settings
                     timeout:timeout reason:reason error:error]) {
        A2RXPCRecordError(error, A2RemoteXPCErrorHandshakeFailed);
        return NO;
    }

    // 2. WINDOW_UPDATE：increment=983041，stream 0
    uint32_t inc = 983041;
    uint8_t wu[4] = { (uint8_t)(inc >> 24), (uint8_t)(inc >> 16), (uint8_t)(inc >> 8), (uint8_t)(inc & 0xFF) };
    if (![self sendFrameType:A2RXPCFrameTypeWindowUpdate flags:0 streamID:0
                     payload:[NSData dataWithBytes:wu length:4]
                     timeout:timeout reason:reason error:error]) {
        A2RXPCRecordError(error, A2RemoteXPCErrorHandshakeFailed);
        return NO;
    }

    // 3. 开流 1（根通道）：HEADERS
    NSString *why = nil;
    NSData *hdr1 = A2RXPCEncodeHeaderBlock(@[ @[ @":method", @"POST" ],
                                              @[ @":scheme", @"http" ],
                                              @[ @":path", @"/" ] ], &why);
    if (hdr1 == nil
        || ![self sendFrameType:A2RXPCFrameTypeHeaders
                          flags:A2RXPCFrameFlagEndHeaders
                       streamID:A2RXPC_STREAM_ROOT
                        payload:hdr1
                        timeout:timeout reason:reason error:error]) {
        if (reason && *reason == nil) {
            *reason = why ?: @"流 1 HEADERS 发送失败";
        }
        A2RXPCRecordError(error, A2RemoteXPCErrorHandshakeFailed);
        return NO;
    }

    // 4. 流 1 上发【空 XPC 字典】（flags=AlwaysSet）
    if (![self sendXPCMessage:@{} flags:A2RXPC_XPC_FLAG_ALWAYS_SET
                     streamID:A2RXPC_STREAM_ROOT frameFlags:0
                      timeout:timeout reason:reason error:error]) {
        A2RXPCRecordError(error, A2RemoteXPCErrorHandshakeFailed);
        return NO;
    }

    // 5. 开流 3（回复通道）：HEADERS
    NSData *hdr3 = A2RXPCEncodeHeaderBlock(@[ @[ @":method", @"POST" ],
                                              @[ @":scheme", @"http" ],
                                              @[ @":path", @"/" ] ], &why);
    if (hdr3 == nil
        || ![self sendFrameType:A2RXPCFrameTypeHeaders
                          flags:A2RXPCFrameFlagEndHeaders
                       streamID:A2RXPC_STREAM_REPLY
                        payload:hdr3
                        timeout:timeout reason:reason error:error]) {
        A2RXPCRecordError(error, A2RemoteXPCErrorHandshakeFailed);
        return NO;
    }

    // 6. 流 3 上发 init 握手（flags=InitHandshake|AlwaysSet）
    if (![self sendXPCMessage:@{}
                        flags:(A2RXPC_XPC_FLAG_INIT_HANDSHAKE | A2RXPC_XPC_FLAG_ALWAYS_SET)
                     streamID:A2RXPC_STREAM_REPLY frameFlags:0
                      timeout:timeout reason:reason error:error]) {
        A2RXPCRecordError(error, A2RemoteXPCErrorHandshakeFailed);
        return NO;
    }

    // 7. 流 1 上发特殊标志 0x201
    if (![self sendXPCMessage:@{}
                        flags:A2RXPC_STREAM_SPECIAL_FLAGS
                     streamID:A2RXPC_STREAM_ROOT frameFlags:0
                      timeout:timeout reason:reason error:error]) {
        A2RXPCRecordError(error, A2RemoteXPCErrorHandshakeFailed);
        return NO;
    }

    self.handshakeComplete = YES;
    A2RXPCLog([NSString stringWithFormat:@"handshake 完成（前导+SETTINGS+WINDOW_UPDATE+流1/3 HEADERS+init+特殊标志 0x%X）",
               A2RXPC_STREAM_SPECIAL_FLAGS]);
    return YES;
}

#pragma mark - 收

/// 从解码后的 XPC 值里找 pairingData 的 TLV 字节（规格 §4：该路径是原始 XPC Data）。
/// 同时把 awaitingUserConsent / 拒绝 标记回填。★找不到时 reason 可为 nil（只是还没到）★。
static NSData *A2RXPCFindPairingData(id node, NSUInteger depth,
                                     BOOL *awaiting, NSString **rejected, NSString **reason) {
    if (depth > 16 || node == nil) {
        return nil;
    }
    if ([node isKindOfClass:[NSArray class]]) {
        for (id elem in (NSArray *)node) {
            NSData *hit = A2RXPCFindPairingData(elem, depth + 1, awaiting, rejected, reason);
            if (hit != nil) {
                return hit;
            }
        }
        return nil;
    }
    if (![node isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSDictionary *dict = (NSDictionary *)node;
    if (dict[@"awaitingUserConsent"] != nil && awaiting) {
        *awaiting = YES;
    }
    if (dict[@"pairVerifyFailed"] != nil && rejected && *rejected == nil) {
        *rejected = @"对端回了 pairVerifyFailed（设备不认这个主机 ⇒ 需先做 pair-setup）";
    }
    if (dict[@"pairingRejectedWithError"] != nil && rejected && *rejected == nil) {
        *rejected = @"对端回了 pairingRejectedWithError（用户拒绝或设备拒绝）";
    }
    if (dict[@"pairingData"] != nil) {
        id inner = dict[@"pairingData"];
        if ([inner isKindOfClass:[NSDictionary class]]) {
            id d0 = ((NSDictionary *)inner)[@"_0"];
            if ([d0 isKindOfClass:[NSDictionary class]]) {
                id data = ((NSDictionary *)d0)[@"data"];
                if ([data isKindOfClass:[NSData class]]) {
                    return data;                    // ★RemoteXPC 这条路是原始字节★
                }
                if ([data isKindOfClass:[NSString class]]) {
                    NSData *raw = [[NSData alloc] initWithBase64EncodedString:(NSString *)data options:0];
                    if (raw != nil) {
                        return raw;
                    }
                    if (reason) {
                        *reason = @"pairingData 是字符串但不是合法 base64";
                    }
                    return nil;
                }
                if (data != nil && reason) {
                    *reason = [NSString stringWithFormat:@"pairingData.data 的类型不支持：%@",
                               NSStringFromClass([data class])];
                    return nil;
                }
            }
        }
    }
    for (id key in dict) {
        NSData *hit = A2RXPCFindPairingData(dict[key], depth + 1, awaiting, rejected, reason);
        if (hit != nil) {
            return hit;
        }
    }
    return nil;
}

- (BOOL)sendPairingData:(NSData *)tlv
                   kind:(NSString *)kind
               startNew:(BOOL)startNewSession
                 reason:(NSString **)reason
                  error:(A2RemoteXPCErrorKind *)error {
    if (!self.handshakeComplete) {
        if (reason) {
            *reason = @"RemoteXPC 会话尚未完成初始化握手";
        }
        A2RXPCRecordError(error, A2RemoteXPCErrorNotConnected);
        return NO;
    }
    if (tlv == nil) {
        if (reason) {
            *reason = @"要发的 TLV 为 nil";
        }
        A2RXPCRecordError(error, A2RemoteXPCErrorSendFailed);
        return NO;
    }

    NSUInteger seq = self.sequenceNumber;
    NSDictionary *pairingData = @{ @"_0": @{ @"data": tlv,
                                             @"kind": kind ?: @"",
                                             @"startNewSession": @(startNewSession) } };
    NSDictionary *envelope = @{
        @"message": @{ @"plain": @{ @"_0": @{ @"event": @{ @"_0": @{ @"pairingData": pairingData } } } } },
        @"originatedBy": self.originatedBy,
        @"sequenceNumber": @(seq),
    };

    A2RXPCLog([NSString stringWithFormat:@"tx pairingData seq=%lu kind=%@ startNew=%@ tlv=%lu 字节",
               (unsigned long)seq, kind ?: @"", startNewSession ? @"YES" : @"NO",
               (unsigned long)tlv.length]);

    if (![self sendXPCMessage:envelope
                        flags:A2RXPC_XPC_FLAG_ALWAYS_SET
                     streamID:A2RXPC_STREAM_ROOT
                   frameFlags:0
                      timeout:self.exchangeTimeout
                       reason:reason
                        error:error]) {
        A2RXPCLog([NSString stringWithFormat:@"错误分类=%@ 步骤=tx pairingData seq=%lu",
                   A2RemoteXPCErrorKindName(error ? *error : A2RemoteXPCErrorNone),
                   (unsigned long)seq]);
        return NO;
    }
    self.sequenceNumber = seq + 1;
    return YES;
}

- (NSData *)receivePairingDataWithKind:(NSString *)kind
                               timeout:(NSTimeInterval)timeout
                                reason:(NSString **)reason
                                 error:(A2RemoteXPCErrorKind *)error {
    (void)kind;
    if (!self.handshakeComplete) {
        if (reason) {
            *reason = @"RemoteXPC 会话尚未完成初始化握手";
        }
        A2RXPCRecordError(error, A2RemoteXPCErrorNotConnected);
        return nil;
    }

    // ---- 读回复：DATA 帧 → XPC 消息 → 值树里找 pairingData ----
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (YES) {
        if ([deadline timeIntervalSinceNow] <= 0) {
            if (reason) {
                *reason = [NSString stringWithFormat:@"等对端回复超时（%.1fs）", timeout];
            }
            A2RXPCRecordError(error, A2RemoteXPCErrorReceiveTimeout);
            A2RXPCLog([NSString stringWithFormat:@"错误分类=%@ 步骤=rx pairingData seq=%lu",
                       A2RemoteXPCErrorKindName(A2RemoteXPCErrorReceiveTimeout),
                       (unsigned long)self.sequenceNumber]);
            return nil;
        }
        NSString *why = nil;
        A2RXPCFrame *frame = [self.reader popFrameWithReason:&why];
        if (frame == nil) {
            if (why != nil) {                       // ★确实是错★
                if (reason) {
                    *reason = why;
                }
                A2RXPCRecordError(error, A2RemoteXPCErrorFrameFormat);
                A2RXPCLog([NSString stringWithFormat:@"错误分类=%@ 步骤=帧解析（%@）",
                           A2RemoteXPCErrorKindName(A2RemoteXPCErrorFrameFormat), why]);
                return nil;
            }
            // 还不够一帧 ⇒ 再读一段
            NSString *rwhy = nil;
            A2RemoteXPCErrorKind rerr = A2RemoteXPCErrorNone;
            NSData *chunk = [self.stream readBytesWithTimeout:1.0 reason:&rwhy error:&rerr];
            if (chunk == nil) {
                if (rerr == A2RemoteXPCErrorReceiveTimeout) {
                    continue;                       // 等下一段，直到总超时
                }
                if (reason) {
                    *reason = rwhy ?: @"读失败";
                }
                A2RXPCRecordError(error, rerr);
                A2RXPCLog([NSString stringWithFormat:@"错误分类=%@ 步骤=读字节",
                           A2RemoteXPCErrorKindName(rerr)]);
                return nil;
            }
            [self.reader appendData:chunk];
            continue;
        }

        A2RXPCLog([NSString stringWithFormat:@"rx frame type=%u flags=0x%02X stream=%u bytes=%lu",
                   (unsigned)frame.type, (unsigned)frame.flags,
                   (unsigned)frame.streamID, (unsigned long)frame.payload.length]);

        if (frame.type == A2RXPCFrameTypeGoAway) {
            if (reason) {
                *reason = @"对端发了 GOAWAY（连接被拒/协商失败）";
            }
            A2RXPCRecordError(error, A2RemoteXPCErrorHandshakeFailed);
            return nil;
        }
        if (frame.type != A2RXPCFrameTypeData) {
            continue;                               // SETTINGS/WINDOW_UPDATE/PING/HEADERS 一律略过
        }
        NSUInteger consumed = 0;
        A2RXPCXPCMessage *msg = nil;
        NSString *mwhy = nil;
        if (!A2RXPCDecodeXPCMessage(frame.payload, &consumed, &msg, &mwhy)) {
            if (mwhy == nil) {
                if (reason) {
                    *reason = @"DATA 帧里的 XPC 消息不完整";
                }
                A2RXPCRecordError(error, A2RemoteXPCErrorXPCDecode);
            } else {
                if (reason) {
                    *reason = mwhy;
                }
                A2RXPCRecordError(error, A2RemoteXPCErrorXPCDecode);
            }
            A2RXPCLog([NSString stringWithFormat:@"错误分类=%@ 步骤=XPC 消息解码",
                       A2RemoteXPCErrorKindName(A2RemoteXPCErrorXPCDecode)]);
            return nil;
        }
        NSString *vwhy = nil;
        id value = A2RXPCDecodeXPCValue(msg.body, NULL, &vwhy);
        if (value == nil) {
            if (reason) {
                *reason = vwhy ?: @"XPC 值被截断";
            }
            A2RXPCRecordError(error, A2RemoteXPCErrorXPCDecode);
            A2RXPCLog([NSString stringWithFormat:@"错误分类=%@ 步骤=XPC 值解码（%@）",
                       A2RemoteXPCErrorKindName(A2RemoteXPCErrorXPCDecode), vwhy ?: @"截断"]);
            return nil;
        }
        BOOL awaiting = NO;
        NSString *rejected = nil;
        NSString *fwhy = nil;
        NSData *found = A2RXPCFindPairingData(value, 0, &awaiting, &rejected, &fwhy);
        if (awaiting) {
            self.observedAwaitingUserConsent = YES;
            A2RXPCLog(@"rx awaitingUserConsent（设备正在弹信任框；配对码取固定码）");
            continue;                               // 等设备随后发的 SRP 参数
        }
        if (rejected != nil) {
            if (reason) {
                *reason = rejected;
            }
            A2RXPCRecordError(error, A2RemoteXPCErrorHandshakeFailed);
            A2RXPCLog([NSString stringWithFormat:@"错误分类=%@ 步骤=对端拒绝（%@）",
                       A2RemoteXPCErrorKindName(A2RemoteXPCErrorHandshakeFailed), rejected]);
            return nil;
        }
        if (fwhy != nil) {
            if (reason) {
                *reason = fwhy;
            }
            A2RXPCRecordError(error, A2RemoteXPCErrorXPCDecode);
            return nil;
        }
        if (found != nil) {
            A2RXPCLog([NSString stringWithFormat:@"rx pairingData seq=%lu 收到 %lu 字节",
                       (unsigned long)self.sequenceNumber, (unsigned long)found.length]);
            return found;
        }
        // 与本协议无关的消息 ⇒ 继续读
    }
}

/// ★既有语义保持不动★：发一条 pairingData TLV，同步取回对端的下一条。
/// 现在 = sendPairingData: + receivePairingDataWithKind:timeout:reason:（同一份实现，无复制）。
- (NSData *)exchangePairingData:(NSData *)tlv
                           kind:(NSString *)kind
                       startNew:(BOOL)startNewSession
                         reason:(NSString **)reason
                          error:(A2RemoteXPCErrorKind *)error {
    if (![self sendPairingData:tlv kind:kind startNew:startNewSession reason:reason error:error]) {
        return nil;
    }
    return [self receivePairingDataWithKind:kind timeout:self.exchangeTimeout reason:reason error:error];
}

@end
