//
//  a2_rppairing_chacha.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [JIT-AUTOPAIR-2] ChaCha20-Poly1305（RFC 8439）自研实现。
//  自研理由见头文件；正确性由 tests/JIT ⑯ 用 RFC 8439 向量 + 25 条独立库生成的随机向量逐位自证。
//

#include "a2_rppairing_chacha.h"

#include <string.h>

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

static uint32_t a2rp_ld32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void a2rp_st32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static void a2rp_st64le(uint8_t *p, uint64_t v) {
    for (int i = 0; i < 8; i++) {
        p[i] = (uint8_t)(v >> (8 * i));
    }
}

static uint32_t a2rp_rotl32(uint32_t x, int n) {
    return (x << n) | (x >> (32 - n));
}

// ---------------------------------------------------------------------------
// ChaCha20（RFC 8439 §2.1–2.4）
// ---------------------------------------------------------------------------

static void a2rp_chacha_qr(uint32_t s[16], int a, int b, int c, int d) {
    s[a] += s[b]; s[d] ^= s[a]; s[d] = a2rp_rotl32(s[d], 16);
    s[c] += s[d]; s[b] ^= s[c]; s[b] = a2rp_rotl32(s[b], 12);
    s[a] += s[b]; s[d] ^= s[a]; s[d] = a2rp_rotl32(s[d], 8);
    s[c] += s[d]; s[b] ^= s[c]; s[b] = a2rp_rotl32(s[b], 7);
}

/// 一个 64 字节密钥流块（state = "expand 32-byte k" ‖ key ‖ counter ‖ nonce）。
static void a2rp_chacha_block(uint8_t out[A2RP_CHACHA_BLOCK_BYTES],
                              const uint8_t key[A2RP_CHACHA_KEY_BYTES],
                              uint32_t counter,
                              const uint8_t nonce[A2RP_CHACHA_NONCE_BYTES]) {
    uint32_t st[16], w[16];
    st[0] = 0x61707865u;   // "expa"
    st[1] = 0x3320646eu;   // "nd 3"
    st[2] = 0x79622d32u;   // "2-by"
    st[3] = 0x6b206574u;   // "te k"
    for (int i = 0; i < 8; i++) {
        st[4 + i] = a2rp_ld32(key + 4 * i);
    }
    st[12] = counter;
    st[13] = a2rp_ld32(nonce);
    st[14] = a2rp_ld32(nonce + 4);
    st[15] = a2rp_ld32(nonce + 8);

    memcpy(w, st, sizeof(w));
    for (int i = 0; i < 10; i++) {           // 20 轮 = 10 次双轮
        a2rp_chacha_qr(w, 0, 4,  8, 12);
        a2rp_chacha_qr(w, 1, 5,  9, 13);
        a2rp_chacha_qr(w, 2, 6, 10, 14);
        a2rp_chacha_qr(w, 3, 7, 11, 15);
        a2rp_chacha_qr(w, 0, 5, 10, 15);
        a2rp_chacha_qr(w, 1, 6, 11, 12);
        a2rp_chacha_qr(w, 2, 7,  8, 13);
        a2rp_chacha_qr(w, 3, 4,  9, 14);
    }
    for (int i = 0; i < 16; i++) {
        a2rp_st32(out + 4 * i, w[i] + st[i]);
    }
}

int A2RPChaCha20XOR(uint8_t *out,
                    const uint8_t *in,
                    size_t len,
                    const uint8_t key[A2RP_CHACHA_KEY_BYTES],
                    uint32_t counter,
                    const uint8_t nonce[A2RP_CHACHA_NONCE_BYTES]) {
    if (out == NULL || key == NULL || nonce == NULL) {
        return 0;
    }
    if (len > 0 && in == NULL) {
        return 0;
    }
    uint8_t ks[A2RP_CHACHA_BLOCK_BYTES];
    size_t off = 0;
    while (off < len) {
        a2rp_chacha_block(ks, key, counter + (uint32_t)(off / A2RP_CHACHA_BLOCK_BYTES), nonce);
        size_t n = len - off;
        if (n > A2RP_CHACHA_BLOCK_BYTES) {
            n = A2RP_CHACHA_BLOCK_BYTES;
        }
        for (size_t i = 0; i < n; i++) {
            out[off + i] = (uint8_t)(in[off + i] ^ ks[i]);
        }
        off += n;
    }
    return 1;
}

