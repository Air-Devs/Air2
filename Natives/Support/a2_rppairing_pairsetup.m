//
//  a2_rppairing_pairsetup.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [JIT-AUTOPAIR-3] RPPairing pair-setup 消息机实现。协议出处、做到哪一步、以及配对码注入缝见头文件。
//

#import "a2_rppairing_pairsetup.h"
#import "a2_rppairing_crypto.h"
#import "a2_rppairing_srp.h"

#include <string.h>

#pragma mark - 协议常量（公开规格 §9 规定的字面量；★只取事实，未取任何代码★）

static const char *const kA2RPPSUsername      = "Pair-Setup";                 // §9：Username
static const char *const kA2RPPSKind          = "setupManualPairing";         // §9：事件 kind
static const char *const kA2RPPSEncryptSalt    = "Pair-Setup-Encrypt-Salt";   // §9 Phase 3
static const char *const kA2RPPSEncryptInfo    = "Pair-Setup-Encrypt-Info";
static const char *const kA2RPPSCtrlSignSalt   = "Pair-Setup-Controller-Sign-Salt";
static const char *const kA2RPPSCtrlSignInfo   = "Pair-Setup-Controller-Sign-Info";
/// 设备侧签名材料标签：RPPairing 规格 §9 未给出设备侧派生，这里沿用公开 HomeKit(HAP) pair-setup 的
/// 同名约定（Pair-Setup-Accessory-Sign-*）。★仅用于本仓的 Device 自测角色；真机与真设备对拍前属未定项★。
static const char *const kA2RPPSAccSignSalt    = "Pair-Setup-Accessory-Sign-Salt";
static const char *const kA2RPPSAccSignInfo    = "Pair-Setup-Accessory-Sign-Info";

/// 12 字节 nonce = 4×0x00 || ASCII(tag8)（规格 §9 / §Appendix B 常量表）。
static NSData *A2RPPNonce(const char *tag8) {
    NSMutableData *d = [NSMutableData dataWithLength:A2RP_AEAD_NONCE_BYTES];
    memcpy((uint8_t *)d.mutableBytes + 4, tag8, 8);
    return d;
}

static NSData *A2RPPSOneByte(uint8_t b) {
    return [NSData dataWithBytes:&b length:1];
}

#pragma mark - 摘要 / HKDF / AEAD 小工具（复用已有件，不另造一套）

static NSData *A2RPPSHKDF(NSData *ikm, const char *salt, const char *info, size_t outLen) {
    if (ikm.length == 0) {
        return nil;
    }
    NSMutableData *out = [NSMutableData dataWithLength:outLen];
    if (!A2RPHKDF_SHA512(ikm.bytes, ikm.length,
                         (const uint8_t *)salt, salt ? strlen(salt) : 0,
                         (const uint8_t *)info, info ? strlen(info) : 0,
                         out.mutableBytes, outLen)) {
        return nil;
    }
    return out;
}

/// ChaCha20-Poly1305 加密：输出 = 密文 ‖ 16 字节 tag（AAD 空）。失败 ⇒ nil + reason。
static NSData *A2RPPSSeal(NSData *key, const char *tag8, NSData *plain, NSString **reason) {
    if (key.length != A2RP_CHACHA_KEY_BYTES) {
        if (reason) { *reason = @"加密密钥长度不为 32"; }
        return nil;
    }
    NSData *nonce = A2RPPNonce(tag8);
    NSMutableData *out = [NSMutableData dataWithLength:plain.length + A2RP_AEAD_TAG_BYTES];
    uint8_t tag[A2RP_AEAD_TAG_BYTES];
    if (A2RPChaCha20Poly1305Seal(out.mutableBytes, tag, key.bytes, nonce.bytes,
                                 NULL, 0,
                                 plain.length ? plain.bytes : NULL, plain.length) != 1) {
        if (reason) { *reason = @"ChaCha20-Poly1305 加密失败"; }
        return nil;
    }
    [out replaceBytesInRange:NSMakeRange(plain.length, A2RP_AEAD_TAG_BYTES) withBytes:tag];
    return out;
}

/// 解密并认证：输入 = 密文 ‖ tag。失败 ⇒ nil + reason（★认证失败一律拒绝★）。
static NSData *A2RPPSOpen(NSData *key, const char *tag8, NSData *sealed, NSString **reason) {
    if (key.length != A2RP_CHACHA_KEY_BYTES) {
        if (reason) { *reason = @"解密密钥长度不为 32"; }
        return nil;
    }
    if (sealed.length <= A2RP_AEAD_TAG_BYTES) {
        if (reason) { *reason = @"密文长度不足以含认证标签"; }
        return nil;
    }
    NSData *nonce = A2RPPNonce(tag8);
    NSUInteger ctLen = sealed.length - A2RP_AEAD_TAG_BYTES;
    NSMutableData *pt = [NSMutableData dataWithLength:ctLen];
    if (A2RPChaCha20Poly1305Open(pt.mutableBytes, key.bytes, nonce.bytes, NULL, 0,
                                 sealed.bytes, ctLen,
                                 (const uint8_t *)sealed.bytes + ctLen) != 1) {
        if (reason) { *reason = @"对端密文认证失败（密钥不符 / 被篡改）⇒ 拒绝"; }
        return nil;
    }
    return pt;
}

