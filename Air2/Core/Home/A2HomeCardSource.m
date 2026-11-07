//
//  A2HomeCardSource.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  卡片来源解析的实现。设计与边界见 A2HomeCardSource.h 顶部。
//
//  实现上只有两条纪律：
//   ① **不改入参**：卡片、快照都只读；不可用只是「如实回答」，不是「动手清理」。
//   ② **判定顺序固定**：未安装 → 已停用 → 贡献对不上 → 命中。
//      顺序换了会出现「卸载了但还显示停用」这种自相矛盾的诊断，测试已钉住。
//

#import "A2HomeCardSource.h"

#pragma mark - 原因名

NSString *A2HomePluginCardAvailabilityName(A2HomePluginCardAvailability availability) {
    switch (availability) {
        case A2HomePluginCardAvailabilityAvailable:           return @"available";
        case A2HomePluginCardAvailabilityPluginDisabled:      return @"disabled";
        case A2HomePluginCardAvailabilityPluginMissing:       return @"missing";
        case A2HomePluginCardAvailabilityContributionMissing: return @"contribution";
    }
    return @"unknown";
}

#pragma mark - 本地工具

/// 去重保序，并丢掉空白 / 非字符串项。
/// 注意**不裁剪** id 本身：插件 id 是契约值，悄悄改写它只会让「明明装了却查不到」更难查。
static NSArray<NSString *> *A2UniqueIdentifierStrings(NSArray<NSString *> *input) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in input) {
        if (![item isKindOfClass:[NSString class]]) { continue; }
        NSString *value = (NSString *)item;
        NSString *trimmed = [value stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0 || [seen containsObject:value]) { continue; }
        [seen addObject:value];
        [out addObject:value];
    }
    return out.copy;
}

/// 存卡时快照下来的名字（`A2HomeCardTarget.fallbackLabel`）；没有就是 nil。
/// 这就是「实体没了卡片还知道自己本来是什么」的唯一依据（设计 §2.4.1 / §4.5）。
static NSString *_Nullable A2CardFallbackLabel(A2HomeCard *_Nullable card) {
    NSString *label = card.target.fallbackLabel;
    if (label.length == 0) { return nil; }
    return label;
}

#pragma mark - A2HomePluginCardContent

@interface A2HomePluginCardContent ()
@property (nonatomic, copy) NSString *pluginId;
@property (nonatomic, copy, nullable) NSString *pluginVersion;
@property (nonatomic, copy) NSString *contributionId;
@property (nonatomic, copy, nullable) NSString *slot;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, copy, nullable) NSString *symbolName;
@end

@implementation A2HomePluginCardContent

+ (instancetype)contentWithPluginId:(NSString *)pluginId
                      pluginVersion:(NSString *)pluginVersion
                     contributionId:(NSString *)contributionId
                               slot:(NSString *)slot
                              title:(NSString *)title
                           subtitle:(NSString *)subtitle
                         symbolName:(NSString *)symbolName {
    A2HomePluginCardContent *content = [[self alloc] init];
    content.pluginId = pluginId;
    content.pluginVersion = pluginVersion;
    content.contributionId = contributionId;
    content.slot = slot;
    content.title = title;
    content.subtitle = subtitle;
    content.symbolName = symbolName;
    return content;
}

@end

#pragma mark - A2HomePluginCardCatalog

@interface A2HomePluginCardCatalog ()
@property (nonatomic, copy) NSArray<NSString *> *installedPluginIds;
@property (nonatomic, copy) NSArray<NSString *> *disabledPluginIds;
@property (nonatomic, copy) NSArray<A2HomePluginCardContent *> *contents;
/// pluginId → (contributionId → content)。查表用，构造时一次建好。
@property (nonatomic, copy) NSDictionary<NSString *, NSDictionary<NSString *, A2HomePluginCardContent *> *> *contentsByPlugin;
/// 上面两个数组的集合形式（`containsObject:` 是线性的，插件多起来没必要每次扫）。
@property (nonatomic, copy) NSSet<NSString *> *installedSet;
@property (nonatomic, copy) NSSet<NSString *> *disabledSet;
@end

