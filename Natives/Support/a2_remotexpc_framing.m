//
//  a2_remotexpc_framing.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [A2-RXPC] RemoteXPC 线上编解码：HTTP/2 帧 + HPACK 静态表/字面量 + XPC 消息/对象。
//  协议出处、做到哪一步、以及「不做 Huffman/动态表」的边界，见头文件顶部。
//

#import "a2_remotexpc_framing.h"
#import "a2_log.h"

#import <string.h>

NSString *const A2RXPCConnectionPrefaceString = @"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

// ---------------------------------------------------------------------------
// 字节读写小工具（本文件私有；不对外暴露 ⇒ 不构成新 API 面）
// ---------------------------------------------------------------------------

static void A2RXPCAppendLE32(NSMutableData *out, uint32_t v) {
    uint8_t b[4];
    b[0] = (uint8_t)(v & 0xFF);
    b[1] = (uint8_t)((v >> 8) & 0xFF);
    b[2] = (uint8_t)((v >> 16) & 0xFF);
    b[3] = (uint8_t)((v >> 24) & 0xFF);
    [out appendBytes:b length:sizeof(b)];
}

static void A2RXPCAppendLE64(NSMutableData *out, uint64_t v) {
    uint8_t b[8];
    for (int i = 0; i < 8; i++) {
        b[i] = (uint8_t)((v >> (8 * i)) & 0xFF);
    }
    [out appendBytes:b length:sizeof(b)];
}

/// 读 4 字节 LE。越界 ⇒ NO。
static BOOL A2RXPCReadLE32(NSData *in, NSUInteger off, uint32_t *out) {
    if (off + 4 > in.length) {
        return NO;
    }
    const uint8_t *p = (const uint8_t *)in.bytes;
    *out = (uint32_t)p[off]
         | ((uint32_t)p[off + 1] << 8)
         | ((uint32_t)p[off + 2] << 16)
         | ((uint32_t)p[off + 3] << 24);
    return YES;
}

/// 读 8 字节 LE。越界 ⇒ NO。
static BOOL A2RXPCReadLE64(NSData *in, NSUInteger off, uint64_t *out) {
    if (off + 8 > in.length) {
        return NO;
    }
    const uint8_t *p = (const uint8_t *)in.bytes;
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) {
        v |= ((uint64_t)p[off + i]) << (8 * i);
    }
    *out = v;
    return YES;
}

/// 把缓冲补零到 4 字节边界（XPC 的 Data/String 后要对齐）。
static void A2RXPCPadTo4(NSMutableData *out) {
    NSUInteger rem = out.length % 4;
    if (rem != 0) {
        uint8_t zero[3] = { 0, 0, 0 };
        [out appendBytes:zero length:(4 - rem)];
    }
}

#pragma mark - 判据行

void A2RXPCLog(NSString *message) {
    a2_log_criterion(@"[RXPC] %@", message ?: @"");
}

#pragma mark - HTTP/2

@implementation A2RXPCFrame
- (instancetype)init {
    self = [super init];
    if (self) {
        _payload = [NSData data];
    }
    return self;
}
@end

NSData *A2RXPCConnectionPreface(void) {
    return [A2RXPCConnectionPrefaceString dataUsingEncoding:NSASCIIStringEncoding];
}

NSData *A2RXPCEncodeFrame(A2RXPCFrame *frame, NSString **reason) {
    if (frame == nil) {
        if (reason) {
            *reason = @"帧为 nil";
        }
        return nil;
    }
    NSUInteger len = frame.payload.length;
    if (len > 0xFFFFFFu) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"HTTP/2 帧载荷超过 24 位上限（%lu 字节）",
                       (unsigned long)len];
        }
        return nil;
    }
    NSMutableData *out = [NSMutableData dataWithCapacity:A2RXPC_FRAME_HEADER_BYTES + len];
    uint8_t head[9];
    head[0] = (uint8_t)((len >> 16) & 0xFF);
    head[1] = (uint8_t)((len >> 8) & 0xFF);
    head[2] = (uint8_t)(len & 0xFF);
    head[3] = frame.type;
    head[4] = frame.flags;
    // 流号最高位恒为 0（R 位）
    head[5] = (uint8_t)((frame.streamID >> 24) & 0x7F);
    head[6] = (uint8_t)((frame.streamID >> 16) & 0xFF);
    head[7] = (uint8_t)((frame.streamID >> 8) & 0xFF);
    head[8] = (uint8_t)(frame.streamID & 0xFF);
    [out appendBytes:head length:sizeof(head)];
    if (len > 0) {
        [out appendData:frame.payload];
    }
    return out;
}

