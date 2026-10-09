//
//  A2DownloadHomeViewController.m
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
//  下载中心首屏内容 —— 分类落地 + 入口路由。
//
//  分类：
//    · 游戏          安装新版本（唯一入口，进入版本清单）
//    · 整合包/模组/资源包/存档/光影   资源搜索（Modrinth / CurseForge）
//    · 按 ID         按项目 ID 直接定位
//    · 收藏          已收藏的项目
//
//  资源来源（Modrinth / CurseForge）放在内容区顶部，不再占一整块卡片。
//
//  本页是容器右侧导航栈的栈底：它的返回要退回启动器，
//  由外层下载中心容器注入 onBack 决定，不在这里判断。
//

#import "A2DownloadHomeViewController.h"
#import "A2CurseForgeAPI.h"
#import "A2CurseForgeKeyPrompt.h"
#import "A2DownloadListViewController.h"
#import "A2GameVersionListViewController.h"
#import "A2SearchByIdViewController.h"
#import "A2FavoritesViewController.h"
#import "A2ContentSource.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2GlassCard.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Log.h"

@interface A2DownloadHomeViewController ()
@property (nonatomic, strong) UIScrollView *detailScroll;
@property (nonatomic, strong) UIStackView *detailStack;
@property (nonatomic, assign) A2ContentPlatform source;
@property (nonatomic, strong) UISegmentedControl *sourceSwitch;
@property (nonatomic, strong) UILabel *sourceHint;
@end

@implementation A2DownloadHomeViewController

- (void)viewDidLoad {
    // 必须写在 super 之前：基类在 [super viewDidLoad] 里就按它决定建 scroll 还是
    // plain 内容容器。晚设会让 plainContentView 一直是 nil。
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = @"下载";
    self.source = [A2ContentSource preferredPlatform];

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
        [_detailScroll.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_detailScroll.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_detailScroll.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor],
        [_detailScroll.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],

        [_detailStack.topAnchor constraintEqualToAnchor:_detailScroll.topAnchor constant:A2SpaceS],
        [_detailStack.bottomAnchor constraintEqualToAnchor:_detailScroll.bottomAnchor
                                                   constant:-A2SpaceXXL],
        [_detailStack.leadingAnchor constraintEqualToAnchor:_detailScroll.leadingAnchor
                                                    constant:A2PageMargin],
        [_detailStack.trailingAnchor constraintEqualToAnchor:_detailScroll.trailingAnchor
                                                     constant:-A2PageMargin],
    ]];
}

#pragma mark - 分类切换

- (void)showCategoryAtIndex:(NSInteger)index {
    // 容器可能在 view 还没上屏时就调用（push 的当帧），先确保视图已就绪，
    // 否则下面的 stack 还是 nil，内容会静默地不显示。
    [self loadViewIfNeeded];
    [self rebuildContentForIndex:index];
}

#pragma mark - 分类元信息

- (A2DownloadCategory)categoryForIndex:(NSInteger)index {
    switch (index) {
        case 1: return A2DownloadCategoryModpack;
        case 2: return A2DownloadCategoryMod;
        case 3: return A2DownloadCategoryResourcePack;
        case 4: return A2DownloadCategoryWorld;
        case 5: return A2DownloadCategoryShader;
        default: return A2DownloadCategoryMod;
    }
}

- (NSString *)titleForIndex:(NSInteger)index {
    switch (index) {
        case 1: return @"整合包";
        case 2: return @"模组";
        case 3: return @"资源包";
        case 4: return @"存档";
        case 5: return @"光影";
        default: return @"资源";
    }
}

- (NSString *)subtitleForIndex:(NSInteger)index {
    switch (index) {
        case 1: return @"一键安装完整整合包";
        case 2: return @"单模组安装";
        case 3: return @"材质与音效包";
        case 4: return @"世界存档";
        case 5: return @"光影效果";
        default: return @"搜索资源";
    }
}

- (NSString *)symbolForIndex:(NSInteger)index {
    switch (index) {
        case 1: return @"shippingbox.fill";
        case 2: return @"puzzlepiece.extension.fill";
        case 3: return @"photo.stack.fill";
        case 4: return @"map.fill";
        case 5: return @"sun.max.fill";
        default: return @"cube.fill";
    }
}

#pragma mark - 内容重建

