//
//  A2PluginContributionHost.m
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
//  「一份注册表 + 一处映射 + 一行判据」的具体实现。分工见头文件，这里只写取舍：
//
//   · 装配用 `dispatch_once` 而不是属性懒初始化：三件套必须**同时**就位（注册表 →
//     安装器 → Phase A 建表）。分三个 `if (!x)` 写，两个线程各建一半就会得到
//     「安装器接的是 A 注册表、界面读的是 B 注册表」—— 正是本类要消灭的那种 bug。
//   · `entriesForSlot:` 里容量截断**不自己算**，调注册表的 `effectiveEntriesForSlot:`
//     （容量规则只有一处实现）；这里的第二道过滤只回答「这个位置画不画得出这个 component」。
//   · 画不出的 component **不抛错、不伪造**：跳过并计入判据行的「跳过 M 条」。
//

#import "A2PluginContributionHost.h"

#import "A2Icon.h"
#import "A2Log.h"
#import "A2Metrics.h"
#import "A2PluginInstaller.h"
#import "A2PluginRegistry.h"
#import "A2SettingsRow.h"
#import "A2SettingsSection.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"

/// 判据行前缀。与 `[A2-PLUGIN]`（安装器）/ `[A2-PLUGIN-BOOT]`（启动闸门）同一套分诊口径。
static NSString *const kA2PluginUILogPrefix = @"[A2-PLUGIN-UI]";

#pragma mark - 装配状态（全进程各一份）

static A2PluginRegistry *gA2PluginPackageRegistry = nil;
static A2PluginContributionRegistry *gA2PluginContributionRegistry = nil;
static A2PluginInstaller *gA2PluginInstaller = nil;
static dispatch_once_t gA2PluginAssemblyOnce;

/// 某处插入点能画的 component（`PLUGIN-COMPAT.md` 2.3 的叶子组件按位置收敛）。
///
/// 这张表就是「未映射 ⇒ 不画 + 诊断」的判据：表里没有的 component，或表里没有的 slot，
/// 一律不画。它按**位置**而不是按 component 能力写，因为同一个 `icon.glyph` 在顶栏是按钮、
/// 在卡片角上是徽标，能画不等于画得对。
static NSSet<NSString *> *A2CUIRenderableComponents(NSString *slot) {
    static NSDictionary<NSString *, NSSet<NSString *> *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"home.toolbar.action":
                [NSSet setWithArray:@[ @"button.primary", @"button.secondary", @"icon.glyph" ]],
            @"home.card.badge":
                [NSSet setWithArray:@[ @"badge.status", @"text.label", @"icon.glyph" ]],
            @"versions.list.badge":
                [NSSet setWithArray:@[ @"badge.status", @"text.label" ]],
            @"version.detail.header":
                [NSSet setWithArray:@[ @"badge.status", @"text.label", @"text.caption",
                                       @"icon.glyph" ]],
            @"settings.section":
                [NSSet setWithArray:@[ @"list.row", @"switch.toggle", @"text.label",
                                       @"text.caption", @"divider", @"spacer" ]],
            @"home.section":
                [NSSet setWithArray:@[ @"list.row", @"text.label", @"text.caption",
                                       @"divider", @"spacer" ]],
            @"launch.overlay":
                [NSSet setWithArray:@[ @"text.label", @"text.caption", @"badge.status" ]],
        };
    });
    return table[slot] ?: [NSSet set];
}

@interface A2PluginContributionHost ()

/// 一行判据：`[A2-PLUGIN-UI] <slot> 渲染 N 条（跳过 M 条：原因）`。
+ (void)a2_logRenderLineForSlot:(NSString *)slot
                       rendered:(NSUInteger)rendered
                        skipped:(NSUInteger)skipped
                        reasons:(NSArray<NSString *> *)reasons;

/// 条目文案：字面量优先，其次 i18n 键（P2 没有语言表 ⇒ 按 `PLUGIN-COMPAT` 4.2 回退成键本身）。
+ (NSString *)a2_textForEntry:(A2PluginSlotContribution *)entry;

/// 把一条贡献落成设置行 / 分隔线 / 间距，加进分区。
+ (void)a2_addEntry:(A2PluginSlotContribution *)entry toSection:(A2SettingsSection *)section;

@end

@implementation A2PluginContributionHost

