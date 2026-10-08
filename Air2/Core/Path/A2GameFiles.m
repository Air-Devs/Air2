//
//  A2GameFiles.m
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
//  见头文件：越界用“失败”而不用“截断”，目录大小不递归统计。
//  路径比较用标准化 + 分隔符边界，避免 /foo/bar 与 /foo/bar2 的前缀误判。
//

#import "A2GameFiles.h"

NSString *const A2GameFilesErrorDomain = @"A2GameFiles";

@implementation A2GameFileEntry

- (instancetype)initWithName:(NSString *)name
                 isDirectory:(BOOL)isDirectory
                    fileSize:(long long)fileSize
            modificationDate:(NSDate *)date {
    self = [super init];
    if (!self) return nil;
    _name = [name copy];
    _isDirectory = isDirectory;
    _fileSize = fileSize;
    _modificationDate = date;
    return self;
}

@end

@implementation A2GameFiles

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：无 root 的实例是非法状态。
    // 保留实现体是因为声明/实现一致性检查要求每个声明都有实现；
    // 正常代码走不到这里（编译期已拦截），走到即返回 nil。
    return nil;
}

- (instancetype)initWithRootPath:(NSString *)rootPath error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    // root 不存在/不是目录就是调用方 bug（版本目录缺失），不在这里静默创建。
    BOOL isDir = NO;
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:rootPath isDirectory:&isDir];
    if (!exists || !isDir) {
        if (error) *error = [NSError errorWithDomain:A2GameFilesErrorDomain
                                                code:A2GameFilesErrorIO
                                            userInfo:@{NSLocalizedDescriptionKey: @"游戏目录不存在"}];
        return nil;
    }
    _rootPath = [[rootPath stringByStandardizingPath] copy];
    return self;
}

#pragma mark - 路径守卫

// 相对路径拼到 root 并标准化；越界返回 nil。
- (NSString *)guardedPathForRelativePath:(NSString *)relativePath error:(NSError **)error {
    NSString *rel = relativePath.length ? relativePath : @"";
    // 绝对路径不接受：调用方只能给相对路径，避免绕过守卫。
    if ([rel hasPrefix:@"/"]) {
        if (error) *error = [self scopeError];
        return nil;
    }
    NSString *joined = rel.length ? [self.rootPath stringByAppendingPathComponent:rel] : self.rootPath;
    NSString *standard = [joined stringByStandardizingPath];
    // 分隔符边界比较：root 本身放行，否则必须以 root/ 开头。
    if ([standard isEqualToString:self.rootPath]) return standard;
    NSString *prefix = [self.rootPath stringByAppendingString:@"/"];
    if (![standard hasPrefix:prefix]) {
        if (error) *error = [self scopeError];
        return nil;
    }
    return standard;
}

- (NSError *)scopeError {
    return [NSError errorWithDomain:A2GameFilesErrorDomain
                               code:A2GameFilesErrorOutOfScope
                           userInfo:@{NSLocalizedDescriptionKey: @"路径超出游戏目录范围"}];
}

- (NSError *)ioError:(NSError *)underlying message:(NSString *)message {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (message) info[NSLocalizedDescriptionKey] = message;
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:A2GameFilesErrorDomain code:A2GameFilesErrorIO userInfo:info];
}

#pragma mark - 操作

- (NSArray<A2GameFileEntry *> *)entriesInDirectory:(NSString *)relativePath
                                             error:(NSError **)error {
    NSString *dir = [self guardedPathForRelativePath:relativePath error:error];
    if (!dir) return nil;
    NSError *listErr = nil;
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir
                                                                                   error:&listErr];
    if (!names) {
        if (error) *error = [self ioError:listErr message:@"列目录失败"];
        return nil;
    }
    NSMutableArray<A2GameFileEntry *> *out = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) {
        // 跳过 .DS_Store 这类系统文件，保持列表干净。
        if ([name hasPrefix:@".DS_Store"]) continue;
        NSString *full = [dir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:full error:nil];
        NSString *type = attrs[NSFileType];
        BOOL isDir = [type isEqualToString:NSFileTypeDirectory];
        long long size = -1;
        if (!isDir) {
            NSNumber *n = attrs[NSFileSize];
            size = [n isKindOfClass:NSNumber.class] ? n.longLongValue : 0;
        }
        A2GameFileEntry *e = [[A2GameFileEntry alloc] initWithName:name
                                                      isDirectory:isDir
                                                         fileSize:size
                                                 modificationDate:attrs[NSFileModificationDate]];
        [out addObject:e];
    }
    // 目录优先、名称升序（ZL2 列表同款排序，localizedCompare 适配中文）。
    [out sortUsingComparator:^NSComparisonResult(A2GameFileEntry *a, A2GameFileEntry *b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedStandardCompare:b.name];
    }];
    return [out copy];
}

