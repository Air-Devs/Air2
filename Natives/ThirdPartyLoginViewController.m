//
//  ThirdPartyLoginViewController.m
//  Amethyst
//
//  参照 FCL 安卓版：LittleSkin / 自定义第三方登录表单页
//

#import "ThirdPartyLoginViewController.h"
#import "authenticator/ThirdPartyAuthenticator.h"
#import "BackgroundManager.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface ThirdPartyLoginViewController () <UITextFieldDelegate>

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;

@property (nonatomic, strong) UIView *headerCard;
@property (nonatomic, strong) UIImageView *headerIcon;
@property (nonatomic, strong) UILabel *headerTitle;
@property (nonatomic, strong) UILabel *headerSubtitle;

@property (nonatomic, strong) UIView *usernameCard;
@property (nonatomic, strong) UITextField *usernameField;

@property (nonatomic, strong) UIView *passwordCard;
@property (nonatomic, strong) UITextField *passwordField;

@property (nonatomic, strong) UIView *serverCard; // 仅 Custom 模式显示
@property (nonatomic, strong) UITextField *serverField;

@property (nonatomic, strong) UIButton *loginButton;
@property (nonatomic, strong) UIActivityIndicatorView *loginIndicator;
@property (nonatomic, strong) UILabel *errorLabel;
// ★ [ACCT-DUP] 重入守卫：登录请求在飞期间锁死提交入口，防重复提交产生两条账户。
@property (nonatomic) BOOL ameLoginInFlight;

@end

@implementation ThirdPartyLoginViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    // 适配自定义启动器背景：将当前视图控制器透明化，使全局背景壁纸能够透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.view.backgroundColor = [UIColor clearColor];
    self.title = (self.mode == ThirdPartyLoginModeLittleSkin) ? localize(@"i18n_str_2050", nil) : localize(@"i18n_str_1035", nil);

    [self setupUI];
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // 点击空白收起键盘
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];

    // 监听背景 UI 效果变化通知，当用户切换背景效果（半透明/毛玻璃）时重新应用透明化
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// 背景效果改变时重新应用透明化（由 BackgroundUIEffectChanged 通知触发）
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:YES];
}

/// ★ [ACCT-DONE] 离开本页(成功被 pop / 失败退出 / 宿主换走)一律解锁提交态 ——
///   防"回调丢失/宿主未 pop"把提交键永久转圈锁死。放在 viewDidDisappear:此刻视图已不可见,
///   即便成功路径故意保持的 in-flight 锁也一并归还,不会造成"pop 动画间隙可重复提交"。
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self setLoginInProgress:NO];
}

#pragma mark - Setup

