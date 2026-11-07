//
//  A2PluginContribution.m
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
//  贡献点深校验 + 纯内存注册表。头文件的「这一层在整条链里的位置」是契约，这里只写
//  **为什么这么判**，不重复抄文档字段表。
//
//  三件事按顺序发生：
//    ① 校验（`A2PluginContributionSet`）：把 manifest 的 ui / contributes 变成不可变模型。
//       失败一定带 `E_*` 码 + 字段路径 + 人话原因 —— 不许出现「manifest 不合法」这种笼统话。
//    ② 去重与排序（注册表）：同插件重复接入是幂等替换；逐字段相同的声明合并；
//       顺序键 `(priority, layer, pluginId, declarationIndex)` 全升序。
//    ③ 卸载（注册表）：`removeContributionsForPlugin:` 一次摘干净，状态回到接入之前。
//

#import "A2PluginContribution.h"

#import <dispatch/dispatch.h>   // 注册表的串行队列（见文件末尾【线程】）
#include <string.h>

#pragma mark - 错误

NSString *A2PluginContributionErrorCodeString(A2PluginContributionError code) {
    switch (code) {
        case A2PluginContributionErrorNone: return @"ok";
        case A2PluginContributionErrorFormat: return @"E_FORMAT";
        case A2PluginContributionErrorField: return @"E_FIELD";
        case A2PluginContributionErrorContribUnknown: return @"E_CONTRIB_UNKNOWN";
        case A2PluginContributionErrorSlotUnknown: return @"E_SLOT_UNKNOWN";
        case A2PluginContributionErrorComponentUnknown: return @"E_COMPONENT_UNKNOWN";
        case A2PluginContributionErrorDuplicate: return @"E_CONTRIB_DUPLICATE";
        case A2PluginContributionErrorSlotConflict: return @"E_SLOT_CONFLICT";
        case A2PluginContributionErrorContribPermission: return @"E_CONTRIB_PERM";
        case A2PluginContributionErrorHostVersionMin: return @"E_HOST_VERSION_MIN";
        case A2PluginContributionErrorHostVersionMax: return @"E_HOST_VERSION_MAX";
    }
    return @"E_FIELD";
}

NSError *A2PluginContributionErrorMake(A2PluginContributionError code,
                                       NSString *_Nullable field,
                                       NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // userInfo 与 P1 的 A2PluginErrorMake 逐键一致：管理页只有一套读法。
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setObject:(message ?: @"插件贡献点校验失败") forKey:NSLocalizedDescriptionKey];
    [userInfo setObject:A2PluginContributionErrorCodeString(code) forKey:A2PluginErrorCodeKey];
    if (field.length > 0) {
        [userInfo setObject:field forKey:A2PluginErrorFieldKey];
    }
    return [NSError errorWithDomain:A2PluginErrorDomain code:code userInfo:userInfo];
}

static BOOL A2CFail(NSError **error, A2PluginContributionError code, NSString *_Nullable field,
                    NSString *format, ...) NS_FORMAT_FUNCTION(4, 5);

static BOOL A2CFail(NSError **error, A2PluginContributionError code, NSString *_Nullable field,
                    NSString *format, ...) {
    if (error) {
        va_list args;
        va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        *error = A2PluginContributionErrorMake(code, field, @"%@", message ?: @"贡献点校验失败");
    }
    return NO;
}

#pragma mark - 词表

/// v2 slot 词表（`PLUGIN-COMPAT.md` 2.2）。v3 的 `home.page` / `versions.list.page` 不在其中：
/// 它们是**整页入口**，v2 包声明它们等于声明了一个宿主画不出来的页面。
static NSSet<NSString *> *A2CKnownSlots(void) {
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"home.toolbar.action", @"home.card.badge", @"versions.list.badge",
            @"version.detail.header", @"settings.section", @"home.section", @"launch.overlay",
        ]];
    });
    return set;
}

/// v3 才有的 slot —— 单独一张表，只为了在报错时能说「这是 v3 的，不是拼错了」。
static NSSet<NSString *> *A2CV3OnlySlots(void) {
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"home.page", @"versions.list.page"]];
    });
    return set;
}

/// v2 叶子组件词表（`PLUGIN-COMPAT.md` 2.3 第一张表）。容器与 v3 叶子不收：
/// 纯 JSON 插件的 slot 只放叶子，页面才用容器（P3b）。
static NSSet<NSString *> *A2CKnownComponents(void) {
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"text.label", @"text.caption", @"button.primary", @"button.secondary",
            @"switch.toggle", @"list.row", @"badge.status", @"icon.glyph",
            @"divider", @"spacer",
        ]];
    });
    return set;
}

/// 主题 token → MD3 语义角色（`A2ColorScheme` 的属性名）。
/// 键的写法：`color.` + 角色名按词用 `.` 分隔、全小写（`plugin.schema.json` 的
/// `propertyNames` 只允许小写字母与点，所以 `color.surfaceContainerHigh` 那种驼峰写法是**非法键**，
/// 这里给的是唯一合法形状 `color.surface.container.high`）。
/// `color.accent` 是 `color.primary` 的别名 —— 文档示例用它，不能让它变成「未知 token」。
static NSDictionary<NSString *, NSString *> *A2CThemeTokenTable(void) {
    static NSDictionary<NSString *, NSString *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"color.accent": @"primary",
            @"color.primary": @"primary",
            @"color.on.primary": @"onPrimary",
            @"color.primary.container": @"primaryContainer",
            @"color.on.primary.container": @"onPrimaryContainer",
            @"color.secondary": @"secondary",
            @"color.on.secondary": @"onSecondary",
            @"color.secondary.container": @"secondaryContainer",
            @"color.on.secondary.container": @"onSecondaryContainer",
            @"color.tertiary": @"tertiary",
            @"color.tertiary.container": @"tertiaryContainer",
            @"color.surface": @"surface",
            @"color.on.surface": @"onSurface",
            @"color.surface.variant": @"surfaceVariant",
            @"color.on.surface.variant": @"onSurfaceVariant",
            @"color.surface.container": @"surfaceContainer",
            @"color.surface.container.lowest": @"surfaceContainerLowest",
            @"color.surface.container.low": @"surfaceContainerLow",
            @"color.surface.container.high": @"surfaceContainerHigh",
            @"color.surface.container.highest": @"surfaceContainerHighest",
            @"color.outline": @"outline",
            @"color.outline.variant": @"outlineVariant",
            @"color.error": @"error",
            @"color.on.error": @"onError",
            @"color.error.container": @"errorContainer",
            @"color.on.error.container": @"onErrorContainer",
            @"color.success": @"success",
            @"color.warning": @"warning",
            @"color.inverse.surface": @"inverseSurface",
            @"color.inverse.on.surface": @"inverseOnSurface",
            @"color.inverse.primary": @"inversePrimary",
        };
    });
    return table;
}

BOOL A2PluginIsKnownSlotName(NSString *_Nullable slot) {
    if (![slot isKindOfClass:NSString.class]) return NO;
    return [A2CKnownSlots() containsObject:slot];
}

BOOL A2PluginIsKnownComponentName(NSString *_Nullable component) {
    if (![component isKindOfClass:NSString.class]) return NO;
    return [A2CKnownComponents() containsObject:component];
}

NSUInteger A2PluginSlotCapacity(NSString *_Nullable slot) {
    if (![slot isKindOfClass:NSString.class]) return 0;
    if ([slot isEqualToString:@"home.toolbar.action"]) return 4;
    if ([slot isEqualToString:@"home.card.badge"]) return 1;
    return 0;   // 0 = 不限
}

BOOL A2PluginIsKnownThemeToken(NSString *_Nullable token) {
    if (![token isKindOfClass:NSString.class]) return NO;
    return [A2CThemeTokenTable() objectForKey:token] != nil;
}

NSString *_Nullable A2PluginThemeTokenRole(NSString *_Nullable token) {
    if (![token isKindOfClass:NSString.class]) return nil;
    return [A2CThemeTokenTable() objectForKey:token];
}

/// 给「写错的 token」找一个最可能的正确写法，用在诊断里。
/// 触发面：作者把 MD3 角色照原样搬过来、只是没按词拆点，例如
/// `color.surfacecontainerhigh`（全小写、合法形状 ⇒ 走到「未知 token」分支）。
/// 做法：把输入的最后一段当作角色名，和词表里的角色逐个比（忽略大小写）。
/// 找不到就返回 nil —— **不猜**，宁可不说也不要给一个错建议。
static NSString *_Nullable A2CSuggestThemeToken(NSString *token) {
    if (![token isKindOfClass:NSString.class]) return nil;
    NSString *lastSegment = [[token componentsSeparatedByString:@"."] lastObject];
    if (lastSegment.length == 0) return nil;
    NSString *flattened = [lastSegment lowercaseString];
    for (NSString *candidate in A2CThemeTokenTable()) {
        NSString *role = A2PluginThemeTokenRole(candidate);
        if (role == nil) continue;
        if ([[role lowercaseString] isEqualToString:flattened]) return candidate;
    }
    return nil;
}

#pragma mark - 层

A2PluginContributionLayer A2PluginContributionLayerForPermissions(NSArray<NSString *> *_Nullable permissions) {
    // 层由**申请的能力**推导（ADR-018 决策 3）：作者写什么都不影响判定。
    // 顺序即优先级：只要申请了 ui.override 就是 L2，哪怕同时有 ui.contribute。
    if ([permissions containsObject:@"ui.override"]) return A2PluginContributionLayerOverride;
    if ([permissions containsObject:@"ui.contribute"]) return A2PluginContributionLayerDecor;
    return A2PluginContributionLayerData;
}

