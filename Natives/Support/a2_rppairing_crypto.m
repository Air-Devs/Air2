//
//  a2_rppairing_crypto.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [JIT-AUTOPAIR-2] 系统密码学原语薄封装实现。
//  ★只用系统库★：CommonCrypto（CCHmac / CC_MD5 / CC_SHA512，公开头）+ SecRandom（公开头）
//  + corecrypto 的 cccurve25519（libSystem 导出，无公开头 ⇒ 见下方原型声明与实测依据）。
//  ★零第三方依赖、未搬运任何外部项目代码★。
//

#import "a2_rppairing_crypto.h"

#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <Security/Security.h>

#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------
// 系统 corecrypto 原语的【原型自声明】
// ---------------------------------------------------------------------------
// 依据：libSystem 导出符号（i386/arm64 均导出），无公开头文件。
// 签名以 RFC 向量实测确定（探针程序 /tmp/a2_rpc_probe2.c）：
//   - 三参形式 cccurve25519(sk, privkey, pubkey) 对 RFC 7748 §5.2 向量
//     (priv=a546…9ac4, pub=e6db…1c4c) 得 c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552 ✓；
//     X25519(9,9) 得 422c8e7a…11ae3079 ✓。
//   - 四参形式（首参为 cccurve25519_ctx）在本机 SIGSEGV ⇒ 本平台为三参形式。
// 若将来系统改签名，本文件的 RFC 7748 自证会立刻失败（tests/JIT 会红），不会静默出错。
extern int cccurve25519(uint8_t *session_key,
                        const uint8_t *private_key,
                        const uint8_t *public_key);

/// RFC 7748 定义的 X25519 基点 u=9（其余 31 字节为 0）。
static const uint8_t kA2RPX25519BasePoint[A2RP_X25519_KEY_BYTES] = { 9 };

/// RFC 4122 §4.3 的 NAMESPACE_DNS = 6ba7b810-9dad-11d1-80b4-00c04fd430c8。
static const uint8_t kA2RPNamespaceDNS[16] = {
    0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1,
    0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8
};

#pragma mark - 随机数

BOOL A2RPRandomBytes(void *buffer, size_t length) {
    if (buffer == NULL || length == 0) {
        return NO;
    }
    return SecRandomCopyBytes(kSecRandomDefault, length, buffer) == errSecSuccess;
}

#pragma mark - X25519（RFC 7748）

BOOL A2RPX25519(uint8_t *out,
                const uint8_t *privkey,
                const uint8_t *pubkey) {
    if (out == NULL || privkey == NULL || pubkey == NULL) {
        return NO;
    }
    // 返回值 0 = 成功（corecrypto 约定）。
    return cccurve25519(out, privkey, pubkey) == 0;
}

BOOL A2RPX25519PublicKey(uint8_t *out,
                         const uint8_t *privkey) {
    // 公钥 = 私钥对基点的标量乘（RFC 7748 §5）。
    return A2RPX25519(out, privkey, kA2RPX25519BasePoint);
}

#pragma mark - HKDF-SHA512（RFC 5869）

BOOL A2RPHKDF_SHA512(const uint8_t *_Nullable ikm, size_t ikmLen,
                     const uint8_t *_Nullable salt, size_t saltLen,
                     const uint8_t *_Nullable info, size_t infoLen,
                     uint8_t *out, size_t outLen) {
    if (out == NULL || outLen == 0) {
        return NO;
    }
    if (outLen > (size_t)255 * A2RP_SHA512_BYTES) {
        return NO;   // RFC 5869 §2.3 的 L 上限
    }

    // ---- Extract ----
    // salt 缺省 = HashLen 个 0 字节（RFC 5869 §2.2）。
    uint8_t zeroSalt[A2RP_SHA512_BYTES] = { 0 };
    const uint8_t *useSalt = salt;
    size_t useSaltLen = saltLen;
    if (salt == NULL || saltLen == 0) {
        useSalt = zeroSalt;
        useSaltLen = A2RP_SHA512_BYTES;
    }
    uint8_t prk[A2RP_SHA512_BYTES];
    CCHmac(kCCHmacAlgSHA512, useSalt, useSaltLen,
           ikm ? ikm : (const uint8_t *)"", ikmLen, prk);

    // ---- Expand ----
    // T(i) = HMAC(prk, T(i-1) | info | i)，逐块拼接至 outLen。
    uint8_t t[A2RP_SHA512_BYTES];
    size_t tLen = 0;
    size_t produced = 0;
    uint8_t counter = 1;
    while (produced < outLen) {
        CCHmacContext ctx;
        CCHmacInit(&ctx, kCCHmacAlgSHA512, prk, A2RP_SHA512_BYTES);
        if (tLen > 0) {
            CCHmacUpdate(&ctx, t, tLen);
        }
        if (info != NULL && infoLen > 0) {
            CCHmacUpdate(&ctx, info, infoLen);
        }
        CCHmacUpdate(&ctx, &counter, 1);
        CCHmacFinal(&ctx, t);
        tLen = A2RP_SHA512_BYTES;

        size_t take = outLen - produced;
        if (take > A2RP_SHA512_BYTES) {
            take = A2RP_SHA512_BYTES;
        }
        memcpy(out + produced, t, take);
        produced += take;
        counter += 1;
    }
    // 抹掉中间态（best-effort；编译器可能优化掉，此处只为降低驻留窗口）。
    memset(prk, 0, sizeof(prk));
    memset(t, 0, sizeof(t));
    return YES;
}

