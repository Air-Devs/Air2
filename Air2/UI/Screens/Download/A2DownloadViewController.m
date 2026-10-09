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
//  子页面之所以一行代码都不用改：它们跳转时用的是 self.navigationController，
//  这个属性会自动解析到离自己最近的那条栈 —— 也就是这里的 _contentNav。
//
//  容器自身不画顶栏：标题与返回交给右侧当前页，边栏因此能从顶部贯到底。
//

#import "A2DownloadViewController.h"
#import "A2DownloadHomeViewController.h"
#import "A2CategoryNavView.h"
#import "A2NavigationController.h"
#import "A2Metrics.h"
#import "A2Log.h"

@interface A2DownloadViewController ()
@property (nonatomic, strong) A2CategoryNavView *nav;
@property (nonatomic, strong) A2NavigationController *contentNav;
@property (nonatomic, strong) A2DownloadHomeViewController *home;
@end

@implementation A2DownloadViewController

- (void)viewDidLoad {
    // 必须写在 super 之前：基类在 [super viewDidLoad] 里就按它决定建 scroll 还是
    // plain 内容容器。晚设会让 plainContentView 一直是 nil。
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.hidesTopBar = YES;

    __weak typeof(self) weakSelf = self;

    _home = [[A2DownloadHomeViewController alloc] init];
    // 栈底页再返回就是出下载区了，所以要退外层栈，而不是在内层栈里 pop。
    _home.onBack = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self.navigationController popViewControllerAnimated:YES];
    };

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
    _contentNav = [[A2NavigationController alloc] initWithRootViewController:_home];
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
    // 先退回栈底再换内容：否则上一个分类的二级页面会继续压在栈上，
    // 与边栏的选中项对不上，用户看到的内容和点亮的分类是两回事。
    if (_contentNav.viewControllers.count > 1) {
        [_contentNav popToRootViewControllerAnimated:NO];
    }
    [_home showCategoryAtIndex:index];
}

@end
