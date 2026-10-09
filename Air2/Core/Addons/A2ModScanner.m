//
//  A2ModScanner.m
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
//  实现见头文件。解析规则（字段取舍）见各 reader 函数头的说明。
//

#import "A2ModScanner.h"
#import "A2LocalMod.h"
#import "A2GameFiles.h"
#import "A2ZipReader.h"
#import "A2Strings.h"
#import "A2Log.h"
#include <string.h>

/// 禁用后缀（大小写不敏感，启用即去掉一层）。
static NSString *const kDisabledSuffix = @".disabled";

@interface A2ModScanner ()

@property (nonatomic, strong) A2GameFiles *files;

@end

#pragma mark - 文件名规则

/// 是否禁用态（后缀大小写不敏感）。
static BOOL A2ModFileIsDisabled(NSString *fileName) {
    return [[fileName lowercaseString] hasSuffix:kDisabledSuffix];
}

/// 去掉一层禁用后缀；本来就没后缀则原样返回。
static NSString *A2ModFileByStrippingDisabled(NSString *fileName) {
    if (!A2ModFileIsDisabled(fileName)) return fileName;
    return [fileName substringToIndex:fileName.length - kDisabledSuffix.length];
}

/// notMod 的展示名：去后缀再去扩展（"sodium.jar.disabled" → "sodium"）。
/// 极端空名回落到原文件名，不展示空行。
static NSString *A2NotModDisplayName(NSString *fileName) {
    NSString *base = A2ModFileByStrippingDisabled(fileName);
    NSString *noExt = [base stringByDeletingPathExtension];
    if (noExt.length == 0) return fileName;
    return noExt;
}

/// 解析失败兜底：照常列出、照常可开关删。
static A2LocalMod *A2NotMod(NSString *fileName, long long fileSize, BOOL enabled) {
    return [[A2LocalMod alloc] initWithFileName:fileName
                                    displayName:A2NotModDisplayName(fileName)
                                          modID:@""
                                        version:nil
                                        authors:@[]
                                        summary:nil
                                     loaderKind:A2ModLoaderKindUnknown
                                       fileSize:fileSize
                                        enabled:enabled
                                         notMod:YES];
}

#pragma mark - 小工具

/// 逗号分隔的作者串 → 去空白去空项（Forge 顶层 authors 形如 "Alice, Bob"）。
static NSArray<NSString *> *A2SplitAuthorsString(NSString *s) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *part in [s componentsSeparatedByString:@","]) {
        NSString *t = [part stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length > 0) [out addObject:t];
    }
    return out;
}

/// Fabric authors：字符串或 {name} 混排，只收 name。
static NSArray<NSString *> *A2AuthorsFromJSONArray(id value) {
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        NSString *name = nil;
        if ([item isKindOfClass:NSString.class]) {
            name = A2NonEmptyString(item);
        } else if ([item isKindOfClass:NSDictionary.class]) {
            name = A2NonEmptyString(((NSDictionary *)item)[@"name"]);
        }
        if (name) [out addObject:name];
    }
    return out;
}

/// Quilt contributors：{人名: 身份}，身份非空拼成 "人名 (身份)"。
static NSArray<NSString *> *A2ContributorsFromJSON(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *key in (NSDictionary *)value) {
        if (key.length == 0) continue;
        id role = ((NSDictionary *)value)[key];
        NSString *roleText = nil;
        if ([role isKindOfClass:NSString.class]) {
            roleText = A2NonEmptyString(role);
        } else if ([role isKindOfClass:NSDictionary.class]) {
            roleText = A2NonEmptyString(((NSDictionary *)role)[@"name"]);
        }
        if (roleText) {
            [out addObject:[NSString stringWithFormat:@"%@ (%@)", key, roleText]];
        } else {
            [out addObject:key];
        }
    }
    return out;
}

#pragma mark - TOML 子集

