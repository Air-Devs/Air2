//
//  A2MurmurHash2.m
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
//  见头文件：标准 MurmurHash2-32，全部运算按 32 位无符号回绕。
//  ObjC 没有 Kotlin 的 ushr/ULong 语义，这里用 uint32_t + 显式掩码对齐。
//

#import "A2MurmurHash2.h"

static const uint32_t kM32 = 0x5bd1e995u;
static const uint32_t kR32 = 24u;

@implementation A2MurmurHash2

+ (uint32_t)hash32OfData:(NSData *)data seed:(uint32_t)seed {
    // 空输入的哈希仍要走尾部雪崩，不能直接返回 seed。
    uint32_t len = (uint32_t)data.length;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    uint32_t h = seed ^ len;

    uint32_t i = 0;
    // 每次 4 字节小端组 k（与平台端序无关，逐字节拼）。
    for (; i + 4 <= len; i += 4) {
        uint32_t k = ((uint32_t)bytes[i])
            | ((uint32_t)bytes[i + 1] << 8)
            | ((uint32_t)bytes[i + 2] << 16)
            | ((uint32_t)bytes[i + 3] << 24);
        k *= kM32;
        k ^= k >> kR32;
        k *= kM32;
        h *= kM32;
        h ^= k;
    }
    // 尾部 0-3 字节：ZL2 用“异或后整体乘 M”，与 commons-codec 一致。
    uint32_t tail = len - i;
    if (tail == 3) {
        h ^= (uint32_t)bytes[i + 2] << 16;
        h ^= (uint32_t)bytes[i + 1] << 8;
        h ^= (uint32_t)bytes[i];
        h *= kM32;
    } else if (tail == 2) {
        h ^= (uint32_t)bytes[i + 1] << 8;
        h ^= (uint32_t)bytes[i];
        h *= kM32;
    } else if (tail == 1) {
        h ^= (uint32_t)bytes[i];
        h *= kM32;
    }
    // 最终雪崩（ZL2 与参考实现相同三步）。
    h ^= h >> 13;
    h *= kM32;
    h ^= h >> 15;
    return h;
}

+ (uint32_t)hash32OfFileAtPath:(NSString *)path
                     skipBytes:(NSSet<NSNumber *> *)skipBytes
                          seed:(uint32_t)seed
                         error:(NSError **)error {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        if (error) *error = [NSError errorWithDomain:@"A2MurmurHash2" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"打不开文件"}];
        return 0;
    }

    // 256 查表：逐字节判断时避免集合查找（ZL2 同款 skipTable 决策）。
    BOOL skip[256] = { NO };
    for (NSNumber *n in skipBytes) {
        NSInteger v = n.integerValue;
        if (v >= 0 && v < 256) skip[v] = YES;
    }
    BOOL filtering = skipBytes.count > 0;

    // 第一遍：统计过滤后长度（哈希初始 h 要用它，不是文件大小）。
    uint32_t filteredLen = 0;
    @try {
        [handle seekToFileOffset:0];
        while (YES) {
            NSData *chunk = [handle readDataOfLength:8192];
            if (chunk.length == 0) break;
            const uint8_t *b = (const uint8_t *)chunk.bytes;
            if (!filtering) {
                filteredLen += (uint32_t)chunk.length;
            } else {
                for (NSUInteger i = 0; i < chunk.length; i++) {
                    if (!skip[b[i]]) filteredLen++;
                }
            }
        }
    } @catch (NSException *e) {
        [handle closeFile];
        if (error) *error = [NSError errorWithDomain:@"A2MurmurHash2" code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"读文件失败"}];
        return 0;
    }

    // 第二遍：增量哈希（4 字节一组，不足一组进尾部逻辑）。
    uint32_t h = seed ^ filteredLen;
    uint8_t buf[4];
    int bufCount = 0;
    @try {
        [handle seekToFileOffset:0];
        while (YES) {
            NSData *chunk = [handle readDataOfLength:8192];
            if (chunk.length == 0) break;
            const uint8_t *b = (const uint8_t *)chunk.bytes;
            for (NSUInteger i = 0; i < chunk.length; i++) {
                if (filtering && skip[b[i]]) continue;
                buf[bufCount++] = b[i];
                if (bufCount == 4) {
                    uint32_t k = ((uint32_t)buf[0])
                        | ((uint32_t)buf[1] << 8)
                        | ((uint32_t)buf[2] << 16)
                        | ((uint32_t)buf[3] << 24);
                    k *= kM32;
                    k ^= k >> kR32;
                    k *= kM32;
                    h *= kM32;
                    h ^= k;
                    bufCount = 0;
                }
            }
        }
    } @catch (NSException *e) {
        [handle closeFile];
        if (error) *error = [NSError errorWithDomain:@"A2MurmurHash2" code:-3
                                            userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"读文件失败"}];
        return 0;
    }
    [handle closeFile];

    if (bufCount == 3) {
        h ^= (uint32_t)buf[2] << 16;
        h ^= (uint32_t)buf[1] << 8;
        h ^= (uint32_t)buf[0];
        h *= kM32;
    } else if (bufCount == 2) {
        h ^= (uint32_t)buf[1] << 8;
        h ^= (uint32_t)buf[0];
        h *= kM32;
    } else if (bufCount == 1) {
        h ^= (uint32_t)buf[0];
        h *= kM32;
    }
    h ^= h >> 13;
    h *= kM32;
    h ^= h >> 15;
    return h;
}

@end