- (BOOL)createDirectory:(NSString *)name
           inDirectory:(NSString *)relativePath
                 error:(NSError **)error {
    if (![A2GameFiles validateFileName:name error:error]) return NO;
    NSString *dir = [self guardedPathForRelativePath:relativePath error:error];
    if (!dir) return NO;
    NSString *target = [[dir stringByAppendingPathComponent:name] stringByStandardizingPath];
    // 二次守卫：name 合法也不应拼出界（防御未来改动）。
    if (![self isUnderRoot:target]) {
        if (error) *error = [self scopeError];
        return NO;
    }
    NSError *ioErr = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:target
                                 withIntermediateDirectories:NO
                                                  attributes:nil
                                                       error:&ioErr]) {
        if (error) *error = [self ioError:ioErr message:@"创建文件夹失败"];
        return NO;
    }
    return YES;
}

- (BOOL)renameEntryAt:(NSString *)relativePath
               toName:(NSString *)newName
                error:(NSError **)error {
    if (![A2GameFiles validateFileName:newName error:error]) return NO;
    NSString *src = [self guardedPathForRelativePath:relativePath error:error];
    if (!src) return NO;
    // 根目录本身不允许改名。
    if ([src isEqualToString:self.rootPath]) {
        if (error) *error = [NSError errorWithDomain:A2GameFilesErrorDomain
                                                code:A2GameFilesErrorInvalidName
                                            userInfo:@{NSLocalizedDescriptionKey: @"不能重命名根目录"}];
        return NO;
    }
    NSString *dest = [[[src stringByDeletingLastPathComponent]
                        stringByAppendingPathComponent:newName] stringByStandardizingPath];
    if (![self isUnderRoot:dest]) {
        if (error) *error = [self scopeError];
        return NO;
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:dest]) {
        if (error) *error = [NSError errorWithDomain:A2GameFilesErrorDomain
                                                code:A2GameFilesErrorInvalidName
                                            userInfo:@{NSLocalizedDescriptionKey: @"同名文件已存在"}];
        return NO;
    }
    NSError *ioErr = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:src toPath:dest error:&ioErr]) {
        if (error) *error = [self ioError:ioErr message:@"重命名失败"];
        return NO;
    }
    return YES;
}

- (BOOL)deleteEntryAt:(NSString *)relativePath error:(NSError **)error {
    NSString *target = [self guardedPathForRelativePath:relativePath error:error];
    if (!target) return NO;
    // 根目录不允许删除（版本目录删了整个版本就没了，走版本删除流程）。
    if ([target isEqualToString:self.rootPath]) {
        if (error) *error = [NSError errorWithDomain:A2GameFilesErrorDomain
                                                code:A2GameFilesErrorInvalidName
                                            userInfo:@{NSLocalizedDescriptionKey: @"不能删除根目录"}];
        return NO;
    }
    NSError *ioErr = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:target error:&ioErr]) {
        if (error) *error = [self ioError:ioErr message:@"删除失败"];
        return NO;
    }
    return YES;
}

- (BOOL)isUnderRoot:(NSString *)standardPath {
    if ([standardPath isEqualToString:self.rootPath]) return YES;
    return [standardPath hasPrefix:[self.rootPath stringByAppendingString:@"/"]];
}

+ (BOOL)validateFileName:(NSString *)name error:(NSError **)error {
    // 空名、路径分隔符、. / ..、首尾空格、超长逐项拒绝，错误信息直接可展示。
    if (name.length == 0) {
        if (error) *error = [NSError errorWithDomain:A2GameFilesErrorDomain
                                                code:A2GameFilesErrorInvalidName
                                            userInfo:@{NSLocalizedDescriptionKey: @"文件名不能为空"}];
        return NO;
    }
    if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        if (error) *error = [NSError errorWithDomain:A2GameFilesErrorDomain
                                                code:A2GameFilesErrorInvalidName
                                            userInfo:@{NSLocalizedDescriptionKey: @"文件名非法"}];
        return NO;
    }
    if ([name containsString:@"/"]) {
        if (error) *error = [NSError errorWithDomain:A2GameFilesErrorDomain
                                                code:A2GameFilesErrorInvalidName
                                            userInfo:@{NSLocalizedDescriptionKey: @"文件名不能包含 /"}];
        return NO;
    }
    if ([name hasPrefix:@" "] || [name hasSuffix:@" "] ||
        [name hasPrefix:@"\t"] || [name hasSuffix:@"\t"]) {
        if (error) *error = [NSError errorWithDomain:A2GameFilesErrorDomain
                                                code:A2GameFilesErrorInvalidName
                                            userInfo:@{NSLocalizedDescriptionKey: @"首尾不能是空格"}];
        return NO;
    }
    // HFS+/APFS 单文件名上限 255 UTF-8 字节。
    if ([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255) {
        if (error) *error = [NSError errorWithDomain:A2GameFilesErrorDomain
                                                code:A2GameFilesErrorInvalidName
                                            userInfo:@{NSLocalizedDescriptionKey: @"文件名过长"}];
        return NO;
    }
    return YES;
}

@end
