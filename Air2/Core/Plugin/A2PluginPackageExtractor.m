//
//  A2PluginPackageExtractor.m
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
//  流程见头文件：预检（不看内容只看中央目录）→ 解压（复核落盘路径）→
//  manifest 校验 → 完整性 → 内容摘要。
//

#import "A2PluginPackageExtractor.h"

#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <unistd.h>

#import "A2ZipReader.h"

/// 必须全部出现在 `manifest.files` 里的目录（PLUGIN-SYSTEM 3.2 第 4 条）。
/// 包根的其他文件（README / LICENSE）不在此列：它们不影响加载，也不被任何代码路径执行。
static NSArray<NSString *> *A2DeclaredDirectoryPrefixes(void) {
    static NSArray<NSString *> *prefixes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[@"ui/", @"pages/", @"assets/", @"locales/", @"schematics/"];
    });
    return prefixes;
}

static NSString *const kRootManifestName = @"manifest.json";

#pragma mark - 结果

@interface A2PluginPackage ()
@property (nonatomic, copy) NSString *rootDirectory;
@property (nonatomic, strong) A2PluginManifest *manifest;
@property (nonatomic, copy) NSString *contentHash;
@end

@implementation A2PluginPackage
@end

#pragma mark - 摘要

static NSString *A2SHA256HexOfData(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

/// 单文件 SHA-256（64 位小写 hex）。文件已在单文件上限之内，直接映射读。
static NSString *A2SHA256HexOfFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:NULL];
    if (!data) return nil;
    return A2SHA256HexOfData(data);
}

#pragma mark - 解包器

@interface A2PluginPackageExtractor ()
@property (nonatomic, assign) A2PluginLimits limits;
@end

@implementation A2PluginPackageExtractor

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：没有上限的解包器是非法状态。
    // 声明/实现一致性检查要求每个声明都有实现；正常代码走不到这里。
    return nil;
}

- (instancetype)initWithLimits:(A2PluginLimits)limits {
    self = [super init];
    if (self) {
        _limits = limits;
    }
    return self;
}

- (nullable A2PluginPackage *)extractPackageAtURL:(NSURL *)url
                                    intoDirectory:(NSString *)destination
                                            error:(NSError **)error {
    if (!url.isFileURL || url.path.length == 0) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil,
                                       @"只接受本地文件包（网络来源请先用下载层落地成文件）");
        }
        return nil;
    }
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *packagePath = url.path;

    // ① 包体大小：先看文件系统上的字节数，不必打开 zip
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [fileManager attributesOfItemAtPath:packagePath error:NULL];
    if (!attributes) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"包文件读不出来：%@", packagePath);
        }
        return nil;
    }
    unsigned long long packageBytes = attributes.fileSize;
    if (packageBytes > self.limits.maxPackageBytes) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorSize, nil,
                                       @"包体 %llu 字节超过上限 %llu 字节",
                                       packageBytes, self.limits.maxPackageBytes);
        }
        return nil;
    }

    // ② 打开 zip：读不出中央目录就是「不是普通 zip」
    A2ZipReader *reader = [[A2ZipReader alloc] initWithPath:packagePath];
    if (!reader) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorFormat, nil,
                                       @"包读不出 zip 中央目录，请用普通 zip 重新打包");
        }
        return nil;
    }
    if (reader.hasUnsupportedFeatures) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorFormat, nil,
                                       @"包用了不支持的 zip 特性（zip64 / 加密 / 非 UTF-8 文件名 / "
                                       @"未知压缩算法），请用普通 zip 重新打包");
        }
        return nil;
    }
    if (reader.hasDuplicateEntryNames) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorFormat, nil,
                                       @"包里有重名条目：同一条路径出现两次，取哪一条全看解压实现");
        }
        return nil;
    }

    // ③ 中央目录预检：这一步之前一个字节都没落盘
    NSError *precheckError = nil;
    if (![self precheckEntryInfos:reader.entryInfos error:&precheckError]) {
        if (error) *error = precheckError;
        return nil;
    }

    // ④ 解压（复核落盘路径是否仍在 destination 之内）
    NSError *extractError = nil;
    if (![self extractEntryInfos:reader.entryInfos
                          reader:reader
                   intoDirectory:destination
                           error:&extractError]) {
        if (error) *error = extractError;
        return nil;
    }

    // ⑤ manifest 校验
    NSString *manifestPath = [destination stringByAppendingPathComponent:kRootManifestName];
    NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath];
    if (!manifestData) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorFormat, nil, @"包根缺少 manifest.json");
        }
        return nil;
    }
    NSError *manifestError = nil;
    A2PluginManifest *manifest = [A2PluginManifest manifestWithData:manifestData
                                                             limits:self.limits
                                                              error:&manifestError];
    if (!manifest) {
        if (error) *error = manifestError;
        return nil;
    }

    // ⑥ 完整性 + ⑦ 内容摘要
    NSArray<NSString *> *relativePaths = [self regularFilePathsInDirectory:destination
                                                                fileManager:fileManager];
    if (!relativePaths) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"解压目录列举失败：%@", destination);
        }
        return nil;
    }

    NSError *integrityError = nil;
    if (![self verifyIntegrityOfManifest:manifest
                                   root:destination
                          relativePaths:relativePaths
                            fileManager:fileManager
                                  error:&integrityError]) {
        if (error) *error = integrityError;
        return nil;
    }

    NSError *hashError = nil;
    NSString *contentHash = [self contentHashForRoot:destination
                                       relativePaths:relativePaths
                                              error:&hashError];
    if (!contentHash) {
        if (error) *error = hashError;
        return nil;
    }

    A2PluginPackage *package = [A2PluginPackage new];
    package.rootDirectory = destination;
    package.manifest = manifest;
    package.contentHash = contentHash;
    return package;
}