#pragma mark - OPack（公开规格 §6）：只做 pair-setup Msg05 需要的「字符串键字典」最小子集

static void A2RPOPackAppendLen(NSMutableData *out, NSUInteger n,
                               uint8_t shortBase, uint8_t u8, uint8_t u16, uint8_t u32) {
    if (n < 32) {
        uint8_t m = (uint8_t)(shortBase + n);
        [out appendBytes:&m length:1];
    } else if (n < 256) {
        uint8_t m = u8, l = (uint8_t)n;
        [out appendBytes:&m length:1];
        [out appendBytes:&l length:1];
    } else if (n < 65536) {
        uint8_t m = u16;
        uint8_t l[2] = { (uint8_t)(n & 0xFF), (uint8_t)((n >> 8) & 0xFF) };
        [out appendBytes:&m length:1];
        [out appendBytes:l length:2];
    } else {
        uint8_t m = u32;
        uint8_t l[4] = { (uint8_t)(n & 0xFF), (uint8_t)((n >> 8) & 0xFF),
                         (uint8_t)((n >> 16) & 0xFF), (uint8_t)((n >> 24) & 0xFF) };
        [out appendBytes:&m length:1];
        [out appendBytes:l length:4];
    }
}

static void A2RPOPackString(NSMutableData *out, NSString *s) {
    NSData *b = [s dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    A2RPOPackAppendLen(out, b.length, 0x40, 0x61, 0x62, 0x63);
    [out appendData:b];
}

static void A2RPOPackData(NSMutableData *out, NSData *d) {
    A2RPOPackAppendLen(out, d.length, 0x70, 0x91, 0x92, 0x93);
    [out appendData:d];
}

/// 组装设备信息 blob（§9 Phase 3 的字典）。★字段值设备不校验★；altIRK 用 CSPRNG，取不到则用 0。
static NSData *A2RPOPackDeviceInfo(NSString *identifier, NSString *hostName) {
    uint8_t irk[16] = { 0 };
    A2RPRandomBytes(irk, sizeof(irk));
    const uint8_t mac[6] = { 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };

    NSArray<NSString *> *keys = @[ @"altIRK", @"btAddr", @"mac", @"remotepairing_serial_number",
                                   @"accountID", @"model", @"name" ];
    NSMutableData *out = [NSMutableData data];
    uint8_t marker = (uint8_t)(0xE0 + keys.count);   // count < 15 ⇒ 0xE0 + count
    [out appendBytes:&marker length:1];
    A2RPOPackString(out, keys[0]); A2RPOPackData(out, [NSData dataWithBytes:irk length:16]);
    A2RPOPackString(out, keys[1]); A2RPOPackString(out, @"11:22:33:44:55:66");
    A2RPOPackString(out, keys[2]); A2RPOPackData(out, [NSData dataWithBytes:mac length:6]);
    A2RPOPackString(out, keys[3]); A2RPOPackString(out, @"AAAAAAAAAAAA");
    A2RPOPackString(out, keys[4]); A2RPOPackString(out, identifier ?: @"");
    A2RPOPackString(out, keys[5]); A2RPOPackString(out, @"computer-model");
    A2RPOPackString(out, keys[6]); A2RPOPackString(out, hostName ?: @"");
    return out;
}

#pragma mark - 会话

@interface A2RPPairSetupSession ()
@property (nonatomic, readwrite) A2RPPairSetupRole role;
@property (nonatomic, readwrite) A2RPPairSetupStep step;
@property (nonatomic, readwrite, strong) A2RPPairingIdentity *identity;
@property (nonatomic, readwrite, copy, nullable) NSData *sessionKey;
@property (nonatomic, readwrite, copy, nullable) NSString *peerIdentifier;
@property (nonatomic, readwrite, copy, nullable) NSData *peerPublicKey;
@property (nonatomic, readwrite, copy, nullable) NSData *peerInfoTLV;

@property (nonatomic, copy, nullable) A2RPPairSetupPinProvider pinProvider;
@property (nonatomic) A2RPPairSetupPinPrompt pinPromptHint;
@property (nonatomic, copy, nullable) NSString *devicePin;

// SRP
@property (nonatomic) A2RPSRPClient *srpClient;
@property (nonatomic) A2RPSRPServer *srpServer;

// 中间量
@property (nonatomic, copy, nullable) NSData *setupEncryptionKey;
@property (nonatomic, copy, nullable) NSData *controllerSigningMaterial;
@property (nonatomic, copy, nullable) NSData *accessorySigningMaterial;

// 我方保存的「对端下一步期望」等
@property (nonatomic) BOOL peerProofVerified;
@end

@implementation A2RPPairSetupSession

+ (nullable instancetype)hostSessionWithIdentity:(A2RPPairingIdentity *)identity
                                     pinProvider:(A2RPPairSetupPinProvider)pinProvider
                                          reason:(NSString **)reason {
    if (identity == nil || identity.privateKey.length != A2RP_ED25519_KEY_BYTES) {
        if (reason) { *reason = @"本方身份缺失或 Ed25519 私钥长度不是 32 字节"; }
        return nil;
    }
    if (pinProvider == nil) {
        if (reason) { *reason = @"未注入配对码来源（pinProvider 为空）⇒ 拒绝建 pair-setup 会话"; }
        return nil;
    }
    A2RPPairSetupSession *s = [A2RPPairSetupSession new];
    s.role = A2RPPairSetupRoleHost;
    s.identity = identity;
    s.pinProvider = pinProvider;
    s.pinPromptHint = A2RPPairSetupPinPromptOnDevice;
    s.step = A2RPPairSetupStepIdle;
    return s;
}

+ (nullable instancetype)deviceSessionWithIdentity:(A2RPPairingIdentity *)identity
                                               pin:(NSString *)pin
                                            reason:(NSString **)reason {
    if (identity == nil || identity.privateKey.length != A2RP_ED25519_KEY_BYTES) {
        if (reason) { *reason = @"设备身份缺失或 Ed25519 私钥长度不是 32 字节"; }
        return nil;
    }
    if (pin.length == 0) {
        if (reason) { *reason = @"设备侧配对码为空 ⇒ 拒绝建 pair-setup 会话"; }
        return nil;
    }
    A2RPPairSetupSession *s = [A2RPPairSetupSession new];
    s.role = A2RPPairSetupRoleDevice;
    s.identity = identity;
    s.devicePin = pin;
    s.step = A2RPPairSetupStepIdle;
    return s;
}

- (void)setPinPromptHint:(A2RPPairSetupPinPrompt)prompt {
    _pinPromptHint = prompt;
}

- (BOOL)established {
    return self.step == A2RPPairSetupStepEstablished;
}

- (void)dealloc {
    if (_srpClient != NULL) { A2RPSRPClientFree(_srpClient); _srpClient = NULL; }
    if (_srpServer != NULL) { A2RPSRPServerFree(_srpServer); _srpServer = NULL; }
}

#pragma mark 发送侧

- (NSData *_Nullable)nextMessageWithReason:(NSString *_Nullable *_Nullable)reason {
    if (self.role == A2RPPairSetupRoleHost) {
        if (self.step == A2RPPairSetupStepIdle) {
            // PS-Msg01：Method=0x00 + State=0x01（§9 Phase 1）
            NSData *msg = A2RPTLVEncode(@[ @(A2RPTLVTypeMethod), @(A2RPTLVTypeState) ],
                                        @[ A2RPPSOneByte(0x00), A2RPPSOneByte(0x01) ]);
            self.step = A2RPPairSetupStepMsg01;
            return msg;
        }
        if (self.step == A2RPPairSetupStepMsg02) {
            // PS-Msg03：State=0x03 + PublicKey=A + Proof=M1
            size_t aLen = 0, m1Len = 0;
            const uint8_t *A = A2RPSRPClientPublicA(self.srpClient, &aLen);
            const uint8_t *m1 = A2RPSRPClientProofM1(self.srpClient, &m1Len);
            if (A == NULL || m1 == NULL) {
                if (reason) { *reason = @"尚未算出 A/M1（SRP 未就绪）⇒ 不发 Msg03"; }
                return nil;
            }
            NSData *msg = A2RPTLVEncode(@[ @(A2RPTLVTypeState), @(A2RPTLVTypePublicKey),
                                           @(A2RPTLVTypeProof) ],
                                        @[ A2RPPSOneByte(0x03),
                                           [NSData dataWithBytes:A length:aLen],
                                           [NSData dataWithBytes:m1 length:m1Len] ]);
            self.step = A2RPPairSetupStepMsg03;
            return msg;
        }
        if (self.step == A2RPPairSetupStepMsg04) {
            // PS-Msg05：EncryptedData + State=0x05（§9 Phase 3）
            if (self.setupEncryptionKey == nil || self.controllerSigningMaterial == nil) {
                if (reason) { *reason = @"pair-setup 密钥未派生（未收到 Msg04）⇒ 不发 Msg05"; }
                return nil;
            }
            NSMutableData *signedBuf = [NSMutableData data];
            [signedBuf appendData:self.controllerSigningMaterial];
            [signedBuf appendData:[self.identity.identifier dataUsingEncoding:NSUTF8StringEncoding]];
            [signedBuf appendData:self.identity.publicKey];
            NSData *sig = [self.identity signMessage:signedBuf];
            if (sig == nil) {
                if (reason) { *reason = @"Ed25519 签名失败"; }
                return nil;
            }
            NSData *info = A2RPOPackDeviceInfo(self.identity.identifier,
                                               NSProcessInfo.processInfo.hostName);
            NSData *inner = A2RPTLVEncode(@[ @(A2RPTLVTypeIdentifier), @(A2RPTLVTypePublicKey),
                                             @(A2RPTLVTypeSignature), @(A2RPTLVTypeInfo) ],
                                          @[ [self.identity.identifier dataUsingEncoding:NSUTF8StringEncoding],
                                             self.identity.publicKey,
                                             sig,
                                             info ]);
            NSData *sealed = A2RPPSSeal(self.setupEncryptionKey, "PS-Msg05", inner, reason);
            if (sealed == nil) {
                return nil;
            }
            NSData *msg = A2RPTLVEncode(@[ @(A2RPTLVTypeEncryptedData), @(A2RPTLVTypeState) ],
                                        @[ sealed, A2RPPSOneByte(0x05) ]);
            self.step = A2RPPairSetupStepMsg05;
            return msg;
        }
        if (reason) {
            *reason = self.established ? @"已建立（无待发消息）" : @"Host 当前无待发消息（等待对端）";
        }
        return nil;
    }

    // ---- Device 角色 ----
    if (self.step == A2RPPairSetupStepMsg01) {
        // PS-Msg02：State=0x02 + PublicKey=B + Salt
        size_t bn = 0, sn = 0;
        const uint8_t *B = A2RPSRPServerPublicB(self.srpServer, &bn);
        const uint8_t *salt = A2RPSRPServerSalt(self.srpServer, &sn);
        if (B == NULL || salt == NULL) {
            if (reason) { *reason = @"设备侧 SRP 未就绪 ⇒ 不发 Msg02"; }
            return nil;
        }
        NSData *msg = A2RPTLVEncode(@[ @(A2RPTLVTypeState), @(A2RPTLVTypePublicKey),
                                       @(A2RPTLVTypeSalt) ],
                                    @[ A2RPPSOneByte(0x02),
                                       [NSData dataWithBytes:B length:bn],
                                       [NSData dataWithBytes:salt length:sn] ]);
        self.step = A2RPPairSetupStepMsg02;
        return msg;
    }
    if (self.step == A2RPPairSetupStepMsg03) {
        // PS-Msg04：State=0x04 + Proof=M2
        size_t m2Len = 0;
        const uint8_t *m2 = A2RPSRPServerProofM2(self.srpServer, &m2Len);
        if (m2 == NULL) {
            if (reason) { *reason = @"设备侧尚未算出 M2（未校验 M1？）⇒ 不发 Msg04"; }
            return nil;
        }
        NSData *msg = A2RPTLVEncode(@[ @(A2RPTLVTypeState), @(A2RPTLVTypeProof) ],
                                    @[ A2RPPSOneByte(0x04), [NSData dataWithBytes:m2 length:m2Len] ]);
        self.step = A2RPPairSetupStepMsg04;
        return msg;
    }
    if (self.step == A2RPPairSetupStepMsg05) {
        // PS-Msg06：State=0x06 + EncryptedData（设备自己的记录）
        if (self.setupEncryptionKey == nil || self.accessorySigningMaterial == nil) {
            if (reason) { *reason = @"设备侧密钥未派生 ⇒ 不发 Msg06"; }
            return nil;
        }
        NSMutableData *signedBuf = [NSMutableData data];
        [signedBuf appendData:self.accessorySigningMaterial];
        [signedBuf appendData:[self.identity.identifier dataUsingEncoding:NSUTF8StringEncoding]];
        [signedBuf appendData:self.identity.publicKey];
        NSData *sig = [self.identity signMessage:signedBuf];
        if (sig == nil) {
            if (reason) { *reason = @"设备侧 Ed25519 签名失败"; }
            return nil;
        }
        NSData *inner = A2RPTLVEncode(@[ @(A2RPTLVTypeIdentifier), @(A2RPTLVTypePublicKey),
                                         @(A2RPTLVTypeSignature) ],
                                      @[ [self.identity.identifier dataUsingEncoding:NSUTF8StringEncoding],
                                         self.identity.publicKey,
                                         sig ]);
        NSData *sealed = A2RPPSSeal(self.setupEncryptionKey, "PS-Msg06", inner, reason);
        if (sealed == nil) {
            return nil;
        }
        NSData *msg = A2RPTLVEncode(@[ @(A2RPTLVTypeState), @(A2RPTLVTypeEncryptedData) ],
                                    @[ A2RPPSOneByte(0x06), sealed ]);
        self.step = A2RPPairSetupStepEstablished;
        return msg;
    }
    if (reason) {
        *reason = self.established ? @"已建立（无待发消息）" : @"Device 当前无待发消息（等待对端）";
    }
    return nil;
}

#pragma mark 接收侧

- (BOOL)acceptMessage:(NSData *)tlv reason:(NSString *_Nullable *_Nullable)reason {
    NSString *perr = nil;
    NSDictionary<NSNumber *, NSData *> *dict = A2RPTLVDecode(tlv, &perr);
    if (dict == nil) {
        if (reason) { *reason = [NSString stringWithFormat:@"对端消息不是合法 TLV8：%@", perr ?: @"未知"]; }
        return NO;
    }
    // 任何状态下的 Error ⇒ 如实失败。
    if (A2RPTLVValue(dict, A2RPTLVTypeError) != nil) {
        if (reason) { *reason = @"对端返回 ErrorResponse ⇒ 失败"; }
        return NO;
    }
    NSInteger state = A2RPTLVStateValue(dict);
    if (state < 0) {
        if (reason) { *reason = @"对端消息缺 State（或长度不为 1）"; }
        return NO;
    }

    NSInteger expect = -1;
    if (self.role == A2RPPairSetupRoleHost) {
        expect = (self.step == A2RPPairSetupStepMsg01) ? 2
               : (self.step == A2RPPairSetupStepMsg03) ? 4
               : (self.step == A2RPPairSetupStepMsg05) ? 6 : -1;
    } else {
        expect = (self.step == A2RPPairSetupStepIdle)  ? 1
               : (self.step == A2RPPairSetupStepMsg02) ? 3
               : (self.step == A2RPPairSetupStepMsg04) ? 5 : -1;
    }
    if (expect < 0 || state != expect) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"pair-setup 消息流顺序错：本方 step=%ld，收到 State=%ld",
                       (long)self.step, (long)state];
        }
        return NO;
    }

    if (self.role == A2RPPairSetupRoleHost) {
        return [self hostAcceptState:(NSInteger)state dict:dict reason:reason];
    }
    return [self deviceAcceptState:(NSInteger)state dict:dict reason:reason];
}

