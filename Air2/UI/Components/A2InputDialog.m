//
//  A2InputDialog.m
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
//    · 键盘弹出时抬升卡片，避免盖住输入框与按钮
//    · 提交分两段：先跑同步 validator，再跑异步 onCommit（可停留、可报错）
//

#import "A2InputDialog.h"
#import "A2TextField.h"
#import "A2PrimaryButton.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

/// 卡片最大宽度。横屏下不铺满，保持可读行宽。
static const CGFloat kA2InputDialogMaxWidth = 460;

@interface A2InputDialog ()

@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) A2TextField *field;
@property (nonatomic, strong) UIView *divider;
@property (nonatomic, strong) A2PrimaryButton *cancelButton;
@property (nonatomic, strong) A2PrimaryButton *confirmButton;
@property (nonatomic, strong) NSLayoutConstraint *cardCenterY;

/// 提交中：锁定按钮与遮罩，防止重复提交
@property (nonatomic, assign) BOOL submitting;

@end

@implementation A2InputDialog

#pragma mark - 构建

+ (instancetype)dialogWithTitle:(NSString *)title
                        message:(nullable NSString *)message
                          label:(nullable NSString *)label
                    initialText:(nullable NSString *)initialText {
    A2InputDialog *vc = [[A2InputDialog alloc] init];
    vc.titleText = title;
    vc.messageText = message;
    vc.fieldLabel = label;
    vc.initialText = initialText;
    return vc;
}

