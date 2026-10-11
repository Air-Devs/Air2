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
#import "a2_rppairing_verify.h"     // [JIT-AUTOPAIR-2] pair-verify 自握手（自检里真跑一次）
#import "a2_rppairing_pairsetup.h"  // [JIT-AUTOPAIR-3] pair-setup(SRP-3072) 自握手（自检里真跑一次）

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

#pragma mark - TLV8 编解码

NSData *A2RPTLVEncode(NSArray<NSNumber *> *types, NSArray<NSData *> *values) {
    if (types.count == 0 || types.count != values.count) {
        return nil;                       // ★数量不符 ⇒ 不产半截数据（不静默）★
    }
    NSMutableData *out = [NSMutableData data];
    for (NSUInteger i = 0; i < types.count; i++) {
        NSData *v = values[i];
        if (v == nil || [v isKindOfClass:[NSNull class]]) {
            continue;                     // 可选字段缺席 ⇒ 该条目不输出
        }
        uint8_t type = (uint8_t)types[i].unsignedIntegerValue;
        NSUInteger off = 0;
        do {
            NSUInteger n = v.length - off;
            if (n > 255) {
                n = 255;                  // 规格：>255 字节拆成连续同型条目
            }
            uint8_t head[2] = { type, (uint8_t)n };
            [out appendBytes:head length:2];
            if (n > 0) {
                [out appendBytes:((const uint8_t *)v.bytes) + off length:n];
            }
            off += n;
        } while (off < v.length);
    }
    return out;
}

NSDictionary<NSNumber *, NSData *> *A2RPTLVDecode(NSData *data, NSString **errorReason) {
    if (data == nil) {
        if (errorReason) {
            *errorReason = @"数据为空";
        }
        return nil;
    }
    NSMutableDictionary<NSNumber *, NSMutableData *> *acc = [NSMutableDictionary dictionary];
    const uint8_t *b = (const uint8_t *)data.bytes;
    NSUInteger i = 0;
    while (i < data.length) {
        if (i + 2 > data.length) {
            if (errorReason) {
                *errorReason = [NSString stringWithFormat:@"TLV 头被截断（偏移 %lu）", (unsigned long)i];
            }
            return nil;
        }
        uint8_t type = b[i];
        NSUInteger len = b[i + 1];
        if (i + 2 + len > data.length) {
            if (errorReason) {
                *errorReason = [NSString stringWithFormat:@"TLV 值被截断（类型 0x%02x 声明 %lu 字节）",
                                type, (unsigned long)len];
            }
            return nil;
        }
        NSNumber *key = @(type);
        NSMutableData *slot = acc[key];
        if (slot == nil) {
            slot = [NSMutableData data];
            acc[key] = slot;
        }
        if (len > 0) {
            [slot appendBytes:b + i + 2 length:len];   // 相邻同型 ⇒ 拼接
        }
        i += 2 + len;
    }
    return [acc copy];
}

NSData *A2RPTLVValue(NSDictionary<NSNumber *, NSData *> *tlv, A2RPTLVType type) {
    if (tlv == nil) {
        return nil;
    }
    return tlv[@((uint8_t)type)];
}

NSInteger A2RPTLVStateValue(NSDictionary<NSNumber *, NSData *> *tlv) {
    NSData *d = A2RPTLVValue(tlv, A2RPTLVTypeState);
    if (d.length != 1) {
        return -1;
    }
    return (NSInteger)((const uint8_t *)d.bytes)[0];
}

#pragma mark - 本方身份

@interface A2RPPairingIdentity ()
@property (nonatomic, readwrite, copy) NSString *identifier;
@property (nonatomic, readwrite, copy) NSData *publicKey;
@property (nonatomic, readwrite, copy) NSData *privateKey;
@end

@implementation A2RPPairingIdentity