#pragma mark - 装配

+ (void)assembleIfNeeded {
    dispatch_once(&gA2PluginAssemblyOnce, ^{
        gA2PluginPackageRegistry = [[A2PluginRegistry alloc] initWithPluginsDirectory:nil];
        gA2PluginContributionRegistry = [A2PluginContributionRegistry new];

        gA2PluginInstaller = [[A2PluginInstaller alloc] initWithRegistry:gA2PluginPackageRegistry];
        // ★本类的存在理由★：安装器与七处插入点必须是同一个贡献点注册表实例。
        gA2PluginInstaller.contributionRegistry = gA2PluginContributionRegistry;

        // Phase A 建表：贡献点注册表是**运行时缓存**，进程重启后是空的；
        // 按磁盘上的 enabled 重建一次，「昨天启用的插件今天开机还在」才成立。
        (void)[gA2PluginInstaller attachContributionsForEnabledPlugins];
    });
}

+ (A2PluginRegistry *)packageRegistry {
    [self assembleIfNeeded];
    return gA2PluginPackageRegistry;
}

+ (A2PluginContributionRegistry *)contributionRegistry {
    [self assembleIfNeeded];
    return gA2PluginContributionRegistry;
}

+ (A2PluginInstaller *)installer {
    [self assembleIfNeeded];
    return gA2PluginInstaller;
}

#pragma mark - 读

+ (NSArray<A2PluginSlotContribution *> *)entriesForSlot:(NSString *)slot {
    [self assembleIfNeeded];
    if (![slot isKindOfClass:NSString.class] || slot.length == 0) return @[];

    // 容量截断只走注册表那一处实现；这里另拿一份「未截断」的只为了把跳过的原因说清楚。
    NSArray<A2PluginSlotContribution *> *all = [gA2PluginContributionRegistry slotEntriesForSlot:slot];
    NSArray<A2PluginSlotContribution *> *effective =
        [gA2PluginContributionRegistry effectiveEntriesForSlot:slot];
    NSSet<NSString *> *renderable = A2CUIRenderableComponents(slot);

    NSMutableArray<A2PluginSlotContribution *> *result = [NSMutableArray array];
    NSMutableArray<NSString *> *unmapped = [NSMutableArray array];
    for (A2PluginSlotContribution *entry in effective) {
        if (![renderable containsObject:entry.component]) {
            [unmapped addObject:entry.component ?: @"?"];
            continue;
        }
        [result addObject:entry];
    }

    NSUInteger droppedByCapacity = all.count > effective.count ? (all.count - effective.count) : 0;
    NSMutableArray<NSString *> *reasons = [NSMutableArray array];
    if (droppedByCapacity > 0) {
        [reasons addObject:[NSString stringWithFormat:@"容量上限 %lu，挤掉 %lu 条",
                            (unsigned long)A2PluginSlotCapacity(slot),
                            (unsigned long)droppedByCapacity]];
    }
    if (unmapped.count > 0) {
        [reasons addObject:[NSString stringWithFormat:@"component「%@」在本位置没有映射",
                            [unmapped componentsJoinedByString:@"」「"]]];
    }

    [self a2_logRenderLineForSlot:slot
                         rendered:result.count
                          skipped:(droppedByCapacity + unmapped.count)
                          reasons:reasons];
    return result;
}

+ (void)a2_logRenderLineForSlot:(NSString *)slot
                       rendered:(NSUInteger)rendered
                        skipped:(NSUInteger)skipped
                        reasons:(NSArray<NSString *> *)reasons {
    NSString *tail = reasons.count > 0
        ? [NSString stringWithFormat:@"：%@", [reasons componentsJoinedByString:@"；"]]
        : @"";
    [A2Log criterion:@"%@ %@ 渲染 %lu 条（跳过 %lu 条%@）",
     kA2PluginUILogPrefix, slot, (unsigned long)rendered, (unsigned long)skipped, tail];
}

+ (NSString *)a2_textForEntry:(A2PluginSlotContribution *)entry {
    if (entry.labelText.length > 0) return entry.labelText;
    if (entry.labelI18n.length > 0) return entry.labelI18n;
    return entry.identifier ?: @"";
}

#pragma mark - 画：徽标

