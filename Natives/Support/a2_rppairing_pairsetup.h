//
//  a2_rppairing_pairsetup.h
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
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— [JIT-AUTOPAIR-3] RPPairing **pair-setup 消息机**（首次配对；SRP-3072 + PS-Msg01..06）。
//
//  这是「设备内自动配对」在真机上【首配】缺的那一块：pair-verify 只能在设备**已认识本机**时用。
//
//  协议出处（★只取公开规格事实/常量，未搬运任何项目源码★）：
//    · https://jkcoxson.com/blog/rppairing-spec §9「Pair-Setup (Initial Pairing)」：
//        Phase 1 请求同意：TLV{Method=0x00, State=0x01}，kind="setupManualPairing"；
//        设备回 awaitingUserConsent（iOS 用固定码 "000000"）或直接回 SRP 参数，或拒绝。
//        Phase 2 SRP：group=SRP-3072(RFC 5054 App.A)、Hash=SHA-512、Username=b"Pair-Setup"、
//          Password=配对码前 6 字节 ASCII、用户名进 x；Msg03=TLV{State=0x03, PublicKey=A, Proof=M1}；
//          设备回 M2（Proof），验证 verifier.verify_server(M2)；session_key = SRP 会话密钥。
//        Phase 3 存配对记录：重生成 Ed25519 签名密钥；HKDF 派生
//          setup_encryption_key = HKDF-SHA512(salt="Pair-Setup-Encrypt-Salt", ikm=session_key,
//                                            info="Pair-Setup-Encrypt-Info", 32)；
//          signing_material = HKDF-SHA512(salt="Pair-Setup-Controller-Sign-Salt", ikm=session_key,
//                                         info="Pair-Setup-Controller-Sign-Info", 32)；
//          sign_buffer = signing_material || identifier || ed25519_public_key；
//          Msg05 明文 = TLV{Identifier, PublicKey, Signature, Info(OPack 设备信息)}，
//          以 ChaCha20-Poly1305 加密（nonce = 4×0x00 || "PS-Msg05"，AAD 空），
//          外层 = TLV{EncryptedData, State=0x05}；设备回 State=0x06 的 EncryptedData（nonce "PS-Msg06"）。
//      §5 TLV8 / §6 OPack / §7 配对文件 的字段与常量同样取自该公开描述。
//    · SRP 数学在 a2_rppairing_srp.[hm]（已用 RFC 5054 §Appendix B 公开向量逐位核对）。
//
//  ★配对码（PIN）来源【可注入】★：
//    真机上配对码从哪来（iOS 是信任弹窗 + 固定码；TV/Vision 是屏幕显示 6 位码）属★未定项★，
//    本文件**不发明获取渠道**：由调用方通过 A2RPPairSetupPinProvider 注入；
//    未注入 / 返回空 ⇒ 一律如实拒绝并点名「配对码来源未注入」。
//
//  ★本文件能做到 / 做不到（如实，绝不假成功）★：
//    · 做到：Host 与 Device 两侧的 PS-Msg01..06 消息机（真密码学 + 真消息流），
//      并可在进程内 Host↔Device 自握手自证（双方会话密钥一致、篡改/错码被拒）。
//    · 做不到（本会话无真机）：与 iOS 27 真设备互操作；且 pair-setup 在真机上走的是
//      §2a/§2b（RemoteXPC）传输 —— §2c（裸 socket）按规格**不支持 pair-setup**。
//      本文件给出 A2RPPairSetupMessageTransport 抽象缝，传输实现另行提供。
//

#import <Foundation/Foundation.h>
#import "a2_rppairing.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 角色 / 步骤 / 配对码来源

typedef NS_ENUM(NSInteger, A2RPPairSetupRole) {
    A2RPPairSetupRoleHost   = 1,   ///< 控制器（本机；发起 pair-setup）
    A2RPPairSetupRoleDevice = 2,   ///< 设备（真机 / 自测里的角色扮演）
};

/// 协议状态号（与 TLV 里的 State 一致；Established 不是线上状态号）。
typedef NS_ENUM(NSInteger, A2RPPairSetupStep) {
    A2RPPairSetupStepIdle        = 0,
    A2RPPairSetupStepMsg01       = 1,
    A2RPPairSetupStepMsg02       = 2,
    A2RPPairSetupStepMsg03       = 3,
    A2RPPairSetupStepMsg04       = 4,
    A2RPPairSetupStepMsg05       = 5,
    A2RPPairSetupStepMsg06       = 6,
    A2RPPairSetupStepEstablished = 7,
};

/// 触发取配对码时的场景（供注入的提供者决定去哪拿码）。
typedef NS_ENUM(NSInteger, A2RPPairSetupPinPrompt) {
    A2RPPairSetupPinPromptOnDevice        = 1,  ///< 码显示在设备屏幕上（TV / Vision）
    A2RPPairSetupPinPromptAwaitingConsent = 2,  ///< 设备正在弹信任框（iOS 用固定码）
};

