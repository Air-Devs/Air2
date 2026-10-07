//
//  A2CategoryNavView.m
//  Air2
//

#import "A2CategoryNavView.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

#pragma mark - 分类定义

@implementation A2NavCategory
+ (instancetype)title:(NSString *)t symbol:(NSString *)s {
    return [self title:t symbol:s division:NO];
}
+ (instancetype)title:(NSString *)t symbol:(NSString *)s division:(BOOL)division {
    A2NavCategory *c = [A2NavCategory new];
    c.title = t;
    c.symbol = s;
    c.divisionBefore = division;
    return c;
}
@end

#pragma mark - 导航项按钮

@interface A2NavItemButton : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, assign, getter=isSelected) BOOL selected;
- (instancetype)initWithCategory:(A2NavCategory *)category;
- (void)applyTheme;
@end

@implementation A2NavItemButton

- (instancetype)initWithCategory:(A2NavCategory *)category {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = A2RadiusM;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightMedium];
    _iconView = [[UIImageView alloc] initWithImage:
                 [UIImage systemImageNamed:category.symbol withConfiguration:cfg]];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;

    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.text = category.title;
    _label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.numberOfLines = 2;
    _label.adjustsFontSizeToFitWidth = YES;
    _label.minimumScaleFactor = 0.75;

    [self addSubview:_iconView];
    [self addSubview:_label];

    [NSLayoutConstraint activateConstraints:@[
        // 图标在上：距顶 8，尺寸 24
        [_iconView.topAnchor constraintEqualToAnchor:self.topAnchor constant:A2SpaceS],
        [_iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:24],
        [_iconView.heightAnchor constraintEqualToConstant:24],

        // 文字在下：距图标 4，距底 8
        [_label.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:A2SpaceXS],
        [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
        [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-2],
        [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-A2SpaceS],
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

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    if (self.isSelected) {
        self.backgroundColor = t.cSecondaryContainer;
        _iconView.tintColor = t.cOnSecondaryContainer;
        _label.textColor = t.cOnSecondaryContainer;
    } else {
        self.backgroundColor = UIColor.clearColor;
        _iconView.tintColor = t.cOnSurfaceVariant;
        _label.textColor = t.cOnSurfaceVariant;
    }
}

@end

#pragma mark - 导航容器

@interface A2CategoryNavView ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) NSArray<A2NavCategory *> *categories;
@property (nonatomic, strong) NSMutableArray<A2NavItemButton *> *buttons;
@property (nonatomic, strong) NSMutableArray<UIView *> *dividers;
@property (nonatomic, assign) NSInteger selectedIndex;
@end

@implementation A2CategoryNavView

- (instancetype)initWithCategories:(NSArray<A2NavCategory *> *)categories {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _categories = categories;
    _buttons = [NSMutableArray array];
    _dividers = [NSMutableArray array];
    _navWidth = 88;
    _selectedIndex = -1;
    [self setup];
    return self;
}

- (void)setup {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.showsVerticalScrollIndicator = NO;
    [self addSubview:_scroll];

    _stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = A2SpaceS;
    [_scroll addSubview:_stack];

    [NSLayoutConstraint activateConstraints:@[
        [self.widthAnchor constraintEqualToConstant:_navWidth],

        [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [_stack.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:A2SpaceM],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:-A2SpaceM],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor],
        [_stack.widthAnchor constraintEqualToAnchor:_scroll.widthAnchor],
    ]];

    for (NSUInteger i = 0; i < _categories.count; i++) {
        A2NavCategory *cat = _categories[i];

        // 分组分隔线：40% 宽、上下各 12
        if (cat.divisionBefore) {
            UIView *wrapper = [[UIView alloc] initWithFrame:CGRectZero];
            wrapper.translatesAutoresizingMaskIntoConstraints = NO;

            UIView *line = [[UIView alloc] initWithFrame:CGRectZero];
            line.translatesAutoresizingMaskIntoConstraints = NO;
            [wrapper addSubview:line];

            [NSLayoutConstraint activateConstraints:@[
                [wrapper.heightAnchor constraintEqualToConstant:25],   // 12 + 1 + 12
                [line.centerYAnchor constraintEqualToAnchor:wrapper.centerYAnchor],
                [line.centerXAnchor constraintEqualToAnchor:wrapper.centerXAnchor],
                [line.widthAnchor constraintEqualToAnchor:wrapper.widthAnchor multiplier:0.4],
                [line.heightAnchor constraintEqualToConstant:1],
            ]];
            [_dividers addObject:line];
            [_stack addArrangedSubview:wrapper];
        }

        A2NavItemButton *btn = [[A2NavItemButton alloc] initWithCategory:cat];
        btn.tag = i;
        [btn addTarget:self action:@selector(itemTapped:) forControlEvents:UIControlEventTouchUpInside];
        [NSLayoutConstraint activateConstraints:@[
            [btn.heightAnchor constraintGreaterThanOrEqualToConstant:62],
        ]];
        [_buttons addObject:btn];
        [_stack addArrangedSubview:btn];
    }

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setNavWidth:(CGFloat)navWidth {
    _navWidth = navWidth;
    for (NSLayoutConstraint *c in self.constraints) {
        if (c.firstAttribute == NSLayoutAttributeWidth && c.firstItem == self) {
            c.constant = navWidth;
            break;
        }
    }
}

- (void)itemTapped:(A2NavItemButton *)sender {
    UISelectionFeedbackGenerator *fb = [UISelectionFeedbackGenerator new];
    [fb selectionChanged];
    [self selectIndex:sender.tag animated:YES];
}

- (void)selectIndex:(NSInteger)index animated:(BOOL)animated {
    if (index < 0 || index >= (NSInteger)_buttons.count) return;
    if (_selectedIndex == index) return;
    _selectedIndex = index;

    for (A2NavItemButton *b in _buttons) {
        b.selected = (b.tag == index);
    }

    // 选中项做一次轻微回弹
    if (animated) {
        A2NavItemButton *btn = _buttons[index];
        UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationFast);
        [a addAnimations:^{ btn.transform = CGAffineTransformMakeScale(1.06, 1.06); }];
        [a addCompletion:^(UIViewAnimatingPosition pos) {
            UIViewPropertyAnimator *b = A2SpringAnimator(A2AnimDurationFast);
            [b addAnimations:^{ btn.transform = CGAffineTransformIdentity; }];
            [b startAnimation];
        }];
        [a startAnimation];
    }

    if (self.onSelect) self.onSelect(index);
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    for (UIView *line in _dividers) {
        line.backgroundColor = [t.cOnSurface colorWithAlphaComponent:0.25];
    }
}

@end
