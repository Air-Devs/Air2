//
//  a2_rppairing_verify.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [JIT-AUTOPAIR-2] RPPairing pair-verify 握手本体实现。协议出处与范围声明见头文件。
//

#import "a2_rppairing_verify.h"
#import "a2_rppairing_crypto.h"

#pragma mark - 协议常量（公开规格 §8：nonce 与 HKDF 标签都是协议规定的字面量）

static const char *const kA2RPPVSaltVerify = "Pair-Verify-Encrypt-Salt";
static const char *const kA2RPPVInfoVerify = "Pair-Verify-Encrypt-Info";
static const char *const kA2RPPVInfoClient = "ClientEncrypt-main";
static const char *const kA2RPPVInfoServer = "ServerEncrypt-main";

/// nonce = 4 个 0 字节 + ASCII 标签（12 字节）。
static NSData *A2RPPVNonce(const char *tag) {
    NSMutableData *d = [NSMutableData dataWithLength:12];
    memcpy((uint8_t *)d.mutableBytes + 4, tag, 8);
    return d;
}

#pragma mark - 会话

@interface A2RPPairVerifySession ()
@property (nonatomic, readwrite) A2RPPairVerifyRole role;
@property (nonatomic, readwrite) A2RPPairVerifyStep step;
@property (nonatomic, readwrite, strong) A2RPPairingIdentity *identity;
@property (nonatomic, readwrite, copy) NSData *peerPublicKey;
@property (nonatomic, readwrite, copy, nullable) NSData *sharedSecret;
@property (nonatomic, readwrite, copy, nullable) NSData *clientKey;
@property (nonatomic, readwrite, copy, nullable) NSData *serverKey;

/// 本方的临时 X25519 私钥 / 公钥。
@property (nonatomic, copy) NSData *ephemeralPrivate;
@property (nonatomic, copy) NSData *ephemeralPublic;
/// 对端的临时 X25519 公钥（收到 M1 / M2 后填）。
@property (nonatomic, copy, nullable) NSData *peerEphemeral;
/// pair-verify 加密密钥（HKDF 派生，建立后擦除）。
@property (nonatomic, copy, nullable) NSData *verifyKey;
/// 会话建立前的「已验证过对端证明」标记。
@property (nonatomic) BOOL peerProofVerified;
@end

@implementation A2RPPairVerifySession

+ (nullable instancetype)sessionWithRole:(A2RPPairVerifyRole)role
                                identity:(A2RPPairingIdentity *)identity
                           peerPublicKey:(NSData *)peerPublicKey
                                  reason:(NSString *_Nullable *_Nullable)reason {
    if (identity == nil || identity.privateKey.length != A2RP_ED25519_KEY_BYTES) {
        if (reason) {
            *reason = @"本方身份缺失或私钥长度不是 32 字节";
        }
        return nil;
    }
    if (peerPublicKey != nil && peerPublicKey.length != A2RP_ED25519_KEY_BYTES) {
        if (reason) {
            *reason = @"对端 Ed25519 公钥长度不是 32 字节";
        }
        return nil;
    }
    if (peerPublicKey == nil && role == A2RPPairVerifyRoleDevice) {
        if (reason) {
            *reason = @"Device 角色必须给出对端（Host）Ed25519 公钥用于验签";
        }
        return nil;
    }
    A2RPPairVerifySession *s = [A2RPPairVerifySession new];
    s.role = role;
    s.identity = identity;
    s.peerPublicKey = peerPublicKey;
    s.step = A2RPPairVerifyStepIdle;

    uint8_t priv[A2RP_X25519_KEY_BYTES], pub[A2RP_X25519_KEY_BYTES];
    if (!A2RPRandomBytes(priv, sizeof(priv))) {
        if (reason) {
            *reason = @"CSPRNG 不可用（无法生成临时 X25519 密钥）";
        }
        return nil;
    }
    if (A2RPX25519PublicKey(pub, priv) != 1) {
        if (reason) {
            *reason = @"X25519 公钥派生失败（原语不可用）";
        }
        return nil;
    }
    s.ephemeralPrivate = [NSData dataWithBytes:priv length:sizeof(priv)];
    s.ephemeralPublic = [NSData dataWithBytes:pub length:sizeof(pub)];
    memset(priv, 0, sizeof(priv));
    return s;
}

