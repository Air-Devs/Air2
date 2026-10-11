//
//  a2_rppairing_ed25519.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [JIT-AUTOPAIR-2] Ed25519（RFC 8032 §5.1）自研实现。
//
//  结构：
//    · 域运算  —— 5×51 位肢体（uint64_t），乘法用 unsigned __int128 教科书式落幂后按 2^51 归约；
//    · 曲线运算 —— 扭曲爱德华兹曲线（a=-1）的**扩展坐标**（X:Y:Z:T）；加法/倍点用公开的标准公式；
//      标量乘 = 朴素 MSB-first「倍点-加点」（★非常数时间，见头文件声明★）；
//    · 标量运算 —— mod L 的归约用「逐位 2 倍 + 条件减」的直白算法（512 次循环，正确性一眼可查）。
//
//  ★所有常量都不是我手推的★：d、sqrt(-1)、(p-2)、(p-5)/8、L 都由 Python 用整数运算算出后按字节写入
//  （见报告 §验证），且 d 与 sqrt(-1) 的取值与公开已知值一致（自证见 tests/JIT ⑯）。
//
//  正确性验收：RFC 8032 §7.1 TEST 1/2/3（公钥 + 签名逐位）+ 24 条 PyNaCl(libsodium) 随机向量。
//

#include "a2_rppairing_ed25519.h"

#include <string.h>
#include <CommonCrypto/CommonDigest.h>

// ---------------------------------------------------------------------------
// 常量（Python 整数运算生成；little-endian 字节序）
// ---------------------------------------------------------------------------

/// d = -121665/121666 mod p
static const uint8_t A2RP_K_D[32] = {
    0xa3, 0x78, 0x59, 0x13, 0xca, 0x4d, 0xeb, 0x75, 0xab, 0xd8, 0x41, 0x41,
    0x4d, 0x0a, 0x70, 0x00, 0x98, 0xe8, 0x79, 0x77, 0x79, 0x40, 0xc7, 0x8c,
    0x73, 0xfe, 0x6f, 0x2b, 0xee, 0x6c, 0x03, 0x52
};

/// sqrt(-1) = 2^((p-1)/4) mod p
static const uint8_t A2RP_K_SQRTM1[32] = {
    0xb0, 0xa0, 0x0e, 0x4a, 0x27, 0x1b, 0xee, 0xc4, 0x78, 0xe4, 0x2f, 0xad,
    0x06, 0x18, 0x43, 0x2f, 0xa7, 0xd7, 0xfb, 0x3d, 0x99, 0x00, 0x4d, 0x2b,
    0x0b, 0xdf, 0xc1, 0x4f, 0x80, 0x24, 0x83, 0x2b
};

/// p - 2（求逆的费马指数）
static const uint8_t A2RP_K_EXP_INV[32] = {
    0xeb, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f
};

/// (p - 5)/8（开方的指数）
static const uint8_t A2RP_K_EXP_SQRT[32] = {
    0xfd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f
};

/// 基点 B 的压缩编码（y = 4/5，x 为偶）
static const uint8_t A2RP_K_BASE_ENC[32] = {
    0x58, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
    0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
    0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66
};

/// 群阶 L = 2^252 + 27742317777372353535851937790883648493（用 4 个 64 位肢体表示）
static const uint64_t A2RP_K_L_LIMBS[4] = {
    0x5812631a5cf5d3edULL, 0x14def9dea2f79cd6ULL, 0x0000000000000000ULL, 0x1000000000000000ULL
};

// ---------------------------------------------------------------------------
// 域运算（5×51 位肢体）
// ---------------------------------------------------------------------------

typedef uint64_t a2rp_fe[5];

#define A2RP_FE_MASK51 0x7ffffffffffffULL

static uint64_t a2rp_load64le(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) {
        v = (v << 8) | p[i];
    }
    return v;
}

static void a2rp_fe_zero(a2rp_fe h) { memset(h, 0, sizeof(a2rp_fe)); }
static void a2rp_fe_one(a2rp_fe h)  { memset(h, 0, sizeof(a2rp_fe)); h[0] = 1; }

