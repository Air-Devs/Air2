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
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#import "A2Log.h"
#import "A2ZipReader.h"

static NSString *const kRootManifestName = @"manifest.json";

/// 分块算哈希时的块大小（64 KB）：与解压缓冲同量级，且远小于单文件上限 32 MB。
static const size_t kHashChunkBytes = 64 * 1024;

/// ★仅测试用★ 解压 / 校验节流：环境变量 `A2_PLUGIN_TEST_SLOW_MS`（毫秒，默认不设 = 0）。
///
/// 用途只有一个：真机验收「原子性」时，24 MB 的包解压太快，杀进程总落在写完以后，
/// 观察不到「中途被打断」这一态。设上这个变量后，解压每个文件**前后各一次**、
/// 逐文件校验每文件一次 sleep 指定毫秒，验收方能在解压中途把进程杀掉，
/// 再看暂存目录与 registry 是否干净。
///
/// 生产路径不设这个变量 ⇒ 读到 0 ⇒ 两个入口都只做一次 `if (ms == 0) return;`。
/// 不做成 API / 配置项，就是为了不让它有机会出现在正式安装流程里。
static unsigned int A2PluginTestSlowMilliseconds(void) {
    static unsigned int milliseconds = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *raw = getenv("A2_PLUGIN_TEST_SLOW_MS");
        if (raw == NULL || *raw == '\0') return;
        long parsed = strtol(raw, NULL, 10);
        // 上限 60 s/文件：再大就不是「慢一点」，是验收脚本自己写错了
        if (parsed > 0 && parsed <= 60000) milliseconds = (unsigned int)parsed;
    });
    return milliseconds;
}

/// 每处理一个文件调一次；默认不设环境变量时立即返回。
static void A2PluginTestSlowTick(void) {
    unsigned int milliseconds = A2PluginTestSlowMilliseconds();
    if (milliseconds == 0) return;
    usleep((useconds_t)milliseconds * 1000);
}

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