// ---------------------------------------------------------------------------
// Poly1305（RFC 8439 §2.5）—— 5×26 位肢体表示
// ---------------------------------------------------------------------------

typedef struct {
    uint32_t r[5];
    uint32_t h[5];
    uint32_t pad[4];
    size_t   leftover;
    uint8_t  buffer[16];
} a2rp_poly1305_ctx;

static void a2rp_poly_init(a2rp_poly1305_ctx *st, const uint8_t key[32]) {
    // 按 RFC 8439 §2.5 的 clamp：清 r 的高位（每 4 字节的高 4 位）与相关低位。
    uint8_t rb[16];
    memcpy(rb, key, 16);
    rb[3] &= 15;  rb[7] &= 15;  rb[11] &= 15;  rb[15] &= 15;
    rb[4] &= 252; rb[8] &= 252; rb[12] &= 252;

    uint32_t t0 = a2rp_ld32(rb + 0), t1 = a2rp_ld32(rb + 4);
    uint32_t t2 = a2rp_ld32(rb + 8), t3 = a2rp_ld32(rb + 12);
    st->r[0] = t0 & 0x3ffffffu;
    st->r[1] = ((t0 >> 26) | (t1 << 6)) & 0x3ffffffu;
    st->r[2] = ((t1 >> 20) | (t2 << 12)) & 0x3ffffffu;
    st->r[3] = ((t2 >> 14) | (t3 << 18)) & 0x3ffffffu;
    st->r[4] = (t3 >> 8) & 0x3ffffffu;

    st->pad[0] = a2rp_ld32(key + 16);
    st->pad[1] = a2rp_ld32(key + 20);
    st->pad[2] = a2rp_ld32(key + 24);
    st->pad[3] = a2rp_ld32(key + 28);

    memset(st->h, 0, sizeof(st->h));
    st->leftover = 0;
}

/// 处理若干【完整】16 字节块（hibit = 2^128 对应的位）。
static void a2rp_poly_blocks(a2rp_poly1305_ctx *st, const uint8_t *m, size_t bytes, uint32_t hibit) {
    uint32_t h0 = st->h[0], h1 = st->h[1], h2 = st->h[2], h3 = st->h[3], h4 = st->h[4];
    uint32_t r0 = st->r[0], r1 = st->r[1], r2 = st->r[2], r3 = st->r[3], r4 = st->r[4];
    uint32_t s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;

    while (bytes >= 16) {
        uint32_t t0 = a2rp_ld32(m + 0), t1 = a2rp_ld32(m + 4);
        uint32_t t2 = a2rp_ld32(m + 8), t3 = a2rp_ld32(m + 12);

        h0 += t0 & 0x3ffffffu;
        h1 += ((t0 >> 26) | (t1 << 6)) & 0x3ffffffu;
        h2 += ((t1 >> 20) | (t2 << 12)) & 0x3ffffffu;
        h3 += ((t2 >> 14) | (t3 << 18)) & 0x3ffffffu;
        h4 += (t3 >> 8) | hibit;

        uint64_t d0 = (uint64_t)h0 * r0 + (uint64_t)h1 * s4 + (uint64_t)h2 * s3
                    + (uint64_t)h3 * s2 + (uint64_t)h4 * s1;
        uint64_t d1 = (uint64_t)h0 * r1 + (uint64_t)h1 * r0 + (uint64_t)h2 * s4
                    + (uint64_t)h3 * s3 + (uint64_t)h4 * s2;
        uint64_t d2 = (uint64_t)h0 * r2 + (uint64_t)h1 * r1 + (uint64_t)h2 * r0
                    + (uint64_t)h3 * s4 + (uint64_t)h4 * s3;
        uint64_t d3 = (uint64_t)h0 * r3 + (uint64_t)h1 * r2 + (uint64_t)h2 * r1
                    + (uint64_t)h3 * r0 + (uint64_t)h4 * s4;
        uint64_t d4 = (uint64_t)h0 * r4 + (uint64_t)h1 * r3 + (uint64_t)h2 * r2
                    + (uint64_t)h3 * r1 + (uint64_t)h4 * r0;

        uint32_t c;
        c = (uint32_t)(d0 >> 26); h0 = (uint32_t)d0 & 0x3ffffffu;
        d1 += c; c = (uint32_t)(d1 >> 26); h1 = (uint32_t)d1 & 0x3ffffffu;
        d2 += c; c = (uint32_t)(d2 >> 26); h2 = (uint32_t)d2 & 0x3ffffffu;
        d3 += c; c = (uint32_t)(d3 >> 26); h3 = (uint32_t)d3 & 0x3ffffffu;
        d4 += c; c = (uint32_t)(d4 >> 26); h4 = (uint32_t)d4 & 0x3ffffffu;
        h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffffu;
        h1 += c;

        m += 16;
        bytes -= 16;
    }

    st->h[0] = h0; st->h[1] = h1; st->h[2] = h2; st->h[3] = h3; st->h[4] = h4;
}

