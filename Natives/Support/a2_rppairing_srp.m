//
//  a2_rppairing_srp.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [JIT-AUTOPAIR-3] SRP-6a（SHA-512）内核实现。协议出处与编码约定的声明见头文件。
//
//  ★大数模幂 = mbedTLS 的 mbedtls_mpi★（随仓第三方，Apache-2.0）。本文件不自造 bignum。
//
//  ★编码约定（公开实现间有分歧的地方，本文件逐条定死，并已在头文件声明需真机对拍）★：
//    · k  = H(N_fixed || PAD_n(g))；N_fixed = N 的 primeBytes 定长大端。
//    · u  = H(PAD_n(A) || PAD_n(B))；PAD_n = 左补零到 primeBytes。
//    · x  = H(salt || H(I || ":" || P))（RFC 2945 派生；用户名进 x）。
//    · K  = H(S_min)；S_min = S 的**最短**大端（无前导零）。
//    · M1 = H( (H(N) xor H(g))_fixedLen || H(I) || salt || A_min || B_min || K )。
//    · M2 = H( A_min || M1 || K )。
//    以上与 SRP-6a 权威表述、以及公开 HAP 参考实现（tadglines/go-pkgs、go2rtc/pkg/hap）一致。
//

#import "a2_rppairing_srp.h"
#import "a2_rppairing_crypto.h"

#import <mbedtls/bignum.h>

#include <stdlib.h>
#include <string.h>

#pragma mark - 群参数（RFC 5054 §Appendix A 的 3072-bit Group）

/// RFC 5054 §Appendix A「4. 3072-bit Group」的十六进制 N（384 字节）。
/// ★逐字符照抄公开 RFC 值★（tests/JIT 会与 RFC 值逐位对拍）。
static const char kA2RPSRP3072PrimeHex[] =
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22"
    "514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6"
    "F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3D"
    "C2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB"
    "9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B"
    "2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA05101572"
    "8E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F"
    "85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D876027"
    "33EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFC"
    "E0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF";

static const A2RPSRPGroup kA2RPSRPGroup3072 = {
    /* primeHex   */ kA2RPSRP3072PrimeHex,
    /* generator  */ 5,     // RFC 5054 §Appendix A：3072-bit 群的生成元 = 5
    /* primeBytes */ 384,   // 3072 / 8
};

const A2RPSRPGroup *A2RPSRPGroup3072(void) {
    return &kA2RPSRPGroup3072;
}

#pragma mark - 摘要（生产 = SHA-512）

static int A2RPSRPXSHA512(const uint8_t *in, size_t inLen, uint8_t *out) {
    static const uint8_t kEmpty = 0;
    const uint8_t *p = (in != NULL) ? in : &kEmpty;
    return A2RPSHA512(p, inLen, out) ? 1 : 0;
}

A2RPSRPHashFn A2RPSRPHashSHA512(void) {
    return A2RPSRPXSHA512;
}

size_t A2RPSRPSHA512DigestLength(void) {
    return A2RP_SHA512_BYTES;
}

#pragma mark - 小工具

static void A2RPSRPXBufFree(uint8_t **buf, size_t *len) {
    if (buf != NULL && *buf != NULL) {
        memset(*buf, 0, *len);
        free(*buf);
        *buf = NULL;
    }
    if (len != NULL) {
        *len = 0;
    }
}

/// 把 mpi 写成**最短**大端字节（0 写成单字节 0x00）。失败 ⇒ NO。
static BOOL A2RPSRPXMPIToMinimal(const mbedtls_mpi *v, uint8_t **outBuf, size_t *outLen) {
    size_t n = mbedtls_mpi_size(v);
    if (n == 0) {
        n = 1;
    }
    uint8_t *b = (uint8_t *)malloc(n);
    if (b == NULL) {
        return NO;
    }
    if (mbedtls_mpi_write_binary(v, b, n) != 0) {
        free(b);
        return NO;
    }
    *outBuf = b;
    *outLen = n;
    return YES;
}

/// 把 mpi 写成**定长**大端（左补零到 fixedBytes）。超出则失败（如实拒绝）。
static BOOL A2RPSRPXMPIToFixed(const mbedtls_mpi *v, size_t fixedBytes,
                               uint8_t *out, size_t *outLen) {
    if (mbedtls_mpi_size(v) > fixedBytes) {
        return NO;
    }
    if (mbedtls_mpi_write_binary(v, out, fixedBytes) != 0) {
        return NO;
    }
    *outLen = fixedBytes;
    return YES;
}

/// 拼若干段（用于单参数摘要接口）。失败 ⇒ NULL。
static uint8_t *A2RPSRPXConcat(const uint8_t *const *parts, const size_t *lens, size_t count,
                               size_t *outLen) {
    size_t total = 0;
    for (size_t i = 0; i < count; i++) {
        total += lens[i];
    }
    uint8_t *buf = (uint8_t *)malloc(total > 0 ? total : 1);
    if (buf == NULL) {
        return NULL;
    }
    size_t off = 0;
    for (size_t i = 0; i < count; i++) {
        if (lens[i] > 0 && parts[i] != NULL) {
            memcpy(buf + off, parts[i], lens[i]);
            off += lens[i];
        }
    }
    *outLen = total;
    return buf;
}

/// 摘要若干段 → out（长度 = hashLen）。失败 ⇒ NO。
static BOOL A2RPSRPXHashParts(A2RPSRPHashFn hash, size_t hashLen,
                              const uint8_t *const *parts, const size_t *lens, size_t count,
                              uint8_t *out) {
    size_t total = 0;
    uint8_t *buf = A2RPSRPXConcat(parts, lens, count, &total);
    if (buf == NULL) {
        return NO;
    }
    int rc = hash(buf, total, out);
    memset(buf, 0, total);
    free(buf);
    return rc == 1;
}

static BOOL A2RPSRPXReadMPI(mbedtls_mpi *out, const uint8_t *bytes, size_t len) {
    if (len == 0 || bytes == NULL) {
        return NO;
    }
    return mbedtls_mpi_read_binary(out, bytes, len) == 0;
}

