//
//  A2LocalMod.m
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
//  实现见头文件。
//

#import "A2LocalMod.h"

NSString *A2ModLoaderKindDisplayName(A2ModLoaderKind kind) {
    switch (kind) {
        case A2ModLoaderKindFabric: return @"Fabric";
        case A2ModLoaderKindForge: return @"Forge";
        case A2ModLoaderKindQuilt: return @"Quilt";
        case A2ModLoaderKindNeoForge: return @"NeoForge";
        case A2ModLoaderKindOptiFine: return @"OptiFine";
        default: return @"Unknown";
    }
}

@implementation A2LocalMod

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：字段缺失的模型是非法状态。
    // 声明/实现一致性检查要求每个声明都有实现；正常代码走不到这里。
    return nil;
}

- (instancetype)initWithFileName:(NSString *)fileName
                    displayName:(NSString *)displayName
                          modID:(nullable NSString *)modID
                        version:(nullable NSString *)version
                        authors:(nullable NSArray<NSString *> *)authors
                        summary:(nullable NSString *)summary
                     loaderKind:(A2ModLoaderKind)loaderKind
                       fileSize:(long long)fileSize
                        enabled:(BOOL)enabled
                         notMod:(BOOL)notMod {
    self = [super init];
    if (!self) return nil;
    _fileName = [fileName copy] ?: @"";
    _displayName = [displayName copy] ?: _fileName;
    _modID = [modID copy] ?: @"";
    _version = [version copy];
    _authors = [authors copy] ?: @[];
    _summary = [summary copy];
    _loaderKind = loaderKind;
    _fileSize = fileSize;
    _enabled = enabled;
    _notMod = notMod;
    return self;
}

@end
