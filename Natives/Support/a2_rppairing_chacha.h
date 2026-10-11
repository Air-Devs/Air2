//
//  a2_rppairing_chacha.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— [JIT-AUTOPAIR-2] ChaCha20-Poly1305 AEAD（RFC 8439）自研实现。
//
//  ★为什么自研而不是用系统库★（有本单实测证据，见 docs/JIT-PROVISIONING.md §3.6）：
//    · RPPairing 的 AEAD 是 ChaCha20-Poly1305（协议事实，来源见 a2_rppairing.h 顶部）。
//    · iOS/macOS 的公开 API 里 **没有** ChaCha20-Poly1305：CommonCrypto 只提供 AES/DES/3DES/RC4 等；
//      corecrypto 的 `ccchacha20poly1305_*` 是**私有符号**，且其 ctx 需要 corecrypto 的 info 结构
//      （本单在 macOS 上实测：`ccchacha20poly1305_info()` 返回的指针按公开结构解释不可用），
//      而 SDK 里**没有** corecrypto 头文件（实测 `$(xcrun --sdk iphoneos --show-sdk-path)/usr/include/corecrypto` 为空）。
//    ⇒ 本仓「零第三方依赖 + 只用公开/可自证通道」的纪律下，唯一诚实做法是**按 RFC 自研**，
//      并用 RFC 8439 的官方向量逐位自证（tests/JIT ⑯）。
//
//  纯 C（不依赖 Foundation），返回 int：1 = 成功，0 = 失败（调用方负责如实转成 BOOL）。
//

#ifndef A2_RPPAIRING_CHACHA_H
#define A2_RPPAIRING_CHACHA_H

#include <stddef.h>
#include <stdint.h>

#define A2RP_CHACHA_KEY_BYTES     32
#define A2RP_CHACHA_NONCE_BYTES   12
#define A2RP_CHACHA_BLOCK_BYTES   64
#define A2RP_AEAD_TAG_BYTES       16
#define A2RP_AEAD_NONCE_BYTES     A2RP_CHACHA_NONCE_BYTES

/// ChaCha20 流加密/解密（同函数，RFC 8439 §2.4）。counter 为初始块计数（AEAD 用 1）。
/// out 与 in 可同址。返回 1 成功；参数非法返回 0。
int A2RPChaCha20XOR(uint8_t *out,
                    const uint8_t *in,
                    size_t len,
                    const uint8_t key[A2RP_CHACHA_KEY_BYTES],
                    uint32_t counter,
                    const uint8_t nonce[A2RP_CHACHA_NONCE_BYTES]);

/// AEAD 加密（RFC 8439 §2.8）：先按 counter=0 的块派生 Poly1305 一次性密钥，再用 counter=1 起加密。
/// ctOut 至少 ptLen 字节；tagOut 16 字节。
int A2RPChaCha20Poly1305Seal(uint8_t *ctOut,
                             uint8_t tagOut[A2RP_AEAD_TAG_BYTES],
                             const uint8_t key[A2RP_CHACHA_KEY_BYTES],
                             const uint8_t nonce[A2RP_CHACHA_NONCE_BYTES],
                             const uint8_t *aad, size_t aadLen,
                             const uint8_t *pt, size_t ptLen);

/// AEAD 解密 + **常数时间**认证校验（校验失败 ⇒ 返回 0，且调用方不应使用 ptOut 内容）。
int A2RPChaCha20Poly1305Open(uint8_t *ptOut,
                             const uint8_t key[A2RP_CHACHA_KEY_BYTES],
                             const uint8_t nonce[A2RP_CHACHA_NONCE_BYTES],
                             const uint8_t *aad, size_t aadLen,
                             const uint8_t *ct, size_t ctLen,
                             const uint8_t tag[A2RP_AEAD_TAG_BYTES]);

#endif /* A2_RPPAIRING_CHACHA_H */