#pragma mark - 客户端

struct A2RPSRPClient {
    const A2RPSRPGroup *group;
    A2RPSRPHashFn hash;
    size_t hashLen;
    mbedtls_mpi N;
    mbedtls_mpi g;
    mbedtls_mpi a;
    mbedtls_mpi A;
    uint8_t *identity; size_t identityLen;
    uint8_t *password; size_t passwordLen;
    uint8_t *kBytes; size_t kLen;            // k = H(N|PAD(g))
    // 输出（最短大端）
    uint8_t *aBytes; size_t aBytesLen;        // A
    // 计算后
    BOOL hasKey;
    mbedtls_mpi B;
    mbedtls_mpi u;
    mbedtls_mpi x;
    mbedtls_mpi S;
    uint8_t *saltBytes; size_t saltBytesLen;
    uint8_t *bBytes; size_t bBytesLen;        // B（最短大端）
    uint8_t *uBytes; size_t uBytesLen;
    uint8_t *xBytes; size_t xBytesLen;
    uint8_t *sBytes; size_t sBytesLen;
    uint8_t *keyBytes; size_t keyBytesLen;    // K
    uint8_t *m1Bytes; size_t m1BytesLen;
};

/// k = H(N_fixed | PAD_n(g))。失败 ⇒ NO。
static BOOL A2RPSRPXComputeK(const A2RPSRPGroup *group, A2RPSRPHashFn hash, size_t hashLen,
                             const mbedtls_mpi *N, const mbedtls_mpi *g,
                             uint8_t *out, size_t *outLen) {
    size_t n = group->primeBytes;
    uint8_t *nBuf = (uint8_t *)malloc(n);
    uint8_t *gBuf = (uint8_t *)malloc(n);
    if (nBuf == NULL || gBuf == NULL) {
        free(nBuf); free(gBuf);
        return NO;
    }
    size_t got = 0;
    BOOL ok = A2RPSRPXMPIToFixed(N, n, nBuf, &got)
           && A2RPSRPXMPIToFixed(g, n, gBuf, &got);
    if (ok) {
        const uint8_t *parts[2] = { nBuf, gBuf };
        const size_t lens[2] = { n, n };
        ok = A2RPSRPXHashParts(hash, hashLen, parts, lens, 2, out);
    }
    memset(nBuf, 0, n); memset(gBuf, 0, n);
    free(nBuf); free(gBuf);
    if (ok) {
        *outLen = hashLen;
    }
    return ok;
}

A2RPSRPClient *A2RPSRPClientCreate(const A2RPSRPGroup *group,
                                   A2RPSRPHashFn hash, size_t hashLen,
                                   const uint8_t *identity, size_t identityLen,
                                   const uint8_t *password, size_t passwordLen,
                                   const uint8_t *aBytes, size_t aLen,
                                   NSString **reason) {
    if (group == NULL || group->primeHex == NULL || hash == NULL) {
        if (reason) { *reason = @"SRP 群/摘要参数缺失"; }
        return NULL;
    }
    if (hashLen != 64 && hashLen != 20 && hashLen != 32) {
        if (reason) { *reason = [NSString stringWithFormat:@"不支持的摘要长度 %lu", (unsigned long)hashLen]; }
        return NULL;
    }
    if (aLen == 0 || aBytes == NULL) {
        if (reason) { *reason = @"私随机数 a 为空"; }
        return NULL;
    }
    A2RPSRPClient *c = (A2RPSRPClient *)calloc(1, sizeof(A2RPSRPClient));
    if (c == NULL) {
        if (reason) { *reason = @"内存不足"; }
        return NULL;
    }
    c->group = group;
    c->hash = hash;
    c->hashLen = hashLen;
    mbedtls_mpi_init(&c->N); mbedtls_mpi_init(&c->g); mbedtls_mpi_init(&c->a);
    mbedtls_mpi_init(&c->A); mbedtls_mpi_init(&c->B); mbedtls_mpi_init(&c->u);
    mbedtls_mpi_init(&c->x); mbedtls_mpi_init(&c->S);

    BOOL ok = mbedtls_mpi_read_string(&c->N, 16, group->primeHex) == 0
           && mbedtls_mpi_lset(&c->g, (mbedtls_mpi_sint)group->generator) == 0
           && A2RPSRPXReadMPI(&c->a, aBytes, aLen)
           && mbedtls_mpi_exp_mod(&c->A, &c->g, &c->a, &c->N, NULL) == 0;
    if (ok) {
        c->identity = (uint8_t *)malloc(identityLen > 0 ? identityLen : 1);
        c->password = (uint8_t *)malloc(passwordLen > 0 ? passwordLen : 1);
        c->kBytes = (uint8_t *)malloc(hashLen);
        ok = (c->identity != NULL && c->password != NULL && c->kBytes != NULL);
        if (ok) {
            if (identityLen > 0) { memcpy(c->identity, identity, identityLen); }
            if (passwordLen > 0) { memcpy(c->password, password, passwordLen); }
            c->identityLen = identityLen;
            c->passwordLen = passwordLen;
            ok = A2RPSRPXComputeK(group, hash, hashLen, &c->N, &c->g, c->kBytes, &c->kLen);
        }
    }
    if (ok) {
        ok = A2RPSRPXMPIToMinimal(&c->A, &c->aBytes, &c->aBytesLen);
    }
    if (!ok) {
        if (reason) { *reason = @"SRP 客户端初始化失败（群/私钥非法？）"; }
        A2RPSRPClientFree(c);
        return NULL;
    }
    return c;
}

