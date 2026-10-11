//
//  a2_rppairing_srp.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— [JIT-AUTOPAIR-3] SRP-6a（SHA-512）纯密码学内核（RPPairing pair-setup 的认证原语）。
//
//  协议出处（★只取公开规格事实/常量，未搬运任何项目源码★）：
//    · 群参数：RFC 5054 §Appendix A 的 **3072-bit Group**（`N` 见下面的十六进制字面量，`g = 5`）。
//      —— RFC 5054 "Using the Secure Remote Password (SRP) Protocol for TLS Authentication"。
//    · 算法（SRP-6a）：
//        k = H(N | PAD(g))
//        x = H(salt | H(I | ":" | P))
//        v = g^x mod N
//        A = g^a mod N
//        u = H(PAD(A) | PAD(B))
//        B = (k*v + g^b) mod N
//        S = (B - k*g^x)^(a + u*x) mod N   ==   S = (A * v^u)^b mod N
//        K = H(S)
//        M1 = H( H(N) xor H(g) | H(I) | salt | A | B | K )
//        M2 = H( A | M1 | K )
//      —— RFC 5054 §2.4/§2.5/§2.6 定义 x/v/B/A/u/S；K/M1/M2 取 SRP-6a 权威表述
//         （srp.stanford.edu/design.html，及公开测试向量仓 secure-remote-password/test-vectors 的映射说明）。
//    · 与 Apple/HAP 一致的取用口径（RPPairing pair-setup 与 HomeKit pair-setup 同源）：
//        Hash = SHA-512、group = rfc5054.3072（g=5）、I = "Pair-Setup"、RFC 2945 派生（用户名进 x）。
//      —— 依据：公开规格 https://jkcoxson.com/blog/rppairing-spec §9「Group: SRP-3072 (RFC 5054 Appendix A);
//         Hash: SHA-512; Username: b"Pair-Setup"; no_username_in_x: false」，
//         以及公开的 HAP 参考实现（go2rtc/pkg/hap 使用 `srp.NewSRP("rfc5054.3072", sha512, keyDerivativeFuncRFC2945)`）。
//
//  ★大数模幂用随仓第三方 mbedTLS 的 `mbedtls_mpi`★（`Libraries/ThirdParty/mbedtls`，Apache-2.0；
//    见 docs/DEPENDENCIES.md）。★本文件不自造 bignum★。
//
//  ★本文件只做 SRP 数学，不含消息流、不含配对码来源★：
//    配对码（PIN）由调用方给（见 a2_rppairing_pairsetup.h 的可注入缝）。
//
//  ★如实声明（未与真机联调时须知道）★：
//    · 本内核已用 **RFC 5054 §Appendix B 公开测试向量逐位核对**（见 tests/JIT）。
//    · 但 SRP 的若干「编码约定」在公开实现间存在分歧（K 里 S 的字节长度、M1 里 A/B 是否补零、
//      H(N) xor H(g) 是否保留定长）。本仓采用 SRP-6a/公开 HAP 参考实现一致的**定长/最短大端**约定，
//      并在 .m 顶部逐条写明；与真机互通前这些约定需以真机对拍确认（本仓无真机）。
//

#ifndef A2_RPPAIRING_SRP_H
#define A2_RPPAIRING_SRP_H

#import <Foundation/Foundation.h>
#include <stddef.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 摘要函数（成功 = 1，失败 = 0）。★可注入★：生产用 SHA-512；单测用同一内核核对 RFC 5054 的 SHA-1 向量。
typedef int (*A2RPSRPHashFn)(const uint8_t *in, size_t inLen, uint8_t *out);

/// SRP 群参数（公开规格值）。N 以**大端十六进制字符串**给（便于与 RFC 直接对拍）。
typedef struct A2RPSRPGroup {
    const char *primeHex;   ///< N（大端十六进制）
    unsigned int generator; ///< g
    unsigned int primeBytes;///< N 的定长字节数（RFC 5054 §2.1 的 PAD 基准）
} A2RPSRPGroup;

/// RFC 5054 §Appendix A 的 3072-bit 群（N 见 .m；g = 5）。
const A2RPSRPGroup *A2RPSRPGroup3072(void);

/// 生产口径的摘要 = SHA-512（与 a2_rppairing_crypto 的 A2RPSHA512 同实现）。
A2RPSRPHashFn A2RPSRPHashSHA512(void);
/// SHA-512 摘要长度（64）。
size_t A2RPSRPSHA512DigestLength(void);

// ---------------------------------------------------------------------------
// 诊断用派生量（供向量核对 / 日志；★不参与协议状态★）
// ---------------------------------------------------------------------------

#define A2RP_SRP_MAX_MOD_BYTES     384
#define A2RP_SRP_MAX_DIGEST_BYTES   64
#define A2RP_SRP_MAX_SALT_BYTES     64

typedef struct A2RPSRPTrace {
    size_t  kLen;   uint8_t k[A2RP_SRP_MAX_DIGEST_BYTES];
    size_t  xLen;   uint8_t x[A2RP_SRP_MAX_DIGEST_BYTES];
    size_t  uLen;   uint8_t u[A2RP_SRP_MAX_DIGEST_BYTES];
    size_t  vLen;   uint8_t v[A2RP_SRP_MAX_MOD_BYTES];
    size_t  aLen;   uint8_t A[A2RP_SRP_MAX_MOD_BYTES];
    size_t  bLen;   uint8_t B[A2RP_SRP_MAX_MOD_BYTES];
    size_t  sLen;   uint8_t S[A2RP_SRP_MAX_MOD_BYTES];
    size_t  keyLen; uint8_t K[A2RP_SRP_MAX_DIGEST_BYTES];
    size_t  m1Len;  uint8_t M1[A2RP_SRP_MAX_DIGEST_BYTES];
    size_t  m2Len;  uint8_t M2[A2RP_SRP_MAX_DIGEST_BYTES];
} A2RPSRPTrace;

