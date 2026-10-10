//
//  A2ResourceBadge.m
//  Air2
//

#import "A2ResourceBadge.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

#pragma mark - 平台标签

@interface A2PlatformBadge ()
@property (nonatomic, strong) UILabel *label;
@end

@implementation A2PlatformBadge

- (instancetype)initWithPlatform:(A2ContentPlatform)platform {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = 4;

    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
    _label.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_label];

    [NSLayoutConstraint activateConstraints:@[
        [_label.topAnchor constraintEqualToAnchor:self.topAnchor constant:1],
        [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-1],
        [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:5],
        [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-5],
    ]];

    _platform = platform;
    [self applyTheme];
    return self;
}

- (void)setPlatform:(A2ContentPlatform)platform {
    _platform = platform;
    [self applyTheme];
}

/// 用两家的品牌色，不做主题适配 —— 用户要一眼分辨来源
- (void)applyTheme {
    if (_platform == A2ContentPlatformModrinth) {
        // Modrinth 品牌绿
        _label.text = @"MODRINTH";
        _label.textColor = [UIColor colorWithRed:0.11 green:0.65 blue:0.34 alpha:1.0];
        self.backgroundColor = [_label.textColor colorWithAlphaComponent:0.14];
    } else {
        // CurseForge 品牌橙
        _label.text = @"CURSEFORGE";
        _label.textColor = [UIColor colorWithRed:0.94 green:0.49 blue:0.13 alpha:1.0];
        self.backgroundColor = [_label.textColor colorWithAlphaComponent:0.14];
    }
}

@end

#pragma mark - 类别标签

@interface A2ClassBadge ()
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *label;
@end

@implementation A2ClassBadge

- (instancetype)initWithContentClass:(A2ContentClass)contentClass {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = A2RadiusS;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;

    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];

    [self addSubview:_iconView];
    [self addSubview:_label];

    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintEqualToConstant:18],

        [_iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:5],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:11],
        [_iconView.heightAnchor constraintEqualToConstant:11],

        [_label.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:3],
        [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
        [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];

    _contentClass = contentClass;
    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setContentClass:(A2ContentClass)contentClass {
    _contentClass = contentClass;
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    NSString *symbol = @"cube.fill";
    switch (_contentClass) {
        case A2ContentClassMod:          symbol = @"puzzlepiece.extension.fill"; break;
        case A2ContentClassModPack:      symbol = @"shippingbox.fill"; break;
        case A2ContentClassResourcePack: symbol = @"photo.stack.fill"; break;
        case A2ContentClassShader:       symbol = @"sun.max.fill"; break;
        case A2ContentClassWorld:        symbol = @"map.fill"; break;
        case A2ContentClassDataPack:     symbol = @"doc.fill"; break;
    }

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIImageSymbolWeightSemibold];
    _iconView.image = [UIImage systemImageNamed:symbol withConfiguration:cfg];
    _label.text = A2ClassDisplayName(_contentClass);

    // 用 tertiary 色系 —— 与主色区分，不抢视觉焦点
    _iconView.tintColor = t.cTertiary;
    _label.textColor = t.cTertiary;
    self.backgroundColor = [t.cTertiary colorWithAlphaComponent:0.14];
}

@end

#pragma mark - 已安装标记

@interface A2InstalledBadge ()
@property (nonatomic, strong) UIImageView *checkView;
@end

@implementation A2InstalledBadge

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = 7;

    _checkView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _checkView.translatesAutoresizingMaskIntoConstraints = NO;
    _checkView.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_checkView];

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIImageSymbolWeightBold];
    _checkView.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:cfg];

    [NSLayoutConstraint activateConstraints:@[
        [self.widthAnchor constraintEqualToConstant:14],
        [self.heightAnchor constraintEqualToConstant:14],
        [_checkView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_checkView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setInstalled:(BOOL)installed {
    _installed = installed;
    self.hidden = !installed;
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    self.backgroundColor = t.cTertiary;
    _checkView.tintColor = t.cInverseOnSurface;
}

@end

#pragma mark - 收藏按钮

@interface A2FavoriteButton ()
@property (nonatomic, strong) UIImageView *starView;
@property (nonatomic, strong) UISelectionFeedbackGenerator *feedback;
@end

@implementation A2FavoriteButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _feedback = [UISelectionFeedbackGenerator new];

    _starView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _starView.translatesAutoresizingMaskIntoConstraints = NO;
    _starView.contentMode = UIViewContentModeScaleAspectFit;
    _starView.userInteractionEnabled = NO;
    [self addSubview:_starView];

    [NSLayoutConstraint activateConstraints:@[
        [self.widthAnchor constraintEqualToConstant:A2MinTouchTarget],
        [self.heightAnchor constraintEqualToConstant:A2MinTouchTarget],
        [_starView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_starView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_starView.widthAnchor constraintEqualToConstant:18],
        [_starView.heightAnchor constraintEqualToConstant:18],
    ]];

    [self addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];
    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setFavorite:(BOOL)favorite {
    _favorite = favorite;
    [self applyTheme];

    // 切换时做个轻弹，明确反馈
    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationFast);
    [a addAnimations:^{
        self.starView.transform = CGAffineTransformMakeScale(1.25, 1.25);
    }];
    [a addCompletion:^(UIViewAnimatingPosition pos) {
        UIViewPropertyAnimator *b = A2SpringAnimator(A2AnimDurationFast);
        [b addAnimations:^{ self.starView.transform = CGAffineTransformIdentity; }];
        [b startAnimation];
    }];
    [a startAnimation];
}

- (void)handleTap {
    [_feedback selectionChanged];
    self.favorite = !self.isFavorite;
    if (self.onToggle) self.onToggle(self.isFavorite);
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:17
                                                       weight:_favorite ? UIImageSymbolWeightBold
                                                                        : UIImageSymbolWeightRegular];
    _starView.image = [UIImage systemImageNamed:(_favorite ? @"star.fill" : @"star")
                              withConfiguration:cfg];
    _starView.tintColor = _favorite ? t.cPrimary : t.cOnSurfaceVariant;
}

@end
