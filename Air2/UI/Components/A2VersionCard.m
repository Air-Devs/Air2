//
//  A2VersionCard.m
//  Air2
//

#import "A2VersionCard.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2VersionCard ()
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *initialLabel;   // 无图标时的字母占位
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UIImageView *pinBadge;
@property (nonatomic, strong) UIView *selectionRing;
@end

@implementation A2VersionCard

- (instancetype)initWithVersionName:(NSString *)name meta:(NSString *)meta {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _versionName = [name copy];
    _meta = [meta copy];
    _status = A2VersionCardStatusAvailable;
    [self setupContent];
    return self;
}

- (void)setupContent {
    self.cornerRadius = A2RadiusL;
    self.tappable = YES;
    self.contentInsets = UIEdgeInsetsMake(A2SpaceM, A2SpaceM, A2SpaceM, A2SpaceM);

    __weak typeof(self) weakSelf = self;
    self.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self.onSelect) self.onSelect();
    };

    // ---- 图标容器 ----
    UIView *iconBox = [[UIView alloc] initWithFrame:CGRectZero];
    iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    iconBox.layer.cornerRadius = A2RadiusS;
    iconBox.layer.cornerCurve = kCACornerCurveContinuous;
    iconBox.clipsToBounds = YES;
    iconBox.tag = 200;

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFill;
    _iconView.hidden = YES;
    [iconBox addSubview:_iconView];

    _initialLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _initialLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _initialLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    _initialLabel.textAlignment = NSTextAlignmentCenter;
    [iconBox addSubview:_initialLabel];

    // ---- 文字 ----
    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [A2Typography titleCard];
    _nameLabel.numberOfLines = 1;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.75;
    _nameLabel.text = _versionName;

    _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metaLabel.font = [A2Typography caption];
    _metaLabel.numberOfLines = 1;
    _metaLabel.text = _meta;
    _metaLabel.hidden = (_meta.length == 0);

    // ---- 状态点 ----
    _statusDot = [[UIView alloc] initWithFrame:CGRectZero];
    _statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    _statusDot.layer.cornerRadius = 3.5;
    _statusDot.hidden = YES;

    // ---- 置顶角标 ----
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold];
    _pinBadge = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"pin.fill" withConfiguration:cfg]];
    _pinBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _pinBadge.hidden = YES;
    _pinBadge.tag = 201;

    // ---- 选中描边 ----
    _selectionRing = [[UIView alloc] initWithFrame:CGRectZero];
    _selectionRing.translatesAutoresizingMaskIntoConstraints = NO;
    _selectionRing.userInteractionEnabled = NO;
    _selectionRing.layer.cornerRadius = A2RadiusL;
    _selectionRing.layer.cornerCurve = kCACornerCurveContinuous;
    _selectionRing.layer.borderWidth = 1.8;
    _selectionRing.hidden = YES;
    [self addSubview:_selectionRing];

    UIView *cv = self.contentView;
    [cv addSubview:iconBox];
    [cv addSubview:_nameLabel];
    [cv addSubview:_metaLabel];
    [cv addSubview:_statusDot];
    [cv addSubview:_pinBadge];

    [NSLayoutConstraint activateConstraints:@[
        [iconBox.topAnchor constraintEqualToAnchor:cv.topAnchor],
        [iconBox.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
        [iconBox.widthAnchor constraintEqualToConstant:34],
        [iconBox.heightAnchor constraintEqualToConstant:34],

        [_iconView.topAnchor constraintEqualToAnchor:iconBox.topAnchor],
        [_iconView.bottomAnchor constraintEqualToAnchor:iconBox.bottomAnchor],
        [_iconView.leadingAnchor constraintEqualToAnchor:iconBox.leadingAnchor],
        [_iconView.trailingAnchor constraintEqualToAnchor:iconBox.trailingAnchor],

        [_initialLabel.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor],
        [_initialLabel.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],

        [_pinBadge.topAnchor constraintEqualToAnchor:cv.topAnchor],
        [_pinBadge.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],

        [_nameLabel.topAnchor constraintEqualToAnchor:iconBox.bottomAnchor constant:A2SpaceS],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],

        [_metaLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
        [_metaLabel.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
        [_metaLabel.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
        [_metaLabel.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor],

        [_statusDot.centerYAnchor constraintEqualToAnchor:_metaLabel.centerYAnchor],
        [_statusDot.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
        [_statusDot.widthAnchor constraintEqualToConstant:7],
        [_statusDot.heightAnchor constraintEqualToConstant:7],

        [_selectionRing.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_selectionRing.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_selectionRing.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_selectionRing.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];

    // 长按
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    lp.minimumPressDuration = 0.45;
    [self addGestureRecognizer:lp];

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

- (void)setVersionName:(NSString *)versionName {
    _versionName = [versionName copy];
    _nameLabel.text = versionName;
    [self updateInitial];
}

- (void)setMeta:(NSString *)meta {
    _meta = [meta copy];
    _metaLabel.text = meta;
    _metaLabel.hidden = (meta.length == 0);
}

- (void)setVersionIcon:(UIImage *)versionIcon {
    _versionIcon = versionIcon;
    _iconView.image = versionIcon;
    _iconView.hidden = (versionIcon == nil);
    _initialLabel.hidden = (versionIcon != nil);
    [self applyTheme];
}

- (void)setPinned:(BOOL)pinned {
    _pinned = pinned;
    _pinBadge.hidden = !pinned;
}

- (void)setStatus:(A2VersionCardStatus)status {
    _status = status;
    _statusDot.hidden = (status == A2VersionCardStatusAvailable ||
                         status == A2VersionCardStatusLoading);
    [self applyTheme];

    switch (status) {
        case A2VersionCardStatusDeleted:
            self.alpha = 0.62;
            _metaLabel.text = _meta.length ? _meta : @"版本已删除";
            break;
        case A2VersionCardStatusInaccessible:
            self.alpha = 0.45;
            _metaLabel.text = @"目录不可访问";
            _metaLabel.hidden = NO;
            break;
        case A2VersionCardStatusLoading:
            self.alpha = 1.0;
            break;
        case A2VersionCardStatusAvailable:
        default:
            self.alpha = 1.0;
            _metaLabel.text = _meta;
            _metaLabel.hidden = (_meta.length == 0);
            break;
    }
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    _selectionRing.hidden = !selected;
}

#pragma mark - 辅助

- (void)updateInitial {
    NSString *initial = _versionName.length > 0 ? [_versionName substringToIndex:1] : @"?";
    _initialLabel.text = [initial uppercaseString];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];
    if (self.onLongPress) self.onLongPress();
}

#pragma mark - 主题

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ThemeManager *tm = A2ThemeManager.shared;
    A2ColorScheme *t = tm.scheme;

    _nameLabel.textColor = t.onSurface;
    _metaLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];

    UIView *iconBox = [self.contentView viewWithTag:200];
    if (iconBox) {
        // 有图标时透明底，无图标时用主题色渐变底
        iconBox.backgroundColor = _versionIcon ? UIColor.clearColor
                                               : [t.primary colorWithAlphaComponent:0.85];
    }
    _initialLabel.textColor = UIColor.whiteColor;
    _pinBadge.tintColor = t.primary;

    _selectionRing.layer.borderColor = t.primary.CGColor;

    if (!_statusDot.hidden) {
        _statusDot.backgroundColor = (_status == A2VersionCardStatusDeleted)
            ? t.error
            : t.outline;
    }
}

@end
