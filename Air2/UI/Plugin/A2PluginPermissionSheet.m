//
//  A2PluginPermissionSheet.m
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

#import "A2PluginPermissionSheet.h"

#import "A2Dialog.h"
#import "A2Metrics.h"
#import "A2PluginCriticalConfirmFlow.h"
#import "A2PluginManifest.h"
#import "A2SettingsRow.h"
#import "A2SettingsSection.h"
#import "A2Toast.h"

/// 包哈希的展示形式：前 8 位 + 后 4 位（§3.2 规则 2），完整值点开看。
static NSString *A2PluginSheetShortHash(NSString *hash) {
    if (!hash.length) return @"（未提供）";
    NSString *value = [hash hasPrefix:@"sha256:"] ? [hash substringFromIndex:7] : hash;
    if (value.length <= 12) return value;
    return [NSString stringWithFormat:@"%@…%@",
            [value substringToIndex:8],
            [value substringFromIndex:value.length - 4]];
}

/// 完整哈希按 16 位一行折开 —— 64 位连续字符串在弹窗里会撑成一堵墙。
static NSString *A2PluginSheetWrappedHash(NSString *hash) {
    NSString *value = [hash hasPrefix:@"sha256:"] ? [hash substringFromIndex:7] : hash;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSUInteger index = 0;
    while (index < value.length) {
        NSUInteger length = MIN((NSUInteger)16, value.length - index);
        [lines addObject:[value substringWithRange:NSMakeRange(index, length)]];
        index += length;
    }
    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - 分组视图

/// 一个后果组的两张卡：标题卡（永远显示）与细项卡（折叠）。
/// 拆成两张卡而不是「一行标题 + 缩进的子行」，是为了让折叠态的圆角仍然正确 ——
/// 行隐藏后 `A2SettingsSection` 仍会把它算进首/末行，视觉上会露出一条平角。
@interface A2PluginPermissionGroupView : NSObject
@property (nonatomic, assign) A2PluginPermissionGroup group;
@property (nonatomic, strong) A2SettingsSection *headerSection;
@property (nonatomic, strong) A2SettingsSection *itemsSection;
@property (nonatomic, strong) A2SettingsRow *headerRow;
@property (nonatomic, strong) NSArray<A2PluginPermissionInfo *> *items;
@property (nonatomic, assign) BOOL expanded;
@end

@implementation A2PluginPermissionGroupView
@end

#pragma mark - 授权页

@interface A2PluginPermissionSheet ()
@property (nonatomic, strong) A2PluginManifest *manifest;
@property (nonatomic, strong) A2PluginPermissionStore *store;
@property (nonatomic, copy, nullable) NSString *packageHash;
@property (nonatomic, copy, nullable) void (^completion)(NSArray<NSString *> *grantedPermissions);

@property (nonatomic, strong) NSMutableArray<A2PluginPermissionGroupView *> *groupViews;
@property (nonatomic, strong) NSMutableDictionary<NSString *, A2SettingsRow *> *itemRows;
@property (nonatomic, strong, nullable) A2PluginCriticalConfirmFlow *activeFlow;
@property (nonatomic, assign) BOOL didFinish;
@end

@implementation A2PluginPermissionSheet

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：没有 manifest / store 的授权页是非法状态。
    // 声明/实现一致性检查要求每个声明都有实现；正常代码走不到这里。
    return nil;
}

