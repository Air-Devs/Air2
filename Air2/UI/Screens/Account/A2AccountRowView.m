//
//  A2AccountRowView.m
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

#import "A2AccountRowView.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import "A2SkinHeadView.h"

@interface A2AccountRowView ()
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) UIView *radioOuter;
@property (nonatomic, strong) UIView *radioInner;
@property (nonatomic, strong) A2SkinHeadView *avatarView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *typeLabel;
@property (nonatomic, strong) UIButton *refreshButton;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) UISelectionFeedbackGenerator *feedback;
@end

@implementation A2AccountRowView

- (instancetype)initWithName:(NSString *)name type:(NSString *)type {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _accountName = [name copy];
    _accountType = [type copy];
    _current = NO;
    _refreshable = YES;
    _feedback = [UISelectionFeedbackGenerator new];
    [self setup];
    return self;
}

- (void)setup {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.clipsToBounds = YES;

    _fillView = [[UIView alloc] initWithFrame:CGRectZero];
    _fillView.translatesAutoresizingMaskIntoConstraints = NO;
    _fillView.userInteractionEnabled = NO;
    _fillView.layer.cornerRadius = A2RadiusM;
    _fillView.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_fillView];

    // ---- 单选 ----
    _radioOuter = [[UIView alloc] initWithFrame:CGRectZero];
    _radioOuter.translatesAutoresizingMaskIntoConstraints = NO;
    _radioOuter.layer.cornerRadius = 10;
    _radioOuter.layer.borderWidth = 2;
    _radioOuter.userInteractionEnabled = NO;
    [self addSubview:_radioOuter];

    _radioInner = [[UIView alloc] initWithFrame:CGRectZero];
    _radioInner.translatesAutoresizingMaskIntoConstraints = NO;
    _radioInner.layer.cornerRadius = 5;
    _radioInner.hidden = YES;
    [_radioOuter addSubview:_radioInner];

    // ---- 头像 46 ----
    _avatarView = [[A2SkinHeadView alloc] initWithFrame:CGRectZero];
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarView.fallbackText = _accountName;
    [self addSubview:_avatarView];

    // ---- 文字 ----
    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _nameLabel.text = _accountName;
    _nameLabel.numberOfLines = 1;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.75;

    _typeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _typeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _typeLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _typeLabel.text = _accountType;
    _typeLabel.numberOfLines = 1;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel, _typeLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 1;
    [self addSubview:textStack];

    // ---- 右侧按钮 ----
    _refreshButton = [self makeIconButton:@"arrow.clockwise" action:@selector(handleRefresh)];
    _moreButton = [self makeIconButton:@"ellipsis" action:@selector(handleMore)];

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[_refreshButton, _moreButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 0;
    [self addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:62],

        [_fillView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_fillView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_fillView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_fillView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [_radioOuter.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceM],
        [_radioOuter.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_radioOuter.widthAnchor constraintEqualToConstant:20],
        [_radioOuter.heightAnchor constraintEqualToConstant:20],
        [_radioInner.centerXAnchor constraintEqualToAnchor:_radioOuter.centerXAnchor],
        [_radioInner.centerYAnchor constraintEqualToAnchor:_radioOuter.centerYAnchor],
        [_radioInner.widthAnchor constraintEqualToConstant:10],
        [_radioInner.heightAnchor constraintEqualToConstant:10],

        [_avatarView.leadingAnchor constraintEqualToAnchor:_radioOuter.trailingAnchor constant:A2SpaceM],
        [_avatarView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_avatarView.widthAnchor constraintEqualToConstant:46],
        [_avatarView.heightAnchor constraintEqualToConstant:46],

        // ZL2 用 18 的间距
        [textStack.leadingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor constant:18],
        [textStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:buttonRow.leadingAnchor
                                                          constant:-A2SpaceS],

        [buttonRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceS],
        [buttonRow.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UIButton *)makeIconButton:(NSString *)symbol action:(SEL)action {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [b.widthAnchor constraintEqualToConstant:44],
        [b.heightAnchor constraintEqualToConstant:44],
    ]];
    return b;
}

#pragma mark - 属性

- (void)setCurrent:(BOOL)current {
    _current = current;
    _radioInner.hidden = !current;
    [self applyTheme];
}

- (void)setRefreshable:(BOOL)refreshable {
    _refreshable = refreshable;
    _refreshButton.enabled = refreshable;
    _refreshButton.alpha = refreshable ? 1.0 : 0.35;
}

- (void)setSkinPath:(NSString *)skinPath {
    _skinPath = [skinPath copy];
    _avatarView.skinPath = _skinPath;
}

#pragma mark - 交互

- (void)handleRefresh {
    [_feedback selectionChanged];
    if (self.onRefresh) self.onRefresh();
}

- (void)handleMore {
    [_feedback selectionChanged];
    if (self.onMore) self.onMore();
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    CGPoint p = [touches.anyObject locationInView:self];
    if (CGRectContainsPoint(self.bounds, p) && !self.isCurrent) {
        [_feedback selectionChanged];
        if (self.onSelect) self.onSelect();
    }
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    _fillView.backgroundColor = self.isCurrent ? t.cSecondaryContainer : t.cSurfaceContainerLow;

    _radioOuter.layer.borderColor = (self.isCurrent ? t.cPrimary : t.cOutline).CGColor;
    _radioInner.backgroundColor = t.cPrimary;

    // 头像底色与占位文字色由 A2SkinHeadView 自己跟随主题，这里不再代管。
    _nameLabel.textColor = t.cOnSurface;
    _typeLabel.textColor = t.cOnSurfaceVariant;

    _refreshButton.tintColor = t.cOnSurfaceVariant;
    _moreButton.tintColor = t.cOnSurfaceVariant;
}

@end
