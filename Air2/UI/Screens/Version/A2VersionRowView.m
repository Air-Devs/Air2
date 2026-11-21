//
//  A2VersionRowView.m
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

#import "A2VersionRowView.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

@interface A2VersionRowView ()
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) UIView *radioOuter;
@property (nonatomic, strong) UIView *radioInner;
@property (nonatomic, strong) UIView *iconBox;
@property (nonatomic, strong) UILabel *initialLabel;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIButton *pinButton;
@property (nonatomic, strong) UIButton *settingsButton;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) UISelectionFeedbackGenerator *feedback;
@end

@implementation A2VersionRowView

- (instancetype)initWithVersionName:(NSString *)name meta:(NSString *)meta {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _versionName = [name copy];
    _meta = [meta copy];
    _current = NO;
    _pinned = NO;
    _valid = YES;
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

    // ---- 左侧单选按钮 ----
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

    // ---- 版本图标 ----
    _iconBox = [[UIView alloc] initWithFrame:CGRectZero];
    _iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBox.layer.cornerRadius = A2RadiusS;
    _iconBox.layer.cornerCurve = kCACornerCurveContinuous;
    _iconBox.clipsToBounds = YES;
    [self addSubview:_iconBox];

    _initialLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _initialLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _initialLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    _initialLabel.textAlignment = NSTextAlignmentCenter;
    _initialLabel.text = _versionName.length ? [[_versionName substringToIndex:1] uppercaseString] : @"?";
    [_iconBox addSubview:_initialLabel];

    // ---- 文字 ----
    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _nameLabel.text = _versionName;
    _nameLabel.numberOfLines = 1;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.75;

    _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metaLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _metaLabel.text = _meta;
    _metaLabel.numberOfLines = 1;
    _metaLabel.hidden = (_meta.length == 0);

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel, _metaLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 1;
    [self addSubview:textStack];

    // ---- 右侧三个图标按钮 ----
    _pinButton = [self makeIconButton:@"pin" action:@selector(handlePin)];
    _settingsButton = [self makeIconButton:@"gearshape.fill" action:@selector(handleSettings)];
    _moreButton = [self makeIconButton:@"ellipsis" action:@selector(handleMore)];

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[_pinButton, _settingsButton, _moreButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 0;
    [self addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:64],

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

        [_iconBox.leadingAnchor constraintEqualToAnchor:_radioOuter.trailingAnchor constant:A2SpaceM],
        [_iconBox.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconBox.widthAnchor constraintEqualToConstant:36],
        [_iconBox.heightAnchor constraintEqualToConstant:36],
        [_initialLabel.centerXAnchor constraintEqualToAnchor:_iconBox.centerXAnchor],
        [_initialLabel.centerYAnchor constraintEqualToAnchor:_iconBox.centerYAnchor],

        [textStack.leadingAnchor constraintEqualToAnchor:_iconBox.trailingAnchor constant:A2SpaceM],
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

- (void)setPinned:(BOOL)pinned {
    _pinned = pinned;
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    NSString *sym = pinned ? @"pin.fill" : @"pin";
    [_pinButton setImage:[UIImage systemImageNamed:sym withConfiguration:cfg]
                forState:UIControlStateNormal];
    [self applyTheme];
}

- (void)setValid:(BOOL)valid {
    _valid = valid;
    _pinButton.enabled = valid;
    _settingsButton.enabled = valid;
    self.alpha = valid ? 1.0 : 0.55;
    [self applyTheme];
}

#pragma mark - 交互

- (void)handlePin {
    [_feedback selectionChanged];
    if (self.onPin) self.onPin();
}

- (void)handleSettings {
    [_feedback selectionChanged];
    if (self.onSettings) self.onSettings();
}

- (void)handleMore {
    [_feedback selectionChanged];
    if (self.onMore) self.onMore();
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationFast);
    [a addAnimations:^{ self.transform = CGAffineTransformMakeScale(0.99, 0.99); }];
    [a startAnimation];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationFast);
    [a addAnimations:^{ self.transform = CGAffineTransformIdentity; }];
    [a startAnimation];

    CGPoint p = [touches.anyObject locationInView:self];
    if (CGRectContainsPoint(self.bounds, p) && !self.isCurrent) {
        [_feedback selectionChanged];
        if (self.onSelect) self.onSelect();
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.transform = CGAffineTransformIdentity;
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    // 选中当前版本时用强调容器色
    _fillView.backgroundColor = self.isCurrent ? t.cSecondaryContainer : t.cSurfaceContainerLow;

    _radioOuter.layer.borderColor = (self.isCurrent ? t.cPrimary : t.cOutline).CGColor;
    _radioInner.backgroundColor = t.cPrimary;

    _iconBox.backgroundColor = t.cPrimaryContainer;
    _initialLabel.textColor = t.cOnPrimaryContainer;

    _nameLabel.textColor = t.cOnSurface;
    _metaLabel.textColor = t.cOnSurfaceVariant;

    UIColor *btnColor = t.cOnSurfaceVariant;
    _pinButton.tintColor = self.isPinned ? t.cPrimary : btnColor;
    _settingsButton.tintColor = btnColor;
    _moreButton.tintColor = btnColor;
}

@end