static void a2rp_poly_update(a2rp_poly1305_ctx *st, const uint8_t *m, size_t bytes) {
    if (bytes == 0) {
        return;
    }
    // 先把上轮残留补满一块
    if (st->leftover) {
        size_t want = 16 - st->leftover;
        if (want > bytes) {
            want = bytes;
        }
        memcpy(st->buffer + st->leftover, m, want);
        st->leftover += want;
        m += want;
        bytes -= want;
        if (st->leftover == 16) {
            a2rp_poly_blocks(st, st->buffer, 16, 1u << 24);
            st->leftover = 0;
        }
    }
    // 整块
    size_t full = bytes - (bytes % 16);
    if (full) {
        a2rp_poly_blocks(st, m, full, 1u << 24);
        m += full;
        bytes -= full;
    }
    // 尾巴
    if (bytes) {
        memcpy(st->buffer, m, bytes);
        st->leftover = bytes;
    }
}

/// 该次消息的全部输入必须已按 16 字节对齐送入（AEAD 路径保证），
/// 若还有残留则按 RFC 8439 §2.5.1「最后一块后补 1 字节 0x01」处理。
static void a2rp_poly_finish(a2rp_poly1305_ctx *st, uint8_t mac[16]) {
    if (st->leftover) {
        st->buffer[st->leftover] = 1;
        memset(st->buffer + st->leftover + 1, 0, 16 - st->leftover - 1);
        a2rp_poly_blocks(st, st->buffer, 16, 0);
    }

    uint32_t h0 = st->h[0], h1 = st->h[1], h2 = st->h[2], h3 = st->h[3], h4 = st->h[4];
    uint32_t c;

    // 完全进位
    c = h1 >> 26; h1 &= 0x3ffffffu;
    h2 += c; c = h2 >> 26; h2 &= 0x3ffffffu;
    h3 += c; c = h3 >> 26; h3 &= 0x3ffffffu;
    h4 += c; c = h4 >> 26; h4 &= 0x3ffffffu;
    h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffffu;
    h1 += c;

    // 计算 h + -p
    uint32_t g0 = h0 + 5; c = g0 >> 26; g0 &= 0x3ffffffu;
    uint32_t g1 = h1 + c; c = g1 >> 26; g1 &= 0x3ffffffu;
    uint32_t g2 = h2 + c; c = g2 >> 26; g2 &= 0x3ffffffu;
    uint32_t g3 = h3 + c; c = g3 >> 26; g3 &= 0x3ffffffu;
    uint32_t g4 = h4 + c - (1u << 26);

    // h < p 则保留 h，否则取 g（常数时间选择）
    uint32_t mask = (g4 >> 31) - 1;
    g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
    mask = ~mask;
    h0 = (h0 & mask) | g0;
    h1 = (h1 & mask) | g1;
    h2 = (h2 & mask) | g2;
    h3 = (h3 & mask) | g3;
    h4 = (h4 & mask) | g4;

    // h = (h + pad) mod 2^128
    uint64_t f;
    f = ((uint64_t)(h0 | (h1 << 26))         & 0xffffffffu) + st->pad[0];
    uint32_t o0 = (uint32_t)f;
    f = ((uint64_t)((h1 >> 6) | (h2 << 20))  & 0xffffffffu) + st->pad[1] + (f >> 32);
    uint32_t o1 = (uint32_t)f;
    f = ((uint64_t)((h2 >> 12) | (h3 << 14)) & 0xffffffffu) + st->pad[2] + (f >> 32);
    uint32_t o2 = (uint32_t)f;
    f = ((uint64_t)((h3 >> 18) | (h4 << 8))  & 0xffffffffu) + st->pad[3] + (f >> 32);
    uint32_t o3 = (uint32_t)f;

    a2rp_st32(mac + 0, o0);
    a2rp_st32(mac + 4, o1);
    a2rp_st32(mac + 8, o2);
    a2rp_st32(mac + 12, o3);
}