static void a2rp_fe_frombytes(a2rp_fe h, const uint8_t s[32]) {
    h[0] = a2rp_load64le(s + 0) & A2RP_FE_MASK51;
    h[1] = (a2rp_load64le(s + 6) >> 3) & A2RP_FE_MASK51;
    h[2] = (a2rp_load64le(s + 12) >> 6) & A2RP_FE_MASK51;
    h[3] = (a2rp_load64le(s + 19) >> 1) & A2RP_FE_MASK51;
    h[4] = (a2rp_load64le(s + 24) >> 12) & A2RP_FE_MASK51;   // 高于 2^255 的位被丢掉（RFC 8032 的 y 只有 255 位）
}

/// 单趟完全进位（并把顶肢溢出折回 2^0 的 *19）
static void a2rp_fe_carry(a2rp_fe h) {
    uint64_t c;
    c = h[0] >> 51; h[0] &= A2RP_FE_MASK51; h[1] += c;
    c = h[1] >> 51; h[1] &= A2RP_FE_MASK51; h[2] += c;
    c = h[2] >> 51; h[2] &= A2RP_FE_MASK51; h[3] += c;
    c = h[3] >> 51; h[3] &= A2RP_FE_MASK51; h[4] += c;
    c = h[4] >> 51; h[4] &= A2RP_FE_MASK51; h[0] += c * 19;
    c = h[0] >> 51; h[0] &= A2RP_FE_MASK51; h[1] += c;
}

static void a2rp_fe_add(a2rp_fe h, const a2rp_fe f, const a2rp_fe g) {
    for (int i = 0; i < 5; i++) {
        h[i] = f[i] + g[i];
    }
}

/// h = f - g（先把 g 抬 2p 再减，保证非负；结果 ∈ [0, 2^52)）
static void a2rp_fe_sub(a2rp_fe h, const a2rp_fe f, const a2rp_fe g) {
    static const uint64_t two_p[5] = {
        0xfffffffffffdaULL, 0xffffffffffffeULL, 0xffffffffffffeULL,
        0xffffffffffffeULL, 0xffffffffffffeULL
    };
    for (int i = 0; i < 5; i++) {
        h[i] = f[i] + two_p[i] - g[i];
    }
}

static void a2rp_fe_neg(a2rp_fe h, const a2rp_fe f) {
    a2rp_fe z;
    a2rp_fe_zero(z);
    a2rp_fe_sub(h, z, f);
}

static void a2rp_fe_mul(a2rp_fe h, const a2rp_fe f, const a2rp_fe g) {
    uint64_t f0 = f[0], f1 = f[1], f2 = f[2], f3 = f[3], f4 = f[4];
    uint64_t g0 = g[0], g1 = g[1], g2 = g[2], g3 = g[3], g4 = g[4];
    uint64_t g1_19 = 19 * g1, g2_19 = 19 * g2, g3_19 = 19 * g3, g4_19 = 19 * g4;
    unsigned __int128 t0, t1, t2, t3, t4;
    uint64_t c;

    t0 = (unsigned __int128)f0 * g0 + (unsigned __int128)f1 * g4_19
       + (unsigned __int128)f2 * g3_19 + (unsigned __int128)f3 * g2_19
       + (unsigned __int128)f4 * g1_19;
    t1 = (unsigned __int128)f0 * g1 + (unsigned __int128)f1 * g0
       + (unsigned __int128)f2 * g4_19 + (unsigned __int128)f3 * g3_19
       + (unsigned __int128)f4 * g2_19;
    t2 = (unsigned __int128)f0 * g2 + (unsigned __int128)f1 * g1
       + (unsigned __int128)f2 * g0 + (unsigned __int128)f3 * g4_19
       + (unsigned __int128)f4 * g3_19;
    t3 = (unsigned __int128)f0 * g3 + (unsigned __int128)f1 * g2
       + (unsigned __int128)f2 * g1 + (unsigned __int128)f3 * g0
       + (unsigned __int128)f4 * g4_19;
    t4 = (unsigned __int128)f0 * g4 + (unsigned __int128)f1 * g3
       + (unsigned __int128)f2 * g2 + (unsigned __int128)f3 * g1
       + (unsigned __int128)f4 * g0;

    c = (uint64_t)(t0 >> 51); t0 &= A2RP_FE_MASK51; t1 += c;
    c = (uint64_t)(t1 >> 51); t1 &= A2RP_FE_MASK51; t2 += c;
    c = (uint64_t)(t2 >> 51); t2 &= A2RP_FE_MASK51; t3 += c;
    c = (uint64_t)(t3 >> 51); t3 &= A2RP_FE_MASK51; t4 += c;
    c = (uint64_t)(t4 >> 51); t4 &= A2RP_FE_MASK51; t0 += c * 19;
    c = (uint64_t)(t0 >> 51); t0 &= A2RP_FE_MASK51; t1 += c;

    h[0] = (uint64_t)t0; h[1] = (uint64_t)t1; h[2] = (uint64_t)t2;
    h[3] = (uint64_t)t3; h[4] = (uint64_t)t4;
}

