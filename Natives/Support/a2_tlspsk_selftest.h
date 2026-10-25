// ============================================================================
//  Natives/Support/a2_tlspsk_selftest.h
//  Air2 —— [A2-PAIR-ONDEVICE] TLS-PSK 隧道 ★回环自检★（真握手，不是配置检查）
// ----------------------------------------------------------------------------
//  为什么需要它：
//    `a2_rppairing_rsd.h:19-22` 记的「TLS-PSK 未打通」不是缺代码，而是**没有任何证据**
//    能证明这段代码真的能协商出设备要的套件（§12 的 0x00AF / 0x008C）。真实对端是
//    iOS 设备的 RSD 监听口，手边没有设备时 ⇒ 永远无法自证。
//
//    本自检用**同一份 mbedTLS**（同一静态库、同一配置）在 127.0.0.1 起一个 PSK
//    服务端，再用**生产代码路径**（`A2TLSPskTunnel` + mbedTLS 后端）连上去，跑完
//    ClientHello→Finished、协商套件、并用隧道帧（4B 大端长度 + 载荷）走一次回显。
//    通过 ⇒ 「TLS 1.2 PSK 隧道本体可用」有实证；不通过 ⇒ 如实点名卡在哪一步。
//
//  ★边界（不谎报）★：
//    · 只证明「我们能和 PSK 对端握手并收发帧」，**不证明**设备接受我们发的 PSK
//      identity（见 docs/ONDEVICE-PAIR.md §3：mbedTLS 在 identity 长度 0 时会**不
//      再提供 PSK 套件**，故本自检用非空 identity）；设备侧的 identity 语义要真机验。
//    · 全程回环，无网络出口（主机准入策略也把它限在本机）。
//
//  SPDX-License-Identifier: GPL-3.0-or-later
// ============================================================================
#ifndef A2_TLSPK_SELFTEST_H
#define A2_TLSPK_SELFTEST_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 自检结果（结构化，便于 UI 与日志共用同一份事实）。
@interface A2TLSPskSelfTestResult : NSObject

/// 是否真的通了（握手 + 帧回显都对）。
@property (nonatomic, assign) BOOL passed;
/// 人读原因（失败时点名卡在哪一步；成功时给协商结果）。
@property (nonatomic, copy) NSString *detail;
/// 协商到的套件（如 «0x00AF»）；未握手 ⇒ «-»。
@property (nonatomic, copy) NSString *cipherSuite;
/// 协商到的版本（如 «TLSv1.2»）；未握手 ⇒ «-»。
@property (nonatomic, copy) NSString *tlsVersion;
/// 回显回来的字节数（0 ⇒ 没收到）。
@property (nonatomic, assign) NSUInteger echoBytes;
/// 自检耗时（秒）。
@property (nonatomic, assign) NSTimeInterval elapsed;
/// 稳定的判据行（前缀 `[A2-TLSPK-SELFTEST]`，日志可搜）。
@property (nonatomic, copy) NSString *criterionLine;

@end

/// 跑一次回环自检（同步阻塞，最长约 timeout 秒；★不要在主线程调★）。
/// @param timeout 本次自检的总预算（≤0 ⇒ 用默认 8 s）。
/// @return 永远非 nil（连「库没编进来」也返回一个 passed=NO 的结果）。
A2TLSPskSelfTestResult *A2TLSPskSelfTestRun(NSTimeInterval timeout);

/// 默认预算（秒）。
FOUNDATION_EXPORT NSTimeInterval const A2TLSPskSelfTestDefaultTimeout;

NS_ASSUME_NONNULL_END
#endif /* A2_TLSPK_SELFTEST_H */