void A2RPSRPClientFree(A2RPSRPClient *client) {
    if (client == NULL) { return; }
    mbedtls_mpi_free(&client->N); mbedtls_mpi_free(&client->g); mbedtls_mpi_free(&client->a);
    mbedtls_mpi_free(&client->A); mbedtls_mpi_free(&client->B); mbedtls_mpi_free(&client->u);
    mbedtls_mpi_free(&client->x); mbedtls_mpi_free(&client->S);
    A2RPSRPXBufFree(&client->identity, &client->identityLen);
    A2RPSRPXBufFree(&client->password, &client->passwordLen);
    A2RPSRPXBufFree(&client->kBytes, &client->kLen);
    A2RPSRPXBufFree(&client->aBytes, &client->aBytesLen);
    A2RPSRPXBufFree(&client->saltBytes, &client->saltBytesLen);
    A2RPSRPXBufFree(&client->bBytes, &client->bBytesLen);
    A2RPSRPXBufFree(&client->uBytes, &client->uBytesLen);
    A2RPSRPXBufFree(&client->xBytes, &client->xBytesLen);
    A2RPSRPXBufFree(&client->sBytes, &client->sBytesLen);
    A2RPSRPXBufFree(&client->keyBytes, &client->keyBytesLen);
    A2RPSRPXBufFree(&client->m1Bytes, &client->m1BytesLen);
    free(client);
}

const uint8_t *A2RPSRPClientPublicA(A2RPSRPClient *client, size_t *lenOut) {
    if (client == NULL || client->aBytes == NULL) { return NULL; }
    if (lenOut) { *lenOut = client->aBytesLen; }
    return client->aBytes;
}