- (instancetype)initWithManifest:(A2PluginManifest *)manifest
                           store:(A2PluginPermissionStore *)store
                     packageHash:(nullable NSString *)packageHash {
    self = [super init];
    if (self) {
        _manifest = manifest;
        _store = store;
        _packageHash = [packageHash copy];
        _hostMilestone = A2PluginMilestoneP1;
        _groupViews = [NSMutableArray array];
        _itemRows = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark 入口

+ (instancetype)presentForManifest:(A2PluginManifest *)manifest
                             store:(A2PluginPermissionStore *)store
                       packageHash:(nullable NSString *)packageHash
                     hostMilestone:(A2PluginMilestone)hostMilestone
                fromViewController:(UIViewController *)presenter
                        completion:(nullable void (^)(NSArray<NSString *> *grantedPermissions))
                                       completion {
    A2PluginPermissionSheet *sheet = [[A2PluginPermissionSheet alloc] initWithManifest:manifest
                                                                                 store:store
                                                                           packageHash:packageHash];
    sheet.hostMilestone = hostMilestone;
    sheet.completion = completion;
    sheet.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:sheet animated:YES completion:nil];
    return sheet;
}

#pragma mark 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = self.manifest.name.length ? self.manifest.name : self.manifest.pluginId;

    __weak typeof(self) weakSelf = self;
    // 顶栏的「完成」与返回箭头做同一件事：授权是逐项即时落盘的，
    // 离开页面不会丢掉已经点过的授权，区别只在要不要回调。
    [self addTrailingButtonWithSymbol:@"checkmark" action:^{
        __strong typeof(weakSelf) self = weakSelf;
        [self finishSheet];
    }];
    self.onBack = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self finishSheet];
    };

    [self addSection:[self pluginInfoSection]];
    [self addSection:[self overviewSection]];

    for (NSNumber *groupNumber in [self groupOrder]) {
        [self addGroupSection:(A2PluginPermissionGroup)groupNumber.integerValue];
    }

    [self addSection:[self footerSection]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 进页面先让 VoiceOver 从标题开始，而不是从顶栏按钮开始。
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification,
                                    self.scrollView);
}

#pragma mark 分区构建

/// 固定的组顺序（§3.2.1：不按风险、不按插件申请顺序重排）。
- (NSArray<NSNumber *> *)groupOrder {
    return @[@(A2PluginPermissionGroupGameFiles),
             @(A2PluginPermissionGroupNetwork),
             @(A2PluginPermissionGroupReadData),
             @(A2PluginPermissionGroupLaunch),
             @(A2PluginPermissionGroupInterface)];
}

- (NSArray<A2PluginPermissionInfo *> *)itemsForGroup:(A2PluginPermissionGroup)group {
    NSMutableArray<A2PluginPermissionInfo *> *items = [NSMutableArray array];
    for (NSString *permissionId in self.manifest.permissions) {
        A2PluginPermissionInfo *info = A2PluginPermissionInfoForId(permissionId);
        if (!info) continue;
        if (info.group != group) continue;
        [items addObject:info];
    }
    return items;
}

- (A2SettingsSection *)pluginInfoSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"这个插件"];
    section.footerText =
        @"Air2 不验证作者身份。请确认这个包来自你信任的地方。"
         "哈希只能证明「包没变」，不能证明「是谁做的」。";

    A2SettingsRow *nameRow = [[A2SettingsRow alloc] init];
    nameRow.title = self.manifest.name;
    nameRow.subtitle = [NSString stringWithFormat:@"%@ · %@",
                        self.manifest.pluginId, self.manifest.version];
    nameRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:nameRow];

    A2SettingsRow *authorRow = [[A2SettingsRow alloc] init];
    authorRow.title = @"作者（自述）";
    authorRow.valueText = self.manifest.authorName.length ? self.manifest.authorName : @"未填写";
    authorRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:authorRow];

    A2SettingsRow *hashRow = [[A2SettingsRow alloc] init];
    hashRow.title = @"包哈希";
    hashRow.subtitle = @"这次安装的内容摘要，点开看完整值";
    hashRow.valueText = A2PluginSheetShortHash(self.packageHash);
    hashRow.accessory = A2SettingsRowAccessoryDisclosure;
    __weak typeof(self) weakSelf = self;
    hashRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self presentFullHash];
    };
    [section addRow:hashRow];

    return section;
}