static void a2rp_fe_sq(a2rp_fe h, const a2rp_fe f) {
    a2rp_fe_mul(h, f, f);
}

static void a2rp_fe_tobytes(uint8_t s[32], const a2rp_fe f) {
    a2rp_fe t;
    memcpy(t, f, sizeof(t));
    a2rp_fe_carry(t);
    a2rp_fe_carry(t);

    // 条件减 p：t + 19 若溢出 2^255，说明 t ≥ p
    uint64_t u0 = t[0] + 19, c = u0 >> 51; u0 &= A2RP_FE_MASK51;
    uint64_t u1 = t[1] + c;  c = u1 >> 51; u1 &= A2RP_FE_MASK51;
    uint64_t u2 = t[2] + c;  c = u2 >> 51; u2 &= A2RP_FE_MASK51;
    uint64_t u3 = t[3] + c;  c = u3 >> 51; u3 &= A2RP_FE_MASK51;
    uint64_t u4 = t[4] + c;  c = u4 >> 51; u4 &= A2RP_FE_MASK51;

    uint64_t mask = (uint64_t)0 - c;           // c==1 ⇒ 全 1
    uint64_t v0 = (t[0] & ~mask) | (u0 & mask);
    uint64_t v1 = (t[1] & ~mask) | (u1 & mask);
    uint64_t v2 = (t[2] & ~mask) | (u2 & mask);
    uint64_t v3 = (t[3] & ~mask) | (u3 & mask);
    uint64_t v4 = (t[4] & ~mask) | (u4 & mask);

    uint64_t b0 = v0 | (v1 << 51);
    uint64_t b1 = (v1 >> 13) | (v2 << 38);
    uint64_t b2 = (v2 >> 26) | (v3 << 25);
    uint64_t b3 = (v3 >> 39) | (v4 << 12);
    for (int i = 0; i < 8; i++) {
        s[i]      = (uint8_t)(b0 >> (8 * i));
        s[8 + i]  = (uint8_t)(b1 >> (8 * i));
        s[16 + i] = (uint8_t)(b2 >> (8 * i));
        s[24 + i] = (uint8_t)(b3 >> (8 * i));
    }
}

static int a2rp_fe_eq(const a2rp_fe f, const a2rp_fe g) {
    uint8_t a[32], b[32];
    a2rp_fe_tobytes(a, f);
    a2rp_fe_tobytes(b, g);
    uint8_t acc = 0;
    for (int i = 0; i < 32; i++) {
        acc |= (uint8_t)(a[i] ^ b[i]);
    }
    return acc == 0;
}

/// h = f^exp（exp 为 32 字节小端指数）——朴素「平方-乘」，256 位全扫。
static void a2rp_fe_pow(a2rp_fe h, const a2rp_fe f, const uint8_t exp[32]) {
    a2rp_fe r, base;
    memcpy(base, f, sizeof(a2rp_fe));
    a2rp_fe_one(r);
    int started = 0;
    for (int i = 255; i >= 0; i--) {
        int bit = (exp[i >> 3] >> (i & 7)) & 1;
        if (started) {
            a2rp_fe_sq(r, r);
        }
        if (bit) {
            a2rp_fe_mul(r, r, base);
            started = 1;
        }
    }
    memcpy(h, r, sizeof(a2rp_fe));
}

static void a2rp_fe_invert(a2rp_fe h, const a2rp_fe f) {
    a2rp_fe_pow(h, f, A2RP_K_EXP_INV);
}

