//
//  A2TextField.m
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

#import "A2TextField.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

/// MD3 填充式输入框的标准高度。
static const CGFloat kA2FieldHeight = 56;

@interface A2TextField () <UITextFieldDelegate>

@property (nonatomic, strong) UIStackView *rootStack;
@property (nonatomic, strong) UIView *box;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UIView *underline;
@property (nonatomic, strong) UILabel *supportLabel;

@property (nonatomic, strong) NSLayoutConstraint *labelFloatingTop;
@property (nonatomic, strong) NSLayoutConstraint *labelRestingCenterY;
@property (nonatomic, strong) NSLayoutConstraint *underlineHeight;

/// 标签当前是否处于上浮态
@property (nonatomic, assign) BOOL labelFloating;

@end

@implementation A2TextField

- (instancetype)initWithLabel:(NSString *)label {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _labelText = [label copy];
    [self setup];
    return self;
}

- (void)setup {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _rootStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    _rootStack.axis = UILayoutConstraintAxisVertical;
    _rootStack.spacing = A2SpaceXS;
    [self addSubview:_rootStack];

    // ---- 填充框 ----
    _box = [[UIView alloc] initWithFrame:CGRectZero];
    _box.translatesAutoresizingMaskIntoConstraints = NO;
    _box.layer.cornerRadius = A2RadiusXS;
    _box.layer.cornerCurve = kCACornerCurveContinuous;
    // MD3 填充式输入框只有上两角是圆的
    _box.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    _box.clipsToBounds = YES;

    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.text = _labelText;
    _label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    _label.userInteractionEnabled = NO;
    [_box addSubview:_label];

    _field = [[UITextField alloc] initWithFrame:CGRectZero];
    _field.translatesAutoresizingMaskIntoConstraints = NO;
    _field.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    _field.borderStyle = UITextBorderStyleNone;
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    _field.spellCheckingType = UITextSpellCheckingTypeNo;
    _field.delegate = self;
    [_field addTarget:self action:@selector(handleEditingChanged)
     forControlEvents:UIControlEventEditingChanged];
    [_box addSubview:_field];

    _underline = [[UIView alloc] initWithFrame:CGRectZero];
    _underline.translatesAutoresizingMaskIntoConstraints = NO;
    [_box addSubview:_underline];

    _supportLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _supportLabel.font = [A2Typography caption];
    _supportLabel.numberOfLines = 0;
    _supportLabel.hidden = YES;

    [_rootStack addArrangedSubview:_box];
    [_rootStack addArrangedSubview:_supportLabel];

    // 标签两套纵向约束：静止态对齐输入行，上浮态贴顶。二选一激活。
    _labelFloatingTop = [_label.topAnchor constraintEqualToAnchor:_box.topAnchor
                                                          constant:7];
    _labelRestingCenterY = [_label.centerYAnchor constraintEqualToAnchor:_field.centerYAnchor];
    _labelRestingCenterY.active = YES;

    _underlineHeight = [_underline.heightAnchor constraintEqualToConstant:1];

    [NSLayoutConstraint activateConstraints:@[
        [_rootStack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_rootStack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_rootStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_rootStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [_box.heightAnchor constraintEqualToConstant:kA2FieldHeight],

        [_label.leadingAnchor constraintEqualToAnchor:_box.leadingAnchor constant:A2SpaceM],
        [_label.trailingAnchor constraintLessThanOrEqualToAnchor:_box.trailingAnchor
                                                        constant:-A2SpaceM],

        [_field.leadingAnchor constraintEqualToAnchor:_box.leadingAnchor constant:A2SpaceM],
        [_field.trailingAnchor constraintEqualToAnchor:_box.trailingAnchor constant:-A2SpaceM],
        [_field.topAnchor constraintEqualToAnchor:_box.topAnchor constant:22],
        [_field.bottomAnchor constraintEqualToAnchor:_box.bottomAnchor constant:-6],

        [_underline.leadingAnchor constraintEqualToAnchor:_box.leadingAnchor],
        [_underline.trailingAnchor constraintEqualToAnchor:_box.trailingAnchor],
        [_underline.bottomAnchor constraintEqualToAnchor:_box.bottomAnchor],
        _underlineHeight,

        [_supportLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceM],
        [_supportLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                     constant:-A2SpaceM],
    ]];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleBeginEditing)
                                              name:UITextFieldTextDidBeginEditingNotification
                                            object:_field];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleEndEditing)
                                              name:UITextFieldTextDidEndEditingNotification
                                            object:_field];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 公开属性

