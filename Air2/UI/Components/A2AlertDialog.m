//
//  A2AlertDialog.m
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
//  见头文件。实现要点：
//    · 呈现走 overFullScreen + 半透明遮罩，卡片弹簧缩放入场
//    · 正文放进可滚动容器：免责声明这类长文案不能把卡片撑出屏幕
//    · 单按钮形态（cancelTitle 为 nil）下点遮罩不关闭 —— 必须显式确认
//

#import "A2AlertDialog.h"
#import "A2PrimaryButton.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

/// 卡片最大宽度。横屏下不铺满，保持可读行宽。
static const CGFloat kA2AlertDialogMaxWidth = 420;
/// 正文区最大高度，超出则内部滚动
static const CGFloat kA2AlertDialogMaxMessageHeight = 300;

@interface A2AlertDialog ()

@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIScrollView *messageScroll;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIView *divider;
@property (nonatomic, strong, nullable) A2PrimaryButton *cancelButton;
@property (nonatomic, strong) A2PrimaryButton *confirmButton;

/// 收尾中，防止重复回调
@property (nonatomic, assign) BOOL finishing;

@end

@implementation A2AlertDialog

#pragma mark - 构建

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _confirmTitle = @"确定";
    return self;
}

+ (instancetype)dialogWithTitle:(NSString *)title
                        message:(nullable NSString *)message {
    A2AlertDialog *vc = [[A2AlertDialog alloc] init];
    vc.titleText = title;
    vc.messageText = message;
    return vc;
}

+ (void)presentFrom:(UIViewController *)host
              title:(NSString *)title
            message:(nullable NSString *)message
       confirmTitle:(nullable NSString *)confirmTitle
        cancelTitle:(nullable NSString *)cancelTitle
           onFinish:(nullable A2AlertDialogFinishBlock)onFinish {
    A2AlertDialog *vc = [self dialogWithTitle:title message:message];
    if (confirmTitle.length) vc.confirmTitle = confirmTitle;
    vc.cancelTitle = cancelTitle;
    vc.onFinish = onFinish;
    [vc presentFrom:host];
}