BOOL A2RXPCDecodeFrame(NSData *buffer,
                       NSUInteger *consumedOut,
                       A2RXPCFrame **frameOut,
                       NSString **reasonOut) {
    if (reasonOut) {
        *reasonOut = nil;
    }
    if (buffer.length < A2RXPC_FRAME_HEADER_BYTES) {
        return NO;                          // ★不够 ≠ 出错★
    }
    const uint8_t *p = (const uint8_t *)buffer.bytes;
    NSUInteger len = ((NSUInteger)p[0] << 16) | ((NSUInteger)p[1] << 8) | (NSUInteger)p[2];
    if (buffer.length < A2RXPC_FRAME_HEADER_BYTES + len) {
        return NO;                          // 载荷还没收全
    }
    A2RXPCFrame *f = [[A2RXPCFrame alloc] init];
    f.type = p[3];
    f.flags = p[4];
    f.streamID = (((uint32_t)p[5] & 0x7F) << 24)
               | ((uint32_t)p[6] << 16)
               | ((uint32_t)p[7] << 8)
               | (uint32_t)p[8];
    f.payload = len > 0
        ? [buffer subdataWithRange:NSMakeRange(A2RXPC_FRAME_HEADER_BYTES, len)]
        : [NSData data];
    if (consumedOut) {
        *consumedOut = A2RXPC_FRAME_HEADER_BYTES + len;
    }
    if (frameOut) {
        *frameOut = f;
    }
    return YES;
}

@interface A2RXPCFrameReader ()
@property (nonatomic, strong) NSMutableData *buffer;
@end

@implementation A2RXPCFrameReader

- (instancetype)init {
    self = [super init];
    if (self) {
        _buffer = [NSMutableData data];
    }
    return self;
}

- (void)appendData:(NSData *)data {
    if (data.length > 0) {
        [self.buffer appendData:data];
    }
}

- (NSUInteger)bufferedBytes {
    return self.buffer.length;
}

- (A2RXPCFrame *)popFrameWithReason:(NSString **)reasonOut {
    NSUInteger consumed = 0;
    A2RXPCFrame *f = nil;
    NSString *why = nil;
    if (!A2RXPCDecodeFrame(self.buffer, &consumed, &f, &why)) {
        if (reasonOut) {
            *reasonOut = why;
        }
        return nil;
    }
    [self.buffer replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
    if (reasonOut) {
        *reasonOut = nil;
    }
    return f;
}

@end

#pragma mark - HPACK

// RFC 7541 Appendix A 的静态表（公开规格数据）。
static NSArray<NSArray<NSString *> *> *A2RXPCStaticTableBuild(void) {
    return @[
        @[ @"", @"" ],                                   // index 0 占位（不可用）
        @[ @":authority", @"" ],
        @[ @":method", @"GET" ],
        @[ @":method", @"POST" ],
        @[ @":path", @"/" ],
        @[ @":path", @"/index.html" ],
        @[ @":scheme", @"http" ],
        @[ @":scheme", @"https" ],
        @[ @":status", @"200" ],
        @[ @":status", @"204" ],
        @[ @":status", @"206" ],
        @[ @":status", @"304" ],
        @[ @":status", @"400" ],
        @[ @":status", @"404" ],
        @[ @":status", @"500" ],
        @[ @"accept-charset", @"" ],
        @[ @"accept-encoding", @"gzip, deflate" ],
        @[ @"accept-language", @"" ],
        @[ @"accept-ranges", @"" ],
        @[ @"accept", @"" ],
        @[ @"access-control-allow-origin", @"" ],
        @[ @"age", @"" ],
        @[ @"allow", @"" ],
        @[ @"authorization", @"" ],
        @[ @"cache-control", @"" ],
        @[ @"content-disposition", @"" ],
        @[ @"content-encoding", @"" ],
        @[ @"content-language", @"" ],
        @[ @"content-length", @"" ],
        @[ @"content-location", @"" ],
        @[ @"content-range", @"" ],
        @[ @"content-type", @"" ],
        @[ @"cookie", @"" ],
        @[ @"date", @"" ],
        @[ @"etag", @"" ],
        @[ @"expect", @"" ],
        @[ @"expires", @"" ],
        @[ @"from", @"" ],
        @[ @"host", @"" ],
        @[ @"if-match", @"" ],
        @[ @"if-modified-since", @"" ],
        @[ @"if-none-match", @"" ],
        @[ @"if-range", @"" ],
        @[ @"if-unmodified-since", @"" ],
        @[ @"last-modified", @"" ],
        @[ @"link", @"" ],
        @[ @"location", @"" ],
        @[ @"max-forwards", @"" ],
        @[ @"proxy-authenticate", @"" ],
        @[ @"proxy-authorization", @"" ],
        @[ @"range", @"" ],
        @[ @"referer", @"" ],
        @[ @"refresh", @"" ],
        @[ @"retry-after", @"" ],
        @[ @"server", @"" ],
        @[ @"set-cookie", @"" ],
        @[ @"strict-transport-security", @"" ],
        @[ @"transfer-encoding", @"" ],
        @[ @"user-agent", @"" ],
        @[ @"vary", @"" ],
        @[ @"via", @"" ],
        @[ @"www-authenticate", @"" ],
    ];
}

NSArray<NSArray<NSString *> *> *A2RXPCStaticTable(void) {
    static NSArray<NSArray<NSString *> *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = A2RXPCStaticTableBuild(); });
    return table;
}

