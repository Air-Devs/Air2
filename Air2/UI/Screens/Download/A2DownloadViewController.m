//
//  A2DownloadViewController.m
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
//  下载中心 —— 左侧分类导航 + 右侧内容。
//
//  结构对齐 ZL2 的 DownloadScreen：
//    ┌──────────┬──────────────────────────────────┐
//    │ 🎮 游戏   │                                  │
//    │ 📦 整合包 │  当前分类的内容                    │
//    │ 🧩 模组   │                                  │
//    │ ───────  │                                  │
//    │ 🎨 资源包 │                                  │
//    │ 🗺 存档   │                                  │
//    │ 💡 光影   │                                  │
//    │ ───────  │                                  │
//    │ # 按 ID   │                                  │
//    │ ⭐ 收藏   │                                  │
//    └──────────┴──────────────────────────────────┘
//
//  资源来源（Modrinth / CurseForge）放在内容区顶部，
//  不再占一整块卡片。
//

#import "A2DownloadViewController.h"
#import "A2CategoryNavView.h"
#import "A2DownloadListViewController.h"
#import "A2GameVersionListViewController.h"
#import "A2ContentSource.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2GlassCard.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2DownloadViewController ()
@property (nonatomic, strong) A2CategoryNavView *nav;
@property (nonatomic, strong) UIScrollView *detailScroll;
@property (nonatomic, strong) UIStackView *detailStack;
@property (nonatomic, assign) A2ContentPlatform source;
@property (nonatomic, strong) UISegmentedControl *sourceSwitch;
@property (nonatomic, strong) UILabel *sourceHint;
@end

@implementation A2DownloadViewController

- (void)viewDidLoad {
    // 必须写在 super 之前：基类在 [super viewDidLoad] 里就按它决定建 scroll 还是
    // plain 内容容器。晚设会让 plainContentView 一直是 nil。
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = @"下载";
    self.source = A2ContentPlatformModrinth;

    NSArray<A2NavCategory *> *cats = @[
        [A2NavCategory title:@"游戏"   symbol:@"sports.esports"],
        [A2NavCategory title:@"整合包" symbol:@"shippingbox.fill"],
        [A2NavCategory title:@"模组"   symbol:@"puzzlepiece.extension.fill" division:YES],
        [A2NavCategory title:@"资源包" symbol:@"photo.stack.fill"],
        [A2NavCategory title:@"存档"   symbol:@"map.fill"],
        [A2NavCategory title:@"光影"   symbol:@"sun.max.fill"],
        [A2NavCategory title:@"按 ID"  symbol:@"number" division:YES],
        [A2NavCategory title:@"收藏"   symbol:@"star.fill"],
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
    _detailStack.spacing = A2SpaceL;
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

    // 资源来源选择（仅 Modrinth / CurseForge 类分类需要）
    BOOL needsSource = (index != 0);   // 「游戏」分类不需要
    if (needsSource) {
        [_detailStack addArrangedSubview:[self buildSourceRow]];
    }

    // 「游戏」分类：安装新版本 + 模组加载器
    if (index == 0) {
        [_detailStack addArrangedSubview:[self buildGameSection]];
    } else {
        [_detailStack addArrangedSubview:[self buildResourceHint:index]];
    }

    _detailStack.alpha = 0;
    _detailStack.transform = CGAffineTransformMakeTranslation(0, 8);
    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationCard);
    [a addAnimations:^{
        self.detailStack.alpha = 1;
        self.detailStack.transform = CGAffineTransformIdentity;
    }];
    [a startAnimation];
}