- (BOOL)established {
    return self.step == A2RPPairVerifyStepEstablished;
}

#pragma mark - 发送侧

- (NSData *_Nullable)nextMessageWithReason:(NSString *_Nullable *_Nullable)reason {
    if (self.role == A2RPPairVerifyRoleHost) {
        if (self.step == A2RPPairVerifyStepIdle) {
            // M1：State=1 + 本方临时公钥
            NSData *msg = A2RPTLVEncode(@[ @(A2RPTLVTypeState), @(A2RPTLVTypePublicKey) ],
                                        @[ [NSData dataWithBytes:"\x01" length:1], self.ephemeralPublic ]);
            self.step = A2RPPairVerifyStepMsg01;
            return msg;
        }
        if (self.step == A2RPPairVerifyStepMsg02) {
            // M3：State=3 + EncryptedData（内含 Identifier + Signature）
            if (self.peerEphemeral == nil || self.verifyKey == nil) {
                if (reason) {
                    *reason = @"尚未收到对端 M2（缺临时公钥/派生密钥）";
                }
                return nil;
            }
            NSMutableData *signedBuf = [NSMutableData data];
            [signedBuf appendData:self.ephemeralPublic];                    // x_pub
            [signedBuf appendData:[self.identity.identifier
                                   dataUsingEncoding:NSUTF8StringEncoding]];  // identifier
            [signedBuf appendData:self.peerEphemeral];                      // device_pub
            NSData *sig = [self.identity signMessage:signedBuf];
            if (sig == nil) {
                if (reason) {
                    *reason = @"Ed25519 签名失败";
                }
                return nil;
            }
            NSData *inner = A2RPTLVEncode(@[ @(A2RPTLVTypeIdentifier), @(A2RPTLVTypeSignature) ],
                                          @[ [self.identity.identifier dataUsingEncoding:NSUTF8StringEncoding],
                                             sig ]);
            NSData *sealed = [self sealPayload:inner nonceTag:"PV-Msg03" reason:reason];
            if (sealed == nil) {
                return nil;
            }
            NSData *msg = A2RPTLVEncode(@[ @(A2RPTLVTypeState), @(A2RPTLVTypeEncryptedData) ],
                                        @[ [NSData dataWithBytes:"\x03" length:1], sealed ]);
            self.step = A2RPPairVerifyStepMsg03;
            return msg;
        }
        if (reason) {
            *reason = self.established ? @"已建立（无待发消息）" : @"Host 当前无待发消息（等待对端）";
        }
        return nil;
    }

    // Device 角色
    if (self.step == A2RPPairVerifyStepMsg01) {
        // M2：State=2 + device 临时公钥 + EncryptedData（本方证明）
        NSMutableData *signedBuf = [NSMutableData data];
        [signedBuf appendData:self.ephemeralPublic];
        [signedBuf appendData:[self.identity.identifier dataUsingEncoding:NSUTF8StringEncoding]];
        [signedBuf appendData:self.peerEphemeral];
        NSData *sig = [self.identity signMessage:signedBuf];
        if (sig == nil) {
            if (reason) {
                *reason = @"Ed25519 签名失败";
            }
            return nil;
        }
        NSData *inner = A2RPTLVEncode(@[ @(A2RPTLVTypeIdentifier), @(A2RPTLVTypeSignature) ],
                                      @[ [self.identity.identifier dataUsingEncoding:NSUTF8StringEncoding],
                                         sig ]);
        NSData *sealed = [self sealPayload:inner nonceTag:"PV-Msg02" reason:reason];
        if (sealed == nil) {
            return nil;
        }
        NSData *msg = A2RPTLVEncode(@[ @(A2RPTLVTypeState), @(A2RPTLVTypePublicKey),
                                       @(A2RPTLVTypeEncryptedData) ],
                                    @[ [NSData dataWithBytes:"\x02" length:1], self.ephemeralPublic, sealed ]);
        self.step = A2RPPairVerifyStepMsg02;
        return msg;
    }
    if (self.step == A2RPPairVerifyStepMsg03) {
        if (!self.peerProofVerified) {
            if (reason) {
                *reason = @"本方尚未验证对端(M3)的证明，拒绝进入 M4";
            }
            return nil;
        }
        NSData *msg = A2RPTLVEncode(@[ @(A2RPTLVTypeState) ], @[ [NSData dataWithBytes:"\x04" length:1] ]);
        if (![self deriveMainKeysWithReason:reason]) {
            return nil;
        }
        self.step = A2RPPairVerifyStepEstablished;
        return msg;
    }
    if (reason) {
        *reason = self.established ? @"已建立（无待发消息）" : @"Device 当前无待发消息（等待对端）";
    }
    return nil;
}