- (BOOL)hostAcceptState:(NSInteger)state
                   dict:(NSDictionary<NSNumber *, NSData *> *)dict
                 reason:(NSString *_Nullable *_Nullable)reason {
    if (state == 2) {
        // 设备回 SRP 参数：Salt + PublicKey=B。★在这里取配对码（注入缝）★。
        NSData *salt = A2RPTLVValue(dict, A2RPTLVTypeSalt);
        NSData *B = A2RPTLVValue(dict, A2RPTLVTypePublicKey);
        if (salt.length == 0 || B.length == 0) {
            if (reason) { *reason = @"对端 Msg02 缺 Salt / PublicKey(B)"; }
            return NO;
        }
        NSString *pin = self.pinProvider ? self.pinProvider(self.pinPromptHint) : nil;
        if (pin.length == 0) {
            if (reason) { *reason = @"配对码来源未注入 / 取到空码 ⇒ 拒绝（不猜、不默认）"; }
            return NO;
        }
        const char *pinStr = pin.UTF8String;
        uint8_t a[32];
        if (!A2RPRandomBytes(a, sizeof(a))) {
            if (reason) { *reason = @"CSPRNG 不可用（无法生成 SRP 私随机数 a）"; }
            return NO;
        }
        NSString *srpWhy = nil;
        self.srpClient = A2RPSRPClientCreate(A2RPSRPGroup3072(), A2RPSRPHashSHA512(),
                                             A2RPSRPSHA512DigestLength(),
                                             (const uint8_t *)kA2RPPSUsername, strlen(kA2RPPSUsername),
                                             (const uint8_t *)pinStr, strlen(pinStr),
                                             a, sizeof(a), &srpWhy);
        memset(a, 0, sizeof(a));
        if (self.srpClient == NULL) {
            if (reason) { *reason = [NSString stringWithFormat:@"建 SRP 客户端失败：%@", srpWhy ?: @"未知"]; }
            return NO;
        }
        srpWhy = nil;
        if (!A2RPSRPClientComputeKey(self.srpClient, salt.bytes, salt.length, B.bytes, B.length, &srpWhy)) {
            if (reason) { *reason = [NSString stringWithFormat:@"SRP 客户端算密钥失败：%@", srpWhy ?: @"未知"]; }
            return NO;
        }
        self.step = A2RPPairSetupStepMsg02;
        return YES;
    }
    if (state == 4) {
        // M2 校验。
        NSData *m2 = A2RPTLVValue(dict, A2RPTLVTypeProof);
        if (!A2RPSRPClientVerifyM2(self.srpClient, m2.bytes, m2.length)) {
            if (reason) { *reason = @"服务端证明 M2 校验失败 ⇒ 拒绝（对端不持有同一码）"; }
            return NO;
        }
        // 派生 Phase 3 的密钥。
        size_t kLen = 0;
        const uint8_t *kp = A2RPSRPClientSessionKey(self.srpClient, &kLen);
        if (kp == NULL || kLen == 0) {
            if (reason) { *reason = @"SRP 客户端会话密钥不可用"; }
            return NO;
        }
        NSData *K = [NSData dataWithBytes:kp length:kLen];
        self.sessionKey = K;
        self.setupEncryptionKey = A2RPPSHKDF(K, kA2RPPSEncryptSalt, kA2RPPSEncryptInfo, 32);
        self.controllerSigningMaterial = A2RPPSHKDF(K, kA2RPPSCtrlSignSalt, kA2RPPSCtrlSignInfo, 32);
        if (self.setupEncryptionKey == nil || self.controllerSigningMaterial == nil) {
            if (reason) { *reason = @"HKDF-SHA512 派生 pair-setup 密钥失败"; }
            return NO;
        }
        self.step = A2RPPairSetupStepMsg04;
        return YES;
    }
    if (state == 6) {
        // 解密设备记录（规格说「非必需」，所以字段缺失不致命）。
        NSData *enc = A2RPTLVValue(dict, A2RPTLVTypeEncryptedData);
        if (enc.length == 0) {
            if (reason) { *reason = @"对端 Msg06 缺 EncryptedData"; }
            return NO;
        }
        NSData *inner = A2RPPSOpen(self.setupEncryptionKey, "PS-Msg06", enc, reason);
        if (inner == nil) {
            return NO;
        }
        self.peerInfoTLV = inner;
        NSString *perr = nil;
        NSDictionary<NSNumber *, NSData *> *pdict = A2RPTLVDecode(inner, &perr);
        if (pdict != nil) {
            NSData *ident = A2RPTLVValue(pdict, A2RPTLVTypeIdentifier);
            if (ident.length > 0) {
                self.peerIdentifier = [[NSString alloc] initWithData:ident encoding:NSUTF8StringEncoding];
            }
            NSData *pk = A2RPTLVValue(pdict, A2RPTLVTypePublicKey);
            if (pk.length == A2RP_ED25519_KEY_BYTES) {
                self.peerPublicKey = pk;
            }
        }
        self.step = A2RPPairSetupStepEstablished;
        return YES;
    }
    if (reason) { *reason = @"Host 收到意外状态号"; }
    return NO;
}

