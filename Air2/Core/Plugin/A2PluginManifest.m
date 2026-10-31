//
//  A2PluginManifest.m
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
//  见头文件。本文件只依赖 Foundation：不读磁盘、不写日志 ——
//  失败原因以 NSError 返回，由安装器决定怎么展示与记录
//  （这样数据层能在 macOS 上被单测直接链接，见 tests/Plugin/）。
//

#import "A2PluginManifest.h"

NSString *const A2PluginErrorDomain = @"dev.airdevs.air2.plugin";
NSString *const A2PluginErrorCodeKey = @"A2PluginErrorCode";
NSString *const A2PluginErrorFieldKey = @"A2PluginErrorField";

/// manifest 允许出现的顶层字段（对应 schema 的 properties）。
/// 不在这张表里的字段一律拒装 —— additionalProperties 全为 false。
static NSSet<NSString *> *A2ManifestTopLevelKeys(void) {
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"formatVersion", @"id", @"name", @"version", @"type", @"description",
            @"author", @"homepage", @"license", @"air2", @"platforms", @"permissions",
            @"depends", @"entry", @"ui", @"contributes", @"locales", @"files", @"native",
        ]];
    });
    return set;
}

/// `ui` 允许的字段。
static NSSet<NSString *> *A2ManifestUIKeys(void) {
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"priority", @"slots", @"theme", @"pages", @"overrides"]];
    });
    return set;
}

/// `contributes` 允许的字段。
static NSSet<NSString *> *A2ManifestContributesKeys(void) {
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"versionDecorate", @"downloadSources", @"versionFilter"]];
    });
    return set;
}

/// 权限目录（24 项）与风险级。**与 `docs/PLUGIN-SECURITY.md` 第二节逐项对应**，
/// 新增 / 改名权限必须同时改：本表、schema 的 permissions 枚举、
/// `PLUGIN-SECURITY.md` 第二节与第九节、`PLUGIN-AUTHORING.md` 3.3。
static NSDictionary<NSString *, NSNumber *> *A2PermissionRiskTable(void) {
    static NSDictionary<NSString *, NSNumber *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            // 启动类
            @"launch.tuning": @(A2PluginRiskMedium),
            @"launch.properties": @(A2PluginRiskMedium),
            @"launch.args": @(A2PluginRiskCritical),
            @"launch.env": @(A2PluginRiskMedium),
            @"launch.env.code": @(A2PluginRiskCritical),
            @"launch.classpath": @(A2PluginRiskCritical),
            @"launch.libraryPath": @(A2PluginRiskCritical),
            @"launch.gameArgs": @(A2PluginRiskCritical),
            @"java.agent": @(A2PluginRiskCritical),
            // 文件类
            @"files.game.read": @(A2PluginRiskMedium),
            @"files.game.write.config": @(A2PluginRiskMedium),
            @"files.game.write.content": @(A2PluginRiskCritical),
            @"files.export": @(A2PluginRiskMedium),
            // 版本类
            @"version.decorate": @(A2PluginRiskLow),
            @"version.patch": @(A2PluginRiskCritical),
            @"version.filter": @(A2PluginRiskLow),
            // 网络与下载
            @"network.http": @(A2PluginRiskMedium),
            @"download.source": @(A2PluginRiskMedium),
            @"download.fetch": @(A2PluginRiskMedium),
            // 界面类
            @"ui.contribute": @(A2PluginRiskLow),
            @"ui.override": @(A2PluginRiskMedium),
            // 实例类
            @"instance.guard": @(A2PluginRiskMedium),
            // P5 才可用
            @"native.module": @(A2PluginRiskCritical),
            @"ui.web": @(A2PluginRiskCritical),
        };
    });
    return table;
}

/// `type: json` 能申请的权限（schema 的 allOf 第 2 条）。
/// 纯 JSON 插件没有代码，运行时类权限对它没有意义，放行只会误导用户。
static NSSet<NSString *> *A2JSONOnlyPermissions(void) {
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"version.decorate", @"download.source", @"version.filter",
            @"ui.contribute", @"ui.override",
        ]];
    });
    return set;
}

/// 合法的平台值（`common` 不是合法值）。
static NSSet<NSString *> *A2SupportedPlatforms(void) {
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"ios", @"android", @"desktop"]];
    });
    return set;
}

#pragma mark - 错误

static BOOL A2Fail(NSError **error, A2PluginError code, NSString *_Nullable field,
                   NSString *format, ...) NS_FORMAT_FUNCTION(4, 5);

static BOOL A2Fail(NSError **error, A2PluginError code, NSString *_Nullable field,
                   NSString *format, ...) {
    if (!error) return NO;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message ?: @"manifest 校验失败";
    userInfo[A2PluginErrorCodeKey] = A2PluginErrorCodeString(code);
    if (field.length) userInfo[A2PluginErrorFieldKey] = field;
    *error = [NSError errorWithDomain:A2PluginErrorDomain code:code userInfo:userInfo];
    return NO;
}

NSString *A2PluginErrorCodeString(A2PluginError code) {
    switch (code) {
        case A2PluginErrorNone: return @"ok";
        case A2PluginErrorFormat: return @"E_FORMAT";
        case A2PluginErrorField: return @"E_FIELD";
        case A2PluginErrorFormatVersion: return @"E_FORMAT_VERSION";
        case A2PluginErrorPermUnknown: return @"E_PERM_UNKNOWN";
        case A2PluginErrorPath: return @"E_PATH";
        case A2PluginErrorSize: return @"E_SIZE";
        case A2PluginErrorTypeUnsupported: return @"E_TYPE_UNSUPPORTED";
        case A2PluginErrorPlatform: return @"E_PLATFORM";
        case A2PluginErrorJsonPerm: return @"E_JSON_PERM";
        case A2PluginErrorLegacySignature: return @"E_LEGACY_SIGNATURE";
    }
    return @"E_FIELD";
}

#pragma mark - 风险级

A2PluginRisk A2PluginRiskForPermission(NSString *permissionId) {
    if (![permissionId isKindOfClass:NSString.class]) return A2PluginRiskUnknown;
    NSDictionary<NSString *, NSNumber *> *table = A2PermissionRiskTable();
    NSNumber *risk = table[permissionId];
    if (!risk) return A2PluginRiskUnknown;
    return (A2PluginRisk)risk.integerValue;
}

NSString *A2PluginRiskName(A2PluginRisk risk) {
    switch (risk) {
        case A2PluginRiskLow: return @"low";
        case A2PluginRiskMedium: return @"medium";
        case A2PluginRiskCritical: return @"critical";
        case A2PluginRiskUnknown: break;
    }
    return @"unknown";
}

