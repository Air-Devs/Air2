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
//  三种登录方式共用一个页面：顶部 MD3 分段控件切换，下方内容随模式重建。
//  微软是「展示设备码 + 轮询」，离线 / 第三方是「表单输入」。
//
//  登录成功后统一走 finishLoginWithAccount:，会写入账号目录（见
//  A2AccountManager）并自动切换为当前账号。
//

#import <SafariServices/SafariServices.h>

#import "A2LoginViewController.h"
#import "A2MicrosoftAuth.h"
#import "A2AccountManager.h"
#import "A2Account.h"
#import "A2Log.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2SettingsSection.h"
#import "A2TextField.h"
#import "A2SegmentedControl.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2LoginViewController ()
@property (nonatomic, assign) A2LoginMode mode;
@property (nonatomic, strong) A2MicrosoftAuth *msAuth;
@property (nonatomic, strong) A2SegmentedControl *segmented;
/// 当前模式的内容容器，切换模式时整体重建
@property (nonatomic, strong) UIStackView *modeStack;

// ---- 微软设备码 ----
@property (nonatomic, strong, nullable) A2DeviceCodeInfo *deviceInfo;
@property (nonatomic, strong, nullable) UILabel *codeLabel;
@property (nonatomic, strong, nullable) UILabel *hintLabel;
// 不叫 copyButton：以 copy 开头的属性会被 clang 判为 Cocoa 的 copy 族
// （约定返回 +1 对象），直接报 property follows Cocoa naming convention 编译失败。
@property (nonatomic, strong, nullable) A2PrimaryButton *codeCopyButton;
@property (nonatomic, strong, nullable) A2PrimaryButton *openButton;

// ---- 表单（离线 / 第三方）----
@property (nonatomic, strong, nullable) A2TextField *serverField;
@property (nonatomic, strong, nullable) A2TextField *nameField;
@property (nonatomic, strong, nullable) A2TextField *passField;
@property (nonatomic, strong, nullable) A2PrimaryButton *loginButton;

@property (nonatomic, assign) BOOL loggingIn;
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

    _modeStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _modeStack.axis = UILayoutConstraintAxisVertical;
    _modeStack.spacing = A2SpaceL;

    _segmented = [[A2SegmentedControl alloc] initWithTitles:@[@"正版", @"离线", @"第三方"]];
    __weak typeof(self) weakSelf = self;
    _segmented.onSegmentChange = ^(NSInteger index) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self applyMode:(A2LoginMode)index];
    };

    [self addSection:_segmented];
    [self addSection:_modeStack];

    [self applyMode:_mode];
}

#pragma mark - 模式切换

- (void)applyMode:(A2LoginMode)mode {
    // 切换前先停掉上一个模式可能还在跑的轮询
    [_msAuth cancel];

    NSArray<UIView *> *oldViews = [_modeStack.arrangedSubviews copy];
    for (UIView *v in oldViews) {
        [_modeStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    _deviceInfo = nil;
    _codeLabel = nil;
    _hintLabel = nil;
    _codeCopyButton = nil;
    _openButton = nil;
    _serverField = nil;
    _nameField = nil;
    _passField = nil;
    _loginButton = nil;
    _loggingIn = NO;

    _mode = mode;
    _segmented.selectedIndex = mode;
    [A2Log log:@"Login: 切换到登录方式 %ld", (long)mode];

    switch (mode) {
        case A2LoginModeMicrosoft:
            self.pageTitle = @"正版账号登录";
            [self buildMicrosoftUI];
            [self beginMicrosoftLogin];
            break;
        case A2LoginModeOffline:
            self.pageTitle = @"离线登录";
            [self buildFormUI];
            break;
        case A2LoginModeThirdParty:
            self.pageTitle = @"第三方认证服务器";
            [self buildFormUI];
            break;
    }
}

#pragma mark - 微软：设备码

- (void)buildMicrosoftUI {
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
    _codeLabel.font = [UIFont monospacedSystemFontOfSize:34 weight:UIFontWeightBold];
    _codeLabel.textColor = t.cPrimary;
    _codeLabel.textAlignment = NSTextAlignmentCenter;
    _codeLabel.adjustsFontSizeToFitWidth = YES;
    _codeLabel.minimumScaleFactor = 0.5;
    _codeLabel.text = @"————";

    _hintLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _hintLabel.font = [A2Typography caption];
    _hintLabel.textColor = t.cOnSurfaceVariant;
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.numberOfLines = 3;
    _hintLabel.text = @"正在获取设备码…";

    _codeCopyButton = [[A2PrimaryButton alloc] initWithTitle:@"复制代码"
                                                       style:A2ButtonStyleSecondary];
    _codeCopyButton.icon = [UIImage systemImageNamed:@"doc.on.doc"];
    [_codeCopyButton addTarget:self action:@selector(copyDeviceCode)
              forControlEvents:UIControlEventTouchUpInside];
    _codeCopyButton.enabled = NO;
    _codeCopyButton.alpha = 0.5;

    _openButton = [[A2PrimaryButton alloc] initWithTitle:@"打开授权页面"
                                                   style:A2ButtonStylePrimary];
    _openButton.icon = [UIImage systemImageNamed:@"safari"];
    [_openButton addTarget:self action:@selector(openVerificationPage)
          forControlEvents:UIControlEventTouchUpInside];
    _openButton.enabled = NO;
    _openButton.alpha = 0.5;

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:
                            @[_codeCopyButton, _openButton]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = A2SpaceM;
    buttons.distribution = UIStackViewDistributionFillEqually;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[title, _codeLabel, _hintLabel, buttons]];
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

    [_modeStack addArrangedSubview:card];

    A2SettingsSection *tips = [[A2SettingsSection alloc] initWithTitle:nil];
    tips.footerText = @"设备码登录不需要在启动器里输入密码，"
                       "所有账号信息都由微软官方页面收集，本应用无法接触你的密码。";
    [_modeStack addArrangedSubview:tips];
}

- (void)beginMicrosoftLogin {
    __weak typeof(self) weakSelf = self;
    [A2Log log:@"Login: 开始请求微软设备码"];
    [_msAuth requestDeviceCode:^(A2DeviceCodeInfo *info, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (error) {
            [A2Log log:@"Login: 获取设备码失败 %@", error.localizedDescription ?: @"未知错误"];
            self.hintLabel.text = error.localizedDescription ?: @"获取设备码失败";
            [A2Toast show:@"获取设备码失败" inView:self.view];
            return;
        }

        [A2Log log:@"Login: 拿到设备码，开始轮询授权结果"];
        self.deviceInfo = info;
        self.codeLabel.text = info.userCode;
        // 自动复制：用户接下来要切到浏览器粘贴，省掉手动点「复制代码」这一步
        UIPasteboard.generalPasteboard.string = info.userCode;
        self.hintLabel.text = [NSString stringWithFormat:
            @"代码已复制到剪贴板\n访问 %@ 输入上方代码完成登录", info.verificationURI];
        self.codeCopyButton.enabled = YES;
        self.codeCopyButton.alpha = 1.0;
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
            [self finishLoginWithAccount:account
                                 message:[NSString stringWithFormat:@"已登录：%@", account.username]];
        } else {
            NSString *msg = error.localizedDescription ?: @"登录失败";
            [A2Log log:@"Login: 微软轮询结束但未拿到账号 %@", msg];
            self.hintLabel.text = msg;
            [A2Toast show:msg inView:self.view];
        }
    }];
}

