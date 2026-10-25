//
//  A2TLSPskTunnelBridge.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Bridge —— TLS-PSK 隧道的跨层转发（见头文件的分层说明）。
//  本文件【只转发】：
//    · 注册入口：A2TLSPskMbedTLSEnsureRegistered()（Natives/Support/a2_tlspsk_mbedtls.m）
//    · 状态行  ：[A2TLSPskTunnel statusLine]
//    · 回环自检：A2TLSPskSelfTestRun()（Natives/Support/a2_tlspsk_selftest.m）
//

#import "A2TLSPskTunnelBridge.h"
#import "a2_tlspsk_tunnel.h"
#import "a2_tlspsk_mbedtls.h"
#import "a2_tlspsk_selftest.h"
#import "A2Log.h"

/// 最近一次自检结果（进程内缓存；UI 刷新时不必重跑）。
static A2TLSPskSelfTestResult *gA2LastSelfTest = nil;
static NSLock *gA2SelfTestLock = nil;

@implementation A2TLSPskTunnelBridge

+ (void)initialize {
    if (self == [A2TLSPskTunnelBridge class]) {
        gA2SelfTestLock = [[NSLock alloc] init];
    }
}

+ (NSString *)statusLine {
    // ★注册入口唯一去处★：这里注册即保证「后端就绪」这件事在真机日志里可核。
    A2TLSPskMbedTLSEnsureRegistered();
    return [A2TLSPskTunnel statusLine];
}

+ (NSString *)runSelfTestCriterionLine {
    A2TLSPskSelfTestResult *r = A2TLSPskSelfTestRun(0);
    [gA2SelfTestLock lock];
    gA2LastSelfTest = r;
    [gA2SelfTestLock unlock];
    // 自检结论也进会话日志（A2Log criterion: 会同时写控制台与 lastlog.txt）。
    [A2Log criterion:@"%@", r.criterionLine];
    return r.criterionLine;
}

+ (NSString *)lastSelfTestSummary {
    [gA2SelfTestLock lock];
    A2TLSPskSelfTestResult *r = gA2LastSelfTest;
    [gA2SelfTestLock unlock];
    if (r == nil) {
        return @"未运行（点「运行自检」）";
    }
    return [NSString stringWithFormat:@"%@：%@", r.passed ? @"通过" : @"未通过", r.detail];
}

+ (BOOL)lastSelfTestPassed {
    [gA2SelfTestLock lock];
    BOOL passed = gA2LastSelfTest.passed;
    [gA2SelfTestLock unlock];
    return passed;
}

@end
