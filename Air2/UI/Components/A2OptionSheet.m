//
//  A2OptionSheet.m
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
//    · 呈现走 overFullScreen + 0.45 遮罩，卡片 surfaceContainerHigh + 弹簧缩放入场
//    · 选项列表用 A2SettingsSection（首/末行大圆角、行间距 2）装在滚动区里，
//      选项多时（渲染器 7 项）滚动，少时随内容收缩
//    · 选项行默认不透明（surfaceContainerLow），弹窗内没有任何玻璃/模糊
//

#import "A2OptionSheet.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2PrimaryButton.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

/// 卡片最大宽度。横屏下不铺满，保持可读行宽（与仓内其它自绘弹窗同口径）。
static const CGFloat kA2OptionSheetMaxWidth = 460;
/// 选项区最多占屏高的一半，超出即滚动。
static const CGFloat kA2OptionSheetOptionsMaxHeightRatio = 0.5;

@interface A2OptionSheet ()

@property (nonatomic, copy, nullable) NSString *titleText;
@property (nonatomic, copy, nullable) NSString *messageText;

@property (nonatomic, strong) NSMutableArray<NSString *> *optionTitles;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *optionSelected;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *optionDestructive;
@property (nonatomic, strong) NSMutableArray<void (^)(void)> *optionHandlers;

@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIScrollView *optionsScroll;
@property (nonatomic, strong) A2SettingsSection *optionsSection;
@property (nonatomic, strong) UIView *divider;
@property (nonatomic, strong) A2PrimaryButton *cancelButton;

@end

@implementation A2OptionSheet

#pragma mark - 构建

+ (instancetype)sheetWithTitle:(NSString *)title message:(NSString *)message {
    A2OptionSheet *vc = [[A2OptionSheet alloc] init];
    vc.titleText = title;
    vc.messageText = message;
    return vc;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _optionTitles = [NSMutableArray array];
    _optionSelected = [NSMutableArray array];
    _optionDestructive = [NSMutableArray array];
    _optionHandlers = [NSMutableArray array];
    return self;
}

- (void)addOptionWithTitle:(NSString *)title
                  selected:(BOOL)selected
               destructive:(BOOL)destructive
                   handler:(void (^)(void))handler {
    [_optionTitles addObject:title ?: @""];
    [_optionSelected addObject:@(selected)];
    [_optionDestructive addObject:@(destructive)];
    [_optionHandlers addObject:handler ?: ^{}];
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
    _titleLabel.hidden = (self.titleText.length == 0);

    _messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _messageLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _messageLabel.text = self.messageText;
    _messageLabel.textAlignment = NSTextAlignmentCenter;
    _messageLabel.numberOfLines = 0;
    _messageLabel.hidden = (self.messageText.length == 0);

    _optionsSection = [[A2SettingsSection alloc] initWithTitle:nil];
    for (NSUInteger i = 0; i < _optionTitles.count; i++) {
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.title = _optionTitles[i];
        row.accessory = _optionSelected[i].boolValue ? A2SettingsRowAccessoryCheckmark
                                                    : A2SettingsRowAccessoryNone;
        row.destructive = _optionDestructive[i].boolValue;
        __weak typeof(self) weakSelf = self;
        row.onTap = ^{ [weakSelf handleOptionAtIndex:i]; };
        [_optionsSection addRow:row];
    }

    _optionsScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _optionsScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _optionsScroll.showsVerticalScrollIndicator = YES;
    _optionsScroll.alwaysBounceVertical = NO;
    [_optionsScroll addSubview:_optionsSection];

    [_optionsSection.topAnchor constraintEqualToAnchor:_optionsScroll.contentLayoutGuide.topAnchor].active = YES;
    [_optionsSection.bottomAnchor constraintEqualToAnchor:_optionsScroll.contentLayoutGuide.bottomAnchor].active = YES;
    [_optionsSection.leadingAnchor constraintEqualToAnchor:_optionsScroll.contentLayoutGuide.leadingAnchor].active = YES;
    [_optionsSection.trailingAnchor constraintEqualToAnchor:_optionsScroll.contentLayoutGuide.trailingAnchor].active = YES;
    [_optionsSection.widthAnchor constraintEqualToAnchor:_optionsScroll.frameLayoutGuide.widthAnchor].active = YES;

    _divider = [[UIView alloc] initWithFrame:CGRectZero];
    _divider.translatesAutoresizingMaskIntoConstraints = NO;
    [_divider.heightAnchor constraintEqualToConstant:1].active = YES;

    _cancelButton = [[A2PrimaryButton alloc] initWithTitle:@"取消"
                                                    style:A2ButtonStyleSecondary];
    [_cancelButton addTarget:self
                      action:@selector(cancelTapped)
            forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[_titleLabel, _messageLabel, _optionsScroll, _divider, _cancelButton]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceL;
    [stack setCustomSpacing:A2SpaceS afterView:_titleLabel];
    [stack setCustomSpacing:A2SpaceXL afterView:_optionsScroll];
    [stack setCustomSpacing:A2SpaceL afterView:_divider];
    [_card addSubview:stack];

    [_cancelButton.heightAnchor constraintEqualToConstant:A2ButtonHeight].active = YES;

    NSLayoutConstraint *fixedWidth = [_card.widthAnchor constraintEqualToConstant:kA2OptionSheetMaxWidth];
    fixedWidth.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *optionsMaxHeight =
        [_optionsScroll.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor
                                                            multiplier:kA2OptionSheetOptionsMaxHeightRatio];

    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        fixedWidth,
        [_card.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor multiplier:0.92],
        [_card.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor multiplier:0.92],
        optionsMaxHeight,

        [stack.topAnchor constraintEqualToAnchor:_card.topAnchor constant:A2SpaceXL],
        [stack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceXL],
        [stack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceXL],
        [stack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-A2SpaceL],
    ]];

    [self applyTheme];
}

#pragma mark - 交互

/// 点遮罩 = 取消（与系统 ActionSheet 点空白处收起同义）
- (void)backdropTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleOptionAtIndex:(NSUInteger)index {
    if (index >= _optionHandlers.count) return;
    void (^handler)(void) = _optionHandlers[index];
    // 先关弹窗再回调：handler 里可能立刻再弹一个弹窗（如「重命名」），
    // 转场还没结束时再 present 会被系统拒绝，所以顺序不能反。
    [self dismissViewControllerAnimated:YES completion:^{
        handler();
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
