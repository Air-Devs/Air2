//
//  A2SettingsViewController.m
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
//  设置页 —— 左侧分类导航 + 右侧内容。
//
//  结构对齐 ZL2 的 SettingsScreen，左侧导航用共用的 A2CategoryNavView。
//

#import "A2SettingsViewController.h"
#import "A2CategoryNavView.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

#import "A2SettingsSections.h"
#import "A2DiagnosticsSettings.h"
#import "A2OnDevicePairingSettings.h"   // [A2-PAIR-ONDEVICE] 诊断 › 设备内配对（调试开关控制显示）
#import "A2PluginListViewController.h"  // ★插件★ 设置 › 插件（安装器/注册表/权限存储的唯一 UI 入口）
#import "A2PluginRegistry.h"            // ★插件★ 分类行的副标题（已安装数）
#import "A2PluginContributionHost.h"    // ★插件 P2★ 共享注册表 + 插入点 ⑤ settings.section

@interface A2SettingsViewController ()
@property (nonatomic, strong) A2CategoryNavView *nav;
@property (nonatomic, strong) UIScrollView *detailScroll;
@property (nonatomic, strong) UIStackView *detailStack;
/// 当前选中的分类索引（「设备内配对」开关切换后要按同一个索引重建内容）。
@property (nonatomic, assign) NSInteger currentIndex;
@end

@implementation A2SettingsViewController

- (void)viewDidLoad {
    // 必须写在 super 之前：基类在 [super viewDidLoad] 里就按它决定建 scroll 还是
    // plain 内容容器。晚设会让 plainContentView 一直是 nil，后面的约束拿到 nil
    // 锚点，直接抛 NSInvalidArgumentException。
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = @"设置";

    // 其余等对应功能实现后再加。见 A2SettingsSections.h 的说明。
    // 只放有真实实现的分类。
    // 渲染设置暂不加 —— 渲染层还没实现，加了就是空壳。
    NSArray<A2NavCategory *> *cats = @[
        [A2NavCategory title:@"游戏" symbol:@"gamecontroller.fill"],
        [A2NavCategory title:@"外观" symbol:@"paintpalette.fill"],
        [A2NavCategory title:@"诊断" symbol:@"stethoscope"],
        // ★插件★（P1 移植）分类顺序 = rebuildContentForIndex 的索引，插件在 index 3。
        // 只是多一档导航，前三档的索引不变 ⇒ 主线既有分类行为逐字不变。
        [A2NavCategory title:@"插件" symbol:@"puzzlepiece.extension.fill"],
    ];

    __weak typeof(self) weakSelf = self;
    _nav = [[A2CategoryNavView alloc] initWithCategories:cats];
    _nav.onSelect = ^(NSInteger index) {
        __strong typeof(weakSelf) self = weakSelf;
        [self rebuildContentForIndex:index];
    };
    [self.plainContentView addSubview:_nav];

    _detailScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _detailScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _detailScroll.showsVerticalScrollIndicator = NO;
    _detailScroll.alwaysBounceVertical = YES;
    [self.plainContentView addSubview:_detailScroll];

    _detailStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _detailStack.translatesAutoresizingMaskIntoConstraints = NO;
    _detailStack.axis = UILayoutConstraintAxisVertical;
    _detailStack.spacing = A2SpaceXL;
    [_detailScroll addSubview:_detailStack];

    [NSLayoutConstraint activateConstraints:@[
        [_nav.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_nav.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_nav.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                           constant:A2SpaceS],

        [_detailScroll.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_detailScroll.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_detailScroll.leadingAnchor constraintEqualToAnchor:_nav.trailingAnchor
                                                    constant:A2SpaceM],
        [_detailScroll.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],

        [_detailStack.topAnchor constraintEqualToAnchor:_detailScroll.topAnchor constant:A2SpaceS],
        [_detailStack.bottomAnchor constraintEqualToAnchor:_detailScroll.bottomAnchor
                                                   constant:-A2SpaceXXL],
        [_detailStack.leadingAnchor constraintEqualToAnchor:_detailScroll.leadingAnchor
                                                    constant:A2SpaceM],
        // ★关键★ 宽度必须钉在「可视区」(frameLayoutGuide)，不能钉 contentLayoutGuide：
        //   钉 content 时内容宽 = 最宽子视图的固有宽度 ⇒ 每个 section 各按自己内容宽
        //   （真机现象：主题卡片短、资源下载卡片长出屏幕，长短不齐）。
        [_detailStack.widthAnchor constraintEqualToAnchor:_detailScroll.frameLayoutGuide.widthAnchor
                                                 constant:-(A2SpaceM + A2SpaceXL)],
    ]];

    [_nav selectIndex:0 animated:NO];

    // [A2-PAIR-ONDEVICE] 「设备内配对」调试开关切换后重建当前分类（入口出现/消失，
    //  不留「点了没反应」的死行）。通知只由 A2OnDevicePairingSettings 发出。
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(onDevicePairingEntryDidChange:)
                                              name:A2OnDevicePairingEntryDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // ★插件 P2 插入点 ⑤★ 「插件」分类里的 `settings.section` 是插件声明的：从插件页
    // 装/启用一个插件回来，必须按当前注册表重画，否则要杀进程才看见。
    // 只在插件分类做 —— 其它分类的内容与滚动位置不因为进出页面而重建。
    if (_currentIndex == 3) [self rebuildContentForIndex:3];
}

