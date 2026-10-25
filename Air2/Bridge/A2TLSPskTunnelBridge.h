//
//  A2TLSPskTunnelBridge.h
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Bridge —— [A2-PAIR-ONDEVICE] TLS-PSK 隧道的★唯一跨层入口★（UI/Player 不得 import Natives）。
//
//  分层（docs/ARCHITECTURE.md:29 起）：App → UI → Player → Core → Bridge → Natives。
//  ⇒ 设置页要看「隧道后端 / 握手结果」，只能经过本文件；本文件只做转发与文案化，
//    不含任何 TLS 逻辑（逻辑在 Natives/Support/a2_tlspsk_*）。
//
//  ★不谎报★：后端没编进来 / 自检没过，都如实返回；绝不返回「已打通」的结论。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2TLSPskTunnelBridge : NSObject

/// 注册 mbedTLS 后端（幂等）并返回一行如实状态（后端名 / 可用性 / 开关）。
+ (NSString *)statusLine;

/// 跑一次回环自检（★同步阻塞，最长 ~8 s，别在主线程调★）。
/// @return 判据行（前缀 `[A2-TLSPK-SELFTEST]`，含 passed/suite/version/echo）。
+ (NSString *)runSelfTestCriterionLine;

/// 最近一次自检的结论（给人看的短句；「通过：…」/「未通过：…」）。
+ (NSString *)lastSelfTestSummary;

/// 自检是否通过（没跑过 ⇒ NO，且 summary 里写明「未运行」）。
+ (BOOL)lastSelfTestPassed;

@end

NS_ASSUME_NONNULL_END