BOOL A2RPSRPClientComputeKey(A2RPSRPClient *client,
                             const uint8_t *salt, size_t saltLen,
                             const uint8_t *B, size_t bLen,
                             NSString **reason) {
    if (client == NULL) {
        if (reason) { *reason = @"客户端为空"; }
        return NO;
    }
    size_t n = client->group->primeBytes;
    if (saltLen == 0 || salt == NULL) {
        if (reason) { *reason = @"SRP 盐为空"; }
        return NO;
    }
    if (bLen == 0 || B == NULL) {
        if (reason) { *reason = @"服务端公开值 B 为空"; }
        return NO;
    }
    mbedtls_mpi Bmpi; mbedtls_mpi_init(&Bmpi);
    mbedtls_mpi Bmod; mbedtls_mpi_init(&Bmod);
    mbedtls_mpi gx;   mbedtls_mpi_init(&gx);
    mbedtls_mpi kgx;  mbedtls_mpi_init(&kgx);
    mbedtls_mpi base; mbedtls_mpi_init(&base);
    mbedtls_mpi expo; mbedtls_mpi_init(&expo);
    mbedtls_mpi ux;   mbedtls_mpi_init(&ux);
    mbedtls_mpi uNew; mbedtls_mpi_init(&uNew);
    mbedtls_mpi xNew; mbedtls_mpi_init(&xNew);
    mbedtls_mpi SNew; mbedtls_mpi_init(&SNew);
    uint8_t *padA = (uint8_t *)malloc(n);
    uint8_t *padB = (uint8_t *)malloc(n);
    uint8_t *uBuf = (uint8_t *)malloc(client->hashLen);
    uint8_t *xInner = (uint8_t *)malloc(client->hashLen);
    uint8_t *xTmp = (uint8_t *)malloc(client->hashLen);
    uint8_t *newSalt = (uint8_t *)malloc(saltLen);
    uint8_t *newB = NULL; size_t newBLen = 0;
    uint8_t *newU = NULL; size_t newULen = 0;
    uint8_t *newX = NULL; size_t newXLen = 0;
    uint8_t *newS = NULL; size_t newSLen = 0;
    uint8_t *newK = NULL;
    uint8_t *newM1 = NULL;
    BOOL ok = (padA != NULL && padB != NULL && uBuf != NULL && xInner != NULL
               && xTmp != NULL && newSalt != NULL);

    // B 合法性（RFC 5054 §2.5.3）：B > 0 且 B < N 且 B mod N != 0。
    if (ok) {
        ok = A2RPSRPXReadMPI(&Bmpi, B, bLen);
        if (ok && mbedtls_mpi_cmp_int(&Bmpi, 0) <= 0) {
            if (reason) { *reason = @"服务端公开值 B <= 0 ⇒ 拒绝"; }
            ok = NO;
        }
        if (ok && (mbedtls_mpi_cmp_mpi(&Bmpi, &client->N) >= 0)) {
            if (reason) { *reason = @"服务端公开值 B >= N ⇒ 拒绝"; }
            ok = NO;
        }
        if (ok && mbedtls_mpi_mod_mpi(&Bmod, &Bmpi, &client->N) == 0
            && mbedtls_mpi_cmp_int(&Bmod, 0) == 0) {
            if (reason) { *reason = @"服务端公开值 B mod N == 0 ⇒ 拒绝"; }
            ok = NO;
        }
    }

    // x = H(salt | H(I | ":" | P))
    if (ok) {
        const uint8_t kColon[1] = { ':' };
        const uint8_t *ipParts[3] = { client->identity, kColon, client->password };
        const size_t ipLens[3] = { client->identityLen, 1, client->passwordLen };
        ok = A2RPSRPXHashParts(client->hash, client->hashLen, ipParts, ipLens, 3, xInner);
        if (ok) {
            const uint8_t *xParts[2] = { salt, xInner };
            const size_t xLens[2] = { saltLen, client->hashLen };
            ok = A2RPSRPXHashParts(client->hash, client->hashLen, xParts, xLens, 2, xTmp);
        }
        if (ok) {
            ok = A2RPSRPXReadMPI(&xNew, xTmp, client->hashLen);
        }
    }

    // u = H(PAD(A) | PAD(B))
    if (ok) {
        size_t got = 0;
        ok = A2RPSRPXMPIToFixed(&client->A, n, padA, &got)
          && A2RPSRPXMPIToFixed(&Bmpi, n, padB, &got);
        if (ok) {
            const uint8_t *uParts[2] = { padA, padB };
            const size_t uLens[2] = { n, n };
            ok = A2RPSRPXHashParts(client->hash, client->hashLen, uParts, uLens, 2, uBuf);
        }
        if (ok) {
            ok = A2RPSRPXReadMPI(&uNew, uBuf, client->hashLen);
            if (ok && mbedtls_mpi_cmp_int(&uNew, 0) == 0) {
                if (reason) { *reason = @"u = H(A,B) == 0 ⇒ 拒绝"; }
                ok = NO;
            }
        }
    }

    // S = (B - k*g^x) ^ (a + u*x) mod N
    if (ok) {
        ok = mbedtls_mpi_exp_mod(&gx, &client->g, &xNew, &client->N, NULL) == 0;
    }
    if (ok) {
        mbedtls_mpi kMpi; mbedtls_mpi_init(&kMpi);
        ok = A2RPSRPXReadMPI(&kMpi, client->kBytes, client->kLen);
        if (ok) {
            ok = mbedtls_mpi_mul_mpi(&kgx, &kMpi, &gx) == 0
              && mbedtls_mpi_mod_mpi(&kgx, &kgx, &client->N) == 0;
        }
        mbedtls_mpi_free(&kMpi);
    }
    if (ok) {
        ok = mbedtls_mpi_sub_mpi(&base, &Bmpi, &kgx) == 0;
        if (ok && mbedtls_mpi_cmp_int(&base, 0) < 0) {
            ok = mbedtls_mpi_add_mpi(&base, &base, &client->N) == 0;
        }
        if (ok) {
            ok = mbedtls_mpi_mul_mpi(&ux, &uNew, &xNew) == 0
              && mbedtls_mpi_add_mpi(&expo, &client->a, &ux) == 0
              && mbedtls_mpi_exp_mod(&SNew, &base, &expo, &client->N, NULL) == 0;
        }
    }

    // K = H(S_min)
    if (ok) {
        uint8_t *sMin = NULL; size_t sMinLen = 0;
        ok = A2RPSRPXMPIToMinimal(&SNew, &sMin, &sMinLen);
        if (ok) {
            newK = (uint8_t *)malloc(client->hashLen);
            ok = (newK != NULL) && (client->hash(sMin, sMinLen, newK) == 1);
        }
        if (ok) {
            ok = A2RPSRPXMPIToMinimal(&SNew, &newS, &newSLen)
              && A2RPSRPXMPIToMinimal(&Bmpi, &newB, &newBLen)
              && A2RPSRPXMPIToMinimal(&uNew, &newU, &newULen)
              && A2RPSRPXMPIToMinimal(&xNew, &newX, &newXLen);
        }
        if (sMin) { memset(sMin, 0, sMinLen); free(sMin); }
    }

    // M1 = H( (H(N) xor H(g)) | H(I) | salt | A_min | B_min | K )
    if (ok) {
        uint8_t hn[64], hg[64];
        uint8_t hxor[64];
        uint8_t *nMin = NULL, *gMin = NULL;
        size_t nMinLen = 0, gMinLen = 0;
        uint8_t *hi = (uint8_t *)malloc(client->hashLen);
        BOOL m1ok = (hi != NULL);
        if (m1ok) {
            // H(N)/H(g) 用各自的**最短**大端（与 SRP-6a 表述 / 公开 HAP 参考实现一致）。
            m1ok = A2RPSRPXMPIToMinimal(&client->N, &nMin, &nMinLen)
                && A2RPSRPXMPIToMinimal(&client->g, &gMin, &gMinLen)
                && client->hash(nMin, nMinLen, hn) == 1
                && client->hash(gMin, gMinLen, hg) == 1;
        }
        if (m1ok) {
            for (size_t i = 0; i < client->hashLen; i++) {
                hxor[i] = (uint8_t)(hn[i] ^ hg[i]);   // 定长逐字节 XOR
            }
            const uint8_t *iParts[1] = { client->identity };
            const size_t iLens[1] = { client->identityLen };
            m1ok = A2RPSRPXHashParts(client->hash, client->hashLen, iParts, iLens, 1, hi);
        }
        if (m1ok) {
            newM1 = (uint8_t *)malloc(client->hashLen);
            // M1 = H( (H(N) xor H(g)) | H(I) | salt | A_min | B_min | K )
            const uint8_t *m1Parts[6] = { hxor, hi, salt, client->aBytes, newB, newK };
            const size_t m1Lens[6] = { client->hashLen, client->hashLen, saltLen,
                                       client->aBytesLen, newBLen, client->hashLen };
            m1ok = (newM1 != NULL)
                && A2RPSRPXHashParts(client->hash, client->hashLen, m1Parts, m1Lens, 6, newM1);
        }
        free(nMin); free(gMin);
        if (hi) { memset(hi, 0, client->hashLen); free(hi); }
        ok = ok && m1ok;
    }

    if (ok) {
        // 落库（先清旧值）
        A2RPSRPXBufFree(&client->saltBytes, &client->saltBytesLen);
        A2RPSRPXBufFree(&client->bBytes, &client->bBytesLen);
        A2RPSRPXBufFree(&client->uBytes, &client->uBytesLen);
        A2RPSRPXBufFree(&client->xBytes, &client->xBytesLen);
        A2RPSRPXBufFree(&client->sBytes, &client->sBytesLen);
        A2RPSRPXBufFree(&client->keyBytes, &client->keyBytesLen);
        A2RPSRPXBufFree(&client->m1Bytes, &client->m1BytesLen);
        client->saltBytes = newSalt; newSalt = NULL; client->saltBytesLen = saltLen;
        client->bBytes = newB; client->bBytesLen = newBLen;
        client->uBytes = newU; client->uBytesLen = newULen;
        client->xBytes = newX; client->xBytesLen = newXLen;
        client->sBytes = newS; client->sBytesLen = newSLen;
        client->keyBytes = newK; client->keyBytesLen = client->hashLen;
        client->m1Bytes = newM1; client->m1BytesLen = client->hashLen;
        newSalt = NULL; newB = NULL; newU = NULL; newX = NULL; newS = NULL; newK = NULL; newM1 = NULL;
        client->hasKey = YES;
    } else if (reason && *reason == nil) {
        *reason = @"SRP 客户端算密钥失败（参数非法或 mbedTLS 出错）";
    }

    mbedtls_mpi_free(&Bmpi); mbedtls_mpi_free(&Bmod);
    mbedtls_mpi_free(&gx); mbedtls_mpi_free(&kgx);
    mbedtls_mpi_free(&base); mbedtls_mpi_free(&expo);
    mbedtls_mpi_free(&ux); mbedtls_mpi_free(&uNew);
    mbedtls_mpi_free(&xNew); mbedtls_mpi_free(&SNew);
    free(padA); free(padB); free(uBuf); free(xInner); free(xTmp);
    free(newSalt); free(newB); free(newU); free(newX); free(newS); free(newK); free(newM1);
    return ok;
}