+ (void)presentFrom:(UIViewController *)host
              title:(NSString *)title
              label:(nullable NSString *)label
        initialText:(nullable NSString *)initialText
           onFinish:(nullable A2InputDialogFinishBlock)onFinish {
    A2InputDialog *vc = [self dialogWithTitle:title message:nil label:label initialText:initialText];
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
                                     initWithTarget:self action:@selector(cancelTapped)]];
    [self.view addSubview:_backdrop];

    [self setupCard];

    [NSLayoutConstraint activateConstraints:@[
        [_backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(keyboardWillChangeFrame:)
                                              name:UIKeyboardWillChangeFrameNotification
                                            object:nil];
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
    [self.field.textField becomeFirstResponder];
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

    _messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _messageLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _messageLabel.text = self.messageText;
    _messageLabel.textAlignment = NSTextAlignmentCenter;
    _messageLabel.numberOfLines = 0;
    _messageLabel.hidden = (self.messageText.length == 0);

    _field = [[A2TextField alloc] initWithLabel:self.fieldLabel ?: @""];
    _field.text = self.initialText ?: @"";
    _field.secure = self.isSecure;
    if (self.keyboardType != UIKeyboardTypeDefault) _field.keyboardType = self.keyboardType;
    _field.autocapitalizationType = self.autocapitalizationType;
    __weak typeof(self) weakSelf = self;
    _field.onReturn = ^{ [weakSelf confirmTapped]; };

    _divider = [[UIView alloc] initWithFrame:CGRectZero];
    _divider.translatesAutoresizingMaskIntoConstraints = NO;

    _cancelButton = [[A2PrimaryButton alloc] initWithTitle:(self.cancelTitle ?: @"取消")
                                                    style:A2ButtonStyleSecondary];
    [_cancelButton addTarget:self
                      action:@selector(cancelTapped)
            forControlEvents:UIControlEventTouchUpInside];

    _confirmButton = [[A2PrimaryButton alloc] initWithTitle:(self.confirmTitle ?: @"确认")
                                                      style:A2ButtonStylePrimary];
    [_confirmButton addTarget:self
                       action:@selector(confirmTapped)
             forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttonRow =
        [[UIStackView alloc] initWithArrangedSubviews:@[_cancelButton, _confirmButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.distribution = UIStackViewDistributionFillEqually;
    buttonRow.spacing = A2SpaceM;
    [buttonRow.heightAnchor constraintEqualToConstant:A2ButtonHeight].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[_titleLabel, _messageLabel, _field, _divider, buttonRow]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceL;
    [stack setCustomSpacing:A2SpaceS afterView:_titleLabel];
    [stack setCustomSpacing:A2SpaceXL afterView:_field];
    [stack setCustomSpacing:A2SpaceL afterView:_divider];
    [_card addSubview:stack];

    [_divider.heightAnchor constraintEqualToConstant:1].active = YES;

    _cardCenterY = [_card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor];

    NSLayoutConstraint *fixedWidth = [_card.widthAnchor constraintEqualToConstant:kA2InputDialogMaxWidth];
    fixedWidth.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        _cardCenterY,
        fixedWidth,
        [_card.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor multiplier:0.92],
        [_card.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor multiplier:0.92],

        [stack.topAnchor constraintEqualToAnchor:_card.topAnchor constant:A2SpaceXL],
        [stack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceXL],
        [stack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceXL],
        [stack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-A2SpaceL],
    ]];

    [self applyTheme];
}

#pragma mark - 交互

- (void)cancelTapped {
    if (_submitting) return;
    [self finishCommitted:NO text:@""];
}

- (void)confirmTapped {
    if (_submitting) return;
    NSString *text = _field.text ?: @"";

    if (self.validator) {
        NSString *error = self.validator(text);
        if (error.length > 0) {
            _field.errorText = error;
            UINotificationFeedbackGenerator *fb = [UINotificationFeedbackGenerator new];
            [fb notificationOccurred:UINotificationFeedbackTypeError];
            return;
        }
    }
    [_field clearError];

    A2InputDialogCommitBlock commit = self.onCommit;
    if (!commit) {
        [self finishCommitted:YES text:text];
        return;
    }

    self.submitting = YES;
    _confirmButton.loading = YES;
    // A2PrimaryButton 自身的触摸处理不看 enabled，只能靠 userInteractionEnabled 锁
    _cancelButton.userInteractionEnabled = NO;
    _cancelButton.alpha = 0.4;

    __weak typeof(self) weakSelf = self;
    commit(text, ^(BOOL success, NSString *errorMessage) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (success) {
            [self finishCommitted:YES text:text];
            return;
        }
        self.submitting = NO;
        self.confirmButton.loading = NO;
        self.cancelButton.userInteractionEnabled = YES;
        self.cancelButton.alpha = 1;
        self.field.errorText = errorMessage.length > 0 ? errorMessage : @"提交失败";
        UINotificationFeedbackGenerator *fb = [UINotificationFeedbackGenerator new];
        [fb notificationOccurred:UINotificationFeedbackTypeError];
    });
}

- (void)finishCommitted:(BOOL)committed text:(NSString *)text {
    A2InputDialogFinishBlock finish = self.onFinish;
    [self dismissViewControllerAnimated:YES completion:^{
        if (finish) finish(committed, text ?: @"");
    }];
}

#pragma mark - 键盘

- (void)keyboardWillChangeFrame:(NSNotification *)note {
    CGRect endFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect inView = [self.view convertRect:endFrame fromView:nil];
    CGFloat keyboardTop = CGRectGetMinY(inView);
    CGFloat cardBottom = CGRectGetMaxY(_card.frame);
    CGFloat desiredBottom = keyboardTop - A2SpaceL;
    // 只在键盘确实压住卡片时上移，且不把卡片顶出屏幕上沿
    CGFloat delta = MIN(0, desiredBottom - cardBottom);
    CGFloat minCenterY = _card.bounds.size.height / 2.0 + A2SpaceS;
    CGFloat maxUpShift = MIN(0, minCenterY - _card.center.y);
    if (delta < maxUpShift) delta = maxUpShift;
    if (fabs(delta - _cardCenterY.constant) < 0.5) return;

    _cardCenterY.constant = delta;
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration > 0 ? duration : A2AnimDurationFast
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ [self.view layoutIfNeeded]; }
                     completion:nil];
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
