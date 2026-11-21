//
//  A2VersionTabBar.m
//  Air2
//

#import "A2VersionTabBar.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

@interface A2VersionTabBar ()
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) NSMutableArray<UIButton *> *buttons;
@end

@implementation A2VersionTabBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [self build];
    [self applyTheme];
    return self;
}

- (void)build {
    _buttons = [NSMutableArray array];

    // 图标 + 文字（对照 ZL2 的 CategoryItem：CategoryIcon + 文字）
    NSArray<NSArray *> *items = @[
        @[@"总览",   @"info.circle"],
        @[@"启动",   @"gear"],
        @[@"目录",   @"folder"],
        @[@"删除",   @"trash"],      // 危险操作单独一栏，与上面隔开
    ];

    _stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = A2SpaceXS;
    [self addSubview:_stack];

    for (NSUInteger i = 0; i < items.count; i++) {
        // 「删除」之前插一条分隔线（对照 ZL2 的 division 标记）
        if (i == items.count - 1) {
            UIView *sep = [[UIView alloc] initWithFrame:CGRectZero];
            sep.translatesAutoresizingMaskIntoConstraints = NO;
            [sep.heightAnchor constraintEqualToConstant:1].active = YES;
            sep.tag = 999;   // 主题里单独上色
            [_stack addArrangedSubview:sep];
        }

        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        b.tag = i;
        b.layer.cornerRadius = A2RadiusM;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);

        // 竖排：图标在上、文字在下（窄栏更好看）
        [b setTitle:items[i][0] forState:UIControlStateNormal];
        [b setImage:[UIImage systemImageNamed:items[i][1]] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        [b.heightAnchor constraintEqualToConstant:56].active = YES;

        // 图标与文字竖排需要自定义 configuration；这里先用系统默认
        // （iOS 15+ 可用 UIButtonConfiguration，但部署目标是 14.0）
        b.contentEdgeInsets = UIEdgeInsetsMake(6, 6, 6, 6);
        b.titleEdgeInsets = UIEdgeInsetsMake(0, -60, -26, 0);
        b.imageEdgeInsets = UIEdgeInsetsMake(-18, 0, 0, 0);

        [b addTarget:self action:@selector(tabTapped:)
    forControlEvents:UIControlEventTouchUpInside];
        [_stack addArrangedSubview:b];
        [_buttons addObject:b];
    }

    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor],
    ]];
}

- (void)tabTapped:(UIButton *)sender {
    self.selectedTab = (A2VersionTab)sender.tag;
    if (self.onTabChanged) self.onTabChanged(self.selectedTab);
}

- (void)setSelectedTab:(A2VersionTab)selectedTab {
    _selectedTab = selectedTab;
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    for (UIButton *b in self.buttons) {
        BOOL selected = ((A2VersionTab)b.tag == self.selectedTab);
        BOOL isDanger = ((A2VersionTab)b.tag == A2VersionTabDanger);

        b.backgroundColor = selected ? t.cSecondaryContainer : UIColor.clearColor;

        UIColor *color = selected ? t.cOnSecondaryContainer
                                  : (isDanger ? t.cError : t.cOnSurfaceVariant);
        [b setTitleColor:color forState:UIControlStateNormal];
        b.tintColor = color;
    }

    // 分隔线
    for (UIView *v in self.stack.arrangedSubviews) {
        if (v.tag == 999) v.backgroundColor = t.cOutlineVariant;
    }
}

@end