NSString *A2RXPCStaticTableName(NSUInteger index) {
    NSArray<NSArray<NSString *> *> *t = A2RXPCStaticTable();
    if (index == 0 || index >= t.count) {
        return nil;
    }
    return t[index][0];
}

/// RFC 7541 §5.1 整数编码（prefixBits 位前缀）。
static void A2RXPCAppendHPACKInteger(NSMutableData *out, uint8_t prefixBits, uint8_t pattern, NSUInteger value) {
    NSUInteger maxPrefix = ((NSUInteger)1 << prefixBits) - 1;
    if (value < maxPrefix) {
        uint8_t b = (uint8_t)(pattern | (uint8_t)value);
        [out appendBytes:&b length:1];
        return;
    }
    uint8_t b = (uint8_t)(pattern | (uint8_t)maxPrefix);
    [out appendBytes:&b length:1];
    NSUInteger rest = value - maxPrefix;
    while (rest >= 128) {
        uint8_t c = (uint8_t)((rest % 128) + 128);
        [out appendBytes:&c length:1];
        rest /= 128;
    }
    uint8_t c = (uint8_t)rest;
    [out appendBytes:&c length:1];
}

/// RFC 7541 §5.1 整数解码。成功 ⇒ YES 且回填 value / nextOff。
static BOOL A2RXPCReadHPACKInteger(NSData *in, NSUInteger off, uint8_t prefixBits,
                                   NSUInteger *valueOut, NSUInteger *nextOff, NSString **reason) {
    if (off >= in.length) {
        if (reason) {
            *reason = @"HPACK 整数被截断（越界）";
        }
        return NO;
    }
    const uint8_t *p = (const uint8_t *)in.bytes;
    NSUInteger maxPrefix = ((NSUInteger)1 << prefixBits) - 1;
    NSUInteger v = p[off] & (uint8_t)maxPrefix;
    NSUInteger i = off + 1;
    if (v < maxPrefix) {
        *valueOut = v;
        *nextOff = i;
        return YES;
    }
    NSUInteger shift = 0;
    while (i < in.length) {
        uint8_t b = p[i++];
        v += (NSUInteger)(b & 0x7F) << shift;
        if ((b & 0x80) == 0) {
            *valueOut = v;
            *nextOff = i;
            return YES;
        }
        shift += 7;
        if (shift > 56) {
            if (reason) {
                *reason = @"HPACK 整数溢出（续字节过多）";
            }
            return NO;
        }
    }
    if (reason) {
        *reason = @"HPACK 整数被截断";
    }
    return NO;
}

/// 写一个 HPACK 字符串字面量（★恒 H=0，不做 Huffman★）。
static BOOL A2RXPCAppendHPACKString(NSMutableData *out, NSString *s, NSString **reason) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (d == nil) {
        if (reason) {
            *reason = @"头字段不是合法 UTF-8";
        }
        return NO;
    }
    A2RXPCAppendHPACKInteger(out, 7, 0x00, d.length);   // H=0
    [out appendData:d];
    return YES;
}

/// 读一个 HPACK 字符串字面量。★H=1（Huffman）一律报错★。
static BOOL A2RXPCReadHPACKString(NSData *in, NSUInteger off, NSString **valueOut,
                                  NSUInteger *nextOff, NSString **reason) {
    if (off >= in.length) {
        if (reason) {
            *reason = @"HPACK 字符串被截断（越界）";
        }
        return NO;
    }
    const uint8_t *p = (const uint8_t *)in.bytes;
    BOOL huffman = (p[off] & 0x80) != 0;
    if (huffman) {
        if (reason) {
            *reason = @"头字段用了 Huffman 编码（★本仓不做 Huffman：如实拒绝，不猜★）";
        }
        return NO;
    }
    NSUInteger len = 0;
    NSUInteger afterLen = 0;
    if (!A2RXPCReadHPACKInteger(in, off, 7, &len, &afterLen, reason)) {
        return NO;
    }
    if (afterLen + len > in.length) {
        if (reason) {
            *reason = @"HPACK 字符串被截断";
        }
        return NO;
    }
    NSData *raw = [in subdataWithRange:NSMakeRange(afterLen, len)];
    NSString *s = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
    if (s == nil) {
        if (reason) {
            *reason = @"HPACK 字符串不是合法 UTF-8";
        }
        return NO;
    }
    *valueOut = s;
    *nextOff = afterLen + len;
    return YES;
}