NSString *A2PluginContributionLayerName(A2PluginContributionLayer layer) {
    switch (layer) {
        case A2PluginContributionLayerData: return @"L0";
        case A2PluginContributionLayerDecor: return @"L1";
        case A2PluginContributionLayerOverride: return @"L2";
    }
    return @"L0";
}

#pragma mark - 类型 / 形状判定小工具

static BOOL A2CIsString(id value) {
    return [value isKindOfClass:NSString.class];
}

static BOOL A2CIsDictionary(id value) {
    return [value isKindOfClass:NSDictionary.class];
}

static BOOL A2CIsArray(id value) {
    return [value isKindOfClass:NSArray.class];
}

/// JSON 里的整数（`NSJSONSerialization` 会给 NSNumber；布尔也是 NSNumber，要排除掉，
/// 否则 `"priority": true` 会被当成 1 通过 —— P1 同样的坑，这里保持一致）。
/// 同时排除 `f`/`d`（小数）与 `B`（C99 `_Bool`，arm64 上 `@YES` 可能是它）。
static BOOL A2CIsInteger(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    const char *type = [(NSNumber *)value objCType];
    if (type == NULL) return NO;
    if (strcmp(type, @encode(BOOL)) == 0) return NO;
    if (strcmp(type, "c") == 0 || strcmp(type, "B") == 0) return NO;
    return strcmp(type, "d") != 0 && strcmp(type, "f") != 0;
}

static BOOL A2CIsScalar(id value) {
    if (!value || value == [NSNull null]) return YES;
    return [value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class];
}

static BOOL A2CIsLowerAlpha(unichar c) { return c >= 'a' && c <= 'z'; }
static BOOL A2CIsDigit(unichar c) { return c >= '0' && c <= '9'; }

/// 条目 id：`^[a-z][a-z0-9_.-]*$`，1～64 字符（`plugin.schema.json` 的 `ui.slots[].id`）。
static BOOL A2CIsEntryIdentifier(NSString *value) {
    if (!A2CIsString(value) || value.length == 0 || value.length > 64) return NO;
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if (i == 0) {
            if (!A2CIsLowerAlpha(c)) return NO;
            continue;
        }
        if (!(A2CIsLowerAlpha(c) || A2CIsDigit(c) || c == '.' || c == '_' || c == '-')) return NO;
    }
    return YES;
}

/// 语义 ID（图标 / token 键）：点分小写段，至少两段。
/// @param allowUnderscore 图标 ID 允许 `_`（schema 的 `iconId`），token 键不允许。
static BOOL A2CIsDottedLowerIdentifier(NSString *value, BOOL allowUnderscore, NSUInteger maxLength) {
    if (!A2CIsString(value) || value.length == 0 || value.length > maxLength) return NO;
    NSArray<NSString *> *segments = [value componentsSeparatedByString:@"."];
    if (segments.count < 2) return NO;
    for (NSString *segment in segments) {
        if (segment.length == 0) return NO;
        for (NSUInteger i = 0; i < segment.length; i++) {
            unichar c = [segment characterAtIndex:i];
            if (i == 0) {
                if (!A2CIsLowerAlpha(c)) return NO;
                continue;
            }
            BOOL ok = A2CIsLowerAlpha(c) || A2CIsDigit(c) || (allowUnderscore && c == '_');
            if (!ok) return NO;
        }
    }
    return YES;
}

/// 主题颜色值：`#RRGGBB`（六个 hex）。只收这一种形状 ——
/// 「rgb()」「颜色名」「#RGBA」留给宿主以后的扩展，现在收下就无法保证能被解析。
static BOOL A2CIsHexColor(NSString *value) {
    if (!A2CIsString(value) || value.length != 7) return NO;
    if ([value characterAtIndex:0] != '#') return NO;
    for (NSUInteger i = 1; i < 7; i++) {
        unichar c = [value characterAtIndex:i];
        BOOL isHex = A2CIsDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!isHex) return NO;
    }
    return YES;
}

/// 绑定路径：`state.*` / `item.*` 的点分路径。纯 JSON 插件的绑定恒为空值，
/// 但**形状**在安装期就要对 —— 否则要等到 P3b 页面渲染才发现写错。
static BOOL A2CIsBindingPath(NSString *value) {
    if (!A2CIsString(value) || value.length == 0 || value.length > 128) return NO;
    if (![value hasPrefix:@"state."] && ![value hasPrefix:@"item."]) return NO;
    return [value componentsSeparatedByString:@"."].count >= 2;
}

#pragma mark - 单条贡献

/// nil 归一成空串，供下面逐字段比较用（`isIdenticalDeclaration:` 用到，必须先声明）。
static NSString *A2CNilableString(NSString *_Nullable value);

@interface A2PluginSlotContribution ()
@property (nonatomic, copy) NSString *pluginId;
@property (nonatomic, copy) NSString *pluginVersion;
@property (nonatomic, copy) NSString *slot;
@property (nonatomic, copy) NSString *component;
@property (nonatomic, copy, nullable) NSString *identifier;
@property (nonatomic, copy, nullable) NSString *icon;
@property (nonatomic, copy, nullable) NSString *labelI18n;
@property (nonatomic, copy, nullable) NSString *labelText;
@property (nonatomic, copy, nullable) NSString *actionId;
@property (nonatomic, assign) NSInteger priority;
@property (nonatomic, assign) NSInteger pluginPriority;
@property (nonatomic, assign) A2PluginContributionLayer layer;
@property (nonatomic, assign) NSUInteger declarationIndex;
@end

@implementation A2PluginSlotContribution

- (BOOL)isIdenticalDeclaration:(A2PluginSlotContribution *)other {
    if (![other isKindOfClass:A2PluginSlotContribution.class]) return NO;
    if (![self.slot isEqualToString:other.slot]) return NO;
    if (![self.component isEqualToString:other.component]) return NO;
    if (self.priority != other.priority) return NO;
    // 可空字段逐项比：nil 与 @"" 都算「没有」，否则 `label: {i18n: ""}` 这种边角会误判成不同。
    if (![A2CNilableString(self.identifier) isEqualToString:A2CNilableString(other.identifier)]) return NO;
    if (![A2CNilableString(self.icon) isEqualToString:A2CNilableString(other.icon)]) return NO;
    if (![A2CNilableString(self.labelI18n) isEqualToString:A2CNilableString(other.labelI18n)]) return NO;
    if (![A2CNilableString(self.labelText) isEqualToString:A2CNilableString(other.labelText)]) return NO;
    if (![A2CNilableString(self.actionId) isEqualToString:A2CNilableString(other.actionId)]) return NO;
    return YES;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ slot=%@ component=%@ id=%@ priority=%ld layer=%@>",
            NSStringFromClass(self.class), self.pluginId, self.slot, self.component,
            self.identifier ?: @"-", (long)self.priority,
            A2PluginContributionLayerName(self.layer)];
}

@end

/// nil 归一成空串，供上面逐字段比较用。
static NSString *A2CNilableString(NSString *_Nullable value) {
    return value ?: @"";
}

#pragma mark - 版本行装饰

@interface A2PluginVersionDecoration ()
@property (nonatomic, copy) NSString *pluginId;
@property (nonatomic, copy) NSString *pluginVersion;
@property (nonatomic, copy, nullable) NSString *titleTemplate;
@property (nonatomic, copy, nullable) NSString *subtitleTemplate;
@property (nonatomic, copy, nullable) NSString *badgeI18n;
@property (nonatomic, copy, nullable) NSString *badgeText;
@property (nonatomic, copy, nullable) NSString *icon;
@property (nonatomic, assign) NSInteger priority;
@property (nonatomic, assign) A2PluginContributionLayer layer;
@end

@implementation A2PluginVersionDecoration

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ title=%@ subtitle=%@ badge=%@>",
            NSStringFromClass(self.class), self.pluginId,
            self.titleTemplate ?: @"-", self.subtitleTemplate ?: @"-",
            self.badgeI18n ?: self.badgeText ?: @"-"];
}

@end

#pragma mark - 排序键

