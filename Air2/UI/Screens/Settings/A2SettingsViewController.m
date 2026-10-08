//
//  A2SettingsViewController.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
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

@interface A2SettingsViewController ()
@property (nonatomic, strong) A2CategoryNavView *nav;
@property (nonatomic, strong) UIScrollView *detailScroll;
@property (nonatomic, strong) UIStackView *detailStack;
@end

@implementation A2SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.usesScrollContent = NO;
    self.pageTitle = @"设置";

    // 目前只有「外观」一个分类 —— 其余等对应功能实现后再加。
    // 见 A2SettingsSections.h 的说明。
    NSArray<A2NavCategory *> *cats = @[
        [A2NavCategory title:@"外观" symbol:@"paintpalette.fill"],
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

    if (index == 0) {
        [_detailStack addArrangedSubview:[A2AppearanceSettings buildWithHost:self]];
        [_detailStack addArrangedSubview:[A2AppearanceSettings buildSourceSectionWithHost:self]];
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