/// 单文件 SHA-256（64 位小写 hex）。
///
/// ★分块算，不把文件一次读进内存★：单文件上限 32 MB（`maxSingleFileBytes`），
/// 峰值会和解压缓冲叠加；在低内存设备上「装一个插件」不该变成一次 jetsam。
/// 读失败返回 nil —— 绝不返回一个「看起来对」的哈希（那样坏包会被当成好包）。
static NSString *A2SHA256HexOfFile(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return nil;

    unsigned char *buffer = malloc(kHashChunkBytes);
    if (buffer == NULL) {
        close(fd);
        return nil;
    }

    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);

    BOOL ok = YES;
    ssize_t got = 0;
    while ((got = read(fd, buffer, kHashChunkBytes)) > 0) {
        CC_SHA256_Update(&context, buffer, (CC_LONG)got);
    }
    if (got < 0) ok = NO;      // EINTR 也按失败算：这次校验宁可重来，也不猜内容

    free(buffer);
    close(fd);
    if (!ok) return nil;

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
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
            // 中央目录里有、解压后根目录里没有：预检已拦过一次，这里是第二道门。
            *error = A2PluginErrorMake(A2PluginErrorManifestMissing, nil,
                                       @"包根缺少 manifest.json");
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
            // 机器码与文档码一致：E_MANIFEST_MISSING（PLUGIN-AUTHORING 第十二节）
            *error = A2PluginErrorMake(A2PluginErrorManifestMissing, nil,
                                       @"包根缺少 manifest.json");
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

        // ★仅测试用★ 写这个条目之前先停一下：一个 24 MB 的包里可能只有一两个文件，
        // 只在写完后停会让「杀进程」落在整包已经落盘之后。这里 + 循环末尾各一次，
        // 任何规模的多文件包都能在「暂存目录里有东西、但还没换目录」的中间态被杀到。
        A2PluginTestSlowTick();

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

        // ★仅测试用★ 原子性验收：设了 A2_PLUGIN_TEST_SLOW_MS 才有停顿
        A2PluginTestSlowTick();
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
        NSString *type = attributes[NSFileType];
        if (![type isEqualToString:NSFileTypeRegular]) {
            // 真正的目录要照常进去（插件包按 <dir>/<file> 组织）；
            // 只有目录以外的东西（符号链接等）才剪枝，不跟进去。
            if (![type isEqualToString:NSFileTypeDirectory]) [enumerator skipDescendants];
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
    // 盘上的实际文件集合。**不含 manifest.json 自身**（它不是自己的清单项），
    // 也不含目录 —— regularFilePathsInDirectory 只收 NSFileTypeRegular。
    NSMutableSet<NSString *> *actual = [NSMutableSet setWithCapacity:relativePaths.count];
    for (NSString *path in relativePaths) {
        if ([path isEqualToString:kRootManifestName]) continue;
        [actual addObject:path];
    }
    NSMutableSet<NSString *> *declared = [NSMutableSet setWithCapacity:manifest.files.count];

    // ① 清单 → 盘：声明了却没落地的，是清单说谎（≠「包里多文件」）
    for (A2PluginFileEntry *entry in manifest.files) {
        [declared addObject:entry.path];
        if (![actual containsObject:entry.path]) {
            [A2Log log:@"[A2-PLUGIN] 完整性校验失败：manifest.files 声明了「%@」，"
                       @"但包内没有这个文件（清单 %lu 项，盘上 %lu 项）",
                      entry.path, (unsigned long)manifest.files.count,
                      (unsigned long)actual.count];
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorFileSetMismatch, entry.path,
                                           @"manifest.files 声明了包里不存在的文件「%@」"
                                           @"（清单 %lu 项，包内实际 %lu 项）",
                                           entry.path, (unsigned long)manifest.files.count,
                                           (unsigned long)actual.count);
            }
            return NO;
        }

        NSString *filePath = [root stringByAppendingPathComponent:entry.path];
        NSDictionary<NSFileAttributeKey, id> *attributes =
            [fileManager attributesOfItemAtPath:filePath error:NULL];
        if (!attributes) {
            [A2Log log:@"[A2-PLUGIN] 完整性校验失败：读不到「%@」的文件属性", entry.path];
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorIO, entry.path,
                                           @"读不到文件属性「%@」", entry.path);
            }
            return NO;
        }
        unsigned long long size = attributes.fileSize;
        if (size != entry.size) {
            [A2Log log:@"[A2-PLUGIN] 完整性校验失败：「%@」字节数不符（清单 %llu，实际 %llu）",
                  entry.path, entry.size, size];
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorHashMismatch, entry.path,
                                           @"「%@」字节数与清单不符：清单写 %llu 字节，实际 %llu 字节",
                                           entry.path, entry.size, size);
            }
            return NO;
        }
        NSString *digest = A2SHA256HexOfFile(filePath);
        if (!digest || ![digest isEqualToString:entry.sha256.lowercaseString]) {
            [A2Log log:@"[A2-PLUGIN] 完整性校验失败：「%@」的 SHA-256 不符"
                       @"（清单 %@，实际 %@）",
                  entry.path, entry.sha256.lowercaseString, digest ?: @"(读不出来)"];
            if (error) {
                *error = A2PluginErrorMake(A2PluginErrorHashMismatch, entry.path,
                                           @"「%@」的 SHA-256 与清单不符：清单写 %@，实际 %@"
                                           @"（打包后又改过文件？）",
                                           entry.path, entry.sha256.lowercaseString,
                                           digest ?: @"(读不出来)");
            }
            return NO;
        }

        // ★仅测试用★ 原子性验收：设了 A2_PLUGIN_TEST_SLOW_MS 才有停顿
        A2PluginTestSlowTick();
    }

    // ② 盘 → 清单：多出来的文件没有任何清单项覆盖它，就是夹带。
    // 包根同样算在内（README / LICENSE 也一样）—— 双向严格相等是 schema 与
    // PLUGIN-AUTHORING 第二节第 2 条对作者承诺的规则；不想被校验就别打进包。
    // 按 UTF-8 字节序排序：NSSet 的顺序随机，报哪一个「多余文件」必须可复现。
    NSArray<NSString *> *actualSorted =
        [[actual allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        int result = strcmp(a.UTF8String, b.UTF8String);
        if (result < 0) return NSOrderedAscending;
        if (result > 0) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    for (NSString *path in actualSorted) {
        if ([declared containsObject:path]) continue;
        [A2Log log:@"[A2-PLUGIN] 完整性校验失败：包里有「%@」，manifest.files 里没有它"
                   @"（清单 %lu 项，盘上 %lu 项）",
              path, (unsigned long)manifest.files.count, (unsigned long)actualSorted.count];
        if (error) {
            *error = A2PluginErrorMake(A2PluginErrorFileSetMismatch, path,
                                       @"包里有「%@」却没写进 manifest.files：这份文件不会被"
                                       @"任何校验覆盖（清单 %lu 项，包内实际 %lu 项）",
                                       path, (unsigned long)manifest.files.count,
                                       (unsigned long)actualSorted.count);
        }
        return NO;
    }

    // 入口脚本必须真实存在（type: js 的 manifest 已在解析阶段保证 entry 非空）。
    // 上面两个方向都过了还走到这里 = entry 既没声明也不在盘上，是清单自相矛盾。
    if (manifest.entry.length && ![actual containsObject:manifest.entry]) {
        [A2Log log:@"[A2-PLUGIN] 完整性校验失败：入口脚本「%@」不在包里", manifest.entry];
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
