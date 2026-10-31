//
//  A2ZipReader.m
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
//  实现见头文件里「两套接口，一个实现」的说明：
//  解压只有一条路径（`inflateEntry:maxBytes:sink:error:`），
//  「整条进内存」和「流式写 fd」只是两个不同的 sink。
//  两套各写一遍 inflate 的后果是上限检查早晚漏在另一条路径上。
//

#import "A2ZipReader.h"
#import <zlib.h>
#import <errno.h>
#import <limits.h>
#import <string.h>
#import <unistd.h>

NSString *const A2ZipReaderErrorDomain = @"A2ZipReaderErrorDomain";

/// zip 中央目录条目签名
static const uint32_t kCentralDirSig = 0x02014b50;
/// 本地文件头签名
static const uint32_t kLocalHeaderSig = 0x04034b50;
/// EOCD 签名
static const uint32_t kEOCDSig = 0x06054b50;

/// 通用标志位：bit 0 加密，bit 11 文件名是 UTF-8
static const uint16_t kFlagEncrypted = 1u << 0;
static const uint16_t kFlagUTF8Name = 1u << 11;

/// 生成该条目的主机系统：3 = Unix，19 = macOS
static const uint16_t kMadeByUnix = 3;
static const uint16_t kMadeByMacOS = 19;

/// 解压搬运用的缓冲大小：64 KB 是「一次系统调用不嫌小、内存不嫌大」的折中
static const NSUInteger kInflateChunkSize = 64 * 1024;

static uint16_t readU16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t readU32(const uint8_t *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24));
}

static NSError *ZipError(A2ZipReaderError code, NSString *reason) {
    return [NSError errorWithDomain:A2ZipReaderErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: reason}];
}

#pragma mark - 条目元数据

@interface A2ZipEntryInfo ()
/// 本地文件头的偏移（只有解析器与解压核心用）。
@property (nonatomic, assign) uint32_t localHeaderOffset;
/// 名字的原始字节：解压时用它核对「本地头是不是同一个名字」。
@property (nonatomic, strong) NSData *rawNameBytes;
@end

@implementation A2ZipEntryInfo
@end

#pragma mark - 读取器

@interface A2ZipReader ()
@property (nonatomic, strong) NSData *data;
/// 名字 → 条目（不含目录条目，与原 `entryNames` 语义一致）
@property (nonatomic, strong) NSMutableDictionary<NSString *, A2ZipEntryInfo *> *entries;
/// 含目录条目、含重名条目的全量清单
@property (nonatomic, strong) NSMutableArray<A2ZipEntryInfo *> *allInfos;
@property (nonatomic, assign) BOOL duplicateNames;
@property (nonatomic, assign) BOOL unsupportedFeatures;
@end

@implementation A2ZipReader

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (!self) return nil;

    // installer jar 可能几十 MB，用映射而不是全读进内存
    NSData *d = [NSData dataWithContentsOfFile:path
                                       options:NSDataReadingMappedIfSafe
                                         error:nil];
    if (!d || d.length < 22) return nil;

    _data = d;
    _entries = [NSMutableDictionary dictionary];
    _allInfos = [NSMutableArray array];

    if (![self parseCentralDirectory]) return nil;
    return self;
}

- (NSArray<NSString *> *)entryNames {
    return self.entries.allKeys;
}

- (NSArray<A2ZipEntryInfo *> *)entryInfos {
    return [self.allInfos copy];
}

- (BOOL)hasDuplicateEntryNames {
    return self.duplicateNames;
}

- (BOOL)hasUnsupportedFeatures {
    return self.unsupportedFeatures;
}

- (BOOL)containsEntry:(NSString *)name {
    return self.entries[name] != nil;
}

