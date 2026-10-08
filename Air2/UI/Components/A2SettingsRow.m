//
//  A2SettingsRow.m
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

#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"

@interface A2SettingsRow ()
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) UIView *iconBox;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UIImageView *chevron;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, strong) UIImageView *checkmark;
@property (nonatomic, strong) UIView *separator;
@property (nonatomic, strong) UIStackView *textStack;
@property (nonatomic, strong) UIStackView *trailingStack;
@property (nonatomic, strong) UISelectionFeedbackGenerator *feedback;
@end

@implementation A2SettingsRow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self setup];
    return self;
}

- (void)setup {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.clipsToBounds = YES;
    _feedback = [UISelectionFeedbackGenerator new];
    _accessory = A2SettingsRowAccessoryNone;
    _cardPosition = A2CardPositionSingle;

    // 背景填充（圆角由 cardPosition 决定）
    _fillView = [[UIView alloc] initWithFrame:CGRectZero];
    _fillView.translatesAutoresizingMaskIntoConstraints = NO;
    _fillView.userInteractionEnabled = NO;
    _fillView.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_fillView];

    // ---- 图标 ----
    _iconBox = [[UIView alloc] initWithFrame:CGRectZero];
    _iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBox.layer.cornerRadius = A2RadiusS;
    _iconBox.layer.cornerCurve = kCACornerCurveContinuous;
    _iconBox.hidden = YES;
    [self addSubview:_iconBox];

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconBox addSubview:_iconView];

    // ---- 文字 ----
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _titleLabel.numberOfLines = 1;

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _subtitleLabel.numberOfLines = 2;
    _subtitleLabel.hidden = YES;

    _textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subtitleLabel]];
    _textStack.translatesAutoresizingMaskIntoConstraints = NO;
    _textStack.axis = UILayoutConstraintAxisVertical;
    _textStack.spacing = 1;
    _textStack.alignment = UIStackViewAlignmentLeading;
    [self addSubview:_textStack];

    // ---- 右侧 ----
    _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _valueLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _valueLabel.textAlignment = NSTextAlignmentRight;
    _valueLabel.hidden = YES;
    [_valueLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh
                                                 forAxis:UILayoutConstraintAxisHorizontal];

    UIImageSymbolConfiguration *chevCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
    _chevron = [[UIImageView alloc] initWithImage:
                [UIImage systemImageNamed:@"chevron.right" withConfiguration:chevCfg]];
    _chevron.translatesAutoresizingMaskIntoConstraints = NO;
    _chevron.hidden = YES;

    _toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    _toggle.translatesAutoresizingMaskIntoConstraints = NO;
    _toggle.hidden = YES;
    _toggle.transform = CGAffineTransformMakeScale(0.85, 0.85);   // MD3 的开关更小
    [_toggle addTarget:self action:@selector(toggleChanged) forControlEvents:UIControlEventValueChanged];

    _checkmark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
    _checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    _checkmark.hidden = YES;

    _trailingStack = [[UIStackView alloc] initWithArrangedSubviews:@[_valueLabel, _checkmark, _chevron, _toggle]];
    _trailingStack.translatesAutoresizingMaskIntoConstraints = NO;
    _trailingStack.axis = UILayoutConstraintAxisHorizontal;
    _trailingStack.spacing = A2SpaceS;
    _trailingStack.alignment = UIStackViewAlignmentCenter;
    [self addSubview:_trailingStack];

    // ---- 分隔线：与文字左对齐 ----
    _separator = [[UIView alloc] initWithFrame:CGRectZero];
    _separator.translatesAutoresizingMaskIntoConstraints = NO;
    _separator.hidden = YES;
    [self addSubview:_separator];

    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:A2MinTouchTarget],

        [_fillView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_fillView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_fillView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_fillView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [_iconBox.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceL],
        [_iconBox.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconBox.widthAnchor constraintEqualToConstant:28],
        [_iconBox.heightAnchor constraintEqualToConstant:28],

        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBox.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBox.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:16],
        [_iconView.heightAnchor constraintEqualToConstant:16],

        [_textStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceL],
        [_textStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_textStack.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor constant:A2SpaceM],

        [_trailingStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceL],
        [_trailingStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_trailingStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:_textStack.trailingAnchor
                                                                  constant:A2SpaceM],

        [_separator.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_separator.heightAnchor constraintEqualToConstant:1],
    ]];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 属性

- (void)setSymbolName:(NSString *)symbolName {
    _symbolName = [symbolName copy];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
    _iconView.image = [UIImage systemImageNamed:symbolName withConfiguration:cfg];
    _iconBox.hidden = (symbolName.length == 0);
    [self updateTextLeading];
    [self applyTheme];
}

- (void)setSymbolColor:(UIColor *)symbolColor {
    _symbolColor = symbolColor;
    [self applyTheme];
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    _titleLabel.text = title;
}

- (void)setSubtitle:(NSString *)subtitle {
    _subtitle = [subtitle copy];
    _subtitleLabel.text = subtitle;
    _subtitleLabel.hidden = (subtitle.length == 0);
}