// ---------------------------------------------------------------------------
// 曲线运算（扩展坐标 X:Y:Z:T，a = -1）
// ---------------------------------------------------------------------------

typedef struct {
    a2rp_fe X, Y, Z, T;
} a2rp_ge;

static void a2rp_ge_identity(a2rp_ge *p) {
    a2rp_fe_zero(p->X);
    a2rp_fe_one(p->Y);
    a2rp_fe_one(p->Z);
    a2rp_fe_zero(p->T);
}

/// r = p + q（统一加法公式，扩展坐标；对 a = -1 的扭曲爱德华兹曲线）
static void a2rp_ge_add(a2rp_ge *r, const a2rp_ge *p, const a2rp_ge *q) {
    a2rp_fe d_fe, two_d, A, B, C, D, E, F, G, H, t1, t2;
    a2rp_fe_frombytes(d_fe, A2RP_K_D);
    a2rp_fe_add(two_d, d_fe, d_fe);

    a2rp_fe_sub(t1, p->Y, p->X); a2rp_fe_sub(t2, q->Y, q->X); a2rp_fe_mul(A, t1, t2);
    a2rp_fe_add(t1, p->Y, p->X); a2rp_fe_add(t2, q->Y, q->X); a2rp_fe_mul(B, t1, t2);
    a2rp_fe_mul(t1, p->T, q->T);  a2rp_fe_mul(C, t1, two_d);
    a2rp_fe_mul(t1, p->Z, q->Z);  a2rp_fe_add(D, t1, t1);

    a2rp_fe_sub(E, B, A);
    a2rp_fe_sub(F, D, C);
    a2rp_fe_add(G, D, C);
    a2rp_fe_add(H, B, A);

    a2rp_fe_mul(r->X, E, F);
    a2rp_fe_mul(r->Y, G, H);
    a2rp_fe_mul(r->T, E, H);
    a2rp_fe_mul(r->Z, F, G);
}

/// r = 2p（倍点公式）
static void a2rp_ge_dbl(a2rp_ge *r, const a2rp_ge *p) {
    a2rp_fe A, B, C, D, E, F, G, H, t1, t2;
    a2rp_fe_sq(A, p->X);
    a2rp_fe_sq(B, p->Y);
    a2rp_fe_sq(C, p->Z); a2rp_fe_add(C, C, C);
    a2rp_fe_neg(D, A);                                   // a = -1
    a2rp_fe_add(t1, p->X, p->Y); a2rp_fe_sq(t2, t1);
    a2rp_fe_sub(t2, t2, A); a2rp_fe_sub(E, t2, B);       // E = (X+Y)^2 - A - B
    a2rp_fe_sub(G, B, A);                                // G = D + B
    a2rp_fe_sub(F, G, C);
    a2rp_fe_sub(H, D, B);                                // H = D - B

    a2rp_fe_mul(r->X, E, F);
    a2rp_fe_mul(r->Y, G, H);
    a2rp_fe_mul(r->T, E, H);
    a2rp_fe_mul(r->Z, F, G);
}

/// r = scalar * p（朴素 MSB-first；★非常数时间★）
static void a2rp_ge_scalarmult(a2rp_ge *r, const a2rp_ge *p, const uint8_t scalar[32]) {
    a2rp_ge acc, base;
    a2rp_ge_identity(&acc);
    memcpy(&base, p, sizeof(base));
    for (int i = 255; i >= 0; i--) {
        a2rp_ge_dbl(&acc, &acc);
        if ((scalar[i >> 3] >> (i & 7)) & 1) {
            a2rp_ge_add(&acc, &acc, &base);
        }
    }
    memcpy(r, &acc, sizeof(acc));
}

/// 压缩编码（RFC 8032 §5.1.2）：y 的 255 位 + x 的最低位进最高位
static void a2rp_ge_tobytes(uint8_t s[32], const a2rp_ge *p) {
    a2rp_fe zinv, x, y;
    uint8_t xs[32];
    a2rp_fe_invert(zinv, p->Z);
    a2rp_fe_mul(x, p->X, zinv);
    a2rp_fe_mul(y, p->Y, zinv);
    a2rp_fe_tobytes(s, y);
    a2rp_fe_tobytes(xs, x);
    s[31] ^= (uint8_t)((xs[0] & 1) << 7);
}

