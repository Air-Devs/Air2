//
//  a2_rppairing_ed25519.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— [JIT-AUTOPAIR-2] Ed25519（RFC 8032）签名/验签自研实现。
//
//  ★为什么自研而不是用系统库★（本单实测证据，见 docs/JIT-PROVISIONING.md §3.6）：
//    · RPPairing 用 Ed25519 签配对/握手（协议事实）。配对文件里的 public_key/private_key 也是 Ed25519。
//    · iOS/macOS 的**公开** API 没有 Ed25519：Security.framework 只给 NIST 曲线，
//      CryptoKit 是 Swift-only（本仓是 ObjC，且 gen_xcodeproj 只扫 .m/.mm）。
//    · corecrypto 的 `cced25519_*` 是**私有符号**，且其 ctx 无公开初始化路径 —— 本单在 macOS 上实测：
//        · `cced25519_make_pub(ctx=NULL, …)` ⇒ SIGSEGV（说明 ctx 会被解引用，不能省）
//        · `cced25519_make_pub(ctx=4096B 全零, …)` ⇒ rc=-7（参数错，不能驱动）
//        · `cced25519_sign/verify/make_key_pair(同 ctx)` ⇒ SIGSEGV
//      且 SDK 里**没有** corecrypto 头（实测 `…/iPhoneOS26.2.sdk/usr/include/corecrypto` 为空），
//      即无法确定 ctx 结构 ⇒ ★把握手压在「逆向私有 ABI」上不划算★。
//    ⇒ 按 RFC 8032 **自研**，并用 RFC 8032 §7.1 官方向量 + 24 条 PyNaCl(libsodium) 随机向量逐位自证。
//
//  实现说明（如实声明）：曲线运算用扩展坐标 + 朴素「倍点-加点」标量乘，
//  ★不是常数时间实现★（本用途是设备内自配对的一次性握手，不参与签名预言机攻击面；
//   密钥不跨网络暴露）。CSPRNG 用 SecRandomCopyBytes（调用方 / 上层）。
//
//  纯 C（只依赖 CommonCrypto 的 SHA-512），返回 int：1 = 成功，0 = 失败。
//

#ifndef A2_RPPAIRING_ED25519_H
#define A2_RPPAIRING_ED25519_H

#include <stddef.h>
#include <stdint.h>

#define A2RP_ED25519_SEED_BYTES 32
#define A2RP_ED25519_PUB_BYTES  32
#define A2RP_ED25519_SIG_BYTES  64

/// 由 32 字节种子派生公钥（RFC 8032 §5.1.5）。
int A2RPEd25519PublicKey(uint8_t pubOut[A2RP_ED25519_PUB_BYTES],
                         const uint8_t seed[A2RP_ED25519_SEED_BYTES]);

/// 签名（RFC 8032 §5.1.6）。msg 可为 NULL（msgLen=0 时空消息）。
int A2RPEd25519Sign(uint8_t sigOut[A2RP_ED25519_SIG_BYTES],
                    const uint8_t seed[A2RP_ED25519_SEED_BYTES],
                    const uint8_t *msg, size_t msgLen);

/// 验签（RFC 8032 §5.1.7）。S ≥ L、公钥非曲线点、签名字节不符 ⇒ 返回 0。
int A2RPEd25519Verify(const uint8_t pub[A2RP_ED25519_PUB_BYTES],
                      const uint8_t *msg, size_t msgLen,
                      const uint8_t sig[A2RP_ED25519_SIG_BYTES]);

#endif /* A2_RPPAIRING_ED25519_H */