+ (nullable UIView *)badgeForEntry:(A2PluginSlotContribution *)entry onDarkSurface:(BOOL)onDarkSurface {
    if (![entry isKindOfClass:A2PluginSlotContribution.class]) return nil;

    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    NSString *text = [self a2_textForEntry:entry];
    BOOL isBadge = [entry.component isEqualToString:@"badge.status"];
    BOOL isCaption = [entry.component isEqualToString:@"text.caption"];
    BOOL isIconOnly = [entry.component isEqualToString:@"icon.glyph"];

    UIImage *icon = nil;
    if (entry.icon.length > 0) {
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:12
                                                            weight:UIImageSymbolWeightSemibold];
        icon = [UIImage systemImageNamed:[A2Icon symbolForSemanticIconID:entry.icon]
                       withConfiguration:cfg];
    }

    // 纯图标（或没有文案的图标条目）→ 只有字形，不套胶囊底
    if (icon != nil && (isIconOnly || text.length == 0)) {
        UIImageView *imageView = [[UIImageView alloc] initWithImage:icon];
        imageView.translatesAutoresizingMaskIntoConstraints = NO;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.tintColor = onDarkSurface ? [UIColor colorWithWhite:1.0 alpha:0.75]
                                            : t.cOnSurfaceVariant;
        return imageView;
    }
    // 既没文案也没字形：不画（调用方按「跳过」处理，不补假视图）
    if (text.length == 0) return nil;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.numberOfLines = 1;                       // 契约：徽标最多一行
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    // ★宁可截断也不挤跑布局★：这一条只在别的视图抢宽度时生效
    [label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                           forAxis:UILayoutConstraintAxisHorizontal];

    if (isBadge) {
        label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    } else {
        label.font = [A2Typography caption];
    }

    if (onDarkSurface) {
        // 启动遮罩是深底（白字），浅色主题的语义色搬过去会看不见
        label.textColor = isBadge ? [UIColor colorWithWhite:1.0 alpha:0.95]
                                  : [UIColor colorWithWhite:1.0 alpha:0.7];
    } else if (isBadge) {
        label.textColor = t.cOnSecondaryContainer;
    } else if (isCaption) {
        label.textColor = t.cOnSurfaceVariant;
    } else {
        label.textColor = t.cOnSurface;
    }

    UIView *pill = [[UIView alloc] initWithFrame:CGRectZero];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    if (isBadge) {
        pill.backgroundColor = onDarkSurface ? [UIColor colorWithWhite:1.0 alpha:0.16]
                                             : t.cSecondaryContainer;
        pill.layer.cornerRadius = A2RadiusS;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.clipsToBounds = YES;
    }
    [pill addSubview:label];

    CGFloat hPad = isBadge ? 6.0 : 0.0;
    CGFloat vPad = isBadge ? 3.0 : 0.0;
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:pill.topAnchor constant:vPad],
        [label.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-vPad],
        [label.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:hPad],
        [label.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-hPad],
    ]];
    return pill;
}

#pragma mark - 画：工具栏按钮

+ (nullable UIButton *)actionButtonForEntry:(A2PluginSlotContribution *)entry
                                    handler:(nullable void (^)(A2PluginSlotContribution *entry))handler {
    if (![entry isKindOfClass:A2PluginSlotContribution.class]) return nil;

    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    NSString *text = [self a2_textForEntry:entry];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightMedium];
    UIImage *image = [UIImage systemImageNamed:[A2Icon symbolForSemanticIconID:entry.icon]
                            withConfiguration:cfg];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    if (image != nil) {
        [button setImage:image forState:UIControlStateNormal];
    } else if (text.length > 0) {
        // 没有可用字形时退回文字按钮：不画一个空白可点区域
        [button setTitle:text forState:UIControlStateNormal];
        button.titleLabel.font = [A2Typography caption];
    } else {
        return nil;
    }

    // 无障碍名用文案：图标按钮光看字形说不清是什么
    button.accessibilityLabel = text.length > 0 ? text : entry.identifier;
    button.tintColor = [entry.component isEqualToString:@"button.primary"]
        ? t.cPrimary
        : t.cOnSurfaceVariant;
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:A2MinTouchTarget],
        [button.heightAnchor constraintEqualToConstant:A2MinTouchTarget],
    ]];

    if (handler != nil) {
        __weak A2PluginSlotContribution *weakEntry = entry;
        [button addAction:[UIAction actionWithHandler:^(UIAction *action) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
            (void)action;
#pragma clang diagnostic pop
            A2PluginSlotContribution *strongEntry = weakEntry;
            if (strongEntry != nil) handler(strongEntry);
        }] forControlEvents:UIControlEventTouchUpInside];
    }
    return button;
}

