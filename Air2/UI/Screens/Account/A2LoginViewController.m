//
//  A2LoginViewController.m
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

#import "A2LoginViewController.h"
#import "A2MicrosoftAuth.h"
#import "A2AccountManager.h"
#import "A2Account.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2LoginViewController ()
@property (nonatomic, assign) A2LoginMode mode;
@property (nonatomic, strong) A2MicrosoftAuth *msAuth;

// 微软登录
@property (nonatomic, strong, nullable) A2DeviceCodeInfo *deviceInfo;
@property (nonatomic, strong, nullable) UILabel *codeLabel;
@property (nonatomic, strong, nullable) UILabel *hintLabel;
@property (nonatomic, strong, nullable) A2PrimaryButton *openButton;

// 表单登录
@property (nonatomic, strong, nullable) UITextField *nameField;
@property (nonatomic, strong, nullable) UITextField *passField;
@property (nonatomic, strong, nullable) UITextField *serverField;
@end

@implementation A2LoginViewController

- (instancetype)initWithMode:(A2LoginMode)mode {
    self = [super init];
    if (!self) return nil;
    _mode = mode;
    _msAuth = [[A2MicrosoftAuth alloc] init];
    return self;
}

- (void)dealloc {
    [_msAuth cancel];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    switch (_mode) {
        case A2LoginModeMicrosoft:  self.pageTitle = @"Microsoft 登录"; break;
        case A2LoginModeOffline:    self.pageTitle = @"离线登录"; break;
        case A2LoginModeThirdParty: self.pageTitle = @"第三方认证服务器"; break;
    }

    if (_mode == A2LoginModeMicrosoft) {
        [self setupMicrosoftUI];
        [self beginMicrosoftLogin];
    } else {
        [self setupFormUI];
    }
}

#pragma mark - 微软：设备码

- (void)setupMicrosoftUI {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationLow;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.textColor = t.cOnSurface;
    title.text = @"在浏览器中打开下方网址";
    title.textAlignment = NSTextAlignmentCenter;

    _codeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _codeLabel.font = [UIFont monospacedSystemFontOfSize:32 weight:UIFontWeightBold];
    _codeLabel.textColor = t.cPrimary;
    _codeLabel.textAlignment = NSTextAlignmentCenter;
    _codeLabel.text = @"————";

    _hintLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _hintLabel.font = [A2Typography caption];
    _hintLabel.textColor = t.cOnSurfaceVariant;
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.numberOfLines = 3;
    _hintLabel.text = @"正在获取设备码…";

    _openButton = [[A2PrimaryButton alloc] initWithTitle:@"打开授权页面"
                                                   style:A2ButtonStylePrimary];
    _openButton.icon = [UIImage systemImageNamed:@"safari"];
    [_openButton addTarget:self action:@selector(openVerificationPage)
          forControlEvents:UIControlEventTouchUpInside];
    _openButton.enabled = NO;
    _openButton.alpha = 0.5;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[title, _codeLabel, _hintLabel, _openButton]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceL;
    [stack setCustomSpacing:A2SpaceXL afterView:title];
    [stack setCustomSpacing:A2SpaceXL afterView:_hintLabel];

    [card.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:A2SpaceS],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-A2SpaceS],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [self addSection:card];

    // 说明
    A2SettingsSection *tips = [[A2SettingsSection alloc] initWithTitle:nil];
    tips.footerText = @"设备码登录不需要在启动器里输入密码，"
                       "所有账号信息都由微软官方页面收集，本应用无法接触你的密码。";
    [self addSection:tips];
}

- (void)beginMicrosoftLogin {
    __weak typeof(self) weakSelf = self;
    [_msAuth requestDeviceCode:^(A2DeviceCodeInfo *info, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (error) {
            self.hintLabel.text = error.localizedDescription;
            [A2Toast show:@"获取设备码失败" inView:self.view];
            return;
        }

        self.deviceInfo = info;
        self.codeLabel.text = info.userCode;
        self.hintLabel.text = [NSString stringWithFormat:
            @"访问 %@\n输入上方代码完成登录", info.verificationURI];
        self.openButton.enabled = YES;
        self.openButton.alpha = 1.0;

        UINotificationFeedbackGenerator *fb = [UINotificationFeedbackGenerator new];
        [fb notificationOccurred:UINotificationFeedbackTypeSuccess];

        [self startPolling];
    }];
}