/// 行内注释去掉（# 在引号内不算注释；单双引号都跟踪）。
/// 三引号行不管（调用方另行处理多行串）。
static NSString *A2TomlStripComment(NSString *line) {
    NSMutableString *out = [NSMutableString string];
    BOOL inDouble = NO;
    BOOL inSingle = NO;
    for (NSUInteger i = 0; i < line.length; i++) {
        unichar c = [line characterAtIndex:i];
        if (c == '\\' && (inDouble || inSingle) && i + 1 < line.length) {
            [out appendFormat:@"%C%C", c, [line characterAtIndex:i + 1]];
            i++;
            continue;
        }
        if (c == '"' && !inSingle) inDouble = !inDouble;
        else if (c == '\'' && !inDouble) inSingle = !inSingle;
        if (c == '#' && !inDouble && !inSingle) break;
        [out appendFormat:@"%C", c];
    }
    return [out stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

/// 双引号串解转义（常见子集；生僻转义原样保留，不断解析）。
static NSString *A2TomlUnescape(NSString *s) {
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c != '\\' || i + 1 >= s.length) {
            [out appendFormat:@"%C", c];
            continue;
        }
        unichar n = [s characterAtIndex:i + 1];
        switch (n) {
            case '"': [out appendString:@"\""]; break;
            case '\\': [out appendString:@"\\"]; break;
            case 'n': [out appendString:@"\n"]; break;
            case 't': [out appendString:@"\t"]; break;
            case 'r': [out appendString:@"\r"]; break;
            default: [out appendFormat:@"%C%C", c, n]; break;
        }
        i++;
    }
    return out;
}

/// 顶层 key = "..."（表头出现前有效；表头后出现的顶层键忽略，从严）。
static NSString *A2TomlTopValue(NSArray<NSString *> *codeLines, NSString *key) {
    for (NSString *line in codeLines) {
        if ([line hasPrefix:@"["]) break;
        NSString *v = A2TomlKeyValue(line, key);
        if (v) return v;
    }
    return nil;
}

/// 单行 key = "..."（三引号与裸值不管，缺了上层按缺字段处理）。
static NSString *A2TomlKeyValue(NSString *line, NSString *key) {
    NSRange eq = [line rangeOfString:@"="];
    if (eq.location == NSNotFound) return nil;
    NSString *lhs = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:
                     NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![lhs isEqualToString:key]) return nil;
    NSString *rhs = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:
                     NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (rhs.length < 2 || ![rhs hasPrefix:@"\""] || ![rhs hasSuffix:@"\""]) return nil;
    return A2TomlUnescape([rhs substringWithRange:NSMakeRange(1, rhs.length - 2)]);
}

/// 取首个 [[mods]] 表（键值对均为原文串）。表头缺失、表为空、歧义即返回 nil。
/// mods.toml 的多 [[mods]] 只取首个（整合包式多模组不在管理范围，首个即所见）。
static NSDictionary<NSString *, NSString *> *A2ParseFirstModsTable(NSArray<NSString *> *codeLines) {
    NSMutableDictionary<NSString *, NSString *> *table = nil;
    for (NSString *line in codeLines) {
        if ([line hasPrefix:@"["]) {
            if (table) break;
            if ([line isEqualToString:@"[[mods]]"]) {
                table = [NSMutableDictionary dictionary];
            }
            continue;
        }
        if (!table) continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *lhs = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *rhs = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (lhs.length == 0 || rhs.length < 2) continue;
        if (![rhs hasPrefix:@"\""] || ![rhs hasSuffix:@"\""]) continue;
        table[lhs] = A2TomlUnescape([rhs substringWithRange:NSMakeRange(1, rhs.length - 2)]);
    }
    if (!table || table.count == 0) return nil;
    return table;
}

/// 全文 → 代码行（含 ''' 多行串原样保留；三引号外的注释已去）。
/// 结构坏到无法切分返回 nil（调用方按解析失败处理）。
static NSArray<NSString *> *A2TomlCodeLines(NSString *text) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableString *pendingKey = nil;
    NSMutableString *pendingBuf = nil;
    for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = rawLine;
        if ([line hasSuffix:@"\r"]) line = [line substringToIndex:line.length - 1];
        if (pendingKey) {
            NSRange end = [line rangeOfString:@"'''"];
            if (end.location == NSNotFound) {
                [pendingBuf appendString:line];
                [pendingBuf appendString:@"\n"];
                continue;
            }
            [pendingBuf appendString:[line substringToIndex:end.location]];
            // 存原文（不转义）：转义只在入库时做一次，洗两次会吃掉反斜杠。
            [out addObject:[NSString stringWithFormat:@"%@ = \"%@\"",
                            pendingKey, pendingBuf]];
            pendingKey = nil;
            pendingBuf = nil;
            continue;
        }
        NSRange triple = [line rangeOfString:@"'''"];
        if (triple.location != NSNotFound) {
            NSString *before = [[line substringToIndex:triple.location] stringByTrimmingCharactersInSet:
                                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSRange eq = [before rangeOfString:@"="];
            NSString *after = [line substringFromIndex:triple.location + 3];
            NSRange close = [after rangeOfString:@"'''"];
            if (eq.location == NSNotFound) return nil;
            NSString *lhs = [[before substringToIndex:eq.location] stringByTrimmingCharactersInSet:
                             NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (lhs.length == 0) return nil;
            if (close.location != NSNotFound) {
                [out addObject:[NSString stringWithFormat:@"%@ = \"%@\"",
                                lhs, [after substringToIndex:close.location]]];
            } else {
                pendingKey = [lhs mutableCopy];
                pendingBuf = [[after stringByAppendingString:@"\n"] mutableCopy];
            }
            continue;
        }
        [out addObject:A2TomlStripComment(line)];
    }
    if (pendingKey) return nil;
    return out;
}