+ (nullable instancetype)identityWithHostName:(NSString *)hostName
                                        error:(NSError *_Nullable *_Nullable)error {
    if (hostName.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2RPPairing" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"主机名为空，无法派生 identifier"
            }];
        }
        return nil;
    }
    NSString *ident = A2RPPairingIdentifierForName(hostName);
    if (ident.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2RPPairing" code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"identifier 派生失败"
            }];
        }
        return nil;
    }
    uint8_t seed[A2RP_ED25519_KEY_BYTES], pub[A2RP_ED25519_KEY_BYTES];
    if (!A2RPRandomBytes(seed, sizeof(seed))) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2RPPairing" code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"CSPRNG 不可用（无法生成 Ed25519 种子）"
            }];
        }
        return nil;
    }
    if (A2RPEd25519PublicKey(pub, seed) != 1) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2RPPairing" code:4 userInfo:@{
                NSLocalizedDescriptionKey: @"Ed25519 公钥派生失败"
            }];
        }
        return nil;
    }
    A2RPPairingIdentity *ident2 = [A2RPPairingIdentity new];
    ident2.identifier = ident;
    ident2.privateKey = [NSData dataWithBytes:seed length:sizeof(seed)];
    ident2.publicKey = [NSData dataWithBytes:pub length:sizeof(pub)];
    memset(seed, 0, sizeof(seed));
    return ident2;
}

+ (nullable instancetype)identityWithPairingFileData:(NSData *)data
                                               error:(NSError *_Nullable *_Nullable)error {
    if (data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2RPPairing" code:10 userInfo:@{
                NSLocalizedDescriptionKey: @"配对文件为空"
            }];
        }
        return nil;
    }
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data
                                                                   options:0
                                                                    format:NULL
                                                                     error:NULL];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2RPPairing" code:11 userInfo:@{
                NSLocalizedDescriptionKey: @"不是合法 plist 字典"
            }];
        }
        return nil;
    }
    NSString *ident = plist[@"identifier"];
    NSData *pub = plist[@"public_key"];
    NSData *priv = plist[@"private_key"];
    if (![ident isKindOfClass:[NSString class]] || ident.length == 0
        || ![pub isKindOfClass:[NSData class]] || pub.length != A2RP_ED25519_KEY_BYTES
        || ![priv isKindOfClass:[NSData class]] || priv.length != A2RP_ED25519_KEY_BYTES) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2RPPairing" code:12 userInfo:@{
                NSLocalizedDescriptionKey: @"缺 identifier / public_key / private_key（或长度不是 32 字节）"
            }];
        }
        return nil;
    }
    // ★一致性自证★：private_key 必须真的派生出 public_key（否则身份不可信 ⇒ 拒绝）。
    uint8_t derived[A2RP_ED25519_KEY_BYTES];
    if (A2RPEd25519PublicKey(derived, priv.bytes) != 1
        || memcmp(derived, pub.bytes, A2RP_ED25519_KEY_BYTES) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2RPPairing" code:13 userInfo:@{
                NSLocalizedDescriptionKey: @"private_key 派生不出 public_key ⇒ 拒绝该配对文件"
            }];
        }
        return nil;
    }
    A2RPPairingIdentity *ident2 = [A2RPPairingIdentity new];
    ident2.identifier = ident;
    ident2.publicKey = pub;
    ident2.privateKey = priv;
    return ident2;
}

- (NSData *)pairingFileData {
    return A2RPPairingFileData(self.identifier, self.publicKey, self.privateKey);
}

- (NSData *)signMessage:(NSData *)message {
    if (self.privateKey.length != A2RP_ED25519_KEY_BYTES) {
        return nil;
    }
    uint8_t sig[A2RP_ED25519_SIG_BYTES];
    size_t len = message.length;
    if (A2RPEd25519Sign(sig, self.privateKey.bytes, len ? message.bytes : NULL, len) != 1) {
        return nil;
    }
    return [NSData dataWithBytes:sig length:sizeof(sig)];
}

+ (BOOL)verifySignature:(NSData *)signature
              forMessage:(NSData *)message
              publicKey:(NSData *)publicKey {
    if (signature.length != A2RP_ED25519_SIG_BYTES || publicKey.length != A2RP_ED25519_KEY_BYTES) {
        return NO;
    }
    size_t len = message.length;
    return A2RPEd25519Verify(publicKey.bytes, len ? message.bytes : NULL, len, signature.bytes) == 1;
}

