//
//  a2_rppairing_crypto.h
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
//  Natives/Support —— [JIT-AUTOPAIR-2] RPPairing 握手所需的【系统密码学原语】薄封装。
//
//  为什么需要这一层（而不是在协议代码里直接调）：
//    · RPPairing（Remote Pairing）的握手密码学公开描述为
//      Ed25519（签名）+ X25519（密钥交换）+ ChaCha20-Poly1305（AEAD）+ HKDF-SHA512（KDF）。
//      （来源：公开协议描述 https://jkcoxson.com/blog/rppairing-spec §1）
//    · 本仓为 ObjC、零第三方依赖、只用系统框架。Objective-C 侧**没有** Curve25519 的公开 API
//      （CryptoKit 是 Swift-only；Security.framework 只提供 NIST P-256 等，无 X25519/Ed25519）。
//    · 系统库 libSystem 导出的 corecrypto 原语（CryptoKit 底层同一实现）才是可用通道：
//        实测符号（iPhoneOS26.2.sdk / macOS 15 均导出）：
//          cccurve25519 / cccurve25519_make_pub / cccurve25519_make_key_pair
//          cced25519_make_key_pair / cced25519_make_pub / cced25519_sign / cced25519_verify
//          ccchacha20poly1305_info / ccchacha20poly1305_{encrypt,decrypt}_oneshot
//      这些符号无公开头文件 ⇒ 原型在 .m 内自声明（签名以 RFC 向量实测确认，见 .m 注释）。
//
//  ★本阶段实际落地与未落地的边界（如实，绝不假成功）★：
//    · 已落地并【用 RFC 向量自证】的：X25519 标量乘（RFC 7748）、HKDF-SHA512、SHA-512、MD5、CSPRNG、UUIDv3。
//    · 未落地：Ed25519（crypto 符号存在，但 ctx 结构无公开初始化路径，签名/验签驱动未确认）、
//      ChaCha20-Poly1305（oneshot 需 corecrypto 的 info 结构，未确认）。
//      ⇒ 这两个由 A2RPEd25519Available() / A2RPChaCha20Poly1305Available() **如实回报 NO**。
//
//  与 GameNative/A2JITEnvironment 的关系：无。本文件不下 Natives 业务语义，只回传原语结果。
//

#import <Foundation/Foundation.h>
#include <stddef.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 密钥 / 摘要尺寸（编译期常量，供调用方做静态数组；勿改语义）。
#define A2RP_X25519_KEY_BYTES     32
#define A2RP_ED25519_KEY_BYTES    32
#define A2RP_ED25519_SIG_BYTES    64
#define A2RP_SHA512_BYTES         64
#define A2RP_MD5_BYTES            16
#define A2RP_SYMMETRIC_KEY_BYTES  32
#define A2RP_AES256_KEY_BYTES     32

// ---------------------------------------------------------------------------
// 已落地的系统原语（全部经 RFC 向量自证；见 tests/JIT）
// ---------------------------------------------------------------------------

/// CSPRNG（SecRandomCopyBytes）。成功填满 length 字节。
BOOL A2RPRandomBytes(void *buffer, size_t length);

/// X25519 标量乘（RFC 7748）：out = X25519(privkey, pubkey)。
/// 底层 = 系统 corecrypto 的 cccurve25519（libSystem 导出）。
/// 入参/出参均为 32 字节缓冲（A2RP_X25519_KEY_BYTES）。
/// @return YES 成功（rc==0）；NO 失败（参数非法 / 原语不可用）。
BOOL A2RPX25519(uint8_t *out,
                const uint8_t *privkey,
                const uint8_t *pubkey);

/// X25519 公钥：out = X25519(privkey, 基点 9)（RFC 7748 定义的 base point）。
BOOL A2RPX25519PublicKey(uint8_t *out,
                         const uint8_t *privkey);

/// HKDF（RFC 5869 结构），哈希 = SHA-512，基于 CommonCrypto 的 CCHmac（公开 API）。
/// salt 传 NULL/0 时按 RFC 5869 用「HashLen 个 0」当盐。
/// outLen 上限 = 255 * 64；超限返回 NO。
BOOL A2RPHKDF_SHA512(const uint8_t *_Nullable ikm, size_t ikmLen,
                     const uint8_t *_Nullable salt, size_t saltLen,
                     const uint8_t *_Nullable info, size_t infoLen,
                     uint8_t *out, size_t outLen);

/// SHA-512 / MD5（CommonCrypto）。入参出参缓冲长度见上方尺寸常量。
BOOL A2RPSHA512(const uint8_t *data, size_t length, uint8_t *out);
BOOL A2RPMD5(const uint8_t *data, size_t length, uint8_t *out);

/// UUIDv3（RFC 4122 §4.3）：MD5(NAMESPACE_DNS || UTF-8(name))，再按规范置版本/变体位。
/// out 为 16 字节缓冲。
BOOL A2RPUUIDv3FromName(NSString *name, uint8_t *out);

// ---------------------------------------------------------------------------
// ★未落地的原语：如实回报（调用方据此走「NotImplemented / 降级」，绝不假成功）★
// ---------------------------------------------------------------------------

/// Ed25519 是否可用（本阶段 = NO；原因见 A2RPHandshakeCryptoUnavailableReason()）。
BOOL A2RPEd25519Available(void);
/// ChaCha20-Poly1305 是否可用（本阶段 = NO）。
BOOL A2RPChaCha20Poly1305Available(void);
/// 未落地原语的可读原因（给日志 / UI 直接用；点名缺什么，不写万能文案）。
NSString *A2RPHandshakeCryptoUnavailableReason(void);

NS_ASSUME_NONNULL_END
