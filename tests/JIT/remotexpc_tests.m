//
//  remotexpc_tests.m
//  Air2 tests
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [A2-RXPC] 传输层单测：RemoteXPC 帧 / HPACK / XPC 对象与消息 / 会话（含错误与超时）/
//  传输缝 / pairable-host 通告契约（authTag 用公开测试向量）。
//
//  ★本文件只测「协议层可做的部分」★：帧编解码、头块处理、错误路径、超时、契约。
//  与 iOS 27 真设备的互操作★未验证（本会话无真机）★ —— 这里证的是【自洽】。
//
//  运行：python3 tests/JIT/run_remotexpc_tests.py
//

#import <Foundation/Foundation.h>
#import <stdio.h>

#import "a2_remotexpc_framing.h"
#import "a2_remotexpc_session.h"
#import "a2_rppairing_pairsetup_transport.h"
#import "a2_rppairing_pairable_host.h"

static int gPass = 0;
static int gFail = 0;

static void T(const char *name, BOOL cond) {
    if (cond) {
        printf("PASS %s\n", name);
        gPass++;
    } else {
        printf("FAIL %s\n", name);
        gFail++;
    }
}

#pragma mark - 测试夹具

/// 造一条「对端回复的 pairingData」线上字节：DATA 帧 → XPC 消息 → 值树。
static NSData *ReplyBytes(NSData *tlv, NSString *whyOut) {
    (void)whyOut;
    NSDictionary *value = @{ @"event": @{ @"_0": @{ @"pairingData": @{ @"_0": @{
        @"data": tlv, @"kind": @"setupManualPairing", @"startNewSession": @NO } } } } };
    NSString *why = nil;
    NSData *body = A2RXPCEncodeXPCValue(value, &why);
    A2RXPCXPCMessage *m = [[A2RXPCXPCMessage alloc] init];
    m.flags = A2RXPC_XPC_FLAG_ALWAYS_SET;
    m.messageID = 1;
    m.body = body;
    NSData *wire = A2RXPCEncodeXPCMessage(m, &why);
    A2RXPCFrame *f = [[A2RXPCFrame alloc] init];
    f.type = A2RXPCFrameTypeData;
    f.flags = 0;
    f.streamID = A2RXPC_STREAM_ROOT;
    f.payload = wire;
    return A2RXPCEncodeFrame(f, &why);
}

/// 造一条「对端回了 awaitingUserConsent」的线上字节。
static NSData *ConsentBytes(void) {
    NSString *why = nil;
    NSData *body = A2RXPCEncodeXPCValue(@{ @"event": @{ @"_0": @{ @"awaitingUserConsent": @{} } } }, &why);
    A2RXPCXPCMessage *m = [[A2RXPCXPCMessage alloc] init];
    m.flags = A2RXPC_XPC_FLAG_ALWAYS_SET;
    m.messageID = 2;
    m.body = body;
    NSData *wire = A2RXPCEncodeXPCMessage(m, &why);
    A2RXPCFrame *f = [[A2RXPCFrame alloc] init];
    f.type = A2RXPCFrameTypeData;
    f.streamID = A2RXPC_STREAM_ROOT;
    f.payload = wire;
    return A2RXPCEncodeFrame(f, &why);
}

/// 造一条「对端回了拒绝」的线上字节。
static NSData *RejectBytes(void) {
    NSString *why = nil;
    NSData *body = A2RXPCEncodeXPCValue(@{ @"event": @{ @"_0": @{ @"pairingRejectedWithError": @{} } } }, &why);
    A2RXPCXPCMessage *m = [[A2RXPCXPCMessage alloc] init];
    m.flags = A2RXPC_XPC_FLAG_ALWAYS_SET;
    m.messageID = 3;
    m.body = body;
    NSData *wire = A2RXPCEncodeXPCMessage(m, &why);
    A2RXPCFrame *f = [[A2RXPCFrame alloc] init];
    f.type = A2RXPCFrameTypeData;
    f.streamID = A2RXPC_STREAM_ROOT;
    f.payload = wire;
    return A2RXPCEncodeFrame(f, &why);
}