const uint8_t *A2RPSRPClientProofM1(A2RPSRPClient *client, size_t *lenOut) {
    if (client == NULL || !client->hasKey || client->m1Bytes == NULL) { return NULL; }
    if (lenOut) { *lenOut = client->m1BytesLen; }
    return client->m1Bytes;
}

const uint8_t *A2RPSRPClientSessionKey(A2RPSRPClient *client, size_t *lenOut) {
    if (client == NULL || !client->hasKey || client->keyBytes == NULL) { return NULL; }
    if (lenOut) { *lenOut = client->keyBytesLen; }
    return client->keyBytes;
}

BOOL A2RPSRPClientVerifyM2(A2RPSRPClient *client, const uint8_t *m2, size_t m2Len) {
    if (client == NULL || !client->hasKey || m2 == NULL) { return NO; }
    if (m2Len != client->hashLen) { return NO; }
    // M2 = H(A_min | M1 | K)
    uint8_t expected[64];
    const uint8_t *parts[3] = { client->aBytes, client->m1Bytes, client->keyBytes };
    const size_t lens[3] = { client->aBytesLen, client->m1BytesLen, client->keyBytesLen };
    if (!A2RPSRPXHashParts(client->hash, client->hashLen, parts, lens, 3, expected)) {
        return NO;
    }
    // 定长比较（不短路）。
    uint8_t diff = 0;
    for (size_t i = 0; i < client->hashLen; i++) {
        diff |= (uint8_t)(expected[i] ^ m2[i]);
    }
    return diff == 0;
}

BOOL A2RPSRPClientTrace(A2RPSRPClient *client, A2RPSRPTrace *out) {
    if (client == NULL || out == NULL) { return NO; }
    memset(out, 0, sizeof(*out));
    if (client->kBytes)    { memcpy(out->k,   client->kBytes,   client->kLen);   out->kLen = client->kLen; }
    if (client->xBytes)    { memcpy(out->x,   client->xBytes,   client->xBytesLen);   out->xLen = client->xBytesLen; }
    if (client->uBytes)    { memcpy(out->u,   client->uBytes,   client->uBytesLen);   out->uLen = client->uBytesLen; }
    if (client->aBytes)    { memcpy(out->A,   client->aBytes,   client->aBytesLen);   out->aLen = client->aBytesLen; }
    if (client->bBytes)    { memcpy(out->B,   client->bBytes,   client->bBytesLen);   out->bLen = client->bBytesLen; }
    if (client->sBytes)    { memcpy(out->S,   client->sBytes,   client->sBytesLen);   out->sLen = client->sBytesLen; }
    if (client->keyBytes)  { memcpy(out->K,   client->keyBytes, client->keyBytesLen); out->keyLen = client->keyBytesLen; }
    if (client->m1Bytes)   { memcpy(out->M1,  client->m1Bytes,  client->m1BytesLen);  out->m1Len = client->m1BytesLen; }
    // 客户端不算 v / M2（服务端才算）—— 相应字段保持 0。
    return YES;
}

#pragma mark - 服务端

struct A2RPSRPServer {
    const A2RPSRPGroup *group;
    A2RPSRPHashFn hash;
    size_t hashLen;
    mbedtls_mpi N;
    mbedtls_mpi g;
    uint8_t *identity; size_t identityLen;
    uint8_t *saltBytes; size_t saltBytesLen;
    mbedtls_mpi v;
    mbedtls_mpi b;
    mbedtls_mpi B;
    uint8_t *kBytes; size_t kLen;
    // 输出
    uint8_t *vBytes; size_t vBytesLen;
    uint8_t *bBytes; size_t bBytesLen;     // B
    // 计算后
    BOOL hasKey;
    mbedtls_mpi A;
    mbedtls_mpi u;
    mbedtls_mpi x;
    mbedtls_mpi S;
    uint8_t *uBytes; size_t uBytesLen;
    uint8_t *xBytes; size_t xBytesLen;
    uint8_t *sBytes; size_t sBytesLen;
    uint8_t *keyBytes; size_t keyBytesLen;
    uint8_t *m1Bytes; size_t m1BytesLen;   // 期望的 M1
    uint8_t *m2Bytes; size_t m2BytesLen;
    uint8_t *aBytes; size_t aBytesLen;     // 客户端 A（最短大端副本）
};

