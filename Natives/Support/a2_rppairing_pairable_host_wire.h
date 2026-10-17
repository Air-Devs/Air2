//
//  a2_rppairing_pairable_host_wire.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [A2-PAIRPIN] pairable-host 连接的【线上契约】——纯 Foundation、无 Network.framework、
//  无 socket：帧编解码 / 信封 / 握手里程碑 / TLV 承载体，全部是纯函数
//  ⇒ 可在 macOS 上真编译真跑（tests/Natives/pairable_host_wire_tests.m）。
//
//  ── 为什么需要这一层（本单的根因）──
//  设备「发起」配对时连到 `_remotepairing-pairable-host._tcp` 之后，走的是
//  【裸 TCP + "RPPairing" 前导 + 2 字节大端长度 + UTF-8 JSON 信封】这条线；
//  ★不是★ §2b `_remoted._tcp` 的 RemoteXPC（HTTP/2 前导 + SETTINGS + XPC 字典）。
//  把 RemoteXPC 会话套在这条连接上 ⇒ 设备收到的是 HTTP/2 前导而非握手响应，
//  于是它永远不发 pair-setup M1，界面停在「已连入」且从不弹 6 位码输入框。
//
//  ── 线上顺序（本侧 = accessory/responder，★对端先说话★）──
//    ① 设备 → 握手请求 `request._0.handshake._0`
//    ② 本机 → 握手响应 `response._1.handshake._0`（含 deviceOptions）
//    ③ 设备 → M1（pairingData，State=1）
//    ④ 本机 → M2（pairingData，State=2 + Salt + PublicKey=B）★设备在此之后才弹输码框★
//    ⑤ … M3/M4、M5/M6
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 帧前导：9 字节 ASCII `RPPairing`；其后 2 字节【大端】长度，再其后 UTF-8 JSON。
FOUNDATION_EXPORT NSString *const A2RPPHWWireMagicString;

/// 本侧在 pairable-host 会话里扮演 accessory/responder ⇒ 信封的 `originatedBy` 恒为 `device`。
FOUNDATION_EXPORT NSString *const A2RPPHWOriginatedByAccessory;

/// 握手里我们声明支持的最低对端协议版本（与公开实现同值 8）。
FOUNDATION_EXPORT const NSUInteger A2RPPHWMinimumWireProtocolVersion;

/// 判据行标记（★单行、默认可见★）。
FOUNDATION_EXPORT NSString *const A2RPPHWCriterionMarker;

#pragma mark - 帧

/// 拼一帧：magic + 2B 大端长度 + JSON 负载。
/// 负载长度 > 65535 ⇒ nil 且写 why（★不静默截断★）。
NSData *_Nullable A2RPPHWEncodeFrame(NSData *jsonPayload, NSString *_Nullable *_Nullable why);

/// 校验前导并读出负载长度。buffer 至少 11 字节；magic 不符/长度不足 ⇒ NO + why。
BOOL A2RPPHWDecodeFrameHeader(NSData *buffer,
                              NSUInteger *_Nullable outPayloadLength,
                              NSString *_Nullable *_Nullable why);

#pragma mark - 信封

/// 信封：`{"message":{"plain":{"_0":value}},"originatedBy":…,"sequenceNumber":…}`
NSData *_Nullable A2RPPHWEncodeEnvelope(id value,
                                        NSString *originatedBy,
                                        NSUInteger sequenceNumber,
                                        NSString *_Nullable *_Nullable why);

/// 解信封。返回整条信封字典（用于读 originatedBy / sequenceNumber）；
/// `outPlainValue` 取 `message.plain._0`，缺席时回退为整条信封（与对端实现同口径）。
NSDictionary *_Nullable A2RPPHWDecodeEnvelope(NSData *json,
                                              id _Nullable *_Nullable outPlainValue,
                                              NSString *_Nullable *_Nullable why);

#pragma mark - 握手

/// 握手响应（②）。`wireVersion` 走 `A2RPPairableHostWireProtocolVersion`。
NSDictionary *A2RPPHWHandshakeResponse(NSString *name,
                                       NSString *model,
                                       NSString *identifier,
                                       NSString *udid,
                                       NSUInteger wireVersion);

/// `deviceOptions`。★`allowsPinlessPairing = NO` + `allowsPairSetup = YES`
/// 就是「本机要用户输 6 位配对码」的声明★——声明成可免码，设备就不会弹输码框。
NSDictionary *A2RPPHWDeviceOptions(void);

/// 是不是握手请求（`request._0.handshake._0` 存在）。
BOOL A2RPPHWIsHandshakeRequest(id _Nullable plainValue);

/// 设备是否要求 pair-verify（`hostOptions.attemptPairVerify` 为真）。
/// ★本侧只支持 pair-setup ⇒ 为真时必须如实拒绝，不假装能继续★。
BOOL A2RPPHWHandshakeWantsPairVerify(id _Nullable plainValue);

#pragma mark - pairingData 事件

/// 造一条 pairingData 事件值（放进信封 `message.plain._0`）。
NSDictionary *A2RPPHWEncodePairingDataEvent(NSString *base64TLV,
                                            NSString *kind,
                                            BOOL startNewSession);

/// 是不是 pairingData 事件（`event._0.pairingData._0` 存在）。
BOOL A2RPPHWIsPairingDataEvent(id _Nullable plainValue);

/// 取事件里的 TLV 字节（`data` 是 base64 字符串）；顺带回填 `kind`。
NSData *_Nullable A2RPPHWPairingDataFromEvent(id _Nullable plainValue,
                                              NSString *_Nullable *_Nullable outKind,
                                              NSString *_Nullable *_Nullable why);

#pragma mark - 判据

/// 前 N 字节的大写十六进制（诊断：对端最先发来的字节）。
NSString *A2RPPHWHexPrefix(NSData *_Nullable data, NSUInteger maxBytes);

/// 判据行（★返回值已含 `[A2-PAIRPIN]` 前缀★）：
/// `[A2-PAIRPIN] stage=… txKeys=… firstBytes=… m2=ok|fail reason=…`
NSString *A2RPPHWCriterionLine(NSString *stage,
                               NSArray<NSString *> *_Nullable txtKeys,
                               NSData *_Nullable firstBytes,
                               BOOL m2Sent,
                               NSString *_Nullable reason);

NS_ASSUME_NONNULL_END