#pragma mark - 接收侧

- (BOOL)acceptMessage:(NSData *)tlv reason:(NSString *_Nullable *_Nullable)reason {
    NSString *perr = nil;
    NSDictionary<NSNumber *, NSData *> *dict = A2RPTLVDecode(tlv, &perr);
    if (dict == nil) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"对端消息不是合法 TLV8：%@", perr ?: @"未知"];
        }
        return NO;
    }
    // 任何状态下，对端带 Error ⇒ 如实失败（规格：回落到 pair-setup）。
    NSData *err = A2RPTLVValue(dict, A2RPTLVTypeError);
    if (err != nil) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"对端返回 ErrorResponse（长度 %lu）",
                       (unsigned long)err.length];
        }
        return NO;
    }
    NSInteger state = A2RPTLVStateValue(dict);
    if (state < 0) {
        if (reason) {
            *reason = @"对端消息缺 State（或长度不为 1）";
        }
        return NO;
    }

    // 期望的状态号（严格按消息流）
    NSInteger expect = 0;
    if (self.role == A2RPPairVerifyRoleHost) {
        expect = (self.step == A2RPPairVerifyStepMsg01) ? 2
               : (self.step == A2RPPairVerifyStepMsg03) ? 4 : -1;
    } else {
        expect = (self.step == A2RPPairVerifyStepIdle) ? 1
               : (self.step == A2RPPairVerifyStepMsg02) ? 3 : -1;
    }
    if (expect < 0 || state != expect) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"消息流顺序错：本方处于 step=%ld，收到 State=%ld",
                       (long)self.step, (long)state];
        }
        return NO;
    }

    if (state == 1 || state == 2) {
        NSData *pk = A2RPTLVValue(dict, A2RPTLVTypePublicKey);
        if (pk.length != A2RP_X25519_KEY_BYTES) {
            if (reason) {
                *reason = [NSString stringWithFormat:@"对端临时公钥长度不是 32 字节（%lu）",
                           (unsigned long)pk.length];
            }
            return NO;
        }
        self.peerEphemeral = pk;
        if (![self deriveSharedAndVerifyKeyWithReason:reason]) {
            return NO;
        }
    }

    if (state == 1) {
        // Device 已收到 M1：可以发 M2
        self.step = A2RPPairVerifyStepMsg01;
        return YES;
    }

    if (state == 2) {
        // Host：验证 device 的证明（M2 的 EncryptedData；规格 Step 6 说明可解 —— 我们解并验）
        NSData *enc = A2RPTLVValue(dict, A2RPTLVTypeEncryptedData);
        if (enc.length <= A2RP_AEAD_TAG_BYTES) {
            if (reason) {
                *reason = @"M2 缺 EncryptedData（或长度不足以含认证标签）";
            }
            return NO;
        }
        NSData *inner = [self openPayload:enc nonceTag:"PV-Msg02" reason:reason];
        if (inner == nil) {
            return NO;
        }
        if (self.peerPublicKey == nil) {
            // ★公开规格 §8 Step 6：设备那份证明「可不解」★ —— 缺设备公钥时如实跳过身份验签
            // （AEAD 认证仍然成立，密钥交换仍完成），并把「跳过」记进状态属性。
            self.peerProofVerified = NO;
        } else if (![self verifyPeerProof:inner reason:reason]) {
            return NO;
        } else {
            self.peerProofVerified = YES;
        }
        self.step = A2RPPairVerifyStepMsg02;
        return YES;
    }

    if (state == 3) {
        // Device：验证 host 的证明
        NSData *enc = A2RPTLVValue(dict, A2RPTLVTypeEncryptedData);
        if (enc.length <= A2RP_AEAD_TAG_BYTES) {
            if (reason) {
                *reason = @"M3 缺 EncryptedData（或长度不足以含认证标签）";
            }
            return NO;
        }
        NSData *inner = [self openPayload:enc nonceTag:"PV-Msg03" reason:reason];
        if (inner == nil) {
            return NO;
        }
        if (![self verifyPeerProof:inner reason:reason]) {
            return NO;
        }
        self.peerProofVerified = YES;
        self.step = A2RPPairVerifyStepMsg03;
        return YES;
    }

    if (state == 4) {
        // Host：对端确认；派生主密钥并进入 Established
        self.step = A2RPPairVerifyStepMsg04;
        if (![self deriveMainKeysWithReason:reason]) {
            return NO;
        }
        self.step = A2RPPairVerifyStepEstablished;
        return YES;
    }
    return NO;
}