#pragma mark - Reader

/// OptiFine：包内同时含两份 installer 特征即认（与其它元数据互斥，先判）。
/// 版本从 Config 类字节里的 OptiFine_ 标记后截取：可打印 ASCII 段按 _ 切，
/// 去掉前两段拼回（"OptiFine_1.20.4_HD_U_I7" → "HD_U_I7"）。
/// 截不出也认（版本 nil），特征对上就是 OptiFine 本体。
static NSString *A2OptiFineVersionFromBytes(NSData *data) {
    static const char kMarker[] = "OptiFine_";
    const size_t mlen = sizeof(kMarker) - 1;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger n = data.length;
    if (n < mlen) return nil;
    NSUInteger start = NSNotFound;
    for (NSUInteger i = 0; i + mlen <= n; i++) {
        if (memcmp(bytes + i, kMarker, mlen) == 0) { start = i; break; }
    }
    if (start == NSNotFound) return nil;
    NSUInteger end = start;
    while (end < n && bytes[end] >= 32 && bytes[end] <= 122) end++;
    NSString *full = [[NSString alloc] initWithBytes:bytes + start
                                              length:end - start
                                            encoding:NSASCIIStringEncoding];
    if (!full) return nil;
    NSArray<NSString *> *parts = [full componentsSeparatedByString:@"_"];
    if (parts.count <= 2) return @"";
    return [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)]
            componentsJoinedByString:@" "];
}

static A2LocalMod *A2ModFromOptiFine(NSString *fileName, long long fileSize, BOOL enabled,
                                     A2ZipReader *zip) {
    if (![zip containsEntry:@"optifine/Installer.class"]) return nil;
    if (![zip containsEntry:@"optifine/OptiFineTweaker.class"]) return nil;
    NSArray<NSString *> *candidates = @[@"net/optifine/Config.class",
                                        @"notch/net/optifine/Config.class",
                                        @"Config.class",
                                        @"VersionThread.class"];
    NSString *version = nil;
    for (NSString *entry in candidates) {
        NSData *data = [zip dataForEntry:entry];
        if (!data) continue;
        version = A2OptiFineVersionFromBytes(data);
        break;
    }
    return [[A2LocalMod alloc] initWithFileName:fileName
                                    displayName:@"OptiFine"
                                          modID:@"optifine"
                                        version:version
                                        authors:@[@"sp614x"]
                                        summary:nil
                                     loaderKind:A2ModLoaderKindOptiFine
                                       fileSize:fileSize
                                        enabled:enabled
                                         notMod:NO];
}

/// MANIFEST.MF 的实现版本（供 ${file.jarVersion} 回填；没有就 nil）。
static NSString *A2ManifestImplementationVersion(A2ZipReader *zip) {
    NSData *data = [zip dataForEntry:@"META-INF/MANIFEST.MF"];
    if (!data) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return nil;
    for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([line hasPrefix:@"Implementation-Version:"]) {
            NSString *v = [[line substringFromIndex:@"Implementation-Version:".length] stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet];
            return v.length > 0 ? v : nil;
        }
    }
    return nil;
}

/// fabric.mod.json：id/version 必备（名缺失回落 modID，与 quilt 同例）；
/// authors 混排只收字符串与 {name}，其余忽略。
static A2LocalMod *A2ModFromFabricJSON(NSString *fileName, long long fileSize, BOOL enabled,
                                       NSDictionary *json) {
    NSString *modID = A2NonEmptyString(json[@"id"]);
    NSString *version = A2NonEmptyString(json[@"version"]);
    if (!modID || !version) return nil;
    NSString *name = A2NonEmptyString(json[@"name"]) ?: modID;
    return [[A2LocalMod alloc] initWithFileName:fileName
                                    displayName:name
                                          modID:modID
                                        version:version
                                        authors:A2AuthorsFromJSONArray(json[@"authors"])
                                        summary:A2NonEmptyString(json[@"description"])
                                     loaderKind:A2ModLoaderKindFabric
                                       fileSize:fileSize
                                        enabled:enabled
                                         notMod:NO];
}

