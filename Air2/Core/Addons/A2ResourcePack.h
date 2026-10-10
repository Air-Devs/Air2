//
//  A2ResourcePack.h
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
//  本地资源包身份 —— resourcepacks 目录里一项（文件夹或 zip）的解析结果。
//
//  只描述数据形状，不读文件（扫描在 A2ResourceScanner）。
//  图标（pack.png）本刀不读：取图要异步管线，另起设计，模型里不留占位字段。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一个已解析（或明确无效）的本地资源包。
@interface A2ResourcePack : NSObject

/// 磁盘名（文件夹名或 zip 名，原样保留，供删除定位）。
@property (nonatomic, copy, readonly) NSString *fileName;
/// 展示名（简介文本；没有简介回落到去扩展的文件名）。
@property (nonatomic, copy, readonly) NSString *displayName;
/// 是否文件夹形式（zip 为 NO）。
@property (nonatomic, assign, readonly, getter=isDirectory) BOOL directory;
/// pack_format；解析失败时为 -1。
@property (nonatomic, assign, readonly) NSInteger packFormat;
/// 简介文本；缺失或非文本时为 nil。
@property (nonatomic, copy, readonly, nullable) NSString *summary;
/// 文件字节数；文件夹不递归统计，记 -1。
@property (nonatomic, assign, readonly) long long fileSize;
/// pack.mcmeta 解析成功且 pack_format 合法。
@property (nonatomic, assign, readonly, getter=isValid) BOOL valid;

- (instancetype)initWithFileName:(NSString *)fileName
                     displayName:(NSString *)displayName
                       directory:(BOOL)directory
                      packFormat:(NSInteger)packFormat
                         summary:(nullable NSString *)summary
                        fileSize:(long long)fileSize
                           valid:(BOOL)valid NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