#pragma mark - 摘要

BOOL A2RPSHA512(const uint8_t *data, size_t length, uint8_t *out) {
    if (out == NULL) {
        return NO;
    }
    // 用流式 API（非弃用形式），避免 CC_SHA512() 一次性接口在新 SDK 上的弃用告警。
    CC_SHA512_CTX ctx;
    if (CC_SHA512_Init(&ctx) != 1) {
        return NO;
    }
    if (length > 0 && data != NULL) {
        CC_SHA512_Update(&ctx, data, (CC_LONG)length);
    }
    return CC_SHA512_Final(out, &ctx) == 1;
}

// MD5 在 iOS 13+/macOS 10.15+ 被标弃用，但 RFC 4122 UUIDv3 的算法【就是】MD5 —— 这里不是拿它做
// 安全用途，而是复现协议规定的标识符派生。为免把「与本次改动无关」的弃用告警带进构建，
// 只在本函数范围内显式抑制该告警（其余文件不受影响）。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
BOOL A2RPMD5(const uint8_t *data, size_t length, uint8_t *out) {
    if (out == NULL) {
        return NO;
    }
    CC_MD5_CTX ctx;
    if (CC_MD5_Init(&ctx) != 1) {
        return NO;
    }
    if (length > 0 && data != NULL) {
        CC_MD5_Update(&ctx, data, (CC_LONG)length);
    }
    return CC_MD5_Final(out, &ctx) == 1;
}
#pragma clang diagnostic pop

#pragma mark - UUIDv3

BOOL A2RPUUIDv3FromName(NSString *name, uint8_t out[16]) {
    if (name == nil || out == NULL) {
        return NO;
    }
    NSData *nameBytes = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (nameBytes == nil) {
        return NO;
    }
    // digest 输入 = NAMESPACE_DNS(16) || name（用 malloc 而非 VLA，避免变长数组告警）。
    size_t total = 16 + nameBytes.length;
    uint8_t *buf = (uint8_t *)malloc(total);
    if (buf == NULL) {
        return NO;
    }
    memcpy(buf, kA2RPNamespaceDNS, 16);
    if (nameBytes.length > 0) {
        memcpy(buf + 16, nameBytes.bytes, nameBytes.length);
    }
    BOOL ok = A2RPMD5(buf, total, out);
    free(buf);
    if (!ok) {
        return NO;
    }
    // RFC 4122 §4.3：版本位置 3，变体位 10xx。
    out[6] = (uint8_t)((out[6] & 0x0F) | 0x30);
    out[8] = (uint8_t)((out[8] & 0x3F) | 0x80);
    return YES;
}

#pragma mark - 未落地原语的如实回报

BOOL A2RPEd25519Available(void) {
    // ★如实回 NO★：cced25519_* 符号在 libSystem 中存在，但 cced25519_ctx 无公开初始化路径
    // （实测：ctx 传 NULL 或自备缓冲均失败/崩溃，cced25519_ctx_size/ctx_new 符号不存在）⇒
    // 签名/验签的驱动方式未确认完成，本阶段不落地、不猜、不假成功。
    return NO;
}

BOOL A2RPChaCha20Poly1305Available(void) {
    // ★如实回 NO★：ccchacha20poly1305_{encrypt,decrypt}_oneshot 需要一个 corecrypto
    // 的 info 结构，其获取方式未确认（实测调用崩溃）⇒ 本阶段不落地。
    return NO;
}

NSString *A2RPHandshakeCryptoUnavailableReason(void) {
    return @"RPPairing 握手的 Ed25519(签名) 与 ChaCha20-Poly1305(AEAD) 原语尚未落地："
           @"Objective-C 侧无 Curve25519/Ed25519 公开 API（CryptoKit 为 Swift-only），"
           @"libSystem 虽导出 cced25519_*/ccchacha20poly1305_* 符号，但其 ctx/info 结构无公开"
           @"初始化路径（实测不可驱动）⇒ 需先决定「引入 Swift/CryptoKit」或「落地可自证的私有符号桥」"
           @"（见 docs/JIT-PROVISIONING.md §4.2-a）。X25519/HKDF-SHA512 已落地并自证。";
}