#pragma mark - 类型判定

static BOOL A2IsString(id value) {
    return [value isKindOfClass:NSString.class];
}

static BOOL A2IsDictionary(id value) {
    return [value isKindOfClass:NSDictionary.class];
}

static BOOL A2IsArray(id value) {
    return [value isKindOfClass:NSArray.class];
}

/// JSON 里的 true/false 也是 NSNumber，必须用 CFBoolean 的 TypeID 排掉，
/// 否则 `"formatVersion": true` 会被当成整数 1 放过。
static BOOL A2IsBoolNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    return CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

/// 是否为整数（JSON 的 2.0 也会被 NSJSONSerialization 解成 NSNumber，
/// 这里按值判断，避免「2.0 通过、2.5 不通过」的不一致）。
static BOOL A2IsIntegerNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    if (A2IsBoolNumber(value)) return NO;
    NSNumber *number = (NSNumber *)value;
    return number.doubleValue == (double)number.longLongValue;
}

#pragma mark - 标识 / 版本 / 语言标记

static BOOL A2IsLowerAlnum(unichar c) {
    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
}

static BOOL A2IsAlpha(unichar c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static BOOL A2IsAlnum(unichar c) {
    return A2IsAlpha(c) || (c >= '0' && c <= '9');
}

BOOL A2PluginIsValidIdentifier(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class]) return NO;
    if (identifier.length < 3 || identifier.length > 128) return NO;
    NSArray<NSString *> *segments = [identifier componentsSeparatedByString:@"."];
    if (segments.count < 2) return NO;
    for (NSString *segment in segments) {
        if (segment.length == 0) return NO;
        for (NSUInteger i = 0; i < segment.length; i++) {
            unichar c = [segment characterAtIndex:i];
            if (i == 0) {
                if (!A2IsLowerAlnum(c)) return NO;
            } else if (!A2IsLowerAlnum(c) && c != '_' && c != '-') {
                return NO;
            }
        }
    }
    return YES;
}

/// 点分的三段数字，每段不允许前导零（`01` 不合法）。
static BOOL A2IsDigitsSegment(NSString *segment) {
    if (![segment isKindOfClass:NSString.class] || segment.length == 0) return NO;
    if ([segment characterAtIndex:0] == '0' && segment.length > 1) return NO;
    for (NSUInteger i = 0; i < segment.length; i++) {
        unichar c = [segment characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

static BOOL A2IsPlainSemver(NSString *version) {
    if (![version isKindOfClass:NSString.class] || version.length == 0) return NO;
    NSArray<NSString *> *parts = [version componentsSeparatedByString:@"."];
    if (parts.count != 3) return NO;
    for (NSString *part in parts) {
        if (!A2IsDigitsSegment(part)) return NO;
    }
    return YES;
}

BOOL A2PluginIsValidVersion(NSString *version) {
    if (![version isKindOfClass:NSString.class]) return NO;
    if (version.length == 0 || version.length > 32) return NO;
    NSString *core = version;
    NSRange dash = [version rangeOfString:@"-"];
    if (dash.location != NSNotFound) {
        core = [version substringToIndex:dash.location];
        NSString *prerelease = [version substringFromIndex:dash.location + 1];
        if (prerelease.length == 0) return NO;
        for (NSUInteger i = 0; i < prerelease.length; i++) {
            unichar c = [prerelease characterAtIndex:i];
            if (!A2IsAlnum(c) && c != '.' && c != '-') return NO;
        }
    }
    return A2IsPlainSemver(core);
}

/// 依赖的版本约束：`x.y.z` / `=x.y.z` / `>=x.y.z` / `^x.y.z` / `~x.y.z`。
static BOOL A2IsValidVersionConstraint(NSString *constraint) {
    if (![constraint isKindOfClass:NSString.class]) return NO;
    if (constraint.length == 0 || constraint.length > 32) return NO;
    NSString *core = constraint;
    NSArray<NSString *> *prefixes = @[@">=", @"^", @"~", @"="];
    for (NSString *prefix in prefixes) {
        if ([constraint hasPrefix:prefix]) {
            core = [constraint substringFromIndex:prefix.length];
            break;
        }
    }
    return A2IsPlainSemver(core);
}

/// BCP-47 的宽松形态：`^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$`。
/// 不校验具体子标签语义（那是 locale 库的事），只拦「用下划线当分隔符」这类
/// 会让回退链失配的写法。
static BOOL A2IsValidLanguageTag(NSString *tag) {
    if (![tag isKindOfClass:NSString.class] || tag.length == 0) return NO;
    NSArray<NSString *> *parts = [tag componentsSeparatedByString:@"-"];
    if (parts.count == 0) return NO;
    NSString *primary = parts[0];
    if (primary.length < 2 || primary.length > 3) return NO;
    for (NSUInteger i = 0; i < primary.length; i++) {
        if (!A2IsAlpha([primary characterAtIndex:i])) return NO;
    }
    for (NSUInteger p = 1; p < parts.count; p++) {
        NSString *part = parts[p];
        if (part.length < 2 || part.length > 8) return NO;
        for (NSUInteger i = 0; i < part.length; i++) {
            if (!A2IsAlnum([part characterAtIndex:i])) return NO;
        }
    }
    return YES;
}

#pragma mark - 路径

/// 是否「往外跑」的路径：含 `..`、以 `/` 开头、盘符形式（`C:`）、
/// 反斜杠、控制字符。这些在解压后会落到包目录之外，或在不同平台被解释成别的意思。
static BOOL A2IsEscapingPath(NSString *path) {
    if (![path isKindOfClass:NSString.class]) return NO;
    if ([path rangeOfString:@".."].location != NSNotFound) return YES;
    if ([path hasPrefix:@"/"]) return YES;
    if ([path rangeOfString:@"\\"].location != NSNotFound) return YES;
    if (path.length >= 2) {
        unichar first = [path characterAtIndex:0];
        if (A2IsAlpha(first) && [path characterAtIndex:1] == ':') return YES;
    }
    for (NSUInteger i = 0; i < path.length; i++) {
        unichar c = [path characterAtIndex:i];
        if (c < 0x20 || c == 0x7F) return YES;
    }
    return NO;
}

/// 包内相对路径的检查，按「哪个环节不通过」返回对应错误码，便于测试与文案分档。
static A2PluginError A2CheckPackagePath(NSString *path, NSUInteger maxLength) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) return A2PluginErrorField;
    if (A2IsEscapingPath(path)) return A2PluginErrorPath;
    if (path.length > maxLength) return A2PluginErrorSize;
    if ([path hasPrefix:@"."]) return A2PluginErrorField;
    for (NSUInteger i = 0; i < path.length; i++) {
        unichar c = [path characterAtIndex:i];
        BOOL allowed = A2IsAlnum(c) || c == '.' || c == '_' || c == '/' || c == '-';
        if (!allowed) return A2PluginErrorField;
    }
    return A2PluginErrorNone;
}

/// 整棵树里第一个「往外跑」的字符串；没有则返回 nil。
/// 递归扫描而不是逐字段检查：能塞路径的字段有 entry / files[].path / locales 值 /
/// ui.pages[].source / native.ios，逐字段写检查早晚会漏一个。
static NSString *A2FirstEscapingString(id node) {
    if ([node isKindOfClass:NSString.class]) {
        return A2IsEscapingPath((NSString *)node) ? (NSString *)node : nil;
    }
    if ([node isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = (NSDictionary *)node;
        for (NSString *key in [dict allKeys]) {
            NSString *hit = A2FirstEscapingString(dict[key]);
            if (hit) return hit;
        }
        return nil;
    }
    if ([node isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)node) {
            NSString *hit = A2FirstEscapingString(item);
            if (hit) return hit;
        }
        return nil;
    }
    return nil;
}

/// 64 位小写 hex（不带前缀）。
static BOOL A2IsHexDigest(NSString *digest) {
    if (![digest isKindOfClass:NSString.class] || digest.length != 64) return NO;
    for (NSUInteger i = 0; i < digest.length; i++) {
        unichar c = [digest characterAtIndex:i];
        BOOL ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!ok) return NO;
    }
    return YES;
}

