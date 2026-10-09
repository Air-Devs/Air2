//
//  A2ResourcePack.m
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

#import "A2ResourcePack.h"

@implementation A2ResourcePack

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：字段缺失的模型是非法状态。
    return nil;
}

- (instancetype)initWithFileName:(NSString *)fileName
                     displayName:(NSString *)displayName
                       directory:(BOOL)directory
                      packFormat:(NSInteger)packFormat
                         summary:(nullable NSString *)summary
                        fileSize:(long long)fileSize
                           valid:(BOOL)valid {
    self = [super init];
    if (!self) return nil;
    _fileName = [fileName copy] ?: @"";
    _displayName = [displayName copy] ?: _fileName;
    _directory = directory;
    _packFormat = packFormat;
    _summary = [summary copy];
    _fileSize = fileSize;
    _valid = valid;
    return self;
}

@end