- (BOOL)parseCentralDirectory {
    const uint8_t *bytes = _data.bytes;
    NSUInteger len = _data.length;

    // 从尾部往前找 EOCD（可能带注释，最多 64KB）
    NSUInteger scanStart = (len > 65557) ? (len - 65557) : 0;
    NSInteger eocdOffset = -1;
    for (NSInteger i = (NSInteger)len - 22; i >= (NSInteger)scanStart; i--) {
        if (readU32(bytes + i) == kEOCDSig) {
            eocdOffset = i;
            break;
        }
    }
    if (eocdOffset < 0) return NO;

    const uint8_t *eocd = bytes + eocdOffset;
    uint16_t entryCount = readU16(eocd + 10);
    uint32_t cdOffset = readU32(eocd + 16);

    // zip64 的两个标志位：条目数 0xFFFF、中央目录偏移 0xFFFFFFFF。
    // 结构上「读得出」，只是格式不支持 —— 标出来由调用方按自己的契约拒装，
    // 别在这里静默截断成「只有前 65535 条」。
    if (entryCount == 0xFFFF || cdOffset == 0xFFFFFFFF) {
        _unsupportedFeatures = YES;
        return YES;
    }
    if (cdOffset >= len) return NO;

    NSUInteger p = cdOffset;
    for (uint16_t i = 0; i < entryCount && p + 46 <= len; i++) {
        if (readU32(bytes + p) != kCentralDirSig) break;

        uint16_t versionMadeBy = readU16(bytes + p + 4);
        uint16_t flags = readU16(bytes + p + 8);
        uint16_t method = readU16(bytes + p + 10);
        uint32_t compressedSize = readU32(bytes + p + 20);
        uint32_t uncompressedSize = readU32(bytes + p + 24);
        uint16_t nameLen = readU16(bytes + p + 28);
        uint16_t extraLen = readU16(bytes + p + 30);
        uint16_t commentLen = readU16(bytes + p + 32);
        uint32_t externalAttributes = readU32(bytes + p + 38);
        uint32_t localHeaderOffset = readU32(bytes + p + 42);

        if (p + 46 + nameLen > len) break;

        // zip64：任一尺寸字段是 0xFFFFFFFF 表示真值在 extra 字段里
        if (compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF
            || localHeaderOffset == 0xFFFFFFFF) {
            _unsupportedFeatures = YES;
        }
        if (flags & kFlagEncrypted) _unsupportedFeatures = YES;
        if (method != 0 && method != 8) _unsupportedFeatures = YES;

        NSData *rawName = [NSData dataWithBytesNoCopy:(void *)(bytes + p + 46)
                                               length:nameLen
                                         freeWhenDone:NO];
        NSString *name = [self nameFromBytes:rawName utf8Flag:(flags & kFlagUTF8Name) != 0];

        A2ZipEntryInfo *info = [A2ZipEntryInfo new];
        info.name = name ?: @"";
        info.compressionMethod = method;
        info.compressedSize = compressedSize;
        info.uncompressedSize = uncompressedSize;
        info.generalPurposeBitFlag = flags;
        info.versionMadeBy = versionMadeBy;
        info.externalAttributes = externalAttributes;
        info.localHeaderOffset = localHeaderOffset;
        info.rawNameBytes = rawName;
        info.isSymbolicLink = [self isSymbolicLinkIn:info];
        info.isDirectory = [info.name hasSuffix:@"/"] || ((externalAttributes & 0x10) != 0);

        [_allInfos addObject:info];

        if (info.name.length > 0 && !info.isDirectory) {
            // 同名两条时后一条覆盖前一条 —— 与原实现一致，但要把「有重名」记下来：
            // 取哪一条全看实现，正是夹带手法想要的
            if (_entries[info.name] != nil) _duplicateNames = YES;
            _entries[info.name] = info;
        }

        p += 46 + nameLen + extraLen + commentLen;
    }

    return _entries.count > 0 || _allInfos.count > 0;
}

/// 名字解码：置了 UTF-8 标志位就只认 UTF-8；没置位时只认纯 ASCII
/// （ASCII 是合法 UTF-8，字节序不歧义）。其余情况一律记成「文件名非 UTF-8」——
/// 那是契约违规，不是编码猜测题。
- (nullable NSString *)nameFromBytes:(NSData *)rawName utf8Flag:(BOOL)utf8Flag {
    if (rawName.length == 0) return @"";

    if (utf8Flag) {
        NSString *decoded = [[NSString alloc] initWithData:rawName encoding:NSUTF8StringEncoding];
        if (!decoded) {
            _unsupportedFeatures = YES;
            return [[NSString alloc] initWithData:rawName encoding:NSISOLatin1StringEncoding];
        }
        return decoded;
    }

    const uint8_t *bytes = rawName.bytes;
    for (NSUInteger i = 0; i < rawName.length; i++) {
        if (bytes[i] >= 0x80) {
            _unsupportedFeatures = YES;
            return [[NSString alloc] initWithData:rawName encoding:NSISOLatin1StringEncoding];
        }
    }
    return [[NSString alloc] initWithData:rawName encoding:NSUTF8StringEncoding];
}

