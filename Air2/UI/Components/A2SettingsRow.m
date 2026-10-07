//
//  A2SettingsRow.m
//  Air2
//

#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2SettingsRow ()
@property (nonatomic, strong) UIView *iconBox;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UIImageView *chevron;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, strong) UIImageView *checkmark;
@property (nonatomic, strong) UIView *topSep;
@property (nonatomic, strong) UIView *bottomSep;
@property (nonatomic, strong) UIStackView *textStack;
@property (nonatomic, strong) UIStackView *trailingStack;
@end

@implementation A2SettingsRow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self setup];
    return self;
}

- (void)setup {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    // ---- 图标 ----
    _iconBox = [[UIView alloc] initWithFrame:CGRectZero];
    _iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBox.layer.cornerRadius = A2RadiusS;
    _iconBox.layer.cornerCurve = kCACornerCurveContinuous;
    _iconBox.hidden = YES;
    [self addSubview:_iconBox];

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconBox addSubview:_iconView];

    // ---- 文字 ----
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [A2Typography body];
    _titleLabel.numberOfLines = 1;

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.font = [A2Typography caption];
    _subtitleLabel.numberOfLines = 2;
    _subtitleLabel.hidden = YES;

    _textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subtitleLabel]];
    _textStack.translatesAutoresizingMaskIntoConstraints = NO;
    _textStack.axis = UILayoutConstraintAxisVertical;
    _textStack.spacing = 2;
    _textStack.alignment = UIStackViewAlignmentLeading;
    [self addSubview:_textStack];

    // ---- 右侧 ----
    _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _valueLabel.font = [A2Typography subtitleCard];
    _valueLabel.textAlignment = NSTextAlignmentRight;
    _valueLabel.hidden = YES;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
    _chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:cfg]];
    _chevron.translatesAutoresizingMaskIntoConstraints = NO;
    _chevron.hidden = YES;

    _toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    _toggle.translatesAutoresizingMaskIntoConstraints = NO;
    _toggle.hidden = YES;
    [_toggle addTarget:self action:@selector(toggleChanged) forControlEvents:UIControlEventValueChanged];

    _checkmark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
    _checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    _checkmark.hidden = YES;

    _trailingStack = [[UIStackView alloc] initWithArrangedSubviews:@[_valueLabel, _checkmark, _chevron, _toggle]];
    _trailingStack.translatesAutoresizingMaskIntoConstraints = NO;
    _trailingStack.axis = UILayoutConstraintAxisHorizontal;
    _trailingStack.spacing = A2SpaceS;
    _trailingStack.alignment = UIStackViewAlignmentCenter;
    [self addSubview:_trailingStack];

    // ---- 分隔线 ----
    _topSep = [self makeSeparator];
    _bottomSep = [self makeSeparator];
    _topSep.hidden = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:A2MinTouchTarget],

        [_iconBox.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceL],
        [_iconBox.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconBox.widthAnchor constraintEqualToConstant:28],
        [_iconBox.heightAnchor constraintEqualToConstant:28],

        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBox.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBox.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:16],
        [_iconView.heightAnchor constraintEqualToConstant:16],

        [_textStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceL],
        [_textStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_textStack.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor constant:A2SpaceM],

        [_trailingStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceL],
        [_trailingStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_trailingStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:_textStack.trailingAnchor constant:A2SpaceM],

        [_topSep.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_topSep.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceL],
        [_topSep.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_topSep.heightAnchor constraintEqualToConstant:0.5],

        [_bottomSep.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_bottomSep.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceL],
        [_bottomSep.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_bottomSep.heightAnchor constraintEqualToConstant:0.5],
    ]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    [self addGestureRecognizer:tap];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UIView *)makeSeparator {
    UIView *v = [[UIView alloc] initWithFrame:CGRectZero];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:v];
    return v;
}

#pragma mark - 属性

- (void)setSymbolName:(NSString *)symbolName {
    _symbolName = [symbolName copy];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    _iconView.image = [UIImage systemImageNamed:symbolName withConfiguration:cfg];
    _iconBox.hidden = (symbolName.length == 0);
    [self updateTextLeading];
    [self applyTheme];
}