/// 解压（RFC 8032 §5.1.3）。失败（y 不是曲线上的点）⇒ 0。
static int a2rp_ge_frombytes(a2rp_ge *p, const uint8_t s[32]) {
    a2rp_fe y, yy, one, u, v, v3, t, check, x, sqrtm1;
    uint8_t ys[32];
    memcpy(ys, s, 32);
    int sign = ys[31] >> 7;
    ys[31] &= 0x7f;

    a2rp_fe_frombytes(y, ys);
    a2rp_fe_frombytes(sqrtm1, A2RP_K_SQRTM1);
    a2rp_fe_one(one);

    a2rp_fe_sq(yy, y);
    a2rp_fe_sub(u, yy, one);                     // u = y^2 - 1
    {
        a2rp_fe d_fe;
        a2rp_fe_frombytes(d_fe, A2RP_K_D);
        a2rp_fe_mul(v, yy, d_fe);
        a2rp_fe_add(v, v, one);                  // v = d*y^2 + 1
    }

    a2rp_fe_sq(t, v); a2rp_fe_mul(v3, t, v);     // v^3
    a2rp_fe_mul(t, v3, u);                       // t = u * v^3
    a2rp_fe_sq(check, v3); a2rp_fe_mul(check, check, v);   // v^7
    a2rp_fe_mul(check, check, u);                // u * v^7
    a2rp_fe_pow(check, check, A2RP_K_EXP_SQRT);
    a2rp_fe_mul(x, t, check);                    // 候选 x

    a2rp_fe_sq(check, x); a2rp_fe_mul(check, check, v);
    if (!a2rp_fe_eq(check, u)) {
        a2rp_fe_mul(x, x, sqrtm1);               // 试乘以 sqrt(-1)
        a2rp_fe_sq(check, x); a2rp_fe_mul(check, check, v);
        if (!a2rp_fe_eq(check, u)) {
            return 0;                            // 非曲线点
        }
    }

    uint8_t xs[32];
    a2rp_fe_tobytes(xs, x);
    if ((xs[0] & 1) != (uint8_t)sign) {
        a2rp_fe_neg(x, x);
    }

    memcpy(p->X, x, sizeof(a2rp_fe));
    memcpy(p->Y, y, sizeof(a2rp_fe));
    a2rp_fe_one(p->Z);
    a2rp_fe_mul(p->T, x, y);
    return 1;
}

static int a2rp_ge_base(a2rp_ge *B) {
    return a2rp_ge_frombytes(B, A2RP_K_BASE_ENC);
}

// ---------------------------------------------------------------------------
// 标量运算 mod L（直白实现：逐位 2 倍 + 条件减）
// ---------------------------------------------------------------------------

static int a2rp_sc_ge_l(const uint64_t a[4]) {
    for (int i = 3; i >= 0; i--) {
        if (a[i] > A2RP_K_L_LIMBS[i]) return 1;
        if (a[i] < A2RP_K_L_LIMBS[i]) return 0;
    }
    return 1;                                    // 相等也算 ≥
}

static void a2rp_sc_sub_l(uint64_t a[4]) {
    uint64_t borrow = 0;
    for (int i = 0; i < 4; i++) {
        uint64_t sub = A2RP_K_L_LIMBS[i] + borrow;
        uint64_t old = a[i];
        a[i] = old - sub;
        borrow = (old < sub) ? 1 : 0;
    }
}

/// 把 nbits 位的大整数（小端肢体）按位归约 mod L。
static void a2rp_sc_reduce_bits(const uint64_t *x, int nbits, uint64_t out[4]) {
    uint64_t acc[4] = { 0, 0, 0, 0 };
    for (int i = nbits - 1; i >= 0; i--) {
        uint64_t carry = (x[i >> 6] >> (i & 63)) & 1;
        for (int j = 0; j < 4; j++) {
            uint64_t nc = acc[j] >> 63;
            acc[j] = (acc[j] << 1) | carry;
            carry = nc;
        }
        // carry 必为 0：acc < L < 2^253 ⇒ 2*acc+1 < 2^254
        if (a2rp_sc_ge_l(acc)) {
            a2rp_sc_sub_l(acc);
        }
    }
    memcpy(out, acc, sizeof(uint64_t) * 4);
}