/// 全升序：插件级 priority → 层 → pluginId → 条目 priority → 声明下标。
/// 前三级就是 `PLUGIN-SYSTEM.md` 5.2 的加载顺序三元组；后两级只用来确定同一个插件内部的先后
/// （否则「同插件两条同 priority 的贡献」顺序会随字典遍历变化，不是「每次启动一致」）。
/// 用 C 比较函数而不是 block：本文件不持有 block。
static NSInteger A2CCompareContributions(id a, id b, void *context) {
    (void)context;
    A2PluginSlotContribution *left = a;
    A2PluginSlotContribution *right = b;
    if (left.pluginPriority != right.pluginPriority) {
        return left.pluginPriority < right.pluginPriority ? NSOrderedAscending : NSOrderedDescending;
    }
    if (left.layer != right.layer) return left.layer < right.layer ? NSOrderedAscending : NSOrderedDescending;
    NSComparisonResult byPlugin = [left.pluginId compare:right.pluginId];
    if (byPlugin != NSOrderedSame) return byPlugin;
    if (left.priority != right.priority) return left.priority < right.priority ? NSOrderedAscending : NSOrderedDescending;
    if (left.declarationIndex != right.declarationIndex) {
        return left.declarationIndex < right.declarationIndex ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}

static NSInteger A2CCompareDecorations(id a, id b, void *context) {
    (void)context;
    A2PluginVersionDecoration *left = a;
    A2PluginVersionDecoration *right = b;
    if (left.priority != right.priority) return left.priority < right.priority ? NSOrderedAscending : NSOrderedDescending;
    if (left.layer != right.layer) return left.layer < right.layer ? NSOrderedAscending : NSOrderedDescending;
    return [left.pluginId compare:right.pluginId];
}

#pragma mark - 贡献集

@interface A2PluginContributionSet ()
@property (nonatomic, copy) NSString *pluginId;
@property (nonatomic, copy) NSString *pluginVersion;
@property (nonatomic, assign) NSInteger priority;
@property (nonatomic, assign) A2PluginContributionLayer layer;
@property (nonatomic, copy) NSArray<A2PluginSlotContribution *> *slotContributions;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *themeTokens;
@property (nonatomic, strong, nullable) A2PluginVersionDecoration *versionDecoration;
@property (nonatomic, copy) NSArray<NSString *> *diagnostics;

// 单项解析器：主校验方法在它们定义之前调用，所以先声明（ARC 下「未知类方法」是错误不是警告）。
+ (BOOL)parseSlotItem:(id)rawItem
                field:(NSString *)field
             pluginId:(NSString *)pluginId
        pluginVersion:(NSString *)pluginVersion
            uiPriority:(NSInteger)uiPriority
                 layer:(A2PluginContributionLayer)layer
       declarationIndex:(NSUInteger)index
              outItem:(A2PluginSlotContribution **)outItem
          diagnostics:(NSMutableArray<NSString *> *)diagnostics
                error:(NSError **)error;
+ (BOOL)parseLocalizedText:(id)value
                     field:(NSString *)field
                   outI18n:(NSString **)outI18n
                   outText:(NSString **)outText
                     error:(NSError **)error;
+ (BOOL)parseAction:(id)value
              field:(NSString *)field
              outId:(NSString **)outId
              error:(NSError **)error;
+ (BOOL)parseVersionDecorate:(NSDictionary *)value
                    pluginId:(NSString *)pluginId
               pluginVersion:(NSString *)pluginVersion
                       layer:(A2PluginContributionLayer)layer
                    priority:(NSInteger)priority
                      outDec:(A2PluginVersionDecoration **)outDecoration
                       error:(NSError **)error;
@end

@implementation A2PluginContributionSet

#pragma mark 入口

+ (nullable instancetype)setWithManifestData:(NSData *)manifestData
                                 hostVersion:(NSString *)hostVersion
                                   milestone:(A2PluginHostMilestone)milestone
                                       error:(NSError **)error {
    if (![manifestData isKindOfClass:NSData.class] || manifestData.length == 0) {
        A2CFail(error, A2PluginContributionErrorFormat, nil,
                @"manifest.json 为空：读不到贡献点声明");
        return nil;
    }
    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&jsonError];
    if (!A2CIsDictionary(root)) {
        A2CFail(error, A2PluginContributionErrorFormat, nil,
                @"manifest.json 解析失败：根节点必须是对象（%@）",
                jsonError.localizedDescription ?: @"语法错误");
        return nil;
    }
    return [self setWithManifestDictionary:(NSDictionary *)root
                               hostVersion:hostVersion
                                 milestone:milestone
                                     error:error];
}

#pragma mark 主校验