A2RPSRPServer *A2RPSRPServerCreate(const A2RPSRPGroup *group,
                                   A2RPSRPHashFn hash, size_t hashLen,
                                   const uint8_t *identity, size_t identityLen,
                                   const uint8_t *password, size_t passwordLen,
                                   const uint8_t *salt, size_t saltLen,
                                   const uint8_t *bBytes, size_t bLen,
                                   NSString **reason) {
    if (group == NULL || group->primeHex == NULL || hash == NULL) {
        if (reason) { *reason = @"SRP 群/摘要参数缺失"; }
        return NULL;
    }
    if (hashLen != 64 && hashLen != 20 && hashLen != 32) {
        if (reason) { *reason = [NSString stringWithFormat:@"不支持的摘要长度 %lu", (unsigned long)hashLen]; }
        return NULL;
    }
    if (saltLen == 0 || salt == NULL || bLen == 0 || bBytes == NULL) {
        if (reason) { *reason = @"盐或私随机数 b 为空"; }
        return NULL;
    }
    A2RPSRPServer *s = (A2RPSRPServer *)calloc(1, sizeof(A2RPSRPServer));
    if (s == NULL) {
        if (reason) { *reason = @"内存不足"; }
        return NULL;
    }
    s->group = group;
    s->hash = hash;
    s->hashLen = hashLen;
    mbedtls_mpi_init(&s->N); mbedtls_mpi_init(&s->g); mbedtls_mpi_init(&s->v);
    mbedtls_mpi_init(&s->b); mbedtls_mpi_init(&s->B); mbedtls_mpi_init(&s->A);
    mbedtls_mpi_init(&s->u); mbedtls_mpi_init(&s->x); mbedtls_mpi_init(&s->S);

    mbedtls_mpi xMpi; mbedtls_mpi_init(&xMpi);
    mbedtls_mpi gb;   mbedtls_mpi_init(&gb);
    mbedtls_mpi kv;   mbedtls_mpi_init(&kv);
    mbedtls_mpi kMpi; mbedtls_mpi_init(&kMpi);

    s->identity = (uint8_t *)malloc(identityLen > 0 ? identityLen : 1);
    s->saltBytes = (uint8_t *)malloc(saltLen);
    s->kBytes = (uint8_t *)malloc(hashLen);
    uint8_t *xInner = (uint8_t *)malloc(hashLen);
    uint8_t *xTmp = (uint8_t *)malloc(hashLen);
    BOOL ok = (s->identity != NULL && s->saltBytes != NULL && s->kBytes != NULL
               && xInner != NULL && xTmp != NULL);
    if (ok) {
        if (identityLen > 0) { memcpy(s->identity, identity, identityLen); }
        s->identityLen = identityLen;
        memcpy(s->saltBytes, salt, saltLen);
        s->saltBytesLen = saltLen;
    }
    if (ok) {
        ok = mbedtls_mpi_read_string(&s->N, 16, group->primeHex) == 0
          && mbedtls_mpi_lset(&s->g, (mbedtls_mpi_sint)group->generator) == 0
          && A2RPSRPXReadMPI(&s->b, bBytes, bLen)
          && A2RPSRPXComputeK(group, hash, hashLen, &s->N, &s->g, s->kBytes, &s->kLen);
    }
    // x → v → B
    if (ok) {
        const uint8_t kColon[1] = { ':' };
        const uint8_t *ipParts[3] = { s->identity, kColon, password };
        const size_t ipLens[3] = { s->identityLen, 1, passwordLen };
        ok = A2RPSRPXHashParts(hash, hashLen, ipParts, ipLens, 3, xInner);
        if (ok) {
            const uint8_t *xParts[2] = { salt, xInner };
            const size_t xLens[2] = { saltLen, hashLen };
            ok = A2RPSRPXHashParts(hash, hashLen, xParts, xLens, 2, xTmp);
        }
        if (ok) {
            ok = A2RPSRPXReadMPI(&xMpi, xTmp, hashLen)
              && mbedtls_mpi_exp_mod(&s->v, &s->g, &xMpi, &s->N, NULL) == 0;
        }
        if (ok) {
            ok = A2RPSRPXReadMPI(&kMpi, s->kBytes, s->kLen)
              && mbedtls_mpi_mul_mpi(&kv, &kMpi, &s->v) == 0
              && mbedtls_mpi_exp_mod(&gb, &s->g, &s->b, &s->N, NULL) == 0
              && mbedtls_mpi_add_mpi(&s->B, &kv, &gb) == 0
              && mbedtls_mpi_mod_mpi(&s->B, &s->B, &s->N) == 0;
        }
        if (ok) {
            ok = A2RPSRPXMPIToMinimal(&s->v, &s->vBytes, &s->vBytesLen)
              && A2RPSRPXMPIToMinimal(&s->B, &s->bBytes, &s->bBytesLen);
        }
    }
    memset(xInner, 0, hashLen); memset(xTmp, 0, hashLen);
    free(xInner); free(xTmp);
    mbedtls_mpi_free(&xMpi); mbedtls_mpi_free(&gb); mbedtls_mpi_free(&kv); mbedtls_mpi_free(&kMpi);
    if (!ok) {
        if (reason && *reason == nil) { *reason = @"SRP 服务端初始化失败"; }
        A2RPSRPServerFree(s);
        return NULL;
    }
    return s;
}

void A2RPSRPServerFree(A2RPSRPServer *server) {
    if (server == NULL) { return; }
    mbedtls_mpi_free(&server->N); mbedtls_mpi_free(&server->g);
    mbedtls_mpi_free(&server->v); mbedtls_mpi_free(&server->b);
    mbedtls_mpi_free(&server->B); mbedtls_mpi_free(&server->A);
    mbedtls_mpi_free(&server->u); mbedtls_mpi_free(&server->x);
    mbedtls_mpi_free(&server->S);
    A2RPSRPXBufFree(&server->identity, &server->identityLen);
    A2RPSRPXBufFree(&server->saltBytes, &server->saltBytesLen);
    A2RPSRPXBufFree(&server->kBytes, &server->kLen);
    A2RPSRPXBufFree(&server->vBytes, &server->vBytesLen);
    A2RPSRPXBufFree(&server->bBytes, &server->bBytesLen);
    A2RPSRPXBufFree(&server->uBytes, &server->uBytesLen);
    A2RPSRPXBufFree(&server->xBytes, &server->xBytesLen);
    A2RPSRPXBufFree(&server->sBytes, &server->sBytesLen);
    A2RPSRPXBufFree(&server->keyBytes, &server->keyBytesLen);
    A2RPSRPXBufFree(&server->m1Bytes, &server->m1BytesLen);
    A2RPSRPXBufFree(&server->m2Bytes, &server->m2BytesLen);
    A2RPSRPXBufFree(&server->aBytes, &server->aBytesLen);
    free(server);
}

