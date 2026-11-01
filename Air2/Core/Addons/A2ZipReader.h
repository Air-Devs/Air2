//
//  A2ZipReader.h
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
//  最小可用的 zip 读取器。
//
//  iOS 上没有公开的 zip 解压 API，而安装 Forge 需要从
//  installer jar 里读 version.json。自己实现只读版本，
//  代价比引入第三方库小。
//
//  支持：stored（不压缩）与 deflate（用 zlib 解压）
//  不支持：加密、zip64、多卷
//
//  ## 两套接口，一个实现
//
//  · `dataForEntry:` 那组是给 mod 加载器用的：整条读进内存，够用就好。
//  · `entryInfos` + `writeEntryInfo:toFileDescriptor:` 是给插件安装器用的：
//    **解压之前**就能拿到每条的声明大小、压缩比、外部属性（符号链接位），
//    解压时边解边写、按实际产出字节数刹车。
//
//  为什么安装器需要第二套：只有「先看中央目录再落盘」才能在写出任何字节之前
//  拒掉 zip 炸弹与穿越条目；只有「按实际产出计数」才能防住中央目录里
//  谎报 uncompressedSize 的包。两者缺一，炸弹进得来。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// zip 层错误的错误域。这一层不知道「插件」是什么，只报字节层的事实；
/// 由调用方翻成自己的错误码（安装器翻成 `E_PATH_ESCAPE` / `E_LINK` / `E_SIZE` 等）。
extern NSString *const A2ZipReaderErrorDomain;

typedef NS_ENUM(NSInteger, A2ZipReaderError) {
    /// 结构坏：找不到 EOCD、中央目录签名不对、本地文件头与中央目录声明的名字不一致。
    A2ZipReaderErrorCorrupt = 1,
    /// 用了本读取器不支持的格式：zip64 / 加密 / 算法不是 stored 或 deflate。
    A2ZipReaderErrorUnsupported,
    /// 解压产物超过调用方给的上限（按**实际产出**计，不信中央目录的声明）。
    A2ZipReaderErrorTooLarge,
    /// 写入失败（磁盘满 / 权限）。
    A2ZipReaderErrorIO,
};

/// 中央目录里的一条元数据。解压前的一切判断都只能靠它。
@interface A2ZipEntryInfo : NSObject

/// 条目名（包内相对路径；目录条目带尾随 `/`）。
@property (nonatomic, copy, readonly) NSString *name;

/// 压缩算法：0 = stored，8 = deflate。其余值由 `hasUnsupportedFeatures` 标出。
@property (nonatomic, assign, readonly) uint16_t compressionMethod;

/// 压缩后字节数（中央目录声明值）。
@property (nonatomic, assign, readonly) unsigned long long compressedSize;

/// 解压后字节数（中央目录声明值 —— 可能撒谎，写入时按实际产出复核）。
@property (nonatomic, assign, readonly) unsigned long long uncompressedSize;

/// 通用标志位。bit 0 = 加密，bit 11 = 文件名为 UTF-8。
@property (nonatomic, assign, readonly) uint16_t generalPurposeBitFlag;

/// 生成该条目的主机系统：高字节 3 = Unix，19 = macOS；低字节是该主机的 zip 版本。
@property (nonatomic, assign, readonly) uint16_t versionMadeBy;

/// 外部属性：Unix 模式下高 16 位是 st_mode。
@property (nonatomic, assign, readonly) uint32_t externalAttributes;

/// 目录条目（名字以 `/` 结尾，或外部属性标了目录位）。
@property (nonatomic, assign, readonly) BOOL isDirectory;

/// 符号链接条目（Unix 模式位 `S_IFLNK`）。zip 用这种方式夹带链接：
/// 解压出来的不是文件，而是一个指向包外的路径。
@property (nonatomic, assign, readonly) BOOL isSymbolicLink;

@end

@interface A2ZipReader : NSObject

/// 打开 zip 文件。失败返回 nil。
- (nullable instancetype)initWithPath:(NSString *)path;

/// 所有条目名（不含目录条目）
@property (nonatomic, copy, readonly) NSArray<NSString *> *entryNames;

/// 条目是否存在
- (BOOL)containsEntry:(NSString *)name;

/// 取出指定条目的内容（自动解压）
- (nullable NSData *)dataForEntry:(NSString *)name;

/// 取出内容并写入指定路径
- (BOOL)extractEntry:(NSString *)name toPath:(NSString *)destPath;

/// 取出内容到目录（文件名用条目名）
- (nullable NSString *)extractEntry:(NSString *)name toDirectory:(NSString *)dir;

#pragma mark - 解压前预检 / 流式解压

/// 中央目录里的**全部**条目（含目录条目、含重名条目），按中央目录出现顺序。
@property (nonatomic, copy, readonly) NSArray<A2ZipEntryInfo *> *entryInfos;

/// 存在重名条目。同名两条时解析器取哪一条全看实现 —— 那是夹带手法的入口。
@property (nonatomic, assign, readonly) BOOL hasDuplicateEntryNames;

/// 含 zip64 / 加密条目 / 未知压缩算法 / 非 UTF-8 文件名。
/// 这些是**格式**问题，不是安全判断：调用方按自己的契约拒装。
@property (nonatomic, assign, readonly) BOOL hasUnsupportedFeatures;

/// 把一条解压后写进 fd：边解边写，不把整条读进内存；超过 maxBytes 立刻失败。
/// 写完还会核对「实际产出」与中央目录声明的 `uncompressedSize` 是否一致，
/// 不一致按 `A2ZipReaderErrorCorrupt` 报错（谎报大小的包就是靠这里挡住的）。
/// @param writtenBytes 可选出参：实际写入的字节数
- (BOOL)writeEntryInfo:(A2ZipEntryInfo *)info
      toFileDescriptor:(int)fd
              maxBytes:(unsigned long long)maxBytes
          writtenBytes:(nullable unsigned long long *)writtenBytes
                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