#pragma mark - 密钥派生与证明校验

/// shared = X25519(本方临时私钥, 对端临时公钥)；verifyKey = HKDF-SHA512(…, "Pair-Verify-Encrypt-*")。
- (BOOL)deriveSharedAndVerifyKeyWithReason:(NSString *_Nullable *_Nullable)reason {
    uint8_t shared[A2RP_X25519_KEY_BYTES];
    if (A2RPX25519(shared, self.ephemeralPrivate.bytes, self.peerEphemeral.bytes) != 1) {
        if (reason) {
            *reason = @"X25519 密钥协商失败";
        }
        return NO;
    }
    uint8_t acc = 0;
    for (int i = 0; i < A2RP_X25519_KEY_BYTES; i++) {
        acc |= shared[i];
    }
    if (acc == 0) {
        if (reason) {
            *reason = @"X25519 共享密钥全零（对端公钥落在小子群）⇒ 拒绝";
        }
        return NO;
    }
    self.sharedSecret = [NSData dataWithBytes:shared length:sizeof(shared)];

    uint8_t vk[A2RP_SYMMETRIC_KEY_BYTES];
    BOOL ok = A2RPHKDF_SHA512(shared, sizeof(shared),
                              (const uint8_t *)kA2RPPVSaltVerify, strlen(kA2RPPVSaltVerify),
                              (const uint8_t *)kA2RPPVInfoVerify, strlen(kA2RPPVInfoVerify),
                              vk, sizeof(vk));
    memset(shared, 0, sizeof(shared));
    if (!ok) {
        if (reason) {
            *reason = @"HKDF-SHA512 派生 pair-verify 密钥失败";
        }
        return NO;
    }
    self.verifyKey = [NSData dataWithBytes:vk length:sizeof(vk)];
    memset(vk, 0, sizeof(vk));
    return YES;
}

