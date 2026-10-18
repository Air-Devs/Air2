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

#import "A2InputDialog.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2InputDialog () <UITextFieldDelegate>

@property (nonatomic, copy, nullable) NSString *placeholder;
@property (nonatomic, copy, nullable) NSString *initialText;
@property (nonatomic, copy, nullable) A2InputDialogValidator validateBlock;
@property (nonatomic, copy, nullable) A2InputDialogConfirm confirmBlock;

@property (nonatomic, strong) UIView *fieldContainer;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UILabel *supportingLabel;

@property (nonatomic, assign) BOOL fieldFocused;
@property (nonatomic, assign) BOOL showsError;

@end

@implementation A2InputDialog

- (instancetype)initWithTitle:(NSString *)title
                  placeholder:(NSString *)placeholder
                  initialText:(NSString *)initialText
                     validate:(A2InputDialogValidator)validate {
    self = [super init];
    if (self) {
        self.titleText = title;
        _placeholder = [placeholder copy];
        _initialText = [initialText copy];
        _validateBlock = [validate copy];
    }
    return self;
}

- (instancetype)init {
    return [self initWithTitle:nil placeholder:nil initialText:nil validate:nil];
}

+ (void)presentOver:(UIViewController *)host
              title:(NSString *)title
        placeholder:(NSString *)placeholder
        initialText:(NSString *)initialText
           validate:(A2InputDialogValidator)validate
        cancelTitle:(NSString *)cancelTitle
       confirmTitle:(NSString *)confirmTitle
          onConfirm:(A2InputDialogConfirm)onConfirm {
    A2InputDialog *dialog = [[A2InputDialog alloc] initWithTitle:title
                                                    placeholder:placeholder
                                                    initialText:initialText
                                                       validate:validate];
    dialog.confirmBlock = onConfirm;
    [dialog addButtonRowWithCancelTitle:cancelTitle
                           cancelAction:nil
                           confirmTitle:confirmTitle
                          confirmAction:nil];
    [dialog presentOver:host];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [self buildField];
    [self applyTheme];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.textField becomeFirstResponder];
}

#pragma mark - 输入框

- (void)buildField {
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.layer.cornerRadius = A2RadiusM;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    container.layer.borderWidth = 1.0;
    [self.contentStack addArrangedSubview:container];
    _fieldContainer = container;

    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.font = [A2Typography body];
    field.borderStyle = UITextBorderStyleNone;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.returnKeyType = UIReturnKeyDone;
    field.delegate = self;
    field.text = self.initialText;
    [container addSubview:field];
    _textField = field;

    UILabel *supporting = [[UILabel alloc] initWithFrame:CGRectZero];
    supporting.numberOfLines = 0;
    supporting.font = [A2Typography caption];
    supporting.hidden = YES;
    [self.contentStack addArrangedSubview:supporting];
    _supportingLabel = supporting;

    [NSLayoutConstraint activateConstraints:@[
        [container.heightAnchor constraintEqualToConstant:A2ButtonHeight],
        [field.topAnchor constraintEqualToAnchor:container.topAnchor],
        [field.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [field.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:A2SpaceL],
        [field.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-A2SpaceL],
    ]];

    [self updatePlaceholder];
}

- (void)updatePlaceholder {
    if (self.placeholder.length == 0) {
        self.textField.attributedPlaceholder = nil;
        return;
    }
    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;
    self.textField.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:self.placeholder
                                        attributes:@{NSForegroundColorAttributeName: scheme.cOnSurfaceVariant}];
}

#pragma mark - 确认（重写基类：先校验，不过就留在弹窗里）

- (void)confirmDialog {
    NSString *text = self.textField.text ?: @"";
    NSString *error = self.validateBlock ? self.validateBlock(text) : nil;
    if (error.length > 0) {
        [self showError:error];
        return;
    }

    A2InputDialogConfirm handler = self.confirmBlock;
    [self dismissDialogWithCompletion:^{
        if (handler) {
            handler(text);
        }
    }];
}

- (void)showError:(NSString *)message {
    self.showsError = YES;
    self.supportingLabel.text = message;
    self.supportingLabel.hidden = NO;
    [self applyTheme];
}

#pragma mark - 焦点

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    self.fieldFocused = YES;
    [self applyTheme];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    self.fieldFocused = NO;
    [self applyTheme];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self confirmDialog];
    return YES;
}

#pragma mark - 主题

- (void)applyTheme {
    [super applyTheme];

    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;

    self.fieldContainer.backgroundColor = scheme.cSurfaceContainerHigh;
    self.textField.textColor = scheme.cOnSurface;

    UIColor *borderColor = scheme.cOutlineVariant;
    if (self.showsError) {
        borderColor = scheme.cError;
    } else if (self.fieldFocused) {
        borderColor = scheme.cPrimary;
    }
    self.fieldContainer.layer.borderColor = borderColor.CGColor;
    self.fieldContainer.layer.borderWidth = (self.fieldFocused && !self.showsError) ? 2.0 : 1.0;

    self.supportingLabel.textColor = self.showsError ? scheme.cError : scheme.cOnSurfaceVariant;

    [self updatePlaceholder];
}

@end
