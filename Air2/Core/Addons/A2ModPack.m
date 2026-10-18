//
//  A2ModPack.m
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
//  见头文件：只解析清单，不下载、不解压 overrides（执行层另起任务）。
//  字段缺失按“可空”处理：名字取不到就用文件名，下载地址取不到就记 nil
//  让执行层跳过而不是崩；required 语义两边对齐（CF 可选 vs MR 服务端排除）。
//

#import "A2ModPack.h"
#import "A2ZipReader.h"

NSString *const A2ModPackErrorDomain = @"A2ModPack";

static NSString *const kCFManifestName = @"manifest.json";
static NSString *const kMRIndexName = @"modrinth.index.json";

@implementation A2ModPackFile

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：无路径的文件项是非法的。
    // 保留实现体满足声明/实现一致性检查；正常代码走不到这里。
    return nil;
}

- (instancetype)initWithRelativePath:(NSString *)relativePath
                         downloadURL:(NSString *)downloadURL
                                sha1:(NSString *)sha1
                            fileSize:(long long)fileSize
                            required:(BOOL)required {
    self = [super init];
    if (!self) return nil;
    _relativePath = [relativePath copy];
    _downloadURL = [downloadURL copy];
    _sha1 = [sha1 copy];
    _fileSize = fileSize;
    _required = required;
    return self;
}

@end

@interface A2ModPackPlan ()
@property (nonatomic, assign) A2ModPackFormat format;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic, copy, nullable) NSString *gameVersion;
@property (nonatomic, copy, nullable) NSString *loaderID;
@property (nonatomic, copy, nullable) NSString *overridesDir;
@property (nonatomic, copy) NSArray<A2ModPackFile *> *files;
@end

@implementation A2ModPackPlan
@end