/// 字典里键是否都在白名单内；不在时把键名写进 `badKey`。
static BOOL A2AllKeysAllowed(NSDictionary *dict, NSSet<NSString *> *allowed, NSString **badKey) {
    for (NSString *key in [dict allKeys]) {
        if (![allowed containsObject:key]) {
            if (badKey) *badKey = key;
            return NO;
        }
    }
    return YES;
}

#pragma mark - 依赖 / 文件条目

@interface A2PluginDependency ()
@property (nonatomic, copy) NSString *pluginId;
@property (nonatomic, copy) NSString *versionConstraint;
@end

@implementation A2PluginDependency
@end

@interface A2PluginFileEntry ()
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *sha256;
@property (nonatomic, assign) unsigned long long size;
@end

@implementation A2PluginFileEntry
@end

#pragma mark - manifest

@interface A2PluginManifest ()
@property (nonatomic, assign) NSInteger formatVersion;
@property (nonatomic, copy) NSString *pluginId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, assign) A2PluginType type;
@property (nonatomic, copy, nullable) NSString *summary;
@property (nonatomic, copy, nullable) NSString *authorName;
@property (nonatomic, copy, nullable) NSString *authorURL;
@property (nonatomic, copy, nullable) NSString *homepage;
@property (nonatomic, copy, nullable) NSString *license;
@property (nonatomic, assign) NSInteger apiVersion;
@property (nonatomic, copy, nullable) NSString *minHostVersion;
@property (nonatomic, copy, nullable) NSString *maxHostVersion;
@property (nonatomic, copy) NSArray<NSString *> *platforms;
@property (nonatomic, copy) NSArray<NSString *> *permissions;
@property (nonatomic, copy) NSArray<A2PluginDependency *> *dependencies;
@property (nonatomic, copy, nullable) NSString *entry;
@property (nonatomic, copy) NSArray<A2PluginFileEntry *> *files;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *locales;
@end

@implementation A2PluginManifest

A2PluginLimits A2PluginDefaultLimits(void) {
    A2PluginLimits limits;
    limits.maxPackageBytes = 64ULL * 1024ULL * 1024ULL;
    limits.maxFileCount = 5000;
    limits.maxPathLength = 200;
    return limits;
}

+ (nullable instancetype)manifestWithData:(NSData *)data
                                   limits:(A2PluginLimits)limits
                                    error:(NSError **)error {
    if (![data isKindOfClass:NSData.class] || data.length == 0) {
        A2Fail(error, A2PluginErrorFormat, nil, @"manifest.json 为空");
        return nil;
    }

    // 契约要求 UTF-8 无 BOM（PLUGIN-SYSTEM 3.2）。带 BOM 的 JSON 能让某些解析器
    // 「看起来能跑」，但哈希与跨端解析都会出岔子，这里直接挡在门口。
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    if (data.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        A2Fail(error, A2PluginErrorFormat, nil,
               @"manifest.json 带 UTF-8 BOM，请用 UTF-8 无 BOM 重新导出");
        return nil;
    }

    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (!root) {
        A2Fail(error, A2PluginErrorFormat, nil, @"manifest.json 不是合法 JSON：%@",
               jsonError.localizedDescription ?: @"解析失败");
        return nil;
    }
    if (!A2IsDictionary(root)) {
        A2Fail(error, A2PluginErrorFormat, nil, @"manifest.json 的根节点必须是对象");
        return nil;
    }
    return [self manifestWithDictionary:(NSDictionary *)root limits:limits error:error];
}