const uint8_t *A2RPSRPServerSalt(A2RPSRPServer *server, size_t *lenOut) {
    if (server == NULL || server->saltBytes == NULL) { return NULL; }
    if (lenOut) { *lenOut = server->saltBytesLen; }
    return server->saltBytes;
}

const uint8_t *A2RPSRPServerVerifier(A2RPSRPServer *server, size_t *lenOut) {
    if (server == NULL || server->vBytes == NULL) { return NULL; }
    if (lenOut) { *lenOut = server->vBytesLen; }
    return server->vBytes;
}

const uint8_t *A2RPSRPServerPublicB(A2RPSRPServer *server, size_t *lenOut) {
    if (server == NULL || server->bBytes == NULL) { return NULL; }
    if (lenOut) { *lenOut = server->bBytesLen; }
    return server->bBytes;
}

BOOL A2RPSRPServerComputeKey(A2RPSRPServer *server,
                             const uint8_t *A, size_t aLen,
                             NSString **reason) {
    if (server == NULL) {
        if (reason) { *reason = @"服务端为空"; }
        return NO;
    }
    if (aLen == 0 || A == NULL) {
        if (reason) { *reason = @"客户端公开值 A 为空"; }
        return NO;
    }
    size_t n = server->group->primeBytes;
    mbedtls_mpi Ampi; mbedtls_mpi_init(&Ampi);
    mbedtls_mpi Amod; mbedtls_mpi_init(&Amod);
    mbedtls_mpi uNew; mbedtls_mpi_init(&uNew);
    mbedtls_mpi vu;   mbedtls_mpi_init(&vu);
    mbedtls_mpi base; mbedtls_mpi_init(&base);
    mbedtls_mpi SNew; mbedtls_mpi_init(&SNew);
    uint8_t *padA = (uint8_t *)malloc(n);
    uint8_t *padB = (uint8_t *)malloc(n);
    uint8_t *uBuf = (uint8_t *)malloc(server->hashLen);
    uint8_t *newU = NULL; size_t newULen = 0;
    uint8_t *newS = NULL; size_t newSLen = 0;
    uint8_t *newA = NULL; size_t newALen = 0;
    uint8_t *newK = NULL;
    uint8_t *newM1 = NULL;
    uint8_t *newM2 = NULL;
    BOOL ok = (padA != NULL && padB != NULL && uBuf != NULL);

    // A 合法性（RFC 5054 §2.5.4）：A > 0 且 A < N 且 A mod N != 0。
    if (ok) {
        ok = A2RPSRPXReadMPI(&Ampi, A, aLen);
        if (ok && mbedtls_mpi_cmp_int(&Ampi, 0) <= 0) {
            if (reason) { *reason = @"客户端公开值 A <= 0 ⇒ 拒绝"; }
            ok = NO;
        }
        if (ok && mbedtls_mpi_cmp_mpi(&Ampi, &server->N) >= 0) {
            if (reason) { *reason = @"客户端公开值 A >= N ⇒ 拒绝"; }
            ok = NO;
        }
        if (ok && mbedtls_mpi_mod_mpi(&Amod, &Ampi, &server->N) == 0
            && mbedtls_mpi_cmp_int(&Amod, 0) == 0) {
            if (reason) { *reason = @"客户端公开值 A mod N == 0 ⇒ 拒绝"; }
            ok = NO;
        }
    }
    // u = H(PAD(A) | PAD(B))
    if (ok) {
        size_t got = 0;
        ok = A2RPSRPXMPIToFixed(&Ampi, n, padA, &got)
          && A2RPSRPXMPIToFixed(&server->B, n, padB, &got);
        if (ok) {
            const uint8_t *uParts[2] = { padA, padB };
            const size_t uLens[2] = { n, n };
            ok = A2RPSRPXHashParts(server->hash, server->hashLen, uParts, uLens, 2, uBuf);
        }
        if (ok) {
            ok = A2RPSRPXReadMPI(&uNew, uBuf, server->hashLen);
            if (ok && mbedtls_mpi_cmp_int(&uNew, 0) == 0) {
                if (reason) { *reason = @"u = H(A,B) == 0 ⇒ 拒绝"; }
                ok = NO;
            }
        }
    }
    // S = (A * v^u)^b mod N
    if (ok) {
        ok = mbedtls_mpi_exp_mod(&vu, &server->v, &uNew, &server->N, NULL) == 0
          && mbedtls_mpi_mul_mpi(&base, &Ampi, &vu) == 0
          && mbedtls_mpi_mod_mpi(&base, &base, &server->N) == 0
          && mbedtls_mpi_exp_mod(&SNew, &base, &server->b, &server->N, NULL) == 0;
    }
    // K = H(S_min) + 期望的 M1/M2
    if (ok) {
        uint8_t *sMin = NULL; size_t sMinLen = 0;
        ok = A2RPSRPXMPIToMinimal(&SNew, &sMin, &sMinLen);
        if (ok) {
            newK = (uint8_t *)malloc(server->hashLen);
            ok = (newK != NULL) && (server->hash(sMin, sMinLen, newK) == 1);
        }
        if (ok) {
            ok = A2RPSRPXMPIToMinimal(&SNew, &newS, &newSLen)
              && A2RPSRPXMPIToMinimal(&Ampi, &newA, &newALen)
              && A2RPSRPXMPIToMinimal(&uNew, &newU, &newULen);
        }
        if (sMin) { memset(sMin, 0, sMinLen); free(sMin); }
    }
    // M1 = H( (H(N) xor H(g)) | H(I) | salt | A_min | B_min | K )
    if (ok) {
        uint8_t hn[64], hg[64], hxor[64];
        uint8_t *nMin = NULL, *gMin = NULL;
        size_t nMinLen = 0, gMinLen = 0;
        uint8_t *hi = (uint8_t *)malloc(server->hashLen);
        BOOL m1ok = (hi != NULL);
        if (m1ok) {
            m1ok = A2RPSRPXMPIToMinimal(&server->N, &nMin, &nMinLen)
                && A2RPSRPXMPIToMinimal(&server->g, &gMin, &gMinLen)
                && server->hash(nMin, nMinLen, hn) == 1
                && server->hash(gMin, gMinLen, hg) == 1;
        }
        if (m1ok) {
            for (size_t i = 0; i < server->hashLen; i++) { hxor[i] = (uint8_t)(hn[i] ^ hg[i]); }
            const uint8_t *iParts[1] = { server->identity };
            const size_t iLens[1] = { server->identityLen };
            m1ok = A2RPSRPXHashParts(server->hash, server->hashLen, iParts, iLens, 1, hi);
        }
        if (m1ok) {
            newM1 = (uint8_t *)malloc(server->hashLen);
            const uint8_t *m1Parts[6] = { hxor, hi, server->saltBytes, newA, server->bBytes, newK };
            const size_t m1Lens[6] = { server->hashLen, server->hashLen, server->saltBytesLen,
                                       newALen, server->bBytesLen, server->hashLen };
            m1ok = (newM1 != NULL)
                && A2RPSRPXHashParts(server->hash, server->hashLen, m1Parts, m1Lens, 6, newM1);
        }
        // M2 = H(A_min | M1 | K)
        if (m1ok) {
            newM2 = (uint8_t *)malloc(server->hashLen);
            const uint8_t *m2Parts[3] = { newA, newM1, newK };
            const size_t m2Lens[3] = { newALen, server->hashLen, server->hashLen };
            m1ok = (newM2 != NULL)
                && A2RPSRPXHashParts(server->hash, server->hashLen, m2Parts, m2Lens, 3, newM2);
        }
        free(nMin); free(gMin); free(hi);
        ok = ok && m1ok;
    }

    if (ok) {
        A2RPSRPXBufFree(&server->uBytes, &server->uBytesLen);
        A2RPSRPXBufFree(&server->sBytes, &server->sBytesLen);
        A2RPSRPXBufFree(&server->keyBytes, &server->keyBytesLen);
        A2RPSRPXBufFree(&server->m1Bytes, &server->m1BytesLen);
        A2RPSRPXBufFree(&server->m2Bytes, &server->m2BytesLen);
        A2RPSRPXBufFree(&server->aBytes, &server->aBytesLen);
        server->uBytes = newU; server->uBytesLen = newULen;
        server->sBytes = newS; server->sBytesLen = newSLen;
        server->keyBytes = newK; server->keyBytesLen = server->hashLen;
        server->m1Bytes = newM1; server->m1BytesLen = server->hashLen;
        server->m2Bytes = newM2; server->m2BytesLen = server->hashLen;
        server->aBytes = newA; server->aBytesLen = newALen;
        newU = NULL; newS = NULL; newK = NULL; newM1 = NULL; newM2 = NULL; newA = NULL;
        server->hasKey = YES;
    } else if (reason && *reason == nil) {
        *reason = @"SRP 服务端算密钥失败";
    }

    mbedtls_mpi_free(&Ampi); mbedtls_mpi_free(&Amod); mbedtls_mpi_free(&uNew);
    mbedtls_mpi_free(&vu); mbedtls_mpi_free(&base); mbedtls_mpi_free(&SNew);
    free(padA); free(padB); free(uBuf);
    free(newU); free(newS); free(newA); free(newK); free(newM1); free(newM2);
    return ok;
}