/// 在静态表里找 (name, value) 的精确索引；找不到回 0。
static NSUInteger A2RXPCStaticExactIndex(NSString *name, NSString *value, BOOL *nameOnly) {
    if (nameOnly) {
        *nameOnly = NO;
    }
    if (value.length == 0) {
        return 0;                       // 空值不做精确匹配，交给「只匹配名字」分支
    }
    NSArray<NSArray<NSString *> *> *t = A2RXPCStaticTable();
    NSUInteger nameIdx = 0;
    for (NSUInteger i = 1; i < t.count; i++) {
        if ([t[i][0] isEqualToString:name]) {
            if (nameIdx == 0) {
                nameIdx = i;
            }
            if ([t[i][1] isEqualToString:value]) {
                return i;
            }
        }
    }
    if (nameIdx != 0 && nameOnly) {
        *nameOnly = YES;
    }
    return nameIdx;
}

NSData *A2RXPCEncodeHeaderBlock(NSArray<NSArray<NSString *> *> *headers, NSString **reason) {
    if (reason) {
        *reason = nil;
    }
    NSMutableData *out = [NSMutableData data];
    for (NSArray<NSString *> *pair in headers) {
        if (![pair isKindOfClass:[NSArray class]] || pair.count != 2) {
            if (reason) {
                *reason = @"头块条目不是 (name, value) 二元组";
            }
            return nil;
        }
        NSString *name = pair[0];
        NSString *value = pair[1];
        if (![name isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]
            || name.length == 0) {
            if (reason) {
                *reason = @"头字段名/值必须是非空字符串";
            }
            return nil;
        }
        BOOL nameOnly = NO;
        NSUInteger idx = A2RXPCStaticExactIndex(name, value, &nameOnly);
        NSUInteger exact = 0;
        if (value.length > 0) {
            NSArray<NSArray<NSString *> *> *t = A2RXPCStaticTable();
            for (NSUInteger i = 1; i < t.count; i++) {
                if ([t[i][0] isEqualToString:name] && [t[i][1] isEqualToString:value]) {
                    exact = i;
                    break;
                }
            }
        }
        if (exact != 0) {
            // 索引头字段：1xxxxxxx
            A2RXPCAppendHPACKInteger(out, 7, 0x80, exact);
            continue;
        }
        if (idx != 0) {
            // 不索引字面量 + 索引名字：0000xxxx
            A2RXPCAppendHPACKInteger(out, 4, 0x00, idx);
        } else {
            // 不索引字面量 + 字面量名字：0000 0000 + 名字字符串
            A2RXPCAppendHPACKInteger(out, 4, 0x00, 0);
            if (!A2RXPCAppendHPACKString(out, name, reason)) {
                return nil;
            }
        }
        if (!A2RXPCAppendHPACKString(out, value, reason)) {
            return nil;
        }
    }
    return out;
}

