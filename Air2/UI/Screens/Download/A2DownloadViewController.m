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
//  下载中心容器 —— 左侧分类边栏常驻 + 右侧内层导航栈。
//
//  为什么要有这一层：
//  以前下载的分类边栏长在「下载」这一页里，一旦跳进选版页/资源搜索，
//  整页被替换，边栏就跟着消失了，用户得先退回来才能换分类。
//  把边栏提到容器层、右侧塞一条独立导航栈之后，下载区内的任何子页面
//  都活在右边这条栈上，边栏始终在，且只有下载区（及其子页面）能看到它。
//
//  选中分类即直达该分类的内容页（版本清单 / 资源搜索 / 按 ID / 收藏）——
//  不再经过中间那层「只放一个入口按钮」的落地页，少一次无意义的点击。
//  内容页按分类缓存：切走再切回时保留搜索词、已拉到的清单，
//  也避免每次切分类都重新拉一遍版本清单。
//
//  子页面之所以一行代码都不用改：它们跳转时用的是 self.navigationController，
//  这个属性会自动解析到离自己最近的那条栈 —— 也就是这里的 _contentNav。
//
//  容器自身不画顶栏：标题与返回交给右侧当前页，边栏因此能从顶部贯到底。
//

#import "A2DownloadViewController.h"
#import "A2BaseViewController.h"
#import "A2CategoryNavView.h"
#import "A2NavigationController.h"
#import "A2GameVersionListViewController.h"
#import "A2DownloadListViewController.h"
#import "A2SearchByIdViewController.h"
#import "A2FavoritesViewController.h"
#import "A2Metrics.h"
#import "A2Log.h"

@interface A2DownloadViewController ()
@property (nonatomic, strong) A2CategoryNavView *nav;
@property (nonatomic, strong) A2NavigationController *contentNav;
/// 分类索引 → 内容页。切走再切回时复用，保留状态、避免重复拉网络。
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIViewController *> *contentCache;
@end

@implementation A2DownloadViewController

- (void)viewDidLoad {
    // 必须写在 super 之前：基类在 [super viewDidLoad] 里就按它决定建 scroll 还是
    // plain 内容容器。晚设会让 plainContentView 一直是 nil。
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.hidesTopBar = YES;

    _contentCache = [NSMutableDictionary dictionary];

    [self setupCategoryNav];
    [self setupContentNav];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        // 边栏贴安全区上沿，避免横屏刘海压住第一项
        [_nav.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_nav.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_nav.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:A2SpaceS],

        // 右侧内容区贯满高度：子页面自己会把顶栏贴到安全区上沿，
        // 于是内层顶栏与边栏顶部在视觉上对齐。
        [_contentNav.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_contentNav.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_contentNav.view.leadingAnchor constraintEqualToAnchor:_nav.trailingAnchor
                                                      constant:A2SpaceM],
        [_contentNav.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    [_nav selectIndex:0 animated:NO];
}

#pragma mark - 装配

- (void)setupCategoryNav {
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
        [self selectCategoryAtIndex:index];
    };
    [self.view addSubview:_nav];
}

- (void)setupContentNav {
    // 内层栈需要栈底页，直接拿第一个分类的内容页当栈底。
    UIViewController *first = [self contentViewControllerForIndex:0];
    _contentNav = [[A2NavigationController alloc] initWithRootViewController:first];
    _contentNav.view.translatesAutoresizingMaskIntoConstraints = NO;
    // 背景透出去，让子页面自己的背景图/渐变与整体连成一片
    _contentNav.view.backgroundColor = UIColor.clearColor;
    [self addChildViewController:_contentNav];
    [self.view addSubview:_contentNav.view];
    [_contentNav didMoveToParentViewController:self];
}

#pragma mark - 分类切换

- (void)selectCategoryAtIndex:(NSInteger)index {
    [A2Log log:@"download: 切换分类 index=%ld", (long)index];
    UIViewController *vc = [self contentViewControllerForIndex:index];
    // 直接把该分类的内容页设为栈底：上一个分类的二级页面随栈一并换掉，
    // 免得看到的内容和点亮的分类对不上。
    [_contentNav setViewControllers:@[vc] animated:NO];
}

/// 取（或首次创建）某分类的内容页。
- (UIViewController *)contentViewControllerForIndex:(NSInteger)index {
    NSNumber *key = @(index);
    UIViewController *cached = _contentCache[key];
    if (cached) return cached;

    UIViewController *vc = [self makeContentViewControllerForIndex:index];
    // 内容页是内层栈的栈底，再返回就是出下载区了，所以退外层栈，而不是内层 pop。
    if ([vc isKindOfClass:A2BaseViewController.class]) {
        __weak typeof(self) weakSelf = self;
        ((A2BaseViewController *)vc).onBack = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self.navigationController popViewControllerAnimated:YES];
        };
    }
    _contentCache[key] = vc;
    return vc;
}

/// 分类索引 → 内容页。索引与 setupCategoryNav 的顺序一一对应。
- (UIViewController *)makeContentViewControllerForIndex:(NSInteger)index {
    switch (index) {
        case 0:
            return [[A2GameVersionListViewController alloc] init];
        case 6:
            return [[A2SearchByIdViewController alloc] init];
        case 7:
            return [[A2FavoritesViewController alloc] init];
        default: {
            A2DownloadListViewController *vc = [[A2DownloadListViewController alloc] init];
            vc.category = [self resourceCategoryForIndex:index];
            return vc;
        }
    }
}

/// 资源类分类（整合包 / 模组 / 资源包 / 存档 / 光影）→ 资源分类枚举。
- (A2DownloadCategory)resourceCategoryForIndex:(NSInteger)index {
    switch (index) {
        case 1: return A2DownloadCategoryModpack;
        case 2: return A2DownloadCategoryMod;
        case 3: return A2DownloadCategoryResourcePack;
        case 4: return A2DownloadCategoryWorld;
        case 5: return A2DownloadCategoryShader;
        default: return A2DownloadCategoryMod;
    }
}

@end
