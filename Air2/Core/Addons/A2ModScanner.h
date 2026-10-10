//
//  A2ModScanner.h
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
//  mods 目录扫描与启用开关 —— 目录内容与模型之间的唯一桥梁。
//
//  职责：列目录 → 逐个解析身份 → 按文件名排序；启用/禁用改名。
//  删除走通用文件后端（与模组无关，不需要懂元数据），不在这里。
//  模型不可变：开关成功后调用方重扫，返回的旧模型即过期。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class A2LocalMod;

@interface A2ModScanner : NSObject

/// mods 目录（标准化后的绝对路径）。
@property (nonatomic, copy, readonly) NSString *modsDirectory;

/// root 不存在即失败（缺目录本身就是异常信号，不静默创建）。
- (nullable instancetype)initWithModsDirectory:(NSString *)dir error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// 扫描全部文件：解析成功给身份，失败给 notMod 兜底（列表永不崩）。
/// 按文件名排序；目录返回 nil 并填 error。
/// 同步执行且逐个读 jar，大目录请放后台线程调（调用方负责切线程）。
- (nullable NSArray<A2LocalMod *> *)scanMods:(NSError **)error;

/// 切换启用态（同目录改名语义）。已是目标状态直接成功；
/// 成功后请重扫。失败返回 NO 并填 error。
- (BOOL)applyMod:(A2LocalMod *)mod enabled:(BOOL)enabled error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
