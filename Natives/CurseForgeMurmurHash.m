//
//  CurseForgeMurmurHash.m
//  Amethyst
//
//  CurseForge MurmurHash2 文件指纹计算（mod "检测更新"指纹反查用）
//
//  修复原因：ModUpdateService 原先直接把 mod.filePath 字符串传给
//  CurseForgeAPI projectForFileHash:，内部 [murmurHash longLongValue] 对
//  文件路径恒为 0，指纹永不命中。本文件提供本地真实指纹计算。
//
//  算法说明（已在沙箱实测验证，2026-08）：
//  CurseForge 的指纹是 MurmurHash2（32 位，种子 1），且计算前必须过滤
//  0x09(tab)/0x0a(LF)/0x0d(CR)/0x20(space) 四个空白字节（与 Modrinth 的
//  全量 sha1 不同）。实测依据：sodium-fabric-0.5.13+mc1.20.1.jar 全量字节
//  murmur2=1718316660 提交 /v1/fingerprints/432 后落在 unmatchedFingerprints；
//  过滤空白字节后 murmur2=2838862230 则命中 exactMatches（file.modId=394468）。
//  JEI 15.49.0.191 同样只有过滤变体（2268438859）命中（file.modId=238222）。
//  与仓库既有 MurmurHash2.m（流式实现）及 packwiz/murmwur 等参考实现一致。
//

#import "CurseForgeMurmurHash.h"
#include <stdint.h>
#include <stdlib.h>

// MurmurHash2 算法常量
static const uint32_t kCFMurmur2_M = 0x5bd1e995u;
static const int kCFMurmur2_R = 24;
static const uint32_t kCFMurmur2_Seed = 1u;

uint32_t CFMurmurHash2(const uint8_t *data, size_t len) {
    uint32_t h = kCFMurmur2_Seed ^ (uint32_t)len;
    while (len >= 4) {
        // 小端序组装 4 字节块
        uint32_t k = ((uint32_t)data[0])
                   | ((uint32_t)data[1] << 8)
                   | ((uint32_t)data[2] << 16)
                   | ((uint32_t)data[3] << 24);
        // 核心混淆
        k *= kCFMurmur2_M;
        k ^= k >> kCFMurmur2_R;
        k *= kCFMurmur2_M;
        h *= kCFMurmur2_M;
        h ^= k;
        data += 4;
        len -= 4;
    }
    // 尾部不足 4 字节（故意 fall-through，与标准实现一致）
    switch (len) {
        case 3:
            h ^= ((uint32_t)data[2]) << 16;
            // fall through
        case 2:
            h ^= ((uint32_t)data[1]) << 8;
            // fall through
        case 1:
            h ^= (uint32_t)data[0];
            h *= kCFMurmur2_M;
            break;
        default:
            break;
    }
    // 最终混合
    h ^= h >> 13;
    h *= kCFMurmur2_M;
    h ^= h >> 15;
    return h;
}

@implementation CurseForgeMurmurHash

+ (uint32_t)fingerprintForFileAtPath:(NSString *)path {
    if (path.length == 0) return 0;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length == 0 || data.length > UINT32_MAX) return 0;

    const uint8_t *src = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    // 过滤空白字节后的缓冲（最坏情况等于原始长度）
    uint8_t *filtered = malloc(length);
    if (!filtered) return 0;
    NSUInteger filteredLen = 0;
    for (NSUInteger i = 0; i < length; i++) {
        uint8_t b = src[i];
        if (b == 0x09 || b == 0x0a || b == 0x0d || b == 0x20) continue;
        filtered[filteredLen++] = b;
    }
    uint32_t fingerprint = CFMurmurHash2(filtered, filteredLen);
    free(filtered);
    return fingerprint;
}

@end