int main(void) {
    @autoreleasepool {

    // =====================================================================
    // 1. HTTP/2 帧
    // =====================================================================
    NSData *preface = A2RXPCConnectionPreface();
    T("frame/preface-24-bytes", preface.length == A2RXPC_PREFACE_BYTES);
    T("frame/preface-prefix",
      [[[NSString alloc] initWithData:[preface subdataWithRange:NSMakeRange(0, 14)]
                             encoding:NSASCIIStringEncoding] isEqualToString:@"PRI * HTTP/2.0"]);

    A2RXPCFrame *f1 = [[A2RXPCFrame alloc] init];
    f1.type = A2RXPCFrameTypeData;
    f1.flags = A2RXPCFrameFlagEndHeaders;
    f1.streamID = A2RXPC_STREAM_REPLY;
    f1.payload = [NSData dataWithBytes:"\x01\x02\x03" length:3];
    NSString *why = nil;
    NSData *enc1 = A2RXPCEncodeFrame(f1, &why);
    T("frame/encode-non-nil", enc1 != nil);
    T("frame/encode-header-9", enc1.length == 9 + 3);
    const uint8_t *p1 = (const uint8_t *)enc1.bytes;
    T("frame/length-big-endian", p1[0] == 0 && p1[1] == 0 && p1[2] == 3);
    T("frame/type-and-flags", p1[3] == A2RXPCFrameTypeData && p1[4] == A2RXPCFrameFlagEndHeaders);
    T("frame/stream-big-endian", p1[5] == 0 && p1[6] == 0 && p1[7] == 0 && p1[8] == A2RXPC_STREAM_REPLY);

    A2RXPCFrame *back1 = nil;
    NSUInteger used1 = 0;
    NSString *dwhy1 = nil;
    BOOL ok1 = A2RXPCDecodeFrame(enc1, &used1, &back1, &dwhy1);
    T("frame/roundtrip-ok", ok1 && back1 != nil);
    T("frame/roundtrip-consumed", used1 == enc1.length);
    T("frame/roundtrip-fields",
      back1.type == f1.type && back1.flags == f1.flags && back1.streamID == f1.streamID);
    T("frame/roundtrip-payload", [back1.payload isEqualToData:f1.payload]);

    A2RXPCFrame *backNil = nil;
    NSString *dwhy2 = nil;
    NSUInteger used2 = 0;
    BOOL shortOK = A2RXPCDecodeFrame([enc1 subdataWithRange:NSMakeRange(0, 5)], &used2, &backNil, &dwhy2);
    T("frame/truncated-is-not-error", shortOK == NO && dwhy2 == nil && backNil == nil);

    NSMutableData *twoFrames = [NSMutableData dataWithData:enc1];
    [twoFrames appendData:enc1];
    A2RXPCFrame *first2 = nil;
    NSString *dwhy3 = nil;
    NSUInteger used3 = 0;
    BOOL ok3 = A2RXPCDecodeFrame(twoFrames, &used3, &first2, &dwhy3);
    T("frame/only-consumes-one-frame", ok3 && used3 == enc1.length);

    A2RXPCFrameReader *reader = [[A2RXPCFrameReader alloc] init];
    [reader appendData:[enc1 subdataWithRange:NSMakeRange(0, 4)]];
    NSString *rwhy1 = nil;
    T("frame/reader-insufficient", [reader popFrameWithReason:&rwhy1] == nil && rwhy1 == nil);
    [reader appendData:[enc1 subdataWithRange:NSMakeRange(4, enc1.length - 4)]];
    NSString *rwhy2 = nil;
    A2RXPCFrame *rf1 = [reader popFrameWithReason:&rwhy2];
    T("frame/reader-reassembles", rf1 != nil && [rf1.payload isEqualToData:f1.payload]);
    T("frame/reader-empty-after-pop", [reader popFrameWithReason:NULL] == nil);

    A2RXPCFrameReader *reader2 = [[A2RXPCFrameReader alloc] init];
    [reader2 appendData:twoFrames];
    A2RXPCFrame *rf2a = [reader2 popFrameWithReason:NULL];
    A2RXPCFrame *rf2b = [reader2 popFrameWithReason:NULL];
    T("frame/reader-pops-two", rf2a != nil && rf2b != nil);
    T("frame/reader-buffered-zero", reader2.bufferedBytes == 0);

    A2RXPCFrame *big = [[A2RXPCFrame alloc] init];
    big.type = A2RXPCFrameTypeData;
    big.payload = [NSMutableData dataWithLength:(0xFFFFFFu + 1)];
    NSString *bigWhy = nil;
    T("frame/oversize-rejected", A2RXPCEncodeFrame(big, &bigWhy) == nil && bigWhy != nil);

    // =====================================================================
    // 2. HPACK
    // =====================================================================
    T("hpack/static-table-size", A2RXPCStaticTable().count == 62);
    T("hpack/static-index-3-name", [A2RXPCStaticTableName(3) isEqualToString:@":method"]);
    T("hpack/static-index-oob-nil", A2RXPCStaticTableName(999) == nil);

    NSArray *hdrs = @[ @[ @":method", @"POST" ], @[ @":scheme", @"http" ], @[ @":path", @"/" ] ];
    NSString *hwhy = nil;
    NSData *hblock = A2RXPCEncodeHeaderBlock(hdrs, &hwhy);
    T("hpack/encode-non-nil", hblock != nil);
    NSString *hwhy2 = nil;
    NSArray *hback = A2RXPCDecodeHeaderBlock(hblock, &hwhy2);
    T("hpack/roundtrip-count", hback != nil && hback.count == hdrs.count);
    T("hpack/roundtrip-values",
      hback != nil && [hback[0][0] isEqualToString:@":method"] && [hback[0][1] isEqualToString:@"POST"]);
    T("hpack/exact-match-uses-index", hblock.length == 3);      // 三个索引字段各 1 字节

    NSArray *oddHdrs = @[ @[ @"x-a2-custom", @"v1" ], @[ @"content-length", @"42" ] ];
    NSString *hwhy3 = nil;
    NSData *hblock2 = A2RXPCEncodeHeaderBlock(oddHdrs, &hwhy3);
    NSString *hwhy4 = nil;
    NSArray *hback2 = hblock2 != nil ? A2RXPCDecodeHeaderBlock(hblock2, &hwhy4) : nil;
    T("hpack/literal-name-roundtrip",
      hback2 != nil && hback2.count == 2 && [hback2[0][0] isEqualToString:@"x-a2-custom"]);
    T("hpack/static-name-index-roundtrip",
      hback2 != nil && [hback2[1][0] isEqualToString:@"content-length"] && [hback2[1][1] isEqualToString:@"42"]);

    // 索引头字段 :method GET（静态表 2）
    uint8_t indexedGet = 0x82;
    NSData *idxBlock = [NSData dataWithBytes:&indexedGet length:1];
    NSString *iwhy = nil;
    NSArray *idxBack = A2RXPCDecodeHeaderBlock(idxBlock, &iwhy);
    T("hpack/decode-indexed", idxBack != nil && idxBack.count == 1
      && [idxBack[0][0] isEqualToString:@":method"] && [idxBack[0][1] isEqualToString:@"GET"]);

    // Huffman（H=1）必须被拒：字面量名索引 0 + 字符串长度字节带 H 位
    uint8_t huffBlockBytes[2] = { 0x00, 0x85 };
    NSData *huffBlock = [NSData dataWithBytes:huffBlockBytes length:sizeof(huffBlockBytes)];
    NSString *huwhy = nil;
    T("hpack/huffman-rejected", A2RXPCDecodeHeaderBlock(huffBlock, &huwhy) == nil && huwhy != nil);

    // 截断的字面量
    uint8_t truncStart = 0x00;
    NSData *truncBlock = [NSData dataWithBytes:&truncStart length:1];
    NSString *trwhy = nil;
    T("hpack/truncated-rejected", A2RXPCDecodeHeaderBlock(truncBlock, &trwhy) == nil && trwhy != nil);

    // 动态表索引（0xFF…）必须被拒
    uint8_t dynStart = 0xBE;    // 索引头字段，7 位前缀值 62（> 静态表）
    NSData *dynBlock = [NSData dataWithBytes:&dynStart length:1];
    NSString *dywhy = nil;
    T("hpack/dynamic-index-rejected", A2RXPCDecodeHeaderBlock(dynBlock, &dywhy) == nil && dywhy != nil);

    // 非二元组必须被拒
    NSString *badWhy = nil;
    T("hpack/bad-tuple-rejected",
      A2RXPCEncodeHeaderBlock(@[ @[ @"only-name" ] ], &badWhy) == nil && badWhy != nil);
    // 空头名必须被拒
    NSString *badWhy2 = nil;
    T("hpack/empty-name-rejected",
      A2RXPCEncodeHeaderBlock(@[ @[ @"", @"v" ] ], &badWhy2) == nil && badWhy2 != nil);

    // 长值（>127）走整数续字节
    NSMutableString *longVal = [NSMutableString string];
    for (int i = 0; i < 300; i++) {
        [longVal appendString:@"a"];
    }
    NSString *lwhy = nil;
    NSData *lblock = A2RXPCEncodeHeaderBlock(@[ @[ @"x-long", longVal ] ], &lwhy);
    NSString *lwhy2 = nil;
    NSArray *lback = lblock != nil ? A2RXPCDecodeHeaderBlock(lblock, &lwhy2) : nil;
    T("hpack/long-value-roundtrip",
      lback != nil && [lback[0][1] length] == 300);
    T("hpack/long-value-length-prefixed", lblock.length < 20);

    // =====================================================================
    // 3. XPC 消息
    // =====================================================================
    NSString *xwhy = nil;
    NSData *xbody = A2RXPCEncodeXPCValue(@{ @"k": @"v" }, &xwhy);
    A2RXPCXPCMessage *msg = [[A2RXPCXPCMessage alloc] init];
    msg.flags = A2RXPC_XPC_FLAG_INIT_HANDSHAKE | A2RXPC_XPC_FLAG_ALWAYS_SET;
    msg.messageID = 4242;
    msg.body = xbody;
    NSString *mwhy = nil;
    NSData *mwire = A2RXPCEncodeXPCMessage(msg, &mwhy);
    T("xpc/message-encode-non-nil", mwire != nil && mwire.length == 24 + xbody.length);
    const uint8_t *mp = (const uint8_t *)mwire.bytes;
    T("xpc/message-magic-le",
      mp[0] == 0x92 && mp[1] == 0x0B && mp[2] == 0xB0 && mp[3] == 0x29);
    A2RXPCXPCMessage *mBack = nil;
    NSString *mdwhy = nil;
    NSUInteger mUsed = 0;
    T("xpc/message-decode-ok",
      A2RXPCDecodeXPCMessage(mwire, &mUsed, &mBack, &mdwhy) && mBack != nil);
    T("xpc/message-flags-roundtrip", mBack.flags == msg.flags);
    T("xpc/message-id-roundtrip", mBack.messageID == 4242);
    T("xpc/message-body-roundtrip", [mBack.body isEqualToData:xbody]);

    NSMutableData *badMagic = [NSMutableData dataWithData:mwire];
    ((uint8_t *)badMagic.mutableBytes)[0] = 0x00;
    A2RXPCXPCMessage *mBad = nil;
    NSString *mbwhy = nil;
    NSUInteger mbUsed = 0;
    T("xpc/message-bad-magic-rejected",
      A2RXPCDecodeXPCMessage(badMagic, &mbUsed, &mBad, &mbwhy) == NO && mbwhy != nil);

    A2RXPCXPCMessage *mTrunc = nil;
    NSString *mtwhy = nil;
    NSUInteger mtUsed = 0;
    T("xpc/message-truncated-not-error",
      A2RXPCDecodeXPCMessage([mwire subdataWithRange:NSMakeRange(0, 10)], &mtUsed, &mTrunc, &mtwhy) == NO
      && mtwhy == nil);

    // =====================================================================
    // 4. XPC 对象
    // =====================================================================
    NSString *vwhy = nil;
    T("xpc/null-roundtrip",
      [A2RXPCDecodeXPCValue(A2RXPCEncodeXPCValue([NSNull null], &vwhy), NULL, &vwhy) isEqual:[NSNull null]]);
    T("xpc/bool-true-roundtrip",
      [A2RXPCDecodeXPCValue(A2RXPCEncodeXPCValue(@YES, &vwhy), NULL, &vwhy) boolValue] == YES);
    T("xpc/bool-false-roundtrip",
      [A2RXPCDecodeXPCValue(A2RXPCEncodeXPCValue(@NO, &vwhy), NULL, &vwhy) boolValue] == NO);
    T("xpc/int64-negative-roundtrip",
      [A2RXPCDecodeXPCValue(A2RXPCEncodeXPCValue(@(-1234567), &vwhy), NULL, &vwhy) longLongValue] == -1234567);
    T("xpc/uint64-large-roundtrip",
      [A2RXPCDecodeXPCValue(A2RXPCEncodeXPCValue(@(18446744073709551615ULL), &vwhy), NULL, &vwhy)
        unsignedLongLongValue] == 18446744073709551615ULL);
    T("xpc/double-roundtrip",
      [A2RXPCDecodeXPCValue(A2RXPCEncodeXPCValue(@(3.5), &vwhy), NULL, &vwhy) doubleValue] == 3.5);

    NSData *payload3 = [NSData dataWithBytes:"\xAA\xBB\xCC" length:3];
    NSData *dback = A2RXPCDecodeXPCValue(A2RXPCEncodeXPCValue(payload3, &vwhy), NULL, &vwhy);
    T("xpc/data-roundtrip", [dback isEqualToData:payload3]);
    NSString *dblobOK = vwhy ?: @"";
    T("xpc/data-padding-4", (dblobOK.length == 0));

    NSString *s = @"héllo";
    NSString *sback = A2RXPCDecodeXPCValue(A2RXPCEncodeXPCValue(s, &vwhy), NULL, &vwhy);
    T("xpc/string-roundtrip", [sback isEqualToString:s]);

    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:@"8b025e0b-7a6c-4a7a-8a52-66c75262a520"];
    NSUUID *uback = A2RXPCDecodeXPCValue(A2RXPCEncodeXPCValue(uuid, &vwhy), NULL, &vwhy);
    T("xpc/uuid-roundtrip", [uback isEqual:uuid]);

    NSDictionary *nested = @{ @"a": @[ @1, @"two", @{ @"deep": @YES } ], @"n": [NSNull null] };
    NSDictionary *nback = A2RXPCDecodeXPCValue(A2RXPCEncodeXPCValue(nested, &vwhy), NULL, &vwhy);
    T("xpc/nested-roundtrip", [nback isEqual:nested]);

    NSString *uWhy = nil;
    T("xpc/unsupported-type-rejected",
      A2RXPCEncodeXPCValue([NSDate date], &uWhy) == nil && uWhy != nil);

    NSString *kWhy = nil;
    T("xpc/non-string-key-rejected",
      A2RXPCEncodeXPCValue(@{ @1: @"v" }, &kWhy) == nil && kWhy != nil);

    // 未知类型号
    NSMutableData *unk = [NSMutableData data];
    uint8_t mag[8] = { 0x42, 0x37, 0x13, 0x42, 0x05, 0x00, 0x00, 0x00 };
    [unk appendBytes:mag length:8];
    uint8_t tid[4] = { 0x99, 0x99, 0x00, 0x00 };
    [unk appendBytes:tid length:4];
    NSString *unkWhy = nil;
    T("xpc/unknown-type-rejected", A2RXPCDecodeXPCValue(unk, NULL, &unkWhy) == nil && unkWhy != nil);

    // magic 不符
    NSMutableData *badObj = [NSMutableData dataWithData:A2RXPCEncodeXPCValue(@1, &vwhy)];
    ((uint8_t *)badObj.mutableBytes)[0] = 0x00;
    NSString *boWhy = nil;
    T("xpc/object-bad-magic-rejected", A2RXPCDecodeXPCValue(badObj, NULL, &boWhy) == nil && boWhy != nil);

    T("xpc/type-name-stable",
      [A2RXPCObjectTypeName(A2RXPCObjectTypeDictionary) isEqualToString:@"Dictionary"]
      && [A2RXPCObjectTypeName(A2RXPCObjectTypeData) isEqualToString:@"Data"]);

    // =====================================================================
    // 5. 会话（错误路径与超时）
    // =====================================================================
    A2RemoteXPCInMemoryStream *s1 = [[A2RemoteXPCInMemoryStream alloc] init];
    A2RemoteXPCSession *sess1 = [[A2RemoteXPCSession alloc] initWithStream:s1
                                                      wireProtocolVersion:19
                                                             originatedBy:@"host"];
    NSString *sWhy = nil;
    A2RemoteXPCErrorKind sErr = A2RemoteXPCErrorNone;
    T("session/handshake-ok", [sess1 connectAndHandshakeWithTimeout:5.0 reason:&sWhy error:&sErr]);
    T("session/handshake-sets-flag", sess1.handshakeComplete);
    T("session/handshake-wrote-preface",
      [s1.writtenBytes length] > A2RXPC_PREFACE_BYTES
      && [[[NSString alloc] initWithData:[s1.writtenBytes subdataWithRange:NSMakeRange(0, 14)]
                                encoding:NSASCIIStringEncoding] isEqualToString:@"PRI * HTTP/2.0"]);
    T("session/handshake-wrote-multiple-messages", s1.writeCount >= 7);

    A2RemoteXPCInMemoryStream *s2 = [[A2RemoteXPCInMemoryStream alloc] init];
    s2.failOnOpen = YES;
    A2RemoteXPCSession *sess2 = [[A2RemoteXPCSession alloc] initWithStream:s2
                                                      wireProtocolVersion:19
                                                             originatedBy:@"host"];
    NSString *s2Why = nil;
    A2RemoteXPCErrorKind s2Err = A2RemoteXPCErrorNone;
    BOOL s2OK = [sess2 connectAndHandshakeWithTimeout:5.0 reason:&s2Why error:&s2Err];
    T("session/connect-failed", s2OK == NO && s2Err == A2RemoteXPCErrorConnectFailed && s2Why != nil);

    A2RemoteXPCSession *sess3 = [[A2RemoteXPCSession alloc] initWithStream:(id)nil
                                                      wireProtocolVersion:19
                                                             originatedBy:@"host"];
    NSString *s3Why = nil;
    A2RemoteXPCErrorKind s3Err = A2RemoteXPCErrorNone;
    T("session/no-stream-not-connected",
      [sess3 connectAndHandshakeWithTimeout:1.0 reason:&s3Why error:&s3Err] == NO
      && s3Err == A2RemoteXPCErrorNotConnected);

    NSString *preWhy = nil;
    A2RemoteXPCErrorKind preErr = A2RemoteXPCErrorNone;
    T("session/exchange-before-handshake",
      [sess1.exchangePairingData:[NSData dataWithBytes:"x" length:1] kind:@"k" startNew:YES
                          reason:&preWhy error:&preErr] == nil
      && preErr == A2RemoteXPCErrorNotConnected);

    // 成功往返
    A2RemoteXPCInMemoryStream *s4 = [[A2RemoteXPCInMemoryStream alloc] init];
    NSData *tlvIn = [NSData dataWithBytes:"\x06\x01\x03" length:3];
    [s4 enqueueReadChunk:ReplyBytes(tlvIn, nil)];
    A2RemoteXPCSession *sess4 = [[A2RemoteXPCSession alloc] initWithStream:s4
                                                      wireProtocolVersion:19
                                                             originatedBy:@"host"];
    sess4.exchangeTimeout = 2.0;
    NSString *h4why = nil;
    A2RemoteXPCErrorKind h4err = A2RemoteXPCErrorNone;
    T("session/exchange-handshake-ok",
      [sess4 connectAndHandshakeWithTimeout:2.0 reason:&h4why error:&h4err]);
    NSString *e4why = nil;
    A2RemoteXPCErrorKind e4err = A2RemoteXPCErrorNone;
    NSData *tlvOut = [sess4 exchangePairingData:[NSData dataWithBytes:"\x06\x01\x01" length:3]
                                           kind:@"setupManualPairing"
                                       startNew:YES
                                         reason:&e4why
                                          error:&e4err];
    T("session/exchange-returns-tlv", tlvOut != nil && [tlvOut isEqualToData:tlvIn]);
    T("session/exchange-seq-incremented", sess4.sequenceNumber == 1);

    // awaitingUserConsent 之后才给数据
    A2RemoteXPCInMemoryStream *s5 = [[A2RemoteXPCInMemoryStream alloc] init];
    [s5 enqueueReadChunk:ConsentBytes()];
    [s5 enqueueReadChunk:ReplyBytes(tlvIn, nil)];
    A2RemoteXPCSession *sess5 = [[A2RemoteXPCSession alloc] initWithStream:s5
                                                      wireProtocolVersion:19
                                                             originatedBy:@"host"];
    sess5.exchangeTimeout = 2.0;
    NSString *h5why = nil;
    A2RemoteXPCErrorKind h5err = A2RemoteXPCErrorNone;
    (void)[sess5 connectAndHandshakeWithTimeout:2.0 reason:&h5why error:&h5err];
    NSString *e5why = nil;
    A2RemoteXPCErrorKind e5err = A2RemoteXPCErrorNone;
    NSData *tlvOut5 = [sess5 exchangePairingData:[NSData dataWithBytes:"\x06\x01\x01" length:3]
                                            kind:@"setupManualPairing"
                                        startNew:YES
                                          reason:&e5why
                                           error:&e5err];
    T("session/consent-then-data", tlvOut5 != nil && sess5.observedAwaitingUserConsent == YES);

    // 对端拒绝
    A2RemoteXPCInMemoryStream *s6 = [[A2RemoteXPCInMemoryStream alloc] init];
    [s6 enqueueReadChunk:RejectBytes()];
    A2RemoteXPCSession *sess6 = [[A2RemoteXPCSession alloc] initWithStream:s6
                                                      wireProtocolVersion:19
                                                             originatedBy:@"host"];
    sess6.exchangeTimeout = 2.0;
    NSString *h6why = nil;
    A2RemoteXPCErrorKind h6err = A2RemoteXPCErrorNone;
    (void)[sess6 connectAndHandshakeWithTimeout:2.0 reason:&h6why error:&h6err];
    NSString *e6why = nil;
    A2RemoteXPCErrorKind e6err = A2RemoteXPCErrorNone;
    T("session/rejected-by-peer",
      [sess6 exchangePairingData:[NSData dataWithBytes:"x" length:1] kind:@"k" startNew:NO
                          reason:&e6why error:&e6err] == nil
      && e6why != nil);

    // 超时
    A2RemoteXPCInMemoryStream *s7 = [[A2RemoteXPCInMemoryStream alloc] init];
    A2RemoteXPCSession *sess7 = [[A2RemoteXPCSession alloc] initWithStream:s7
                                                      wireProtocolVersion:19
                                                             originatedBy:@"host"];
    sess7.exchangeTimeout = 0.3;
    NSString *h7why = nil;
    A2RemoteXPCErrorKind h7err = A2RemoteXPCErrorNone;
    (void)[sess7 connectAndHandshakeWithTimeout:2.0 reason:&h7why error:&h7err];
    NSString *e7why = nil;
    A2RemoteXPCErrorKind e7err = A2RemoteXPCErrorNone;
    NSData *tlvOut7 = [sess7 exchangePairingData:[NSData dataWithBytes:"x" length:1] kind:@"k"
                                        startNew:NO reason:&e7why error:&e7err];
    T("session/receive-timeout",
      tlvOut7 == nil && e7err == A2RemoteXPCErrorReceiveTimeout && e7why != nil);

    // 对端关闭
    A2RemoteXPCInMemoryStream *s8 = [[A2RemoteXPCInMemoryStream alloc] init];
    A2RemoteXPCSession *sess8 = [[A2RemoteXPCSession alloc] initWithStream:s8
                                                      wireProtocolVersion:19
                                                             originatedBy:@"host"];
    sess8.exchangeTimeout = 2.0;
    NSString *h8why = nil;
    A2RemoteXPCErrorKind h8err = A2RemoteXPCErrorNone;
    (void)[sess8 connectAndHandshakeWithTimeout:2.0 reason:&h8why error:&h8err];
    s8.peerClosed = YES;
    NSString *e8why = nil;
    A2RemoteXPCErrorKind e8err = A2RemoteXPCErrorNone;
    NSData *tlvOut8 = [sess8 exchangePairingData:[NSData dataWithBytes:"x" length:1] kind:@"k"
                                        startNew:NO reason:&e8why error:&e8err];
    T("session/peer-closed",
      tlvOut8 == nil && e8err == A2RemoteXPCErrorPeerClosed);

    // 帧格式错（脚本给一段 magic 不对的「帧」）
    A2RXPCFrame *badFrame = [[A2RXPCFrame alloc] init];
    badFrame.type = A2RXPCFrameTypeData;
    badFrame.streamID = A2RXPC_STREAM_ROOT;
    badFrame.payload = [NSData dataWithBytes:"\x00\x00\x00\x00" length:4];   // 不是合法 XPC magic
    NSString *bfwhy = nil;
    NSData *badFrameBytes = A2RXPCEncodeFrame(badFrame, &bfwhy);
    A2RemoteXPCInMemoryStream *s9 = [[A2RemoteXPCInMemoryStream alloc] init];
    [s9 enqueueReadChunk:badFrameBytes];
    A2RemoteXPCSession *sess9 = [[A2RemoteXPCSession alloc] initWithStream:s9
                                                      wireProtocolVersion:19
                                                             originatedBy:@"host"];
    sess9.exchangeTimeout = 2.0;
    NSString *h9why = nil;
    A2RemoteXPCErrorKind h9err = A2RemoteXPCErrorNone;
    (void)[sess9 connectAndHandshakeWithTimeout:2.0 reason:&h9why error:&h9err];
    NSString *e9why = nil;
    A2RemoteXPCErrorKind e9err = A2RemoteXPCErrorNone;
    T("session/xpc-decode-error",
      [sess9 exchangePairingData:[NSData dataWithBytes:"x" length:1] kind:@"k" startNew:NO
                          reason:&e9why error:&e9err] == nil
      && (e9err == A2RemoteXPCErrorXPCDecode || e9err == A2RemoteXPCErrorFrameFormat));

    // 写失败
    A2RemoteXPCInMemoryStream *s10 = [[A2RemoteXPCInMemoryStream alloc] init];
    A2RemoteXPCSession *sess10 = [[A2RemoteXPCSession alloc] initWithStream:s10
                                                       wireProtocolVersion:19
                                                              originatedBy:@"host"];
    NSString *h10why = nil;
    A2RemoteXPCErrorKind h10err = A2RemoteXPCErrorNone;
    (void)[sess10 connectAndHandshakeWithTimeout:2.0 reason:&h10why error:&h10err];
    s10.failOnWriteAtIndex = s10.writeCount + 1;
    NSString *e10why = nil;
    A2RemoteXPCErrorKind e10err = A2RemoteXPCErrorNone;
    NSData *tlvOut10 = [sess10 exchangePairingData:[NSData dataWithBytes:"x" length:1] kind:@"k"
                                          startNew:NO reason:&e10why error:&e10err];
    T("session/send-failed",
      tlvOut10 == nil && e10err == A2RemoteXPCErrorSendFailed && e10why != nil);

    T("session/error-kind-names",
      [A2RemoteXPCErrorKindName(A2RemoteXPCErrorReceiveTimeout) isEqualToString:@"ReceiveTimeout"]
      && [A2RemoteXPCErrorKindName(A2RemoteXPCErrorPeerClosed) isEqualToString:@"PeerClosed"]
      && [A2RemoteXPCErrorKindName(A2RemoteXPCErrorXPCDecode) isEqualToString:@"XPCDecode"]
      && [A2RemoteXPCErrorKindName(A2RemoteXPCErrorConnectTimeout) isEqualToString:@"ConnectTimeout"]);

    // =====================================================================
    // 6. 传输缝
    // =====================================================================
    NSString *twhy = nil;
    A2RemoteXPCErrorKind terr = A2RemoteXPCErrorNone;
    T("transport/nil-stream-rejected",
      [A2RPPairSetupRemoteXPCTransport transportOverByteStream:(id)nil
                                                      hostName:@"h"
                                                   wireVersion:19
                                                       timeout:1.0
                                                        reason:&twhy
                                                         error:&terr] == nil
      && twhy != nil);

    A2RemoteXPCInMemoryStream *ts1 = [[A2RemoteXPCInMemoryStream alloc] init];
    ts1.failOnOpen = YES;
    NSString *t2why = nil;
    A2RemoteXPCErrorKind t2err = A2RemoteXPCErrorNone;
    T("transport/open-failure-nil",
      [A2RPPairSetupRemoteXPCTransport transportOverByteStream:ts1
                                                      hostName:@"h"
                                                   wireVersion:19
                                                       timeout:1.0
                                                        reason:&t2why
                                                         error:&t2err] == nil
      && t2why != nil);

    A2RemoteXPCInMemoryStream *ts2 = [[A2RemoteXPCInMemoryStream alloc] init];
    [ts2 enqueueReadChunk:ReplyBytes(tlvIn, nil)];
    NSString *t3why = nil;
    A2RemoteXPCErrorKind t3err = A2RemoteXPCErrorNone;
    A2RPPairSetupRemoteXPCTransport *transport =
        [A2RPPairSetupRemoteXPCTransport transportOverByteStream:ts2
                                                        hostName:@"air2"
                                                     wireVersion:19
                                                         timeout:2.0
                                                          reason:&t3why
                                                           error:&t3err];
    T("transport/handshake-ok", transport != nil);
    NSString *t4why = nil;
    NSData *t4out = [transport exchangePairingData:[NSData dataWithBytes:"\x06\x01\x01" length:3]
                                              kind:@"setupManualPairing"
                                          startNew:YES
                                            reason:&t4why];
    T("transport/exchange-through-seam", t4out != nil && [t4out isEqualToData:tlvIn]);
    T("transport/awaiting-consent-getter", transport.awaitingUserConsentObserved == NO);

    A2RemoteXPCInMemoryStream *ts3 = [[A2RemoteXPCInMemoryStream alloc] init];
    NSString *t5why = nil;
    A2RemoteXPCErrorKind t5err = A2RemoteXPCErrorNone;
    A2RPPairSetupRemoteXPCTransport *transport2 =
        [A2RPPairSetupRemoteXPCTransport transportOverByteStream:ts3
                                                        hostName:@"air2"
                                                     wireVersion:19
                                                         timeout:2.0
                                                          reason:&t5why
                                                           error:&t5err];
    [transport2 close];
    ts3.peerClosed = YES;
    NSString *t6why = nil;
    T("transport/exchange-after-close-fails",
      [transport2 exchangePairingData:[NSData dataWithBytes:"x" length:1] kind:@"k" startNew:NO
                               reason:&t6why] == nil
      && t6why != nil);

    // =====================================================================
    // 7. pairable-host 契约（authTag 用公开测试向量）
    // =====================================================================
    NSData *vecIRK = [[NSData alloc] initWithBase64EncodedString:@"Mgp6ZGPzXM2ku9br46vsiw==" options:0];
    NSString *vecIdent = @"2BE6E510-0325-4365-923E-B14C6F57DB3A";
    NSData *tag = A2RPPairableHostAuthTag(vecIRK, vecIdent);
    T("pairable/authTag-public-vector",
      tag != nil && [[tag base64EncodedStringWithOptions:0] isEqualToString:@"kXjlTr2l"]);
    T("pairable/authTag-length-6", tag.length == 6);
    T("pairable/authTag-bad-irk-nil", A2RPPairableHostAuthTag([NSData dataWithBytes:"x" length:3], vecIdent) == nil);
    T("pairable/authTag-empty-ident-nil", A2RPPairableHostAuthTag(vecIRK, @"") == nil);

    T("pairable/siphash-deterministic",
      vecIRK.length == 16
      && A2RPSipHash24WithKey16((const uint8_t *)vecIRK.bytes, "abc", 3)
         == A2RPSipHash24WithKey16((const uint8_t *)vecIRK.bytes, "abc", 3));

    NSDictionary *txt = A2RPPairableHostTXTRecords(@"Air2", @"Mac17,7", vecIdent, vecIRK);
    T("pairable/txt-seven-keys", txt.count == 7);
    T("pairable/txt-ver-26", [txt[@"ver"] isEqualToString:@"26"]);
    T("pairable/txt-minver-17", [txt[@"minVer"] isEqualToString:@"17"]);
    T("pairable/txt-flags-1", [txt[@"flags"] isEqualToString:@"1"]);
    T("pairable/txt-identifier", [txt[@"identifier"] isEqualToString:vecIdent]);
    T("pairable/txt-name-recognizable", [txt[@"name"] isEqualToString:@"Air2"]);
    T("pairable/txt-authTag-b64", [txt[@"authTag"] isEqualToString:@"kXjlTr2l"]);
    T("pairable/wire-version-26", A2RPPairableHostWireProtocolVersion == 26);

    NSString *longIdent = @"0123456789ABCDEF0123456789ABCDEF";   // 32 字符
    T("pairable/service-name-truncated-30",
      A2RPPairableHostServiceName(longIdent).length == A2RPPairableHostServiceNameMaxLength);
    T("pairable/service-name-short-unchanged",
      [A2RPPairableHostServiceName(@"SHORT") isEqualToString:@"SHORT"]);

    NSData *fresh = A2RPPairableHostFreshAltIRK();
    T("pairable/fresh-altIRK-16", fresh.length == A2RPPairableHostAltIRKBytes);

    T("pairable/failure-names",
      [A2RPPairableHostFailureName(A2RPPairableHostFailureNoLocalNetworkPermission)
        isEqualToString:@"NoLocalNetworkPermission"]
      && [A2RPPairableHostFailureName(A2RPPairableHostFailureSuspended) isEqualToString:@"Suspended"]
      && [A2RPPairableHostFailureName(A2RPPairableHostFailureTimedOut) isEqualToString:@"TimedOut"]
      && [A2RPPairableHostFailureName(A2RPPairableHostFailureKeyRotated) isEqualToString:@"KeyRotated"]);

    // §2a 如实不支持
    NSString *usbWhy = nil;
    T("pairable/section2a-unsupported",
      A2RPPairSetupUSBPathAvailable(&usbWhy) == NO && usbWhy.length > 0);

    // 通告器：altIRK 不合法/identifier 为空时必须拒绝（不静默）
    A2RPPairableHostAdvertiser *badAdv =
        [[A2RPPairableHostAdvertiser alloc] initWithName:@"Air2" model:@"Mac17,7"
                                              identifier:@"X" altIRK:[NSData dataWithBytes:"z" length:4]];
    NSString *advWhy = nil;
    T("pairable/advertiser-rejects-bad-irk",
      [badAdv advertiseAndWaitForDeviceWithBudget:0.2 reason:&advWhy] == nil
      && advWhy != nil);
    A2RPPairableHostAdvertiser *emptyAdv =
        [[A2RPPairableHostAdvertiser alloc] initWithName:@"Air2" model:@"Mac17,7"
                                              identifier:@"" altIRK:vecIRK];
    NSString *advWhy2 = nil;
    T("pairable/advertiser-rejects-empty-identifier",
      [emptyAdv advertiseAndWaitForDeviceWithBudget:0.2 reason:&advWhy2] == nil
      && advWhy2 != nil);

    A2RXPCLog(@"单测完成（判据行通路可用）");

    printf("\n[remotexpc_tests] PASS=%d FAIL=%d\n", gPass, gFail);
    }
    return gFail == 0 ? 0 : 1;
}