@implementation A2HomePluginCardCatalog

+ (instancetype)catalogWithInstalledPluginIds:(NSArray<NSString *> *)installedPluginIds
                            disabledPluginIds:(NSArray<NSString *> *)disabledPluginIds
                                     contents:(NSArray<A2HomePluginCardContent *> *)contents {
    A2HomePluginCardCatalog *catalog = [[self alloc] init];
    catalog.installedPluginIds = A2UniqueIdentifierStrings(installedPluginIds ?: @[]);
    catalog.disabledPluginIds = A2UniqueIdentifierStrings(disabledPluginIds ?: @[]);
    catalog.installedSet = [NSSet setWithArray:catalog.installedPluginIds];
    catalog.disabledSet = [NSSet setWithArray:catalog.disabledPluginIds];

    NSMutableArray<A2HomePluginCardContent *> *kept = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, A2HomePluginCardContent *> *> *byPlugin =
        [NSMutableDictionary dictionary];
    for (id item in contents) {
        if (![item isKindOfClass:[A2HomePluginCardContent class]]) { continue; }
        A2HomePluginCardContent *content = (A2HomePluginCardContent *)item;
        // 查不到的条目（缺 pluginId / contributionId）留着只会被误命中，直接丢。
        if (content.pluginId.length == 0 || content.contributionId.length == 0) { continue; }
        NSMutableDictionary<NSString *, A2HomePluginCardContent *> *perPlugin = byPlugin[content.pluginId];
        if (perPlugin == nil) {
            perPlugin = [NSMutableDictionary dictionary];
            byPlugin[content.pluginId] = perPlugin;
        }
        if (perPlugin[content.contributionId] != nil) { continue; }  // 先声明者优先
        perPlugin[content.contributionId] = content;
        [kept addObject:content];
    }
    catalog.contents = kept.copy;
    catalog.contentsByPlugin = byPlugin.copy;
    return catalog;
}

- (A2HomePluginCardAvailability)availabilityForPluginId:(NSString *)pluginId
                                        contributionId:(NSString *)contributionId
                                               content:(A2HomePluginCardContent **)outContent {
    if (pluginId.length == 0 || contributionId.length == 0) {
        return A2HomePluginCardAvailabilityContributionMissing;
    }
    // ① 未安装优先于「已停用」：卸载之后那个停用标记只是残留，按卸载说才对。
    if (![self.installedSet containsObject:pluginId]) {
        return A2HomePluginCardAvailabilityPluginMissing;
    }
    if ([self.disabledSet containsObject:pluginId]) {
        return A2HomePluginCardAvailabilityPluginDisabled;
    }
    A2HomePluginCardContent *content = self.contentsByPlugin[pluginId][contributionId];
    if (content == nil) {
        return A2HomePluginCardAvailabilityContributionMissing;
    }
    if (outContent) { *outContent = content; }
    return A2HomePluginCardAvailabilityAvailable;
}

@end

#pragma mark - A2HomeCardSource

@interface A2HomeCardSource ()
@property (nonatomic, copy, nullable) NSString *cardID;
@property (nonatomic, assign) A2HomeCardSourceState state;
@property (nonatomic, assign) A2HomeCardKind kind;
@property (nonatomic, copy, nullable) NSString *pluginId;
@property (nonatomic, copy, nullable) NSString *pluginVersion;
@property (nonatomic, copy, nullable) NSString *contributionId;
@property (nonatomic, copy, nullable) NSString *slot;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic, copy, nullable) NSString *unavailableReason;
@property (nonatomic, assign) A2HomePluginCardAvailability pluginAvailability;
@property (nonatomic, assign) BOOL allowsRetarget;
@end

@implementation A2HomeCardSource

