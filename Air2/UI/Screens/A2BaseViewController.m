//
//  A2BaseViewController.m
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

#import "A2BaseViewController.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2BaseViewController ()
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIStackView *trailingStack;
@property (nonatomic, strong) UIScrollView *scrollViewInternal;
@property (nonatomic, strong) UIStackView *contentStackInternal;
@property (nonatomic, strong) UIView *plainContentViewInternal;
@property (nonatomic, assign) BOOL didSetupConstraints;
@property (nonatomic, strong) NSMapTable<UIButton *, void (^)(void)> *buttonActions;
@end

@implementation A2BaseViewController

#pragma mark - 生命周期

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _trailingButtons = [NSMutableArray array];
    _buttonActions = [NSMapTable strongToStrongObjectsMapTable];
    _usesScrollContent = YES;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // ★二级页面底板 = MD3 不透明 surface★
    // 这里刻意不挂「壁纸 + 模糊」那层组件：它本身就是玻璃的载体，
    // 二级选择界面一律 MD3（实心表面 + 卡片 tonal 层级），一级页面才用玻璃。
    // 见 docs/DECISIONS.md「二级界面改 MD3、去玻璃」。
    self.view.backgroundColor = A2ThemeManager.shared.scheme.cSurface;

    [self setupTopBar];

    if (_usesScrollContent) {
        [self setupScrollContent];
    } else {
        [self setupPlainContent];
    }

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

#pragma mark - 顶栏

- (void)setupTopBar {
    _topBar = [[UIView alloc] initWithFrame:CGRectZero];
    _topBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_topBar];

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    _backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _backButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_backButton setImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:cfg]
                 forState:UIControlStateNormal];
    [_backButton addTarget:self action:@selector(handleBack) forControlEvents:UIControlEventTouchUpInside];
    [_topBar addSubview:_backButton];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [_topBar addSubview:_titleLabel];

    _trailingStack = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    _trailingStack.translatesAutoresizingMaskIntoConstraints = NO;
    _trailingStack.axis = UILayoutConstraintAxisHorizontal;
    _trailingStack.spacing = A2SpaceXS;
    [_topBar addSubview:_trailingStack];
}

- (void)setPageTitle:(NSString *)pageTitle {
    _pageTitle = [pageTitle copy];
    _titleLabel.text = pageTitle;
}

- (void)setHidesTopBar:(BOOL)hidesTopBar {
    _hidesTopBar = hidesTopBar;
    _topBar.hidden = hidesTopBar;
}

- (void)setLeadingCustomView:(UIView *)leadingCustomView {
    if (_leadingCustomView) [_leadingCustomView removeFromSuperview];
    _leadingCustomView = leadingCustomView;
    if (!leadingCustomView) return;
    leadingCustomView.translatesAutoresizingMaskIntoConstraints = NO;
    [_topBar addSubview:leadingCustomView];
    [NSLayoutConstraint activateConstraints:@[
        [leadingCustomView.leadingAnchor constraintEqualToAnchor:_topBar.leadingAnchor constant:A2SpaceM],
        [leadingCustomView.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    ]];
}

- (UIButton *)addTrailingButtonWithSymbol:(NSString *)symbolName action:(void (^)(void))action {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:symbolName withConfiguration:cfg] forState:UIControlStateNormal];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [b.widthAnchor constraintEqualToConstant:A2MinTouchTarget],
        [b.heightAnchor constraintEqualToConstant:A2MinTouchTarget],
    ]];
    if (action) [_buttonActions setObject:[action copy] forKey:b];
    [b addTarget:self action:@selector(handleTrailingButton:) forControlEvents:UIControlEventTouchUpInside];
    [_trailingStack addArrangedSubview:b];
    [_trailingButtons addObject:b];
    return b;
}

- (void)handleTrailingButton:(UIButton *)sender {
    void (^action)(void) = [_buttonActions objectForKey:sender];
    if (action) action();
}

- (void)handleBack {
    if (self.onBack) {
        self.onBack();
        return;
    }
    if (self.navigationController) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - 内容容器

- (void)setupScrollContent {
    _scrollViewInternal = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scrollViewInternal.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollViewInternal.showsVerticalScrollIndicator = NO;
    _scrollViewInternal.showsHorizontalScrollIndicator = NO;
    _scrollViewInternal.alwaysBounceVertical = YES;
    // 二级页面只应垂直滚动。禁用水平方向有两个作用：
    //   1. 即使某处子视图意外撑宽内容，也不会出现"左滑才能看到右边"
    //   2. 内容宽度被钳到可视区宽，超出部分由内层视图自己压缩
    _scrollViewInternal.alwaysBounceHorizontal = NO;
    _scrollViewInternal.directionalLockEnabled = YES;
    _scrollViewInternal.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_scrollViewInternal];

    _contentStackInternal = [[UIStackView alloc] initWithFrame:CGRectZero];
    _contentStackInternal.translatesAutoresizingMaskIntoConstraints = NO;
    _contentStackInternal.axis = UILayoutConstraintAxisVertical;
    _contentStackInternal.spacing = A2SpaceL;
    [_scrollViewInternal addSubview:_contentStackInternal];
}

