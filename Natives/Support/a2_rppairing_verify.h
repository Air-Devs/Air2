//
//  a2_rppairing_verify.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— [JIT-AUTOPAIR-2] RPPairing **pair-verify 握手本体**（消息流 + 密钥交换）。
//
//  依据（公开协议描述，非任何项目源码 —— 见 a2_rppairing.h 顶部对来源的声明）：
//    · §8 Pair-Verify：Step1 hostOptions(wireProtocolVersion=19, attemptPairVerify=true)
//      → M1{State=1, PublicKey=x_pub} → M2{State=2, PublicKey=device_pub, EncryptedData}
//      → shared_secret = X25519(x_priv, device_pub)（★它就是 TLS-PSK 的 PSK★）
//      → pair_verify_key = HKDF-SHA512(salt="Pair-Verify-Encrypt-Salt", ikm=shared,
//                                      info="Pair-Verify-Encrypt-Info", 32)
//      → M3{State=3, EncryptedData = ChaCha20-Poly1305(非命名 nonce "\0\0\0\0PV-Msg03",
//            明文 = TLV{Identifier, Signature = Ed25519(x_pub || identifier || device_pub)})}
//      → M4{State=4}（含 ErrorResponse ⇒ 失败，回落到 pair-setup）
//    · M2 的 EncryptedData 用 nonce "\0\0\0\0PV-Msg02" 可解（公开规格 Step 6 明确写「可不解」）。
//    · §10：client_key = HKDF(salt=无, ikm=shared, info="ClientEncrypt-main", 32)
//            server_key = HKDF(salt=无, ikm=shared, info="ServerEncrypt-main", 32)
//
//  ★本单实现到哪一步（如实）★：
//    · **Host 角色按公开规格逐条实现**（这是与真设备对话的那一侧）。
//    · **Device 角色也实现**，用来在单测/自检里做**进程内自握手**（真密码学、真消息流、
//      真密钥交换），从而在没有真机的情况下也能对「握手本体」做运行期自证。
//      ★Device 侧那份证明的明文布局公开规格没写（Step 6 只说它可解且可选）★，
//      本仓按 Host 侧的对称约定构造（sign(device_pub || identifier || host_pub)）并在文档里标明。
//    ⇒ 自握手证的是「本仓握手实现自洽且密码学正确」，★不等于★已与 iOS 27 真机互操作
//      （后者需要真 RSD 端点，见 docs/JIT-PROVISIONING.md §4.2-a）。
//
//  ★仍未落地★：pair-setup(SRP-3072)、TLS-PSK 隧道（§12）、Bonjour/RSD 连接（见 a2_rppairing_rsd.h）。
//

#import <Foundation/Foundation.h>
#import "a2_rppairing.h"

NS_ASSUME_NONNULL_BEGIN

/// 会话角色。Host = 本机（发起方）；Device = 对端（真机 / 自测里的角色扮演）。
typedef NS_ENUM(NSInteger, A2RPPairVerifyRole) {
    A2RPPairVerifyRoleHost   = 1,
    A2RPPairVerifyRoleDevice = 2,
};

/// 协议状态号（与 TLV 里的 State 一致；Established 不是线上的状态号）。
typedef NS_ENUM(NSInteger, A2RPPairVerifyStep) {
    A2RPPairVerifyStepIdle        = 0,
    A2RPPairVerifyStepMsg01       = 1,
    A2RPPairVerifyStepMsg02       = 2,
    A2RPPairVerifyStepMsg03       = 3,
    A2RPPairVerifyStepMsg04       = 4,
    A2RPPairVerifyStepEstablished = 5,
};

@class A2RPPairVerifySelfTest;

@interface A2RPPairVerifySession : NSObject

@property (nonatomic, readonly) A2RPPairVerifyRole role;
@property (nonatomic, readonly) A2RPPairVerifyStep step;
@property (nonatomic, readonly) BOOL established;
/// 本方身份（Ed25519 密钥对 + identifier）。★strong 而非 copy：该身份对象不可变，且不实现 NSCopying★。
@property (nonatomic, readonly, strong) A2RPPairingIdentity *identity;
/// 对端 Ed25519 公钥（32 字节）。
@property (nonatomic, readonly, copy) NSData *peerPublicKey;
/// ★共享密钥 = TLS-PSK 的 PSK★（建立后才有）。
@property (nonatomic, readonly, copy, nullable) NSData *sharedSecret;
/// 主密钥（§10）；
@property (nonatomic, readonly, copy, nullable) NSData *clientKey;
@property (nonatomic, readonly, copy, nullable) NSData *serverKey;

/// 建会话。identity / peerPublicKey 必填（各 32 字节公钥），否则返回 nil 并回填 reason。
+ (nullable instancetype)sessionWithRole:(A2RPPairVerifyRole)role
                                identity:(A2RPPairingIdentity *)identity
                           peerPublicKey:(NSData *)peerPublicKey
                                  reason:(NSString *_Nullable *_Nullable)reason;

/// 生成本方下一条要发送的 TLV8 消息。
/// @return nil 表示「此刻没有要发的」（已建立 / 还在等对端）；reason 说明原因。
- (NSData *_Nullable)nextMessageWithReason:(NSString *_Nullable *_Nullable)reason;

/// 处理从对端收到的 TLV8 消息。★任何校验失败都返回 NO 并回填 reason（绝不半信）★。
- (BOOL)acceptMessage:(NSData *)tlv reason:(NSString *_Nullable *_Nullable)reason;

@end

// ---------------------------------------------------------------------------
// ★进程内自握手（运行期自证）★
// ---------------------------------------------------------------------------

/// 结果对象：自握手的逐步结果与派生出的密钥（只在自证里用）。
@interface A2RPPairVerifySelfTest : NSObject
@property (nonatomic, readonly) BOOL ok;
@property (nonatomic, readonly, copy) NSString *summary;
/// 双方共享密钥是否一致（PSK 一致）。
@property (nonatomic, readonly) BOOL secretsEqual;
/// 双方 client/server 主密钥是否一致（Host 的 clientKey == Device 的 serverKey）。
@property (nonatomic, readonly) BOOL mainKeysCrossEqual;
/// 篡改 M3 一个字节后，Device 是否如实拒绝。
@property (nonatomic, readonly) BOOL tamperRejected;
/// 四条消息的字节数（供日志核对消息流确实发生了）。
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *messageSizes;
/// 跑一次完整自握手（真密码学 + 真消息流 M1→M4）。不做网络、不写盘。
+ (A2RPPairVerifySelfTest *)runSelfTest;

@end

NS_ASSUME_NONNULL_END