- (void)setupUI {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.scrollView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.scrollView];

    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 16;
    self.contentStack.alignment = UIStackViewAlignmentFill;
    [self.scrollView addSubview:self.contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:20],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:20],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-20],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-20],
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-40],
    ]];

    [self buildHeaderCard];
    [self.contentStack addArrangedSubview:self.headerCard];

    [self buildUsernameCard];
    [self.contentStack addArrangedSubview:self.usernameCard];

    [self buildPasswordCard];
    [self.contentStack addArrangedSubview:self.passwordCard];

    if (self.mode == ThirdPartyLoginModeCustom) {
        [self buildServerCard];
        [self.contentStack addArrangedSubview:self.serverCard];
    }

    // 错误提示（默认隐藏）
    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorLabel.font = [UIFont systemFontOfSize:13];
    self.errorLabel.textColor = [UIColor systemRedColor];
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.textAlignment = NSTextAlignmentCenter;
    self.errorLabel.hidden = YES;
    [self.contentStack addArrangedSubview:self.errorLabel];

    [self buildLoginButton];
    [self.contentStack addArrangedSubview:self.loginButton];

    // 注册键盘事件，滚动避免遮挡
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)buildHeaderCard {
    self.headerCard = [[UIView alloc] init];
    self.headerCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.headerCard.layer.cornerRadius = 16;
    self.headerCard.layer.cornerCurve = kCACornerCurveContinuous;   // ★ [CORNER-FIX] 连续圆角(与系统卡片一致)
    [[BackgroundManager sharedManager] applyEffectToView:self.headerCard];

    self.headerIcon = [[UIImageView alloc] init];
    self.headerIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerIcon.contentMode = UIViewContentModeScaleAspectFit;

    self.headerTitle = [[UILabel alloc] init];
    self.headerTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerTitle.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    self.headerTitle.textColor = [UIColor labelColor];

    self.headerSubtitle = [[UILabel alloc] init];
    self.headerSubtitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerSubtitle.font = [UIFont systemFontOfSize:13];
    self.headerSubtitle.textColor = [UIColor secondaryLabelColor];
    self.headerSubtitle.numberOfLines = 0;

    if (self.mode == ThirdPartyLoginModeLittleSkin) {
        self.headerIcon.image = [UIImage systemImageNamed:@"person.fill.viewfinder"]
                              ?: [UIImage systemImageNamed:@"person.crop.circle.fill"];
        self.headerIcon.tintColor = [UIColor systemPurpleColor];
        self.headerTitle.text = @"LittleSkin";
        self.headerSubtitle.text = localize(@"i18n_str_1036", nil);
    } else {
        self.headerIcon.image = [UIImage systemImageNamed:@"globe"];
        self.headerIcon.tintColor = [UIColor systemOrangeColor];
        self.headerTitle.text = localize(@"i18n_str_1037", nil);
        self.headerSubtitle.text = localize(@"i18n_str_1038", nil);
    }

    [self.headerCard addSubview:self.headerIcon];
    [self.headerCard addSubview:self.headerTitle];
    [self.headerCard addSubview:self.headerSubtitle];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerIcon.leadingAnchor constraintEqualToAnchor:self.headerCard.leadingAnchor constant:16],
        [self.headerIcon.topAnchor constraintEqualToAnchor:self.headerCard.topAnchor constant:18],
        [self.headerIcon.widthAnchor constraintEqualToConstant:34],
        [self.headerIcon.heightAnchor constraintEqualToConstant:34],

        [self.headerTitle.leadingAnchor constraintEqualToAnchor:self.headerIcon.trailingAnchor constant:12],
        [self.headerTitle.centerYAnchor constraintEqualToAnchor:self.headerIcon.centerYAnchor],
        [self.headerTitle.trailingAnchor constraintEqualToAnchor:self.headerCard.trailingAnchor constant:-16],

        [self.headerSubtitle.leadingAnchor constraintEqualToAnchor:self.headerCard.leadingAnchor constant:16],
        [self.headerSubtitle.topAnchor constraintEqualToAnchor:self.headerIcon.bottomAnchor constant:10],
        [self.headerSubtitle.trailingAnchor constraintEqualToAnchor:self.headerCard.trailingAnchor constant:-16],
        [self.headerSubtitle.bottomAnchor constraintEqualToAnchor:self.headerCard.bottomAnchor constant:-16],
    ]];
}