+ (nullable instancetype)setWithManifestDictionary:(NSDictionary<NSString *, id> *)dictionary
                                       hostVersion:(NSString *)hostVersion
                                         milestone:(A2PluginHostMilestone)milestone
                                             error:(NSError **)error {
    if (!A2CIsDictionary(dictionary)) {
        A2CFail(error, A2PluginContributionErrorFormat, nil, @"manifest 根节点必须是对象");
        return nil;
    }
    if (![hostVersion isKindOfClass:NSString.class] || !A2PluginIsValidVersion(hostVersion)) {
        // 宿主版本由宿主自己给，拿不到就没法判 min/maxHostVersion —— 这是装配错误，
        // 不是包的问题；报出来比默默跳过版本门好。
        A2CFail(error, A2PluginContributionErrorField, nil,
                @"hostVersion「%@」不是 x.y.z 形式：贡献点校验需要宿主版本才能判版本区间",
                hostVersion ?: @"(nil)");
        return nil;
    }

    // ① formatVersion：包结构版本。本层只判「本宿主阶段能不能读」，字段本身归 P1。
    id formatVersionValue = [dictionary objectForKey:@"formatVersion"];
    if (!A2CIsInteger(formatVersionValue)) {
        A2CFail(error, A2PluginContributionErrorField, @"formatVersion",
                @"formatVersion 必填且必须是整数 2 或 3");
        return nil;
    }
    NSInteger formatVersion = [(NSNumber *)formatVersionValue integerValue];
    if (formatVersion < 2 || formatVersion > 3) {
        *error = A2PluginErrorMake(A2PluginErrorFormatVersion, @"formatVersion",
                                   @"formatVersion 为 %ld，本宿主只接受 2 或 3", (long)formatVersion);
        return nil;
    }
    if (formatVersion >= 3 && milestone < A2PluginHostMilestoneP3b) {
        // v3 的 pages / overrides 宿主画不出来。「忽略 pages 继续装」会让用户看到缺页的插件。
        *error = A2PluginErrorMake(A2PluginErrorFormatVersion, @"formatVersion",
                                   @"formatVersion 为 %ld（v3 页面/覆盖模型），当前宿主阶段只支持 2："
                                   @"需要更新版本的 Air2", (long)formatVersion);
        return nil;
    }

    // ② type：P2 宿主没有 JSCore ⇒ js 包拒装（ADR-019）。码必须与 P1 逐字相同。
    id typeValue = [dictionary objectForKey:@"type"];
    if (!A2CIsString(typeValue)) {
        A2CFail(error, A2PluginContributionErrorField, @"type", @"type 必填且必须是字符串 json / js");
        return nil;
    }
    NSString *typeString = (NSString *)typeValue;
    if (![typeString isEqualToString:@"json"] && ![typeString isEqualToString:@"js"]) {
        *error = A2PluginErrorMake(A2PluginErrorTypeUnsupported, @"type",
                                   @"type「%@」不受支持：当前只接受 json / js", typeString);
        return nil;
    }
    if ([typeString isEqualToString:@"js"] && milestone < A2PluginHostMilestoneP3a) {
        *error = A2PluginErrorMake(A2PluginErrorTypeUnsupported, @"type",
                                   @"本宿主阶段（P2，纯 JSON 声明）不能安装 type: js 的插件："
                                   @"没有 JSCore 运行时，装上也永远不会执行。"
                                   @"要代码能力请等 P3a，或把插件改写成纯 JSON");
        return nil;
    }

    // ③ id / version：P1 已校验过；这里只取用，缺失即装配错误。
    id idValue = [dictionary objectForKey:@"id"];
    if (!A2CIsString(idValue) || !A2PluginIsValidIdentifier((NSString *)idValue)) {
        A2CFail(error, A2PluginContributionErrorField, @"id",
                @"贡献点校验要求 manifest 已通过 P1 校验：id 缺失或不合法（%@）",
                idValue ?: @"(nil)");
        return nil;
    }
    NSString *pluginId = (NSString *)idValue;

    id versionValue = [dictionary objectForKey:@"version"];
    if (!A2CIsString(versionValue) || !A2PluginIsValidVersion((NSString *)versionValue)) {
        A2CFail(error, A2PluginContributionErrorField, @"version",
                @"贡献点校验要求 manifest 已通过 P1 校验：version 缺失或不合法（%@）",
                versionValue ?: @"(nil)");
        return nil;
    }
    NSString *pluginVersion = (NSString *)versionValue;

    // ④ 版本区间：minHostVersion / maxHostVersion 是对**宿主**的要求（`PLUGIN-API.md` 第二节）。
    //    semver 比较复用 P1 的 A2PluginCompareVersions —— 字符串比大小会把 1.10.0 判得比 1.9.0 小。
    id air2Value = [dictionary objectForKey:@"air2"];
    NSDictionary *hostRequirement = nil;
    if (air2Value != nil) {
        if (!A2CIsDictionary(air2Value)) {
            A2CFail(error, A2PluginContributionErrorField, @"air2", @"air2 必须是对象");
            return nil;
        }
        id hostValue = [(NSDictionary *)air2Value objectForKey:@"host"];
        if (!A2CIsDictionary(hostValue)) {
            A2CFail(error, A2PluginContributionErrorField, @"air2.host",
                    @"air2.host 必填且必须是对象");
            return nil;
        }
        hostRequirement = (NSDictionary *)hostValue;
    }
    NSString *minHostVersion = nil;
    NSString *maxHostVersion = nil;
    if (hostRequirement != nil) {
        id minValue = [hostRequirement objectForKey:@"minHostVersion"];
        if (minValue != nil) {
            if (!A2CIsString(minValue) || !A2PluginIsValidVersion((NSString *)minValue)) {
                A2CFail(error, A2PluginContributionErrorField, @"air2.host.minHostVersion",
                        @"air2.host.minHostVersion 必须是 x.y.z 形式");
                return nil;
            }
            minHostVersion = (NSString *)minValue;
        }
        id maxValue = [hostRequirement objectForKey:@"maxHostVersion"];
        if (maxValue != nil) {
            if (!A2CIsString(maxValue) || !A2PluginIsValidVersion((NSString *)maxValue)) {
                A2CFail(error, A2PluginContributionErrorField, @"air2.host.maxHostVersion",
                        @"air2.host.maxHostVersion 必须是 x.y.z 形式");
                return nil;
            }
            maxHostVersion = (NSString *)maxValue;
        }
    }
    if (minHostVersion && A2PluginCompareVersions(hostVersion, minHostVersion) < 0) {
        A2CFail(error, A2PluginContributionErrorHostVersionMin, @"air2.host.minHostVersion",
                @"此插件要求 Air2 ≥ %@，当前宿主是 %@", minHostVersion, hostVersion);
        return nil;
    }
    if (maxHostVersion && A2PluginCompareVersions(hostVersion, maxHostVersion) > 0) {
        A2CFail(error, A2PluginContributionErrorHostVersionMax, @"air2.host.maxHostVersion",
                @"此插件声明不支持 Air2 > %@（当前宿主 %@）", maxHostVersion, hostVersion);
        return nil;
    }

    // ⑤ permissions：只用来推导层与判「声明了贡献点却没申请权限」。
    NSMutableArray<NSString *> *permissions = [NSMutableArray array];
    id permissionsValue = [dictionary objectForKey:@"permissions"];
    if (permissionsValue != nil) {
        if (!A2CIsArray(permissionsValue)) {
            A2CFail(error, A2PluginContributionErrorField, @"permissions",
                    @"permissions 必须是数组");
            return nil;
        }
        for (id item in (NSArray *)permissionsValue) {
            if (!A2CIsString(item)) {
                A2CFail(error, A2PluginContributionErrorField, @"permissions",
                        @"permissions 的每一项都必须是字符串");
                return nil;
            }
            [permissions addObject:(NSString *)item];
        }
    }
    A2PluginContributionLayer layer = A2PluginContributionLayerForPermissions(permissions);

    // ⑥ ui：slot / theme。**这两块是 P2 的全部界面表达力。**
    NSInteger uiPriority = 0;
    NSMutableArray<A2PluginSlotContribution *> *slots = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *themeTokens = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *diagnostics = [NSMutableArray array];

    id uiValue = [dictionary objectForKey:@"ui"];
    if (uiValue != nil) {
        if (!A2CIsDictionary(uiValue)) {
            A2CFail(error, A2PluginContributionErrorField, @"ui", @"ui 必须是对象");
            return nil;
        }
        NSDictionary *ui = (NSDictionary *)uiValue;

        // 贡献点白名单：ui 下只认 priority / slots / theme（v2）。
        // pages / overrides 是 v3 字段，P1 已经拒过 v2 包里的它们；这里再拦一次是为了
        // 「有人把 P1 的 v3 门放宽了」这种情况不会悄悄漏到本层。
        for (id key in ui) {
            if ([key isEqual:@"priority"] || [key isEqual:@"slots"] || [key isEqual:@"theme"]) continue;
            if ([key isEqual:@"pages"] || [key isEqual:@"overrides"]) {
                A2CFail(error, A2PluginContributionErrorContribUnknown, [NSString stringWithFormat:@"ui.%@", key],
                        @"ui.%@ 是 formatVersion 3 的页面/覆盖贡献点，本宿主阶段（P2）不支持",
                        key);
                return nil;
            }
            A2CFail(error, A2PluginContributionErrorContribUnknown,
                    [NSString stringWithFormat:@"ui.%@", key],
                    @"未知界面贡献点「ui.%@」：ui 下只允许 priority / slots / theme", key);
            return nil;
        }

        id uiPriorityValue = [ui objectForKey:@"priority"];
        if (uiPriorityValue != nil) {
            if (!A2CIsInteger(uiPriorityValue)) {
                A2CFail(error, A2PluginContributionErrorField, @"ui.priority",
                        @"ui.priority 必须是整数");
                return nil;
            }
            uiPriority = [(NSNumber *)uiPriorityValue integerValue];
            if (uiPriority < -1000 || uiPriority > 1000) {
                A2CFail(error, A2PluginContributionErrorField, @"ui.priority",
                        @"ui.priority 必须在 -1000～1000 之间（得到 %ld）", (long)uiPriority);
                return nil;
            }
        }

        // ⑥a slots
        id slotsValue = [ui objectForKey:@"slots"];
        if (slotsValue != nil) {
            if (!A2CIsArray(slotsValue)) {
                A2CFail(error, A2PluginContributionErrorField, @"ui.slots",
                        @"ui.slots 必须是数组");
                return nil;
            }
            NSArray *slotArray = (NSArray *)slotsValue;
            if (slotArray.count > 64) {
                A2CFail(error, A2PluginContributionErrorField, @"ui.slots",
                        @"ui.slots 最多 64 项（得到 %lu）", (unsigned long)slotArray.count);
                return nil;
            }
            NSUInteger index = 0;
            for (id rawItem in slotArray) {
                NSString *field = [NSString stringWithFormat:@"ui.slots[%lu]", (unsigned long)index];
                A2PluginSlotContribution *contribution = nil;
                if (![self parseSlotItem:rawItem
                                   field:field
                                pluginId:pluginId
                          pluginVersion:pluginVersion
                              uiPriority:uiPriority
                                   layer:layer
                        declarationIndex:index
                                 outItem:&contribution
                             diagnostics:diagnostics
                                   error:error]) {
                    return nil;
                }
                if (contribution != nil) {
                    // ── 去重规则（只有一处实现，注册表与校验共用同一判据）──
                    // ① 同 slot 同 id：内容逐字段相同 ⇒ 合并成一条（作者复制粘贴很常见，
                    //    重复渲染两个一样的按钮没有意义，也不要因为手滑就拒装）；
                    // ② 同 slot 同 id 但内容不同 ⇒ 拒装：宿主无法替作者选「哪一份才是他要的」；
                    // ③ 没有 id 的条目：只有**逐字段完全相同**才合并，否则照常并存
                    //    （同一 slot 放两个不同徽标是合法的，容量规则在渲染侧截断）。
                    A2PluginSlotContribution *existing = nil;
                    if (contribution.identifier != nil) {
                        for (A2PluginSlotContribution *previous in slots) {
                            if ([previous.slot isEqualToString:contribution.slot] &&
                                [previous.identifier isEqualToString:contribution.identifier]) {
                                existing = previous;
                                break;
                            }
                        }
                    } else {
                        for (A2PluginSlotContribution *previous in slots) {
                            if ([previous isIdenticalDeclaration:contribution]) {
                                existing = previous;
                                break;
                            }
                        }
                    }
                    if (existing != nil) {
                        if (![existing isIdenticalDeclaration:contribution]) {
                            A2CFail(error, A2PluginContributionErrorDuplicate, field,
                                    @"%@ 与 ui.slots[%lu] 用同一个 id「%@」声明了两份内容不同的贡献："
                                    @"同 slot 同 id 只能有一份，宿主无法替你选",
                                    field, (unsigned long)existing.declarationIndex,
                                    contribution.identifier);
                            return nil;
                        }
                        [diagnostics addObject:[NSString stringWithFormat:
                            @"%@ 与 ui.slots[%lu] 完全重复，已合并为一条",
                            field, (unsigned long)existing.declarationIndex]];
                    } else {
                        [slots addObject:contribution];
                    }
                }
                index++;
            }
        }

        // ⑥b theme.tokens
        id themeValue = [ui objectForKey:@"theme"];
        if (themeValue != nil) {
            if (!A2CIsDictionary(themeValue)) {
                A2CFail(error, A2PluginContributionErrorField, @"ui.theme",
                        @"ui.theme 必须是对象");
                return nil;
            }
            NSDictionary *theme = (NSDictionary *)themeValue;
            for (id key in theme) {
                if (![key isEqual:@"tokens"]) {
                    A2CFail(error, A2PluginContributionErrorContribUnknown,
                            [NSString stringWithFormat:@"ui.theme.%@", key],
                            @"未知主题贡献点「ui.theme.%@」：只允许 tokens", key);
                    return nil;
                }
            }
            id tokensValue = [theme objectForKey:@"tokens"];
            if (tokensValue != nil) {
                if (!A2CIsDictionary(tokensValue)) {
                    A2CFail(error, A2PluginContributionErrorField, @"ui.theme.tokens",
                            @"ui.theme.tokens 必须是对象");
                    return nil;
                }
                NSDictionary *tokens = (NSDictionary *)tokensValue;
                if (tokens.count == 0) {
                    A2CFail(error, A2PluginContributionErrorField, @"ui.theme.tokens",
                            @"ui.theme.tokens 至少要有一项（空对象等于什么都没声明）");
                    return nil;
                }
                if (tokens.count > 64) {
                    A2CFail(error, A2PluginContributionErrorField, @"ui.theme.tokens",
                            @"ui.theme.tokens 最多 64 项（得到 %lu）", (unsigned long)tokens.count);
                    return nil;
                }
                for (id tokenKey in tokens) {
                    if (!A2CIsString(tokenKey) ||
                        !A2CIsDottedLowerIdentifier((NSString *)tokenKey, NO, 64)) {
                        A2CFail(error, A2PluginContributionErrorField, @"ui.theme.tokens",
                                @"主题 token 名「%@」不合法：必须是小写点分标识（如 color.accent）",
                                tokenKey);
                        return nil;
                    }
                    id tokenValue = [tokens objectForKey:tokenKey];
                    if (!A2CIsString(tokenValue) || [(NSString *)tokenValue length] > 32) {
                        A2CFail(error, A2PluginContributionErrorField,
                                [NSString stringWithFormat:@"ui.theme.tokens.%@", tokenKey],
                                @"主题 token「%@」的值必须是长度 ≤32 的字符串", tokenKey);
                        return nil;
                    }
                    if (!A2PluginIsKnownThemeToken((NSString *)tokenKey)) {
                        // ADR-018 决策 5：未知 token 忽略 + 诊断，**不拒载**。
                        // 顺手给一个「是不是想写 …」 —— 最常见的错是把 MD3 角色原样搬过来
                        // （`color.surfacecontainerhigh`），光说「未知」作者得自己去猜写法。
                        NSString *suggestion = A2CSuggestThemeToken((NSString *)tokenKey);
                        if (suggestion != nil) {
                            [diagnostics addObject:[NSString stringWithFormat:
                                @"未知主题 token「%@」已忽略（是不是想写「%@」？）",
                                tokenKey, suggestion]];
                        } else {
                            [diagnostics addObject:[NSString stringWithFormat:
                                @"未知主题 token「%@」已忽略（宿主词表里没有它）", tokenKey]];
                        }
                        continue;
                    }
                    if (!A2CIsHexColor((NSString *)tokenValue)) {
                        A2CFail(error, A2PluginContributionErrorField,
                                [NSString stringWithFormat:@"ui.theme.tokens.%@", tokenKey],
                                @"主题 token「%@」的值「%@」不是 #RRGGBB 颜色",
                                tokenKey, tokenValue);
                        return nil;
                    }
                    [themeTokens setObject:(NSString *)tokenValue forKey:(NSString *)tokenKey];
                }
            }
        }
    }

    // ⑦ contributes：数据层贡献。P2 只认 versionDecorate；downloadSources / versionFilter 属 P4。
    A2PluginVersionDecoration *decoration = nil;
    id contributesValue = [dictionary objectForKey:@"contributes"];
    if (contributesValue != nil) {
        if (!A2CIsDictionary(contributesValue)) {
            A2CFail(error, A2PluginContributionErrorField, @"contributes",
                    @"contributes 必须是对象");
            return nil;
        }
        NSDictionary *contributes = (NSDictionary *)contributesValue;
        for (id key in contributes) {
            if ([key isEqual:@"versionDecorate"]) continue;
            if ([key isEqual:@"downloadSources"] || [key isEqual:@"versionFilter"]) {
                A2CFail(error, A2PluginContributionErrorContribUnknown,
                        [NSString stringWithFormat:@"contributes.%@", key],
                        @"contributes.%@ 属 P4 的数据层贡献点，本宿主阶段（P2）不支持", key);
                return nil;
            }
            A2CFail(error, A2PluginContributionErrorContribUnknown,
                    [NSString stringWithFormat:@"contributes.%@", key],
                    @"未知数据层贡献点「contributes.%@」：本阶段只允许 versionDecorate", key);
            return nil;
        }
        id decorateValue = [contributes objectForKey:@"versionDecorate"];
        if (decorateValue != nil) {
            if (!A2CIsDictionary(decorateValue)) {
                A2CFail(error, A2PluginContributionErrorField, @"contributes.versionDecorate",
                        @"contributes.versionDecorate 必须是对象");
                return nil;
            }
            if (![self parseVersionDecorate:(NSDictionary *)decorateValue
                                   pluginId:pluginId
                              pluginVersion:pluginVersion
                                     layer:layer
                                  priority:uiPriority
                                    outDec:&decoration
                                     error:error]) {
                return nil;
            }
        }
    }

    // ⑧ 声明了贡献点却没申请对应权限 ⇒ 作者的错误（宿主不会渲染没授权的贡献）。
    //    放在最后判：前面的字段错比权限错更基础，先报更具体的那条。
    if (![permissions containsObject:@"ui.contribute"]) {
        if (slots.count > 0) {
            A2CFail(error, A2PluginContributionErrorContribPermission, @"permissions",
                    @"ui.slots 声明了 %lu 条贡献，但没有申请 ui.contribute 权限："
                    @"宿主不会渲染未授权插件的界面贡献",
                    (unsigned long)slots.count);
            return nil;
        }
        if (themeTokens.count > 0) {
            A2CFail(error, A2PluginContributionErrorContribPermission, @"permissions",
                    @"ui.theme 覆盖了 %lu 个主题 token，但没有申请 ui.contribute 权限",
                    (unsigned long)themeTokens.count);
            return nil;
        }
    }
    if (decoration != nil && ![permissions containsObject:@"version.decorate"]) {
        A2CFail(error, A2PluginContributionErrorContribPermission, @"permissions",
                @"contributes.versionDecorate 声明了版本行装饰，但没有申请 version.decorate 权限");
        return nil;
    }

    A2PluginContributionSet *set = [[A2PluginContributionSet alloc] init];
    set.pluginId = pluginId;
    set.pluginVersion = pluginVersion;
    set.priority = uiPriority;
    set.layer = layer;
    set.slotContributions = [NSArray arrayWithArray:slots];
    set.themeTokens = [NSDictionary dictionaryWithDictionary:themeTokens];
    set.versionDecoration = decoration;
    set.diagnostics = [NSArray arrayWithArray:diagnostics];
    return set;
}