/// 配对码提供者。★可注入★：返回 nil / 空串 ⇒ 会话如实失败（不猜、不默认）。
typedef NSString *_Nullable (^A2RPPairSetupPinProvider)(A2RPPairSetupPinPrompt prompt);

/// 驱动模式的失败分类（"谁先发"由驱动方决定；失败也必须能归到一类）。
/// ★Host 侧的 runHostOverTransport: 不产出本枚举（保持原签名不动）★；
/// 本枚举只服务于 [A2-PAIRWIRE] 的 accessory/device 侧驱动。
typedef NS_ENUM(NSInteger, A2RPPairSetupDriveFailure) {
    A2RPPairSetupDriveFailureNone = 0,
    A2RPPairSetupDriveFailurePinMissing,      ///< 配对码为空 / 未注入
    A2RPPairSetupDriveFailurePeerRejected,    ///< 对端证明校验不过（码不对 / 被篡改）⇒ 拒绝
    A2RPPairSetupDriveFailureProtocol,        ///< 非 TLV8 / 缺字段 / 乱序 / 签名不过
    A2RPPairSetupDriveFailureTransport,       ///< 传输未提供所需原语 / 发失败 / 对端关闭
    A2RPPairSetupDriveFailureTransportTimeout,///< 等对端超时
    A2RPPairSetupDriveFailureNotEstablished,  ///< 走完消息流仍不在已建立态
};

/// 传输原语的失败分类（★可选能力★：实现方给出 ⇒ 上层能把「超时」与其它错分开）。
typedef NS_ENUM(NSInteger, A2RPPairSetupTransportFailure) {
    A2RPPairSetupTransportFailureNone = 0,
    A2RPPairSetupTransportFailureTimeout,      ///< 等对端超时
    A2RPPairSetupTransportFailurePeerClosed,   ///< 对端关闭
    A2RPPairSetupTransportFailureFormat,       ///< 帧/载荷格式错
    A2RPPairSetupTransportFailureOther,        ///< 其它（未分类）
};

#pragma mark - 消息传输缝（pair-setup 在真机上走 RemoteXPC；本缝由调用方实现）

@protocol A2RPPairSetupMessageTransport <NSObject>
/// 把一条 pairingData TLV 发给对端，**同步**取回对端的下一条 pairingData TLV。
/// @param kind           "setupManualPairing"（规格 §9）
/// @param startNewSession 首条 true，其后 false
/// @return nil ⇒ 失败，原因写进 reason。
/// ★语义不变★：发起方（Host/controller）侧驱动继续用本方法（先发后收）。
- (NSData *_Nullable)exchangePairingData:(NSData *)tlv
                                    kind:(NSString *)kind
                                startNew:(BOOL)startNewSession
                                  reason:(NSString *_Nullable *_Nullable)reason;

@optional
/// 传输层是否观察到设备在等用户同意（规格 §9 Phase 1 的 awaitingUserConsent）。
/// 置 YES ⇒ Host 取配对码时用 A2RPPairSetupPinPromptAwaitingConsent。
- (BOOL)transportObservedAwaitingUserConsent;

/// ★[A2-PAIRWIRE] 只收对端的下一条 pairingData（不发送）★。
/// 响应方（accessory/device 侧）的会话★由对端发起★ ⇒ 必须先收 PS-Msg01 再回 PS-Msg02。
/// ★不实现本方法的传输 ⇒ accessory 侧驱动如实失败（不假装能收）★；
/// ★Host 侧一个字都不用改★（它压根不调本方法）。
- (NSData *_Nullable)receivePairingDataWithKind:(NSString *)kind
                                        timeout:(NSTimeInterval)timeout
                                         reason:(NSString *_Nullable *_Nullable)reason;

/// ★[A2-PAIRWIRE] 只发一条 pairingData（不等回复）★。
/// 响应方的★最后一条★（PS-Msg06）之后对端不再回 ⇒ 用 exchange 会被迫等到超时；
/// 用本原语「发完即收工」，既不会把成功当超时，也不会把发失败当成功。
- (BOOL)sendPairingData:(NSData *)tlv
                   kind:(NSString *)kind
               startNew:(BOOL)startNewSession
                 reason:(NSString *_Nullable *_Nullable)reason;

/// ★[A2-PAIRWIRE] 最近一次原语调用的失败分类★（可选）：给出它，上层就能把
/// 「等对端超时」与「格式/连接错」分开（判据行与 UI 分流都要）。
/// ★不实现 ⇒ 视为 Other★（仍如实失败，只是分类粗一档）。
@property (nonatomic, readonly) A2RPPairSetupTransportFailure lastFailureKind;
@end

#pragma mark - 会话

@interface A2RPPairSetupSession : NSObject