/// Unix 模式下高 16 位是 st_mode：`S_IFLNK` 是 0xA000。
/// 主机系统在 `versionMadeBy` 的**高字节**（低字节是 zip 版本号），比较前必须先右移 8 位。
- (BOOL)isSymbolicLinkIn:(A2ZipEntryInfo *)info {
    uint16_t hostSystem = (uint16_t)(info.versionMadeBy >> 8);
    if (hostSystem != kMadeByUnix && hostSystem != kMadeByMacOS) return NO;
    uint32_t mode = info.externalAttributes >> 16;
    return (mode & 0xF000) == 0xA000;
}

#pragma mark - 解压核心

/// 唯一的一条解压路径。sink 返回 NO 表示写不出去（磁盘满 / 权限）。
- (BOOL)inflateEntry:(A2ZipEntryInfo *)info
            maxBytes:(unsigned long long)maxBytes
                sink:(BOOL (^)(const uint8_t *bytes, NSUInteger length))sink
               error:(NSError **)error {
    const uint8_t *bytes = _data.bytes;
    NSUInteger len = _data.length;
    NSUInteger p = info.localHeaderOffset;

    if (p + 30 > len || readU32(bytes + p) != kLocalHeaderSig) {
        if (error) *error = ZipError(A2ZipReaderErrorCorrupt, @"本地文件头不成立");
        return NO;
    }

    // 关键：本地头的 name/extra 长度可能与中央目录不同，必须读本地头
    uint16_t nameLen = readU16(bytes + p + 26);
    uint16_t extraLen = readU16(bytes + p + 28);
    NSUInteger headerEnd = p + 30 + nameLen;
    if (headerEnd > len) {
        if (error) *error = ZipError(A2ZipReaderErrorCorrupt, @"本地文件头越界");
        return NO;
    }

    // 「中央目录老实、本地头使坏」：两边名字对不上就是夹带，直接判坏
    NSData *localName = [NSData dataWithBytesNoCopy:(void *)(bytes + p + 30)
                                             length:nameLen
                                       freeWhenDone:NO];
    if (![localName isEqualToData:info.rawNameBytes]) {
        if (error) {
            *error = ZipError(A2ZipReaderErrorCorrupt,
                              [NSString stringWithFormat:@"条目「%@」的本地头名字与中央目录不一致",
                               info.name]);
        }
        return NO;
    }

    NSUInteger dataStart = headerEnd + extraLen;
    if (dataStart + (NSUInteger)info.compressedSize > len) {
        if (error) *error = ZipError(A2ZipReaderErrorCorrupt, @"条目数据越界（包被截断？）");
        return NO;
    }
    if (info.compressionMethod == 0 && info.compressedSize > maxBytes) {
        if (error) *error = ZipError(A2ZipReaderErrorTooLarge, @"条目超过单文件上限");
        return NO;
    }

    unsigned long long written = 0;

    if (info.compressionMethod == 0) {
        if (info.compressedSize > 0 && !sink(bytes + dataStart, (NSUInteger)info.compressedSize)) {
            if (error) *error = ZipError(A2ZipReaderErrorIO, @"写入失败");
            return NO;
        }
        written = info.compressedSize;
    } else if (info.compressedSize > 0) {
        z_stream strm;
        memset(&strm, 0, sizeof(strm));
        // 负数窗口位表示 raw deflate —— zip 的数据没有 zlib 头
        if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) {
            if (error) *error = ZipError(A2ZipReaderErrorCorrupt, @"deflate 初始化失败");
            return NO;
        }
        strm.next_in = (Bytef *)(bytes + dataStart);
        strm.avail_in = (uInt)info.compressedSize;

        uint8_t chunk[kInflateChunkSize];
        int status = Z_OK;
        BOOL failed = NO;
        while (YES) {
            strm.next_out = chunk;
            strm.avail_out = (uInt)sizeof(chunk);
            status = inflate(&strm, Z_NO_FLUSH);
            if (status != Z_OK && status != Z_STREAM_END) {
                if (error) {
                    *error = ZipError(A2ZipReaderErrorCorrupt,
                                      [NSString stringWithFormat:@"条目「%@」的 deflate 流损坏（%d）",
                                       info.name, status]);
                }
                failed = YES;
                break;
            }

            NSUInteger produced = sizeof(chunk) - strm.avail_out;
            if (produced > 0) {
                if (written + produced > maxBytes) {
                    if (error) {
                        *error = ZipError(A2ZipReaderErrorTooLarge,
                                          [NSString stringWithFormat:@"条目「%@」解压后超过上限",
                                           info.name]);
                    }
                    failed = YES;
                    break;
                }
                if (!sink(chunk, produced)) {
                    if (error) *error = ZipError(A2ZipReaderErrorIO, @"写入失败");
                    failed = YES;
                    break;
                }
                written += produced;
            }

            if (status == Z_STREAM_END) break;
            if (strm.avail_in == 0 && produced == 0) {
                // 输入吃完了却还没走到流尾：包被截断
                if (error) *error = ZipError(A2ZipReaderErrorCorrupt, @"deflate 流提前结束");
                failed = YES;
                break;
            }
        }
        inflateEnd(&strm);
        if (failed) return NO;
    }

    // 中央目录声明的解压后大小必须与实际产出一致 —— 谎报大小的包在这里露馅
    if (info.uncompressedSize != 0 && written != info.uncompressedSize) {
        if (error) {
            *error = ZipError(A2ZipReaderErrorCorrupt,
                              [NSString stringWithFormat:@"条目「%@」实际解压 %llu 字节，声明 %llu 字节",
                               info.name, written, info.uncompressedSize]);
        }
        return NO;
    }

    return YES;
}