#pragma mark 单项解析

/// 解析并校验一条 `ui.slots[]`。去重规则在这里落地：
///  · 逐字段相同（同 slot、同 id、同组件、同优先级、同文案/动作）⇒ 合并，只留第一条；
///  · 同 `(slot, id)` 但内容不同 ⇒ `E_CONTRIB_DUPLICATE`（宿主无法替作者选一份）。
/// `settings.section` 额外要求 `id`：宿主拿它做开关值的持久化键，没键就没法存。
+ (BOOL)parseSlotItem:(id)rawItem
                field:(NSString *)field
             pluginId:(NSString *)pluginId
        pluginVersion:(NSString *)pluginVersion
            uiPriority:(NSInteger)uiPriority
                 layer:(A2PluginContributionLayer)layer
       declarationIndex:(NSUInteger)index
              outItem:(A2PluginSlotContribution **)outItem
          diagnostics:(NSMutableArray<NSString *> *)diagnostics
                error:(NSError **)error {
    if (!A2CIsDictionary(rawItem)) {
        A2CFail(error, A2PluginContributionErrorField, field, @"%@ 必须是对象", field);
        return NO;
    }
    NSDictionary *item = (NSDictionary *)rawItem;

    NSSet *allowedKeys = [NSSet setWithArray:@[
        @"slot", @"component", @"id", @"icon", @"label", @"action",
        @"binding", @"visibleWhen", @"enabledWhen", @"priority",
    ]];
    for (id key in item) {
        if (![key isKindOfClass:NSString.class] || ![allowedKeys containsObject:key]) {
            A2CFail(error, A2PluginContributionErrorField, field,
                    @"%@ 出现未知字段「%@」：允许 slot / component / id / icon / label / "
                    @"action / binding / visibleWhen / enabledWhen / priority",
                    field, key);
            return NO;
        }
    }

    id slotValue = [item objectForKey:@"slot"];
    if (!A2CIsString(slotValue)) {
        A2CFail(error, A2PluginContributionErrorField, [field stringByAppendingString:@".slot"],
                @"%@.slot 必填且必须是字符串", field);
        return NO;
    }
    NSString *slot = (NSString *)slotValue;
    if (!A2PluginIsKnownSlotName(slot)) {
        if ([A2CV3OnlySlots() containsObject:slot]) {
            A2CFail(error, A2PluginContributionErrorSlotUnknown,
                    [field stringByAppendingString:@".slot"],
                    @"%@.slot「%@」是 formatVersion 3 的页面 slot，v2 纯 JSON 插件不能用；"
                    @"要用整页请在 P3b 用 v3 包声明", field, slot);
            return NO;
        }
        A2CFail(error, A2PluginContributionErrorSlotUnknown,
                [field stringByAppendingString:@".slot"],
                @"%@.slot「%@」不在宿主词表里：只接受 home.toolbar.action / home.card.badge / "
                @"versions.list.badge / version.detail.header / settings.section / "
                @"home.section / launch.overlay", field, slot);
        return NO;
    }

    id componentValue = [item objectForKey:@"component"];
    if (!A2CIsString(componentValue)) {
        A2CFail(error, A2PluginContributionErrorField,
                [field stringByAppendingString:@".component"],
                @"%@.component 必填且必须是语义组件名", field);
        return NO;
    }
    NSString *component = (NSString *)componentValue;
    if (!A2PluginIsKnownComponentName(component)) {
        A2CFail(error, A2PluginContributionErrorComponentUnknown,
                [field stringByAppendingString:@".component"],
                @"%@.component「%@」不是 v2 的语义组件：只接受 text.label / text.caption / "
                @"button.primary / button.secondary / switch.toggle / list.row / badge.status / "
                @"icon.glyph / divider / spacer（容器与 v3 组件属页面模型）", field, component);
        return NO;
    }

    NSString *identifier = nil;
    id idValue = [item objectForKey:@"id"];
    if (idValue != nil) {
        if (!A2CIsString(idValue) || !A2CIsEntryIdentifier((NSString *)idValue)) {
            A2CFail(error, A2PluginContributionErrorField, [field stringByAppendingString:@".id"],
                    @"%@.id 必须是小写字母开头、只含 a-z 0-9 . _ - 的 1～64 字符串", field);
            return NO;
        }
        identifier = (NSString *)idValue;
    }
    if ([slot isEqualToString:@"settings.section"] && identifier == nil) {
        A2CFail(error, A2PluginContributionErrorField,
                [field stringByAppendingString:@".id"],
                @"%@ 放进 settings.section 时必须写 id：宿主用它做开关值的持久化键，"
                @"没键就没法记住用户的选择", field);
        return NO;
    }

    NSString *icon = nil;
    id iconValue = [item objectForKey:@"icon"];
    if (iconValue != nil) {
        if (!A2CIsString(iconValue) || !A2CIsDottedLowerIdentifier((NSString *)iconValue, YES, 64)) {
            A2CFail(error, A2PluginContributionErrorField, [field stringByAppendingString:@".icon"],
                    @"%@.icon 必须是语义图标 ID（如 action.download），不是图片路径", field);
            return NO;
        }
        icon = (NSString *)iconValue;
    }

    NSString *labelI18n = nil;
    NSString *labelText = nil;
    id labelValue = [item objectForKey:@"label"];
    if (labelValue != nil) {
        if (![self parseLocalizedText:labelValue
                                field:[field stringByAppendingString:@".label"]
                              outI18n:&labelI18n
                              outText:&labelText
                                error:error]) {
            return NO;
        }
    }

    NSString *actionId = nil;
    id actionValue = [item objectForKey:@"action"];
    if (actionValue != nil) {
        if (![self parseAction:actionValue
                         field:[field stringByAppendingString:@".action"]
                       outId:&actionId
                         error:error]) {
            return NO;
        }
    }

    id bindingValue = [item objectForKey:@"binding"];
    if (bindingValue != nil) {
        if (!A2CIsString(bindingValue) || !A2CIsBindingPath((NSString *)bindingValue)) {
            A2CFail(error, A2PluginContributionErrorField,
                    [field stringByAppendingString:@".binding"],
                    @"%@.binding 必须是 state.* 或 item.* 的只读绑定路径", field);
            return NO;
        }
    }
    for (NSString *conditionKey in @[@"visibleWhen", @"enabledWhen"]) {
        id conditionValue = [item objectForKey:conditionKey];
        if (conditionValue == nil) continue;
        // 只做**形状**校验：单条比较（binding + 一个算子）。条件求值属 P3b 页面模型；
        // 纯 JSON 插件的绑定恒为空值，条件永远按「不满足」处理。
        BOOL shaped = NO;
        if (A2CIsDictionary(conditionValue)) {
            NSDictionary *condition = (NSDictionary *)conditionValue;
            shaped = A2CIsString([condition objectForKey:@"binding"]) &&
                     ([condition objectForKey:@"equals"] != nil ||
                      [condition objectForKey:@"notEquals"] != nil ||
                      [condition objectForKey:@"in"] != nil ||
                      [condition objectForKey:@"exists"] != nil);
        }
        if (!shaped) {
            A2CFail(error, A2PluginContributionErrorField,
                    [NSString stringWithFormat:@"%@.%@", field, conditionKey],
                    @"%@.%@ 必须是带 binding 的单条比较对象（binding + equals/notEquals/in/exists 之一）",
                    field, conditionKey);
            return NO;
        }
    }

    NSInteger priority = 0;   // schema 的默认值；不跟随 ui.priority（那是插件级排序键）
    id priorityValue = [item objectForKey:@"priority"];
    if (priorityValue != nil) {
        if (!A2CIsInteger(priorityValue)) {
            A2CFail(error, A2PluginContributionErrorField,
                    [field stringByAppendingString:@".priority"],
                    @"%@.priority 必须是整数", field);
            return NO;
        }
        priority = [(NSNumber *)priorityValue integerValue];
        if (priority < -1000 || priority > 1000) {
            A2CFail(error, A2PluginContributionErrorField,
                    [field stringByAppendingString:@".priority"],
                    @"%@.priority 必须在 -1000～1000 之间（得到 %ld）", field, (long)priority);
            return NO;
        }
    }

    A2PluginSlotContribution *contribution = [[A2PluginSlotContribution alloc] init];
    contribution.pluginId = pluginId;
    contribution.pluginVersion = pluginVersion;
    contribution.slot = slot;
    contribution.component = component;
    contribution.identifier = identifier;
    contribution.icon = icon;
    contribution.labelI18n = labelI18n;
    contribution.labelText = labelText;
    contribution.actionId = actionId;
    contribution.priority = priority;
    contribution.pluginPriority = uiPriority;
    contribution.layer = layer;
    contribution.declarationIndex = index;

    *outItem = contribution;
    return YES;
}

