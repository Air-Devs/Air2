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
#import "A2RendererSettingsViewController.h"
#import "A2DiagnosticsSettings.h"

@interface A2SettingsViewController ()
@property (nonatomic, strong) A2CategoryNavView *nav;
@property (nonatomic, strong) UIScrollView *detailScroll;
@property (nonatomic, strong) UIStackView *detailStack;
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
    // 分类顺序参考 ZL2：渲染在前（最常用）
    NSArray<A2NavCategory *> *cats = @[
        [A2NavCategory title:@"渲染" symbol:@"video.fill"],
        [A2NavCategory title:@"游戏" symbol:@"gamecontroller.fill"],
        [A2NavCategory title:@"外观" symbol:@"paintpalette.fill"],
        [A2NavCategory title:@"诊断" symbol:@"stethoscope"],
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
        [_detailStack.trailingAnchor constraintEqualToAnchor:_detailScroll.trailingAnchor
                                                     constant:-A2SpaceXL],
    ]];

    [_nav selectIndex:0 animated:NO];
}

- (void)rebuildContentForIndex:(NSInteger)index {
    for (UIView *v in _detailStack.arrangedSubviews) {
        [_detailStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    // 索引对应 setupNav 里的分类顺序
    if (index == 0) {
        // 渲染：一个入口行指向渲染器选择页
        A2SettingsSection *sec = [[A2SettingsSection alloc] initWithTitle:@"渲染"];
        sec.footerText = @"不同渲染器在不同设备上表现差异明显，建议逐个尝试后选择最稳定的一个。";

        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = @"video.fill";
        row.title = @"渲染器";
        row.subtitle = @"选择图形渲染后端，或导入渲染器插件";
        row.accessory = A2SettingsRowAccessoryDisclosure;
        row.showsSeparator = NO;
        __weak typeof(self) weakSelf = self;
        row.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            A2RendererSettingsViewController *vc =
                [[A2RendererSettingsViewController alloc] init];
            [self.navigationController pushViewController:vc animated:YES];
        };
        [sec addRow:row];
        [_detailStack addArrangedSubview:sec];

    } else if (index == 1) {
        [_detailStack addArrangedSubview:[A2GameSettings buildWithHost:self]];
    } else if (index == 2) {
        [_detailStack addArrangedSubview:[A2AppearanceSettings buildWithHost:self]];
        [_detailStack addArrangedSubview:[A2AppearanceSettings buildSourceSectionWithHost:self]];
    } else if (index == 3) {
        [_detailStack addArrangedSubview:[A2DiagnosticsSettings buildWithHost:self]];
        [_detailStack addArrangedSubview:[A2AboutSettings buildWithHost:self]];
    }
}

@end