- (void)presentFrom:(UIViewController *)host {
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [host presentViewController:self animated:YES completion:nil];
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _backdrop = [[UIView alloc] initWithFrame:CGRectZero];
    _backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    _backdrop.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    [_backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                     initWithTarget:self action:@selector(backdropTapped)]];
    [self.view addSubview:_backdrop];

    [self setupCard];

    [NSLayoutConstraint activateConstraints:@[
        [_backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];

    // 入场前状态：卡片缩小淡出，viewDidAppear 里弹回
    _card.alpha = 0;
    _card.transform = CGAffineTransformMakeScale(0.96, 0.96);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    UIViewPropertyAnimator *anim = A2ExpressiveSpring(A2AnimDurationFast);
    [anim addAnimations:^{
        self.card.alpha = 1;
        self.card.transform = CGAffineTransformIdentity;
    }];
    [anim startAnimation];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 视图搭建

- (void)setupCard {
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.layer.cornerRadius = A2RadiusXL;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    [self.view addSubview:_card];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    _titleLabel.text = self.titleText ?: @"";
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 0;

    // 正文放进滚动容器：免责声明这类长文案不能把卡片撑出屏幕
    _messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _messageLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _messageLabel.text = self.messageText ?: @"";
    _messageLabel.textAlignment = NSTextAlignmentCenter;
    _messageLabel.numberOfLines = 0;

    _messageScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _messageScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _messageScroll.showsVerticalScrollIndicator = YES;
    _messageScroll.alwaysBounceVertical = NO;
    [_messageScroll addSubview:_messageLabel];

    _divider = [[UIView alloc] initWithFrame:CGRectZero];
    _divider.translatesAutoresizingMaskIntoConstraints = NO;

    NSMutableArray<A2PrimaryButton *> *buttons = [NSMutableArray array];
    if (self.cancelTitle.length) {
        _cancelButton = [[A2PrimaryButton alloc] initWithTitle:self.cancelTitle
                                                        style:A2ButtonStyleSecondary];
        [_cancelButton addTarget:self
                          action:@selector(cancelTapped)
                forControlEvents:UIControlEventTouchUpInside];
        [buttons addObject:_cancelButton];
    }

    _confirmButton = [[A2PrimaryButton alloc] initWithTitle:(self.confirmTitle ?: @"确定")
                                                      style:A2ButtonStylePrimary];
    [_confirmButton addTarget:self
                       action:@selector(confirmTapped)
             forControlEvents:UIControlEventTouchUpInside];
    [buttons addObject:_confirmButton];

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.distribution = UIStackViewDistributionFillEqually;
    buttonRow.spacing = A2SpaceM;
    [buttonRow.heightAnchor constraintEqualToConstant:A2ButtonHeight].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[_titleLabel, _messageScroll, _divider, buttonRow]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceL;
    [stack setCustomSpacing:A2SpaceS afterView:_titleLabel];
    [stack setCustomSpacing:A2SpaceL afterView:_messageScroll];
    [_card addSubview:stack];

    [_divider.heightAnchor constraintEqualToConstant:1].active = YES;

    NSLayoutConstraint *fixedWidth =
        [_card.widthAnchor constraintEqualToConstant:kA2AlertDialogMaxWidth];
    fixedWidth.priority = UILayoutPriorityDefaultHigh;

    // 正文容器：短文案收缩到内容高，长文案最多到上限后内部滚动
    NSLayoutConstraint *fitContent =
        [_messageScroll.heightAnchor constraintEqualToAnchor:_messageLabel.heightAnchor];
    fitContent.priority = UILayoutPriorityDefaultHigh;

    NSLayoutConstraint *labelWidth =
        [_messageLabel.widthAnchor constraintEqualToAnchor:_messageScroll.frameLayoutGuide.widthAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        fixedWidth,
        [_card.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor multiplier:0.92],
        [_card.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor multiplier:0.92],

        [stack.topAnchor constraintEqualToAnchor:_card.topAnchor constant:A2SpaceXL],
        [stack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceXL],
        [stack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceXL],
        [stack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-A2SpaceL],

        [_messageLabel.topAnchor constraintEqualToAnchor:_messageScroll.contentLayoutGuide.topAnchor],
        [_messageLabel.bottomAnchor constraintEqualToAnchor:_messageScroll.contentLayoutGuide.bottomAnchor],
        [_messageLabel.leadingAnchor constraintEqualToAnchor:_messageScroll.contentLayoutGuide.leadingAnchor],
        [_messageLabel.trailingAnchor constraintEqualToAnchor:_messageScroll.contentLayoutGuide.trailingAnchor],
        labelWidth,
        fitContent,
        [_messageScroll.heightAnchor constraintLessThanOrEqualToConstant:kA2AlertDialogMaxMessageHeight],
    ]];

    [self applyTheme];
}

#pragma mark - 交互

- (void)backdropTapped {
    // 单按钮形态下点遮罩不关闭 —— 只是一条告知，必须显式确认
    if (!self.cancelButton) return;
    [self finishConfirmed:NO];
}

- (void)cancelTapped {
    [self finishConfirmed:NO];
}

- (void)confirmTapped {
    [self finishConfirmed:YES];
}

- (void)finishConfirmed:(BOOL)confirmed {
    if (_finishing) return;
    _finishing = YES;

    A2AlertDialogFinishBlock finish = self.onFinish;
    [self dismissViewControllerAnimated:YES completion:^{
        if (finish) finish(confirmed);
    }];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _card.backgroundColor = t.cSurfaceContainerHigh;
    _titleLabel.textColor = t.cOnSurface;
    _messageLabel.textColor = t.cOnSurfaceVariant;
    _divider.backgroundColor = t.cOutlineVariant;
}

@end
