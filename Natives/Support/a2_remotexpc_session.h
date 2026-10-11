//
//  a2_remotexpc_session.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— [A2-RXPC] RemoteXPC 会话：初始化握手 + 「发一条 pairingData TLV / 收下一条」。
//
//  角色与方向：
//    · 公开规格 §4 的初始化序列（前导 / SETTINGS / WINDOW_UPDATE / 开流 1 / 空 XPC 字典 /
//      开流 3 / init 握手 / 流 1 特殊标志 0x201）在本层【真发】。
//    · RPPairing 的 pairingData 走 RemoteXPC 的【根通道流 1】（DATA + XPC 消息）。
//    · 二进制在这里是【原始字节】（XPC Data），★不是 base64★（那是 §2c 裸 socket 的约定）。
//
//  ★本层是「可注入传输」的：字节通道是协议 A2RPByteStream★。
//    真实实现见 a2_rppairing_pairsetup_transport.[hm]（NWConnection / 被接受的连接）；
//    单测用 A2RemoteXPCInMemoryStream（本文件自带，脚本化应答）。
//
//  ★做到 / 做不到（如实）★：
//    · 做到：真建连（由字节通道实现）、真帧、真超时、错误分类（A2RemoteXPCErrorKind）、判据行 [RXPC]。
//    · 做不到：与 iOS 27 真设备互操作（本会话无真机）。头块/流控细节按公开规格写，
//      ★不声称已验证★；失败一律如实返回原因，不静默重试到底、不假报成功。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 错误分类（★失败必须能归到一类，供判据行与 UI 分流★）。
typedef NS_ENUM(NSInteger, A2RemoteXPCErrorKind) {
    A2RemoteXPCErrorNone = 0,
    A2RemoteXPCErrorNotConnected,      ///< 未握手/未连接
    A2RemoteXPCErrorConnectFailed,     ///< 建连失败（对端拒绝/DNS/权限）
    A2RemoteXPCErrorConnectTimeout,    ///< 建连超时
    A2RemoteXPCErrorHandshakeFailed,   ///< RemoteXPC 初始化握手失败
    A2RemoteXPCErrorHandshakeTimeout,  ///< 初始化握手超时
    A2RemoteXPCErrorSendFailed,        ///< 写失败
    A2RemoteXPCErrorReceiveTimeout,    ///< 等对端超时
    A2RemoteXPCErrorFrameFormat,       ///< 帧格式错
    A2RemoteXPCErrorPeerClosed,        ///< 对端关闭连接
    A2RemoteXPCErrorXPCDecode,         ///< 载荷不是可解的 XPC 对象
    A2RemoteXPCErrorUnsupported,       ///< 对端用了本仓不做的形态（如 Huffman/动态表）
    A2RemoteXPCErrorCancelled,         ///< 主动取消
};

/// 错误分类的稳定诊断名（判据行/日志用）。
NSString *A2RemoteXPCErrorKindName(A2RemoteXPCErrorKind kind);

#pragma mark - 字节通道（可注入）

/// 一条【同步】字节通道。实现方负责真建连与真超时。
@protocol A2RPByteStream <NSObject>
/// 建连（真做）。失败 ⇒ NO + reason + error。
- (BOOL)openStreamWithTimeout:(NSTimeInterval)timeout
                       reason:(NSString *_Nullable *_Nullable)reason
                        error:(A2RemoteXPCErrorKind *_Nullable)errorOut;
/// 全量写出（真做）。失败 ⇒ NO + reason + error。
- (BOOL)writeBytes:(NSData *)bytes
           timeout:(NSTimeInterval)timeout
            reason:(NSString *_Nullable *_Nullable)reason
             error:(A2RemoteXPCErrorKind *_Nullable)errorOut;
/// 读一段（真做）。★超时/对端关闭都返回 nil 并用 error 区分★。
- (NSData *_Nullable)readBytesWithTimeout:(NSTimeInterval)timeout
                                   reason:(NSString *_Nullable *_Nullable)reason
                                    error:(A2RemoteXPCErrorKind *_Nullable)errorOut;
/// 关闭（幂等）。
- (void)closeStream;
@end

#pragma mark - 内存字节通道（单测/自证用）

/// 脚本化的内存字节通道：读时按 FIFO 回放预置块；队列空 ⇒ 视 closed 回 ReceiveTimeout 或 PeerClosed。
@interface A2RemoteXPCInMemoryStream : NSObject <A2RPByteStream>

/// 建连是否失败（模拟 ConnectFailed）。
@property (nonatomic) BOOL failOnOpen;
/// 第几次写之后开始失败（0 = 不失败）。
@property (nonatomic) NSUInteger failOnWriteAtIndex;
/// 读返回 nil 时按「对端已关闭」分类（默认 NO ⇒ 超时）。
@property (nonatomic) BOOL peerClosed;
/// 由测试方预置的「对端将发来的字节块」队列（FIFO）。
- (void)enqueueReadChunk:(NSData *)chunk;
/// 已写出的字节（断言用）。
@property (nonatomic, readonly, copy) NSData *writtenBytes;
@property (nonatomic, readonly) NSUInteger writeCount;
@property (nonatomic, readonly) BOOL opened;
@property (nonatomic, readonly) BOOL closed;
@end

#pragma mark - 会话

@interface A2RemoteXPCSession : NSObject

- (instancetype)initWithStream:(id<A2RPByteStream>)stream
           wireProtocolVersion:(NSUInteger)wireProtocolVersion
                  originatedBy:(NSString *)originatedBy;

@property (nonatomic, readonly) BOOL handshakeComplete;
/// 已发出的 RPPairing 消息计数（= 下一条的 sequenceNumber）。
@property (nonatomic, readonly) NSUInteger sequenceNumber;
/// 传输层是否观察到设备在等用户同意（规格 §9 Phase 1）。
@property (nonatomic, readonly) BOOL observedAwaitingUserConsent;
/// 「发一条 pairingData、等对端下一条」的总超时（默认 30s；可调，便于单测）。
@property (nonatomic) NSTimeInterval exchangeTimeout;

/// 真建连 + RemoteXPC 初始化握手（公开规格 §4）。失败 ⇒ NO + reason + error。
- (BOOL)connectAndHandshakeWithTimeout:(NSTimeInterval)timeout
                                reason:(NSString *_Nullable *_Nullable)reason
                                 error:(A2RemoteXPCErrorKind *_Nullable)errorOut;

/// 发一条 pairingData TLV，同步取回对端的下一条 pairingData TLV。
/// @param fromPeerOut 回填「这条对端消息是从哪条流来的」（诊断用；可为 NULL）。
/// @return nil ⇒ 失败，reason 写明原因、error 给出分类。
- (NSData *_Nullable)exchangePairingData:(NSData *)tlv
                                    kind:(NSString *)kind
                                startNew:(BOOL)startNewSession
                                  reason:(NSString *_Nullable *_Nullable)reason
                                   error:(A2RemoteXPCErrorKind *_Nullable)errorOut;

/// 关闭（幂等）。
- (void)close;

@end

NS_ASSUME_NONNULL_END