- (void)copyDeviceCode {
    NSString *code = _deviceInfo.userCode;
    if (code.length == 0) return;
    UIPasteboard.generalPasteboard.string = code;
    [A2Toast show:@"代码已复制" inView:self.view];
}

- (void)openVerificationPage {
    if (_deviceInfo.verificationURI.length == 0) return;
    NSURL *url = [NSURL URLWithString:_deviceInfo.verificationURI];
    if (!url) return;

    // 用应用内 Safari 而不是跳出去：授权页盖在启动器上，
    // 用户输完码可以直接关掉回来，不用靠手动切 App。
    [A2Log log:@"Login: 打开微软授权页"];
    SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
    safari.preferredControlTintColor = A2ThemeManager.shared.scheme.cPrimary;
    [self presentViewController:safari animated:YES completion:nil];
}

#pragma mark - 表单（离线 / 第三方）

- (void)buildFormUI {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationLow;

    NSMutableArray<UIView *> *fields = [NSMutableArray array];

    if (_mode == A2LoginModeThirdParty) {
        _serverField = [[A2TextField alloc] initWithLabel:@"认证服务器地址"];
        _serverField.text = @"https://littleskin.cn/api/yggdrasil";
        _serverField.keyboardType = UIKeyboardTypeURL;
        _serverField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _serverField.supportText = @"兼容 Yggdrasil 协议，如 LittleSkin、Blessing Skin";
        [fields addObject:_serverField];

        _nameField = [[A2TextField alloc] initWithLabel:@"用户名或邮箱"];
    } else {
        _nameField = [[A2TextField alloc] initWithLabel:@"用户名"];
        _nameField.supportText = @"3-16 个字符，仅字母、数字与下划线";
    }
    _nameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [fields addObject:_nameField];

    if (_mode == A2LoginModeThirdParty) {
        _passField = [[A2TextField alloc] initWithLabel:@"密码"];
        _passField.secure = YES;
        [fields addObject:_passField];
    }

    UIStackView *fieldStack = [[UIStackView alloc] initWithArrangedSubviews:fields];
    fieldStack.translatesAutoresizingMaskIntoConstraints = NO;
    fieldStack.axis = UILayoutConstraintAxisVertical;
    fieldStack.spacing = A2SpaceL;

    [card.contentView addSubview:fieldStack];
    [NSLayoutConstraint activateConstraints:@[
        [fieldStack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [fieldStack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [fieldStack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [fieldStack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [_modeStack addArrangedSubview:card];

    _loginButton = [[A2PrimaryButton alloc] initWithTitle:@"登录"
                                                    style:A2ButtonStylePrimary];
    _loginButton.icon = [UIImage systemImageNamed:@"person.badge.key.fill"];
    [_loginButton addTarget:self action:@selector(performLogin)
           forControlEvents:UIControlEventTouchUpInside];
    [_modeStack addArrangedSubview:_loginButton];

    // 回车直接提交
    __weak typeof(self) weakSelf = self;
    A2TextField *lastField = _passField ?: _nameField;
    lastField.onReturn = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self performLogin];
    };

    A2SettingsSection *tips = [[A2SettingsSection alloc] initWithTitle:nil];
    tips.footerText = (_mode == A2LoginModeOffline)
        ? @"离线模式仅需用户名。可用于单机游戏与离线服务器，无法加入正版验证服务器。"
        : @"支持任何兼容 Yggdrasil 协议的认证服务器，如 LittleSkin、Blessing Skin。";
    [_modeStack addArrangedSubview:tips];
}

#pragma mark - 登录

- (void)performLogin {
    if (_loggingIn) return;

    if (_mode == A2LoginModeOffline) {
        NSString *offlineError = [self validateOfflineName:_nameField.text];
        if (offlineError) {
            [A2Log log:@"Login: 离线用户名校验失败 %@", offlineError];
            _nameField.errorText = offlineError;
            [A2Toast show:offlineError inView:self.view];
            return;
        }
        A2Account *acc = [[A2AccountManager shared] createOfflineAccountWithName:_nameField.text];
        [A2Log log:@"Login: 创建离线账号 %@", _nameField.text];
        [self finishLoginWithAccount:acc
                             message:[NSString stringWithFormat:@"已创建离线账号：%@", _nameField.text]];
        return;
    }

    // 第三方：服务器地址需要能解析出 http/https，账号密码不能为空
    NSString *serverError = [self validateServerURL:_serverField.text];
    _serverField.errorText = serverError;
    _nameField.errorText = _nameField.text.length == 0 ? @"请输入用户名或邮箱" : nil;
    _passField.errorText = _passField.text.length == 0 ? @"请输入密码" : nil;
    if (serverError || _nameField.errorText.length > 0 || _passField.errorText.length > 0) {
        [A2Log log:@"Login: 第三方表单校验失败 %@",
                    serverError ?: @"账号或密码为空"];
        [A2Toast show:@"请检查填写内容" inView:self.view];
        return;
    }

    [A2Log log:@"Login: 开始第三方认证 %@", _serverField.text];
    [self setLoggingIn:YES];
    __weak typeof(self) weakSelf = self;
    A2YggdrasilAuth *auth = [A2YggdrasilAuth new];
    [auth authenticateWithServer:_serverField.text
                        username:_nameField.text
                        password:_passField.text
                      completion:^(A2Account *account, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        [self setLoggingIn:NO];
        if (account) {
            [self finishLoginWithAccount:account
                                 message:[NSString stringWithFormat:@"已登录：%@", account.username]];
        } else {
            NSString *msg = error.localizedDescription ?: @"登录失败";
            [A2Log log:@"Login: 第三方认证失败 %@", msg];
            self.passField.errorText = msg;
            [A2Toast show:msg inView:self.view];
        }
    }];
}

/// 登录成功：写盘 + 自动切换为当前账号 + 回调 + 返回上一页。
- (void)finishLoginWithAccount:(A2Account *)account message:(NSString *)message {
    A2AccountManager *manager = A2AccountManager.shared;
    [manager addAccount:account];
    // 登录完就把新账号设为当前账号，而不是留在列表里让用户再点一次
    (void)[manager selectCurrentAccount:account];
    [A2Log log:@"Login: 登录成功并已切换为当前账号 %@", account.username];

    [A2Toast show:message inView:self.view];
    UINotificationFeedbackGenerator *fb = [UINotificationFeedbackGenerator new];
    [fb notificationOccurred:UINotificationFeedbackTypeSuccess];

    if (self.onSuccess) self.onSuccess(account);

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf.navigationController popViewControllerAnimated:YES];
    });
}

- (void)setLoggingIn:(BOOL)loggingIn {
    _loggingIn = loggingIn;
    _loginButton.loading = loggingIn;
    _serverField.textField.enabled = !loggingIn;
    _nameField.textField.enabled = !loggingIn;
    _passField.textField.enabled = !loggingIn;
}

#pragma mark - 校验

/// 离线用户名会同时作为游戏内名字，按官方规则限制。
- (NSString *)validateOfflineName:(NSString *)name {
    if (name.length == 0) return @"请输入用户名";
    if (name.length < 3 || name.length > 16) return @"用户名长度为 3-16 个字符";

    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
    NSCharacterSet *input = [NSCharacterSet characterSetWithCharactersInString:name];
    if (![allowed isSupersetOfSet:input]) return @"只能包含字母、数字与下划线";
    return nil;
}

- (NSString *)validateServerURL:(NSString *)urlString {
    if (urlString.length == 0) return @"请输入服务器地址";

    NSURL *url = [NSURL URLWithString:urlString];
    BOOL schemeOK = [url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"];
    if (url.host.length == 0 || !schemeOK) return @"地址需以 http:// 或 https:// 开头";
    return nil;
}

@end
