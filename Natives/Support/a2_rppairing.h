//
//  a2_rppairing.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— [JIT-AUTOPAIR-2] RPPairing（Remote Pairing）的【线上编解码 + 完成度自检】。
//
//  依据（公开协议描述，非任何项目源码）：
//    · 线上帧：magic(9B ASCII "RPPairing") + 长度(2B 大端) + payload（JSON/plist 载荷）。
//    · 消息信封：{ "message": { "plain"|"streamEncrypted": { "_0": <载荷> } },
//                  "originatedBy": "host"|"device", "sequenceNumber": N }。
//    · 配对文件（RpPairingFile）：plist 字典，键 = identifier(string) + public_key(data) + private_key(data)，
//      其中公开发布的描述指明 identifier = uuid_v3(NAMESPACE_DNS, hostname)，密钥对为 Ed25519。
//    来源：https://jkcoxson.com/blog/rppairing-spec（§3 传输层 / §7 配对文件）——★只取协议事实，未取任何代码★。
//
//  ★本阶段范围（如实）★：本文件落地【帧 / 信封 / 标识符 / 配对文件组装 / 握手完成度自检】，
//  这些是纯逻辑且可自证；★真正的 pair-verify 与 pair-setup(SRP-3072) 消息机已分别落在
//  a2_rppairing_verify.[hm] 与 a2_rppairing_pairsetup.[hm]★；TLS-PSK 隧道、Bonjour 发现/连接
//  见 a2_rppairing_rsd.[hm] / a2_tlspsk_*（原因见 a2_rppairing_crypto.h 顶部与 docs/JIT-PROVISIONING.md §4.2-a）。
//  绝不假成功：未落地的步骤由 A2RPPairingPreflight 如实点名。
//

#import <Foundation/Foundation.h>
#import "a2_rppairing_crypto.h"

NS_ASSUME_NONNULL_BEGIN

/// RPPairing 线上帧的 magic：ASCII "RPPairing"（9 字节）。
FOUNDATION_EXPORT const char *const A2RPPairingMagic;
#define A2RP_PAIRING_MAGIC_BYTES  9
#define A2RP_PAIRING_LENGTH_BYTES 2

// ---------------------------------------------------------------------------
// 线上帧（magic + 2B 大端长度 + 载荷）
// ---------------------------------------------------------------------------

/// 组帧。payload 长度须 ≤ 65535，否则返回 nil。
NSData *_Nullable A2RPFrameEncode(NSData *payload);

/// 组帧（便捷）：先把信封对象序列化成 JSON 再组帧。失败返回 nil 并回填 errorReason。
NSData *_Nullable A2RPFrameEncodeEnvelope(NSDictionary<NSString *, id> *envelope,
                                          NSString *_Nullable *_Nullable errorReason);

/// 从【累积缓冲】里尝试切出一帧（供 NWConnection 分片到达时使用）。
/// @param consumedOut 已消费字节数（返回 YES 时有效）。
/// @param payloadOut  帧载荷（可为 NULL）。
/// @param errorOut    不足一帧/格式错时的可读原因（可为 NULL）。
/// @return YES = 切出一帧；NO = 需要更多数据或帧非法（errorOut 区分）。
BOOL A2RPFramePop(NSData *buffer,
                  NSUInteger *consumedOut,
                  NSData *_Nullable *_Nullable payloadOut,
                  NSString *_Nullable *_Nullable errorOut);

/// 从帧里取载荷长度（buffer 不足 11 字节返回 NO）。
BOOL A2RPFrameReadLength(NSData *buffer, NSUInteger *payloadLengthOut);

// ---------------------------------------------------------------------------
// 消息信封
// ---------------------------------------------------------------------------

/// 明文信封。
NSDictionary<NSString *, id> *A2RPEnvelopePlain(NSDictionary<NSString *, id> *payload,
                                                NSString *originatedBy,
                                                NSInteger sequenceNumber);

/// 密文信封（base64 的 streamEncrypted 载荷）。
NSDictionary<NSString *, id> *A2RPEnvelopeStreamEncrypted(NSString *base64Ciphertext,
                                                          NSString *originatedBy,
                                                          NSInteger sequenceNumber);