- (BOOL)deviceAcceptState:(NSInteger)state
                     dict:(NSDictionary<NSNumber *, NSData *> *)dict
                   reason:(NSString *_Nullable *_Nullable)reason {
    if (state == 1) {
        // PS-Msg01：建立 SRP 服务端（salt/b 随机）。
        NSData *method = A2RPTLVValue(dict, A2RPTLVTypeMethod);
        if (method.length == 1 && ((const uint8_t *)method.bytes)[0] != 0x00) {
            if (reason) { *reason = @"Msg01 的配对方法不是 0x00"; }
            return NO;
        }
        uint8_t salt[16], b[32];
        if (!A2RPRandomBytes(salt, sizeof(salt)) || !A2RPRandomBytes(b, sizeof(b))) {
            if (reason) { *reason = @"CSPRNG 不可用（无法生成 salt/b）"; }
            return NO;
        }
        NSString *srpWhy = nil;
        self.srpServer = A2RPSRPServerCreate(A2RPSRPGroup3072(), A2RPSRPHashSHA512(),
                                             A2RPSRPSHA512DigestLength(),
                                             (const uint8_t *)kA2RPPSUsername, strlen(kA2RPPSUsername),
                                             (const uint8_t *)self.devicePin.UTF8String,
                                             strlen(self.devicePin.UTF8String),
                                             salt, sizeof(salt), b, sizeof(b), &srpWhy);
        memset(b, 0, sizeof(b));
        if (self.srpServer == NULL) {
            if (reason) { *reason = [NSString stringWithFormat:@"建设备侧 SRP 失败：%@", srpWhy ?: @"未知"]; }
            return NO;
        }
        self.step = A2RPPairSetupStepMsg01;
        return YES;
    }
    if (state == 3) {
        // 校验 A 与 M1。
        NSData *A = A2RPTLVValue(dict, A2RPTLVTypePublicKey);
        NSData *m1 = A2RPTLVValue(dict, A2RPTLVTypeProof);
        if (A.length == 0 || m1.length == 0) {
            if (reason) { *reason = @"对端 Msg03 缺 PublicKey(A) / Proof(M1)"; }
            return NO;
        }
        NSString *srpWhy = nil;
        if (!A2RPSRPServerComputeKey(self.srpServer, A.bytes, A.length, &srpWhy)) {
            if (reason) { *reason = [NSString stringWithFormat:@"设备侧 SRP 算密钥失败：%@", srpWhy ?: @"未知"]; }
            return NO;
        }
        if (!A2RPSRPServerVerifyM1(self.srpServer, m1.bytes, m1.length)) {
            if (reason) { *reason = @"客户端证明 M1 校验失败 ⇒ 拒绝（配对码不对？）"; }
            return NO;
        }
        self.peerProofVerified = YES;
        // 派生 Phase 3 密钥。
        size_t kLen = 0;
        const uint8_t *kp = A2RPSRPServerSessionKey(self.srpServer, &kLen);
        if (kp == NULL || kLen == 0) {
            if (reason) { *reason = @"设备侧 SRP 会话密钥不可用"; }
            return NO;
        }
        NSData *K = [NSData dataWithBytes:kp length:kLen];
        self.sessionKey = K;
        self.setupEncryptionKey = A2RPPSHKDF(K, kA2RPPSEncryptSalt, kA2RPPSEncryptInfo, 32);
        self.accessorySigningMaterial = A2RPPSHKDF(K, kA2RPPSAccSignSalt, kA2RPPSAccSignInfo, 32);
        if (self.setupEncryptionKey == nil || self.accessorySigningMaterial == nil) {
            if (reason) { *reason = @"HKDF-SHA512 派生设备侧 pair-setup 密钥失败"; }
            return NO;
        }
        self.step = A2RPPairSetupStepMsg03;
        return YES;
    }
    if (state == 5) {
        // 解密控制器记录并验证其签名。
        NSData *enc = A2RPTLVValue(dict, A2RPTLVTypeEncryptedData);
        if (enc.length == 0) {
            if (reason) { *reason = @"对端 Msg05 缺 EncryptedData"; }
            return NO;
        }
        NSData *inner = A2RPPSOpen(self.setupEncryptionKey, "PS-Msg05", enc, reason);
        if (inner == nil) {
            return NO;
        }
        NSString *perr = nil;
        NSDictionary<NSNumber *, NSData *> *cdict = A2RPTLVDecode(inner, &perr);
        if (cdict == nil) {
            if (reason) { *reason = [NSString stringWithFormat:@"控制器记录不是合法 TLV8：%@", perr ?: @"未知"]; }
            return NO;
        }
        NSData *ident = A2RPTLVValue(cdict, A2RPTLVTypeIdentifier);
        NSData *pk = A2RPTLVValue(cdict, A2RPTLVTypePublicKey);
        NSData *sig = A2RPTLVValue(cdict, A2RPTLVTypeSignature);
        if (ident.length == 0 || pk.length != A2RP_ED25519_KEY_BYTES
            || sig.length != A2RP_ED25519_SIG_BYTES) {
            if (reason) { *reason = @"控制器记录缺 Identifier/PublicKey/Signature（或长度不符）"; }
            return NO;
        }
        // 控制器签名对象 = controllerSigningMaterial || identifier || ed25519_pub
        NSMutableData *signedBuf = [NSMutableData data];
        [signedBuf appendData:A2RPPSHKDF(self.sessionKey, kA2RPPSCtrlSignSalt, kA2RPPSCtrlSignInfo, 32)];
        [signedBuf appendData:ident];
        [signedBuf appendData:pk];
        if (![A2RPPairingIdentity verifySignature:sig forMessage:signedBuf publicKey:pk]) {
            if (reason) { *reason = @"控制器签名校验失败 ⇒ 拒绝（对端身份不可信）"; }
            return NO;
        }
        self.peerIdentifier = [[NSString alloc] initWithData:ident encoding:NSUTF8StringEncoding];
        self.peerPublicKey = pk;
        self.peerInfoTLV = inner;
        self.step = A2RPPairSetupStepMsg05;
        return YES;
    }
    if (reason) { *reason = @"Device 收到意外状态号"; }
    return NO;
}