/// `label`：`{i18n: key}` 或 `{text: 字面量}`，二选一（`plugin.schema.json` 的 `localizedText`）。
+ (BOOL)parseLocalizedText:(id)value
                     field:(NSString *)field
                   outI18n:(NSString **)outI18n
                   outText:(NSString **)outText
                     error:(NSError **)error {
    if (!A2CIsDictionary(value)) {
        A2CFail(error, A2PluginContributionErrorField, field,
                @"%@ 必须是对象：{i18n: \"key\"} 或 {text: \"字面量\"}", field);
        return NO;
    }
    NSDictionary *text = (NSDictionary *)value;
    BOOL hasI18n = [text objectForKey:@"i18n"] != nil;
    BOOL hasText = [text objectForKey:@"text"] != nil;
    if (hasI18n == hasText) {
        A2CFail(error, A2PluginContributionErrorField, field,
                @"%@ 的 i18n 与 text 必须二选一（现在%@）",
                field, (hasI18n && hasText) ? @"两个都写了" : @"一个都没写");
        return NO;
    }
    for (id key in text) {
        if (![key isEqual:@"i18n"] && ![key isEqual:@"text"]) {
            A2CFail(error, A2PluginContributionErrorField, field,
                    @"%@ 出现未知字段「%@」：只允许 i18n / text", field, key);
            return NO;
        }
    }
    if (hasI18n) {
        id i18nValue = [text objectForKey:@"i18n"];
        if (!A2CIsString(i18nValue) || [(NSString *)i18nValue length] == 0 ||
            [(NSString *)i18nValue length] > 128) {
            A2CFail(error, A2PluginContributionErrorField, [field stringByAppendingString:@".i18n"],
                    @"%@.i18n 必须是 1～128 字符的本地化键", field);
            return NO;
        }
        *outI18n = (NSString *)i18nValue;
        return YES;
    }
    id textValue = [text objectForKey:@"text"];
    if (!A2CIsString(textValue) || [(NSString *)textValue length] == 0 ||
        [(NSString *)textValue length] > 256) {
        A2CFail(error, A2PluginContributionErrorField, [field stringByAppendingString:@".text"],
                @"%@.text 必须是 1～256 字符的字面量", field);
        return NO;
    }
    *outText = (NSString *)textValue;
    return YES;
}

/// `action`：字符串（等价 `{id}`）或 `{id, payload}`，payload 只允许标量。
+ (BOOL)parseAction:(id)value
              field:(NSString *)field
              outId:(NSString **)outId
              error:(NSError **)error {
    if (A2CIsString(value)) {
        if (!A2CIsEntryIdentifier((NSString *)value)) {
            A2CFail(error, A2PluginContributionErrorField, field,
                    @"%@ 的动作 id「%@」不合法（小写字母开头，只含 a-z 0-9 . _ -）", field, value);
            return NO;
        }
        *outId = (NSString *)value;
        return YES;
    }
    if (!A2CIsDictionary(value)) {
        A2CFail(error, A2PluginContributionErrorField, field,
                @"%@ 必须是动作 id 字符串或 {id, payload} 对象", field);
        return NO;
    }
    NSDictionary *action = (NSDictionary *)value;
    for (id key in action) {
        if (![key isEqual:@"id"] && ![key isEqual:@"payload"]) {
            A2CFail(error, A2PluginContributionErrorField, field,
                    @"%@ 出现未知字段「%@」：只允许 id / payload", field, key);
            return NO;
        }
    }
    id actionId = [action objectForKey:@"id"];
    if (!A2CIsString(actionId) || !A2CIsEntryIdentifier((NSString *)actionId)) {
        A2CFail(error, A2PluginContributionErrorField, [field stringByAppendingString:@".id"],
                @"%@.id 必填且必须是合法动作 id", field);
        return NO;
    }
    id payload = [action objectForKey:@"payload"];
    if (payload != nil) {
        if (!A2CIsDictionary(payload)) {
            A2CFail(error, A2PluginContributionErrorField, [field stringByAppendingString:@".payload"],
                    @"%@.payload 必须是对象", field);
            return NO;
        }
        NSDictionary *payloadDict = (NSDictionary *)payload;
        if (payloadDict.count > 16) {
            A2CFail(error, A2PluginContributionErrorField, [field stringByAppendingString:@".payload"],
                    @"%@.payload 最多 16 个键", field);
            return NO;
        }
        for (id payloadKey in payloadDict) {
            if (!A2CIsScalar([payloadDict objectForKey:payloadKey])) {
                A2CFail(error, A2PluginContributionErrorField,
                        [NSString stringWithFormat:@"%@.payload.%@", field, payloadKey],
                        @"%@.payload 的「%@」只能是字符串 / 数字 / 布尔 / null", field, payloadKey);
                return NO;
            }
        }
    }
    *outId = (NSString *)actionId;
    return YES;
}