/// 构建统一的输入卡片：左侧 SF Symbol 图标 + 右侧 UITextField
/// 返回卡片视图，并将创建好的 UITextField 赋值到 outField（可选）
- (UIView *)buildInputCardWithIcon:(NSString *)iconName
                       accentColor:(UIColor *)accentColor
                        placeholder:(NSString *)placeholder
                            isSecure:(BOOL)isSecure
                        keyboardType:(UIKeyboardType)keyboardType
                         returnField:(UITextField **)outField {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 14;
    card.layer.cornerCurve = kCACornerCurveContinuous;   // ★ [CORNER-FIX] 连续圆角(与系统卡片一致)
    [[BackgroundManager sharedManager] applyEffectToView:card];

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.image = [UIImage systemImageNamed:iconName];
    icon.tintColor = accentColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:icon];

    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholder = placeholder;
    field.font = [UIFont systemFontOfSize:16];
    field.textColor = [UIColor labelColor];
    field.secureTextEntry = isSecure;
    field.keyboardType = keyboardType;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.delegate = self;
    field.returnKeyType = UIReturnKeyNext;
    [card addSubview:field];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [icon.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:22],
        [icon.heightAnchor constraintEqualToConstant:22],

        [field.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [field.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [field.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [field.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    if (outField) *outField = field;
    return card;
}

- (void)buildUsernameCard {
    UITextField *field = nil;
    self.usernameCard = [self buildInputCardWithIcon:@"person"
                                         accentColor:[UIColor systemBlueColor]
                                          placeholder:localize(@"i18n_str_1039", nil)
                                            isSecure:NO
                                        keyboardType:UIKeyboardTypeDefault
                                         returnField:&field];
    self.usernameField = field;
}

- (void)buildPasswordCard {
    UITextField *field = nil;
    self.passwordCard = [self buildInputCardWithIcon:@"lock"
                                         accentColor:[UIColor systemBlueColor]
                                          placeholder:localize(@"i18n_str_1040", nil)
                                            isSecure:YES
                                        keyboardType:UIKeyboardTypeDefault
                                         returnField:&field];
    self.passwordField = field;
    self.passwordField.returnKeyType = (self.mode == ThirdPartyLoginModeCustom) ? UIReturnKeyNext : UIReturnKeyGo;
}

- (void)buildServerCard {
    UITextField *field = nil;
    self.serverCard = [self buildInputCardWithIcon:@"link"
                                       accentColor:[UIColor systemBlueColor]
                                        placeholder:localize(@"i18n_str_1041", nil)
                                          isSecure:NO
                                      keyboardType:UIKeyboardTypeURL
                                       returnField:&field];
    self.serverField = field;
    self.serverField.text = @"https://littleskin.cn/api/yggdrasil";
    self.serverField.returnKeyType = UIReturnKeyGo;
}

- (void)buildLoginButton {
    self.loginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loginButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loginButton setTitle:localize(@"i18n_str_1042", nil) forState:UIControlStateNormal];
    [self.loginButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.loginButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    UIColor *accent = (self.mode == ThirdPartyLoginModeLittleSkin)
                        ? [UIColor systemPurpleColor]
                        : [UIColor systemOrangeColor];
    self.loginButton.backgroundColor = accent;
    self.loginButton.layer.cornerRadius = 14;
    self.loginButton.layer.cornerCurve = kCACornerCurveContinuous;   // ★ [CORNER-FIX] 连续圆角(与系统卡片一致)
    [self.loginButton addTarget:self action:@selector(loginTapped) forControlEvents:UIControlEventTouchUpInside];

    self.loginIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.loginIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loginIndicator.hidesWhenStopped = YES;
    [self.loginButton addSubview:self.loginIndicator];

    [NSLayoutConstraint activateConstraints:@[
        [self.loginButton.heightAnchor constraintEqualToConstant:50],
        [self.loginIndicator.centerXAnchor constraintEqualToAnchor:self.loginButton.centerXAnchor],
        [self.loginIndicator.centerYAnchor constraintEqualToAnchor:self.loginButton.centerYAnchor],
    ]];
}

#pragma mark - Actions

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)loginTapped {
    // ★ [ACCT-DUP] 重入守卫：登录请求在飞时忽略重复提交（连点/回车），避免同一账户登录两次。
    if (self.ameLoginInFlight) return;
    [self dismissKeyboard];
    [self hideError];

    NSString *username = self.usernameField.text ?: @"";
    NSString *password = self.passwordField.text ?: @"";
    NSString *serverURL = nil;
    if (self.mode == ThirdPartyLoginModeCustom) {
        serverURL = (self.serverField.text.length > 0) ? self.serverField.text : nil;
    } else {
        serverURL = @"https://littleskin.cn/api/yggdrasil";
    }

    // 输入校验
    if (username.length == 0 || password.length == 0) {
        [self showError:localize(@"i18n_str_1043", nil)];
        return;
    }
    if (self.mode == ThirdPartyLoginModeCustom) {
        if (serverURL.length == 0) {
            [self showError:localize(@"i18n_str_1044", nil)];
            return;
        }
        NSURL *url = [NSURL URLWithString:serverURL];
        if (!url || !url.scheme || !url.host) {
            [self showError:localize(@"i18n_str_1045", nil)];
            return;
        }
    }

    [self setLoginInProgress:YES];

    // 参照 authlib-injector 启动器技术规范：登录前先解析 ALI，将简写地址解析为完整 API Root
    // 同时预取服务器元数据，用于启动时传 -Dauthlibinjector.yggdrasil.prefetched
    [self showError:localize(@"i18n_str_1046", nil)];
    self.errorLabel.textColor = [UIColor secondaryLabelColor];

    __weak typeof(self) weakSelf = self;
    [ThirdPartyAuthenticator resolveAuthserverURL:serverURL completion:^(NSString *resolvedURL, NSString *metadata) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        [strongSelf hideError];

        ThirdPartyAuthenticator *auth = [[ThirdPartyAuthenticator alloc] initWithInput:username];
        auth.authData[@"password"] = password;
        auth.authData[@"authserver"] = resolvedURL;
        // 缓存元数据，供 getJvmArgsForAuthlib 使用
        if (metadata.length > 0) {
            auth.authData[@"prefetchedMetadata"] = metadata;
        }

        id callback = ^(id status, BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) sSelf = weakSelf;
                if (!sSelf) return;

                // 状态码为 0 的"进度"消息（如正在下载 authlib-injector）不算最终结果
                if (success && [status isKindOfClass:[NSError class]] &&
                    [(NSError *)status code] == 0) {
                    NSString *msg = [(NSError *)status localizedDescription];
                    if (msg.length > 0) {
                        [sSelf.errorLabel setText:msg];
                        sSelf.errorLabel.textColor = [UIColor secondaryLabelColor];
                        sSelf.errorLabel.hidden = NO;
                    }
                    return;
                }

                [sSelf hideError];

                if (success && (status == nil ||
                                ([status isKindOfClass:[NSString class]] && [status isEqualToString:@"DEMO"]))) {
                    if ([status isKindOfClass:[NSString class]] && [status isEqualToString:@"DEMO"]) {
                        showDialog(localize(@"login.warn.title.demomode", nil),
                                   localize(@"login.warn.message.demomode", nil));
                    }
                    // ★ [ACCT-DUP] 成功后本页会被宿主 pop：**保持** in-flight 锁（不调 setLoginInProgress:NO），
                    //   避免 pop 动画的间隙里按钮又可点、重复提交同一账户。
                    if (sSelf.onLoginComplete) {
                        sSelf.onLoginComplete(YES, nil);
                    }
                    return;
                }

                // 失败：恢复交互，允许重试（★ [ACCT-DUP] 与 in-flight 标志同步解锁）
                [sSelf setLoginInProgress:NO];
                NSString *errMsg;
                if ([status isKindOfClass:[NSError class]]) {
                    errMsg = [(NSError *)status localizedDescription];
                } else if ([status isKindOfClass:[NSString class]]) {
                    errMsg = status;
                } else {
                    errMsg = localize(@"i18n_str_1047", nil);
                }
                [sSelf showError:errMsg];
                if (sSelf.onLoginComplete) {
                    sSelf.onLoginComplete(NO, errMsg);
                }
            });
        };

        [auth loginWithCallback:callback];
    }];
}

