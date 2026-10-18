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
#import "A2ResourceSearchViewController.h"
#import "A2AggregateSearchViewController.h"   // 聚合搜索页（Modrinth + CurseForge 同屏）
#import "A2ModPackImportViewController.h"
#import "A2SearchByIdViewController.h"
#import "A2FavoritesViewController.h"
#import "A2DownloadTasksViewController.h"
#import "A2Metrics.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Log.h"

#pragma mark - 加载占位页

/// 首次进入某分类时的占位页。
///
/// 为什么需要它：内容页的 viewDidLoad 要建整套筛选卡 / 表格并发网络请求，
/// 这一帧在主线程上做完之前，用户点完左栏只看到「没反应」（批注：切换有点卡顿）。
/// 先把这页塞进右侧栈、让本次 runloop 结束去渲染（左栏转圈同时亮起），
/// 内容页的构建留到下一轮主循环 —— 反馈与重活不再抢同一帧。
@interface A2CategoryLoadingViewController : UIViewController
@end

@implementation A2CategoryLoadingViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = A2ThemeManager.shared.scheme.cSurface;

    UIActivityIndicatorView *spinner =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.color = A2ThemeManager.shared.scheme.cPrimary;
    [spinner startAnimating];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [A2Typography caption];
    label.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    label.text = @"正在加载…";

    [self.view addSubview:spinner];
    [self.view addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-16],
        [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [label.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:A2SpaceS],
    ]];
}

@end

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
        // 图标名必须在最低支持系统（iOS 14）上存在，否则 systemImageNamed: 返回 nil、
        // 侧栏该项只剩文字（用户批注：这两项缺图标）。原来「游戏」用 sports.esports、
        // 「资源包」用 photo.stack.fill，两者都是 SF Symbols 4（iOS 16 起）才有的符号，
        // 在 iPad7,11 / iOS 15.4.1 上取不到图。换成 iOS 13 就存在的等价符号。
        [A2NavCategory title:@"游戏"   symbol:@"gamecontroller.fill"],
        [A2NavCategory title:@"整合包" symbol:@"shippingbox.fill"],
        [A2NavCategory title:@"模组"   symbol:@"puzzlepiece.extension.fill" division:YES],
        [A2NavCategory title:@"资源包" symbol:@"rectangle.stack.fill"],
        [A2NavCategory title:@"数据包" symbol:@"doc.text.fill"],
        [A2NavCategory title:@"存档"   symbol:@"map.fill"],
        [A2NavCategory title:@"光影"   symbol:@"sun.max.fill"],
        [A2NavCategory title:@"按 ID"  symbol:@"number" division:YES],
        [A2NavCategory title:@"收藏"   symbol:@"star.fill"],
        [A2NavCategory title:@"导入"   symbol:@"square.and.arrow.down" division:YES],
        [A2NavCategory title:@"任务"   symbol:@"arrow.down.circle.fill"],
        // ★聚合搜索★：一个界面同时检索 Modrinth 与 CurseForge。
        //   放在列表末尾而不是插在「模组」后面 —— 分类索引与
        //   `-makeContentViewControllerForIndex:` 是按位置一一对应的，
        //   插队会平移后面所有 case；追加不动任何既有映射。
        [A2NavCategory title:@"聚合"   symbol:@"square.grid.2x2.fill" division:YES],
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

    // 已建过的页直接换：切回来是瞬时的，不需要加载态。
    UIViewController *cached = _contentCache[@(index)];
    if (cached) {
        [_nav setLoadingIndex:-1];
        [_contentNav setViewControllers:@[cached] animated:NO];
        return;
    }

    // ★首建分类★：先亮左栏转圈 + 右侧「正在加载…」占位，
    // 把内容页构建推到下一轮主循环（见 A2CategoryLoadingViewController 的说明）。
    [_nav setLoadingIndex:index];
    [_contentNav setViewControllers:@[[A2CategoryLoadingViewController new]] animated:NO];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // 这一轮里用户可能又点了别的分类：只认当前选中的那个。
        if (self.nav.selectedIndex != index) return;
        UIViewController *vc = [self contentViewControllerForIndex:index];
        [self.contentNav setViewControllers:@[vc] animated:NO];
        [self.nav setLoadingIndex:-1];
    });
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
///
/// 所有资源类（含整合包）统一走 A2ResourceSearchViewController ——
/// 之前整合包单独用旧的 A2DownloadListViewController，
/// 那套页面没接真实 API 与新的详情页，是被遗漏的一条链路。
/// 整合包在详情页里有专门的安装流程。
- (UIViewController *)makeContentViewControllerForIndex:(NSInteger)index {
    switch (index) {
        case 0:
            return [[A2GameVersionListViewController alloc] init];
        case 1:
            return [[A2ResourceSearchViewController alloc]
                    initWithContentClass:A2ContentClassModPack];
        case 2:
            return [[A2ResourceSearchViewController alloc]
                    initWithContentClass:A2ContentClassMod];
        case 3:
            return [[A2ResourceSearchViewController alloc]
                    initWithContentClass:A2ContentClassResourcePack];
        case 4:
            return [[A2ResourceSearchViewController alloc]
                    initWithContentClass:A2ContentClassDataPack];
        case 5:
            return [[A2ResourceSearchViewController alloc]
                    initWithContentClass:A2ContentClassWorld];
        case 6:
            return [[A2ResourceSearchViewController alloc]
                    initWithContentClass:A2ContentClassShader];
        case 7:
            return [[A2SearchByIdViewController alloc] init];
        case 8:
            return [[A2FavoritesViewController alloc] init];
        case 9:
            return [[A2ModPackImportViewController alloc] init];
        case 10:
            return [[A2DownloadTasksViewController alloc] init];
        case 11:
            // 「聚合」分类：把 Modrinth + CurseForge 放进同一个检索页（默认模组档位；
            // 资源包/光影/数据包/整合包各有自己的分类入口，本页不重复摊开）
            return [[A2AggregateSearchViewController alloc]
                    initWithContentClass:A2ContentClassMod];
        default:
            return [[A2ResourceSearchViewController alloc]
                    initWithContentClass:A2ContentClassMod];
    }
}

@end