/// 主密钥（公开规格 §10）：clientKey/serverKey = HKDF-SHA512(salt=无, ikm=shared, info=…-main)。
- (BOOL)deriveMainKeysWithReason:(NSString *_Nullable *_Nullable)reason {
    if (self.sharedSecret == nil) {
        if (reason) {
            *reason = @"尚无共享密钥，无法派生主密钥";
        }
        return NO;
    }
    uint8_t ck[A2RP_SYMMETRIC_KEY_BYTES], sk[A2RP_SYMMETRIC_KEY_BYTES];
    if (!A2RPHKDF_SHA512(self.sharedSecret.bytes, self.sharedSecret.length, NULL, 0,
                         (const uint8_t *)kA2RPPVInfoClient, strlen(kA2RPPVInfoClient), ck, sizeof(ck))
        || !A2RPHKDF_SHA512(self.sharedSecret.bytes, self.sharedSecret.length, NULL, 0,
                            (const uint8_t *)kA2RPPVInfoServer, strlen(kA2RPPVInfoServer), sk, sizeof(sk))) {
        if (reason) {
            *reason = @"HKDF-SHA512 派生主密钥失败";
        }
        return NO;
    }
    self.clientKey = [NSData dataWithBytes:ck length:sizeof(ck)];
    self.serverKey = [NSData dataWithBytes:sk length:sizeof(sk)];
    memset(ck, 0, sizeof(ck));
    memset(sk, 0, sizeof(sk));
    self.verifyKey = nil;               // 握手完成 ⇒ 擦掉中间密钥
    return YES;
}

/// 用 pair-verify 密钥 + 指定 nonce 加密（输出 = 密文 ‖ 16 字节 tag）。
- (NSData *_Nullable)sealPayload:(NSData *)plain
                        nonceTag:(const char *)tag
                          reason:(NSString *_Nullable *_Nullable)reason {
    if (self.verifyKey == nil) {
        if (reason) {
            *reason = @"pair-verify 密钥未派生（未收到对端临时公钥）";
        }
        return nil;
    }
    NSData *nonce = A2RPPVNonce(tag);
    NSMutableData *out = [NSMutableData dataWithLength:plain.length + A2RP_AEAD_TAG_BYTES];
    uint8_t tagOut[A2RP_AEAD_TAG_BYTES];
    if (A2RPChaCha20Poly1305Seal((uint8_t *)out.mutableBytes, tagOut,
                                 self.verifyKey.bytes, nonce.bytes,
                                 NULL, 0,
                                 plain.length ? plain.bytes : NULL, plain.length) != 1) {
        if (reason) {
            *reason = @"ChaCha20-Poly1305 加密失败";
        }
        return nil;
    }
    [out replaceBytesInRange:NSMakeRange(plain.length, A2RP_AEAD_TAG_BYTES) withBytes:tagOut];
    return out;
}

/// 解密并认证（密文 = 密文 ‖ tag）。失败 ⇒ nil + reason。
- (NSData *_Nullable)openPayload:(NSData *)sealed
                        nonceTag:(const char *)tag
                          reason:(NSString *_Nullable *_Nullable)reason {
    if (self.verifyKey == nil) {
        if (reason) {
            *reason = @"pair-verify 密钥未派生";
        }
        return nil;
    }
    NSData *nonce = A2RPPVNonce(tag);
    NSUInteger ctLen = sealed.length - A2RP_AEAD_TAG_BYTES;
    NSMutableData *pt = [NSMutableData dataWithLength:ctLen];
    if (A2RPChaCha20Poly1305Open((uint8_t *)pt.mutableBytes, self.verifyKey.bytes, nonce.bytes,
                                 NULL, 0, sealed.bytes, ctLen,
                                 (const uint8_t *)sealed.bytes + ctLen) != 1) {
        if (reason) {
            *reason = @"对端密文认证失败（pair-verify 密钥不符 / 被篡改）⇒ 拒绝";
        }
        return nil;
    }
    return pt;
}

