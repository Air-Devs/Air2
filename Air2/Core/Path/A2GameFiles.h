//
//  A2GameFiles.h
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
//  作用域文件操作 —— 版本游戏目录浏览的唯一出口。
//
//  安全决策（参考 ZL2 AccessScope，不照抄实现）：
//    · root 必须是已存在的目录，否则初始化失败（不静默建目录，
//      调用方传的版本目录缺失本身就是异常信号）。
//    · 所有相对路径先拼到 root 再标准化，越界（.. 逃出）直接失败，
//      不做截断式“修正”（截断会让调用方误以为写到了别处）。
//    · 文件名校验拒绝 /、首尾空格、空名、超长与 . / ..（ZL2 同款三类）。
//  只用 Foundation，Core 不依赖 UIKit。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const A2GameFilesErrorDomain;

typedef NS_ENUM(NSInteger, A2GameFilesError) {
    A2GameFilesErrorOutOfScope = 1, ///< 越界（.. 逃出 root）
    A2GameFilesErrorInvalidName,     ///< 非法文件名
    A2GameFilesErrorIO,             ///< 读写失败（userInfo 带底层 error）
};

/// 目录项（只读快照，不持有文件句柄）。
@interface A2GameFileEntry : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, assign, readonly) BOOL isDirectory;
/// 文件字节数；目录为 -1（不递归统计，避免大目录卡死）。
@property (nonatomic, assign, readonly) long long fileSize;
@property (nonatomic, strong, readonly, nullable) NSDate *modificationDate;
- (instancetype)initWithName:(NSString *)name
                 isDirectory:(BOOL)isDirectory
                    fileSize:(long long)fileSize
            modificationDate:(nullable NSDate *)date NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// 以 root 为作用域的文件操作器（实例不可跨 root 复用）。
@interface A2GameFiles : NSObject

/// 作用域根（标准化后的绝对路径）。
@property (nonatomic, copy, readonly) NSString *rootPath;

- (nullable instancetype)initWithRootPath:(NSString *)rootPath
                                    error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// 列目录：relativePath 为 @"" 或子目录相对路径；目录优先、名称升序。
- (nullable NSArray<A2GameFileEntry *> *)entriesInDirectory:(NSString *)relativePath
                                                     error:(NSError **)error;
- (BOOL)createDirectory:(NSString *)name
            inDirectory:(NSString *)relativePath
                  error:(NSError **)error;
- (BOOL)renameEntryAt:(NSString *)relativePath
               toName:(NSString *)newName
                error:(NSError **)error;
- (BOOL)deleteEntryAt:(NSString *)relativePath
                error:(NSError **)error;

/// 文件名校验（创建/重命名共用）。合法返回 YES，否则 NO 并填原因。
+ (BOOL)validateFileName:(NSString *)name error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
