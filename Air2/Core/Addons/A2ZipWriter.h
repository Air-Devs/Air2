//
//  A2ZipWriter.h
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
//
//
//  A2ZipWriter.h
//  Air2
//
//  最小可用的 zip 写入器。
//
//  与 A2ZipReader 对称 —— iOS 没有公开的 zip 打包 API，
//  而整合包导出需要把一堆文件打成一个 zip。
//
//  实现策略：全部用 stored（不压缩）。
//  理由：整合包里的内容多数已经是压缩过的（jar 是 zip、图片是 png），
//  再压一遍收益很小；而 deflate 需要引 zlib 并处理流式写入，
//  复杂度不成比例。ZL2 用 Java 的 ZipOutputStream 可以做压缩，
//  但它的整合包导出对体积也不敏感。
//
//  支持：stored 写入、目录条目
//  不支持：zip64（>4GB）、加密
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2ZipWriter : NSObject

/// 创建新的 zip 文件（已存在会被覆盖）
- (nullable instancetype)initWithPath:(NSString *)path;

/// 添加一个条目。
/// @param data 文件内容
/// @param entryName zip 内的路径（用 / 分隔）
- (BOOL)addData:(NSData *)data entryName:(NSString *)entryName;

/// 添加磁盘上的文件
- (BOOL)addFileAtPath:(NSString *)filePath entryName:(NSString *)entryName;

/// 以指定前缀递归添加整个目录
- (BOOL)addDirectoryAtPath:(NSString *)dirPath prefix:(nullable NSString *)prefix;

/// 完成并关闭（必须调用，否则中央目录不完整）
- (BOOL)finish;

@end

NS_ASSUME_NONNULL_END