#pragma mark - 一次性驱动（Host 侧）

+ (BOOL)runHostOverTransport:(id<A2RPPairSetupMessageTransport>)transport
                    identity:(A2RPPairingIdentity *)identity
                 pinProvider:(A2RPPairSetupPinProvider)pinProvider
                      reason:(NSString *_Nullable *_Nullable)reason
                  sessionKey:(NSData *_Nullable *_Nullable)sessionKeyOut {
    if (transport == nil) {
        if (reason) { *reason = @"未提供 pair-setup 传输（transport=nil）⇒ 拒绝"; }
        return NO;
    }
    NSString *why = nil;
    A2RPPairSetupSession *session = [A2RPPairSetupSession hostSessionWithIdentity:identity
                                                                     pinProvider:pinProvider
                                                                          reason:&why];
    if (session == nil) {
        if (reason) { *reason = why ?: @"建 pair-setup Host 会话失败"; }
        return NO;
    }
    // 传输层若已知设备在弹信任框，则取码场景用 AwaitingConsent（规格 §9 Phase 1）。
    if ([transport respondsToSelector:@selector(transportObservedAwaitingUserConsent)]
        && [transport transportObservedAwaitingUserConsent]) {
        [session setPinPromptHint:A2RPPairSetupPinPromptAwaitingConsent];
    }

    for (int step = 0; step < 3; step++) {
        NSString *nwhy = nil;
        NSData *out = [session nextMessageWithReason:&nwhy];
        if (out == nil) {
            if (reason) { *reason = nwhy ?: @"Host 无待发消息（消息机状态异常）"; }
            return NO;
        }
        NSString *xwhy = nil;
        NSData *in = [transport exchangePairingData:out
                                               kind:@(kA2RPPSKind)
                                           startNew:(step == 0)
                                             reason:&xwhy];
        if (in == nil) {
            if (reason) { *reason = xwhy ?: @"pair-setup 传输失败"; }
            return NO;
        }
        NSString *awhy = nil;
        if (![session acceptMessage:in reason:&awhy]) {
            if (reason) { *reason = awhy ?: @"对端消息被拒"; }
            return NO;
        }
    }
    if (!session.established) {
        if (reason) { *reason = @"pair-setup 未进入已建立状态"; }
        return NO;
    }
    if (sessionKeyOut) { *sessionKeyOut = session.sessionKey; }
    return YES;
}

