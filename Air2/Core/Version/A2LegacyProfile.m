//
//  A2LegacyProfile.m
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
//  远古版本画像实现。判定口径全部写在方法旁边（为什么这么判，而不是「大概」）。
//

#import "A2LegacyProfile.h"

#import "A2LaunchPlan.h"

/// Classic 世代的堆上限（MB）。参照真机结论：Alpha/Beta/1.0–1.6 时代的客户端
/// 常态只用几十 MB，给大堆只会让 iOS 的虚拟地址空间更紧张（Java 8 的连续预留）。
static const NSInteger kA2LegacyHeapCapMB = 192;

@interface A2LegacyProfile ()

@property (nonatomic, assign) A2LegacyGeneration generation;
@property (nonatomic, copy) NSString *versionID;
@property (nonatomic, copy) NSString *mainClass;
@property (nonatomic, copy, nullable) NSString *assetsIndexID;
@property (nonatomic, assign) BOOL requiresLWJGL2Compat;
@property (nonatomic, assign) NSInteger maxJavaMajor;
@property (nonatomic, assign) NSInteger heapCapMB;

#pragma mark - 内部判定（实现见下方）

+ (nullable NSString *)assetsIndexIDFromJSON:(NSDictionary *)json;
+ (BOOL)parseNumericVersionID:(NSString *)versionID
                        major:(NSInteger *)outMajor
                        minor:(NSInteger *)outMinor;
+ (BOOL)hasAncientSnapshotPrefix:(NSString *)versionID;

@end

@implementation A2LegacyProfile

#pragma mark - 构造

+ (nullable instancetype)profileForVersionDirectory:(NSString *)versionDirectory
                                          versionID:(NSString *)versionID {
    if (versionDirectory.length == 0 || versionID.length == 0) return nil;

    // 复用 A2LaunchPlan 的 inheritsFrom 合并（父在前、子覆盖）—— 这里不另写一份。
    NSDictionary *merged = [A2LaunchPlan mergedVersionJSONFromDirectory:versionDirectory
                                                              versionID:versionID
                                                                  error:nil];
    if (![merged isKindOfClass:NSDictionary.class]) return nil;

    return [self profileForVersionJSON:merged versionID:versionID];
}

+ (instancetype)profileForVersionJSON:(NSDictionary *)mergedJSON
                            versionID:(NSString *)versionID {
    A2LegacyProfile *profile = [[A2LegacyProfile alloc] init];
    profile.versionID = versionID ?: @"";
    profile.mainClass = [mergedJSON[@"mainClass"] isKindOfClass:NSString.class]
        ? mergedJSON[@"mainClass"] : @"";
    profile.assetsIndexID = [self assetsIndexIDFromJSON:mergedJSON];

    NSString *type = [mergedJSON[@"type"] isKindOfClass:NSString.class]
        ? [mergedJSON[@"type"] lowercaseString] : @"";

    NSInteger major = 0, minor = 0;
    BOOL parsed = [self parseNumericVersionID:profile.versionID major:&major minor:&minor];

    // ① Alpha / Beta：Mojang 自己的 type 分类，最可靠。
    BOOL isAlphaBeta = [type isEqualToString:@"old_alpha"] || [type isEqualToString:@"old_beta"];
    // ② 远古快照的 id 形态（rd-20090515 / c0.30_01c / inf-20100618 / indev-… / a1.2.6 / b1.7.3）。
    BOOL isAncientPrefix = [self hasAncientSnapshotPrefix:profile.versionID];
    // ③ 1.0–1.6.4：numeric minor ≤ 6。
    BOOL isClassicNumeric = parsed && major == 1 && minor <= 6;
    // ④ 兜底：资产索引名本身就说明了世代（pre-1.6 / legacy 只会出现在远古版本上）。
    BOOL isClassicAssets = [profile.assetsIndexID isEqualToString:@"pre-1.6"] ||
                           [profile.assetsIndexID isEqualToString:@"legacy"];

    BOOL classic = isAlphaBeta || isAncientPrefix || isClassicNumeric || isClassicAssets;
    profile.generation = classic ? A2LegacyGenerationClassic : A2LegacyGenerationModern;

    // 1.13 起才是 LWJGL 3；1.12.2 及更早（含 classic）都按 LWJGL 2 的 API 面编译。
    profile.requiresLWJGL2Compat = classic || (parsed && major == 1 && minor <= 12);

    // Java 档位：1.12.2 及更早只认 Java 8（LWJGL2 的原生库与当时的字节码档位都是 8）。
    profile.maxJavaMajor = profile.requiresLWJGL2Compat ? 8 : 0;
    profile.heapCapMB = classic ? kA2LegacyHeapCapMB : 0;
    return profile;
}

#pragma mark - 判定辅助

/// 取 assets 索引名：1.6+ 在 assetIndex.id，远古版本可能只有顶层的 assets 或干脆没有。
+ (nullable NSString *)assetsIndexIDFromJSON:(NSDictionary *)json {
    id index = json[@"assetIndex"];
    if ([index isKindOfClass:NSDictionary.class]) {
        id identifier = ((NSDictionary *)index)[@"id"];
        if ([identifier isKindOfClass:NSString.class] && [identifier length] > 0) {
            return identifier;
        }
    }
    id assets = json[@"assets"];
    if ([assets isKindOfClass:NSString.class] && [assets length] > 0) {
        return assets;
    }
    return nil;
}