/// 校验对端证明：TLV{Identifier, Signature}，签名对象 = 双方临时公钥 + 对端 identifier。
- (BOOL)verifyPeerProof:(NSData *)inner reason:(NSString *_Nullable *_Nullable)reason {
    NSString *perr = nil;
    NSDictionary<NSNumber *, NSData *> *dict = A2RPTLVDecode(inner, &perr);
    if (dict == nil) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"对端证明不是合法 TLV8：%@", perr ?: @"未知"];
        }
        return NO;
    }
    NSData *identData = A2RPTLVValue(dict, A2RPTLVTypeIdentifier);
    NSData *sig = A2RPTLVValue(dict, A2RPTLVTypeSignature);
    if (identData.length == 0 || sig.length != A2RP_ED25519_SIG_BYTES) {
        if (reason) {
            *reason = @"对端证明缺 Identifier / Signature（或签名长度不是 64）";
        }
        return NO;
    }
    NSString *peerIdent = [[NSString alloc] initWithData:identData encoding:NSUTF8StringEncoding];
    if (peerIdent.length == 0) {
        if (reason) {
            *reason = @"对端 Identifier 不是合法 UTF-8 字符串";
        }
        return NO;
    }

    // 签名对象：对端临时公钥 ‖ 对端 identifier ‖ 本方临时公钥
    NSMutableData *signedBuf = [NSMutableData data];
    [signedBuf appendData:self.peerEphemeral];
    [signedBuf appendData:identData];
    [signedBuf appendData:self.ephemeralPublic];

    if (![A2RPPairingIdentity verifySignature:sig forMessage:signedBuf publicKey:self.peerPublicKey]) {
        if (reason) {
            *reason = @"对端 Ed25519 签名校验失败 ⇒ 拒绝（对端身份不可信）";
        }
        return NO;
    }
    return YES;
}

@end

#pragma mark - 自握手（运行期自证）

@interface A2RPPairVerifySelfTest ()
@property (nonatomic, readwrite) BOOL ok;
@property (nonatomic, readwrite, copy) NSString *summary;
@property (nonatomic, readwrite) BOOL secretsEqual;
@property (nonatomic, readwrite) BOOL mainKeysCrossEqual;
@property (nonatomic, readwrite) BOOL tamperRejected;
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *messageSizes;
@end

@implementation A2RPPairVerifySelfTest

/// 真跑一次 M1→M4 的消息流；任一步失败 ⇒ 返回 NO 并把原因写进 *why。
/// （单独函数而不是 goto：ARC 下 goto 跨过强引用初始化是非法的。）
static BOOL A2RPPVRunExchange(A2RPPairVerifySession *host,
                              A2RPPairVerifySession *dev,
                              NSMutableArray<NSNumber *> *sizes,
                              BOOL *tamperRejected,
                              NSString **why) {
    NSData *m1 = [host nextMessageWithReason:why];
    if (m1 == nil) { return NO; }
    [sizes addObject:@(m1.length)];
    if (![dev acceptMessage:m1 reason:why]) { return NO; }
    NSData *m2 = [dev nextMessageWithReason:why];
    if (m2 == nil) { return NO; }
    [sizes addObject:@(m2.length)];

    // ★篡改检测★：把 M2 的认证标签改一位 —— 真 Host 必须先拒，再接受未篡改的 M2。
    NSMutableData *bad = [m2 mutableCopy];
    ((uint8_t *)bad.mutableBytes)[bad.length - 1] ^= 0x01;
    NSString *treason = nil;
    if ([host acceptMessage:bad reason:&treason]) {
        *why = @"篡改过的 M2 被接受（本应被 AEAD 认证拒绝）";
        return NO;
    }
    *tamperRejected = YES;

    if (![host acceptMessage:m2 reason:why]) { return NO; }
    NSData *m3 = [host nextMessageWithReason:why];
    if (m3 == nil) { return NO; }
    [sizes addObject:@(m3.length)];
    if (![dev acceptMessage:m3 reason:why]) { return NO; }
    NSData *m4 = [dev nextMessageWithReason:why];
    if (m4 == nil) { return NO; }
    [sizes addObject:@(m4.length)];

    if (![host acceptMessage:m4 reason:why]) { return NO; }
    return YES;
}