- (void)setupPlainContent {
    _plainContentViewInternal = [[UIView alloc] initWithFrame:CGRectZero];
    _plainContentViewInternal.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_plainContentViewInternal];
}

- (UIScrollView *)scrollView {
    return _scrollViewInternal;
}

- (UIStackView *)contentStack {
    return _contentStackInternal;
}

- (UIView *)plainContentView {
    return _plainContentViewInternal;
}

- (void)addSection:(UIView *)section {
    if (_contentStackInternal) {
        [_contentStackInternal addArrangedSubview:section];
    }
}

#pragma mark - 约束

- (void)updateViewConstraints {
    if (_didSetupConstraints) {
        [super updateViewConstraints];
        return;
    }
    _didSetupConstraints = YES;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSMutableArray *constraints = [NSMutableArray array];

    [constraints addObjectsFromArray:@[
        [_topBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_topBar.heightAnchor constraintEqualToConstant:A2TopBarHeight],

        [_backButton.leadingAnchor constraintEqualToAnchor:_topBar.leadingAnchor constant:A2SpaceS],
        [_backButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
        [_backButton.widthAnchor constraintEqualToConstant:A2MinTouchTarget],
        [_backButton.heightAnchor constraintEqualToConstant:A2MinTouchTarget],

        [_titleLabel.centerXAnchor constraintEqualToAnchor:_topBar.centerXAnchor],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
        [_titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_backButton.trailingAnchor constant:A2SpaceS],

        [_trailingStack.trailingAnchor constraintEqualToAnchor:_topBar.trailingAnchor constant:-A2SpaceM],
        [_trailingStack.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_trailingStack.leadingAnchor constant:-A2SpaceS],
    ]];

    UIView *contentBelow = _topBar;
    if (_scrollViewInternal) {
        // ScrollView 内的自动布局有个经典坑：
        // 内容视图不能同时用 frame 约束（leading/trailing/width）
        // 和 content 约束（top/bottom）混着来，否则布局会塌。
        //
        // 正确做法：
        //   contentLayoutGuide  —— 管滚动内容的尺寸（top/bottom/leading/trailing）
        //   frameLayoutGuide    —— 管可视区域（用来定宽）
        UILayoutGuide *content = _scrollViewInternal.contentLayoutGuide;
        UILayoutGuide *frame = _scrollViewInternal.frameLayoutGuide;

        // ScrollView 内容布局的正确写法：
        //   【宽度用 frameLayoutGuide】—— 可视区宽度，与内容无关，恒定可解
        //   【垂直用 contentLayoutGuide】—— 决定可滚动范围
        //
        // 之前把 leading/trailing 约束到 contentLayoutGuide，那是错的：
        // content guide 的宽度本来就由内容决定，再反向约束内容会形成
        // 循环依赖。布局器只能给近似解，表现就是内容左右偏移、
        // 右侧被推出屏幕（截图里文案左边被切、chip 只露半截）。
        NSLayoutConstraint *contentWidth =
            [_contentStackInternal.widthAnchor constraintEqualToAnchor:frame.widthAnchor
                                                             constant:-A2PageMargin * 2];
        // 宽屏（iPad 横屏）时限宽，避免一行文字横跨太久
        NSLayoutConstraint *maxWidth =
            [_contentStackInternal.widthAnchor constraintLessThanOrEqualToConstant:A2ContentMaxWidth];
        maxWidth.priority = UILayoutPriorityRequired - 1;

        [constraints addObjectsFromArray:@[
            [_scrollViewInternal.topAnchor constraintEqualToAnchor:contentBelow.bottomAnchor],
            [_scrollViewInternal.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [_scrollViewInternal.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [_scrollViewInternal.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

            // 垂直：贴合 contentLayoutGuide，决定可滚动范围
            [_contentStackInternal.topAnchor constraintEqualToAnchor:content.topAnchor
                                                            constant:A2SpaceS],
            [_contentStackInternal.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                                               constant:-A2SpaceXXL],

            // 水平：居中 + 固定宽度（相对可视区）
            [_contentStackInternal.centerXAnchor constraintEqualToAnchor:frame.centerXAnchor],
            contentWidth,
            maxWidth,
        ]];

    } else if (_plainContentViewInternal) {
        [constraints addObjectsFromArray:@[
            [_plainContentViewInternal.topAnchor constraintEqualToAnchor:contentBelow.bottomAnchor],
            [_plainContentViewInternal.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [_plainContentViewInternal.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [_plainContentViewInternal.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        ]];
    }

    [NSLayoutConstraint activateConstraints:constraints];
    [super updateViewConstraints];
}

#pragma mark - 主题

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    // 页面底板跟随主题的 surface —— 二级页面没有壁纸层，主题切换只换这一个色
    self.view.backgroundColor = t.cSurface;
    _titleLabel.textColor = t.cOnSurface;
    // 顶栏控件跟随背景深浅：亮底用深色、暗底用浅色（onSurface 已按模式解析），
    // 写死白色在亮色纯色背景下会看不见。
    _backButton.tintColor = t.cOnSurface;
    for (UIButton *b in _trailingButtons) {
        b.tintColor = t.cOnSurface;
    }
}

@end
