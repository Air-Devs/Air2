//
//  A2FilterPanel.m
//  Air2
//

#import "A2FilterPanel.h"
#import "A2GlassCard.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

@interface A2FilterPanel ()
@property (nonatomic, strong) A2GlassCard *card;
@property (nonatomic, strong) UIControl *header;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UIImageView *chevron;
@property (nonatomic, strong) UIView *bodyContainer;
@property (nonatomic, strong) UIStackView *contentStackInternal;
@property (nonatomic, strong) NSLayoutConstraint *bodyHeightConstraint;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, strong) UIImpactFeedbackGenerator *feedback;
@end

@implementation A2FilterPanel

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self setup];
    return self;
}

- (void)setup {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _expanded = NO;   // 默认收起，与 ZL2 一致
    _feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

    _card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _card.cornerRadius = A2RadiusXL;
    _card.elevation = A2CardElevationHigh;   // 筛选面板浮在列表上方
    // 内容自带内边距，卡片本身不留
    _card.contentInsets = UIEdgeInsetsZero;
    [self addSubview:_card];

    [self buildHeader];
    [self buildBody];

    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 标题栏

- (void)buildHeader {
    _header = [[UIControl alloc] initWithFrame:CGRectZero];
    _header.translatesAutoresizingMaskIntoConstraints = NO;
    [_header addTarget:self action:@selector(toggleExpanded) forControlEvents:UIControlEventTouchUpInside];

    _summaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _summaryLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _summaryLabel.text = @"筛选";
    _summaryLabel.numberOfLines = 1;
    _summaryLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    _chevron = [[UIImageView alloc] initWithImage:
                [UIImage systemImageNamed:@"chevron.down" withConfiguration:cfg]];
    _chevron.translatesAutoresizingMaskIntoConstraints = NO;
    _chevron.contentMode = UIViewContentModeScaleAspectFit;

    [_header addSubview:_summaryLabel];
    [_header addSubview:_chevron];
    [_card.contentView addSubview:_header];

    [NSLayoutConstraint activateConstraints:@[
        // 标题栏高 48 —— 与 ZL2 的筛选标题栏一致
        [_header.heightAnchor constraintEqualToConstant:48],
        [_header.topAnchor constraintEqualToAnchor:_card.contentView.topAnchor],
        [_header.leadingAnchor constraintEqualToAnchor:_card.contentView.leadingAnchor],
        [_header.trailingAnchor constraintEqualToAnchor:_card.contentView.trailingAnchor],

        [_summaryLabel.leadingAnchor constraintEqualToAnchor:_header.leadingAnchor
                                                    constant:A2SpaceXL],
        [_summaryLabel.centerYAnchor constraintEqualToAnchor:_header.centerYAnchor],
        [_summaryLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_chevron.leadingAnchor
                                                               constant:-A2SpaceS],

        [_chevron.trailingAnchor constraintEqualToAnchor:_header.trailingAnchor
                                                constant:-A2SpaceXL],
        [_chevron.centerYAnchor constraintEqualToAnchor:_header.centerYAnchor],
        [_chevron.widthAnchor constraintEqualToConstant:16],
        [_chevron.heightAnchor constraintEqualToConstant:16],
    ]];
}

#pragma mark - 内容区

- (void)buildBody {
    _bodyContainer = [[UIView alloc] initWithFrame:CGRectZero];
    _bodyContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _bodyContainer.clipsToBounds = YES;
    [_card.contentView addSubview:_bodyContainer];

    _contentStackInternal = [[UIStackView alloc] initWithFrame:CGRectZero];
    _contentStackInternal.translatesAutoresizingMaskIntoConstraints = NO;
    _contentStackInternal.axis = UILayoutConstraintAxisVertical;
    _contentStackInternal.spacing = A2SpaceM;
    [_bodyContainer addSubview:_contentStackInternal];

    // 默认收起：高度 0
    _bodyHeightConstraint = [_bodyContainer.heightAnchor constraintEqualToConstant:0];

    [NSLayoutConstraint activateConstraints:@[
        [_bodyContainer.topAnchor constraintEqualToAnchor:_header.bottomAnchor],
        [_bodyContainer.leadingAnchor constraintEqualToAnchor:_card.contentView.leadingAnchor],
        [_bodyContainer.trailingAnchor constraintEqualToAnchor:_card.contentView.trailingAnchor],
        [_bodyContainer.bottomAnchor constraintEqualToAnchor:_card.contentView.bottomAnchor],
        _bodyHeightConstraint,

        [_contentStackInternal.topAnchor constraintEqualToAnchor:_bodyContainer.topAnchor],
        [_contentStackInternal.leadingAnchor constraintEqualToAnchor:_bodyContainer.leadingAnchor
                                                            constant:A2SpaceXL],
        [_contentStackInternal.trailingAnchor constraintEqualToAnchor:_bodyContainer.trailingAnchor
                                                             constant:-A2SpaceXL],
        [_contentStackInternal.bottomAnchor constraintEqualToAnchor:_bodyContainer.bottomAnchor
                                                           constant:-A2SpaceXL],
    ]];
}

- (UIStackView *)contentStack {
    return _contentStackInternal;
}

#pragma mark - 展开 / 收起

- (void)setSummaryText:(NSString *)summaryText {
    _summaryText = [summaryText copy];
    _summaryLabel.text = summaryText.length ? summaryText : @"筛选";
}

- (void)toggleExpanded {
    [self setExpanded:!self.expanded animated:YES];
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (_expanded == expanded) return;
    _expanded = expanded;

    [_feedback impactOccurred];

    // 展开态：高度由内容自然撑开（用一个足够大的上限 + 自适应）
    // 收起态：高度 0
    if (expanded) {
        [_bodyHeightConstraint setActive:NO];
        _bodyHeightConstraint = nil;
    } else {
        _bodyHeightConstraint = [_bodyContainer.heightAnchor constraintEqualToConstant:0];
        _bodyHeightConstraint.active = YES;
    }

    // 箭头旋转
    CGFloat angle = expanded ? M_PI : 0;

    void (^animations)(void) = ^{
        self.chevron.transform = CGAffineTransformMakeRotation(angle);
        [self.superview layoutIfNeeded];
    };

    if (animated) {
        UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDuration);
        [a addAnimations:animations];
        [a startAnimation];
    } else {
        animations();
    }

    if (self.onExpansionChange) self.onExpansionChange(expanded);
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _summaryLabel.textColor = t.cOnSurface;
    _chevron.tintColor = t.cOnSurfaceVariant;
}

@end