NSArray<NSArray<NSString *> *> *A2RXPCDecodeHeaderBlock(NSData *block, NSString **reason) {
    if (reason) {
        *reason = nil;
    }
    NSMutableArray<NSArray<NSString *> *> *out = [NSMutableArray array];
    NSArray<NSArray<NSString *> *> *t = A2RXPCStaticTable();
    NSUInteger off = 0;
    while (off < block.length) {
        const uint8_t *p = (const uint8_t *)block.bytes;
        uint8_t first = p[off];
        if (first & 0x80) {
            // 索引头字段
            NSUInteger idx = 0;
            NSUInteger next = 0;
            if (!A2RXPCReadHPACKInteger(block, off, 7, &idx, &next, reason)) {
                return nil;
            }
            if (idx == 0 || idx >= t.count) {
                if (reason) {
                    *reason = [NSString stringWithFormat:
                               @"索引头字段指向动态表或不存在的索引 %lu（★本仓不做动态表★）",
                               (unsigned long)idx];
                }
                return nil;
            }
            [out addObject:@[ t[idx][0], t[idx][1] ]];
            off = next;
            continue;
        }
        if ((first & 0xE0) == 0x20) {
            // 动态表尺寸更新：校验并跳过
            NSUInteger sz = 0;
            NSUInteger next = 0;
            if (!A2RXPCReadHPACKInteger(block, off, 5, &sz, &next, reason)) {
                return nil;
            }
            off = next;
            continue;
        }
        BOOL indexed = (first & 0xC0) == 0x40;      // 增量索引
        BOOL never   = (first & 0xF0) == 0x10;      // 永不索引
        NSUInteger prefixBits = indexed ? 6 : 4;
        NSUInteger idx = 0;
        NSUInteger next = 0;
        if (!A2RXPCReadHPACKInteger(block, off, (uint8_t)prefixBits, &idx, &next, reason)) {
            return nil;
        }
        (void)never;
        NSString *name = nil;
        if (idx == 0) {
            if (!A2RXPCReadHPACKString(block, next, &name, &next, reason)) {
                return nil;
            }
        } else if (idx < t.count) {
            if (idx == 0) {
                if (reason) {
                    *reason = @"头字段名索引 0 非法";
                }
                return nil;
            }
            name = t[idx][0];
        } else {
            if (reason) {
                *reason = [NSString stringWithFormat:
                           @"头字段名索引 %lu 落在动态表（★本仓不做动态表★）", (unsigned long)idx];
            }
            return nil;
        }
        NSString *value = nil;
        if (!A2RXPCReadHPACKString(block, next, &value, &next, reason)) {
            return nil;
        }
        [out addObject:@[ name, value ]];
        off = next;
        if (indexed) {
            // ★本仓不做动态表★：增量索引块仍能解，但索引后续引用会失败。
            // 这里只如实跳过，不做插入 —— 与上面「动态表索引报错」口径一致。
        }
    }
    return out;
}

#pragma mark - XPC 消息

@implementation A2RXPCXPCMessage
- (instancetype)init {
    self = [super init];
    if (self) {
        _body = [NSData data];
    }
    return self;
}
@end

NSData *A2RXPCEncodeXPCMessage(A2RXPCXPCMessage *message, NSString **reason) {
    if (reason) {
        *reason = nil;
    }
    if (message == nil) {
        if (reason) {
            *reason = @"XPC 消息为 nil";
        }
        return nil;
    }
    NSMutableData *out = [NSMutableData dataWithCapacity:A2RXPC_XPC_MESSAGE_HEADER_BYTES + message.body.length];
    A2RXPCAppendLE32(out, A2RXPC_XPC_MESSAGE_MAGIC);
    A2RXPCAppendLE32(out, message.flags);
    A2RXPCAppendLE64(out, (uint64_t)message.body.length);
    A2RXPCAppendLE64(out, message.messageID);
    [out appendData:message.body];
    return out;
}

BOOL A2RXPCDecodeXPCMessage(NSData *buffer,
                            NSUInteger *consumedOut,
                            A2RXPCXPCMessage **messageOut,
                            NSString **reasonOut) {
    if (reasonOut) {
        *reasonOut = nil;
    }
    if (buffer.length < A2RXPC_XPC_MESSAGE_HEADER_BYTES) {
        return NO;
    }
    uint32_t magic = 0;
    uint32_t flags = 0;
    uint64_t bodyLen = 0;
    uint64_t msgID = 0;
    A2RXPCReadLE32(buffer, 0, &magic);
    A2RXPCReadLE32(buffer, 4, &flags);
    A2RXPCReadLE64(buffer, 8, &bodyLen);
    A2RXPCReadLE64(buffer, 16, &msgID);
    if (magic != A2RXPC_XPC_MESSAGE_MAGIC) {
        if (reasonOut) {
            *reasonOut = [NSString stringWithFormat:
                          @"XPC 消息 magic 不符（0x%08X，期望 0x%08X）", magic, A2RXPC_XPC_MESSAGE_MAGIC];
        }
        return NO;
    }
    if (bodyLen > (uint64_t)(buffer.length)) {      // 明显越界先挡掉，避免溢出
        if (buffer.length < A2RXPC_XPC_MESSAGE_HEADER_BYTES + (NSUInteger)bodyLen) {
            return NO;
        }
    }
    if (bodyLen > (uint64_t)(buffer.length - A2RXPC_XPC_MESSAGE_HEADER_BYTES)) {
        return NO;                                  // 体还没收全
    }
    A2RXPCXPCMessage *m = [[A2RXPCXPCMessage alloc] init];
    m.flags = flags;
    m.messageID = msgID;
    m.body = bodyLen > 0
        ? [buffer subdataWithRange:NSMakeRange(A2RXPC_XPC_MESSAGE_HEADER_BYTES, (NSUInteger)bodyLen)]
        : [NSData data];
    if (consumedOut) {
        *consumedOut = A2RXPC_XPC_MESSAGE_HEADER_BYTES + (NSUInteger)bodyLen;
    }
    if (messageOut) {
        *messageOut = m;
    }
    return YES;
}