- (A2SettingsSection *)overviewSection {
    NSUInteger total = 0;
    NSUInteger critical = 0;
    NSUInteger groupCount = 0;
    for (NSNumber *groupNumber in [self groupOrder]) {
        NSArray<A2PluginPermissionInfo *> *items =
            [self itemsForGroup:(A2PluginPermissionGroup)groupNumber.integerValue];
        if (items.count == 0) continue;
        groupCount += 1;
        total += items.count;
        for (A2PluginPermissionInfo *info in items) {
            if (info.risk == A2PluginRiskCritical) critical += 1;
        }
    }

    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"申请的权限"];
    A2SettingsRow *summaryRow = [[A2SettingsRow alloc] init];
    summaryRow.title = [NSString stringWithFormat:@"共 %lu 项 · 分 %lu 组",
                        (unsigned long)total, (unsigned long)groupCount];
    // §3.5 更新页那一行：包内容更新但权限集没变时，高危项沿用上次授权、不重复弹。
    // 判定交给 store，UI 只负责把结论写出来 —— 这里不许自己比版本号。
    NSError *reconfirmError = nil;
    BOOL needsReconfirm = critical > 0;
    if (needsReconfirm) {
        needsReconfirm = [self.store needsReconfirmForManifest:self.manifest
                                                   packageHash:self.packageHash
                                                         error:&reconfirmError];
        // 判定失败时按「要确认」处理：宁可多问一次，不能少问。
        if (reconfirmError) needsReconfirm = YES;
    }
    if (critical == 0) {
        summaryRow.subtitle = @"没有高危权限";
    } else if (needsReconfirm) {
        summaryRow.subtitle =
            [NSString stringWithFormat:@"其中 %lu 项高危，需要连续三次确认",
             (unsigned long)critical];
    } else {
        summaryRow.subtitle = @"内容已更新，权限未变 · 高危权限沿用上次的授权";
    }
    summaryRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:summaryRow];
    return section;
}

- (A2SettingsSection *)footerSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:nil];
    section.footerText =
        @"低/中权限默认开启，可以逐项关掉；关掉后插件对应的功能直接不存在。"
         "高危权限默认关闭，需要连续三次确认（每次 5 秒），不提供整组授权。"
         "一项都不授权也能正常安装，插件会在管理页显示「功能受限」。";
    return section;
}

- (void)addGroupSection:(A2PluginPermissionGroup)group {
    NSArray<A2PluginPermissionInfo *> *items = [self itemsForGroup:group];
    if (items.count == 0) return;   // 空组隐藏（§3.2.1 规则 1）

    A2PluginPermissionGroupView *view = [[A2PluginPermissionGroupView alloc] init];
    view.group = group;
    view.items = items;
    view.expanded = NO;

    // ---- 标题卡（折叠态只看得到这一行）----
    view.headerSection = [[A2SettingsSection alloc] initWithTitle:nil];
    A2SettingsRow *headerRow = [[A2SettingsRow alloc] init];
    headerRow.title = A2PluginPermissionGroupTitle(group);
    headerRow.subtitle = A2PluginPermissionGroupConsequence(group);
    headerRow.valueText = [self summaryTextForItems:items];
    headerRow.accessory = A2SettingsRowAccessoryDisclosure;
    headerRow.accessibilityTraits = UIAccessibilityTraitButton;
    view.headerRow = headerRow;
    [view.headerSection addRow:headerRow];

    __weak typeof(self) weakSelf = self;
    headerRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self toggleGroup:group];
    };

    // ---- 细项卡（默认折叠）----
    view.itemsSection = [[A2SettingsSection alloc] initWithTitle:nil];
    view.itemsSection.hidden = YES;
    for (A2PluginPermissionInfo *info in items) {
        A2SettingsRow *row = [self rowForPermission:info];
        [view.itemsSection addRow:row];
        self.itemRows[info.permissionId] = row;
    }

    [self.groupViews addObject:view];
    [self addSection:view.headerSection];
    [self addSection:view.itemsSection];
}