// ---------------------------------------------------------------------------
// 客户端（= pair-setup 里的 Host/控制器）
// ---------------------------------------------------------------------------

typedef struct A2RPSRPClient A2RPSRPClient;

/// 建客户端。aBytes = 私随机数 a（调用方给；生产由 CSPRNG 生成，单测给定量以便对向量）。
/// identity/password 可含任意字节（pair-setup 里分别是 "Pair-Setup" 与配对码）。
/// 失败（参数非法 / 群非法 / 摘要长度不支持）⇒ NULL 并回填 reason。
A2RPSRPClient *_Nullable A2RPSRPClientCreate(const A2RPSRPGroup *group,
                                             A2RPSRPHashFn hash, size_t hashLen,
                                             const uint8_t *identity, size_t identityLen,
                                             const uint8_t *password, size_t passwordLen,
                                             const uint8_t *aBytes, size_t aLen,
                                             NSString *_Nullable *_Nullable reason);

void A2RPSRPClientFree(A2RPSRPClient *_Nullable client);

/// A = g^a mod N（最短大端）。
const uint8_t *_Nullable A2RPSRPClientPublicA(A2RPSRPClient *client, size_t *lenOut);

/// 处理服务端的 (salt, B)：算 u/x/S/K/M1。★任何非法（B mod N == 0、u == 0、长度不符）⇒ NO + reason★。
BOOL A2RPSRPClientComputeKey(A2RPSRPClient *client,
                             const uint8_t *salt, size_t saltLen,
                             const uint8_t *B, size_t bLen,
                             NSString *_Nullable *_Nullable reason);

/// M1（客户端证明）。未 ComputeKey 时返回 NULL。
const uint8_t *_Nullable A2RPSRPClientProofM1(A2RPSRPClient *client, size_t *lenOut);
/// K = H(S)（会话密钥）。未 ComputeKey 时返回 NULL。
const uint8_t *_Nullable A2RPSRPClientSessionKey(A2RPSRPClient *client, size_t *lenOut);
/// 校验服务端证明 M2（定长比较）。
BOOL A2RPSRPClientVerifyM2(A2RPSRPClient *client, const uint8_t *m2, size_t m2Len);

/// 回填诊断派生量（k/x/u/v/A/B/S/K/M1）。未算出的项 len = 0。
BOOL A2RPSRPClientTrace(A2RPSRPClient *client, A2RPSRPTrace *out);

// ---------------------------------------------------------------------------
// 服务端（= pair-setup 里的 Device；本仓用于进程内自握手自证 + 校验器生成）
// ---------------------------------------------------------------------------

typedef struct A2RPSRPServer A2RPSRPServer;

/// 建服务端。salt 与 bBytes 由调用方给（生产：salt 随机、b 随机；单测：给定量）。
/// 失败 ⇒ NULL 并回填 reason。
A2RPSRPServer *_Nullable A2RPSRPServerCreate(const A2RPSRPGroup *group,
                                             A2RPSRPHashFn hash, size_t hashLen,
                                             const uint8_t *identity, size_t identityLen,
                                             const uint8_t *password, size_t passwordLen,
                                             const uint8_t *salt, size_t saltLen,
                                             const uint8_t *bBytes, size_t bLen,
                                             NSString *_Nullable *_Nullable reason);

void A2RPSRPServerFree(A2RPSRPServer *_Nullable server);

/// salt / 校验器 v / 服务端公开值 B（均为最短大端）。
const uint8_t *_Nullable A2RPSRPServerSalt(A2RPSRPServer *server, size_t *lenOut);
const uint8_t *_Nullable A2RPSRPServerVerifier(A2RPSRPServer *server, size_t *lenOut);
const uint8_t *_Nullable A2RPSRPServerPublicB(A2RPSRPServer *server, size_t *lenOut);

/// 处理客户端 A：算 u/S/K/M2。★A mod N == 0 / u == 0 / 长度不符 ⇒ NO + reason★。
BOOL A2RPSRPServerComputeKey(A2RPSRPServer *server,
                             const uint8_t *A, size_t aLen,
                             NSString *_Nullable *_Nullable reason);

/// 校验客户端证明 M1。
BOOL A2RPSRPServerVerifyM1(A2RPSRPServer *server, const uint8_t *m1, size_t m1Len);
/// M2（服务端证明）。未 ComputeKey 时返回 NULL。
const uint8_t *_Nullable A2RPSRPServerProofM2(A2RPSRPServer *server, size_t *lenOut);
/// K = H(S)。未 ComputeKey 时返回 NULL。
const uint8_t *_Nullable A2RPSRPServerSessionKey(A2RPSRPServer *server, size_t *lenOut);

/// 回填诊断派生量。
BOOL A2RPSRPServerTrace(A2RPSRPServer *server, A2RPSRPTrace *out);

NS_ASSUME_NONNULL_END

#endif /* A2_RPPAIRING_SRP_H */
