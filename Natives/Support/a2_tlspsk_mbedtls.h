// ============================================================================
//  Natives/Support/a2_tlspsk_mbedtls.h
//  Air2 —— [A2-INTEGRATION] mbedTLS（第三方，Apache-2.0）TLS-PSK 后端的注册入口
// ----------------------------------------------------------------------------
//  ★谁调它·哪一行★
//    · 生产：`Air2/Bridge/A2JITAutoPairingEngineBridge.m` 的 TLS-PSK 诊断块
//      （A2TLSPskMbedTLSEnsureRegistered() → [A2TLSPskTunnel statusLine]）；
//    · 自证：`tests/JIT/jit_logic_tests.m` 的 [A2-INTEGRATION] 例。
//  ★为什么单独一个入口、不用 +load★：注册点是显式的，日志里能一眼看到「谁注册了后端」，
//    排查「以为编进来了其实没注册」这类假象。
// ============================================================================
#ifndef A2_TLSPK_MBEDTLS_H
#define A2_TLSPK_MBEDTLS_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 把 mbedTLS 后端注册进 A2TLSPskTunnel（幂等）。
/// ★不谎报★：若本文件编译时没有 mbedTLS 头（__has_include 失败）⇒ 不注册任何后端，
/// 只落一条 `[A2-TLSPK]` 实证日志说明「未编入」；门面随之如实报「未注册后端」。
void A2TLSPskMbedTLSEnsureRegistered(void);

/// 本二进制编译时是否带了 mbedTLS 头（= 后端是否被编入）。值由编译期决定，不猜。
BOOL A2TLSPskMbedTLSCompiledIn(void);

/// 期望的 mbedTLS 版本串（编译期常量；未编入则 «未编入»）。日志/自证用。
NSString *A2TLSPskMbedTLSVersionString(void);

NS_ASSUME_NONNULL_END
#endif /* A2_TLSPK_MBEDTLS_H */