- (instancetype)init {
    self = [super init];
    if (!self) { return nil; }
    _title = @"";
    _symbolName = @"square.grid.2x2";
    return self;
}

- (BOOL)isBuiltin    { return self.state == A2HomeCardSourceStateBuiltin; }
- (BOOL)isPlugin     { return self.state == A2HomeCardSourceStatePlugin; }
- (BOOL)isUnavailable { return self.state == A2HomeCardSourceStateUnavailable; }

@end

#pragma mark - A2HomeCardSourceResolver

/// 不可用态的**唯一**装配点：三处判定的差异只在「标题从哪来 / 原因怎么说 / 能不能重指定」，
/// 所以合成一份，避免三份几乎一样的赋值块。
@interface A2HomeCardSource (A2UnavailableAssembly)
+ (A2HomeCardSource *)a2_unavailableWithCard:(A2HomeCard *_Nullable)card
                                      title:(NSString *)title
                                     reason:(NSString *)reason
                               symbolName:(NSString *)symbolName
                             availability:(A2HomePluginCardAvailability)availability
                            allowsRetarget:(BOOL)allowsRetarget;
@end

@implementation A2HomeCardSourceResolver

+ (A2HomeCardSource *)sourceForCard:(A2HomeCard *)card {
    // ① 未知 kind：低版本读到高版本写的卡，或调用方传错枚举值。
    //    不猜、不崩，如实说「不认识」——卡片照样留着（用户升级回去就恢复了）。
    NSInteger raw = (NSInteger)card.kind;
    if (raw < (NSInteger)A2HomeCardKindGreeting || raw > (NSInteger)A2HomeCardKindShortcutCustom) {
        NSString *title = A2CardFallbackLabel(card) ?: @"卡片";
        NSString *reason = [NSString stringWithFormat:@"未知的卡片类型（kind=%ld）", (long)raw];
        return [A2HomeCardSource a2_unavailableWithCard:card
                                                  title:title
                                                 reason:reason
                                           symbolName:@"questionmark.square.dashed"
                                           availability:A2HomePluginCardAvailabilityAvailable
                                         allowsRetarget:NO];
    }

    // ② 已知类型、但本版没接通数据源（收藏存档 / 收藏服务器）：
    //    原因文案就在类型摘要里，不在这里另写一份（文案只有一处实现）。
    if (!A2HomeKindIsAvailable(card.kind)) {
        return [A2HomeCardSource a2_unavailableWithCard:card
                                                  title:A2HomeKindDisplayName(card.kind)
                                                 reason:A2HomeKindSummary(card.kind)
                                           symbolName:A2HomeKindSymbolName(card.kind)
                                           availability:A2HomePluginCardAvailabilityAvailable
                                         allowsRetarget:NO];
    }

    // ③ 内置卡：确定命中。档位 / target 的合法性仍归布局文档，本层不重复判。
    A2HomeCardSource *source = [[A2HomeCardSource alloc] init];
    source.cardID = card.cardID;
    source.state = A2HomeCardSourceStateBuiltin;
    source.kind = card.kind;
    source.title = A2HomeKindDisplayName(card.kind);
    source.symbolName = A2HomeKindSymbolName(card.kind);
    source.pluginAvailability = A2HomePluginCardAvailabilityAvailable;
    return source;
}

