//
//  tests/Natives/tlspsk_tunnel_tests.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [A2-PAIR-ONDEVICE] TLS-PSK 隧道单测 —— ★真编译、真握手★。
//
//  为什么不是源码扫描：`a2_rppairing_rsd.h:19-22` 的「未打通」本质是「没有任何证据」。
//  这里用随仓 mbedTLS（macOS 版静态库）起 127.0.0.1 的 PSK 服务端，用**生产路径**
//  握手一次并回显一帧 —— 通过 ⇒ 隧道本体可用；不通过 ⇒ 打印卡在哪一步。
//
//  用法（Mac）：python3 tests/Natives/run_tlspsk_tunnel_tests.py
//

#import <Foundation/Foundation.h>
#import "a2_tlspsk_tunnel.h"
#import "a2_tlspsk_mbedtls.h"
#import "a2_tlspsk_selftest.h"

static int gPass = 0;
static int gFail = 0;

static void ok(BOOL cond, NSString *what) {
    if (cond) { gPass++; printf("PASS  %s\n", what.UTF8String); }
    else { gFail++; printf("FAIL  %s\n", what.UTF8String); }
}

int main(void) {
    @autoreleasepool {
        A2TLSPskTunnel *tunnel = [A2TLSPskTunnel sharedTunnel];

        // ---- ① 默认关：不许偷偷连 ----
        ok(!tunnel.isEnabled, @"门面默认关闭（enabled == NO）");
        NSString *why = nil;
        unsigned char psk[32] = {0};
        BOOL connected = [tunnel connectToHost:@"127.0.0.1" port:1
                                           psk:[NSData dataWithBytes:psk length:sizeof(psk)]
                                      identity:@""
                                       timeout:1.0
                                        reason:&why];
        ok(connected == NO && [why containsString:@"默认关"],
           @"开关未开 ⇒ connect 如实拒绝（reason 点名「默认关」）");

        // ---- ② 打开但无后端：不许假装可用 ----
        tunnel.enabled = YES;
        why = nil;
        connected = [tunnel connectToHost:@"127.0.0.1" port:1
                                     psk:[NSData dataWithBytes:psk length:sizeof(psk)]
                                identity:@""
                                 timeout:1.0
                                  reason:&why];
        ok(connected == NO && [why containsString:@"未注册"],
           @"无后端 ⇒ connect 如实拒绝（reason 点名「未注册」）");
        ok(![A2TLSPskTunnel isAvailableWithReason:&why], @"无后端 ⇒ 可用性如实为 NO");

        // ---- ③ 不上云：公网地址一律拒绝 ----
        A2TLSPskMbedTLSEnsureRegistered();
        why = nil;
        connected = [tunnel connectToHost:@"example.com" port:443
                                     psk:[NSData dataWithBytes:psk length:sizeof(psk)]
                                identity:@""
                                 timeout:1.0
                                  reason:&why];
        ok(connected == NO && [why containsString:@"不上云"],
           @"公网地址 ⇒ 默认策略拒绝（不上云）");

        // ---- ④ 真握手：回环自检（生产路径）----
        ok([A2TLSPskTunnel isAvailableWithReason:&why], @"注册 mbedTLS 后端后可用性为 YES");
        A2TLSPskSelfTestResult *r = A2TLSPskSelfTestRun(8.0);
        printf("selftest: %s\n", r.criterionLine.UTF8String);
        ok(r.passed, [NSString stringWithFormat:@"回环 TLS-PSK 握手 + 帧回显通过（%@）", r.detail]);
        ok([r.cipherSuite isEqualToString:@"0x00AF"] || [r.cipherSuite isEqualToString:@"0x008C"],
           [NSString stringWithFormat:@"协商套件命中规格 §12 白名单（%@）", r.cipherSuite]);
        ok([r.tlsVersion isEqualToString:@"TLSv1.2"],
           [NSString stringWithFormat:@"协商版本为 TLSv1.2（%@）", r.tlsVersion]);
        ok(r.echoBytes > 0, @"回环帧回显字节数 > 0（收发分帧正确）");

        // ---- ⑤ 自检不许悄悄把开关留在「开」----
        ok(tunnel.isEnabled, @"自检恢复原开关（原为开 ⇒ 仍为开）");
        tunnel.enabled = NO;
        A2TLSPskSelfTestResult *r2 = A2TLSPskSelfTestRun(8.0);
        ok(r2.passed && !tunnel.isEnabled,
           @"自检结束后开关恢复为关（默认关不许被自检打开）");

        // ---- ⑥ 结论行稳定（日志可搜）----
        ok([r2.criterionLine hasPrefix:@"[A2-TLSPK-SELFTEST]"],
           @"判据行前缀固定为 [A2-TLSPK-SELFTEST]");

        printf("\nTOTAL pass=%d fail=%d\n", gPass, gFail);
    }
    return gFail == 0 ? 0 : 1;
}
