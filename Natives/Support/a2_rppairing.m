//
//  a2_rppairing.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [JIT-AUTOPAIR-2] RPPairing 线上编解码 + 完成度自检实现（纯逻辑，无网络、无写盘）。
//

#import "a2_rppairing.h"

#include <string.h>

const char *const A2RPPairingMagic = "RPPairing";

#pragma mark - 线上帧

BOOL A2RPFrameReadLength(NSData *buffer, NSUInteger *payloadLengthOut) {
    if (buffer == nil || buffer.length < A2RP_PAIRING_MAGIC_BYTES + A2RP_PAIRING_LENGTH_BYTES) {
        return NO;
    }
    const uint8_t *b = (const uint8_t *)buffer.bytes;
    if (memcmp(b, A2RPPairingMagic, A2RP_PAIRING_MAGIC_BYTES) != 0) {
        return NO;
    }
    if (payloadLengthOut) {
        *payloadLengthOut = ((NSUInteger)b[A2RP_PAIRING_MAGIC_BYTES] << 8)
                          | (NSUInteger)b[A2RP_PAIRING_MAGIC_BYTES + 1];
    }
    return YES;
}

NSData *A2RPFrameEncode(NSData *payload) {
    if (payload == nil) {
        payload = [NSData data];
    }
    if (payload.length > 0xFFFFu) {
        return nil;   // 2 字节长度装不下（如实返回失败，不截断）
    }
    NSMutableData *out = [NSMutableData dataWithCapacity:
                          A2RP_PAIRING_MAGIC_BYTES + A2RP_PAIRING_LENGTH_BYTES + payload.length];
    [out appendBytes:A2RPPairingMagic length:A2RP_PAIRING_MAGIC_BYTES];
    uint8_t len[2] = {
        (uint8_t)((payload.length >> 8) & 0xFF),
        (uint8_t)(payload.length & 0xFF)
    };
    [out appendBytes:len length:A2RP_PAIRING_LENGTH_BYTES];
    [out appendData:payload];
    return out;
}

NSData *A2RPFrameEncodeEnvelope(NSDictionary<NSString *, id> *envelope,
                                NSString *_Nullable *_Nullable errorReason) {
    if (envelope == nil || ![NSJSONSerialization isValidJSONObject:envelope]) {
        if (errorReason) {
            *errorReason = @"信封不是合法 JSON 对象（无法序列化）";
        }
        return nil;
    }
    NSError *jsonErr = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:&jsonErr];
    if (json == nil) {
        if (errorReason) {
            *errorReason = [NSString stringWithFormat:@"信封 JSON 序列化失败：%@",
                            jsonErr.localizedDescription ?: @"未知"];
        }
        return nil;
    }
    NSData *frame = A2RPFrameEncode(json);
    if (frame == nil && errorReason) {
        *errorReason = @"载荷超过 65535 字节（帧长度字段装不下）";
    }
    return frame;
}

BOOL A2RPFramePop(NSData *buffer,
                  NSUInteger *consumedOut,
                  NSData *_Nullable *_Nullable payloadOut,
                  NSString *_Nullable *_Nullable errorOut) {
    NSUInteger need = A2RP_PAIRING_MAGIC_BYTES + A2RP_PAIRING_LENGTH_BYTES;
    if (buffer == nil || buffer.length < need) {
        if (errorOut) {
            *errorOut = @"帧未收全（不足帧头 11 字节）";
        }
        return NO;
    }
    const uint8_t *b = (const uint8_t *)buffer.bytes;
    if (memcmp(b, A2RPPairingMagic, A2RP_PAIRING_MAGIC_BYTES) != 0) {
        if (errorOut) {
            *errorOut = @"帧头 magic 不匹配（非 RPPairing 流）";
        }
        return NO;
    }
    NSUInteger payloadLen = ((NSUInteger)b[A2RP_PAIRING_MAGIC_BYTES] << 8)
                          | (NSUInteger)b[A2RP_PAIRING_MAGIC_BYTES + 1];
    NSUInteger total = need + payloadLen;
    if (buffer.length < total) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"帧载荷未收全（需 %lu，现有 %lu）",
                         (unsigned long)total, (unsigned long)buffer.length];
        }
        return NO;
    }
    if (payloadOut) {
        *payloadOut = [buffer subdataWithRange:NSMakeRange(need, payloadLen)];
    }
    if (consumedOut) {
        *consumedOut = total;
    }
    return YES;
}

#pragma mark - 信封

NSDictionary<NSString *, id> *A2RPEnvelopePlain(NSDictionary<NSString *, id> *payload,
                                                NSString *originatedBy,
                                                NSInteger sequenceNumber) {
    return @{
        @"message": @{ @"plain": @{ @"_0": payload ?: @{} } },
        @"originatedBy": originatedBy ?: @"host",
        @"sequenceNumber": @(sequenceNumber),
    };
}

NSDictionary<NSString *, id> *A2RPEnvelopeStreamEncrypted(NSString *base64Ciphertext,
                                                          NSString *originatedBy,
                                                          NSInteger sequenceNumber) {
    return @{
        @"message": @{ @"streamEncrypted": @{ @"_0": base64Ciphertext ?: @"" } },
        @"originatedBy": originatedBy ?: @"host",
        @"sequenceNumber": @(sequenceNumber),
    };
}

#pragma mark - 标识符 / 配对文件

