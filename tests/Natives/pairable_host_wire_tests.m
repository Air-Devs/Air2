//
//  pairable_host_wire_tests.m
//  Air2 —— tests/Natives：★pairable-host 线上契约（[A2-PAIRPIN]）单测★
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（★直接链接真实实现 Natives/Support/a2_rppairing_pairable_host_wire.m，不是文本镜像★）：
//    ① 帧：`RPPairing` 前导 + 2 字节【大端】长度 + JSON 负载（含边界：空/超长/截断/错 magic）
//    ② 信封：`{"message":{"plain":{"_0":…}},"originatedBy":…,"sequenceNumber":…}`
//    ③ 握手：响应形状 + ★`allowsPinlessPairing=NO`★（这就是「设备该弹输码框」的声明）
//    ④ pairingData 事件：TLV 走 base64 承载，kind/startNewSession 保真
//    ⑤ 判据行：`[A2-PAIRPIN] stage=… txKeys=… firstBytes=… m2=ok|fail reason=…`
//
//  为什么能在 macOS 上跑：被测文件只依赖 Foundation（无 Network.framework、无 socket），
//  所以帧/信封/判据这些**决策**可以真编译真跑。★真机互操作（设备是否真弹码框）不在此证明★。
//
//  运行：python3 tests/Natives/run_pairable_host_wire_tests.py   （需 macOS + clang）
//

#import <Foundation/Foundation.h>

#import "a2_rppairing_pairable_host_wire.h"

static int gPass = 0;
static int gFail = 0;

static void ok(BOOL cond, NSString *what) {
    if (cond) { gPass++; printf("PASS  %s\n", what.UTF8String); }
    else      { gFail++; printf("FAIL  %s\n", what.UTF8String); }
}

static void eqInt(long got, long want, NSString *what) {
    ok(got == want, [NSString stringWithFormat:@"%@（得到 %ld，期望 %ld）", what, got, want]);
}

static void eqStr(NSString *got, NSString *want, NSString *what) {
    ok([got isEqualToString:want],
       [NSString stringWithFormat:@"%@（得到 %@，期望 %@）", what, got, want]);
}

/// 造一份「设备发来的握手请求」载荷（形状照公开实现的 attemptPairVerify 请求）。
static NSDictionary *DeviceHandshakeRequest(BOOL attemptPairVerify) {
    NSMutableDictionary *hostOptions = [NSMutableDictionary dictionary];
    if (attemptPairVerify) {
        hostOptions[@"attemptPairVerify"] = @YES;
    } else {
        hostOptions[@"attemptPairVerify"] = @NO;
    }
    return @{
        @"request": @{
            @"_0": @{
                @"handshake": @{
                    @"_0": @{
                        @"hostOptions": hostOptions,
                        @"wireProtocolVersion": @26,
                    },
                },
            },
        },
    };
}

