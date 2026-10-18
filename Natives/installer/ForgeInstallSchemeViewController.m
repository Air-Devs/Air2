#import "utils.h"
#import "ForgeInstallSchemeViewController.h"
#import "BackgroundManager.h"

@interface ForgeInstallSchemeViewController ()

@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, strong) UIView *originalCard;
@property (nonatomic, strong) UIView *directCard;
@property (nonatomic, strong) UIButton *closeButton;

@end

@implementation ForgeInstallSchemeViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // 应用毛玻璃效果到根视图
    [[BackgroundManager sharedManager] applyEffectToView:self.view];

    [self setupContentContainer];
    [self setupTitleLabel];
    [self setupCloseButton];
    [self setupStackView];
    [self setupCards];
    [self setupConstraints];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
}

- (void)setupContentContainer {
    self.contentContainer = [[UIView alloc] init];
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.contentContainer];
}

- (void)setupTitleLabel {
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = localize(@"i18n_str_1130", nil);
    self.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:self.titleLabel];
}

- (void)setupCloseButton {
    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    self.closeButton.tintColor = [UIColor secondaryLabelColor];
    self.closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.closeButton addTarget:self action:@selector(actionClose:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentContainer addSubview:self.closeButton];
}

- (void)setupStackView {
    self.stackView = [[UIStackView alloc] init];
    self.stackView.axis = UILayoutConstraintAxisVertical;
    self.stackView.spacing = 16;
    self.stackView.distribution = UIStackViewDistributionFillEqually;
    self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:self.stackView];
}

- (void)setupCards {
    // 直装方案放首位并标注"推荐"：在 iOS 上无需 JIT、无需 AWT、无子进程限制
    self.directCard = [self createCardWithTitle:localize(@"i18n_str_1131", nil)
                                       subtitle:localize(@"i18n_str_1132", nil)
                                           icon:@"bolt.fill"
                                          color:[UIColor systemGreenColor]
                                         scheme:1];

    // 原版方案降级为"高级选项"：依赖 AWT GUI + JIT + 子进程，iOS 上多数场景不可用
    // 仅保留作为某些边缘版本（极老 Forge / 第三方 jar 安装器）的兜底
    self.originalCard = [self createCardWithTitle:localize(@"i18n_str_1133", nil)
                                         subtitle:localize(@"i18n_str_1134", nil)
                                             icon:@"gearshape"
                                            color:[UIColor systemGrayColor]
                                           scheme:0];

    [self.stackView addArrangedSubview:self.directCard];
    [self.stackView addArrangedSubview:self.originalCard];
}

- (UIView *)createCardWithTitle:(NSString *)title
                       subtitle:(NSString *)subtitle
                           icon:(NSString *)iconName
                          color:(UIColor *)color
                         scheme:(NSInteger)scheme {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 16;
    card.layer.cornerCurve = kCACornerCurveContinuous;   // ★ [CORNER-FIX] 连续圆角(与系统卡片一致)
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *iconImageView = [[UIImageView alloc] init];
    UIImage *iconImage = [UIImage systemImageNamed:iconName];
    iconImageView.image = iconImage;
    iconImageView.tintColor = color;
    iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iconImageView];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = subtitle;
    subtitleLabel.font = [UIFont systemFontOfSize:14];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subtitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [iconImageView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [iconImageView.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconImageView.widthAnchor constraintEqualToConstant:32],
        [iconImageView.heightAnchor constraintEqualToConstant:32]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconImageView.trailingAnchor constant:16],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20]
    ]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cardTapped:)];
    [card addGestureRecognizer:tap];
    card.tag = scheme;

    return card;
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [self.contentContainer.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [self.closeButton.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor],
        [self.closeButton.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [self.closeButton.widthAnchor constraintEqualToConstant:32],
        [self.closeButton.heightAnchor constraintEqualToConstant:32]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:8],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.closeButton.leadingAnchor constant:-8]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [self.stackView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:24],
        [self.stackView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.stackView.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [self.stackView.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [self.originalCard.heightAnchor constraintEqualToConstant:100],
        [self.directCard.heightAnchor constraintEqualToConstant:100]
    ]];
}

- (void)cardTapped:(UITapGestureRecognizer *)gesture {
    UIView *card = gesture.view;
    NSInteger scheme = card.tag;

    [UIView animateWithDuration:0.1 animations:^{
        card.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.1 animations:^{
            card.transform = CGAffineTransformIdentity;
        } completion:^(BOOL finished) {
            [self dismissViewControllerAnimated:YES completion:^{
                if ([self.delegate respondsToSelector:@selector(schemeViewController:didSelectScheme:)]) {
                    [self.delegate schemeViewController:self didSelectScheme:scheme];
                }
            }];
        }];
    }];
}

- (void)actionClose:(UIButton *)sender {
    [self dismissViewControllerAnimated:YES completion:^{
        // 通知 delegate 用户取消，避免上游 completionHandler 永久阻塞
        if ([self.delegate respondsToSelector:@selector(schemeViewController:didSelectScheme:)]) {
            [self.delegate schemeViewController:self didSelectScheme:-1];
        }
    }];
}

/// 背景效果变化时重新应用透明化处理与毛玻璃效果，确保背景切换后仍透出全局背景
- (void)reapplyBackgroundEffect {
    // 重新透明化当前 VC
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // 重新应用毛玻璃效果到根视图
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reapplyBackgroundEffect];
    });
}

@end