/// `contributes.versionDecorate`：`PLUGIN-AUTHORING.md` 3.5 的四个字段，至少给一项。
+ (BOOL)parseVersionDecorate:(NSDictionary *)value
                    pluginId:(NSString *)pluginId
               pluginVersion:(NSString *)pluginVersion
                       layer:(A2PluginContributionLayer)layer
                    priority:(NSInteger)priority
                      outDec:(A2PluginVersionDecoration **)outDecoration
                       error:(NSError **)error {
    NSSet *allowed = [NSSet setWithArray:@[
        @"titleTemplate", @"subtitleTemplate", @"badge", @"icon",
    ]];
    for (id key in value) {
        if (![key isKindOfClass:NSString.class] || ![allowed containsObject:key]) {
            A2CFail(error, A2PluginContributionErrorField, @"contributes.versionDecorate",
                    @"contributes.versionDecorate 出现未知字段「%@」：只允许 "
                    @"titleTemplate / subtitleTemplate / badge / icon", key);
            return NO;
        }
    }
    if (value.count == 0) {
        A2CFail(error, A2PluginContributionErrorField, @"contributes.versionDecorate",
                @"contributes.versionDecorate 至少要给一项（titleTemplate / subtitleTemplate / "
                @"badge / icon），空对象等于什么都没装饰");
        return NO;
    }

    A2PluginVersionDecoration *decoration = [[A2PluginVersionDecoration alloc] init];
    decoration.pluginId = pluginId;
    decoration.pluginVersion = pluginVersion;
    decoration.layer = layer;
    decoration.priority = priority;

    for (NSString *templateKey in @[@"titleTemplate", @"subtitleTemplate"]) {
        id templateValue = [value objectForKey:templateKey];
        if (templateValue == nil) continue;
        if (!A2CIsString(templateValue) || [(NSString *)templateValue length] > 64) {
            A2CFail(error, A2PluginContributionErrorField,
                    [NSString stringWithFormat:@"contributes.versionDecorate.%@", templateKey],
                    @"contributes.versionDecorate.%@ 必须是长度 ≤64 的字符串", templateKey);
            return NO;
        }
        if ([templateKey isEqualToString:@"titleTemplate"]) {
            decoration.titleTemplate = (NSString *)templateValue;
        } else {
            decoration.subtitleTemplate = (NSString *)templateValue;
        }
    }

    id badgeValue = [value objectForKey:@"badge"];
    if (badgeValue != nil) {
        NSString *i18n = nil;
        NSString *text = nil;
        if (![self parseLocalizedText:badgeValue
                                field:@"contributes.versionDecorate.badge"
                              outI18n:&i18n
                              outText:&text
                                error:error]) {
            return NO;
        }
        decoration.badgeI18n = i18n;
        decoration.badgeText = text;
    }

    id iconValue = [value objectForKey:@"icon"];
    if (iconValue != nil) {
        if (!A2CIsString(iconValue) ||
            !A2CIsDottedLowerIdentifier((NSString *)iconValue, YES, 64)) {
            A2CFail(error, A2PluginContributionErrorField,
                    @"contributes.versionDecorate.icon",
                    @"contributes.versionDecorate.icon 必须是语义图标 ID（如 action.badge）");
            return NO;
        }
        decoration.icon = (NSString *)iconValue;
    }

    *outDecoration = decoration;
    return YES;
}

#pragma mark 查询

- (NSArray<A2PluginSlotContribution *> *)contributionsForSlot:(NSString *)slot {
    if (![slot isKindOfClass:NSString.class]) return @[];
    NSMutableArray<A2PluginSlotContribution *> *result = [NSMutableArray array];
    for (A2PluginSlotContribution *item in self.slotContributions) {
        if ([item.slot isEqualToString:slot]) [result addObject:item];
    }
    return result;
}

- (NSArray<A2PluginSlotContribution *> *)settingsItems {
    return [self contributionsForSlot:@"settings.section"];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ v%@ layer=%@ priority=%ld slots=%lu tokens=%lu>",
            NSStringFromClass(self.class), self.pluginId, self.pluginVersion,
            A2PluginContributionLayerName(self.layer), (long)self.priority,
            (unsigned long)self.slotContributions.count,
            (unsigned long)self.themeTokens.count];
}

@end

#pragma mark - 注册表

//  【线程】谁在碰注册表：`A2PluginInstaller` 的安装明确要求非主线程（要等 10 次确认），
//  而七处宿主插入点全在主线程读。这里用**一条串行队列**当唯一闸门：
//    · 写（apply / remove）在队列上串行执行；
//    · 读在队列上**只 copy 一份字典快照**，排序与拼装回到调用线程做
//      —— 快照里的 value 是不可变的 `A2PluginContributionSet`，读到的内容不会变一半。
//
//  为什么不「在装配处统一串行化」：宿主插入点有七处，将来任何一处换成后台线程调用、
//  只要忘了排队就会静默丢同步（症状是「偶发少一条徽标」而不是崩溃，最难查）。
//  把约束放进注册表本身，任何调用方都不需要知道这件事。
//
//  队列内只做内存操作：不回调、不写日志、不碰 UI —— 持锁期间被外部重入的可能性为零。
static const void *kA2ContributionQueueKey = &kA2ContributionQueueKey;

@interface A2PluginContributionRegistry ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, A2PluginContributionSet *> *sets;
@end

@implementation A2PluginContributionRegistry {
    /// 注册表内部串行队列（见本节顶部【线程】）。
    dispatch_queue_t _queue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sets = [NSMutableDictionary dictionary];
        _queue = dispatch_queue_create("top.air-devs.air2.plugin.contributions",
                                       DISPATCH_QUEUE_SERIAL);
        // 队列身份挂在 specific 上：公开方法之间会互相调用（`stateSnapshot` 里会调
        // `slotEntriesForSlot:`），没有这条判据就会 dispatch_sync 到自己那条队列 ⇒ 自锁死。
        dispatch_queue_set_specific(_queue, kA2ContributionQueueKey, (__bridge void *)self, NULL);
    }
    return self;
}

#pragma mark 队列

/// 在注册表队列上执行；**已经在队列上**时直接执行（重入安全，见 init）。
- (void)a2_syncOnQueue:(dispatch_block_t)block {
    if (dispatch_get_specific(kA2ContributionQueueKey) == (__bridge void *)self) {
        block();
        return;
    }
    dispatch_sync(_queue, block);
}

/// 读路径的唯一入口：队列上 copy 一份字典，之后在调用线程上算。
- (NSDictionary<NSString *, A2PluginContributionSet *> *)a2_setsSnapshot {
    __block NSDictionary<NSString *, A2PluginContributionSet *> *snapshot = nil;
    [self a2_syncOnQueue:^{
        snapshot = [self.sets copy];
    }];
    return snapshot ?: @{};
}