- (void)onDevicePairingEntryDidChange:(NSNotification *)note {
    (void) note;
    [self rebuildContentForIndex:_currentIndex];
}

/// 已安装插件数。读不出来就说读不出来 —— 显示「0 个」会被当成「一个都没装」。
/// 调用点：rebuildContentForIndex 的插件分类（设置 › 插件 那一行的副标题）。
///
/// ★P2 接线★ 注册表取 `A2PluginContributionHost` 里那一份共享实例，不再每开一次页面
/// 建一个新的（两份实例读到的内容一样，但「同一个实例」才谈得上共享与诊断）。
/// 生效中的贡献条数只在 > 0 时追加，未装插件时的文案与接线前逐字相同。
- (NSString *)pluginSummaryText {
    A2PluginRegistry *registry = [A2PluginContributionHost packageRegistry];
    NSError *error = nil;
    if (![registry loadWithError:&error]) return @"注册表读不出来";
    NSUInteger count = [registry allEntries].count;
    if (count == 0) return @"还没有安装插件";

    NSUInteger contributions =
        [[A2PluginContributionHost contributionRegistry] attachedPluginIds].count;
    if (contributions == 0) {
        return [NSString stringWithFormat:@"已安装 %lu 个", (unsigned long)count];
    }
    return [NSString stringWithFormat:@"已安装 %lu 个 · 生效贡献 %lu 个插件",
            (unsigned long)count, (unsigned long)contributions];
}

- (void)rebuildContentForIndex:(NSInteger)index {
    _currentIndex = index;
    for (UIView *v in _detailStack.arrangedSubviews) {
        [_detailStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    // 索引对应 setupNav 里的分类顺序
    if (index == 0) {
        [_detailStack addArrangedSubview:[A2GameSettings buildWithHost:self]];
        [_detailStack addArrangedSubview:[A2MemorySettings buildWithHost:self]];
        [_detailStack addArrangedSubview:[A2RuntimeSettings buildWithHost:self]];
    } else if (index == 1) {
        [_detailStack addArrangedSubview:[A2AppearanceSettings buildWithHost:self]];
        [_detailStack addArrangedSubview:[A2AppearanceSettings buildSourceSectionWithHost:self]];
        [_detailStack addArrangedSubview:[A2AppearanceSettings buildControlsSectionWithHost:self]];
    } else if (index == 2) {
        [_detailStack addArrangedSubview:[A2DiagnosticsSettings buildWithHost:self]];
        [_detailStack addArrangedSubview:[A2DiagnosticsSettings buildDuoSimSectionWithHost:self]];
        [_detailStack addArrangedSubview:[A2OnDevicePairingSettings buildWithHost:self]];
        [_detailStack addArrangedSubview:[A2JITSettings buildWithHost:self]];
        [_detailStack addArrangedSubview:[A2AboutSettings buildWithHost:self]];
    } else if (index == 3) {
        // ★插件★（P1 移植）插件系统（安装器 / 注册表 / 权限存储）的唯一 UI 入口。
        // 渲染器插件仍在「游戏 → 渲染」之外的老位置（A2RendererPluginViewController），
        // 两条线在 P1 并存、互不影响。
        A2SettingsSection *sec = [[A2SettingsSection alloc] initWithTitle:@"插件"];
        sec.footerText = @"插件的每一项能力都写在权限里。安装之后可以逐项查看、关掉或重新审查。";

        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = @"puzzlepiece.extension.fill";
        row.title = @"插件";
        row.subtitle = [self pluginSummaryText];
        row.accessory = A2SettingsRowAccessoryDisclosure;
        row.showsSeparator = NO;
        __weak typeof(self) weakSelf = self;
        row.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            A2PluginListViewController *vc = [A2PluginListViewController defaultController];
            [self.navigationController pushViewController:vc animated:YES];
        };
        [sec addRow:row];

        [_detailStack addArrangedSubview:sec];

        // ★插件插入点 ⑤★ `settings.section`：插件自己声明的设置分区（一个插件一张卡）。
        // 只挂在「插件」这一分类里 —— 用户知道去哪找；其它分类的内容与顺序不变。
        // 未装插件时 entries 为空 ⇒ 一张卡也不加。
        NSArray<A2PluginSlotContribution *> *pluginSettings =
            [A2PluginContributionHost entriesForSlot:@"settings.section"];
        for (A2SettingsSection *pluginSection in [A2PluginContributionHost sectionsForEntries:pluginSettings]) {
            [_detailStack addArrangedSubview:pluginSection];
        }
    }

    // 内容切换时淡入上浮
    _detailStack.alpha = 0;
    _detailStack.transform = CGAffineTransformMakeTranslation(0, 8);
    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationCard);
    [a addAnimations:^{
        self.detailStack.alpha = 1;
        self.detailStack.transform = CGAffineTransformIdentity;
    }];
    [a startAnimation];
}

@end