// ---------------------------------------------------------------------------
// 标识符 / 配对文件（RpPairingFile）
// ---------------------------------------------------------------------------

/// identifier = uuid_v3(NAMESPACE_DNS, name) 的小写连字符串（RFC 4122）。
NSString *_Nullable A2RPPairingIdentifierForName(NSString *name);

/// 组装 RpPairingFile（XML plist 字节）：identifier + public_key + private_key。
/// ★只负责组装字节，不落盘★（落盘交给 A2JITPairingFileStore，与 ②导入 同一约定位置）。
NSData *_Nullable A2RPPairingFileData(NSString *identifier,
                                      NSData *publicKey,
                                      NSData *privateKey);

// ---------------------------------------------------------------------------
// ★握手完成度自检（真跑已落地原语；如实点名未落地步骤）★
// ---------------------------------------------------------------------------

/// 握手被阻塞的步骤（首个未满足即此值；None 表示全部可用）。
typedef NS_ENUM(NSInteger, A2RPPairingBlockedStep) {
    A2RPPairingBlockedStepNone           = 0,  ///< 无阻塞
    A2RPPairingBlockedStepRandom         = 1,  ///< CSPRNG 不可用
    A2RPPairingBlockedStepKeyAgreement   = 2,  ///< X25519 / HKDF-SHA512 不可用
    A2RPPairingBlockedStepSigningKey     = 3,  ///< Ed25519 签名原语自检未过
    A2RPPairingBlockedStepStreamCipher   = 4,  ///< ChaCha20-Poly1305 AEAD 自检未过
    A2RPPairingBlockedStepPairVerify     = 5,  ///< ★pair-verify 自握手未通过★
    A2RPPairingBlockedStepRsdEndpoint    = 6,  ///< ★本地握手就绪，但缺真 RSD 端点/隧道（Bonjour→连接→TLS-PSK）★
    A2RPPairingBlockedStepPairSetup      = 7,  ///< ★pair-setup(SRP-3072) 消息机自检未过★（实现见 a2_rppairing_pairsetup.[hm]）
};

/// 自检结果（不可变值对象）。
@interface A2RPPairingPreflight : NSObject

/// CSPRNG 可用（真调 SecRandomCopyBytes）。
@property (nonatomic, readonly) BOOL randomOK;
/// X25519 密钥协商可用（真跑一次双方一致的双向 ECDH）。
@property (nonatomic, readonly) BOOL keyAgreementOK;
/// Ed25519 签名可用（真跑：派生公钥 + 签名 + 验签 + 坏签名必须被拒）。
@property (nonatomic, readonly) BOOL signingOK;
/// ChaCha20-Poly1305 AEAD 可用（真跑：seal→open 往返 + 坏 tag 必须被拒）。
@property (nonatomic, readonly) BOOL streamCipherOK;
/// ★pair-verify 握手本体可用（真跑一次进程内自握手 M1→M4：双方 PSK/主密钥一致、篡改被拒）★。
@property (nonatomic, readonly) BOOL pairVerifyOK;
/// pair-verify 自手写的可读结论（★直接来自真跑★，可进日志）。
@property (nonatomic, readonly, copy) NSString *pairVerifySummary;
/// ★pair-setup(SRP-3072) 消息机可用（真跑一次进程内自握手 PS-Msg01..06：双方会话密钥一致、篡改/错码被拒）★。
@property (nonatomic, readonly) BOOL pairSetupOK;
/// pair-setup 自手写的可读结论（★直接来自真跑★，可进日志）。
@property (nonatomic, readonly, copy) NSString *pairSetupSummary;
/// 首个被阻塞的步骤。
@property (nonatomic, readonly) A2RPPairingBlockedStep firstBlockedStep;
/// 可读摘要（供日志 / UI 直接用）。
@property (nonatomic, readonly, copy) NSString *summary;

/// 运行一次自检（不做网络动作、不写盘；只碰本机原语）。
+ (instancetype)run;

