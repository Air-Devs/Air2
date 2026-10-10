//
//  A2ResourceCard.m
//  Air2
//

#import "A2ResourceCard.h"
#import "A2ResourceBadge.h"
#import "A2ContentSource.h"
#import "A2GlassCard.h"
#import "A2RemoteImageView.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

/// 图标尺寸 —— ZL2 用 72dp
static const CGFloat kIconSize = 72;

@interface A2ResourceCard ()
@property (nonatomic, strong) A2GlassCard *card;
@property (nonatomic, strong) A2RemoteImageView *iconView;

// 标题行
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *authorDivider;
@property (nonatomic, strong) UILabel *authorLabel;
@property (nonatomic, strong) A2PlatformBadge *platformBadge;

// 描述 + 下载量
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UIImageView *downloadIcon;
@property (nonatomic, strong) UILabel *downloadLabel;

// 底部标签行
@property (nonatomic, strong) UILabel *loaderLabel;
@property (nonatomic, strong) A2ClassBadge *classBadge;
@property (nonatomic, strong) A2InstalledBadge *installedBadge;
@property (nonatomic, strong) A2FavoriteButton *favoriteButton;

@property (nonatomic, strong) A2ContentItem *item;
@property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
@property (nonatomic, strong) UIImpactFeedbackGenerator *impact;
@end

@implementation A2ResourceCard

#pragma mark - 初始化

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self setup];
    return self;
}

- (void)setup {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _impact = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

    _card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    // ZL2 用 shapes.large；我们的 A2RadiusL = 16，接近
    _card.cornerRadius = A2RadiusL;
    _card.elevation = A2CardElevationLow;
    // ZL2 的卡片内边距是 8dp，比其他组件小 —— 因为图标已经占了很多空间
    _card.contentInsets = UIEdgeInsetsMake(A2SpaceS, A2SpaceS, A2SpaceS, A2SpaceS);
    [self addSubview:_card];

    [self buildIcon];
    [self buildTitleRow];
    [self buildSummaryRow];
    [self buildTagRow];
    [self setupConstraints];

    _tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    [self addGestureRecognizer:_tapGesture];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 构建子视图

- (void)buildIcon {
    _iconView = [[A2RemoteImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.cornerRadius = A2RadiusS;   // ZL2 用 10dp
    _iconView.contentMode = UIViewContentModeScaleAspectFill;
    _iconView.clipsToBounds = YES;
    [_card.contentView addSubview:_iconView];
}

- (void)buildTitleRow {
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _titleLabel.numberOfLines = 1;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                 forAxis:UILayoutConstraintAxisHorizontal];

    // ZL2 在标题与作者之间放了竖直分隔线
    _authorDivider = [[UIView alloc] initWithFrame:CGRectZero];
    _authorDivider.translatesAutoresizingMaskIntoConstraints = NO;

    _authorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _authorLabel.font = [A2Typography caption];
    _authorLabel.numberOfLines = 1;
    _authorLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_authorLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                  forAxis:UILayoutConstraintAxisHorizontal];

    _platformBadge = [[A2PlatformBadge alloc] initWithPlatform:A2ContentPlatformModrinth];
    [_platformBadge setContentHuggingPriority:UILayoutPriorityRequired
                                      forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[_titleLabel, _authorDivider, _authorLabel, _platformBadge]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = A2SpaceS;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.tag = 201;
    [_card.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_authorDivider.widthAnchor constraintEqualToConstant:1],
        [_authorDivider.heightAnchor constraintEqualToConstant:12],
    ]];
}