- (void)startPolling {
    __weak typeof(self) weakSelf = self;
    [_msAuth waitForAuthorization:_deviceInfo
        progress:^(NSString *message) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self && self.deviceInfo) {
            self.hintLabel.text = [NSString stringWithFormat:@"%@\n\n代码：%@",
                                   message, self.deviceInfo.userCode];
        }
    }
        completion:^(A2Account *account, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (account) {
            [[A2AccountManager shared] addAccount:account];
            [A2Toast show:[NSString stringWithFormat:@"已登录：%@", account.username]
                   inView:self.view];
            UINotificationFeedbackGenerator *fb = [UINotificationFeedbackGenerator new];
            [fb notificationOccurred:UINotificationFeedbackTypeSuccess];

            if (self.onSuccess) self.onSuccess(account);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self.navigationController popViewControllerAnimated:YES];
            });
        } else {
            self.hintLabel.text = error.localizedDescription ?: @"登录失败";
            [A2Toast show:@"登录失败" inView:self.view];
        }
    }];
}

- (void)openVerificationPage {
    if (!_deviceInfo.verificationURI) return;
    NSURL *url = [NSURL URLWithString:_deviceInfo.verificationURI];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

#pragma mark - 表单（离线 / 第三方）

- (void)setupFormUI {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationLow;

    _nameField = [self makeField:@"用户名" secure:NO];
    _passField = [self makeField:@"密码" secure:YES];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_nameField]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceM;

    if (_mode == A2LoginModeThirdParty) {
        _serverField = [self makeField:@"认证服务器地址" secure:NO];
        _serverField.text = @"https://littleskin.cn/api/yggdrasil";
        _serverField.keyboardType = UIKeyboardTypeURL;
        [stack insertArrangedSubview:_serverField atIndex:0];
        [stack addArrangedSubview:_passField];
    }

    [card.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];
    [self addSection:card];

    A2PrimaryButton *loginBtn = [[A2PrimaryButton alloc] initWithTitle:@"登录"
                                                                 style:A2ButtonStylePrimary];
    loginBtn.icon = [UIImage systemImageNamed:@"person.badge.key.fill"];
    [loginBtn addTarget:self action:@selector(performLogin) forControlEvents:UIControlEventTouchUpInside];
    [self addSection:loginBtn];

    A2SettingsSection *tips = [[A2SettingsSection alloc] initWithTitle:nil];
    tips.footerText = (_mode == A2LoginModeOffline)
        ? @"离线模式仅需用户名。可用于单机游戏与离线服务器，无法加入正版验证服务器。"
        : @"支持任何兼容 Yggdrasil 协议的认证服务器，如 LittleSkin、Blessing Skin。";
    [self addSection:tips];
}

- (UITextField *)makeField:(NSString *)placeholder secure:(BOOL)secure {
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectZero];
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.placeholder = placeholder;
    f.secureTextEntry = secure;
    f.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;

    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    f.textColor = t.cOnSurface;
    f.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:placeholder
            attributes:@{NSForegroundColorAttributeName: t.cOnSurfaceVariant}];

    [f.heightAnchor constraintEqualToConstant:44].active = YES;
    return f;
}

- (void)performLogin {
    NSString *name = _nameField.text;
    if (name.length == 0) {
        [A2Toast show:@"请输入用户名" inView:self.view];
        return;
    }

    if (_mode == A2LoginModeOffline) {
        A2Account *acc = [[A2AccountManager shared] createOfflineAccountWithName:name];
        [[A2AccountManager shared] addAccount:acc];
        [A2Toast show:[NSString stringWithFormat:@"已创建离线账号：%@", name] inView:self.view];
        UINotificationFeedbackGenerator *fb = [UINotificationFeedbackGenerator new];
        [fb notificationOccurred:UINotificationFeedbackTypeSuccess];
        if (self.onSuccess) self.onSuccess(acc);
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }

    // 第三方
    if (_passField.text.length == 0) {
        [A2Toast show:@"请输入密码" inView:self.view];
        return;
    }

    [A2Toast show:@"正在登录…" inView:self.view];
    __weak typeof(self) weakSelf = self;
    A2YggdrasilAuth *auth = [A2YggdrasilAuth new];
    [auth authenticateWithServer:_serverField.text
                        username:name
                        password:_passField.text
                      completion:^(A2Account *account, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (account) {
            [[A2AccountManager shared] addAccount:account];
            [A2Toast show:[NSString stringWithFormat:@"已登录：%@", account.username]
                   inView:self.view];
            if (self.onSuccess) self.onSuccess(account);
            [self.navigationController popViewControllerAnimated:YES];
        } else {
            [A2Toast show:(error.localizedDescription ?: @"登录失败") inView:self.view];
        }
    }];
}

@end