#pragma mark - XPC 对象

NSString *A2RXPCObjectTypeName(A2RXPCObjectType type) {
    switch (type) {
        case A2RXPCObjectTypeNull:       return @"Null";
        case A2RXPCObjectTypeBool:       return @"Bool";
        case A2RXPCObjectTypeInt64:      return @"Int64";
        case A2RXPCObjectTypeUInt64:     return @"UInt64";
        case A2RXPCObjectTypeDouble:     return @"Double";
        case A2RXPCObjectTypeDate:       return @"Date";
        case A2RXPCObjectTypeData:       return @"Data";
        case A2RXPCObjectTypeString:     return @"String";
        case A2RXPCObjectTypeUUID:       return @"UUID";
        case A2RXPCObjectTypeDictionary: return @"Dictionary";
        case A2RXPCObjectTypeArray:      return @"Array";
    }
    return [NSString stringWithFormat:@"Unknown(0x%08X)", (unsigned)type];
}

static const NSUInteger A2RXPCXPCValueMaxDepth = 32;

static BOOL A2RXPCHasType(NSNumber *n, const char *enc) {
    return n != nil && strcmp(n.objCType, enc) == 0;
}

/// 递归编码一个值到 out（不含 magic/version 前缀）。
static BOOL A2RXPCEncodeValueInto(NSMutableData *out, id value, NSUInteger depth, NSString **reason) {
    if (depth > A2RXPCXPCValueMaxDepth) {
        if (reason) {
            *reason = @"XPC 值嵌套过深";
        }
        return NO;
    }
    if (value == nil || [value isKindOfClass:[NSNull class]]) {
        A2RXPCAppendLE32(out, A2RXPCObjectTypeNull);
        return YES;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *n = (NSNumber *)value;
        CFTypeID tid = CFGetTypeID((__bridge CFTypeRef)n);
        if (tid == CFBooleanGetTypeID()) {
            A2RXPCAppendLE32(out, A2RXPCObjectTypeBool);
            A2RXPCAppendLE32(out, n.boolValue ? 1u : 0u);
            return YES;
        }
        if (A2RXPCHasType(n, @encode(double)) || A2RXPCHasType(n, @encode(float))) {
            A2RXPCAppendLE32(out, A2RXPCObjectTypeDouble);
            double d = n.doubleValue;
            uint64_t bits = 0;
            memcpy(&bits, &d, sizeof(bits));
            A2RXPCAppendLE64(out, bits);
            return YES;
        }
        if (n.doubleValue < 0) {
            A2RXPCAppendLE32(out, A2RXPCObjectTypeInt64);
            A2RXPCAppendLE64(out, (uint64_t)(int64_t)n.longLongValue);
            return YES;
        }
        A2RXPCAppendLE32(out, A2RXPCObjectTypeUInt64);
        A2RXPCAppendLE64(out, (uint64_t)n.unsignedLongLongValue);
        return YES;
    }
    if ([value isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)value;
        A2RXPCAppendLE32(out, A2RXPCObjectTypeData);
        A2RXPCAppendLE32(out, (uint32_t)d.length);
        if (d.length > 0) {
            [out appendData:d];
        }
        A2RXPCPadTo4(out);
        return YES;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)value;
        NSData *utf8 = [s dataUsingEncoding:NSUTF8StringEncoding];
        if (utf8 == nil) {
            if (reason) {
                *reason = @"XPC 字符串不是合法 UTF-8";
            }
            return NO;
        }
        A2RXPCAppendLE32(out, A2RXPCObjectTypeString);
        A2RXPCAppendLE32(out, (uint32_t)(utf8.length + 1));     // 含结尾 NUL
        if (utf8.length > 0) {
            [out appendData:utf8];
        }
        uint8_t nul = 0;
        [out appendBytes:&nul length:1];
        A2RXPCPadTo4(out);
        return YES;
    }
    if ([value isKindOfClass:[NSUUID class]]) {
        uuid_t uuid;
        [(NSUUID *)value getUUIDBytes:uuid];
        A2RXPCAppendLE32(out, A2RXPCObjectTypeUUID);
        [out appendBytes:uuid length:sizeof(uuid_t)];
        return YES;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)value;
        A2RXPCAppendLE32(out, A2RXPCObjectTypeArray);
        A2RXPCAppendLE32(out, (uint32_t)arr.count);
        for (id elem in arr) {
            if (!A2RXPCEncodeValueInto(out, elem, depth + 1, reason)) {
                return NO;
            }
        }
        return YES;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)value;
        A2RXPCAppendLE32(out, A2RXPCObjectTypeDictionary);
        A2RXPCAppendLE32(out, (uint32_t)dict.count);
        for (id key in dict) {
            if (![key isKindOfClass:[NSString class]]) {
                if (reason) {
                    *reason = @"XPC 字典的键必须是字符串";
                }
                return NO;
            }
            if (!A2RXPCEncodeValueInto(out, (NSString *)key, depth + 1, reason)) {
                return NO;
            }
            if (!A2RXPCEncodeValueInto(out, dict[key], depth + 1, reason)) {
                return NO;
            }
        }
        return YES;
    }
    if (reason) {
        *reason = [NSString stringWithFormat:@"不支持的 XPC 值类型：%@",
                   NSStringFromClass([value class])];
    }
    return NO;
}