#pragma mark - 整条进内存（mod 加载器用）

- (NSData *)dataForEntry:(NSString *)name {
    A2ZipEntryInfo *info = _entries[name];
    if (!info) return nil;

    NSMutableData *output = [NSMutableData dataWithCapacity:(NSUInteger)info.uncompressedSize];
    BOOL ok = [self inflateEntry:info
                        maxBytes:info.uncompressedSize ? info.uncompressedSize : ULLONG_MAX
                            sink:^BOOL(const uint8_t *chunk, NSUInteger length) {
        [output appendBytes:chunk length:length];
        return YES;
    }
                           error:NULL];
    return ok ? [output copy] : nil;
}

#pragma mark - 流式写 fd（安装器用）

- (BOOL)writeEntryInfo:(A2ZipEntryInfo *)info
      toFileDescriptor:(int)fd
              maxBytes:(unsigned long long)maxBytes
          writtenBytes:(unsigned long long *)writtenBytes
                 error:(NSError **)error {
    if (![info isKindOfClass:A2ZipEntryInfo.class]) {
        if (error) *error = ZipError(A2ZipReaderErrorCorrupt, @"需要 A2ZipEntryInfo");
        return NO;
    }

    __block unsigned long long total = 0;
    BOOL ok = [self inflateEntry:info
                        maxBytes:maxBytes
                            sink:^BOOL(const uint8_t *chunk, NSUInteger length) {
        NSUInteger offset = 0;
        while (offset < length) {
            ssize_t n = write(fd, chunk + offset, length - offset);
            if (n <= 0) {
                if (errno == EINTR) continue;
                return NO;
            }
            offset += (NSUInteger)n;
        }
        total += length;
        return YES;
    }
                           error:error];

    if (ok && writtenBytes) *writtenBytes = total;
    return ok;
}

#pragma mark - 解压到磁盘

- (BOOL)extractEntry:(NSString *)name toPath:(NSString *)destPath {
    NSData *d = [self dataForEntry:name];
    if (!d) return NO;

    [[NSFileManager defaultManager] createDirectoryAtPath:destPath.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [d writeToFile:destPath atomically:YES];
}

- (NSString *)extractEntry:(NSString *)name toDirectory:(NSString *)dir {
    if (![self containsEntry:name]) return nil;

    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *dest = [dir stringByAppendingPathComponent:name];
    if ([self extractEntry:name toPath:dest]) return dest;
    return nil;
}

@end
