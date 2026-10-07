//
//  A2ThemePickerViewController.m
//  Air2
//

#import "A2ThemePickerViewController.h"
#import "A2GlassCard.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Toast.h"

@interface A2ThemePickerViewController ()
@property (nonatomic, strong) NSMutableArray<A2GlassCard *> *cards;
@end

@implementation A2ThemePickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"主题配色";
    _cards = [NSMutableArray array];

    // 动态取色排在最前
    [self addThemeCardForKind:A2ThemeKindDynamic];

    for (A2ColorTheme *theme in [A2ColorTheme allThemes]) {
        [self addThemeCardForKind:theme.kind];
    }

    [self refreshSelection];
}

- (void)addThemeCardForKind:(A2ThemeKind)kind {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    A2ColorTheme *theme = (kind == A2ThemeKindDynamic)
        ? nil
        : [A2ColorTheme themeForKind:kind];

    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusL;
    card.tappable = YES;
    card.contentInsets = UIEdgeInsetsMake(A2SpaceM, A2SpaceM, A2SpaceM, A2SpaceM);
    card.tag = kind;
    [_cards addObject:card];

    // ---- 渐变色带 ----
    UIView *band = [[UIView alloc] initWithFrame:CGRectZero];
    band.translatesAutoresizingMaskIntoConstraints = NO;
    band.layer.cornerRadius = A2RadiusS;
    band.layer.cornerCurve = kCACornerCurveContinuous;
    band.clipsToBounds = YES;

    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.startPoint = CGPointMake(0, 0.5);
    grad.endPoint = CGPointMake(1, 0.5);
    grad.frame = CGRectMake(0, 0, 64, 40);

    NSArray<UIColor *> *colors;
    NSString *name;
    NSString *desc;

    if (kind == A2ThemeKindDynamic) {
        colors = @[[UIColor colorWithWhite:0.35 alpha:1.0],
                   [UIColor colorWithWhite:0.62 alpha:1.0],
                   [UIColor colorWithWhite:0.85 alpha:1.0]];
        name = @"动态取色";
        desc = @"从壁纸提取主色，随壁纸变化";
    } else {
        colors = theme.backgroundGradient;
        name = theme.displayName;
        desc = [self descriptionForKind:kind];
        grad.colors = @[
            (__bridge id)colors[0].CGColor,
            (__bridge id)colors[1].CGColor,
            (__bridge id)colors[2].CGColor,
        ];
    }
    if (kind == A2ThemeKindDynamic) {
        grad.colors = @[
            (__bridge id)((UIColor *)colors[0]).CGColor,
            (__bridge id)((UIColor *)colors[1]).CGColor,
            (__bridge id)((UIColor *)colors[2]).CGColor,
        ];
    }
    grad.locations = @[@0.0, @0.5, @1.0];
    [band.layer addSublayer:grad];
    band.tag = 900;   // 标记以便 layoutSubviews 时同步渐变帧

    // ---- 文字 ----
    UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    nameLabel.font = [A2Typography titleCard];
    nameLabel.text = name;
    nameLabel.textColor = t.cOnSurface;

    UILabel *descLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    descLabel.font = [A2Typography caption];
    descLabel.text = desc;
    descLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.58];

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[nameLabel, descLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;

    // ---- 选中勾 ----
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold];
    UIImageView *check = [[UIImageView alloc] initWithImage:
                          [UIImage systemImageNamed:@"checkmark.circle.fill" withConfiguration:cfg]];
    check.translatesAutoresizingMaskIntoConstraints = NO;
    check.tag = 901;
    check.hidden = YES;

    [card.contentView addSubview:band];
    [card.contentView addSubview:textStack];
    [card.contentView addSubview:check];

    [NSLayoutConstraint activateConstraints:@[
        [band.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [band.centerYAnchor constraintEqualToAnchor:card.contentView.centerYAnchor],
        [band.widthAnchor constraintEqualToConstant:64],
        [band.heightAnchor constraintEqualToConstant:40],

        [textStack.leadingAnchor constraintEqualToAnchor:band.trailingAnchor constant:A2SpaceM],
        [textStack.centerYAnchor constraintEqualToAnchor:card.contentView.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:check.leadingAnchor constant:-A2SpaceS],

        [check.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [check.centerYAnchor constraintEqualToAnchor:card.contentView.centerYAnchor],
        [check.widthAnchor constraintEqualToConstant:24],
        [check.heightAnchor constraintEqualToConstant:24],
    ]];

    __weak typeof(self) weakSelf = self;
    A2ThemeKind capturedKind = kind;
    card.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self selectKind:capturedKind];
    };

    [self addSection:card];
}

- (NSString *)descriptionForKind:(A2ThemeKind)kind {
    switch (kind) {
        case A2ThemeKindEmbermire:   return @"暖调，视觉重心强";
        case A2ThemeKindGlacier:     return @"冷调，长时间使用更舒适";
        case A2ThemeKindVerdantDawn: return @"自然色，贴合主题";
        case A2ThemeKindVelvetRose:  return @"柔和，低对比";
        case A2ThemeKindUrbanAsh:    return @"中性无彩，专注场景";
        default:                     return @"";
    }
}

- (void)selectKind:(A2ThemeKind)kind {
    A2ThemeManager *tm = A2ThemeManager.shared;
    if (tm.selectedKind == kind) return;

    tm.selectedKind = kind;
    [self refreshSelection];

    UISelectionFeedbackGenerator *fb = [UISelectionFeedbackGenerator new];
    [fb selectionChanged];
}

- (void)refreshSelection {
    A2ThemeKind current = A2ThemeManager.shared.selectedKind;
    for (A2GlassCard *card in _cards) {
        UIView *check = [card.contentView viewWithTag:901];
        check.hidden = (card.tag != current);
        check.tintColor = A2ThemeManager.shared.scheme.cPrimary;

        // 选中项轻微强调
        card.layer.borderWidth = (card.tag == current) ? 1.5 : 0;
        card.layer.borderColor = A2ThemeManager.shared.scheme.cPrimary.CGColor;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // CAGradientLayer 不参与自动布局，手动同步
    for (A2GlassCard *card in _cards) {
        UIView *band = [card.contentView viewWithTag:900];
        for (CALayer *l in band.layer.sublayers) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            l.frame = band.bounds;
            [CATransaction commit];
        }
    }
}

@end
