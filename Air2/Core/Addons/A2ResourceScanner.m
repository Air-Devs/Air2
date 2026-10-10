//
//  A2ResourceScanner.m
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

#import "A2ResourceScanner.h"
#import "A2ResourcePack.h"
#import "A2GameFiles.h"
#import "A2ZipReader.h"
#import "A2Strings.h"
#import "A2Log.h"

@interface A2ResourceScanner ()

@property (nonatomic, strong) A2GameFiles *files;

@end

/// 简介：字符串直接用，{text} 取 text，其余按缺失处理。
static NSString *A2PackDescription(id value) {
    if ([value isKindOfClass:NSString.class]) return A2NonEmptyString(value);
    if ([value isKindOfClass:NSDictionary.class]) {
        return A2NonEmptyString(((NSDictionary *)value)[@"text"]);
    }
    return nil;
}

/// 无扩展名的展示基名（文件夹名原样，文件名去扩展）。
static NSString *A2PackBaseName(NSString *fileName, BOOL isDirectory) {
    if (isDirectory) return fileName.length > 0 ? fileName : @"?";
    NSString *base = [fileName stringByDeletingPathExtension];
    return base.length > 0 ? base : fileName;
}

/// 由 pack.mcmeta 组装（meta 为 nil 即无效，照常建模不抛）。
static A2ResourcePack *A2PackFromMeta(NSString *fileName, BOOL isDirectory, long long fileSize,
                                      NSDictionary *metaOrNil) {
    id pack = [metaOrNil isKindOfClass:NSDictionary.class] ? metaOrNil[@"pack"] : nil;
    NSInteger format = -1;
    NSString *summary = nil;
    BOOL valid = NO;
    if ([pack isKindOfClass:NSDictionary.class]) {
        id rawFormat = ((NSDictionary *)pack)[@"pack_format"];
        if ([rawFormat isKindOfClass:NSNumber.class]) {
            format = [(NSNumber *)rawFormat integerValue];
            valid = YES;
        }
        summary = A2PackDescription(((NSDictionary *)pack)[@"description"]);
    }
    NSString *displayName = summary ?: A2PackBaseName(fileName, isDirectory);
    return [[A2ResourcePack alloc] initWithFileName:fileName
                                        displayName:displayName
                                          directory:isDirectory
                                         packFormat:format
                                            summary:summary
                                           fileSize:fileSize
                                              valid:valid];
}

@implementation A2ResourceScanner

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：无目录的扫描器是非法状态。
    return nil;
}

- (nullable instancetype)initWithResourcePacksDirectory:(NSString *)dir error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    A2GameFiles *files = [[A2GameFiles alloc] initWithRootPath:dir error:error];
    if (!files) return nil;
    _files = files;
    _resourcePacksDirectory = [files.rootPath copy];
    return self;
}

/// 单项解析：文件夹读 pack.mcmeta 文件，zip 读同名条目，其余跳过（nil）。
- (nullable A2ResourcePack *)packForEntry:(A2GameFileEntry *)entry {
    if (entry.isDirectory) {
        NSString *metaPath = [[self.resourcePacksDirectory
                               stringByAppendingPathComponent:entry.name]
                              stringByAppendingPathComponent:@"pack.mcmeta"];
        NSData *data = [NSData dataWithContentsOfFile:metaPath];
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *meta = [obj isKindOfClass:NSDictionary.class] ? obj : nil;
        return A2PackFromMeta(entry.name, YES, -1, meta);
    }
    NSString *ext = [[entry.name pathExtension] lowercaseString];
    if (![ext isEqualToString:@"zip"]) return nil;
    // 全路径同模组扫描：名来自作用域清单，不可能含 /，拼完再标准化兜底。
    NSString *fullPath = [[self.resourcePacksDirectory stringByAppendingPathComponent:entry.name]
                          stringByStandardizingPath];
    A2ZipReader *zip = [[A2ZipReader alloc] initWithPath:fullPath];
    if (!zip) return A2PackFromMeta(entry.name, NO, entry.fileSize, nil);
    NSData *data = [zip dataForEntry:@"pack.mcmeta"];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *meta = [obj isKindOfClass:NSDictionary.class] ? obj : nil;
    return A2PackFromMeta(entry.name, NO, entry.fileSize, meta);
}

- (nullable NSArray<A2ResourcePack *> *)scanPacks:(NSError **)error {
    NSArray<A2GameFileEntry *> *entries = [self.files entriesInDirectory:@"" error:error];
    if (!entries) return nil;
    NSMutableArray<A2ResourcePack *> *out = [NSMutableArray array];
    for (A2GameFileEntry *entry in entries) {
        A2ResourcePack *pack = [self packForEntry:entry];
        if (pack) [out addObject:pack];
    }
    [out sortUsingComparator:^NSComparisonResult(A2ResourcePack *a, A2ResourcePack *b) {
        return [a.fileName compare:b.fileName];
    }];
    [A2Log log:@"resourcepack: 扫描 %@，%lu 个", self.resourcePacksDirectory,
             (unsigned long)out.count];
    return out;
}

@end