- (void)setSymbolColor:(UIColor *)symbolColor {
    _symbolColor = symbolColor;
    [self applyTheme];
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

- (void)setValueText:(NSString *)valueText {
    _valueText = [valueText copy];
    _valueLabel.text = valueText;
    _valueLabel.hidden = (valueText.length == 0);
}

- (void)setAccessory:(A2SettingsRowAccessory)accessory {
    _accessory = accessory;
    _chevron.hidden = (accessory != A2SettingsRowAccessoryDisclosure);
    _toggle.hidden = (accessory != A2SettingsRowAccessorySwitch);
    _checkmark.hidden = (accessory != A2SettingsRowAccessoryCheckmark);
}

- (void)setCustomAccessoryView:(UIView *)customAccessoryView {
    if (_customAccessoryView) {
        [_trailingStack removeArrangedSubview:_customAccessoryView];
        [_customAccessoryView removeFromSuperview];
    }
    _customAccessoryView = customAccessoryView;
    if (customAccessoryView) {
        [_trailingStack addArrangedSubview:customAccessoryView];
        self.accessory = A2SettingsRowAccessoryCustom;
    }
}

- (void)setOn:(BOOL)on {
    _on = on;
    [_toggle setOn:on animated:YES];
}

- (void)setDestructive:(BOOL)destructive {
    _destructive = destructive;
    [self applyTheme];
}

- (void)setShowsTopSeparator:(BOOL)showsTopSeparator {
    _showsTopSeparator = showsTopSeparator;
    _topSep.hidden = !showsTopSeparator;
}

- (void)setShowsBottomSeparator:(BOOL)showsBottomSeparator {
    _showsBottomSeparator = showsBottomSeparator;
    _bottomSep.hidden = !showsBottomSeparator;
}

/// 有图标时文字后移，没图标时文字顶到左边
- (void)updateTextLeading {
    for (NSLayoutConstraint *c in self.constraints) {
        if (c.firstItem == _textStack && c.firstAttribute == NSLayoutAttributeLeading) {
            c.constant = _iconBox.hidden ? A2SpaceL : (A2SpaceL + 28 + A2SpaceM);
            break;
        }
    }
    for (NSLayoutConstraint *c in self.constraints) {
        if (c.firstItem == _topSep && c.firstAttribute == NSLayoutAttributeLeading) {
            c.constant = _iconBox.hidden ? A2SpaceL : (A2SpaceL + 28 + A2SpaceM);
        }
        if (c.firstItem == _bottomSep && c.firstAttribute == NSLayoutAttributeLeading) {
            c.constant = _iconBox.hidden ? A2SpaceL : (A2SpaceL + 28 + A2SpaceM);
        }
    }
}

#pragma mark - 交互

- (void)toggleChanged {
    _on = _toggle.isOn;
    if (self.onToggle) self.onToggle(_on);
}

- (void)handleTap {
    if (_accessory == A2SettingsRowAccessorySwitch) {
        // 点整行也能切开关
        [_toggle setOn:!_toggle.isOn animated:YES];
        [self toggleChanged];
        return;
    }
    if (self.onTap) self.onTap();
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_accessory == A2SettingsRowAccessorySwitch || !self.onTap) {
        [super touchesBegan:touches withEvent:event];
        return;
    }
    [UIView animateWithDuration:A2AnimDurationFast animations:^{
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    }];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [UIView animateWithDuration:A2AnimDurationFast animations:^{
        self.backgroundColor = UIColor.clearColor;
    }];
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.backgroundColor = UIColor.clearColor;
    [super touchesCancelled:touches withEvent:event];
}

#pragma mark - 主题

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ThemeManager *tm = A2ThemeManager.shared;
    A2ColorScheme *t = tm.scheme;

    _iconBox.backgroundColor = self.symbolColor ?: [t.primary colorWithAlphaComponent:0.9];
    _iconView.tintColor = UIColor.whiteColor;
    _titleLabel.textColor = self.isDestructive ? t.error : UIColor.whiteColor;
    _subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    _valueLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    _chevron.tintColor = [UIColor colorWithWhite:1.0 alpha:0.34];
    _checkmark.tintColor = t.primary;
    _toggle.onTintColor = t.primary;

    UIColor *sep = [UIColor colorWithWhite:1.0 alpha:0.09];
    _topSep.backgroundColor = sep;
    _bottomSep.backgroundColor = sep;
}

@end