#pragma mark - ① 中央目录预检

- (BOOL)precheckEntryInfos:(NSArray<A2ZipEntryInfo *> *)infos error:(NSError **)error {
    NSUInteger fileCount = 0;
    unsigned long long declaredTotal = 0;
    BOOL hasRootManifest = NO;

    for (A2ZipEntryInfo *info in infos) {
        NSString *name = info.name;
        if (name.length == 0) {
            if (error) *error = A2PluginErrorMake(A2PluginErrorFormat, nil, @"包里有空名字的条目");
            return NO;
        }

        // 目录条目带尾随 '/'，路径规则按去掉它之后的名字判
        NSString *relative = info.isDirectory ? [name substringToIndex:name.length - 1] : name;

        // 符号链接：解压出来的不是文件，而是一个指向包外的路径。
        // （zip 没有独立的硬链接标记，硬链接只能是普通条目；能藏链接的只有这个模式位。）
        if (info.isSymbolicLink) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorLink, relative,
                                           @"包里有符号链接条目「%@」；重新打包，不要手工塞条目",
                                           relative);
            }
            return NO;
        }

        switch (A2PluginInspectPackagePath(relative, self.limits.maxPathLength)) {
            case A2PluginPathVerdictOK:
                break;
            case A2PluginPathVerdictEscaping:
                if (error) {
                    *error = A2PluginErrorMake(A2PluginErrorZipSlip, relative,
                                               @"条目「%@」会落到包目录之外（.. / 绝对路径 / 反斜杠）",
                                               name);
                }
                return NO;
            case A2PluginPathVerdictTooLong:
                if (error) {
                    *error = A2PluginErrorMake(A2PluginErrorSize, relative,
                                               @"条目路径「%@」超过 %lu 字节",
                                               name, (unsigned long)self.limits.maxPathLength);
                }
                return NO;
            case A2PluginPathVerdictIllegalCharacters:
                if (error) {
                    *error = A2PluginErrorMake(A2PluginErrorPath, relative,
                                               @"条目路径「%@」含非法字符（只允许字母数字 . _ - /，"
                                               @"且不能以 . 开头）", name);
                }
                return NO;
        }

        if ((NSUInteger)[relative componentsSeparatedByString:@"/"].count
            > self.limits.maxPathDepth) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorSize, relative,
                                           @"条目「%@」超过 %lu 层路径深度",
                                           name, (unsigned long)self.limits.maxPathDepth);
            }
            return NO;
        }

        // manifest.json 只能在包根：子目录里再来一份就是夹带
        if ([relative isEqualToString:kRootManifestName]) {
            if (info.isDirectory) {
                if (error) {
                    *error = A2PluginErrorMake(A2PluginErrorFormat, nil,
                                               @"包根把 manifest.json 打成了目录");
                }
                return NO;
            }
            hasRootManifest = YES;
            continue;
        }
        if ([relative hasSuffix:[@"/" stringByAppendingString:kRootManifestName]]) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorFormat, relative,
                                           @"包里有第二份 manifest.json（「%@」）：manifest 必须在包根",
                                           relative);
            }
            return NO;
        }

        if (info.isDirectory) continue;

        fileCount++;
        if (fileCount > self.limits.maxFileCount) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorSize, nil,
                                           @"包内文件数超过上限 %lu",
                                           (unsigned long)self.limits.maxFileCount);
            }
            return NO;
        }
        if (info.uncompressedSize > self.limits.maxSingleFileBytes) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorSize, relative,
                                           @"条目「%@」解压后 %llu 字节，超过单文件上限 %llu 字节",
                                           name, info.uncompressedSize,
                                           self.limits.maxSingleFileBytes);
            }
            return NO;
        }
        // 压缩比：正常资源不会超过 100:1，超了就是炸弹的形态
        if (info.compressionMethod == 8 && info.compressedSize > 0
            && info.uncompressedSize > info.compressedSize * self.limits.maxCompressionRatio) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorSize, relative,
                                           @"条目「%@」压缩比超过 %lu:1（典型的压缩炸弹形态）",
                                           name, (unsigned long)self.limits.maxCompressionRatio);
            }
            return NO;
        }

        declaredTotal += info.uncompressedSize;
        if (declaredTotal > self.limits.maxExtractedBytes) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorSize, nil,
                                           @"解压后总量超过上限 %llu 字节",
                                           self.limits.maxExtractedBytes);
            }
            return NO;
        }
    }

    if (!hasRootManifest) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorFormat, nil, @"包根缺少 manifest.json");
        }
        return NO;
    }
    return YES;
}