/// quilt.mod.json：schema_version == 1 且 id/version 齐备才认；
/// 名缺失回落 modID，简介缺失也认（空简介不影响列表，故意比严格模型放宽）。
static A2LocalMod *A2ModFromQuiltJSON(NSString *fileName, long long fileSize, BOOL enabled,
                                      NSDictionary *json) {
    id schema = json[@"schema_version"];
    if (![schema isKindOfClass:NSNumber.class] || [(NSNumber *)schema integerValue] != 1) return nil;
    id loader = json[@"quilt_loader"];
    if (![loader isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *loaderDict = (NSDictionary *)loader;
    NSString *modID = A2NonEmptyString(loaderDict[@"id"]);
    NSString *version = A2NonEmptyString(loaderDict[@"version"]);
    if (!modID || !version) return nil;
    id meta = loaderDict[@"metadata"];
    NSString *name = ([meta isKindOfClass:NSDictionary.class]
                       ? A2NonEmptyString(((NSDictionary *)meta)[@"name"]) : nil) ?: modID;
    NSString *summary = ([meta isKindOfClass:NSDictionary.class]
                          ? A2NonEmptyString(((NSDictionary *)meta)[@"description"]) : nil);
    NSArray<NSString *> *authors = ([meta isKindOfClass:NSDictionary.class]
                                     ? A2ContributorsFromJSON(((NSDictionary *)meta)[@"contributors"])
                                     : @[]);
    return [[A2LocalMod alloc] initWithFileName:fileName
                                    displayName:name
                                          modID:modID
                                        version:version
                                        authors:authors
                                        summary:summary
                                     loaderKind:A2ModLoaderKindQuilt
                                       fileSize:fileSize
                                        enabled:enabled
                                         notMod:NO];
}

/// mods.toml 系：首个 [[mods]] 表的 modId/version/displayName 齐备才认；
/// version 里的 ${file.jarVersion} 用 manifest 回填（没有填空串）；
/// authors 只读字符串形（表内逗号串，否则顶层逗号串），数组形不支持
/// （要完整 TOML 数组得写真正的解析器，为作者字段不值；缺了按空处理）。
static A2LocalMod *A2ModFromTomlText(NSString *fileName, long long fileSize, BOOL enabled,
                                     NSString *text, A2ModLoaderKind kind,
                                     NSString *jarVersion) {
    NSArray<NSString *> *codeLines = A2TomlCodeLines(text);
    if (!codeLines) return nil;
    NSDictionary<NSString *, NSString *> *table = A2ParseFirstModsTable(codeLines);
    if (!table) return nil;
    NSString *modID = A2NonEmptyString(table[@"modId"]);
    NSString *version = A2NonEmptyString(table[@"version"]);
    NSString *displayName = A2NonEmptyString(table[@"displayName"]) ?: modID;
    if (!modID || !version || !displayName) return nil;
    if ([version containsString:@"${file.jarVersion}"]) {
        version = [version stringByReplacingOccurrencesOfString:@"${file.jarVersion}"
                                                     withString:jarVersion ?: @""];
    }
    NSArray<NSString *> *authors = @[];
    NSString *tableAuthors = A2NonEmptyString(table[@"authors"]);
    if (tableAuthors) {
        authors = A2SplitAuthorsString(tableAuthors);
    } else {
        NSString *topAuthors = A2TomlTopValue(codeLines, @"authors");
        if (topAuthors) authors = A2SplitAuthorsString(topAuthors);
    }
    return [[A2LocalMod alloc] initWithFileName:fileName
                                    displayName:displayName
                                          modID:modID
                                        version:version
                                        authors:authors
                                        summary:A2NonEmptyString(table[@"description"])
                                     loaderKind:kind
                                       fileSize:fileSize
                                        enabled:enabled
                                         notMod:NO];
}

#pragma mark - A2ModScanner

@interface A2ModScanner ()

@property (nonatomic, strong) A2GameFiles *files;

@end

@implementation A2ModScanner

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：无目录的扫描器是非法状态。
    // 声明/实现一致性检查要求每个声明都有实现；正常代码走不到这里。
    return nil;
}

- (nullable instancetype)initWithModsDirectory:(NSString *)dir error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    A2GameFiles *files = [[A2GameFiles alloc] initWithRootPath:dir error:error];
    if (!files) return nil;
    _files = files;
    _modsDirectory = [files.rootPath copy];
    return self;
}