- (void)buildSummaryRow {
    _summaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _summaryLabel.font = [A2Typography subtitleCard];
    _summaryLabel.numberOfLines = 2;   // ZL2 最多 2 行
    _summaryLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_summaryLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                   forAxis:UILayoutConstraintAxisHorizontal];

    // 下载量：图标 + 数字
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightMedium];
    _downloadIcon = [[UIImageView alloc] initWithImage:
                     [UIImage systemImageNamed:@"arrow.down.circle" withConfiguration:cfg]];
    _downloadIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _downloadIcon.contentMode = UIViewContentModeScaleAspectFit;
    [_downloadIcon setContentHuggingPriority:UILayoutPriorityRequired
                                     forAxis:UILayoutConstraintAxisHorizontal];

    _downloadLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _downloadLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _downloadLabel.numberOfLines = 1;
    [_downloadLabel setContentHuggingPriority:UILayoutPriorityRequired
                                      forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *downloadStack = [[UIStackView alloc] initWithArrangedSubviews:
                                  @[_downloadIcon, _downloadLabel]];
    downloadStack.axis = UILayoutConstraintAxisHorizontal;
    downloadStack.spacing = 3;
    downloadStack.alignment = UIStackViewAlignmentCenter;
    [downloadStack setContentHuggingPriority:UILayoutPriorityRequired
                                     forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:
                        @[_summaryLabel, downloadStack]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = A2SpaceS;
    row.alignment = UIStackViewAlignmentTop;
    row.tag = 202;
    [_card.contentView addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [_downloadIcon.widthAnchor constraintEqualToConstant:13],
        [_downloadIcon.heightAnchor constraintEqualToConstant:13],
    ]];
}

- (void)buildTagRow {
    // 加载器标签（Fabric/Forge…）—— ZL2 单独列出，不混在分类里
    _loaderLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _loaderLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    _loaderLabel.numberOfLines = 1;
    [_loaderLabel setContentHuggingPriority:UILayoutPriorityRequired
                                    forAxis:UILayoutConstraintAxisHorizontal];

    _classBadge = [[A2ClassBadge alloc] initWithContentClass:A2ContentClassMod];
    _installedBadge = [[A2InstalledBadge alloc] initWithFrame:CGRectZero];
    _installedBadge.installed = NO;

    _favoriteButton = [[A2FavoriteButton alloc] initWithFrame:CGRectZero];
    __weak typeof(self) weakSelf = self;
    _favoriteButton.onToggle = ^(BOOL fav) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self.onFavoriteToggle) self.onFavoriteToggle(fav);
    };

    UIStackView *spacer = [[UIStackView alloc] initWithFrame:CGRectZero];
    [spacer setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:
                        @[_loaderLabel, _classBadge, spacer, _installedBadge, _favoriteButton]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = A2SpaceS;
    row.alignment = UIStackViewAlignmentCenter;
    row.tag = 203;
    [_card.contentView addSubview:row];
}

- (void)setupConstraints {
    UIView *titleRow = [_card.contentView viewWithTag:201];
    UIView *summaryRow = [_card.contentView viewWithTag:202];
    UIView *tagRow = [_card.contentView viewWithTag:203];

    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        // 图标：72pt，垂直居中，圆角由组件内部处理
        [_iconView.leadingAnchor constraintEqualToAnchor:_card.contentView.leadingAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_card.contentView.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:kIconSize],
        [_iconView.heightAnchor constraintEqualToConstant:kIconSize],
        // 卡片最小高度由图标撑开
        [_card.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:kIconSize],

        // 标题行
        [titleRow.topAnchor constraintEqualToAnchor:_card.contentView.topAnchor constant:2],
        [titleRow.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor
                                               constant:A2SpaceM],
        [titleRow.trailingAnchor constraintEqualToAnchor:_card.contentView.trailingAnchor],

        // 描述行
        [summaryRow.topAnchor constraintEqualToAnchor:titleRow.bottomAnchor constant:4],
        [summaryRow.leadingAnchor constraintEqualToAnchor:titleRow.leadingAnchor],
        [summaryRow.trailingAnchor constraintEqualToAnchor:titleRow.trailingAnchor],

        // 标签行
        [tagRow.topAnchor constraintEqualToAnchor:summaryRow.bottomAnchor constant:4],
        [tagRow.leadingAnchor constraintEqualToAnchor:titleRow.leadingAnchor],
        [tagRow.trailingAnchor constraintEqualToAnchor:titleRow.trailingAnchor],
        [tagRow.bottomAnchor constraintLessThanOrEqualToAnchor:_card.contentView.bottomAnchor
                                                      constant:-2],
    ]];
}