- (void)setLoginInProgress:(BOOL)inProgress {
    // ★ [ACCT-DUP] 与 UI 禁用同步的重入标志：置位即锁死 loginTapped，恢复时解锁。
    self.ameLoginInFlight = inProgress;
    self.loginButton.userInteractionEnabled = !inProgress;
    self.usernameField.userInteractionEnabled = !inProgress;
    self.passwordField.userInteractionEnabled = !inProgress;
    self.serverField.userInteractionEnabled = !inProgress;

    if (inProgress) {
        [self.loginIndicator startAnimating];
        [self.loginButton setTitle:@"" forState:UIControlStateNormal];
        self.loginButton.alpha = 0.85;
    } else {
        [self.loginIndicator stopAnimating];
        [self.loginButton setTitle:localize(@"i18n_str_1042", nil) forState:UIControlStateNormal];
        self.loginButton.alpha = 1.0;
    }
}

- (void)showError:(NSString *)message {
    self.errorLabel.text = message;
    self.errorLabel.textColor = [UIColor systemRedColor];
    self.errorLabel.hidden = NO;
}

- (void)hideError {
    self.errorLabel.hidden = YES;
    self.errorLabel.text = @"";
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.usernameField) {
        [self.passwordField becomeFirstResponder];
    } else if (textField == self.passwordField) {
        if (self.mode == ThirdPartyLoginModeCustom && self.serverField) {
            [self.serverField becomeFirstResponder];
        } else {
            [self loginTapped];
        }
    } else if (textField == self.serverField) {
        [self loginTapped];
    }
    return YES;
}

#pragma mark - Keyboard

- (void)keyboardWillShow:(NSNotification *)notification {
    CGRect endFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat keyboardHeight = endFrame.size.height;
    UIEdgeInsets insets = self.scrollView.contentInset;
    insets.bottom = keyboardHeight + 20;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)keyboardWillHide:(NSNotification *)notification {
    UIEdgeInsets insets = UIEdgeInsetsZero;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
