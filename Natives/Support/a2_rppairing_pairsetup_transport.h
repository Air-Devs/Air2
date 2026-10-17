//
//  a2_rppairing_pairsetup_transport.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— [A2-RXPC] 把 RemoteXPC 会话接到【真网络】上，并对齐 pair-setup 传输缝。
//
//  ── 三条连接路径与「哪条支持 pair-setup」（公开规格 §2，逐条出处）──
//    · §2c `_remotepairing._tcp`（裸 RPPairing socket，JSON 帧）
//        ★规格原文：该路径需要既有配对文件，**只支持 pair-verify，不支持 pair-setup**★。
//        本仓对应实现已存在：a2_rppairing_rsd.[hm]（A2RPRSDFrameReader / A2RPRSDPairVerifyClient）。
//    · §2b `_remoted._tcp`（RemoteXPC：HTTP/2 + XPC 帧；需设备侧 ncm）
//        载荷层 = 公开规格 §4。★pair-setup 在这条路上走 RemoteXPC★。
//        本文件的 A2RPNetworkByteStream + A2RPPairSetupRemoteXPCTransport 就是这条路的实现。
//    · §2a USB/CoreDeviceProxy（USB → usbmuxd → lockdownd → CDTunnel → 用户态 TCP → RSD → RemoteXPC）
//        ★本仓在 iOS App 内【做不到】，理由见 A2RPPairSetupUSBPathAvailable 的实现注释★。
//
//  ── 交付边界（如实，绝不假成功）──
//    · 真做：TCP 建连（§2b 的端点）、字节通道的写/读与超时、RemoteXPC 会话、错误分类、判据行 [RXPC]。
//    · 不做：USB/§2a。★原因写在 A2RPPairSetupUSBPathAvailable★。
//    · 不声称：与 iOS 27 真设备互操作（本会话无真机）。
//

#import <Foundation/Foundation.h>
#import "a2_remotexpc_session.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - §2a 可用性（如实）

/// §2a（USB/CoreDeviceProxy）在本仓/本平台上是否可用。
/// @return ★恒 NO★（iOS App 无法充当 USB 主机，也拿不到 usbmuxd/lockdownd 通道）；原因写进 reason。
BOOL A2RPPairSetupUSBPathAvailable(NSString *_Nullable *_Nullable reason);

#pragma mark - 真网络上的字节通道

/// 基于 Network.framework 的【同步】字节通道（真 TCP；真超时）。
/// 两种来源：① 从端点建连（§2b 的 `_remoted._tcp`）；② 包一条【已被接受】的连接（pairable-host 被连入）。
@interface A2RPNetworkByteStream : NSObject <A2RPByteStream>

/// ① 建连到 Bonjour/TCP 端点（端点对象来自 A2RPRSDDiscovery 的发现结果）。
/// ★构造不自带连接★：真连接发生在 openStreamWithTimeout:（协议要求）。
+ (nullable instancetype)streamToEndpoint:(id)endpoint
                                   reason:(NSString *_Nullable *_Nullable)reason;

/// ② 包一条已被接受的连接（pairable-host 通告后被系统连入）。
+ (instancetype)streamOverAcceptedConnection:(id)connection;

/// 对端的可读描述（`host:port`；日志/判据行用）。
@property (nonatomic, readonly, copy, nullable) NSString *peerDescription;

@end

#pragma mark - 缝：A2RPPairSetupMessageTransport 在 RemoteXPC 之上的实现

/// 实现 pair-setup 的传输缝 ABI：
///   `- exchangePairingData:kind:startNew:reason:`（把一条 pairingData TLV 发出去、同步取回下一条）。
/// ★协议一致性★：当同仓存在 `a2_rppairing_pairsetup.h`（pair-setup 单）时，本类【额外声明】遵守
/// `A2RPPairSetupMessageTransport`（见 .m 里的 __has_include）；不存在时只提供同签名方法，编译不受影响。
@interface A2RPPairSetupRemoteXPCTransport : NSObject

/// 是否观察到设备在等用户同意（规格 §9 Phase 1），透传自会话。
@property (nonatomic, readonly) BOOL awaitingUserConsentObserved;