#pragma mark - 配置

- (void)configureWithItem:(A2ContentItem *)item {
    _item = item;

    _titleLabel.text = item.title.length ? item.title : item.projectID;
    // ZL2 的格式是 "by xxx"
    _authorLabel.text = item.author.length ? [@"by " stringByAppendingString:item.author] : @"";
    _authorDivider.hidden = (item.author.length == 0);

    _summaryLabel.text = item.summary.length ? item.summary : @"暂无简介";

    _downloadLabel.text = [A2ResourceCard formatCount:item.downloadCount];

    // 加载器：从分类里挑出加载器名（Fabric/Forge/NeoForge/Quilt）
    _loaderLabel.text = [A2ResourceCard loaderTextFromCategories:item.categories];
    _loaderLabel.hidden = (_loaderLabel.text.length == 0);

    _platformBadge.platform = item.platform;

    // 作者禁止分发时，界面要有明确提示
    if (!item.downloadable) {
        _summaryLabel.text = @"该作者禁止第三方分发，请前往官网下载";
    }

    // 图标：复用前先取消上一次请求，避免回调落到新内容上
    [_iconView cancelLoading];
    [_iconView setImageURL:item.iconURL placeholder:nil];

    [self applyTheme];
}

/// 从分类数组里挑出加载器名
+ (NSString *)loaderTextFromCategories:(NSArray<NSString *> *)categories {
    NSArray<NSString *> *known = @[@"fabric", @"forge", @"neoforge", @"quilt",
                                   @"liteloader", @"rift", @"optifine"];
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSString *c in categories) {
        NSString *lower = c.lowercaseString;
        for (NSString *k in known) {
            if ([lower isEqualToString:k]) {
                [found addObject:[k capitalizedString]];
                break;
            }
        }
    }
    return [found componentsJoinedByString:@" · "];
}

/// 下载量易读格式：1.2M / 345K / 123
+ (NSString *)formatCount:(long long)count {
    if (count >= 1000000) return [NSString stringWithFormat:@"%.1fM", count / 1000000.0];
    if (count >= 1000)    return [NSString stringWithFormat:@"%.1fK", count / 1000.0];
    return [NSString stringWithFormat:@"%lld", count];
}

#pragma mark - 属性

- (void)setInstalled:(BOOL)installed {
    _installed = installed;
    _installedBadge.installed = installed;
}

- (void)setFavorite:(BOOL)favorite {
    _favorite = favorite;
    _favoriteButton.favorite = favorite;
}

#pragma mark - 交互

- (void)handleTap {
    [_impact impactOccurred];
    if (self.onTap) self.onTap();
}

#pragma mark - 入场动画

/// 卡片从 0.95 缩放展开 —— ZL2 的 ResultProjectLayout 就是这么做的。
/// 逐张延迟入场，形成"列表流动进来"的观感。
- (void)playEntranceAnimationWithDelay:(NSTimeInterval)delay {
    self.alpha = 0;
    self.transform = CGAffineTransformMakeScale(0.95, 0.95);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationCard);
        [a addAnimations:^{
            self.alpha = 1;
            self.transform = CGAffineTransformIdentity;
        }];
        [a startAnimation];
    });
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    _titleLabel.textColor = t.cOnSurface;
    _authorLabel.textColor = [t.cOnSurfaceVariant colorWithAlphaComponent:0.85];
    _authorDivider.backgroundColor = [t.cOnSurface colorWithAlphaComponent:0.25];
    _summaryLabel.textColor = t.cOnSurfaceVariant;
    _downloadLabel.textColor = [t.cOnSurfaceVariant colorWithAlphaComponent:0.8];
    _downloadIcon.tintColor = [t.cOnSurfaceVariant colorWithAlphaComponent:0.8];
    _loaderLabel.textColor = t.cPrimary;
}

@end