#pragma mark - 画：分区

+ (NSArray<A2SettingsSection *> *)sectionsForEntries:(NSArray<A2PluginSlotContribution *> *)entries {
    if (entries.count == 0) return @[];

    // 一个插件一张卡：设置项的 id 是宿主侧唯一键，混进同一张卡就分不清归属
    // （同名键在注册表里已经被 `E_SLOT_CONFLICT` 挡掉，但「哪一行属于谁」仍要说清楚）。
    NSMutableArray<NSString *> *pluginOrder = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray<A2PluginSlotContribution *> *> *byPlugin =
        [NSMutableDictionary dictionary];
    for (A2PluginSlotContribution *entry in entries) {
        NSString *pluginId = entry.pluginId ?: @"?";
        NSMutableArray<A2PluginSlotContribution *> *bucket = [byPlugin objectForKey:pluginId];
        if (bucket == nil) {
            bucket = [NSMutableArray array];
            [byPlugin setObject:bucket forKey:pluginId];
            [pluginOrder addObject:pluginId];
        }
        [bucket addObject:entry];
    }

    NSMutableArray<A2SettingsSection *> *sections = [NSMutableArray array];
    for (NSString *pluginId in pluginOrder) {
        NSArray<A2PluginSlotContribution *> *bucket = [byPlugin objectForKey:pluginId];

        // 整块只有分隔线/间距 ⇒ 不出空卡（卡片有标题+页脚，加了就是一张「什么都没有」的卡）
        BOOL hasContent = NO;
        for (A2PluginSlotContribution *entry in bucket) {
            BOOL isLayoutOnly = [entry.component isEqualToString:@"divider"]
                             || [entry.component isEqualToString:@"spacer"];
            if (!isLayoutOnly) {
                hasContent = YES;
                break;
            }
        }
        if (!hasContent) continue;

        A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:pluginId];
        section.footerText = @"由插件声明。P2 阶段只渲染声明，不执行插件代码。";
        for (A2PluginSlotContribution *entry in bucket) {
            [self a2_addEntry:entry toSection:section];
        }
        [sections addObject:section];
    }
    return sections;
}

+ (void)a2_addEntry:(A2PluginSlotContribution *)entry toSection:(A2SettingsSection *)section {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    NSString *text = [self a2_textForEntry:entry];

    if ([entry.component isEqualToString:@"divider"]) {
        UIView *line = [[UIView alloc] initWithFrame:CGRectZero];
        line.translatesAutoresizingMaskIntoConstraints = NO;
        line.backgroundColor = t.cOutlineVariant;
        [NSLayoutConstraint activateConstraints:@[
            [line.heightAnchor constraintEqualToConstant:1.0],
        ]];
        [section addCustomView:line];
        return;
    }
    if ([entry.component isEqualToString:@"spacer"]) {
        UIView *space = [[UIView alloc] initWithFrame:CGRectZero];
        space.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [space.heightAnchor constraintEqualToConstant:A2SpaceS],
        ]];
        [section addCustomView:space];
        return;
    }

    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.title = text.length > 0 ? text : (entry.identifier ?: @"");
    if (entry.icon.length > 0) {
        row.symbolName = [A2Icon symbolForSemanticIconID:entry.icon];
    }

    if ([entry.component isEqualToString:@"switch.toggle"]) {
        row.accessory = A2SettingsRowAccessorySwitch;
        row.subtitle = @"P2 阶段只渲染声明：开关要等 P3 运行时才会生效";
        row.enabled = NO;      // 装一个点了没反应、也不落盘的开关等于骗人（石山：不留死行）
    } else if ([entry.component isEqualToString:@"text.caption"]) {
        row.accessory = A2SettingsRowAccessoryNone;
    } else {
        // list.row / text.label：只读行，没有动作可绑（P2 没有 action 运行时）
        row.accessory = A2SettingsRowAccessoryNone;
    }
    [section addRow:row];
}

@end