@end

#pragma mark - 进程内自握手（运行期自证）

@interface A2RPPairSetupSelfTest ()
@property (nonatomic, readwrite) BOOL ok;
@property (nonatomic, readwrite, copy) NSString *summary;
@property (nonatomic, readwrite) BOOL sessionKeysEqual;
@property (nonatomic, readwrite) BOOL tamperRejected;
@property (nonatomic, readwrite) BOOL wrongPinRejected;
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *messageSizes;
@end

@implementation A2RPPairSetupSelfTest

/// 真跑一次 PS-Msg01..06；任一步失败 ⇒ NO，原因写进 *why。
static BOOL A2RPPSRunExchange(A2RPPairSetupSession *host,
                              A2RPPairSetupSession *dev,
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
    if (![host acceptMessage:m2 reason:why]) { return NO; }
    NSData *m3 = [host nextMessageWithReason:why];
    if (m3 == nil) { return NO; }
    [sizes addObject:@(m3.length)];

    // ★篡改检测★：把 Msg03 的 M1 末字节改一位 —— 设备必须先拒，再接受未篡改的 Msg03。
    NSMutableData *bad = [m3 mutableCopy];
    ((uint8_t *)bad.mutableBytes)[bad.length - 1] ^= 0x01;
    NSString *treason = nil;
    if ([dev acceptMessage:bad reason:&treason]) {
        *why = @"篡改过的 Msg03 被接受（本应被 M1 校验拒绝）";
        return NO;
    }
    *tamperRejected = YES;

    if (![dev acceptMessage:m3 reason:why]) { return NO; }
    NSData *m4 = [dev nextMessageWithReason:why];
    if (m4 == nil) { return NO; }
    [sizes addObject:@(m4.length)];
    if (![host acceptMessage:m4 reason:why]) { return NO; }
    NSData *m5 = [host nextMessageWithReason:why];
    if (m5 == nil) { return NO; }
    [sizes addObject:@(m5.length)];
    if (![dev acceptMessage:m5 reason:why]) { return NO; }
    NSData *m6 = [dev nextMessageWithReason:why];
    if (m6 == nil) { return NO; }
    [sizes addObject:@(m6.length)];
    if (![host acceptMessage:m6 reason:why]) { return NO; }
    return YES;
}

