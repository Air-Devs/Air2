//
//  A2RootViewController.m
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
//
//  根容器 —— 承载导航栈与全局浮层（任务抽屉）。
//  同时负责方向锁定，保证从启动器到游戏全程横屏。
//

#import "A2RootViewController.h"
#import "A2LauncherViewController.h"
#import "A2NavigationController.h"
#import "A2TaskDrawer.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

@interface A2RootViewController ()
@property (nonatomic, strong) A2NavigationController *nav;
@property (nonatomic, strong) A2LauncherViewController *launcher;
@property (nonatomic, strong) A2TaskDrawer *taskDrawer;
@property (nonatomic, strong) UIView *surfaceBackdrop;
@end

@implementation A2RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 主题的表面色作为最底层，卡片与背景浮在它上面
    self.view.backgroundColor = A2ThemeManager.shared.scheme.cSurface;

    _launcher = [[A2LauncherViewController alloc] init];
    _nav = [[A2NavigationController alloc] initWithRootViewController:_launcher];
    _nav.view.translatesAutoresizingMaskIntoConstraints = NO;
    _nav.view.backgroundColor = UIColor.clearColor;

    [self addChildViewController:_nav];
    [self.view addSubview:_nav.view];
    [NSLayoutConstraint activateConstraints:@[
        [_nav.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_nav.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_nav.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_nav.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
    [_nav didMoveToParentViewController:self];

    [self setupTaskDrawer];
    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 系统外观变化

/// 系统亮暗切换时，通知全应用重新取色。
///
/// 为什么必须显式处理：
/// 我们的色板是按 isDark 解析具体色值的，不是 UIColor 动态颜色，
/// 所以系统切换外观不会自动更新已渲染的视图。
/// 不处理的话，用户在系统设置里切暗色，App 界面不变
///（要杀进程重启才生效）。
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];

    if (previousTraitCollection &&
        previousTraitCollection.userInterfaceStyle == self.traitCollection.userInterfaceStyle) {
        return;   // 外观没变，不处理
    }

    // 走和「用户手动切主题」同一条路径，保证行为一致
    [A2ThemeManager.shared notifyThemeChanged];
    [self applyTheme];
}

#pragma mark - 任务抽屉

- (void)setupTaskDrawer {
    _taskDrawer = [[A2TaskDrawer alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_taskDrawer];

    NSLayoutConstraint *height = [_taskDrawer.heightAnchor constraintEqualToConstant:56];
    _taskDrawer.heightConstraint = height;

    [NSLayoutConstraint activateConstraints:@[
        [_taskDrawer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_taskDrawer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_taskDrawer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        height,
    ]];

    // 无任务时收起在屏幕外
    _taskDrawer.alpha = 0;
    _taskDrawer.transform = CGAffineTransformMakeTranslation(0, 86);
}

#pragma mark - 主题

- (void)applyTheme {
    self.view.backgroundColor = A2ThemeManager.shared.scheme.cSurface;
}

#pragma mark - 方向与状态栏

/// 横屏下状态栏本来就不显示，直接隐藏，把空间还给内容
- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (BOOL)shouldAutorotate {
    return NO;
}

@end
