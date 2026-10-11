//
//  a2_remotexpc_framing.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— [A2-RXPC] RemoteXPC 的【线上编解码】：HTTP/2 帧 + HPACK + XPC 消息/对象。
//
//  为什么需要这一层：
//    RPPairing 有三条连接路径（公开规格 §2）：
//      · §2c `_remotepairing._tcp`  —— 裸 RPPairing socket（magic "RPPairing" + 2B 大端长度 + JSON）。
//        ★该路径按规格【只支持 pair-verify】，不支持 pair-setup★。
//      · §2b `_remoted._tcp`        —— RemoteXPC（HTTP/2 + XPC 帧）。
//      · §2a USB/CoreDeviceProxy    —— 经 usbmuxd → lockdownd → CDTunnel → 用户态 TCP → RSD → RemoteXPC。
//    §2a/§2b 两条路的载荷层都是【RemoteXPC】（公开规格 §4），而本仓此前只落了 §2c（见 a2_rppairing_rsd.m）。
//    本文件把 §4 的编解码做成【纯逻辑、可单测】的一层，供会话层（a2_remotexpc_session.[hm]）调用。
//
//  协议出处（★只取公开规格事实/常量，未搬运任何项目源码★）：
//    · https://jkcoxson.com/blog/rppairing-spec §4「Transport Layer: RemoteXPC」：
//        连接前导 = ASCII "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"（24 字节）；
//        初始化：SETTINGS(MaxConcurrentStreams=100, InitialWindowSize=1048576) → WINDOW_UPDATE(increment=983041, stream 0)
//                → 开流 1(root, HEADERS) → 流 1 空 XPC 字典(flags=AlwaysSet)
//                → 开流 3(reply, HEADERS) → 流 3 init 握手(flags=InitHandshake|AlwaysSet)
//                → 流 1 特殊标志 0x201；
//        XPC 消息 = magic(4B LE 0x29B00B92) + flags(4B LE) + bodyLength(8B LE) + messageID(8B LE) + body；
//        flags：AlwaysSet=0x1 / DataFlag=0x100 / WantingReply=0x10000 / Reply=0x20000 / InitHandshake=0x400000；
//        XPC 对象体 = magic(4B LE 0x42133742) + version(4B LE 5) + 对象值；
//        对象类型号（u32 LE）：Null=0x1000 / Bool=0x2000 / Int64=0x3000 / UInt64=0x4000 / Double=0x5000 /
//          Date=0x7000 / Data=0x8000 / String=0x9000 / UUID=0xA000 / Dictionary=0xF000 / Array=0xE000。
//        Data   = 4B LE 长度 + 原始字节（补齐到 4 字节边界）；
//        String = 4B LE 长度（含结尾 NUL）+ NUL 结尾 UTF-8（补齐到 4 字节边界）；
//        Dict   = 4B LE 条目数 + 条目数 × (键字符串 + 值)；Array = 4B LE 元素数 + 元素数 × 值。
//    · HTTP/2 帧头 = 3B 长度 + 1B 类型 + 1B 标志 + 4B 流号（RFC 7540 §4.1）。
//    · HPACK（RFC 7541）静态表 = Appendix A；本层只实现【不索引字面量 / 索引字段 / 静态表】，
//      ★不支持 Huffman 与动态表★（编码从不产出 Huffman；解码遇 Huffman 一律如实报错，不猜）。
//
//  ★本文件能做到 / 做不到（如实，绝不假成功）★：
//    · 做到：帧/HPACK/XPC 的【编解码与往返自洽】，含错误路径（截断/非法 magic/超长载荷/未知类型）。
//    · 做不到（本会话无真机）：与 iOS 27 真设备的【互操作】。本层只保证「按公开规格自洽」，
//      不保证对端接受（对端还要看头块、流控、握手细节）。详见 D:\CTF\_AIR2_REMOTEXPC.md。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - HTTP/2（RFC 7540；RemoteXPC 的载荷层，公开规格 §4）

/// 固定 24 字节连接前导：ASCII "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"。
FOUNDATION_EXPORT NSString *const A2RXPCConnectionPrefaceString;
#define A2RXPC_PREFACE_BYTES   24
#define A2RXPC_FRAME_HEADER_BYTES 9