/// 用一条字节通道构造（会先做 RemoteXPC 初始化握手；流为 nil 时如实失败）。
+ (nullable instancetype)transportOverByteStream:(nullable id<A2RPByteStream>)stream
                                        hostName:(NSString *)hostName
                                     wireVersion:(NSUInteger)wireVersion
                                         timeout:(NSTimeInterval)timeout
                                          reason:(NSString *_Nullable *_Nullable)reason
                                           error:(A2RemoteXPCErrorKind *_Nullable)errorOut;

/// ★[A2-PAIRWIRE] 同上，但显式指定 `originatedBy`（"host" / "device"）★。
/// 设备发起配对的路径里本机是 accessory ⇒ 传 "device"（既有方法恒传 "host"，语义未改）。
/// ★该字段的取值口径以真机对拍为准（本会话无真机，见报告）★。
+ (nullable instancetype)transportOverByteStream:(nullable id<A2RPByteStream>)stream
                                    originatedBy:(NSString *)originatedBy
                                        hostName:(NSString *)hostName
                                     wireVersion:(NSUInteger)wireVersion
                                         timeout:(NSTimeInterval)timeout
                                          reason:(NSString *_Nullable *_Nullable)reason
                                           error:(A2RemoteXPCErrorKind *_Nullable)errorOut;

/// 缝方法（★无条件实现★）。nil ⇒ 失败，原因写进 reason。
- (NSData *_Nullable)exchangePairingData:(NSData *)tlv
                                    kind:(NSString *)kind
                                startNew:(BOOL)startNewSession
                                  reason:(NSString *_Nullable *_Nullable)reason;

- (void)close;

@end

#pragma mark - ★[A2-PAIRPIN] pairable-host 连接上的 JSON 传输（本单的修复点）★

/// pairable-host 被设备连入之后的那条线上契约：`"RPPairing"` + 2B 大端长度 + UTF-8 JSON 信封。
///
/// ★为什么不能用 A2RPPairSetupRemoteXPCTransport★：那条路是 §2b `_remoted._tcp` 的
/// RemoteXPC（HTTP/2 前导 + SETTINGS + WINDOW_UPDATE + HEADERS + XPC 字典）。
/// 把 RemoteXPC 套在 pairable-host 连接上，设备收到的第一段字节是
/// `PRI * HTTP/2.0…` 而不是握手响应 ⇒ 它永远不发 pair-setup M1 ⇒
/// 界面停在「已连入」且★从不弹 6 位码输入框★（用户反馈的正是这一条）。
///
/// 本类只做三件事：
///   ① 收/发帧（magic + 大端长度 + JSON），带缓冲（底层读是"能读多少读多少"）；
///   ② 握手：收设备请求 → 回 `allowsPairSetup=YES / allowsPinlessPairing=NO` 的响应；
///   ③ 把 pair-setup 的 TLV 装进 `event.pairingData`（data 为 base64）。
/// 帧/信封/事件的全部编解码走 a2_rppairing_pairable_host_wire（纯函数，有单测）。
@interface A2RPPairSetupPairableHostJSONTransport : NSObject

/// 只包一条已被接受的字节通道；★不在这里握手★（上下文还用不上，见 beginSession）。
+ (nullable instancetype)transportWithStream:(nullable id<A2RPByteStream>)stream
                                    hostName:(NSString *)hostName;

/// ★握手（设备连上后的第一帧是握手请求，必须先回它）★。
/// 失败 ⇒ NO 且 reason 写明卡在哪一步（同时已打 `[A2-PAIRPIN]` 判据行）。
/// `txtKeys` 只用于判据行（证明通告的 TXT 契约），可为 nil。
- (BOOL)beginSessionWithName:(NSString *)name
                       model:(NSString *)model
                  identifier:(NSString *)identifier
                 wireVersion:(NSUInteger)wireVersion
                     txtKeys:(nullable NSArray<NSString *> *)txtKeys
                     timeout:(NSTimeInterval)timeout
                      reason:(NSString *_Nullable *_Nullable)reason;

/// 是否已完成握手（判据/UI 用）。
@property (nonatomic, readonly) BOOL handshakeCompleted;
/// 对端最先发来的原始字节（判据行的 `firstBytes=`）。
@property (nonatomic, readonly, copy, nullable) NSData *firstBytes;
- (void)close;

@end

NS_ASSUME_NONNULL_END