- (UITextField *)textField {
    return _field;
}

- (void)setLabelText:(NSString *)labelText {
    _labelText = [labelText copy];
    _label.text = labelText;
}

- (NSString *)text {
    return _field.text;
}

- (void)setText:(NSString *)text {
    _field.text = text;
    [self clearError];
    [self updateFloatingStateAnimated:NO];
}

- (BOOL)isSecure {
    return _field.secureTextEntry;
}

- (void)setSecure:(BOOL)secure {
    _field.secureTextEntry = secure;
}

- (UIKeyboardType)keyboardType {
    return _field.keyboardType;
}

- (void)setKeyboardType:(UIKeyboardType)keyboardType {
    _field.keyboardType = keyboardType;
}

- (UITextAutocapitalizationType)autocapitalizationType {
    return _field.autocapitalizationType;
}

- (void)setAutocapitalizationType:(UITextAutocapitalizationType)type {
    _field.autocapitalizationType = type;
}

- (void)setSupportText:(NSString *)supportText {
    _supportText = [supportText copy];
    [self updateSupportLabel];
}

- (void)setErrorText:(NSString *)errorText {
    _errorText = [errorText copy];
    [self updateSupportLabel];
    [self applyTheme];
}

- (void)clearError {
    if (_errorText.length == 0) return;
    _errorText = nil;
    [self updateSupportLabel];
    [self applyTheme];
}

#pragma mark - 交互

- (void)handleEditingChanged {
    [self clearError];
    [self updateFloatingStateAnimated:YES];
    if (self.onTextChange) self.onTextChange(_field.text ?: @"");
}

- (void)handleBeginEditing {
    [self updateFloatingStateAnimated:YES];
    [self applyTheme];
}

- (void)handleEndEditing {
    [self updateFloatingStateAnimated:YES];
    [self applyTheme];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (self.onReturn) self.onReturn();
    return YES;
}

#pragma mark - 状态

/// 空且未聚焦时标签停在输入行内；聚焦或有内容时上浮到顶部。
- (void)updateFloatingStateAnimated:(BOOL)animated {
    BOOL floating = (_field.isFirstResponder || _field.text.length > 0);
    if (floating == _labelFloating) return;
    _labelFloating = floating;

    _labelRestingCenterY.active = !floating;
    _labelFloatingTop.active = floating;

    void (^changes)(void) = ^{
        self.label.font = floating
            ? [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]
            : [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        [self layoutIfNeeded];
    };
    if (animated) {
        [UIView animateWithDuration:A2AnimDurationFast animations:changes];
    } else {
        changes();
    }
}

- (void)updateSupportLabel {
    NSString *msg = _errorText.length > 0 ? _errorText : _supportText;
    _supportLabel.text = msg;
    _supportLabel.hidden = (msg.length == 0);
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _supportLabel.textColor = _errorText.length > 0 ? t.cError : t.cOnSurfaceVariant;
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    BOOL hasError = (_errorText.length > 0);
    BOOL focused = _field.isFirstResponder;

    _box.backgroundColor = t.cSurfaceContainerHighest;
    _field.textColor = t.cOnSurface;
    _field.tintColor = hasError ? t.cError : t.cPrimary;

    if (hasError) {
        _label.textColor = t.cError;
    } else if (_labelFloating) {
        _label.textColor = focused ? t.cPrimary : t.cOnSurfaceVariant;
    } else {
        _label.textColor = t.cOnSurfaceVariant;
    }

    if (hasError) {
        _underline.backgroundColor = t.cError;
    } else if (focused) {
        _underline.backgroundColor = t.cPrimary;
    } else {
        _underline.backgroundColor = t.cOutlineVariant;
    }

    _underlineHeight.constant = (hasError || focused) ? 2 : 1;

    [self updateSupportLabel];
}

@end