static void a2rp_sc_store(uint8_t out[32], const uint64_t r[4]) {
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 8; j++) {
            out[8 * i + j] = (uint8_t)(r[i] >> (8 * j));
        }
    }
}

/// out = SHA512 的 64 字节 → mod L（32 字节）
static void a2rp_sc_reduce64(uint8_t out[32], const uint8_t in64[64]) {
    uint64_t x[8];
    for (int i = 0; i < 8; i++) {
        x[i] = a2rp_load64le(in64 + 8 * i);
    }
    uint64_t r[4];
    a2rp_sc_reduce_bits(x, 512, r);
    a2rp_sc_store(out, r);
}

/// out = (a*b + c) mod L
static void a2rp_sc_muladd(uint8_t out[32], const uint8_t a[32], const uint8_t b[32], const uint8_t c[32]) {
    uint64_t A[4], B[4], C[4], x[8];
    for (int i = 0; i < 4; i++) {
        A[i] = a2rp_load64le(a + 8 * i);
        B[i] = a2rp_load64le(b + 8 * i);
        C[i] = a2rp_load64le(c + 8 * i);
    }
    memset(x, 0, sizeof(x));
    for (int i = 0; i < 4; i++) {
        unsigned __int128 carry = 0;
        for (int j = 0; j < 4; j++) {
            unsigned __int128 t = (unsigned __int128)A[i] * B[j] + x[i + j] + carry;
            x[i + j] = (uint64_t)t;
            carry = t >> 64;
        }
        x[i + 4] += (uint64_t)carry;
    }
    uint64_t carry = 0;
    for (int i = 0; i < 4; i++) {
        unsigned __int128 t = (unsigned __int128)x[i] + C[i] + carry;
        x[i] = (uint64_t)t;
        carry = (uint64_t)(t >> 64);
    }
    for (int i = 4; i < 8 && carry; i++) {
        unsigned __int128 t = (unsigned __int128)x[i] + carry;
        x[i] = (uint64_t)t;
        carry = (uint64_t)(t >> 64);
    }
    uint64_t r[4];
    a2rp_sc_reduce_bits(x, 512, r);
    a2rp_sc_store(out, r);
}

static int a2rp_sc_lt_l(const uint8_t s[32]) {
    uint64_t a[4];
    for (int i = 0; i < 4; i++) {
        a[i] = a2rp_load64le(s + 8 * i);
    }
    return !a2rp_sc_ge_l(a);
}

// ---------------------------------------------------------------------------
// SHA-512（CommonCrypto，公开 API）
// ---------------------------------------------------------------------------

static void a2rp_sha512_2(const uint8_t *a, size_t alen, const uint8_t *b, size_t blen, uint8_t out[64]) {
    CC_SHA512_CTX ctx;
    CC_SHA512_Init(&ctx);
    if (alen) CC_SHA512_Update(&ctx, a, (CC_LONG)alen);
    if (blen) CC_SHA512_Update(&ctx, b, (CC_LONG)blen);
    CC_SHA512_Final(out, &ctx);
}

// ---------------------------------------------------------------------------
// 公开 API
// ---------------------------------------------------------------------------

/// 由种子算「标量 a」（clamp 后）与「前缀 prefix」
static void a2rp_ed25519_expand(const uint8_t seed[32], uint8_t a[32], uint8_t prefix[32]) {
    uint8_t h[64];
    CC_SHA512(seed, 32, h);
    memcpy(a, h, 32);
    a[0] &= 248;
    a[31] &= 127;
    a[31] |= 64;
    memcpy(prefix, h + 32, 32);
    memset(h, 0, sizeof(h));
}

int A2RPEd25519PublicKey(uint8_t pubOut[A2RP_ED25519_PUB_BYTES],
                         const uint8_t seed[A2RP_ED25519_SEED_BYTES]) {
    if (pubOut == NULL || seed == NULL) {
        return 0;
    }
    uint8_t a[32], prefix[32];
    a2rp_ed25519_expand(seed, a, prefix);
    a2rp_ge B, A;
    if (!a2rp_ge_base(&B)) {
        return 0;
    }
    a2rp_ge_scalarmult(&A, &B, a);
    a2rp_ge_tobytes(pubOut, &A);
    memset(a, 0, sizeof(a));
    memset(prefix, 0, sizeof(prefix));
    return 1;
}

