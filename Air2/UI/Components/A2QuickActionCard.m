//
//  A2QuickActionCard.m
//  Air2
//

#import "A2QuickActionCard.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2QuickActionCard ()
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *label;
@end

@implementation A2QuickActionCard

- (instancetype)initWithTitle:(NSString *)title symbolName:(NSString *)symbolName {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _title = [title copy];
    _symbolName = [symbolName copy];
    [self setupContent];
    return self;
}

- (void)setupContent {
    self.cornerRadius = A2RadiusL;
    self.tappable = YES;
    self.contentInsets = UIEdgeInsetsMake(A2SpaceM, A2SpaceS, A2SpaceM, A2SpaceS);

    __weak typeof(self) weakSelf = self;
    self.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self.onSelect) self.onSelect();
    };

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightMedium];

    _iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:_symbolName withConfiguration:cfg]];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;

    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.text = _title;
    _label.font = [A2Typography caption];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.adjustsFontSizeToFitWidth = YES;
    _label.minimumScaleFactor = 0.8;

    [self.contentView addSubview:_iconView];
    [self.contentView addSubview:_label];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:A2SpaceS],
        [_iconView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:24],
        [_iconView.heightAnchor constraintEqualToConstant:24],

        [_label.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:A2SpaceS],
        [_label.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_label.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_label.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-A2SpaceS],
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

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    _label.text = title;
}

- (void)setSymbolName:(NSString *)symbolName {
    _symbolName = [symbolName copy];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightMedium];
    _iconView.image = [UIImage systemImageNamed:symbolName withConfiguration:cfg];
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    _iconView.tintColor = A2ThemeManager.shared.scheme.primary;
    _label.textColor = [UIColor colorWithWhite:1.0 alpha:0.86];
}

@end