#pragma mark - ② 解压

- (BOOL)extractEntryInfos:(NSArray<A2ZipEntryInfo *> *)infos
                   reader:(A2ZipReader *)reader
            intoDirectory:(NSString *)destination
                    error:(NSError **)error {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager createDirectoryAtPath:destination
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:NULL]) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorIO, nil, @"建不出解压目录：%@", destination);
        }
        return NO;
    }

    NSString *rootStandard = destination.stringByStandardizingPath;
    NSString *rootPrefix = [rootStandard stringByAppendingString:@"/"];

    for (A2ZipEntryInfo *info in infos) {
        if (info.isDirectory) continue;

        NSString *target = [destination stringByAppendingPathComponent:info.name];

        // 第二道门：预检之后再用「标准化后的落盘路径」复核一次。
        // 中央目录可以通过预检、而实际拼接出来的路径跑出去（不同平台的字符串语义差异），
        // 复核一次的成本是一个字符串比较。
        if (![target.stringByStandardizingPath hasPrefix:rootPrefix]) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorZipSlip, info.name,
                                           @"条目「%@」解压落点跑出了包目录", info.name);
            }
            return NO;
        }

        NSString *parent = target.stringByDeletingLastPathComponent;
        if (![fileManager createDirectoryAtPath:parent
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:NULL]) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorIO, info.name,
                                           @"建不出目录：%@", parent);
            }
            return NO;
        }

        int fd = open(target.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (fd < 0) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorIO, info.name,
                                           @"写不出文件「%@」：%s", info.name, strerror(errno));
            }
            return NO;
        }

        NSError *writeError = nil;
        unsigned long long written = 0;
        BOOL ok = [reader writeEntryInfo:info
                        toFileDescriptor:fd
                                maxBytes:self.limits.maxSingleFileBytes
                            writtenBytes:&written
                                   error:&writeError];
        close(fd);

        if (!ok) {
            [fileManager removeItemAtPath:target error:NULL];
            if (error) {
                A2PluginError code = A2PluginErrorFormat;
                if ([writeError.domain isEqualToString:A2ZipReaderErrorDomain]
                    && writeError.code == A2ZipReaderErrorTooLarge) {
                    code = A2PluginErrorSize;
                } else if ([writeError.domain isEqualToString:A2ZipReaderErrorDomain]
                           && writeError.code == A2ZipReaderErrorIO) {
                    code = A2PluginErrorIO;
                }
                *error = A2PluginErrorMake(code, info.name, @"解压「%@」失败：%@",
                                           info.name,
                                           writeError.localizedDescription ?: @"未知原因");
            }
            return NO;
        }

        // 声明 0 字节却解出了内容：中央目录撒谎，按坏包处理
        if (info.uncompressedSize == 0 && written != 0) {
            [fileManager removeItemAtPath:target error:NULL];
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorFormat, info.name,
                                           @"条目「%@」声明 0 字节却解出 %llu 字节",
                                           info.name, written);
            }
            return NO;
        }
    }
    return YES;
}

#pragma mark - ③ 完整性

- (nullable NSArray<NSString *> *)regularFilePathsInDirectory:(NSString *)directory
                                                  fileManager:(NSFileManager *)fileManager {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSDirectoryEnumerator<NSString *> *enumerator = [fileManager enumeratorAtPath:directory];
    for (NSString *relative in enumerator) {
        NSDictionary<NSFileAttributeKey, id> *attributes =
            [enumerator fileAttributes];
        if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) {
            [enumerator skipDescendants];
            continue;
        }
        [paths addObject:relative];
    }
    return paths;
}

