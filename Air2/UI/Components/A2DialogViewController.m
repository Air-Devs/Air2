//
//  A2DialogViewController.m
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

#import "A2DialogViewController.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2DialogViewController ()

@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, strong) A2GlassCard *card;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) NSLayoutConstraint *cardWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *cardCenterYConstraint;

@property (nonatomic, copy, nullable) void (^cancelHandler)(void);
@property (nonatomic, copy, nullable) void (^confirmHandler)(void);

@property (nonatomic, assign) BOOL dismissing;

@end

@implementation A2DialogViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        _maxCardWidth = 460.0;
        _dismissOnBackdropTap = YES;
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.clearColor;

    [self buildChrome];
    [self buildTitleLabel];
    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleThemeChanged)
                                               name:A2ThemeDidChangeNotification
                                             object:nil];
}

#pragma mark - 弹窗外壳

/// 遮罩 + 卡片 + 滚动区 + 内容栈
- (void)buildChrome {
    UIView *backdrop = [[UIView alloc] initWithFrame:CGRectZero];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    [backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleBackdropTap)]];
    [self.view addSubview:backdrop];
    _backdrop = backdrop;

    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationHighest;
    card.contentInsets = UIEdgeInsetsMake(A2SpaceXL, A2SpaceXL, A2SpaceXL, A2SpaceXL);
    [self.view addSubview:card];
    _card = card;

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsVerticalScrollIndicator = NO;
    scrollView.alwaysBounceVertical = NO;
    [card.contentView addSubview:scrollView];
    _scrollView = scrollView;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = A2SpaceL;
    [scrollView addSubview:stack];
    _contentStack = stack;

    _cardWidthConstraint = [card.widthAnchor constraintEqualToConstant:self.maxCardWidth];

    // 竖直居中用「非必需」优先级：有键盘时让位给键盘避让约束，
    // 卡片被压下高度时由内部滚动区消化，而不是把按钮顶出屏幕。
    _cardCenterYConstraint = [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor];
    _cardCenterYConstraint.priority = 750;

    [NSLayoutConstraint activateConstraints:@[
        [backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        _cardCenterYConstraint,
        [card.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor multiplier:0.92],
        [card.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.topAnchor constant:A2SpaceL],
        // keyboardLayoutGuide 键盘弹起时上移，收起时贴在视图底部（含安全区），
        // 因此这一条约束在两种状态下都成立，无需监听键盘通知。
        [card.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor
                                                   constant:-A2SpaceL],

        [scrollView.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],

        [stack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor],
    ]];

    // 让卡片高度贴合内容；内容超出可用高度时（低优先级被压过）内部滚动
    NSLayoutConstraint *hugContent = [scrollView.heightAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.heightAnchor];
    hugContent.priority = UILayoutPriorityDefaultLow;
    hugContent.active = YES;

    _cardWidthConstraint.active = YES;
}

- (void)buildTitleLabel {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.numberOfLines = 0;
    label.font = [A2Typography titleCard];
    label.text = self.titleText;
    label.hidden = (self.titleText.length == 0);
    [_contentStack addArrangedSubview:label];
    _titleLabel = label;
}

- (void)setTitleText:(NSString *)titleText {
    _titleText = [titleText copy];
    _titleLabel.text = _titleText;
    _titleLabel.hidden = (_titleText.length == 0);
}

#pragma mark - 按钮行

- (void)addButtonRowWithCancelTitle:(NSString *)cancelTitle
                       cancelAction:(void (^)(void))cancelAction
                       confirmTitle:(NSString *)confirmTitle
                      confirmAction:(void (^)(void))confirmAction {
    if (cancelTitle.length == 0 && confirmTitle.length == 0) {
        return;
    }

    // 允许调用方在 present 之前就配置按钮行：这里先确保视图已加载，
    // 否则 contentStack 还没建好，按钮会加到一个 nil 上。
    [self loadViewIfNeeded];

    self.cancelHandler = cancelAction;
    self.confirmHandler = confirmAction;

    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentFill;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = A2SpaceM;

    if (cancelTitle.length > 0) {
        A2PrimaryButton *cancelButton = [[A2PrimaryButton alloc] initWithTitle:cancelTitle style:A2ButtonStyleSecondary];
        cancelButton.minHeight = A2ButtonHeight;
        [cancelButton addTarget:self action:@selector(cancelDialog) forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:cancelButton];
    }

    if (confirmTitle.length > 0) {
        A2PrimaryButton *confirmButton = [[A2PrimaryButton alloc] initWithTitle:confirmTitle style:A2ButtonStylePrimary];
        confirmButton.minHeight = A2ButtonHeight;
        [confirmButton addTarget:self action:@selector(confirmDialog) forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:confirmButton];
    }

    [_contentStack addArrangedSubview:row];
}

- (void)cancelDialog {
    // 先把回调拷出来：弹窗关闭后 self 可能被释放
    void (^handler)(void) = self.cancelHandler;
    [self dismissDialogWithCompletion:^{
        if (handler) {
            handler();
        }
    }];
}

- (void)confirmDialog {
    void (^handler)(void) = self.confirmHandler;
    [self dismissDialogWithCompletion:^{
        if (handler) {
            handler();
        }
    }];
}

#pragma mark - 展示与关闭

- (void)presentOver:(UIViewController *)host {
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [host presentViewController:self animated:NO completion:nil];
}

- (void)dismissDialog {
    [self dismissDialogWithCompletion:nil];
}

- (void)dismissDialogWithCompletion:(void (^)(void))completion {
    if (_dismissing) {
        return;
    }
    _dismissing = YES;

    __weak typeof(self) weakSelf = self;
    UIViewPropertyAnimator *animator = A2SpringAnimator(A2AnimDurationFast);
    [animator addAnimations:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        strongSelf.backdrop.alpha = 0.0;
        strongSelf.card.alpha = 0.0;
        strongSelf.card.transform = CGAffineTransformMakeScale(0.96, 0.96);
    }];
    [animator addCompletion:^(UIViewAnimatingPosition position) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf dismissViewControllerAnimated:NO completion:completion];
    }];
    [animator startAnimation];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _backdrop.alpha = 0.0;
    _card.alpha = 0.0;
    _card.transform = CGAffineTransformConcat(CGAffineTransformMakeTranslation(0.0, A2SpaceS),
                                              CGAffineTransformMakeScale(0.94, 0.94));
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    __weak typeof(self) weakSelf = self;
    UIViewPropertyAnimator *animator = A2SpringAnimator(A2AnimDurationCard);
    [animator addAnimations:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        strongSelf.backdrop.alpha = 1.0;
        strongSelf.card.alpha = 1.0;
        strongSelf.card.transform = CGAffineTransformIdentity;
    }];
    [animator startAnimation];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat cardWidth = MIN(self.maxCardWidth, CGRectGetWidth(self.view.bounds) * 0.92);
    if (cardWidth > 0.0 && fabs(_cardWidthConstraint.constant - cardWidth) > 0.5) {
        _cardWidthConstraint.constant = cardWidth;
    }
}

- (void)handleBackdropTap {
    if (!self.dismissOnBackdropTap) {
        return;
    }
    [self dismissDialog];
}

#pragma mark - 主题

- (void)handleThemeChanged {
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;
    _titleLabel.textColor = scheme.cOnSurface;
}

@end
