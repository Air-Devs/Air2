//
//  A2CardTitleBar.m
//  Air2
//

#import "A2CardTitleBar.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2CardTitleBar ()
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIStackView *textStack;
@end

@implementation A2CardTitleBar

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _title = [title copy];
    [self commonInit];
    return self;
}

- (void)commonInit {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.clipsToBounds = YES;

    _fillView = [[UIView alloc] initWithFrame:CGRectZero];
    _fillView.translatesAutoresizingMaskIntoConstraints = NO;
    _fillView.userInteractionEnabled = NO;
    [self addSubview:_fillView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = _title;
    _titleLabel.font = [A2Typography titleCard];
    _titleLabel.numberOfLines = 1;

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.font = [A2Typography subtitleCard];
    _subtitleLabel.numberOfLines = 1;
    _subtitleLabel.hidden = YES;

    _textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subtitleLabel]];
    _textStack.translatesAutoresizingMaskIntoConstraints = NO;
    _textStack.axis = UILayoutConstraintAxisVertical;
    _textStack.spacing = 2;
    _textStack.alignment = UIStackViewAlignmentLeading;
    [self addSubview:_textStack];

    [NSLayoutConstraint activateConstraints:@[
        [_fillView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_fillView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_fillView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_fillView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [self.heightAnchor constraintGreaterThanOrEqualToConstant:A2CardTitleHeight],

        [_textStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceL],
        [_textStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
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
    _titleLabel.text = title;
}

- (void)setSubtitle:(NSString *)subtitle {
    _subtitle = [subtitle copy];
    _subtitleLabel.text = subtitle;
    _subtitleLabel.hidden = (subtitle.length == 0);
}

- (void)setAccessoryButton:(UIButton *)accessoryButton {
    if (_accessoryButton) {
        [_accessoryButton removeFromSuperview];
        for (NSLayoutConstraint *c in self.constraints) {
            if (c.firstItem == _accessoryButton || c.secondItem == _accessoryButton) c.active = NO;
        }
    }
    _accessoryButton = accessoryButton;
    if (!accessoryButton) {
        // 让文字栈可以撑到右边
        [NSLayoutConstraint activateConstraints:@[
            [_textStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-A2SpaceL],
        ]];
        return;
    }

    accessoryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:accessoryButton];

    [NSLayoutConstraint activateConstraints:@[
        [accessoryButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceM],
        [accessoryButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [accessoryButton.widthAnchor constraintGreaterThanOrEqualToConstant:A2MinTouchTarget],
        [accessoryButton.heightAnchor constraintGreaterThanOrEqualToConstant:A2MinTouchTarget],
        [_textStack.trailingAnchor constraintLessThanOrEqualToAnchor:accessoryButton.leadingAnchor constant:-A2SpaceS],
    ]];
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ThemeManager *tm = A2ThemeManager.shared;
    A2ColorTheme *t = tm.currentTheme;

    // 半透明表面：比卡片本体稍亮一点，形成分层
    _fillView.backgroundColor = tm.isDark
        ? [UIColor colorWithWhite:1.0 alpha:0.06]
        : [[t.surfaceElevated colorWithAlphaComponent:1.0] colorWithAlphaComponent:0.55];

    _titleLabel.textColor = t.textPrimary;
    _subtitleLabel.textColor = t.textSecondary;
}

@end