+ (A2RPPairSetupSelfTest *)runSelfTest {
    A2RPPairSetupSelfTest *r = [A2RPPairSetupSelfTest new];
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
    NSString *why = nil;
    BOOL tamperRejected = NO;
    BOOL wrongPinRejected = NO;

    NSError *e1 = nil, *e2 = nil;
    A2RPPairingIdentity *hostID = [A2RPPairingIdentity identityWithHostName:@"air2-ps-host" error:&e1];
    A2RPPairingIdentity *devID = [A2RPPairingIdentity identityWithHostName:@"air2-ps-device" error:&e2];
    if (hostID == nil || devID == nil) {
        r.ok = NO;
        r.messageSizes = sizes;
        r.summary = [NSString stringWithFormat:@"pair-setup 自握手失败：身份生成失败（%@ / %@）",
                     e1.localizedDescription ?: @"-", e2.localizedDescription ?: @"-"];
        return r;
    }

    // ★配对码注入缝★：自测里给一个确定码（生产由 UI/设备提供）。
    NSString *pin = @"123456";
    A2RPPairSetupSession *host = [A2RPPairSetupSession hostSessionWithIdentity:hostID
                                                                  pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
        (void)p;
        return pin;
    } reason:&why];
    A2RPPairSetupSession *dev = [A2RPPairSetupSession deviceSessionWithIdentity:devID pin:pin reason:&why];
    if (host == nil || dev == nil) {
        r.ok = NO;
        r.messageSizes = sizes;
        r.summary = [NSString stringWithFormat:@"pair-setup 自握手失败：建会话失败（%@）", why ?: @"-"];
        return r;
    }

    BOOL stepOK = A2RPPSRunExchange(host, dev, sizes, &tamperRejected, &why);
    r.tamperRejected = tamperRejected;
    r.sessionKeysEqual = (host.sessionKey != nil) && [host.sessionKey isEqualToData:dev.sessionKey];
    r.ok = stepOK && host.established && dev.established && r.sessionKeysEqual
        && r.tamperRejected && sizes.count == 6;

    // 负例：配对码不一致 ⇒ 设备必须拒（M1 校验失败）。
    {
        A2RPPairingIdentity *h2 = [A2RPPairingIdentity identityWithHostName:@"air2-ps-host2" error:NULL];
        A2RPPairingIdentity *d2 = [A2RPPairingIdentity identityWithHostName:@"air2-ps-dev2" error:NULL];
        NSString *w2 = nil;
        A2RPPairSetupSession *hs = [A2RPPairSetupSession hostSessionWithIdentity:h2
                                                                    pinProvider:^NSString *(A2RPPairSetupPinPrompt p) {
            (void)p; return @"000000";   // Host 用错码
        } reason:&w2];
        A2RPPairSetupSession *ds = [A2RPPairSetupSession deviceSessionWithIdentity:d2 pin:@"123456" reason:&w2];
        if (hs && ds) {
            NSData *x1 = [hs nextMessageWithReason:&w2];
            NSData *x2 = [ds acceptMessage:x1 reason:&w2] ? [ds nextMessageWithReason:&w2] : nil;
            NSData *x3 = (x2 && [hs acceptMessage:x2 reason:&w2]) ? [hs nextMessageWithReason:&w2] : nil;
            NSString *w3 = nil;
            if (x3 != nil && ![ds acceptMessage:x3 reason:&w3]) {
                wrongPinRejected = YES;
            }
        }
    }
    r.wrongPinRejected = wrongPinRejected;

    NSString *sizesStr = sizes.count == 6
        ? [NSString stringWithFormat:@"%lu/%lu/%lu/%lu/%lu/%lu",
           (unsigned long)sizes[0].unsignedIntegerValue, (unsigned long)sizes[1].unsignedIntegerValue,
           (unsigned long)sizes[2].unsignedIntegerValue, (unsigned long)sizes[3].unsignedIntegerValue,
           (unsigned long)sizes[4].unsignedIntegerValue, (unsigned long)sizes[5].unsignedIntegerValue]
        : @"(不全)";
    if (r.ok) {
        r.summary = [NSString stringWithFormat:
                     @"pair-setup 自握手：PS-Msg01..06 = %@ 字节｜双方会话密钥一致=是｜"
                     @"篡改 Msg03(M1) 被拒=是｜配对码不一致被拒=是 ⇒ 通过", sizesStr];
    } else {
        r.summary = [NSString stringWithFormat:
                     @"pair-setup 自握手未通过：%@（消息流 %@｜密钥一致=%@｜篡改被拒=%@｜错码被拒=%@）",
                     why ?: @"未知原因", sizesStr,
                     r.sessionKeysEqual ? @"是" : @"否",
                     r.tamperRejected ? @"是" : @"否",
                     r.wrongPinRejected ? @"是" : @"否"];
    }
    r.messageSizes = sizes;
    return r;
}

@end