- (void)rebuildContentForIndex:(NSInteger)index {
    [A2Log log:@"download: 切换分类 index=%ld", (long)index];

    for (UIView *v in _detailStack.arrangedSubviews) {
        [_detailStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    // 资源来源选择：仅资源类分类需要（整合包/模组/资源包/存档/光影）。
    BOOL needsSource = (index >= 1 && index <= 5);
    if (needsSource) {
        [_detailStack addArrangedSubview:[self buildSourceRow]];
    }

    if (index == 0) {
        [_detailStack addArrangedSubview:[self buildGameSection]];
    } else if (index >= 1 && index <= 5) {
        [_detailStack addArrangedSubview:[self buildResourceSectionForIndex:index]];
    } else if (index == 6) {
        [_detailStack addArrangedSubview:[self buildSearchByIdSection]];
    } else {
        [_detailStack addArrangedSubview:[self buildFavoritesSection]];
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
    A2ContentPlatform picked = (A2ContentPlatform)_sourceSwitch.selectedSegmentIndex;
    // 切 CurseForge 但无 Key：弹框要 Key，取消则回退 Modrinth，不留不可用态。
    if (picked == A2ContentPlatformCurseForge && ![A2CurseForgeAPI hasAPIKey]) {
        [A2CurseForgeKeyPrompt promptFrom:self completion:^(BOOL saved) {
            if (saved) {
                self.source = A2ContentPlatformCurseForge;
            } else {
                self.sourceSwitch.selectedSegmentIndex = 0;
                self.source = A2ContentPlatformModrinth;
            }
            self.sourceHint.text = [self hintForSource:self.source];
            [A2ContentSource setPreferredPlatform:self.source];
        }];
        return;
    }
    self.source = picked;
    _sourceHint.text = [self hintForSource:self.source];
    [A2ContentSource setPreferredPlatform:self.source];
}

/// 游戏分类：唯一入口「安装新版本」
- (UIView *)buildGameSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:nil];
    section.footerText = @"安装时可同时选择模组加载器，会自动匹配对应的游戏版本。";

    A2SettingsRow *gameRow = [[A2SettingsRow alloc] init];
    gameRow.symbolName = @"cube.fill";
    gameRow.title = @"安装新版本";
    gameRow.subtitle = @"选择游戏版本与模组加载器";
    gameRow.accessory = A2SettingsRowAccessoryDisclosure;
    __weak typeof(self) weakSelf = self;
    gameRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self openGameVersions];
    };
    [section addRow:gameRow];

    return section;
}

/// 资源分类：搜索入口
- (UIView *)buildResourceSectionForIndex:(NSInteger)index {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:nil];
    section.footerText = @"资源来自 Modrinth / CurseForge 公共仓库。";

    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = [self symbolForIndex:index];
    row.title = [self titleForIndex:index];
    row.subtitle = [self subtitleForIndex:index];
    row.accessory = A2SettingsRowAccessoryDisclosure;

    A2DownloadCategory category = [self categoryForIndex:index];
    __weak typeof(self) weakSelf = self;
    row.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self openListWithCategory:category];
    };
    [section addRow:row];

    return section;
}

/// 按 ID：进入 ID 直查页
- (UIView *)buildSearchByIdSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:nil];
    section.footerText = @"粘贴 Modrinth 项目 ID / slug，或 CurseForge 的 mod ID。";

    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = @"number";
    row.title = @"按 ID 查询";
    row.subtitle = @"已知项目 ID 直接定位";
    row.accessory = A2SettingsRowAccessoryDisclosure;
    __weak typeof(self) weakSelf = self;
    row.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self openSearchById];
    };
    [section addRow:row];

    return section;
}

/// 收藏：进入收藏列表
- (UIView *)buildFavoritesSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:nil];
    section.footerText = @"在资源详情页点「收藏」即可加入这里。";

    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = @"star.fill";
    row.title = @"我的收藏";
    row.subtitle = @"已收藏的项目";
    row.accessory = A2SettingsRowAccessoryDisclosure;
    __weak typeof(self) weakSelf = self;
    row.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self openFavorites];
    };
    [section addRow:row];

    return section;
}

#pragma mark - 路由
//
// 这里一律用 self.navigationController：本页挂在容器的内层导航栈上，
// 于是「下载的全部子页面」天然共享同一条栈，左侧边栏得以常驻。
// 子页面同理不需要改任何跳转代码。

- (void)openGameVersions {
    [A2Log log:@"download: 打开版本清单（安装新版本）"];
    A2GameVersionListViewController *vc = [[A2GameVersionListViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openListWithCategory:(A2DownloadCategory)category {
    // 游戏走版本清单+安装器链路，不进资源搜索。
    if (category == A2DownloadCategoryGame) {
        [self openGameVersions];
        return;
    }
    [A2Log log:@"download: 打开资源搜索 category=%ld", (long)category];
    A2DownloadListViewController *vc = [[A2DownloadListViewController alloc] init];
    vc.category = category;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openSearchById {
    [A2Log log:@"download: 打开按 ID 查询"];
    A2SearchByIdViewController *vc = [[A2SearchByIdViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openFavorites {
    [A2Log log:@"download: 打开收藏列表"];
    A2FavoritesViewController *vc = [[A2FavoritesViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