int main(void) {
    @autoreleasepool {
        NSString *why = nil;

        // ================= ① 帧 =================
        NSData *json = [@"{\"a\":1}" dataUsingEncoding:NSUTF8StringEncoding];

        NSData *frame = A2RPPHWEncodeFrame(json, &why);
        ok(frame.length == 11 + json.length, @"帧长 = 11 字节头 + 负载");

        const uint8_t *fb = (const uint8_t *)frame.bytes;
        ok(memcmp(fb, "RPPairing", 9) == 0, @"帧前 9 字节是 RPPairing 前导");
        eqInt(fb[9], 0, @"大端长度高字节（7 字节负载 ⇒ 0x00）");
        eqInt(fb[10], (long)json.length, @"大端长度低字节 = 负载长度");
        ok(memcmp(fb + 11, json.bytes, json.length) == 0, @"帧尾就是原 JSON 负载");

        NSUInteger need = 0;
        why = nil;
        ok(A2RPPHWDecodeFrameHeader(frame, &need, &why), @"自己装的帧能被自己解出帧头");
        eqInt((long)need, (long)json.length, @"解出的负载长度与装帧一致");

        // 大端性：258 字节 ⇒ 0x01 0x02
        NSMutableData *big = [NSMutableData dataWithLength:258];
        NSData *bigFrame = A2RPPHWEncodeFrame(big, &why);
        const uint8_t *bb = (const uint8_t *)bigFrame.bytes;
        eqInt(bb[9], 0x01, @"258 字节长度的高字节 = 0x01（大端，非小端）");
        eqInt(bb[10], 0x02, @"258 字节长度的低字节 = 0x02（大端，非小端）");

        why = nil;
        ok(A2RPPHWEncodeFrame([NSData data], &why) == nil, @"空负载拒绝装帧");
        ok(why.length > 0, @"空负载拒绝时给出原因");

        why = nil;
        NSData *tooBig = [NSMutableData dataWithLength:70000];
        ok(A2RPPHWEncodeFrame(tooBig, &why) == nil, @">65535 字节拒绝装帧（长度字段只有 2 字节）");
        ok(why.length > 0, @"超长拒绝时给出原因");

        why = nil;
        ok(!A2RPPHWDecodeFrameHeader([NSData data], &need, &why), @"空 buffer 解帧头失败");
        why = nil;
        ok(!A2RPPHWDecodeFrameHeader([NSMutableData dataWithLength:10], &need, &why),
           @"只有 10 字节（差 1 字节）解帧头失败");

        uint8_t badMagic[11] = { 'P','R','I',' ','*',' ','H','T','T','P','/' };
        why = nil;
        ok(!A2RPPHWDecodeFrameHeader([NSData dataWithBytes:badMagic length:sizeof(badMagic)], &need, &why),
           @"HTTP/2 前导（PRI * HTTP/）不被当成 RPPairing 帧");
        ok(why.length > 0, @"magic 不符时给出原因（真机判据靠它）");

        // ================= ② 信封 =================
        NSDictionary *value = @{ @"hello": @"world" };
        NSData *envJSON = A2RPPHWEncodeEnvelope(value, A2RPPHWOriginatedByAccessory, 7, &why);
        ok(envJSON.length > 0, @"信封能序列化");

        id plain = nil;
        why = nil;
        NSDictionary *env = A2RPPHWDecodeEnvelope(envJSON, &plain, &why);
        ok(env != nil, @"信封能解回");
        eqStr(env[@"originatedBy"], @"device", @"本侧 originatedBy = device（accessory 角色）");
        eqInt([env[@"sequenceNumber"] longValue], 7, @"sequenceNumber 原样保留");
        ok([plain isEqual:value], @"message.plain._0 里就是原值");

        why = nil;
        NSData *defEnv = A2RPPHWEncodeEnvelope(value, @"", 0, &why);
        NSDictionary *defDecoded = A2RPPHWDecodeEnvelope(defEnv, NULL, &why);
        eqStr(defDecoded[@"originatedBy"], @"device", @"originatedBy 传空串时默认 device");

        why = nil;
        ok(A2RPPHWEncodeEnvelope(nil, @"device", 0, &why) == nil, @"负载为 nil 拒绝装信封");

        why = nil;
        ok(A2RPPHWDecodeEnvelope([NSData data], NULL, &why) == nil, @"空 JSON 解信封失败");
        why = nil;
        NSData *garbage = [@"not json at all" dataUsingEncoding:NSUTF8StringEncoding];
        ok(A2RPPHWDecodeEnvelope(garbage, NULL, &why) == nil, @"非 JSON 解信封失败");
        why = nil;
        NSData *arr = [@"[1,2,3]" dataUsingEncoding:NSUTF8StringEncoding];
        ok(A2RPPHWDecodeEnvelope(arr, NULL, &why) == nil, @"顶层是数组（不是对象）解信封失败");

        // 无 message.plain 时回退成整条信封（与对端实现同口径）
        NSData *bare = [@"{\"event\":{}}" dataUsingEncoding:NSUTF8StringEncoding];
        id barePlain = nil;
        ok(A2RPPHWDecodeEnvelope(bare, &barePlain, NULL) != nil, @"无 message.plain 的信封仍能解");
        ok([barePlain isKindOfClass:[NSDictionary class]] && barePlain[@"event"] != nil,
           @"无 message.plain 时 plain 回退为整条信封");

        // ================= ③ 握手 =================
        NSDictionary *resp = A2RPPHWHandshakeResponse(@"Air2 (iPhone)", @"Mac17,7",
                                                     @"ABCDEF01-2345-6789-ABCD-EF0123456789",
                                                     @"", 26);
        NSDictionary *r = resp[@"response"];
        ok(r != nil, @"握手响应有 response 层");
        eqInt([r[@"forRequestIdentifier"] longValue], 0, @"forRequestIdentifier = 0");
        NSDictionary *hs = r[@"_1"][@"handshake"][@"_0"];
        ok(hs != nil, @"握手里程碑嵌在 response._1.handshake._0");
        eqInt([hs[@"wireProtocolVersion"] longValue], 26, @"wireProtocolVersion 原样透传 26");
        eqInt([hs[@"minimumSupportedWireProtocolVersion"] longValue], 8, @"minimumSupported 8");

        NSDictionary *opts = hs[@"deviceOptions"];
        ok([opts[@"allowsPairSetup"] boolValue] == YES, @"deviceOptions.allowsPairSetup = YES");
        ok([opts[@"allowsPinlessPairing"] boolValue] == NO,
           @"★deviceOptions.allowsPinlessPairing = NO（这就是「本机要用户输 6 位码」）★");
        ok([opts[@"allowsIncomingTunnelConnections"] boolValue] == NO,
           @"deviceOptions.allowsIncomingTunnelConnections = NO");

        NSDictionary *peer = hs[@"peerDeviceInfo"];
        eqStr(peer[@"name"], @"Air2 (iPhone)", @"peerDeviceInfo.name 是用户看到的显示名");
        eqStr(peer[@"model"], @"Mac17,7", @"peerDeviceInfo.model 是 Mac 型号（iOS 把宿主当电脑）");
        ok(peer[@"identifier"] != nil, @"peerDeviceInfo.identifier 存在");
        ok(peer[@"udid"] != nil, @"peerDeviceInfo.udid 存在（可为空串）");

        ok(A2RPPHWIsHandshakeRequest(DeviceHandshakeRequest(NO)), @"识别设备握手请求（attemptPairVerify=NO）");
        ok(!A2RPPHWHandshakeWantsPairVerify(DeviceHandshakeRequest(NO)),
           @"attemptPairVerify=NO ⇒ 不要求 pair-verify（可以走 pair-setup）");
        ok(A2RPPHWHandshakeWantsPairVerify(DeviceHandshakeRequest(YES)),
           @"attemptPairVerify=YES ⇒ 识别为要求 pair-verify（本侧必须如实拒绝）");

        ok(!A2RPPHWIsHandshakeRequest(@{ @"event": @{} }), @"pairingData 事件不被认成握手请求");
        ok(!A2RPPHWIsHandshakeRequest(nil), @"nil 不被认成握手请求");
        ok(!A2RPPHWIsHandshakeRequest(@"字符串"), @"非字典不被认成握手请求");

        // 握手响应装进信封后整体可解码（端到端形状）
        NSData *hsEnv = A2RPPHWEncodeEnvelope(resp, A2RPPHWOriginatedByAccessory, 0, &why);
        id hsPlain = nil;
        ok(A2RPPHWDecodeEnvelope(hsEnv, &hsPlain, &why) != nil, @"握手响应能装进信封并解回");
        ok([hsPlain isEqual:resp], @"握手响应过一遍信封后逐字段不变");

        // ================= ④ pairingData 事件 =================
        uint8_t tlvBytes[] = { 0x06, 0x01, 0x01, 0x00, 0x01, 0x00 };   // State=1 + Method=0
        NSData *tlv = [NSData dataWithBytes:tlvBytes length:sizeof(tlvBytes)];
        NSString *b64 = [tlv base64EncodedStringWithOptions:0];

        NSDictionary *ev = A2RPPHWEncodePairingDataEvent(b64, @"setupManualPairing", NO);
        ok(A2RPPHWIsPairingDataEvent(ev), @"识别 pairingData 事件");
        NSDictionary *pd = ev[@"event"][@"_0"][@"pairingData"][@"_0"];
        eqStr(pd[@"kind"], @"setupManualPairing", @"事件 kind = setupManualPairing");
        ok([pd[@"startNewSession"] boolValue] == NO, @"startNewSession 原样为 NO");
        eqStr(pd[@"data"], b64, @"data 是 TLV 的 base64 字符串");

        NSDictionary *evNew = A2RPPHWEncodePairingDataEvent(b64, @"setupManualPairing", YES);
        ok([evNew[@"event"][@"_0"][@"pairingData"][@"_0"][@"startNewSession"] boolValue] == YES,
           @"startNewSession=YES 也原样保留");

        NSString *gotKind = nil;
        why = nil;
        NSData *back = A2RPPHWPairingDataFromEvent(ev, &gotKind, &why);
        ok([back isEqualToData:tlv], @"TLV 过一遍 base64 后逐字节不变");
        eqStr(gotKind, @"setupManualPairing", @"回填 kind");

        why = nil;
        ok(A2RPPHWPairingDataFromEvent(@{ @"event": @{} }, NULL, &why) == nil,
           @"缺 pairingData 的事件取 TLV 失败");
        why = nil;
        NSDictionary *badB64 = A2RPPHWEncodePairingDataEvent(@"!!!not base64!!!", @"setupManualPairing", NO);
        ok(A2RPPHWPairingDataFromEvent(badB64, NULL, &why) == nil, @"非法 base64 取 TLV 失败");
        why = nil;
        NSDictionary *noData = A2RPPHWEncodePairingDataEvent(@"", @"setupManualPairing", NO);
        ok(A2RPPHWPairingDataFromEvent(noData, NULL, &why) == nil, @"空 data 取 TLV 失败");

        // ★端到端：pairingData 事件 → 信封 → 帧 → 解帧 → 解信封 → 还原 TLV★
        NSData *evJSON = A2RPPHWEncodeEnvelope(ev, A2RPPHWOriginatedByAccessory, 1, &why);
        NSData *evFrame = A2RPPHWEncodeFrame(evJSON, &why);
        NSUInteger evLen = 0;
        ok(A2RPPHWDecodeFrameHeader(evFrame, &evLen, &why), @"M2 那一帧的帧头可解（前导 RPPairing）");
        NSData *evPayload = [evFrame subdataWithRange:NSMakeRange(11, evLen)];
        id evPlain = nil;
        ok(A2RPPHWDecodeEnvelope(evPayload, &evPlain, &why) != nil, @"M2 那一帧的信封可解");
        ok([[A2RPPHWPairingDataFromEvent(evPlain, NULL, &why) base64EncodedStringWithOptions:0]
            isEqualToString:b64],
           @"★端到端：装帧→解帧后 TLV 逐字节还原★");

        // ================= ⑤ 判据行 =================
        NSArray *keys = @[ @"authTag", @"flags", @"identifier", @"minVer", @"model", @"name", @"ver" ];
        NSData *first = [@"RPPairing" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *line = A2RPPHWCriterionLine(@"m2", keys, first, YES, @"sent-M2");

        ok([line hasPrefix:@"[A2-PAIRPIN] "], @"判据行以 [A2-PAIRPIN] 开头");
        ok([line rangeOfString:@"stage=m2"].location != NSNotFound, @"判据行含 stage=");
        ok([line rangeOfString:@"txKeys=authTag,flags,identifier,minVer,model,name,ver"].location != NSNotFound,
           @"判据行含完整 txKeys（7 个键，逗号分隔）");
        ok([line rangeOfString:@"firstBytes=525050616972696E67"].location != NSNotFound,
           @"★firstBytes 是 RPPairing 的大写十六进制（一眼看出是不是这条线）★");
        ok([line rangeOfString:@"m2=ok"].location != NSNotFound, @"m2 发出时 m2=ok");
        ok([line rangeOfString:@"reason=sent-M2"].location != NSNotFound, @"reason 字段在末尾");

        NSString *failLine = A2RPPHWCriterionLine(@"handshake", nil, nil, NO, nil);
        ok([failLine rangeOfString:@"m2=fail"].location != NSNotFound, @"未发 M2 时 m2=fail");
        ok([failLine rangeOfString:@"txKeys=(none)"].location != NSNotFound, @"无 txKeys ⇒ (none)");
        ok([failLine rangeOfString:@"firstBytes=(none)"].location != NSNotFound, @"无 firstBytes ⇒ (none)");
        ok([failLine rangeOfString:@"reason=(none)"].location != NSNotFound, @"无 reason ⇒ (none)");

        eqStr(A2RPPHWHexPrefix(nil, 16), @"(none)", @"HexPrefix(nil) ⇒ (none)");
        eqStr(A2RPPHWHexPrefix([NSData data], 16), @"(none)", @"HexPrefix(空) ⇒ (none)");
        uint8_t raw[] = { 0x00, 0x0A, 0xFF };
        eqStr(A2RPPHWHexPrefix([NSData dataWithBytes:raw length:3], 16), @"000AFF",
              @"HexPrefix 大写、逐字节两位");
        eqStr(A2RPPHWHexPrefix([NSData dataWithBytes:raw length:3], 2), @"000A",
              @"HexPrefix 按 maxBytes 截断");

        // 常量口径
        eqStr(A2RPPHWWireMagicString, @"RPPairing", @"前导常量 = RPPairing");
        eqStr(A2RPPHWOriginatedByAccessory, @"device", @"本侧 originatedBy 常量 = device");
        eqInt((long)A2RPPHWMinimumWireProtocolVersion, 8, @"最低对端协议版本 = 8");
        eqStr(A2RPPHWCriterionMarker, @"[A2-PAIRPIN]", @"判据标记常量 = [A2-PAIRPIN]");

        printf("\n----- pairable-host wire: PASS=%d FAIL=%d -----\n", gPass, gFail);
    }
    return gFail == 0 ? 0 : 1;
}