/// 步骤的稳定诊断名（供日志）。
+ (NSString *)displayNameForBlockedStep:(A2RPPairingBlockedStep)step;

@end

// ---------------------------------------------------------------------------
// TLV8 编解码（RPPairing 的所有配对数据交换都用它）
// ---------------------------------------------------------------------------

/// TLV8 的类型（公开规格 §5 的组件类型表；只列本单用到的）。
typedef NS_ENUM(uint8_t, A2RPTLVType) {
    A2RPTLVTypeMethod        = 0x00,   ///< 配对方法
    A2RPTLVTypeIdentifier    = 0x01,   ///< 主机标识（UUID 字符串）
    A2RPTLVTypeSalt          = 0x02,   ///< SRP 盐
    A2RPTLVTypePublicKey     = 0x03,   ///< 公钥字节
    A2RPTLVTypeProof         = 0x04,   ///< SRP 证明
    A2RPTLVTypeEncryptedData = 0x05,   ///< 密文（ChaCha20-Poly1305）
    A2RPTLVTypeState         = 0x06,   ///< 协议状态号
    A2RPTLVTypeError         = 0x07,   ///< 错误指示
    A2RPTLVTypeSignature     = 0x0A,   ///< Ed25519 签名
    A2RPTLVTypeInfo          = 0x11,   ///< 设备信息（OPack 编码；公开规格 §5 组件表 / §6 OPack）
};

/// 编码：按传入顺序拼 Type(1B)+Length(1B)+Value；>255 字节的值自动切分成连续同型条目。
/// ★nil 值 ⇒ 该条目不输出（用于「可选字段」）★。
NSData *A2RPTLVEncode(NSArray<NSNumber *> *types, NSArray<NSData *> *values);

/// 解码：把相邻同型条目**按规格要求拼接**。data 为空 ⇒ 空字典。
/// 结构非法（越界/截断）⇒ 返回 nil 并回填可读原因（★不静默吞掉★）。
NSDictionary<NSNumber *, NSData *> *_Nullable A2RPTLVDecode(NSData *data,
                                                            NSString *_Nullable *_Nullable errorReason);

/// 取某型条目的值（不存在 ⇒ nil）。
NSData *_Nullable A2RPTLVValue(NSDictionary<NSNumber *, NSData *> *tlv, A2RPTLVType type);

/// 取 State（0x06）的单字节值。缺失或长度 != 1 ⇒ -1。
NSInteger A2RPTLVStateValue(NSDictionary<NSNumber *, NSData *> *tlv);

// ---------------------------------------------------------------------------
// 本方身份（配对文件的三要素）
// ---------------------------------------------------------------------------

/// 身份：Ed25519 密钥对 + 由主机名派生的 identifier（= 配对文件的三要素）。
@interface A2RPPairingIdentity : NSObject

@property (nonatomic, readonly, copy) NSString *identifier;
/// 32 字节 Ed25519 公钥。
@property (nonatomic, readonly, copy) NSData *publicKey;
/// 32 字节 Ed25519 种子（= 配对文件里的 private_key）。
@property (nonatomic, readonly, copy) NSData *privateKey;

/// 新随机 Ed25519 身份；identifier = uuid_v3(NAMESPACE_DNS, hostName)。
/// ★hostName 为空 ⇒ nil（不静默用空名派生）★。
+ (nullable instancetype)identityWithHostName:(NSString *)hostName
                                        error:(NSError *_Nullable *_Nullable)error;

/// 由既有配对文件字节还原（走 A2PairingFile 同一套字段）。
+ (nullable instancetype)identityWithPairingFileData:(NSData *)data
                                               error:(NSError *_Nullable *_Nullable)error;

/// 本身份的配对文件字节（XML plist；交给 A2JITPairingFileStore 落盘）。
- (NSData *)pairingFileData;

/// 对给定消息签名（Ed25519）。
- (NSData *_Nullable)signMessage:(NSData *)message;

/// 用给定公钥校验签名。
+ (BOOL)verifySignature:(NSData *)signature
              forMessage:(NSData *)message
              publicKey:(NSData *)publicKey;

@end

NS_ASSUME_NONNULL_END