/// 折叠态的摘要：项数 + 最高的那档风险（§3.2.1 规则 4：折叠不等于隐藏）。
- (NSString *)summaryTextForItems:(NSArray<A2PluginPermissionInfo *> *)items {
    NSUInteger critical = 0;
    BOOL hasMedium = NO;
    for (A2PluginPermissionInfo *info in items) {
        if (info.risk == A2PluginRiskCritical) critical += 1;
        if (info.risk == A2PluginRiskMedium) hasMedium = YES;
    }
    if (critical) {
        return [NSString stringWithFormat:@"%lu 项 · 含 %lu 项高危",
                (unsigned long)items.count, (unsigned long)critical];
    }
    if (hasMedium) {
        return [NSString stringWithFormat:@"%lu 项 · 中危", (unsigned long)items.count];
    }
    return [NSString stringWithFormat:@"%lu 项 · 低危", (unsigned long)items.count];
}

- (void)toggleGroup:(A2PluginPermissionGroup)group {
    for (A2PluginPermissionGroupView *view in self.groupViews) {
        if (view.group != group) continue;
        view.expanded = !view.expanded;
        view.itemsSection.hidden = !view.expanded;
        view.headerRow.accessory = view.expanded
            ? A2SettingsRowAccessoryDropdown
            : A2SettingsRowAccessoryDisclosure;
        return;
    }
}

#pragma mark 单行构建

- (BOOL)isAvailable:(A2PluginPermissionInfo *)info {
    // §3.2 规则 5：未到当前宿主里程碑的权限显示「当前版本不可用」，开关禁用、不会授予。
    return info.milestone <= self.hostMilestone;
}

- (A2SettingsRow *)rowForPermission:(A2PluginPermissionInfo *)info {
    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.title = info.shortName;
    row.subtitle = info.consequence;   // §9 人话后果整句（原文）
    row.accessibilityIdentifier = info.permissionId;
    __weak typeof(self) weakSelf = self;

    if (![self isAvailable:info]) {
        // 不可用时不挂开关：一个点了没反应的开关比一句说明更糟。
        row.accessory = A2SettingsRowAccessoryNone;
        row.valueText = @"当前版本不可用";
        row.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [A2Toast show:[NSString stringWithFormat:@"「%@」在 %@ 版本才可用",
                           info.shortName, A2PluginMilestoneName(info.milestone)]
                   inView:self.view];
        };
        return row;
    }

    if (info.risk == A2PluginRiskCritical) {
        row.accessory = A2SettingsRowAccessoryWarning;
        row.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self handleCriticalTap:info];
        };
        [self refreshRowForInfo:info];
        return row;
    }

    row.accessory = A2SettingsRowAccessorySwitch;
    row.on = [self.store isGranted:info.permissionId forPlugin:self.manifest.pluginId];
    row.onToggle = ^(BOOL isOn) {
        __strong typeof(weakSelf) self = weakSelf;
        [self applyToggle:isOn forInfo:info];
    };
    [self refreshRowForInfo:info];
    return row;
}

#pragma mark 状态刷新

- (void)refreshRowForInfo:(A2PluginPermissionInfo *)info {
    A2SettingsRow *row = self.itemRows[info.permissionId];
    if (!row) return;

    if (![self isAvailable:info]) {
        row.valueText = @"当前版本不可用";
        return;
    }
    BOOL granted = [self.store isGranted:info.permissionId forPlugin:self.manifest.pluginId];
    if (info.risk == A2PluginRiskCritical) {
        row.valueText = granted ? @"已授权 · 3 步" : @"未授权 · 需 3 步";
        return;
    }
    row.on = granted;
    row.valueText = granted ? @"已授权" : @"未授权";
}

- (void)refreshAllRows {
    for (NSString *permissionId in self.manifest.permissions) {
        A2PluginPermissionInfo *info = A2PluginPermissionInfoForId(permissionId);
        if (info) [self refreshRowForInfo:info];
    }
}

#pragma mark 交互

- (void)applyToggle:(BOOL)isOn forInfo:(A2PluginPermissionInfo *)info {
    NSError *error = nil;
    BOOL ok;
    if (isOn) {
        ok = [self.store grantPermission:info.permissionId forPlugin:self.manifest error:&error];
    } else {
        ok = [self.store revokePermission:info.permissionId forPlugin:self.manifest error:&error];
    }
    if (!ok) {
        // 失败时把开关拨回真实状态：留在一个「看起来已授权」的界面上，
        // 用户下一次启动才发现功能不存在。
        [A2Toast show:(error.localizedDescription ?: @"操作失败") inView:self.view];
    }
    [self refreshAllRows];
}

