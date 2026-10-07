//
//  A2SettingsSection.m
//  Air2
//

#import "A2SettingsSection.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2SettingsSection ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *footerLabel;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) NSMutableArray<A2SettingsRow *> *mutableRows;
@end

@implementation A2SettingsSection

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _sectionTitle = [title copy];
    _mutableRows = [NSMutableArray array];
    [self setup];
    return self;
}

- (void)setup {
    self.cornerRadius = A2RadiusL;
    self.contentInsets = UIEdgeInsetsZero;

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _titleLabel.text = _sectionTitle;
    _titleLabel.hidden = (_sectionTitle.length == 0);

    _stack = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 0;

    _footerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _footerLabel.font = [A2Typography caption];
    _footerLabel.numberOfLines = 0;
    _footerLabel.hidden = YES;

    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_stack];

    UIStackView *outer = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, container, _footerLabel]];
    outer.translatesAutoresizingMaskIntoConstraints = NO;
    outer.axis = UILayoutConstraintAxisVertical;
    outer.spacing = A2SpaceS;
    [outer setCustomSpacing:A2SpaceXS afterView:_titleLabel];
    [outer setCustomSpacing:A2SpaceXS afterView:container];

    [self.contentView addSubview:outer];

    [NSLayoutConstraint activateConstraints:@[
        [outer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:A2SpaceM],
        [outer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-A2SpaceM],
        [outer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [outer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],

        [_stack.topAnchor constraintEqualToAnchor:container.topAnchor],
        [_stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [_stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
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

- (NSArray<A2SettingsRow *> *)rows {
    return [_mutableRows copy];
}

- (void)setSectionTitle:(NSString *)sectionTitle {
    _sectionTitle = [sectionTitle copy];
    _titleLabel.text = sectionTitle;
    _titleLabel.hidden = (sectionTitle.length == 0);
}

- (void)setFooterText:(NSString *)footerText {
    _footerText = [footerText copy];
    _footerLabel.text = footerText;
    _footerLabel.hidden = (footerText.length == 0);
}

- (void)addRow:(A2SettingsRow *)row {
    // 前一行不该有底部分隔线（由新行用顶部分隔线代替）
    A2SettingsRow *previous = _mutableRows.lastObject;
    if (previous) {
        previous.showsBottomSeparator = NO;
        row.showsTopSeparator = NO;   // 用上一行的底部分隔线即可
    }

    [_mutableRows addObject:row];
    [_stack addArrangedSubview:row];

    [row.leadingAnchor constraintEqualToAnchor:_stack.leadingAnchor].active = YES;
    [row.trailingAnchor constraintEqualToAnchor:_stack.trailingAnchor].active = YES;
}

- (void)addCustomView:(UIView *)view {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [_stack addArrangedSubview:view];
    [view.leadingAnchor constraintEqualToAnchor:_stack.leadingAnchor].active = YES;
    [view.trailingAnchor constraintEqualToAnchor:_stack.trailingAnchor].active = YES;
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _titleLabel.textColor = t.onSurfaceVariant;
    _footerLabel.textColor = [t.onSurfaceVariant colorWithAlphaComponent:0.75];
}

@end