/// 从版本 id 里取 (major, minor)。
///
/// 两遍匹配：
///   ① 锚在串首的 `^(\d+)\.(\d+)` —— 覆盖 "1.6.4"、"1.12.2"、"26.3"；
///   ② 否则取第一个「前后是分隔符」的 `d.d` —— 覆盖 "1.6.4-forge-9.11.1.916"
///      这类 id 里的主版本（取到 1.6），同时不会把 "fabric-loader-0.19.5" 的 0.19 当成主版本
///      （它命中后 major=0 ⇒ 后面所有 1.x 判定都不成立，落回 modern，方向是安全的）。
+ (BOOL)parseNumericVersionID:(NSString *)versionID
                        major:(NSInteger *)outMajor
                        minor:(NSInteger *)outMinor {
    if (versionID.length == 0) return NO;

    static NSRegularExpression *anchored = nil;
    static NSRegularExpression *anywhere = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        anchored = [NSRegularExpression regularExpressionWithPattern:@"^(\\d{1,2})\\.(\\d{1,3})"
                                                             options:0 error:nil];
        anywhere = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[-_])(\\d{1,2})\\.(\\d{1,3})(?=[-_.]|$)"
                                                             options:0 error:nil];
    });

    NSRange full = NSMakeRange(0, versionID.length);
    NSTextCheckingResult *match = [anchored firstMatchInString:versionID options:0 range:full];
    if (match == nil) {
        match = [anywhere firstMatchInString:versionID options:0 range:full];
    }
    if (match == nil || match.numberOfRanges < 3) return NO;

    NSInteger major = [[versionID substringWithRange:[match rangeAtIndex:1]] integerValue];
    NSInteger minor = [[versionID substringWithRange:[match rangeAtIndex:2]] integerValue];
    if (outMajor) *outMajor = major;
    if (outMinor) *outMinor = minor;
    return YES;
}

+ (BOOL)hasAncientSnapshotPrefix:(NSString *)versionID {
    NSString *lower = versionID.lowercaseString;
    for (NSString *prefix in @[@"rd-", @"c0.", @"inf-", @"indev-", @"in-", @"a1.", @"b1."]) {
        if ([lower hasPrefix:prefix]) return YES;
    }
    return NO;
}

#pragma mark - 对外判定

- (BOOL)isClassicGeneration {
    return self.generation == A2LegacyGenerationClassic;
}

- (BOOL)acceptsJavaMajorVersion:(NSInteger)major {
    if (major <= 0) return YES;           // 取不到档位 ⇒ 不判定（不猜）
    if (self.maxJavaMajor <= 0) return YES;
    return major <= self.maxJavaMajor;
}

+ (BOOL)rendererSupportsFixedPipeline:(NSString *)rendererIdentifier {
    if (rendererIdentifier.length == 0) return NO;
    NSString *lower = rendererIdentifier.lowercaseString;

    // gl4es 家族（libgl4es_114 / libnggl4es）是 GL 1.x/2.x 固定管线 → GLES 的翻译层，
    // 1.0–1.6 的 immediate mode 与 GLSL 120 内建（ftransform 等）只有它能接。
    if ([lower containsString:@"gl4es"]) return YES;

    // 明确不行的那几类（写出来是为了让下一个人不必重新踩一遍）：
    //   · libmetallum      —— Metal 直通后端，靠 javaagent 换掉现代 MC 的 GpuBackend，
    //                          远古版本没有这些类，等于没注入；
    //   · libmobileglues   —— 内部 glslang 不认 GLSL 120 的固定管线内建（ftransform 编译失败）；
    //   · libtinygl4angle  —— ANGLE 只提供 ES/GL3+ 语义，没有固定管线；
    //   · libMoltenVK      —— Vulkan，同 ANGLE 的问题更彻底。
    return NO;
}

- (NSArray<NSString *> *)jvmCompatOptions {
    if (!self.isClassicGeneration) return @[];

    // Xms 收小：启动即触发全堆 GC 扫描，大 Xms 只会拖慢远古版本的启动。
    // CodeCache 收小：Classic/Alpha 只有几百个类，大预留白白吃掉 iOS 的虚拟地址空间。
    return @[@"-Xms64M",
             @"-XX:ReservedCodeCacheSize=16m",
             @"-XX:InitialCodeCacheSize=2m"];
}

- (NSString *)diagnosticLine {
    return [NSString stringWithFormat:
            @"[A2-LEGACY] id=%@ gen=%@ lwjgl2=%d jreMax=%ld heapCap=%ld assets=%@ mainClass=%@",
            self.versionID,
            (self.isClassicGeneration ? @"classic" : @"modern"),
            self.requiresLWJGL2Compat ? 1 : 0,
            (long)self.maxJavaMajor,
            (long)self.heapCapMB,
            self.assetsIndexID ?: @"(none)",
            self.mainClass.length > 0 ? self.mainClass : @"(none)"];
}

@end