NSData *A2RXPCEncodeXPCValue(id value, NSString **reason) {
    if (reason) {
        *reason = nil;
    }
    NSMutableData *out = [NSMutableData data];
    A2RXPCAppendLE32(out, A2RXPC_XPC_OBJECT_MAGIC);
    A2RXPCAppendLE32(out, A2RXPC_XPC_OBJECT_VERSION);
    if (!A2RXPCEncodeValueInto(out, value, 0, reason)) {
        return nil;
    }
    return out;
}

/// 跳过一个值后 4 字节对齐。
static NSUInteger A2RXPCPadSkip(NSUInteger len) {
    NSUInteger rem = len % 4;
    return rem == 0 ? 0 : (4 - rem);
}

static BOOL A2RXPCDecodeValueAt(NSData *blob, NSUInteger off, NSUInteger depth,
                                id *valueOut, NSUInteger *nextOff, NSString **reason,
                                BOOL *insufficient) {
    if (insufficient) {
        *insufficient = NO;
    }
    if (depth > A2RXPCXPCValueMaxDepth) {
        if (reason) {
            *reason = @"XPC 值嵌套过深";
        }
        return NO;
    }
    uint32_t type = 0;
    if (!A2RXPCReadLE32(blob, off, &type)) {
        if (insufficient) {
            *insufficient = YES;
        }
        return NO;
    }
    NSUInteger p = off + 4;
    switch ((A2RXPCObjectType)type) {
        case A2RXPCObjectTypeNull: {
            *valueOut = [NSNull null];
            *nextOff = p;
            return YES;
        }
        case A2RXPCObjectTypeBool: {
            uint32_t v = 0;
            if (!A2RXPCReadLE32(blob, p, &v)) { if (insufficient) { *insufficient = YES; } return NO; }
            *valueOut = @(v != 0);
            *nextOff = p + 4;
            return YES;
        }
        case A2RXPCObjectTypeInt64: {
            uint64_t v = 0;
            if (!A2RXPCReadLE64(blob, p, &v)) { if (insufficient) { *insufficient = YES; } return NO; }
            *valueOut = @((int64_t)v);
            *nextOff = p + 8;
            return YES;
        }
        case A2RXPCObjectTypeUInt64: {
            uint64_t v = 0;
            if (!A2RXPCReadLE64(blob, p, &v)) { if (insufficient) { *insufficient = YES; } return NO; }
            *valueOut = @(v);
            *nextOff = p + 8;
            return YES;
        }
        case A2RXPCObjectTypeDouble: {
            uint64_t bits = 0;
            if (!A2RXPCReadLE64(blob, p, &bits)) { if (insufficient) { *insufficient = YES; } return NO; }
            double d = 0;
            memcpy(&d, &bits, sizeof(d));
            *valueOut = @(d);
            *nextOff = p + 8;
            return YES;
        }
        case A2RXPCObjectTypeDate: {
            uint64_t bits = 0;
            if (!A2RXPCReadLE64(blob, p, &bits)) { if (insufficient) { *insufficient = YES; } return NO; }
            *valueOut = @(bits);            // 纳秒；调用方按需转换
            *nextOff = p + 8;
            return YES;
        }
        case A2RXPCObjectTypeData: {
            uint32_t len = 0;
            if (!A2RXPCReadLE32(blob, p, &len)) { if (insufficient) { *insufficient = YES; } return NO; }
            if (p + 4 + len > blob.length) { if (insufficient) { *insufficient = YES; } return NO; }
            *valueOut = len > 0 ? [blob subdataWithRange:NSMakeRange(p + 4, len)] : [NSData data];
            *nextOff = p + 4 + len + A2RXPCPadSkip(len);
            return YES;
        }
        case A2RXPCObjectTypeString: {
            uint32_t len = 0;
            if (!A2RXPCReadLE32(blob, p, &len)) { if (insufficient) { *insufficient = YES; } return NO; }
            if (len == 0) {
                if (reason) {
                    *reason = @"XPC 字符串长度 0（应含结尾 NUL ⇒ 至少 1）";
                }
                return NO;
            }
            if (p + 4 + len > blob.length) { if (insufficient) { *insufficient = YES; } return NO; }
            NSData *raw = [blob subdataWithRange:NSMakeRange(p + 4, len - 1)];
            NSString *s = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
            if (s == nil) {
                if (reason) {
                    *reason = @"XPC 字符串不是合法 UTF-8";
                }
                return NO;
            }
            *valueOut = s;
            *nextOff = p + 4 + len + A2RXPCPadSkip(len);
            return YES;
        }
        case A2RXPCObjectTypeUUID: {
            if (p + 16 > blob.length) { if (insufficient) { *insufficient = YES; } return NO; }
            uuid_t uuid;
            [blob getBytes:uuid range:NSMakeRange(p, 16)];
            *valueOut = [[NSUUID alloc] initWithUUIDBytes:uuid];
            *nextOff = p + 16;
            return YES;
        }
        case A2RXPCObjectTypeArray: {
            uint32_t count = 0;
            if (!A2RXPCReadLE32(blob, p, &count)) { if (insufficient) { *insufficient = YES; } return NO; }
            NSMutableArray *arr = [NSMutableArray arrayWithCapacity:count];
            NSUInteger cur = p + 4;
            for (uint32_t i = 0; i < count; i++) {
                id elem = nil;
                BOOL insuf = NO;
                if (!A2RXPCDecodeValueAt(blob, cur, depth + 1, &elem, &cur, reason, &insuf)) {
                    if (insuf && insufficient) {
                        *insufficient = YES;
                    }
                    return NO;
                }
                [arr addObject:elem];
            }
            *valueOut = arr;
            *nextOff = cur;
            return YES;
        }
        case A2RXPCObjectTypeDictionary: {
            uint32_t count = 0;
            if (!A2RXPCReadLE32(blob, p, &count)) { if (insufficient) { *insufficient = YES; } return NO; }
            NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:count];
            NSUInteger cur = p + 4;
            for (uint32_t i = 0; i < count; i++) {
                id key = nil;
                BOOL insuf = NO;
                if (!A2RXPCDecodeValueAt(blob, cur, depth + 1, &key, &cur, reason, &insuf)) {
                    if (insuf && insufficient) {
                        *insufficient = YES;
                    }
                    return NO;
                }
                if (![key isKindOfClass:[NSString class]]) {
                    if (reason) {
                        *reason = @"XPC 字典的键不是字符串";
                    }
                    return NO;
                }
                id val = nil;
                if (!A2RXPCDecodeValueAt(blob, cur, depth + 1, &val, &cur, reason, &insuf)) {
                    if (insuf && insufficient) {
                        *insufficient = YES;
                    }
                    return NO;
                }
                dict[key] = val;
            }
            *valueOut = dict;
            *nextOff = cur;
            return YES;
        }
    }
    if (reason) {
        *reason = [NSString stringWithFormat:@"未知 XPC 对象类型号 0x%08X", type];
    }
    return NO;
}