// ---------------------------------------------------------------------------
// AEAD（RFC 8439 §2.8）
// ---------------------------------------------------------------------------

static void a2rp_poly_pad16(a2rp_poly1305_ctx *st, size_t n) {
    static const uint8_t zero[16] = { 0 };
    size_t r = n % 16;
    if (r != 0) {
        a2rp_poly_update(st, zero, 16 - r);
    }
}

static void a2rp_aead_tag(uint8_t tag[16],
                          const uint8_t polyKey[32],
                          const uint8_t *aad, size_t aadLen,
                          const uint8_t *ct, size_t ctLen) {
    a2rp_poly1305_ctx st;
    a2rp_poly_init(&st, polyKey);
    a2rp_poly_update(&st, aad, aadLen);
    a2rp_poly_pad16(&st, aadLen);
    a2rp_poly_update(&st, ct, ctLen);
    a2rp_poly_pad16(&st, ctLen);
    uint8_t lens[16];
    a2rp_st64le(lens, (uint64_t)aadLen);
    a2rp_st64le(lens + 8, (uint64_t)ctLen);
    a2rp_poly_update(&st, lens, 16);
    a2rp_poly_finish(&st, tag);
}

int A2RPChaCha20Poly1305Seal(uint8_t *ctOut,
                             uint8_t tagOut[A2RP_AEAD_TAG_BYTES],
                             const uint8_t key[A2RP_CHACHA_KEY_BYTES],
                             const uint8_t nonce[A2RP_CHACHA_NONCE_BYTES],
                             const uint8_t *aad, size_t aadLen,
                             const uint8_t *pt, size_t ptLen) {
    if (ctOut == NULL || tagOut == NULL || key == NULL || nonce == NULL) {
        return 0;
    }
    if ((aadLen > 0 && aad == NULL) || (ptLen > 0 && pt == NULL)) {
        return 0;
    }

    uint8_t otk[A2RP_CHACHA_BLOCK_BYTES];
    a2rp_chacha_block(otk, key, 0, nonce);            // counter=0 ⇒ Poly1305 一次性密钥
    if (ptLen > 0) {
        if (!A2RPChaCha20XOR(ctOut, pt, ptLen, key, 1, nonce)) {   // counter=1 起加密
            return 0;
        }
    }
    a2rp_aead_tag(tagOut, otk, aad, aadLen, ctOut, ptLen);
    memset(otk, 0, sizeof(otk));
    return 1;
}

/// 常数时间比较（不同 ⇒ 0）。
static int a2rp_ct_eq(const uint8_t *a, const uint8_t *b, size_t n) {
    uint8_t acc = 0;
    for (size_t i = 0; i < n; i++) {
        acc |= (uint8_t)(a[i] ^ b[i]);
    }
    return acc == 0;
}

int A2RPChaCha20Poly1305Open(uint8_t *ptOut,
                             const uint8_t key[A2RP_CHACHA_KEY_BYTES],
                             const uint8_t nonce[A2RP_CHACHA_NONCE_BYTES],
                             const uint8_t *aad, size_t aadLen,
                             const uint8_t *ct, size_t ctLen,
                             const uint8_t tag[A2RP_AEAD_TAG_BYTES]) {
    if (ptOut == NULL || key == NULL || nonce == NULL || tag == NULL) {
        return 0;
    }
    if ((aadLen > 0 && aad == NULL) || (ctLen > 0 && ct == NULL)) {
        return 0;
    }

    uint8_t otk[A2RP_CHACHA_BLOCK_BYTES];
    a2rp_chacha_block(otk, key, 0, nonce);

    uint8_t expect[16];
    a2rp_aead_tag(expect, otk, aad, aadLen, ct, ctLen);
    memset(otk, 0, sizeof(otk));

    if (!a2rp_ct_eq(expect, tag, 16)) {
        return 0;                                     // ★认证失败 ⇒ 不写明文、不假成功★
    }
    if (ctLen > 0) {
        return A2RPChaCha20XOR(ptOut, ct, ctLen, key, 1, nonce);
    }
    return 1;
}