NSString *A2RPPairingIdentifierForName(NSString *name) {
    if (name.length == 0) {
        return nil;
    }
    uint8_t u[16];
    if (!A2RPUUIDv3FromName(name, u)) {
        return nil;
    }
    return [NSString stringWithFormat:
            @"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
            u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]];
}

NSData *A2RPPairingFileData(NSString *identifier,
                            NSData *publicKey,
                            NSData *privateKey) {
    if (identifier.length == 0 || publicKey.length == 0 || privateKey.length == 0) {
        return nil;
    }
    // 与 RpPairingFile 一致的字段集（identifier / public_key / private_key）。
    // 顺序固定写法（字典无序，plist 输出稳定与否不重要 —— 解析方按键取）。
    NSDictionary<NSString *, id> *plist = @{
        @"identifier": identifier,
        @"public_key": publicKey,
        @"private_key": privateKey,
    };
    return [NSPropertyListSerialization dataWithPropertyList:plist
                                                      format:NSPropertyListXMLFormat_v1_0
                                                     options:0
                                                       error:NULL];
}

#pragma mark - 完成度自检

@interface A2RPPairingPreflight ()
@property (nonatomic, readwrite) BOOL randomOK;
@property (nonatomic, readwrite) BOOL keyAgreementOK;
@property (nonatomic, readwrite) BOOL signingOK;
@property (nonatomic, readwrite) BOOL streamCipherOK;
@property (nonatomic, readwrite) A2RPPairingBlockedStep firstBlockedStep;
@property (nonatomic, readwrite, copy) NSString *summary;
@end

@implementation A2RPPairingPreflight

+ (NSString *)displayNameForBlockedStep:(A2RPPairingBlockedStep)step {
    switch (step) {
        case A2RPPairingBlockedStepNone:         return @"None";
        case A2RPPairingBlockedStepRandom:       return @"Random";
        case A2RPPairingBlockedStepKeyAgreement: return @"KeyAgreement";
        case A2RPPairingBlockedStepSigningKey:   return @"SigningKey(Ed25519)";
        case A2RPPairingBlockedStepStreamCipher: return @"StreamCipher(ChaCha20-Poly1305)";
        case A2RPPairingBlockedStepPairSetup:    return @"PairSetup(SRP-3072)";
        default:                                 return @"Unknown";
    }
}

/// 真跑一次双向 X25519：a 用 b 的公钥、b 用 a 的公钥，两边共享密钥必须相等。
/// 这是「已落地原语确实可用」的运行期自证（不是查缓存、不是假设）。
static BOOL A2RPX25519AgreementSelfTest(void) {
    uint8_t a[A2RP_X25519_KEY_BYTES], b[A2RP_X25519_KEY_BYTES];
    uint8_t aPub[A2RP_X25519_KEY_BYTES], bPub[A2RP_X25519_KEY_BYTES];
    uint8_t s1[A2RP_X25519_KEY_BYTES], s2[A2RP_X25519_KEY_BYTES];
    if (!A2RPRandomBytes(a, sizeof(a)) || !A2RPRandomBytes(b, sizeof(b))) {
        return NO;
    }
    if (!A2RPX25519PublicKey(aPub, a) || !A2RPX25519PublicKey(bPub, b)) {
        return NO;
    }
    if (!A2RPX25519(s1, a, bPub) || !A2RPX25519(s2, b, aPub)) {
        return NO;
    }
    // 全零共享密钥意味着协商失败（无效公钥的小子群），视为不可用。
    uint8_t acc = 0;
    for (int i = 0; i < A2RP_X25519_KEY_BYTES; i++) {
        acc |= s1[i];
    }
    if (acc == 0) {
        return NO;
    }
    return memcmp(s1, s2, A2RP_X25519_KEY_BYTES) == 0;
}

+ (instancetype)run {
    A2RPPairingPreflight *p = [A2RPPairingPreflight new];

    uint8_t probe[A2RP_SYMMETRIC_KEY_BYTES];
    p.randomOK = A2RPRandomBytes(probe, sizeof(probe));
    p.keyAgreementOK = A2RPX25519AgreementSelfTest();
    p.signingOK = A2RPEd25519Available();
    p.streamCipherOK = A2RPChaCha20Poly1305Available();

    A2RPPairingBlockedStep blocked = A2RPPairingBlockedStepNone;
    if (!p.randomOK) {
        blocked = A2RPPairingBlockedStepRandom;
    } else if (!p.keyAgreementOK) {
        blocked = A2RPPairingBlockedStepKeyAgreement;
    } else if (!p.signingOK) {
        blocked = A2RPPairingBlockedStepSigningKey;
    } else if (!p.streamCipherOK) {
        blocked = A2RPPairingBlockedStepStreamCipher;
    } else {
        // 原语齐了才轮到「SRP-3072 初始配对消息机」这一环（本阶段未落地）。
        blocked = A2RPPairingBlockedStepPairSetup;
    }
    p.firstBlockedStep = blocked;

    p.summary = [NSString stringWithFormat:
                 @"RPPairing 握手自检：CSPRNG=%@ X25519/HKDF=%@ Ed25519=%@ ChaCha20-Poly1305=%@ ⇒ 首个受阻步骤=%@",
                 p.randomOK ? @"可用" : @"不可用",
                 p.keyAgreementOK ? @"可用（双向一致）" : @"不可用",
                 p.signingOK ? @"可用" : @"未落地",
                 p.streamCipherOK ? @"可用" : @"未落地",
                 [self displayNameForBlockedStep:blocked]];
    return p;
}

@end