- (void)setValueText:(NSString *)valueText {
    _valueText = [valueText copy];
    _valueLabel.text = valueText;
    _valueLabel.hidden = (valueText.length == 0);
}

- (void)setAccessory:(A2SettingsRowAccessory)accessory {
    _accessory = accessory;
    _chevron.hidden = (accessory != A2SettingsRowAccessoryDisclosure);
    _toggle.hidden = (accessory != A2SettingsRowAccessorySwitch);
    _checkmark.hidden = (accessory != A2SettingsRowAccessoryCheckmark);
}

- (void)setCustomAccessoryView:(UIView *)customAccessoryView {
    if (_customAccessoryView) {
        [_trailingStack removeArrangedSubview:_customAccessoryView];
        [_customAccessoryView removeFromSuperview];
    }
    _customAccessoryView = customAccessoryView;
    if (customAccessoryView) {
        [_trailingStack addArrangedSubview:customAccessoryView];
        self.accessory = A2SettingsRowAccessoryCustom;
    }
}

- (void)setOn:(BOOL)on {
    _on = on;
    [_toggle setOn:on animated:YES];
}

- (void)setDestructive:(BOOL)destructive {
    _destructive = destructive;
    [self applyTheme];
}

- (void)setCardPosition:(A2CardPosition)cardPosition {
    _cardPosition = cardPosition;
    [self applyTheme];
}

- (void)setShowsSeparator:(BOOL)showsSeparator {
    _showsSeparator = showsSeparator;
    _separator.hidden = !showsSeparator;
}

- (void)setUseHighContainer:(BOOL)useHighContainer {
    _useHighContainer = useHighContainer;
    [self applyTheme];
}

/// 有图标时文字后移
- (void)updateTextLeading {
    CGFloat leading = _iconBox.hidden ? A2SpaceL : (A2SpaceL + 28 + A2SpaceM);
    for (NSLayoutConstraint *c in self.constraints) {
        if (c.firstItem == _textStack && c.firstAttribute == NSLayoutAttributeLeading) {
            c.constant = leading;
        }
    }
    // 分隔线也与文字左对齐
    [self updateSeparatorInsets:leading];
}

- (void)updateSeparatorInsets:(CGFloat)leading {
    // 移除旧的分隔线水平约束
    NSMutableArray *toRemove = [NSMutableArray array];
    for (NSLayoutConstraint *c in self.constraints) {
        if (c.firstItem == _separator || c.secondItem == _separator) {
            if (c.firstAttribute != NSLayoutAttributeBottom &&
                c.firstAttribute != NSLayoutAttributeHeight) {
                [toRemove addObject:c];
            }
        }
    }
    [NSLayoutConstraint deactivateConstraints:toRemove];

    [NSLayoutConstraint activateConstraints:@[
        [_separator.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:leading],
        [_separator.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];
}

#pragma mark - 交互

- (void)toggleChanged {
    _on = _toggle.isOn;
    [_feedback selectionChanged];
    if (self.onToggle) self.onToggle(_on);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (_accessory == A2SettingsRowAccessorySwitch) return;
    [UIView animateWithDuration:A2AnimDurationFast animations:^{
        self.fillView.backgroundColor = [self.fillView.backgroundColor
            colorWithAlphaComponent:0.75];
    }];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [self applyTheme];

    if (_accessory == A2SettingsRowAccessorySwitch) {
        // 点整行也能切开关
        CGPoint p = [touches.anyObject locationInView:self];
        if (CGRectContainsPoint(self.bounds, p)) {
            [_toggle setOn:!_toggle.isOn animated:YES];
            [self toggleChanged];
        }
        return;
    }

    CGPoint p = [touches.anyObject locationInView:self];
    if (CGRectContainsPoint(self.bounds, p)) {
        [_feedback selectionChanged];
        [self sendActionsForControlEvents:UIControlEventTouchUpInside];
        if (self.onTap) self.onTap();
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [self applyTheme];
}

#pragma mark - 主题

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    // 背景：按层级取值，圆角按位置
    UIColor *fill = _useHighContainer ? t.cSurfaceContainerHigh : t.cSurfaceContainerLow;
    _fillView.backgroundColor = fill;
    _fillView.layer.cornerRadius = (_cardPosition == A2CardPositionMiddle)
        ? A2RadiusXS : A2RadiusXL;
    _fillView.layer.maskedCorners = A2CornerMaskForPosition(_cardPosition);

    _iconBox.backgroundColor = self.symbolColor ?: t.cPrimaryContainer;
    _iconView.tintColor = self.symbolColor ? UIColor.whiteColor : t.cOnPrimaryContainer;

    _titleLabel.textColor = self.isDestructive ? t.cError : t.cOnSurface;
    _subtitleLabel.textColor = t.cOnSurfaceVariant;
    _valueLabel.textColor = t.cOnSurfaceVariant;
    _chevron.tintColor = t.cOutline;
    _checkmark.tintColor = t.cPrimary;
    _toggle.onTintColor = t.cPrimary;
    _separator.backgroundColor = [t.cOutlineVariant colorWithAlphaComponent:0.6];
}

@end