/// RemoteXPC 用到的两条流（公开规格 §4：1 = 根通道，3 = 回复通道）。
#define A2RXPC_STREAM_ROOT  1u
#define A2RXPC_STREAM_REPLY 3u
/// 流 1 的「特殊标志」（公开规格 §4 初始化第 7 步）。
#define A2RXPC_STREAM_SPECIAL_FLAGS 0x201u

typedef NS_ENUM(uint8_t, A2RXPCFrameType) {
    A2RXPCFrameTypeData         = 0x0,
    A2RXPCFrameTypeHeaders      = 0x1,
    A2RXPCFrameTypePriority     = 0x2,
    A2RXPCFrameTypeRstStream    = 0x3,
    A2RXPCFrameTypeSettings     = 0x4,
    A2RXPCFrameTypePushPromise  = 0x5,
    A2RXPCFrameTypePing         = 0x6,
    A2RXPCFrameTypeGoAway       = 0x7,
    A2RXPCFrameTypeWindowUpdate = 0x8,
    A2RXPCFrameTypeContinuation = 0x9,
};

typedef NS_ENUM(uint8_t, A2RXPCFrameFlag) {
    A2RXPCFrameFlagAck          = 0x1,   ///< SETTINGS/PING 的 ACK；DATA 的 END_STREAM
    A2RXPCFrameFlagEndHeaders   = 0x4,   ///< HEADERS/CONTINUATION 的 END_HEADERS
    A2RXPCFrameFlagPadded       = 0x8,
    A2RXPCFrameFlagPriority     = 0x20,
};

/// 一帧（解析后）。
@interface A2RXPCFrame : NSObject
@property (nonatomic) uint8_t type;
@property (nonatomic) uint8_t flags;
@property (nonatomic) uint32_t streamID;
@property (nonatomic, copy) NSData *payload;
@end

/// 连接前导字节（24）。
NSData *A2RXPCConnectionPreface(void);

/// 组帧：3B 长度 + 1B 类型 + 1B 标志 + 4B 流号 + 载荷。
/// 载荷 > 16777215 字节 ⇒ 返回 nil 并回填原因。
NSData *_Nullable A2RXPCEncodeFrame(A2RXPCFrame *frame, NSString *_Nullable *_Nullable reason);

/// 从累积缓冲里切一帧。
/// @return YES = 切出一帧（consumedOut / frameOut 有效）；
///         NO 且 *reasonOut == nil  ⇒ ★数据不够，等更多★；
///         NO 且 *reasonOut != nil  ⇒ ★确实是错★（长度非法等）。
BOOL A2RXPCDecodeFrame(NSData *buffer,
                       NSUInteger *consumedOut,
                       A2RXPCFrame *_Nullable *_Nullable frameOut,
                       NSString *_Nullable *_Nullable reasonOut);

/// 流式帧读取器（NWConnection 分片到达时用）。
@interface A2RXPCFrameReader : NSObject
- (void)appendData:(NSData *)data;
@property (nonatomic, readonly) NSUInteger bufferedBytes;
/// 语义同 A2RXPCDecodeFrame 的 reasonOut（nil = 不够）。
- (A2RXPCFrame *_Nullable)popFrameWithReason:(NSString *_Nullable *_Nullable)reasonOut;
@end

#pragma mark - HPACK（RFC 7541；只做静态表 + 字面量，★不做 Huffman/动态表★）

/// HPACK 静态表条目名（index 1..61）；越界 ⇒ nil。
NSString *_Nullable A2RXPCStaticTableName(NSUInteger index);
/// HPACK 静态表的完整条目（name, value）。
NSArray<NSArray<NSString *> *> *A2RXPCStaticTable(void);

/// 编码头块：对每对 (name, value) 写【不索引字面量】；名字若在静态表里则用其索引。
/// 头名/头值必须是非空 NSString；不合法 ⇒ 返回 nil 并回填原因。
NSData *_Nullable A2RXPCEncodeHeaderBlock(NSArray<NSArray<NSString *> *> *headers,
                                          NSString *_Nullable *_Nullable reason);
/// 解码头块：支持索引字段（静态表）、不索引字面量、增量索引字面量、动态表尺寸更新（忽略但校验）。
/// 遇 Huffman（H=1）或动态表索引 ⇒ 返回 nil 并回填原因（★如实不猜★）。
NSArray<NSArray<NSString *> *> *_Nullable A2RXPCDecodeHeaderBlock(NSData *block,
                                                                  NSString *_Nullable *_Nullable reason);