int A2RPEd25519Sign(uint8_t sigOut[A2RP_ED25519_SIG_BYTES],
                    const uint8_t seed[A2RP_ED25519_SEED_BYTES],
                    const uint8_t *msg, size_t msgLen) {
    if (sigOut == NULL || seed == NULL || (msgLen > 0 && msg == NULL)) {
        return 0;
    }
    uint8_t a[32], prefix[32];
    a2rp_ed25519_expand(seed, a, prefix);

    a2rp_ge B, A, R;
    if (!a2rp_ge_base(&B)) {
        return 0;
    }
    a2rp_ge_scalarmult(&A, &B, a);
    uint8_t Aenc[32];
    a2rp_ge_tobytes(Aenc, &A);

    // r = SHA512(prefix || M) mod L
    uint8_t h[64], r[32], k[32];
    a2rp_sha512_2(prefix, 32, msg, msgLen, h);
    a2rp_sc_reduce64(r, h);

    a2rp_ge_scalarmult(&R, &B, r);
    uint8_t Renc[32];
    a2rp_ge_tobytes(Renc, &R);

    // k = SHA512(R || A || M) mod L
    {
        CC_SHA512_CTX ctx;
        CC_SHA512_Init(&ctx);
        CC_SHA512_Update(&ctx, Renc, 32);
        CC_SHA512_Update(&ctx, Aenc, 32);
        if (msgLen) CC_SHA512_Update(&ctx, msg, (CC_LONG)msgLen);
        CC_SHA512_Final(h, &ctx);
    }
    a2rp_sc_reduce64(k, h);

    memcpy(sigOut, Renc, 32);
    a2rp_sc_muladd(sigOut + 32, k, a, r);

    memset(a, 0, sizeof(a));
    memset(prefix, 0, sizeof(prefix));
    memset(h, 0, sizeof(h));
    memset(r, 0, sizeof(r));
    memset(k, 0, sizeof(k));
    return 1;
}

int A2RPEd25519Verify(const uint8_t pub[A2RP_ED25519_PUB_BYTES],
                      const uint8_t *msg, size_t msgLen,
                      const uint8_t sig[A2RP_ED25519_SIG_BYTES]) {
    if (pub == NULL || sig == NULL || (msgLen > 0 && msg == NULL)) {
        return 0;
    }
    if (!a2rp_sc_lt_l(sig + 32)) {
        return 0;                                // RFC 8032 §5.1.7：S ≥ L 必须拒绝
    }

    a2rp_ge A, B;
    if (!a2rp_ge_frombytes(&A, pub)) {
        return 0;                                // 公钥不是曲线点
    }
    if (!a2rp_ge_base(&B)) {
        return 0;
    }

    // k = SHA512(R || A || M) mod L
    uint8_t h[64], k[32];
    {
        CC_SHA512_CTX ctx;
        CC_SHA512_Init(&ctx);
        CC_SHA512_Update(&ctx, sig, 32);
        CC_SHA512_Update(&ctx, pub, 32);
        if (msgLen) CC_SHA512_Update(&ctx, msg, (CC_LONG)msgLen);
        CC_SHA512_Final(h, &ctx);
    }
    a2rp_sc_reduce64(k, h);

    // 验：  [S]B - [k]A  ==  R
    a2rp_ge SB, negA, kA, sum;
    a2rp_ge_scalarmult(&SB, &B, sig + 32);

    memcpy(&negA, &A, sizeof(negA));
    a2rp_fe_neg(negA.X, A.X);
    a2rp_fe_neg(negA.T, A.T);
    a2rp_ge_scalarmult(&kA, &negA, k);

    a2rp_ge_add(&sum, &SB, &kA);

    uint8_t enc[32];
    a2rp_ge_tobytes(enc, &sum);
    uint8_t acc = 0;
    for (int i = 0; i < 32; i++) {
        acc |= (uint8_t)(enc[i] ^ sig[i]);
    }
    return acc == 0;
}