id A2RXPCDecodeXPCValue(NSData *blob, NSUInteger *consumedOut, NSString **reason) {
    if (reason) {
        *reason = nil;
    }
    uint32_t magic = 0;
    uint32_t version = 0;
    if (!A2RXPCReadLE32(blob, 0, &magic) || !A2RXPCReadLE32(blob, 4, &version)) {
        return nil;                                 // 不够（reason 保持 nil）
    }
    if (magic != A2RXPC_XPC_OBJECT_MAGIC) {
        if (reason) {
            *reason = [NSString stringWithFormat:
                       @"XPC 对象 magic 不符（0x%08X，期望 0x%08X）", magic, A2RXPC_XPC_OBJECT_MAGIC];
        }
        return nil;
    }
    if (version != A2RXPC_XPC_OBJECT_VERSION) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"XPC 对象版本不是 5（实为 %u）", version];
        }
        return nil;
    }
    id value = nil;
    NSUInteger next = 0;
    BOOL insufficient = NO;
    if (!A2RXPCDecodeValueAt(blob, 8, 0, &value, &next, reason, &insufficient)) {
        if (insufficient) {
            *reason = nil;                          // 归一：nil = 不够
        }
        return nil;
    }
    if (consumedOut) {
        *consumedOut = next;
    }
    return value;
}