#pragma mark - XPC（公开规格 §4）

#define A2RXPC_XPC_MESSAGE_MAGIC  0x29B00B92u
#define A2RXPC_XPC_OBJECT_MAGIC   0x42133742u
#define A2RXPC_XPC_OBJECT_VERSION 5u
#define A2RXPC_XPC_MESSAGE_HEADER_BYTES 24   // magic(4)+flags(4)+bodyLen(8)+msgID(8)

#define A2RXPC_XPC_FLAG_ALWAYS_SET     0x00000001u
#define A2RXPC_XPC_FLAG_DATA           0x00000100u
#define A2RXPC_XPC_FLAG_WANTING_REPLY  0x00010000u
#define A2RXPC_XPC_FLAG_REPLY          0x00020000u
#define A2RXPC_XPC_FLAG_INIT_HANDSHAKE 0x00400000u

/// XPC 对象类型号（u32 LE）。
typedef NS_ENUM(uint32_t, A2RXPCObjectType) {
    A2RXPCObjectTypeNull       = 0x00001000u,
    A2RXPCObjectTypeBool       = 0x00002000u,
    A2RXPCObjectTypeInt64      = 0x00003000u,
    A2RXPCObjectTypeUInt64     = 0x00004000u,
    A2RXPCObjectTypeDouble     = 0x00005000u,
    A2RXPCObjectTypeDate       = 0x00007000u,
    A2RXPCObjectTypeData       = 0x00008000u,
    A2RXPCObjectTypeString     = 0x00009000u,
    A2RXPCObjectTypeUUID       = 0x0000A000u,
    A2RXPCObjectTypeDictionary = 0x0000F000u,
    A2RXPCObjectTypeArray      = 0x0000E000u,
};

/// 一条 XPC 消息。
@interface A2RXPCXPCMessage : NSObject
@property (nonatomic) uint32_t flags;
@property (nonatomic) uint64_t messageID;
/// 对象体：A2RXPCEncodeXPCValue 的产物（含对象 magic + version）。
@property (nonatomic, copy) NSData *body;
@end

/// 组一条 XPC 消息（magic + flags + bodyLen + msgID + body）。
NSData *_Nullable A2RXPCEncodeXPCMessage(A2RXPCXPCMessage *message, NSString *_Nullable *_Nullable reason);

/// 从累积缓冲里切一条 XPC 消息。语义同 A2RXPCDecodeFrame（reasonOut==nil = 不够）。
BOOL A2RXPCDecodeXPCMessage(NSData *buffer,
                            NSUInteger *consumedOut,
                            A2RXPCXPCMessage *_Nullable *_Nullable messageOut,
                            NSString *_Nullable *_Nullable reasonOut);

/// 编码一个 XPC 值（含对象 magic + version 前缀）。
/// 支持：NSNull / NSNumber(bool|int64|uint64|double) / NSData / NSString / NSUUID /
///       NSDictionary<NSString *, id> / NSArray<id>。
/// 不支持的类型 / 非字符串键 / 嵌套过深 ⇒ 返回 nil 并回填原因。
NSData *_Nullable A2RXPCEncodeXPCValue(id value, NSString *_Nullable *_Nullable reason);

/// 解码一个 XPC 值。consumedOut 回填已消费字节数。语义同上（nil reason = 不够）。
/// @return nil + reason==nil ⇒ 不够；nil + reason!=nil ⇒ 错。成功 ⇒ 返回解码值。
id _Nullable A2RXPCDecodeXPCValue(NSData *blob,
                                  NSUInteger *_Nullable consumedOut,
                                  NSString *_Nullable *_Nullable reason);

/// 值类型诊断名（日志用；稳定字符串）。
NSString *A2RXPCObjectTypeName(A2RXPCObjectType type);

#pragma mark - 判据行（[RXPC]，默认可见，可 grep）

/// 判据行统一出口：一行一条，前缀恒为 `[RXPC] `。message 里不要带换行。
/// 走 a2_log_f（前缀 `[RT] `），因此真机日志里表现为 `[RT] [RXPC] …`，grep `[RXPC]` 即得。
void A2RXPCLog(NSString *message);

NS_ASSUME_NONNULL_END