/// 资源来源：一行分段控件 + 说明，不再占整块卡片
- (UIView *)buildSourceRow {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusL;
    card.elevation = A2CardElevationLow;
    card.contentInsets = UIEdgeInsetsMake(A2CardPadding + 4, A2CardPadding,
                                          A2CardPadding + 4, A2CardPadding);

    _sourceSwitch = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    _sourceSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    _sourceSwitch.selectedSegmentIndex = self.source;
    [_sourceSwitch addTarget:self action:@selector(sourceChanged)
            forControlEvents:UIControlEventValueChanged];

    _sourceHint = [[UILabel alloc] initWithFrame:CGRectZero];
    _sourceHint.translatesAutoresizingMaskIntoConstraints = NO;
    _sourceHint.font = [A2Typography caption];
    _sourceHint.numberOfLines = 0;
    _sourceHint.text = [self hintForSource:self.source];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_sourceSwitch, _sourceHint]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceM;

    [card.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];
    return card;
}

- (NSString *)hintForSource:(A2ContentPlatform)source {
    return (source == A2ContentPlatformModrinth)
        ? @"Modrinth 免费开放，无需额外配置。"
        : @"CurseForge 需要在设置中填入 API Key。";
}

- (void)sourceChanged {
    self.source = (A2ContentPlatform)_sourceSwitch.selectedSegmentIndex;
    _sourceHint.text = [self hintForSource:self.source];
}

/// 游戏分类：安装新版本 + 模组加载器
- (UIView *)buildGameSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:nil];
    section.footerText = @"安装时可同时选择模组加载器，会自动匹配对应的游戏版本。";

    A2SettingsRow *gameRow = [[A2SettingsRow alloc] init];
    gameRow.symbolName = @"cube.fill";
    gameRow.title = @"安装新版本";
    gameRow.subtitle = @"选择游戏版本与模组加载器";
    gameRow.accessory = A2SettingsRowAccessoryDisclosure;
    gameRow.onTap = ^{ [self openListWithCategory:A2DownloadCategoryGame]; };
    [section addRow:gameRow];

    return section;
}

/// 资源分类：直接给搜索入口
- (UIView *)buildResourceHint:(NSInteger)index {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:nil];

    NSArray<NSArray<NSString *> *> *names = @[
        @[@"安装新版本", @"游戏版本与加载器"],
        @[@"整合包", @"一键安装完整整合包"],
        @[@"模组", @"单模组安装"],
        @[@"资源包", @"材质与音效包"],
        @[@"存档", @"世界存档"],
        @[@"光影包", @"光影效果"],
        @[@"按 ID 下载", @"已知项目 ID 直接定位"],
        @[@"收藏夹", @"已收藏的项目"],
    ];
    NSArray<NSString *> *symbols = @[@"cube.fill", @"shippingbox.fill", @"puzzlepiece.extension.fill",
                                     @"photo.stack.fill", @"map.fill", @"sun.max.fill",
                                     @"number", @"star.fill"];

    NSUInteger i = (NSUInteger)index;
    if (i >= names.count) i = 0;

    // 按 ID（6）与收藏夹（7）尚无实现：不进列表，避免挂着羊头卖模组搜索。
    // 有实现后再把对应分支改回 openListWithCategory。
    BOOL implemented = (index >= 0 && index <= 5);

    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = symbols[i];
    row.title = names[i][0];
    row.subtitle = names[i][1];
    row.accessory = implemented ? A2SettingsRowAccessoryDisclosure : A2SettingsRowAccessoryNone;
    NSInteger captured = index;
    NSString *title = names[i][0];
    row.onTap = ^{
        __strong typeof(self) self = self;
        if (!implemented) {
            [A2Toast show:[NSString stringWithFormat:@"%@尚未实现", title] inView:self.view];
            return;
        }
        [self openListWithCategory:(A2DownloadCategory)captured];
    };
    [section addRow:row];

    return section;
}

- (void)openListWithCategory:(A2DownloadCategory)category {
    // 游戏走版本清单+安装器链路，不进资源搜索（此前错进 Modrinth 搜模组）。
    if (category == A2DownloadCategoryGame) {
        A2GameVersionListViewController *vc = [[A2GameVersionListViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    A2DownloadListViewController *vc = [[A2DownloadListViewController alloc] init];
    vc.category = category;
    [self.navigationController pushViewController:vc animated:YES];
}

@end
