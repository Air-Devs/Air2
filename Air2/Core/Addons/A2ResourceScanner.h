//
//  A2ResourceScanner.h
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
//  resourcepacks 目录扫描 —— 目录内容与模型之间的唯一桥梁。
//
//  只认文件夹与 zip（游戏只能加载这两种，其余跳过不列）。
//  元数据坏了记无效（照常列出），不因一个坏包崩列表。
//  资源包没有启用开关（游戏靠选项列表，不靠后缀），故无开关方法。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class A2ResourcePack;

@interface A2ResourceScanner : NSObject

/// resourcepacks 目录（标准化后的绝对路径）。
@property (nonatomic, copy, readonly) NSString *resourcePacksDirectory;

/// root 不存在即失败（缺目录本身就是异常信号，不静默创建）。
- (nullable instancetype)initWithResourcePacksDirectory:(NSString *)dir
                                                 error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// 扫描全部：文件夹与 zip 逐个解析，元数据坏的记无效；
/// 其它文件跳过。按文件名排序；目录取不到返回 nil 并填 error。
/// 同步执行，大目录请放后台线程调。
- (nullable NSArray<A2ResourcePack *> *)scanPacks:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
