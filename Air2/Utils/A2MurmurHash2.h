//
//  A2MurmurHash2.h
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
//  MurmurHash2 32-bit（Austin Appleby 公开算法），与 Minecraft 无关，
//  故放在 Utils（叶子层，不反向依赖业务层）。
//
//  算法决策（对照 ZL2 MurmurHash2Incremental + commons-codec 参考实现）：
//    · 常量 M = 0x5bd1e995、R = 24，seed 由调用方给（CurseForge 用 1）。
//    · 支持按字节值过滤（如 CurseForge 指纹剔除 0x09/0x0A/0x0D/0x20），
//      过滤后的长度参与初始 h（len 在过滤后统计，不是原文件大小）。
//    · 文件版分两次扫描：先统计过滤长度，再算哈希（ZL2 同款，
//      避免把整个 jar 读进内存）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2MurmurHash2 : NSObject

/// 内存版 MurmurHash2-32。data 为空按长度 0 处理。
+ (uint32_t)hash32OfData:(NSData *)data seed:(uint32_t)seed;

/// 文件版：流式两次扫描，可选剔除字节值集合（0-255），nil/空表示不过滤。
/// 失败返回 0 并填 error（调用方把 0 当“算不出”，不要当有效指纹用）。
+ (uint32_t)hash32OfFileAtPath:(NSString *)path
                     skipBytes:(nullable NSSet<NSNumber *> *)skipBytes
                          seed:(uint32_t)seed
                         error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