/// 在册插件按 pluginId 字典序 —— 排序键的最后一级，也是「每次启动顺序一致」的兜底。
/// 入参是快照：读路径一律在队列外计算，队列只负责给出一致的一份状态。
- (NSArray<A2PluginContributionSet *> *)a2_sortedSetsIn:
        (NSDictionary<NSString *, A2PluginContributionSet *> *)sets {
    NSMutableArray<A2PluginContributionSet *> *result = [NSMutableArray array];
    NSArray<NSString *> *ids = [[sets allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *pluginId in ids) {
        A2PluginContributionSet *set = [sets objectForKey:pluginId];
        if (set) [result addObject:set];
    }
    return result;
}

#pragma mark 接入 / 摘除

- (BOOL)applyContributionSet:(A2PluginContributionSet *)set error:(NSError **)error {
    if (![set isKindOfClass:A2PluginContributionSet.class]) {
        A2CFail(error, A2PluginContributionErrorField, nil,
                @"applyContributionSet: 收到 nil 或非贡献集对象");
        return NO;
    }

    __block BOOL applied = YES;
    __block NSError *conflict = nil;
    [self a2_syncOnQueue:^{
        // 独占占位检查：设置项以 id 为宿主持久化键 ⇒ 两个插件用同一个键就是真冲突
        // （不是「谁优先」能解决的问题：写进去以后分不清是谁的值）。
        // P2 词表里另一个独占面（`versions.list.page` 整页替换）属 v3，暂不存在。
        NSArray<A2PluginSlotContribution *> *incoming = [set settingsItems];
        if (incoming.count > 0) {
            for (NSString *otherId in self.sets) {
                if ([otherId isEqualToString:set.pluginId]) continue;
                A2PluginContributionSet *other = [self.sets objectForKey:otherId];
                NSArray<A2PluginSlotContribution *> *existing = [other settingsItems];
                for (A2PluginSlotContribution *newItem in incoming) {
                    for (A2PluginSlotContribution *oldItem in existing) {
                        if (![newItem.identifier isEqualToString:oldItem.identifier]) continue;
                        // 先检查后写入：冲突时一个字节都不改。
                        // 注意用块内局部变量接 A2CFail 的输出：`__block` 变量的地址不能直接
                        // 传给 `NSError **`（ARC 下会报 non-local object / autoreleasing 不匹配）。
                        NSError *innerError = nil;
                        A2CFail(&innerError, A2PluginContributionErrorSlotConflict,
                                [NSString stringWithFormat:@"ui.slots.%@", newItem.identifier],
                                @"设置项键「%@」已被插件 %@ 占用：settings.section 的 id 是宿主侧唯一键，"
                                @"两个插件用同一个键会让用户的选择互相覆盖",
                                newItem.identifier, otherId);
                        conflict = innerError;
                        applied = NO;
                        return;
                    }
                }
            }
        }

        // 幂等替换：同一插件重复接入（启用/禁用来回切、版本回退）不叠加，只覆盖。
        [self.sets setObject:set forKey:set.pluginId];
    }];

    if (!applied) {
        if (error) *error = conflict;
        return NO;
    }
    return YES;
}

- (BOOL)removeContributionsForPlugin:(NSString *)pluginId {
    if (![pluginId isKindOfClass:NSString.class] || pluginId.length == 0) return NO;

    __block BOOL removed = NO;
    [self a2_syncOnQueue:^{
        if ([self.sets objectForKey:pluginId] == nil) return;   // 幂等：没接入就不动
        [self.sets removeObjectForKey:pluginId];
        removed = YES;
    }];
    return removed;
}

- (BOOL)isPluginAttached:(NSString *)pluginId {
    if (![pluginId isKindOfClass:NSString.class]) return NO;

    __block BOOL attached = NO;
    [self a2_syncOnQueue:^{
        attached = ([self.sets objectForKey:pluginId] != nil);
    }];
    return attached;
}

- (NSUInteger)contributionCountForPlugin:(NSString *)pluginId {
    if (![pluginId isKindOfClass:NSString.class]) return 0;

    __block NSUInteger count = 0;
    [self a2_syncOnQueue:^{
        A2PluginContributionSet *set = [self.sets objectForKey:pluginId];
        if (!set) return;
        // 设置项本来就是 slot 条目（ADR-023），不重复计数。
        count = set.slotContributions.count + set.themeTokens.count
            + (set.versionDecoration ? 1 : 0);
    }];
    return count;
}

- (NSArray<NSString *> *)attachedPluginIds {
    return [[[self a2_setsSnapshot] allKeys] sortedArrayUsingSelector:@selector(compare:)];
}

#pragma mark 查询

- (NSArray<A2PluginSlotContribution *> *)slotEntriesForSlot:(NSString *)slot {
    if (![slot isKindOfClass:NSString.class] || slot.length == 0) return @[];

    NSMutableArray<A2PluginSlotContribution *> *result = [NSMutableArray array];
    for (A2PluginContributionSet *set in [self a2_sortedSetsIn:[self a2_setsSnapshot]]) {
        [result addObjectsFromArray:[set contributionsForSlot:slot]];
    }
    return [result sortedArrayUsingFunction:A2CCompareContributions context:NULL];
}

- (NSArray<A2PluginSlotContribution *> *)effectiveEntriesForSlot:(NSString *)slot {
    NSArray<A2PluginSlotContribution *> *all = [self slotEntriesForSlot:slot];
    NSUInteger capacity = A2PluginSlotCapacity(slot);
    if (capacity == 0 || all.count <= capacity) return all;
    // 超容不是错误：按排序键取前 N 个，被挤掉的只记一条诊断（宿主侧事实，不是插件错误）。
    return [all subarrayWithRange:NSMakeRange(0, capacity)];
}

- (NSArray<A2PluginSlotContribution *> *)settingsItems {
    NSMutableArray<A2PluginSlotContribution *> *result = [NSMutableArray array];
    for (A2PluginContributionSet *set in [self a2_sortedSetsIn:[self a2_setsSnapshot]]) {
        [result addObjectsFromArray:[set settingsItems]];
    }
    // 插件内保持声明顺序（priority 相同时 declarationIndex 决定），跨插件按排序键。
    return [result sortedArrayUsingFunction:A2CCompareContributions context:NULL];
}

- (nullable NSString *)themeTokenValue:(NSString *)token ownerPluginId:(NSString **)owner {
    if (![token isKindOfClass:NSString.class]) return nil;
    // 排序键最靠前的插件胜出：同一 token 被多个插件覆盖时，结果必须可复现。
    for (A2PluginContributionSet *set in [self a2_sortedSetsIn:[self a2_setsSnapshot]]) {
        NSString *value = [set.themeTokens objectForKey:token];
        if (value == nil) continue;
        if (owner) *owner = set.pluginId;
        return value;
    }
    if (owner) *owner = nil;
    return nil;
}

- (NSDictionary<NSString *, NSString *> *)themeTokensForPlugin:(NSString *)pluginId {
    if (![pluginId isKindOfClass:NSString.class] || pluginId.length == 0) return @{};

    __block NSDictionary<NSString *, NSString *> *tokens = nil;
    [self a2_syncOnQueue:^{
        A2PluginContributionSet *set = [self.sets objectForKey:pluginId];
        tokens = [set.themeTokens copy];      // 贡献集不可变，copy 只是给调用方一份稳定的快照
    }];
    return tokens ?: @{};
}

- (NSDictionary<NSString *, NSString *> *)resolvedThemeTokens {
    NSArray<A2PluginContributionSet *> *sets = [self a2_sortedSetsIn:[self a2_setsSnapshot]];
    NSMutableDictionary<NSString *, NSString *> *resolved = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *tokens = [NSMutableSet set];
    for (A2PluginContributionSet *set in sets) {
        [tokens addObjectsFromArray:[set.themeTokens allKeys]];
    }
    for (NSString *token in tokens) {
        for (A2PluginContributionSet *set in sets) {      // 与 themeTokenValue: 同一口径，不另写一遍
            NSString *value = [set.themeTokens objectForKey:token];
            if (value == nil) continue;
            [resolved setObject:value forKey:token];
            break;
        }
    }
    return [NSDictionary dictionaryWithDictionary:resolved];
}

- (NSArray<A2PluginVersionDecoration *> *)versionDecorations {
    NSMutableArray<A2PluginVersionDecoration *> *result = [NSMutableArray array];
    for (A2PluginContributionSet *set in [self a2_sortedSetsIn:[self a2_setsSnapshot]]) {
        if (set.versionDecoration != nil) [result addObject:set.versionDecoration];
    }
    return [result sortedArrayUsingFunction:A2CCompareDecorations context:NULL];
}

- (NSArray<NSString *> *)diagnostics {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (A2PluginContributionSet *set in [self a2_sortedSetsIn:[self a2_setsSnapshot]]) {
        for (NSString *line in set.diagnostics) {
            [result addObject:[NSString stringWithFormat:@"%@: %@", set.pluginId, line]];
        }
    }
    return result;
}

- (NSDictionary<NSString *, id> *)stateSnapshot {
    // 快照是「移除后回到接入前」的判据：比的是内容，不是个数。
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, A2PluginContributionSet *> *sets = [self a2_setsSnapshot];
    [snapshot setObject:[[sets allKeys] sortedArrayUsingSelector:@selector(compare:)]
                 forKey:@"plugins"];

    NSMutableDictionary<NSString *, NSArray<NSString *> *> *slots =
        [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *slotNames = [NSMutableSet set];
    for (A2PluginContributionSet *set in [self a2_sortedSetsIn:sets]) {
        for (A2PluginSlotContribution *item in set.slotContributions) {
            [slotNames addObject:item.slot];
        }
    }
    for (NSString *slot in slotNames) {
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (A2PluginSlotContribution *item in [self slotEntriesForSlot:slot]) {
            [lines addObject:[NSString stringWithFormat:@"%@/%@#%lu/%@/%ld",
                              item.pluginId, item.slot, (unsigned long)item.declarationIndex,
                              item.component, (long)item.priority]];
        }
        [slots setObject:lines forKey:slot];
    }
    [snapshot setObject:slots forKey:@"slots"];

    NSMutableDictionary<NSString *, NSString *> *theme = [NSMutableDictionary dictionary];
    for (NSString *token in [[self resolvedThemeTokens] allKeys]) {
        NSString *owner = nil;
        NSString *value = [self themeTokenValue:token ownerPluginId:&owner];
        [theme setObject:[NSString stringWithFormat:@"%@=%@", owner ?: @"?", value ?: @""]
                  forKey:token];
    }
    [snapshot setObject:theme forKey:@"theme"];

    NSMutableArray<NSString *> *decorations = [NSMutableArray array];
    for (A2PluginVersionDecoration *decoration in [self versionDecorations]) {
        [decorations addObject:[NSString stringWithFormat:@"%@@%@",
                                decoration.pluginId, decoration.pluginVersion]];
    }
    [snapshot setObject:decorations forKey:@"versionDecorations"];

    NSMutableArray<NSString *> *settingsKeys = [NSMutableArray array];
    for (A2PluginSlotContribution *item in [self settingsItems]) {
        [settingsKeys addObject:[NSString stringWithFormat:@"%@/%@", item.pluginId, item.identifier]];
    }
    [snapshot setObject:settingsKeys forKey:@"settingsKeys"];

    return [NSDictionary dictionaryWithDictionary:snapshot];
}

- (NSString *)description {
    NSDictionary<NSString *, A2PluginContributionSet *> *sets = [self a2_setsSnapshot];
    return [NSString stringWithFormat:@"<%@ plugins=%lu slots=%lu tokens=%lu>",
            NSStringFromClass(self.class), (unsigned long)sets.count,
            (unsigned long)[self slotEntriesForSlot:@"home.toolbar.action"].count,
            (unsigned long)[[self resolvedThemeTokens] count]];
}

@end