@end

#pragma mark - 完成度自检

@interface A2RPPairingPreflight ()
@property (nonatomic, readwrite) BOOL randomOK;
@property (nonatomic, readwrite) BOOL keyAgreementOK;
@property (nonatomic, readwrite) BOOL signingOK;
@property (nonatomic, readwrite) BOOL streamCipherOK;
@property (nonatomic, readwrite) BOOL pairVerifyOK;
@property (nonatomic, readwrite, copy) NSString *pairVerifySummary;
@property (nonatomic, readwrite) BOOL pairSetupOK;
@property (nonatomic, readwrite, copy) NSString *pairSetupSummary;
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
        case A2RPPairingBlockedStepPairVerify:   return @"PairVerify(自握手)";
        case A2RPPairingBlockedStepRsdEndpoint:  return @"RsdEndpoint(设备端点:Bonjour/RSD/TLS-PSK)";
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

    // ★握手本体自证★：原语齐了才跑（否则自握手必失败，报出来的原因会误导）。
    BOOL cryptoReady = p.randomOK && p.keyAgreementOK && p.signingOK && p.streamCipherOK;
    if (cryptoReady) {
        A2RPPairVerifySelfTest *st = [A2RPPairVerifySelfTest runSelfTest];
        p.pairVerifyOK = st.ok;
        p.pairVerifySummary = st.summary;
        // [JIT-AUTOPAIR-3] pair-setup（SRP-3072）消息机自证：真跑 PS-Msg01..06。
        A2RPPairSetupSelfTest *ps = [A2RPPairSetupSelfTest runSelfTest];
        p.pairSetupOK = ps.ok;
        p.pairSetupSummary = ps.summary;
    } else {
        p.pairVerifyOK = NO;
        p.pairVerifySummary = @"未跑 pair-verify 自握手（前置原语未全绿）";
        p.pairSetupOK = NO;
        p.pairSetupSummary = @"未跑 pair-setup 自握手（前置原语未全绿）";
    }

    A2RPPairingBlockedStep blocked = A2RPPairingBlockedStepNone;
    if (!p.randomOK) {
        blocked = A2RPPairingBlockedStepRandom;
    } else if (!p.keyAgreementOK) {
        blocked = A2RPPairingBlockedStepKeyAgreement;
    } else if (!p.signingOK) {
        blocked = A2RPPairingBlockedStepSigningKey;
    } else if (!p.streamCipherOK) {
        blocked = A2RPPairingBlockedStepStreamCipher;
    } else if (!p.pairVerifyOK) {
        blocked = A2RPPairingBlockedStepPairVerify;
    } else if (!p.pairSetupOK) {
        blocked = A2RPPairingBlockedStepPairSetup;
    } else {
        // ★本地能做的都做完了★：剩下的卡点是「真 RSD 端点」——
        // Bonjour 发现 / 连接 / TLS-PSK 隧道（见 a2_rppairing_rsd.h），不是本地原语。
        // （pair-setup 的传输在真机上走 §2a/§2b RemoteXPC，§2c 裸 socket 不支持它 —— 见 pairsetup 头。）
        blocked = A2RPPairingBlockedStepRsdEndpoint;
    }
    p.firstBlockedStep = blocked;

    p.summary = [NSString stringWithFormat:
                 @"RPPairing 握手自检：CSPRNG=%@ X25519/HKDF=%@ Ed25519=%@ ChaCha20-Poly1305=%@ "
                 @"pair-verify 自握手=%@ pair-setup 自握手=%@ ⇒ 首个受阻步骤=%@",
                 p.randomOK ? @"可用" : @"不可用",
                 p.keyAgreementOK ? @"可用（双向一致）" : @"不可用",
                 p.signingOK ? @"可用（签/验/拒坏签名）" : @"自检未过",
                 p.streamCipherOK ? @"可用（往返/拒坏 tag）" : @"自检未过",
                 p.pairVerifyOK ? @"通过" : @"未通过",
                 p.pairSetupOK ? @"通过" : @"未通过",
                 [self displayNameForBlockedStep:blocked]];
    return p;
}

@end