@property (nonatomic, readonly) A2RPPairSetupRole role;
@property (nonatomic, readonly) A2RPPairSetupStep step;
@property (nonatomic, readonly) BOOL established;
/// 本方身份（Ed25519 密钥对 + identifier）。★strong 而非 copy（不可变且不实现 NSCopying）★。
@property (nonatomic, readonly, strong) A2RPPairingIdentity *identity;
/// SRP 会话密钥（= 后续 TLS-PSK 的加密密钥；建立后才有）。
@property (nonatomic, readonly, copy, nullable) NSData *sessionKey;
/// 对端（设备）从 Msg06 里带出的信息（Host 侧；可能为 nil / 不完整，规格说「非必需」）。
@property (nonatomic, readonly, copy, nullable) NSString *peerIdentifier;
@property (nonatomic, readonly, copy, nullable) NSData *peerPublicKey;
/// Msg06 解密后的设备原始 TLV（Host 侧；诊断/留存用）。
@property (nonatomic, readonly, copy, nullable) NSData *peerInfoTLV;

/// Host 会话。identity 必须是【本次配对新生成】的 Ed25519 身份；配对码经 pinProvider 取。
+ (nullable instancetype)hostSessionWithIdentity:(A2RPPairingIdentity *)identity
                                     pinProvider:(A2RPPairSetupPinProvider)pinProvider
                                          reason:(NSString *_Nullable *_Nullable)reason;

/// Device 会话（自测 / 校验器生成用）。pin = 设备侧自己的配对码。
+ (nullable instancetype)deviceSessionWithIdentity:(A2RPPairingIdentity *)identity
                                               pin:(NSString *)pin
                                            reason:(NSString *_Nullable *_Nullable)reason;

/// 生成本方下一条要发送的 TLV8 消息。nil ⇒ 此刻没有要发的；reason 说明原因。
- (NSData *_Nullable)nextMessageWithReason:(NSString *_Nullable *_Nullable)reason;

/// 处理从对端收到的 TLV8 消息。★任何校验失败都返回 NO 并回填 reason（绝不半信）★。
- (BOOL)acceptMessage:(NSData *)tlv reason:(NSString *_Nullable *_Nullable)reason;

/// 设置「取配对码」的场景提示（默认 OnDevice）。传输层已知设备在弹信任框时设为 AwaitingConsent。
- (void)setPinPromptHint:(A2RPPairSetupPinPrompt)prompt;

/// Host 侧一次性驱动：喂给传输缝跑完 PS-Msg01..06。
/// 成功 ⇒ YES，sessionKeyOut 回填 SRP 会话密钥。★配对文件由调用方从 identity 取★。
+ (BOOL)runHostOverTransport:(id<A2RPPairSetupMessageTransport>)transport
                    identity:(A2RPPairingIdentity *)identity
                 pinProvider:(A2RPPairSetupPinProvider)pinProvider
                      reason:(NSString *_Nullable *_Nullable)reason
                  sessionKey:(NSData *_Nullable *_Nullable)sessionKeyOut;

/// ★[A2-PAIRWIRE] Device/accessory 侧一次性驱动★（★先收后发★，与上面 Host 侧相反）。
/// 会话由对端（rppairing host/controller）发起：先收 PS-Msg01，再回 PS-Msg02……直到 PS-Msg06。
/// @param pin          本机正在显示的 6 位码（★空 ⇒ 立即失败 PinMissing★，不猜不默认）。
/// @param stepObserver 每条消息进/出后回调（step=会话当前步，line=判据行内容）；可为 nil。
/// @param failureOut   失败分类（可为 NULL）；成功时回填 None。
/// 成功 ⇒ YES，sessionKeyOut 回填 SRP 会话密钥；配对文件由调用方从 identity 取。
+ (BOOL)runAccessoryOverTransport:(id<A2RPPairSetupMessageTransport>)transport
                         identity:(A2RPPairingIdentity *)identity
                              pin:(NSString *)pin
                     stepObserver:(nullable void (^)(A2RPPairSetupStep step, NSString *line))stepObserver
                           reason:(NSString *_Nullable *_Nullable)reason
                     failureKind:(A2RPPairSetupDriveFailure *_Nullable)failureOut
                       sessionKey:(NSData *_Nullable *_Nullable)sessionKeyOut;

@end

#pragma mark - 进程内自握手（运行期自证）

@interface A2RPPairSetupSelfTest : NSObject
@property (nonatomic, readonly) BOOL ok;
@property (nonatomic, readonly, copy) NSString *summary;
/// 双方 SRP 会话密钥是否一致。
@property (nonatomic, readonly) BOOL sessionKeysEqual;
/// 篡改 Msg03 的 M1 后，Device 是否如实拒绝。
@property (nonatomic, readonly) BOOL tamperRejected;
/// 配对码不一致（Host 码 ≠ Device 码）时，Device 是否如实拒绝。
@property (nonatomic, readonly) BOOL wrongPinRejected;
/// 六条消息的字节数（供日志核对消息流确实发生了）。
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *messageSizes;
/// 跑一次完整自握手（真密码学 + 真消息流 PS-Msg01..06）。不做网络、不写盘。
+ (A2RPPairSetupSelfTest *)runSelfTest;

@end

NS_ASSUME_NONNULL_END