/// 逐个试身份：fabric → quilt → forge-toml → neoforge-toml，全败给兜底。
- (nullable A2LocalMod *)modForFileName:(NSString *)fileName fileSize:(long long)size {
    BOOL enabled = !A2ModFileIsDisabled(fileName);
    NSString *base = A2ModFileByStrippingDisabled(fileName);
    NSString *ext = [[base pathExtension] lowercaseString];
    if (![ext isEqualToString:@"jar"] && ![ext isEqualToString:@"zip"]) {
        return A2NotMod(fileName, size, enabled);
    }
    // 全路径由作用域根 + 清单返回名拼出：清单名不可能含 /（磁盘上不存在这种名，
    // 传进来也过不了作用域校验），拼完再标准化一次兜底。
    NSString *fullPath = [[self.modsDirectory stringByAppendingPathComponent:fileName] stringByStandardizingPath];
    A2ZipReader *zip = [[A2ZipReader alloc] initWithPath:fullPath];
    if (!zip) return A2NotMod(fileName, size, enabled);

    A2LocalMod *optiFine = A2ModFromOptiFine(fileName, size, enabled, zip);
    if (optiFine) return optiFine;

    NSData *fabricData = [zip dataForEntry:@"fabric.mod.json"];
    if (fabricData) {
        id obj = [NSJSONSerialization JSONObjectWithData:fabricData options:0 error:nil];
        if ([obj isKindOfClass:NSDictionary.class]) {
            A2LocalMod *mod = A2ModFromFabricJSON(fileName, size, enabled, (NSDictionary *)obj);
            if (mod) return mod;
        }
    }
    NSData *quiltData = [zip dataForEntry:@"quilt.mod.json"];
    if (quiltData) {
        id obj = [NSJSONSerialization JSONObjectWithData:quiltData options:0 error:nil];
        if ([obj isKindOfClass:NSDictionary.class]) {
            A2LocalMod *mod = A2ModFromQuiltJSON(fileName, size, enabled, (NSDictionary *)obj);
            if (mod) return mod;
        }
    }
    NSData *forgeData = [zip dataForEntry:@"META-INF/mods.toml"];
    NSData *neoData = [zip dataForEntry:@"META-INF/neoforge.mods.toml"];
    if (!forgeData && !neoData) return A2NotMod(fileName, size, enabled);
    // manifest 只在走到 toml 才读：非 Forge 包不花这一次 IO。
    NSString *jarVersion = A2ManifestImplementationVersion(zip);
    if (forgeData) {
        NSString *text = [[NSString alloc] initWithData:forgeData encoding:NSUTF8StringEncoding];
        if (text) {
            A2LocalMod *mod = A2ModFromTomlText(fileName, size, enabled, text,
                                               A2ModLoaderKindForge, jarVersion);
            if (mod) return mod;
        }
    }
    if (neoData) {
        NSString *text = [[NSString alloc] initWithData:neoData encoding:NSUTF8StringEncoding];
        if (text) {
            A2LocalMod *mod = A2ModFromTomlText(fileName, size, enabled, text,
                                               A2ModLoaderKindNeoForge, jarVersion);
            if (mod) return mod;
        }
    }
    return A2NotMod(fileName, size, enabled);
}

- (nullable NSArray<A2LocalMod *> *)scanMods:(NSError **)error {
    NSArray<A2GameFileEntry *> *entries = [self.files entriesInDirectory:@"" error:error];
    if (!entries) return nil;
    NSMutableArray<A2LocalMod *> *out = [NSMutableArray array];
    for (A2GameFileEntry *entry in entries) {
        if (entry.isDirectory) continue;
        A2LocalMod *mod = [self modForFileName:entry.name fileSize:entry.fileSize];
        if (mod) [out addObject:mod];
    }
    [out sortUsingComparator:^NSComparisonResult(A2LocalMod *a, A2LocalMod *b) {
        return [a.fileName compare:b.fileName];
    }];
    [A2Log log:@"mod: 扫描 %@，%lu 个", self.modsDirectory, (unsigned long)out.count];
    return out;
}

- (BOOL)applyMod:(A2LocalMod *)mod enabled:(BOOL)enabled error:(NSError **)error {
    if (!mod) return NO;
    if (mod.isEnabled == enabled) return YES;
    NSString *target = enabled ? A2ModFileByStrippingDisabled(mod.fileName)
                               : [mod.fileName stringByAppendingString:kDisabledSuffix];
    [A2Log log:@"mod: %@ %@ → %@", enabled ? @"启用" : @"禁用", mod.fileName, target];
    BOOL ok = [self.files renameEntryAt:mod.fileName toName:target error:error];
    if (ok) {
        [A2Log log:@"mod: %@完成 %@", enabled ? @"启用" : @"禁用", target];
    } else if (error && *error) {
        [A2Log log:@"mod: %@失败 %@（%@）", enabled ? @"启用" : @"禁用",
                 mod.fileName, (*error).localizedDescription];
    }
    return ok;
}

@end