+ (nullable instancetype)manifestWithDictionary:(NSDictionary<NSString *, id> *)dictionary
                                         limits:(A2PluginLimits)limits
                                          error:(NSError **)error {
    if (!A2IsDictionary(dictionary)) {
        A2Fail(error, A2PluginErrorFormat, nil, @"manifest.json 的根节点必须是对象");
        return nil;
    }
    if (limits.maxPathLength == 0 || limits.maxFileCount == 0) {
        limits = A2PluginDefaultLimits();
    }

    // ① 未知字段（additionalProperties: false）
    for (NSString *key in [dictionary allKeys]) {
        if (![A2ManifestTopLevelKeys() containsObject:key]) {
            A2Fail(error, A2PluginErrorField, key,
                   @"manifest 出现未知字段「%@」；字段名拼错也会被拒装（schema 的 "
                   @"additionalProperties 全为 false）", key);
            return nil;
        }
    }

    // ② formatVersion
    id formatVersionValue = dictionary[@"formatVersion"];
    if (!formatVersionValue) {
        A2Fail(error, A2PluginErrorField, @"formatVersion", @"缺少必填字段 formatVersion");
        return nil;
    }
    if (!A2IsIntegerNumber(formatVersionValue)) {
        A2Fail(error, A2PluginErrorField, @"formatVersion", @"formatVersion 必须是整数 2 或 3");
        return nil;
    }
    NSInteger formatVersion = [(NSNumber *)formatVersionValue integerValue];
    if (formatVersion < 2) {
        A2Fail(error, A2PluginErrorFormatVersion, @"formatVersion",
               @"formatVersion 为 %ld，本宿主只接受 2 及以上；请用当前版本重新导出",
               (long)formatVersion);
        return nil;
    }
    if (formatVersion > 3) {
        A2Fail(error, A2PluginErrorFormatVersion, @"formatVersion",
               @"formatVersion 为 %ld，需要更新版本的 Air2", (long)formatVersion);
        return nil;
    }

    // ③ 路径穿越兜底扫描（整棵树）
    NSString *escaping = A2FirstEscapingString(dictionary);
    if (escaping) {
        A2Fail(error, A2PluginErrorPath, nil,
               @"manifest 里出现越界路径「%@」：不允许 ..、绝对路径、反斜杠与控制字符",
               escaping);
        return nil;
    }

    // ④ id
    id idValue = dictionary[@"id"];
    if (!idValue) {
        A2Fail(error, A2PluginErrorField, @"id", @"缺少必填字段 id");
        return nil;
    }
    if (!A2IsString(idValue)) {
        A2Fail(error, A2PluginErrorField, @"id", @"id 必须是字符串");
        return nil;
    }
    NSString *pluginId = (NSString *)idValue;
    if (!A2PluginIsValidIdentifier(pluginId)) {
        A2Fail(error, A2PluginErrorField, @"id",
               @"id「%@」不合法：只能用小写字母/数字/点/下划线/连字符，至少两段，3～128 字符",
               pluginId);
        return nil;
    }

    // ⑤ name
    id nameValue = dictionary[@"name"];
    if (!nameValue) {
        A2Fail(error, A2PluginErrorField, @"name", @"缺少必填字段 name");
        return nil;
    }
    if (!A2IsString(nameValue)) {
        A2Fail(error, A2PluginErrorField, @"name", @"name 必须是字符串");
        return nil;
    }
    NSString *name = (NSString *)nameValue;
    if (name.length == 0 || name.length > 64) {
        A2Fail(error, A2PluginErrorField, @"name", @"name 长度必须在 1～64 字符之间");
        return nil;
    }

    // ⑥ version
    id versionValue = dictionary[@"version"];
    if (!versionValue) {
        A2Fail(error, A2PluginErrorField, @"version", @"缺少必填字段 version");
        return nil;
    }
    if (!A2IsString(versionValue)) {
        A2Fail(error, A2PluginErrorField, @"version", @"version 必须是字符串");
        return nil;
    }
    NSString *version = (NSString *)versionValue;
    if (!A2PluginIsValidVersion(version)) {
        A2Fail(error, A2PluginErrorField, @"version",
               @"version「%@」不是语义化版本（要求 x.y.z 或 x.y.z-预发布）", version);
        return nil;
    }

    // ⑦ type
    id typeValue = dictionary[@"type"];
    if (!typeValue) {
        A2Fail(error, A2PluginErrorField, @"type", @"缺少必填字段 type");
        return nil;
    }
    if (!A2IsString(typeValue)) {
        A2Fail(error, A2PluginErrorField, @"type", @"type 必须是字符串");
        return nil;
    }
    NSString *typeString = (NSString *)typeValue;
    A2PluginType type;
    if ([typeString isEqualToString:@"json"]) {
        type = A2PluginTypeJSON;
    } else if ([typeString isEqualToString:@"js"]) {
        type = A2PluginTypeJS;
    } else {
        // native 是 P5 的附加字段，不是第三个 type 值：v2 校验器看到它必须拒装
        // 而不是当成已知类型放过（见 PLUGIN-SYSTEM 2.1 的有意失败方向）。
        A2Fail(error, A2PluginErrorTypeUnsupported, @"type",
               @"type「%@」不受支持：当前只接受 json / js", typeString);
        return nil;
    }

    // ⑧ 可选文本字段
    NSString *summary = nil;
    if (dictionary[@"description"]) {
        if (!A2IsString(dictionary[@"description"])) {
            A2Fail(error, A2PluginErrorField, @"description", @"description 必须是字符串");
            return nil;
        }
        summary = (NSString *)dictionary[@"description"];
        if (summary.length > 512) {
            A2Fail(error, A2PluginErrorField, @"description", @"description 最长 512 字符");
            return nil;
        }
    }

    NSString *license = nil;
    if (dictionary[@"license"]) {
        if (!A2IsString(dictionary[@"license"])) {
            A2Fail(error, A2PluginErrorField, @"license", @"license 必须是字符串");
            return nil;
        }
        license = (NSString *)dictionary[@"license"];
        if (license.length == 0 || license.length > 64) {
            A2Fail(error, A2PluginErrorField, @"license", @"license 长度必须在 1～64 字符之间");
            return nil;
        }
    }

    NSString *homepage = nil;
    if (dictionary[@"homepage"]) {
        if (!A2IsString(dictionary[@"homepage"])) {
            A2Fail(error, A2PluginErrorField, @"homepage", @"homepage 必须是字符串");
            return nil;
        }
        homepage = (NSString *)dictionary[@"homepage"];
        BOOL schemeOK = [homepage hasPrefix:@"http://"] || [homepage hasPrefix:@"https://"];
        if (homepage.length > 256 || !schemeOK) {
            A2Fail(error, A2PluginErrorField, @"homepage",
                   @"homepage 必须是以 http:// 或 https:// 开头、最长 256 字符的地址");
            return nil;
        }
    }

    NSString *authorName = nil;
    NSString *authorURL = nil;
    if (dictionary[@"author"]) {
        id authorValue = dictionary[@"author"];
        if (!A2IsDictionary(authorValue)) {
            A2Fail(error, A2PluginErrorField, @"author", @"author 必须是对象");
            return nil;
        }
        NSDictionary *author = (NSDictionary *)authorValue;
        NSString *badKey = nil;
        if (!A2AllKeysAllowed(author, [NSSet setWithArray:@[@"name", @"url"]], &badKey)) {
            A2Fail(error, A2PluginErrorField, @"author",
                   @"author 出现未知字段「%@」", badKey);
            return nil;
        }
        if (!A2IsString(author[@"name"])) {
            A2Fail(error, A2PluginErrorField, @"author.name", @"author.name 必填且必须是字符串");
            return nil;
        }
        authorName = (NSString *)author[@"name"];
        if (authorName.length == 0 || authorName.length > 64) {
            A2Fail(error, A2PluginErrorField, @"author.name",
                   @"author.name 长度必须在 1～64 字符之间");
            return nil;
        }
        if (author[@"url"]) {
            if (!A2IsString(author[@"url"])) {
                A2Fail(error, A2PluginErrorField, @"author.url", @"author.url 必须是字符串");
                return nil;
            }
            authorURL = (NSString *)author[@"url"];
            BOOL schemeOK = [authorURL hasPrefix:@"http://"] || [authorURL hasPrefix:@"https://"];
            if (authorURL.length > 256 || !schemeOK) {
                A2Fail(error, A2PluginErrorField, @"author.url",
                       @"author.url 必须是以 http:// 或 https:// 开头、最长 256 字符的地址");
                return nil;
            }
        }
    }

    // ⑨ air2.host
    id air2Value = dictionary[@"air2"];
    if (!air2Value) {
        A2Fail(error, A2PluginErrorField, @"air2", @"缺少必填字段 air2");
        return nil;
    }
    if (!A2IsDictionary(air2Value)) {
        A2Fail(error, A2PluginErrorField, @"air2", @"air2 必须是对象");
        return nil;
    }
    NSDictionary *air2 = (NSDictionary *)air2Value;
    NSString *air2BadKey = nil;
    if (!A2AllKeysAllowed(air2, [NSSet setWithArray:@[@"host"]], &air2BadKey)) {
        A2Fail(error, A2PluginErrorField, @"air2", @"air2 出现未知字段「%@」", air2BadKey);
        return nil;
    }
    id hostValue = air2[@"host"];
    if (!A2IsDictionary(hostValue)) {
        A2Fail(error, A2PluginErrorField, @"air2.host", @"air2.host 必填且必须是对象");
        return nil;
    }
    NSDictionary *host = (NSDictionary *)hostValue;
    NSString *hostBadKey = nil;
    if (!A2AllKeysAllowed(host, [NSSet setWithArray:@[
            @"apiVersion", @"minHostVersion", @"maxHostVersion"]], &hostBadKey)) {
        A2Fail(error, A2PluginErrorField, @"air2.host",
               @"air2.host 出现未知字段「%@」", hostBadKey);
        return nil;
    }
    if (!A2IsIntegerNumber(host[@"apiVersion"])) {
        A2Fail(error, A2PluginErrorField, @"air2.host.apiVersion",
               @"air2.host.apiVersion 必填且必须是整数");
        return nil;
    }
    NSInteger apiVersion = [(NSNumber *)host[@"apiVersion"] integerValue];
    if (apiVersion != 1) {
        A2Fail(error, A2PluginErrorField, @"air2.host.apiVersion",
               @"air2.host.apiVersion 为 %ld，当前宿主只提供 API v1", (long)apiVersion);
        return nil;
    }
    NSString *minHostVersion = nil;
    NSString *maxHostVersion = nil;
    if (host[@"minHostVersion"]) {
        if (!A2IsString(host[@"minHostVersion"]) ||
            !A2IsPlainSemver((NSString *)host[@"minHostVersion"])) {
            A2Fail(error, A2PluginErrorField, @"air2.host.minHostVersion",
                   @"air2.host.minHostVersion 必须是 x.y.z 形式");
            return nil;
        }
        minHostVersion = (NSString *)host[@"minHostVersion"];
    }
    if (host[@"maxHostVersion"]) {
        if (!A2IsString(host[@"maxHostVersion"]) ||
            !A2IsPlainSemver((NSString *)host[@"maxHostVersion"])) {
            A2Fail(error, A2PluginErrorField, @"air2.host.maxHostVersion",
                   @"air2.host.maxHostVersion 必须是 x.y.z 形式");
            return nil;
        }
        maxHostVersion = (NSString *)host[@"maxHostVersion"];
    }

    // ⑩ platforms
    id platformsValue = dictionary[@"platforms"];
    if (!platformsValue) {
        A2Fail(error, A2PluginErrorField, @"platforms", @"缺少必填字段 platforms");
        return nil;
    }
    if (!A2IsArray(platformsValue)) {
        A2Fail(error, A2PluginErrorField, @"platforms", @"platforms 必须是数组");
        return nil;
    }
    NSArray *platformsArray = (NSArray *)platformsValue;
    if (platformsArray.count == 0 || platformsArray.count > 3) {
        A2Fail(error, A2PluginErrorField, @"platforms", @"platforms 必须有 1～3 项");
        return nil;
    }
    NSMutableArray<NSString *> *platforms = [NSMutableArray arrayWithCapacity:platformsArray.count];
    for (id item in platformsArray) {
        if (!A2IsString(item) || ![A2SupportedPlatforms() containsObject:(NSString *)item]) {
            A2Fail(error, A2PluginErrorField, @"platforms",
                   @"platforms 里出现非法平台「%@」：只接受 ios / android / desktop", item);
            return nil;
        }
        if ([platforms containsObject:(NSString *)item]) {
            A2Fail(error, A2PluginErrorField, @"platforms", @"platforms 里出现重复项「%@」", item);
            return nil;
        }
        [platforms addObject:(NSString *)item];
    }
    if (![platforms containsObject:@"ios"]) {
        A2Fail(error, A2PluginErrorPlatform, @"platforms",
               @"manifest.platforms 不含 ios，当前宿主只支持 iOS，无法安装");
        return nil;
    }

    // ⑪ permissions
    NSMutableArray<NSString *> *permissions = [NSMutableArray array];
    if (dictionary[@"permissions"]) {
        id permissionsValue = dictionary[@"permissions"];
        if (!A2IsArray(permissionsValue)) {
            A2Fail(error, A2PluginErrorField, @"permissions", @"permissions 必须是数组");
            return nil;
        }
        NSArray *permissionsArray = (NSArray *)permissionsValue;
        if (permissionsArray.count > 24) {
            A2Fail(error, A2PluginErrorField, @"permissions",
                   @"permissions 最多 24 项（权限目录一共 24 项）");
            return nil;
        }
        for (id item in permissionsArray) {
            if (!A2IsString(item)) {
                A2Fail(error, A2PluginErrorField, @"permissions", @"permissions 的每一项都必须是字符串");
                return nil;
            }
            NSString *permissionId = (NSString *)item;
            if (A2PluginRiskForPermission(permissionId) == A2PluginRiskUnknown) {
                A2Fail(error, A2PluginErrorPermUnknown, @"permissions",
                       @"未知权限「%@」：权限目录里没有这一项", permissionId);
                return nil;
            }
            if ([permissions containsObject:permissionId]) {
                A2Fail(error, A2PluginErrorField, @"permissions",
                       @"permissions 里出现重复项「%@」", permissionId);
                return nil;
            }
            [permissions addObject:permissionId];
        }
        if (type == A2PluginTypeJSON) {
            for (NSString *permissionId in permissions) {
                if (![A2JSONOnlyPermissions() containsObject:permissionId]) {
                    A2Fail(error, A2PluginErrorJsonPerm, @"permissions",
                           @"type 为 json 的插件不能申请运行时权限「%@」；要改代码请改成 type: js",
                           permissionId);
                    return nil;
                }
            }
        }
    }

    // ⑫ depends
    NSMutableArray<A2PluginDependency *> *dependencies = [NSMutableArray array];
    NSMutableSet<NSString *> *seenDependencies = [NSMutableSet set];
    if (dictionary[@"depends"]) {
        id dependsValue = dictionary[@"depends"];
        if (!A2IsArray(dependsValue)) {
            A2Fail(error, A2PluginErrorField, @"depends", @"depends 必须是数组");
            return nil;
        }
        NSArray *dependsArray = (NSArray *)dependsValue;
        if (dependsArray.count > 32) {
            A2Fail(error, A2PluginErrorField, @"depends", @"depends 最多 32 项");
            return nil;
        }
        NSUInteger index = 0;
        for (id item in dependsArray) {
            NSString *field = [NSString stringWithFormat:@"depends[%lu]", (unsigned long)index];
            if (!A2IsDictionary(item)) {
                A2Fail(error, A2PluginErrorField, field, @"%@ 必须是对象", field);
                return nil;
            }
            NSDictionary *dependency = (NSDictionary *)item;
            NSString *badKey = nil;
            if (!A2AllKeysAllowed(dependency, [NSSet setWithArray:@[@"id", @"version"]], &badKey)) {
                A2Fail(error, A2PluginErrorField, field,
                       @"%@ 出现未知字段「%@」", field, badKey);
                return nil;
            }
            if (!A2IsString(dependency[@"id"]) ||
                !A2PluginIsValidIdentifier((NSString *)dependency[@"id"])) {
                A2Fail(error, A2PluginErrorField, [field stringByAppendingString:@".id"],
                       @"%@ 的 id 必须是合法的插件 id", field);
                return nil;
            }
            if (!A2IsString(dependency[@"version"]) ||
                !A2IsValidVersionConstraint((NSString *)dependency[@"version"])) {
                A2Fail(error, A2PluginErrorField, [field stringByAppendingString:@".version"],
                       @"%@ 的 version 必须是 x.y.z / =x.y.z / >=x.y.z / ^x.y.z / ~x.y.z",
                       field);
                return nil;
            }
            NSString *dependencyId = (NSString *)dependency[@"id"];
            if ([seenDependencies containsObject:dependencyId]) {
                A2Fail(error, A2PluginErrorField, field,
                       @"depends 里重复声明了对「%@」的依赖", dependencyId);
                return nil;
            }
            [seenDependencies addObject:dependencyId];

            A2PluginDependency *parsed = [[A2PluginDependency alloc] init];
            parsed.pluginId = dependencyId;
            parsed.versionConstraint = (NSString *)dependency[@"version"];
            [dependencies addObject:parsed];
            index++;
        }
    }

    // ⑬ entry（js 必填、json 禁止）
    NSString *entry = nil;
    if (dictionary[@"entry"]) {
        id entryValue = dictionary[@"entry"];
        if (!A2IsString(entryValue)) {
            A2Fail(error, A2PluginErrorField, @"entry", @"entry 必须是字符串");
            return nil;
        }
        entry = (NSString *)entryValue;
        A2PluginError pathCode = A2CheckPackagePath(entry, limits.maxPathLength);
        if (pathCode != A2PluginErrorNone) {
            A2Fail(error, pathCode, @"entry", @"entry「%@」不是合法的包内相对路径", entry);
            return nil;
        }
    }
    if (type == A2PluginTypeJS && !entry) {
        A2Fail(error, A2PluginErrorField, @"entry", @"type 为 js 时必须提供 entry");
        return nil;
    }
    if (type == A2PluginTypeJSON && entry) {
        A2Fail(error, A2PluginErrorField, @"entry",
               @"type 为 json 的插件不允许提供 entry（没有代码可执行）");
        return nil;
    }

    // ⑭ files
    id filesValue = dictionary[@"files"];
    if (!filesValue) {
        A2Fail(error, A2PluginErrorField, @"files", @"缺少必填字段 files");
        return nil;
    }
    if (!A2IsArray(filesValue)) {
        A2Fail(error, A2PluginErrorField, @"files", @"files 必须是数组");
        return nil;
    }
    NSArray *filesArray = (NSArray *)filesValue;
    if (filesArray.count > limits.maxFileCount) {
        A2Fail(error, A2PluginErrorSize, @"files",
               @"包内文件数 %lu 超过上限 %lu", (unsigned long)filesArray.count,
               (unsigned long)limits.maxFileCount);
        return nil;
    }
    NSMutableArray<A2PluginFileEntry *> *files =
        [NSMutableArray arrayWithCapacity:filesArray.count];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];
    NSUInteger fileIndex = 0;
    for (id item in filesArray) {
        NSString *field = [NSString stringWithFormat:@"files[%lu]", (unsigned long)fileIndex];
        if (!A2IsDictionary(item)) {
            A2Fail(error, A2PluginErrorField, field, @"%@ 必须是对象", field);
            return nil;
        }
        NSDictionary *fileDict = (NSDictionary *)item;
        NSString *badKey = nil;
        if (!A2AllKeysAllowed(fileDict, [NSSet setWithArray:@[@"path", @"sha256", @"size"]],
                              &badKey)) {
            A2Fail(error, A2PluginErrorField, field, @"%@ 出现未知字段「%@」", field, badKey);
            return nil;
        }
        NSString *path = A2IsString(fileDict[@"path"]) ? (NSString *)fileDict[@"path"] : nil;
        A2PluginError pathCode = A2CheckPackagePath(path, limits.maxPathLength);
        if (pathCode != A2PluginErrorNone) {
            if (pathCode == A2PluginErrorSize) {
                A2Fail(error, A2PluginErrorSize,
                       [field stringByAppendingString:@".path"],
                       @"%@.path 长度 %lu 超过上限 %lu 字节", field, (unsigned long)path.length,
                       (unsigned long)limits.maxPathLength);
            } else if (pathCode == A2PluginErrorPath) {
                A2Fail(error, A2PluginErrorPath, [field stringByAppendingString:@".path"],
                       @"%@.path「%@」越界：不允许 ..、绝对路径与控制字符", field, path);
            } else {
                A2Fail(error, A2PluginErrorField, [field stringByAppendingString:@".path"],
                       @"%@.path 必须是包内相对路径（只允许字母、数字、. _ / -）", field);
            }
            return nil;
        }
        // 包根 manifest.json 不是「包内文件」，出现在清单里说明打包脚本搞错了；
        // AIR2SIG.json 是已移除的签名格式，按文档给专门的码。
        if ([path isEqualToString:@"manifest.json"]) {
            A2Fail(error, A2PluginErrorField, [field stringByAppendingString:@".path"],
                   @"%@.path 不能是 manifest.json（它不在清单里）", field);
            return nil;
        }
        if ([path isEqualToString:@"AIR2SIG.json"]) {
            A2Fail(error, A2PluginErrorLegacySignature, [field stringByAppendingString:@".path"],
                   @"此包使用了已移除的签名格式（AIR2SIG.json），请重新导出");
            return nil;
        }
        if ([seenPaths containsObject:path]) {
            A2Fail(error, A2PluginErrorField, [field stringByAppendingString:@".path"],
                   @"files 里重复声明了「%@」", path);
            return nil;
        }
        [seenPaths addObject:path];

        if (!A2IsString(fileDict[@"sha256"]) || !A2IsHexDigest((NSString *)fileDict[@"sha256"])) {
            A2Fail(error, A2PluginErrorField, [field stringByAppendingString:@".sha256"],
                   @"%@.sha256 必须是 64 位小写 hex", field);
            return nil;
        }
        if (!A2IsIntegerNumber(fileDict[@"size"])) {
            A2Fail(error, A2PluginErrorField, [field stringByAppendingString:@".size"],
                   @"%@.size 必填且必须是整数", field);
            return nil;
        }
        NSNumber *sizeNumber = (NSNumber *)fileDict[@"size"];
        if (sizeNumber.longLongValue < 0) {
            A2Fail(error, A2PluginErrorField, [field stringByAppendingString:@".size"],
                   @"%@.size 不能为负", field);
            return nil;
        }
        // 单文件解压后 32 MB（PLUGIN-SYSTEM 3.3），超出即视为 zim 炸弹的前兆。
        if (sizeNumber.unsignedLongLongValue > 32ULL * 1024ULL * 1024ULL) {
            A2Fail(error, A2PluginErrorSize, [field stringByAppendingString:@".size"],
                   @"%@.size 超过单文件上限 32 MB", field);
            return nil;
        }

        A2PluginFileEntry *fileEntry = [[A2PluginFileEntry alloc] init];
        fileEntry.path = path;
        fileEntry.sha256 = (NSString *)fileDict[@"sha256"];
        fileEntry.size = sizeNumber.unsignedLongLongValue;
        [files addObject:fileEntry];
        fileIndex++;
    }

    // ⑮ locales
    NSMutableDictionary<NSString *, NSString *> *locales = nil;
    if (dictionary[@"locales"]) {
        id localesValue = dictionary[@"locales"];
        if (!A2IsDictionary(localesValue)) {
            A2Fail(error, A2PluginErrorField, @"locales", @"locales 必须是对象");
            return nil;
        }
        NSDictionary *localesDict = (NSDictionary *)localesValue;
        if (localesDict.count > 32) {
            A2Fail(error, A2PluginErrorField, @"locales", @"locales 最多 32 项");
            return nil;
        }
        locales = [NSMutableDictionary dictionaryWithCapacity:localesDict.count];
        for (NSString *tag in [localesDict allKeys]) {
            if (!A2IsValidLanguageTag(tag)) {
                A2Fail(error, A2PluginErrorField, @"locales",
                       @"locales 的键「%@」不是合法的 BCP-47 语言标记（用 - 分隔，如 zh-Hans）",
                       tag);
                return nil;
            }
            id pathValue = localesDict[tag];
            if (!A2IsString(pathValue)) {
                A2Fail(error, A2PluginErrorField,
                       [NSString stringWithFormat:@"locales.%@", tag],
                       @"locales.%@ 的值必须是包内相对路径", tag);
                return nil;
            }
            A2PluginError pathCode = A2CheckPackagePath((NSString *)pathValue, limits.maxPathLength);
            if (pathCode != A2PluginErrorNone) {
                A2Fail(error, pathCode, [NSString stringWithFormat:@"locales.%@", tag],
                       @"locales.%@ 的路径「%@」不合法", tag, pathValue);
                return nil;
            }
            locales[tag] = (NSString *)pathValue;
        }
    }

    // ⑯ ui（浅校验）
    // 未知 slot / component 由宿主降级 + 记诊断，**不拒装**（PLUGIN-SECURITY 2.5），
    // 所以这里只查「键名是否在白名单、类型对不对、v2 有没有用 v3 字段」。
    if (dictionary[@"ui"]) {
        id uiValue = dictionary[@"ui"];
        if (!A2IsDictionary(uiValue)) {
            A2Fail(error, A2PluginErrorField, @"ui", @"ui 必须是对象");
            return nil;
        }
        NSDictionary *ui = (NSDictionary *)uiValue;
        NSString *badKey = nil;
        if (!A2AllKeysAllowed(ui, A2ManifestUIKeys(), &badKey)) {
            A2Fail(error, A2PluginErrorField, @"ui", @"ui 出现未知字段「%@」", badKey);
            return nil;
        }
        if (ui[@"priority"] && !A2IsIntegerNumber(ui[@"priority"])) {
            A2Fail(error, A2PluginErrorField, @"ui.priority", @"ui.priority 必须是整数");
            return nil;
        }
        if (ui[@"priority"]) {
            NSInteger priority = [(NSNumber *)ui[@"priority"] integerValue];
            if (priority < -1000 || priority > 1000) {
                A2Fail(error, A2PluginErrorField, @"ui.priority",
                       @"ui.priority 必须在 -1000～1000 之间");
                return nil;
            }
        }
        if (ui[@"slots"] && !A2IsArray(ui[@"slots"])) {
            A2Fail(error, A2PluginErrorField, @"ui.slots", @"ui.slots 必须是数组");
            return nil;
        }
        if (ui[@"slots"] && [(NSArray *)ui[@"slots"] count] > 64) {
            A2Fail(error, A2PluginErrorField, @"ui.slots", @"ui.slots 最多 64 项");
            return nil;
        }
        NSArray *slotItems = A2IsArray(ui[@"slots"]) ? (NSArray *)ui[@"slots"] : @[];
        for (id slotItem in slotItems) {
            if (!A2IsDictionary(slotItem)) {
                A2Fail(error, A2PluginErrorField, @"ui.slots", @"ui.slots 的每一项必须是对象");
                return nil;
            }
        }
        if (ui[@"theme"] && !A2IsDictionary(ui[@"theme"])) {
            A2Fail(error, A2PluginErrorField, @"ui.theme", @"ui.theme 必须是对象");
            return nil;
        }
        if (formatVersion == 2) {
            if (ui[@"pages"]) {
                A2Fail(error, A2PluginErrorFormatVersion, @"ui.pages",
                       @"ui.pages 是 formatVersion 3 的字段；v2 包里出现它一律拒装（否则用户会看到缺页的插件）");
                return nil;
            }
            if (ui[@"overrides"]) {
                A2Fail(error, A2PluginErrorFormatVersion, @"ui.overrides",
                       @"ui.overrides 是 formatVersion 3 的字段");
                return nil;
            }
        }
        if (ui[@"pages"] && !A2IsArray(ui[@"pages"])) {
            A2Fail(error, A2PluginErrorField, @"ui.pages", @"ui.pages 必须是数组");
            return nil;
        }
        if (ui[@"overrides"] && !A2IsArray(ui[@"overrides"])) {
            A2Fail(error, A2PluginErrorField, @"ui.overrides", @"ui.overrides 必须是数组");
            return nil;
        }
    }

    // ⑰ contributes（浅校验）
    if (dictionary[@"contributes"]) {
        id contributesValue = dictionary[@"contributes"];
        if (!A2IsDictionary(contributesValue)) {
            A2Fail(error, A2PluginErrorField, @"contributes", @"contributes 必须是对象");
            return nil;
        }
        NSString *badKey = nil;
        if (!A2AllKeysAllowed((NSDictionary *)contributesValue, A2ManifestContributesKeys(),
                              &badKey)) {
            A2Fail(error, A2PluginErrorField, @"contributes",
                   @"contributes 出现未知字段「%@」", badKey);
            return nil;
        }
    }

    // ⑱ native（仅 v3 结构允许，装载还要 P5 + 设备能力）
    if (dictionary[@"native"]) {
        id nativeValue = dictionary[@"native"];
        if (!A2IsDictionary(nativeValue)) {
            A2Fail(error, A2PluginErrorField, @"native", @"native 必须是对象");
            return nil;
        }
        if (formatVersion == 2) {
            A2Fail(error, A2PluginErrorFormatVersion, @"native",
                   @"formatVersion 2 的包不允许出现 native/ 结构（本宿主不支持原生插件）");
            return nil;
        }
        NSDictionary *native = (NSDictionary *)nativeValue;
        NSString *badKey = nil;
        if (!A2AllKeysAllowed(native, [NSSet setWithArray:@[@"ios"]], &badKey)) {
            A2Fail(error, A2PluginErrorField, @"native", @"native 出现未知字段「%@」", badKey);
            return nil;
        }
        if (!A2IsString(native[@"ios"])) {
            A2Fail(error, A2PluginErrorField, @"native.ios", @"native.ios 必填且必须是字符串");
            return nil;
        }
        NSString *dylibPath = (NSString *)native[@"ios"];
        A2PluginError pathCode = A2CheckPackagePath(dylibPath, limits.maxPathLength);
        if (pathCode != A2PluginErrorNone) {
            A2Fail(error, pathCode, @"native.ios", @"native.ios 的路径「%@」不合法", dylibPath);
            return nil;
        }
        if (![dylibPath hasPrefix:@"native/ios/"] || ![dylibPath hasSuffix:@".dylib"]) {
            A2Fail(error, A2PluginErrorField, @"native.ios",
                   @"native.ios 必须是 native/ios/<名字>.dylib");
            return nil;
        }
    }

    A2PluginManifest *manifest = [[A2PluginManifest alloc] init];
    manifest.formatVersion = formatVersion;
    manifest.pluginId = pluginId;
    manifest.name = name;
    manifest.version = version;
    manifest.type = type;
    manifest.summary = summary;
    manifest.authorName = authorName;
    manifest.authorURL = authorURL;
    manifest.homepage = homepage;
    manifest.license = license;
    manifest.apiVersion = apiVersion;
    manifest.minHostVersion = minHostVersion;
    manifest.maxHostVersion = maxHostVersion;
    manifest.platforms = platforms;
    manifest.permissions = permissions;
    manifest.dependencies = dependencies;
    manifest.entry = entry;
    manifest.files = files;
    manifest.locales = locales;
    return manifest;
}

