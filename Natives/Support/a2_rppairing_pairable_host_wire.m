//
//  a2_rppairing_pairable_host_wire.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [A2-PAIRPIN] pairable-host 线上契约的纯函数实现（口径/顺序见头文件）。
//

#import "a2_rppairing_pairable_host_wire.h"

NSString *const A2RPPHWWireMagicString = @"RPPairing";
NSString *const A2RPPHWOriginatedByAccessory = @"device";
const NSUInteger A2RPPHWMinimumWireProtocolVersion = 8;
NSString *const A2RPPHWCriterionMarker = @"[A2-PAIRPIN]";

/// 前导字节数（`RPPairing`）。
#define A2RPPHW_MAGIC_BYTES 9
/// 帧头 = magic(9) + 大端长度(2)。
#define A2RPPHW_FRAME_HEADER_BYTES 11
/// 单个 JSON 负载上限（长度字段只有 2 字节）。
#define A2RPPHW_MAX_PAYLOAD 65535

#pragma mark - 小工具

/// 从 plist 风格字典里按键取值（`_0` 这类键是线上格式的一部分，不是本仓约定）。
static id A2RPPHWValueAt(id object, NSString *key) {
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return [(NSDictionary *)object objectForKey:key];
}

/// 沿一串键下降；任一环不是字典 ⇒ nil。
static id A2RPPHWDescend(id object, NSArray<NSString *> *keys) {
    id cur = object;
    for (NSString *k in keys) {
        cur = A2RPPHWValueAt(cur, k);
        if (cur == nil) {
            return nil;
        }
    }
    return cur;
}

static BOOL A2RPPHWIsTrue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value boolValue];
    }
    return NO;
}

#pragma mark - 帧

NSData *A2RPPHWEncodeFrame(NSData *jsonPayload, NSString **why) {
    if (jsonPayload.length == 0) {
        if (why) { *why = @"帧负载为空"; }
        return nil;
    }
    if (jsonPayload.length > A2RPPHW_MAX_PAYLOAD) {
        if (why) {
            *why = [NSString stringWithFormat:@"帧负载 %lu 字节超过 2 字节长度上限 %d",
                    (unsigned long)jsonPayload.length, A2RPPHW_MAX_PAYLOAD];
        }
        return nil;
    }
    NSMutableData *out = [NSMutableData dataWithCapacity:A2RPPHW_FRAME_HEADER_BYTES + jsonPayload.length];
    [out appendBytes:A2RPPHWWireMagicString.UTF8String length:A2RPPHW_MAGIC_BYTES];
    uint8_t len[2] = { (uint8_t)((jsonPayload.length >> 8) & 0xFF),
                       (uint8_t)(jsonPayload.length & 0xFF) };
    [out appendBytes:len length:sizeof(len)];
    [out appendData:jsonPayload];
    return out;
}

BOOL A2RPPHWDecodeFrameHeader(NSData *buffer, NSUInteger *outPayloadLength, NSString **why) {
    if (buffer.length < A2RPPHW_FRAME_HEADER_BYTES) {
        if (why) {
            *why = [NSString stringWithFormat:@"帧头不足 %d 字节（实得 %lu）",
                    A2RPPHW_FRAME_HEADER_BYTES, (unsigned long)buffer.length];
        }
        return NO;
    }
    const uint8_t *b = (const uint8_t *)buffer.bytes;
    if (memcmp(b, A2RPPHWWireMagicString.UTF8String, A2RPPHW_MAGIC_BYTES) != 0) {
        if (why) {
            *why = [NSString stringWithFormat:@"帧前导不是 \"%@\"（前 9 字节 = %02X%02X%02X%02X%02X%02X%02X%02X%02X）",
                    A2RPPHWWireMagicString,
                    b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8]];
        }
        return NO;
    }
    if (outPayloadLength) {
        *outPayloadLength = ((NSUInteger)b[9] << 8) | (NSUInteger)b[10];
    }
    return YES;
}

#pragma mark - 信封

NSData *A2RPPHWEncodeEnvelope(id value, NSString *originatedBy, NSUInteger sequenceNumber, NSString **why) {
    if (value == nil) {
        if (why) { *why = @"信封负载为 nil"; }
        return nil;
    }
    NSDictionary *envelope = @{
        @"message": @{ @"plain": @{ @"_0": value } },
        @"originatedBy": (originatedBy.length > 0 ? originatedBy : A2RPPHWOriginatedByAccessory),
        @"sequenceNumber": @(sequenceNumber),
    };
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:&err];
    if (json == nil) {
        if (why) {
            *why = [NSString stringWithFormat:@"信封 JSON 序列化失败：%@",
                    err.localizedDescription ?: @"未知"];
        }
        return nil;
    }
    return json;
}

NSDictionary *A2RPPHWDecodeEnvelope(NSData *json, id *outPlainValue, NSString **why) {
    if (json.length == 0) {
        if (why) { *why = @"信封 JSON 为空"; }
        return nil;
    }
    NSError *err = nil;
    id root = [NSJSONSerialization JSONObjectWithData:json options:0 error:&err];
    if (![root isKindOfClass:[NSDictionary class]]) {
        if (why) {
            *why = [NSString stringWithFormat:@"信封不是 JSON 对象（%@）",
                    err.localizedDescription ?: @"类型不符"];
        }
        return nil;
    }
    id plain = A2RPPHWDescend(root, @[ @"message", @"plain", @"_0" ]);
    if (outPlainValue) {
        *outPlainValue = plain ?: root;
    }
    return (NSDictionary *)root;
}