- (void)handleCriticalTap:(A2PluginPermissionInfo *)info {
    BOOL granted = [self.store isGranted:info.permissionId forPlugin:self.manifest.pluginId];
    if (!granted) {
        [self startCriticalFlowForInfo:info];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [A2Dialog showInView:self.view
                   title:@"撤销这项授权？"
                 message:@"撤销后插件立刻失去这项能力；要再授予，需要重新走三次确认。"
                 actions:@[
        [A2DialogAction actionWithTitle:@"保留" style:A2DialogActionStyleText handler:nil],
        [A2DialogAction actionWithTitle:@"撤销" style:A2DialogActionStyleDestructive handler:^{
            __strong typeof(weakSelf) self = weakSelf;
            [self revokeFromDialog:info];
        }],
    ]];
}

- (void)revokeFromDialog:(A2PluginPermissionInfo *)info {
    NSError *error = nil;
    if (![self.store revokePermission:info.permissionId forPlugin:self.manifest error:&error]) {
        [A2Toast show:(error.localizedDescription ?: @"撤销失败") inView:self.view];
    }
    [self refreshAllRows];
}

- (void)startCriticalFlowForInfo:(A2PluginPermissionInfo *)info {
    A2PluginCriticalConfirmFlow *flow =
        [[A2PluginCriticalConfirmFlow alloc] initWithManifest:self.manifest
                                                        store:self.store
                                                  packageHash:self.packageHash];
    // 流程对象由本页持有：三次确认是跨页面的，没有持有者的话
    // 第一个页面 dismiss 后流程就会被释放，第二页再也弹不出来。
    self.activeFlow = flow;

    __weak typeof(self) weakSelf = self;
    [flow runForPermission:info.permissionId
                      from:self
                completion:^(BOOL granted, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        self.activeFlow = nil;
        if (error) {
            [A2Toast show:(error.localizedDescription ?: @"授权失败") inView:self.view];
        }
        [self refreshAllRows];
    }];
}

#pragma mark 包哈希

- (void)presentFullHash {
    NSString *full = self.packageHash.length ? self.packageHash : @"（未提供）";
    [A2Dialog showInView:self.view
                   title:@"包哈希（SHA-256）"
                 message:A2PluginSheetWrappedHash(full)
                 actions:@[
        [A2DialogAction actionWithTitle:@"关闭" style:A2DialogActionStyleText handler:nil],
        [A2DialogAction actionWithTitle:@"复制" style:A2DialogActionStyleFilled handler:^{
            UIPasteboard.generalPasteboard.string = full;
        }],
    ]];
}

#pragma mark 完成

- (void)finishSheet {
    if (self.didFinish) return;
    self.didFinish = YES;

    // §3.4：内容更新但权限集未变时，把当前哈希追加进 approvedHashes。
    // 写失败不该拦住用户离开页面 —— 白名单只取证，不授予任何东西。
    if (self.packageHash.length) {
        NSError *error = nil;
        if (![self.store noteApprovedHash:self.packageHash
                                forPlugin:self.manifest.pluginId
                                    error:&error]) {
            [A2Toast show:(error.localizedDescription ?: @"记录包哈希失败") inView:self.view];
        }
    }

    void (^completion)(NSArray<NSString *> *) = self.completion;
    self.completion = nil;
    if (completion) completion([self grantedPermissionIds]);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSArray<NSString *> *)grantedPermissionIds {
    NSMutableArray<NSString *> *granted = [NSMutableArray array];
    for (NSString *permissionId in self.manifest.permissions) {
        if ([self.store isGranted:permissionId forPlugin:self.manifest.pluginId]) {
            [granted addObject:permissionId];
        }
    }
    return granted;
}

@end