+ (A2HomeCardSource *)sourceForCard:(A2HomeCard *)card
                           pluginId:(NSString *)pluginId
                     contributionId:(NSString *)contributionId
                            catalog:(A2HomePluginCardCatalog *)catalog {
    A2HomeCardSource *source = [[A2HomeCardSource alloc] init];
    source.cardID = card.cardID;
    source.kind = card.kind;
    source.pluginId = pluginId;
    source.contributionId = contributionId;

    // 占位标题的回落顺序：存卡时的名字快照 → 插件 id → 「卡片」。
    // 快照排第一，是因为它记的是**用户当时看到的名字**，比 id 有用。
    NSString *placeholderTitle = A2CardFallbackLabel(card) ?: (pluginId.length > 0 ? pluginId : @"卡片");

    // ① 引用本身不完整：卡片没带齐 (pluginId, contributionId)，谁也查不了。
    if (pluginId.length == 0 || contributionId.length == 0) {
        return [A2HomeCardSource a2_unavailableWithCard:card
                                                  title:placeholderTitle
                                                 reason:@"卡片没有记录插件来源"
                                           symbolName:@"puzzlepiece"
                                           availability:A2HomePluginCardAvailabilityContributionMissing
                                         allowsRetarget:YES];
    }

    // ② 宿主还没装配插件目录（启动早期）：宁可占位，也不画一张没有内容的卡。
    if (catalog == nil) {
        return [A2HomeCardSource a2_unavailableWithCard:card
                                                  title:placeholderTitle
                                                 reason:@"插件尚未就绪"
                                           symbolName:@"puzzlepiece"
                                           availability:A2HomePluginCardAvailabilityPluginMissing
                                         allowsRetarget:NO];
    }

    A2HomePluginCardContent *content = nil;
    A2HomePluginCardAvailability availability =
        [catalog availabilityForPluginId:pluginId contributionId:contributionId content:&content];

    switch (availability) {
        case A2HomePluginCardAvailabilityAvailable: {
            source.state = A2HomeCardSourceStatePlugin;
            source.pluginId = content.pluginId;
            source.pluginVersion = content.pluginVersion;
            source.contributionId = content.contributionId;
            source.slot = content.slot;
            source.title = content.title.length > 0 ? content.title : content.pluginId;
            source.subtitle = content.subtitle;
            source.symbolName = content.symbolName.length > 0 ? content.symbolName : @"puzzlepiece";
            source.pluginAvailability = A2HomePluginCardAvailabilityAvailable;
            return source;
        }
        case A2HomePluginCardAvailabilityPluginDisabled:
            return [A2HomeCardSource a2_unavailableWithCard:card
                                                      title:placeholderTitle
                                                     reason:[NSString stringWithFormat:@"插件「%@」已停用，卡片保留", pluginId]
                                               symbolName:@"puzzlepiece"
                                               availability:availability
                                             allowsRetarget:YES];
        case A2HomePluginCardAvailabilityPluginMissing:
            return [A2HomeCardSource a2_unavailableWithCard:card
                                                      title:placeholderTitle
                                                     reason:[NSString stringWithFormat:@"插件「%@」已卸载，卡片保留", pluginId]
                                               symbolName:@"puzzlepiece"
                                               availability:availability
                                             allowsRetarget:YES];
        case A2HomePluginCardAvailabilityContributionMissing:
            return [A2HomeCardSource a2_unavailableWithCard:card
                                                      title:placeholderTitle
                                                     reason:[NSString stringWithFormat:@"插件「%@」不再提供这张卡片", pluginId]
                                               symbolName:@"puzzlepiece"
                                               availability:availability
                                             allowsRetarget:YES];
    }
}

@end

@implementation A2HomeCardSource (A2UnavailableAssembly)

+ (A2HomeCardSource *)a2_unavailableWithCard:(A2HomeCard *)card
                                      title:(NSString *)title
                                     reason:(NSString *)reason
                               symbolName:(NSString *)symbolName
                             availability:(A2HomePluginCardAvailability)availability
                            allowsRetarget:(BOOL)allowsRetarget {
    A2HomeCardSource *source = [[A2HomeCardSource alloc] init];
    source.cardID = card.cardID;
    source.kind = card.kind;
    source.state = A2HomeCardSourceStateUnavailable;
    source.title = title.length > 0 ? title : @"卡片";
    source.symbolName = symbolName.length > 0 ? symbolName : @"questionmark.square.dashed";
    source.unavailableReason = reason;
    source.pluginAvailability = availability;
    source.allowsRetarget = allowsRetarget;
    return source;
}

@end