#pragma mark - 握手

NSDictionary *A2RPPHWDeviceOptions(void) {
    // ★allowsPinlessPairing = NO★：本机不是「免码」的宿主 ⇒ 设备必须让用户输 6 位码。
    // ★allowsPairSetup = YES★：允许设备用 SRP 配对（而不是只能 pair-verify）。
    return @{
        @"allowsPairSetup": @YES,
        @"allowsPinlessPairing": @NO,
        @"allowsIncomingTunnelConnections": @NO,
        @"allowsUpgradeOfLockdownPairings": @NO,
        @"allowsSharingSensitiveInfo": @NO,
    };
}

NSDictionary *A2RPPHWHandshakeResponse(NSString *name,
                                       NSString *model,
                                       NSString *identifier,
                                       NSString *udid,
                                       NSUInteger wireVersion) {
    NSDictionary *peerInfo = @{
        @"udid": udid ?: @"",
        @"deviceKVSIncludesSensitiveInfo": @NO,
        @"identifier": identifier ?: @"",
        @"name": name ?: @"",
        @"model": model ?: @"",
    };
    NSDictionary *handshake = @{
        @"wireProtocolVersion": @(wireVersion),
        @"minimumSupportedWireProtocolVersion": @(A2RPPHWMinimumWireProtocolVersion),
        @"deviceOptions": A2RPPHWDeviceOptions(),
        @"peerDeviceInfo": peerInfo,
    };
    return @{
        @"response": @{
            @"forRequestIdentifier": @0,
            @"_1": @{ @"handshake": @{ @"_0": handshake } },
        },
    };
}

BOOL A2RPPHWIsHandshakeRequest(id plainValue) {
    return A2RPPHWDescend(plainValue, @[ @"request", @"_0", @"handshake", @"_0" ]) != nil;
}

BOOL A2RPPHWHandshakeWantsPairVerify(id plainValue) {
    id hostOptions = A2RPPHWDescend(plainValue, @[ @"request", @"_0", @"handshake", @"_0", @"hostOptions" ]);
    return A2RPPHWIsTrue(A2RPPHWValueAt(hostOptions, @"attemptPairVerify"));
}

#pragma mark - pairingData 事件

NSDictionary *A2RPPHWEncodePairingDataEvent(NSString *base64TLV, NSString *kind, BOOL startNewSession) {
    return @{
        @"event": @{
            @"_0": @{
                @"pairingData": @{
                    @"_0": @{
                        @"data": base64TLV ?: @"",
                        @"startNewSession": @(startNewSession),
                        @"kind": (kind.length > 0 ? kind : @"setupManualPairing"),
                    },
                },
            },
        },
    };
}

BOOL A2RPPHWIsPairingDataEvent(id plainValue) {
    return A2RPPHWDescend(plainValue, @[ @"event", @"_0", @"pairingData", @"_0" ]) != nil;
}

NSData *A2RPPHWPairingDataFromEvent(id plainValue, NSString **outKind, NSString **why) {
    id payload = A2RPPHWDescend(plainValue, @[ @"event", @"_0", @"pairingData", @"_0" ]);
    if (![payload isKindOfClass:[NSDictionary class]]) {
        if (why) { *why = @"不是 pairingData 事件（缺 event._0.pairingData._0）"; }
        return nil;
    }
    if (outKind) {
        id kind = A2RPPHWValueAt(payload, @"kind");
        *outKind = [kind isKindOfClass:[NSString class]] ? kind : nil;
    }
    id data = A2RPPHWValueAt(payload, @"data");
    if (![data isKindOfClass:[NSString class]] || [(NSString *)data length] == 0) {
        if (why) { *why = @"pairingData 事件缺 data（或 data 不是 base64 字符串）"; }
        return nil;
    }
    NSData *tlv = [[NSData alloc] initWithBase64EncodedString:(NSString *)data options:0];
    if (tlv.length == 0) {
        if (why) { *why = @"pairingData.data 不是合法 base64"; }
        return nil;
    }
    return tlv;
}

#pragma mark - 判据

NSString *A2RPPHWHexPrefix(NSData *data, NSUInteger maxBytes) {
    if (data.length == 0) {
        return @"(none)";
    }
    NSUInteger n = MIN(maxBytes, data.length);
    const uint8_t *b = (const uint8_t *)data.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (NSUInteger i = 0; i < n; i++) {
        [s appendFormat:@"%02X", b[i]];
    }
    return s;
}

NSString *A2RPPHWCriterionLine(NSString *stage,
                               NSArray<NSString *> *txtKeys,
                               NSData *firstBytes,
                               BOOL m2Sent,
                               NSString *reason) {
    NSString *keys = (txtKeys.count > 0)
        ? [txtKeys componentsJoinedByString:@","]
        : @"(none)";
    return [NSString stringWithFormat:@"%@ stage=%@ txKeys=%@ firstBytes=%@ m2=%@ reason=%@",
            A2RPPHWCriterionMarker,
            stage.length > 0 ? stage : @"unknown",
            keys,
            A2RPPHWHexPrefix(firstBytes, 16),
            m2Sent ? @"ok" : @"fail",
            reason.length > 0 ? reason : @"(none)"];
}