+ (A2RPPairVerifySelfTest *)runSelfTest {
    A2RPPairVerifySelfTest *r = [A2RPPairVerifySelfTest new];
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
    NSString *why = nil;
    BOOL tamperRejected = NO;

    NSError *e1 = nil, *e2 = nil;
    A2RPPairingIdentity *hostID = [A2RPPairingIdentity identityWithHostName:@"air2-self-host" error:&e1];
    A2RPPairingIdentity *devID = [A2RPPairingIdentity identityWithHostName:@"air2-self-device" error:&e2];
    if (hostID == nil || devID == nil) {
        r.ok = NO;
        r.tamperRejected = NO;
        r.messageSizes = sizes;
        r.summary = [NSString stringWithFormat:@"自握手失败：身份生成失败（%@ / %@）",
                     e1.localizedDescription ?: @"-", e2.localizedDescription ?: @"-"];
        return r;
    }

    A2RPPairVerifySession *host = [A2RPPairVerifySession sessionWithRole:A2RPPairVerifyRoleHost
                                                               identity:hostID
                                                          peerPublicKey:devID.publicKey
                                                                 reason:&why];
    A2RPPairVerifySession *dev = [A2RPPairVerifySession sessionWithRole:A2RPPairVerifyRoleDevice
                                                              identity:devID
                                                         peerPublicKey:hostID.publicKey
                                                                reason:&why];
    if (host == nil || dev == nil) {
        r.ok = NO;
        r.tamperRejected = NO;
        r.messageSizes = sizes;
        r.summary = [NSString stringWithFormat:@"自握手失败：建会话失败（%@）", why ?: @"-"];
        return r;
    }

    BOOL stepOK = A2RPPVRunExchange(host, dev, sizes, &tamperRejected, &why);
    r.tamperRejected = tamperRejected;

    r.secretsEqual = (host.sharedSecret != nil) && [host.sharedSecret isEqualToData:dev.sharedSecret];
    // §10：两侧各自派生同一对 client/server 主密钥（Host 用 clientKey 加密、serverKey 解密；
    // Device 反过来用）。所以正确的不变量是「同名密钥两侧相同、两名互不相同」。
    r.mainKeysCrossEqual = (host.clientKey != nil)
                        && [host.clientKey isEqualToData:dev.clientKey]
                        && [host.serverKey isEqualToData:dev.serverKey]
                        && ![host.clientKey isEqualToData:host.serverKey]
                        && host.clientKey.length == A2RP_SYMMETRIC_KEY_BYTES
                        && host.serverKey.length == A2RP_SYMMETRIC_KEY_BYTES;
    r.ok = stepOK && host.established && dev.established && r.secretsEqual
        && r.mainKeysCrossEqual && r.tamperRejected && sizes.count == 4;

    NSString *sizesStr = sizes.count == 4
        ? [NSString stringWithFormat:@"%lu/%lu/%lu/%lu",
           (unsigned long)sizes[0].unsignedIntegerValue, (unsigned long)sizes[1].unsignedIntegerValue,
           (unsigned long)sizes[2].unsignedIntegerValue, (unsigned long)sizes[3].unsignedIntegerValue]
        : @"(不全)";
    if (r.ok) {
        r.summary = [NSString stringWithFormat:
                     @"pair-verify 自握手：M1..M4 = %@ 字节｜双方 PSK 一致=是｜主密钥交叉一致=是｜"
                     @"篡改 M2 被 AEAD 拒=是 ⇒ 通过", sizesStr];
    } else {
        r.summary = [NSString stringWithFormat:
                     @"pair-verify 自握手未通过：%@（消息流 %@｜PSK一致=%@｜主密钥=%@｜篡改被拒=%@）",
                     why ?: @"未知原因", sizesStr,
                     r.secretsEqual ? @"是" : @"否", r.mainKeysCrossEqual ? @"是" : @"否",
                     r.tamperRejected ? @"是" : @"否"];
    }
    r.messageSizes = sizes;
    return r;
}
@end