BOOL A2RPSRPServerVerifyM1(A2RPSRPServer *server, const uint8_t *m1, size_t m1Len) {
    if (server == NULL || !server->hasKey || m1 == NULL || server->m1Bytes == NULL) { return NO; }
    if (m1Len != server->m1BytesLen) { return NO; }
    uint8_t diff = 0;
    for (size_t i = 0; i < m1Len; i++) {
        diff |= (uint8_t)(server->m1Bytes[i] ^ m1[i]);
    }
    return diff == 0;
}

const uint8_t *A2RPSRPServerProofM2(A2RPSRPServer *server, size_t *lenOut) {
    if (server == NULL || !server->hasKey || server->m2Bytes == NULL) { return NULL; }
    if (lenOut) { *lenOut = server->m2BytesLen; }
    return server->m2Bytes;
}

const uint8_t *A2RPSRPServerSessionKey(A2RPSRPServer *server, size_t *lenOut) {
    if (server == NULL || !server->hasKey || server->keyBytes == NULL) { return NULL; }
    if (lenOut) { *lenOut = server->keyBytesLen; }
    return server->keyBytes;
}

BOOL A2RPSRPServerTrace(A2RPSRPServer *server, A2RPSRPTrace *out) {
    if (server == NULL || out == NULL) { return NO; }
    memset(out, 0, sizeof(*out));
    if (server->kBytes) { memcpy(out->k, server->kBytes, server->kLen); out->kLen = server->kLen; }
    if (server->xBytes) { memcpy(out->x, server->xBytes, server->xBytesLen); out->xLen = server->xBytesLen; }
    if (server->uBytes) { memcpy(out->u, server->uBytes, server->uBytesLen); out->uLen = server->uBytesLen; }
    if (server->vBytes) { memcpy(out->v, server->vBytes, server->vBytesLen); out->vLen = server->vBytesLen; }
    if (server->aBytes) { memcpy(out->A, server->aBytes, server->aBytesLen); out->aLen = server->aBytesLen; }
    if (server->bBytes) { memcpy(out->B, server->bBytes, server->bBytesLen); out->bLen = server->bBytesLen; }
    if (server->sBytes) { memcpy(out->S, server->sBytes, server->sBytesLen); out->sLen = server->sBytesLen; }
    if (server->keyBytes) { memcpy(out->K, server->keyBytes, server->keyBytesLen); out->keyLen = server->keyBytesLen; }
    if (server->m1Bytes) { memcpy(out->M1, server->m1Bytes, server->m1BytesLen); out->m1Len = server->m1BytesLen; }
    if (server->m2Bytes) { memcpy(out->M2, server->m2Bytes, server->m2BytesLen); out->m2Len = server->m2BytesLen; }
    return YES;
}