- (BOOL)verifyIntegrityOfManifest:(A2PluginManifest *)manifest
                             root:(NSString *)root
                    relativePaths:(NSArray<NSString *> *)relativePaths
                      fileManager:(NSFileManager *)fileManager
                            error:(NSError **)error {
    NSSet<NSString *> *actual = [NSSet setWithArray:relativePaths];
    NSMutableSet<NSString *> *declared = [NSMutableSet setWithCapacity:manifest.files.count];

    for (A2PluginFileEntry *entry in manifest.files) {
        [declared addObject:entry.path];
        if (![actual containsObject:entry.path]) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorFileSetMismatch, entry.path,
                                           @"manifest.files 声明了包里不存在的文件「%@」",
                                           entry.path);
            }
            return NO;
        }

        NSString *filePath = [root stringByAppendingPathComponent:entry.path];
        NSDictionary<NSFileAttributeKey, id> *attributes =
            [fileManager attributesOfItemAtPath:filePath error:NULL];
        if (!attributes) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorIO, entry.path,
                                           @"读不到文件属性「%@」", entry.path);
            }
            return NO;
        }
        unsigned long long size = attributes.fileSize;
        if (size != entry.size) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorHashMismatch, entry.path,
                                           @"「%@」实际 %llu 字节，清单写 %llu 字节",
                                           entry.path, size, entry.size);
            }
            return NO;
        }
        NSString *digest = A2SHA256HexOfFile(filePath);
        if (!digest || ![digest isEqualToString:entry.sha256.lowercaseString]) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorHashMismatch, entry.path,
                                           @"「%@」的 SHA-256 与清单不符（打包后又改过文件？）",
                                           entry.path);
            }
            return NO;
        }
    }

    // 反向：五个目录下的每个文件都必须在清单里，多一个就是没被校验过的内容
    for (NSString *path in relativePaths) {
        if ([path isEqualToString:kRootManifestName]) continue;
        if ([declared containsObject:path]) continue;
        for (NSString *prefix in A2DeclaredDirectoryPrefixes()) {
            if ([path hasPrefix:prefix]) {
                if (error) {
                    *error = A2PluginErrorMake(A2PluginErrorFileSetMismatch, path,
                                               @"「%@」在 %@ 下却没写进 manifest.files："
                                               @"这份文件不会被任何校验覆盖", path, prefix);
                }
                return NO;
            }
        }
    }

    // 入口脚本必须真实存在（type: js 的 manifest 已在解析阶段保证 entry 非空）
    if (manifest.entry.length && ![actual containsObject:manifest.entry]) {
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorFileSetMismatch, @"entry",
                                       @"入口脚本「%@」不在包里", manifest.entry);
        }
        return NO;
    }

    return YES;
}

#pragma mark - ④ 内容摘要

- (nullable NSString *)contentHashForRoot:(NSString *)root
                            relativePaths:(NSArray<NSString *> *)relativePaths
                                    error:(NSError **)error {
    // 按路径的 UTF-8 字节序排序：locale 敏感的排序在不同设备上可能给出不同顺序，
    // 那会让同一份内容算出两个哈希
    NSArray<NSString *> *sorted =
        [relativePaths sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        int result = strcmp(a.UTF8String, b.UTF8String);
        if (result < 0) return NSOrderedAscending;
        if (result > 0) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableData *feed = [NSMutableData data];
    for (NSString *path in sorted) {
        NSString *filePath = [root stringByAppendingPathComponent:path];
        NSDictionary<NSFileAttributeKey, id> *attributes =
            [fileManager attributesOfItemAtPath:filePath error:NULL];
        if (!attributes) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorIO, path, @"读不到文件属性「%@」", path);
            }
            return nil;
        }
        NSString *digest = A2SHA256HexOfFile(filePath);
        if (!digest) {
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorIO, path, @"算不出「%@」的 SHA-256", path);
            }
            return nil;
        }

        [feed appendData:[path dataUsingEncoding:NSUTF8StringEncoding]];
        [feed appendBytes:"\0" length:1];
        NSString *size = [NSString stringWithFormat:@"%llu", attributes.fileSize];
        [feed appendData:[size dataUsingEncoding:NSUTF8StringEncoding]];
        [feed appendBytes:"\0" length:1];
        [feed appendData:[digest dataUsingEncoding:NSUTF8StringEncoding]];
        [feed appendBytes:"\n" length:1];
    }
    return A2SHA256HexOfData(feed);
}

@end