- (BOOL)hasPermission:(NSString *)permissionId {
    if (![permissionId isKindOfClass:NSString.class]) return NO;
    return [self.permissions containsObject:permissionId];
}

+ (NSString *)canonicalPermissionSetForPermissions:(NSArray<NSString *> *)permissions {
    NSArray<NSString *> *sorted =
        [(permissions ?: @[]) sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:sorted.count];
    for (NSString *permissionId in sorted) {
        A2PluginRisk risk = A2PluginRiskForPermission(permissionId);
        [parts addObject:[NSString stringWithFormat:@"%@:%@",
                          permissionId, A2PluginRiskName(risk)]];
    }
    return [parts componentsJoinedByString:@"\n"];
}

- (NSString *)canonicalPermissionSet {
    return [A2PluginManifest canonicalPermissionSetForPermissions:self.permissions];
}

- (BOOL)validatePackageEnvelopeWithBytes:(unsigned long long)bytes
                               fileCount:(NSUInteger)fileCount
                                  limits:(A2PluginLimits)limits
                                   error:(NSError **)error {
    if (limits.maxPackageBytes == 0 || limits.maxFileCount == 0) {
        limits = A2PluginDefaultLimits();
    }
    if (bytes > limits.maxPackageBytes) {
        return A2Fail(error, A2PluginErrorSize, nil,
                      @"包体 %llu 字节超过上限 %llu 字节", bytes, limits.maxPackageBytes);
    }
    if (fileCount > limits.maxFileCount) {
        return A2Fail(error, A2PluginErrorSize, nil,
                      @"包内条目数 %lu 超过上限 %lu", (unsigned long)fileCount,
                      (unsigned long)limits.maxFileCount);
    }
    if (self.files.count > fileCount) {
        return A2Fail(error, A2PluginErrorSize, @"files",
                      @"manifest.files 声明了 %lu 个文件，但包内只有 %lu 个条目",
                      (unsigned long)self.files.count, (unsigned long)fileCount);
    }
    return YES;
}

@end
