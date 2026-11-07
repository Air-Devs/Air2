//
//  A2HomeCardView.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  主页单卡实现。见头文件顶部两条纪律（按档位换版式 / 编辑态隔离）。
//
//  ★M3 口径（docs/DECISIONS.md ADR-010 + air2-ui 规范）★：
//    · 卡片底板走 A2GlassCard 的 elevation 档（surfaceContainer 分层 + outlineVariant 描边
//      + 阴影 token），不自己写背景色 / 圆角 / 阴影数值；
//    · 按下 / 拖动用 M3 state layer（on-surface 12% 覆盖层），不是自创高亮色；
//    · 图标放在语义色圆角容器里，不裸放 SF Symbol；
//    · 字号一律取 A2Typography 阶梯（问候卡字号是用户档位，唯一例外）；
//    · 动效一律弹簧（A2SpringAnimator），不用 ease-in-out。
//
//  布局用 frame 而不是 Auto Layout：卡片可用高度由「行节距 × 跨行数」决定，
//  内容行数是运行时算的（最近游玩条数、存档条数都可变），逐行 setFrame 更好读。
//

#import "A2HomeCardView.h"

#import "A2ColorScheme.h"
#import "A2GlassCard.h"
#import "A2HomeLayout.h"
#import "A2HomeRuntime.h"
#import "A2Metrics.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2VersionIsolation.h"
#import "A2VersionManager.h"

static CGFloat const A2HomeCardInset = 16.0;         // = A2SpaceL（卡片内边距，M3 16dp）
static CGFloat const A2HomeCardHeaderHeight = 22.0;
static CGFloat const A2HomeCardListRowHeight = 42.0;  // 列表行高（与卡片行高 token 不同名）
static CGFloat const A2HomeCardIconBoxSize = 28.0;    // M3 图标容器（圆角 8）
/// M3 state layer：按下 12%、拖动浮起 16%。
static CGFloat const A2HomeStateLayerPressed = 0.12;
static CGFloat const A2HomeStateLayerDragged = 0.16;

@interface A2HomeCardView ()

@property (nonatomic, strong, readwrite) A2HomeCard *card;
@property (nonatomic, strong) A2GlassCard *background;
@property (nonatomic, strong) UIView *stateLayer;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *kindIconBox;
@property (nonatomic, strong) UIImageView *kindIconView;
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) UIImageView *handleView;
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) CAShapeLayer *editBorderLayer;
@property (nonatomic, assign, getter=isLifted) BOOL lifted;
@property (nonatomic, assign, getter=isPressed) BOOL pressed;
/// 与 contentContainer.subviews 一一对应的「期望行高」；0 表示吃掉剩余高度。
@property (nonatomic, strong) NSMutableArray<NSNumber *> *contentHeights;

- (void)rebuildContent;
- (UILabel *)addLabelWithText:(NSString *)text
                         font:(UIFont *)font
                        color:(UIColor *)color
                       height:(CGFloat)height;
- (void)addVersionRow:(A2Version *)version;
- (void)layoutVersionRow:(UIView *)row;
- (NSString *)metaTextForVersion:(A2Version *)version;
- (void)buildGreeting;
- (void)buildCalendar;
- (void)buildVersionList:(BOOL)pinned;
- (void)buildUnavailableKind;
- (void)buildShortcut;
- (void)buildCustomCard;
- (void)handleTap:(UITapGestureRecognizer *)recognizer;
- (void)handleMenuTap;
- (void)setPressed:(BOOL)pressed;
- (void)updateStateLayerAnimated:(BOOL)animated;

@end

@implementation A2HomeCardView

- (instancetype)initWithCard:(A2HomeCard *)card {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _card = card;
    _displayColumnSpan = A2HomeSpanForSize(card.size).columns;
    _contentHeights = [NSMutableArray array];
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;   // 阴影要画到卡片外面（M3 elevation）

    // 底板：M3 elevation 档决定 surfaceContainer 层级与阴影，不手写色值/阴影。
    _background = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _background.cornerRadius = A2RadiusM;          // M3 标准卡片 12
    _background.elevation = A2CardElevationLow;
    _background.contentInsets = UIEdgeInsetsZero;
    [self addSubview:_background];

    // M3 state layer：按下 / 拖动时的 on-surface 覆盖层。
    _stateLayer = [[UIView alloc] initWithFrame:CGRectZero];
    _stateLayer.layer.cornerRadius = A2RadiusM;
    _stateLayer.layer.cornerCurve = kCACornerCurveContinuous;
    _stateLayer.userInteractionEnabled = NO;
    _stateLayer.alpha = 0.0;
    [self addSubview:_stateLayer];

    _editBorderLayer = [CAShapeLayer layer];
    _editBorderLayer.fillColor = UIColor.clearColor.CGColor;
    _editBorderLayer.lineWidth = 1.5;
    _editBorderLayer.lineDashPattern = @[@6, @5];
    _editBorderLayer.hidden = YES;
    [self.layer addSublayer:_editBorderLayer];

    // 图标容器（M3：图标不裸放，装进语义色圆角容器）。
    _kindIconBox = [[UIView alloc] initWithFrame:CGRectZero];
    _kindIconBox.layer.cornerRadius = A2RadiusS;
    _kindIconBox.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_kindIconBox];

    _kindIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _kindIconView.contentMode = UIViewContentModeScaleAspectFit;
    [_kindIconBox addSubview:_kindIconView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [A2Typography titleCard];
    _titleLabel.numberOfLines = 1;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_titleLabel];

    _handleView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _handleView.contentMode = UIViewContentModeScaleAspectFit;
    _handleView.image = [UIImage systemImageNamed:@"line.3.horizontal"];
    _handleView.hidden = YES;
    [self addSubview:_handleView];

    _menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    [_menuButton setImage:[UIImage systemImageNamed:@"ellipsis" withConfiguration:cfg]
                 forState:UIControlStateNormal];
    _menuButton.hidden = YES;
    [_menuButton addTarget:self action:@selector(handleMenuTap) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_menuButton];

    _contentContainer = [[UIView alloc] initWithFrame:CGRectZero];
    _contentContainer.clipsToBounds = YES;
    [self addSubview:_contentContainer];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [self addGestureRecognizer:tap];

    [self rebuildContent];
    [self applyTheme];
    return self;
}

#pragma mark - 对外

- (void)updateCard:(A2HomeCard *)card {
    _card = card;
    self.displayColumnSpan = A2HomeSpanForSize(card.size).columns;
    [self rebuildContent];
    [self applyTheme];
    [self setNeedsLayout];
}

- (void)setEditing:(BOOL)editing {
    _editing = editing;
    _menuButton.hidden = !editing;
    _handleView.hidden = !editing;
    _editBorderLayer.hidden = !editing;
    // 编辑态内容不可交互 —— 这样「编辑时误点启动游戏」不可能发生。
    _contentContainer.userInteractionEnabled = !editing;
    [self setNeedsLayout];
}

- (void)setDisplayColumnSpan:(NSInteger)span {
    if (_displayColumnSpan == span) return;
    _displayColumnSpan = span;
    [self rebuildContent];
    [self setNeedsLayout];
}

/// 拖动浮起：只抬 elevation 档（阴影/表面层级由 token 决定），不自己编阴影数值。
- (void)setLifted:(BOOL)lifted {
    if (_lifted == lifted) return;
    _lifted = lifted;
    _background.elevation = lifted ? A2CardElevationHigh : A2CardElevationLow;
    [self updateStateLayerAnimated:YES];
}

- (void)applyTheme {
    A2ColorScheme *s = A2ThemeManager.shared.scheme;
    [_background applyTheme];
    _stateLayer.backgroundColor = s.cOnSurface;
    _editBorderLayer.strokeColor = s.cPrimary.CGColor;
    _titleLabel.textColor = s.cOnSurface;
    _kindIconBox.backgroundColor = s.cPrimaryContainer;
    _kindIconView.tintColor = s.cOnPrimaryContainer;
    _menuButton.tintColor = s.cOnSurfaceVariant;
    _handleView.tintColor = s.cOnSurfaceVariant;

    // 内容里的文字色在构建时取自当前主题；换主题时整体重建一次最省心
    // （卡片数量个位数，代价可忽略，且能保证配色一致）。
    [self rebuildContent];
    [self setNeedsLayout];
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = self.bounds;
    _background.frame = bounds;
    _stateLayer.frame = bounds;

    CGFloat headerY = A2SpaceM;
    CGFloat handleWidth = self.editing ? 18.0 : 0.0;
    CGFloat iconX = A2HomeCardInset + (self.editing ? handleWidth + A2SpaceS : 0.0);

    _handleView.frame = CGRectMake(A2HomeCardInset, headerY + 7, handleWidth, 14);
    _kindIconBox.frame = CGRectMake(iconX, headerY, A2HomeCardIconBoxSize, A2HomeCardIconBoxSize);
    CGFloat iconInset = (A2HomeCardIconBoxSize - 16) / 2;
    _kindIconView.frame = CGRectMake(iconInset, iconInset, 16, 16);

    CGFloat titleX = iconX + A2HomeCardIconBoxSize + A2SpaceS;
    CGFloat menuWidth = self.editing ? 28.0 : 0.0;
    CGFloat titleWidth = MAX(0.0, CGRectGetWidth(bounds) - titleX - A2HomeCardInset - menuWidth - A2SpaceS);
    CGFloat titleHeight = MAX(A2HomeCardHeaderHeight, A2HomeCardIconBoxSize);
    _titleLabel.frame = CGRectMake(titleX, headerY, titleWidth, titleHeight);
    if (self.editing) {
        _menuButton.frame = CGRectMake(CGRectGetWidth(bounds) - A2HomeCardInset - menuWidth,
                                       headerY - 4, menuWidth, 28);
    }

    _editBorderLayer.frame = bounds;
    _editBorderLayer.path = [UIBezierPath bezierPathWithRoundedRect:bounds
                                                     cornerRadius:A2RadiusM].CGPath;

    CGFloat contentTop = headerY + titleHeight + A2SpaceS;
    CGFloat contentBottom = CGRectGetHeight(bounds) - A2SpaceM;
    CGFloat available = MAX(0.0, contentBottom - contentTop);
    CGFloat contentWidth = MAX(0.0, CGRectGetWidth(bounds) - A2HomeCardInset * 2);

    // 先把固定行高加起来，剩下的给「0 高度」那一行（问候卡的大字行）。
    CGFloat fixedTotal = 0;
    for (NSNumber *h in self.contentHeights) {
        if (h.doubleValue > 0) fixedTotal += h.doubleValue;
    }
    NSInteger stretchCount = 0;
    for (NSNumber *h in self.contentHeights) {
        if (h.doubleValue <= 0) stretchCount++;
    }
    CGFloat stretchHeight = stretchCount > 0 ? MAX(0.0, available - fixedTotal) / stretchCount : 0.0;

    CGFloat y = contentTop;
    NSArray<UIView *> *subviews = self.contentContainer.subviews;
    for (NSUInteger i = 0; i < subviews.count && i < self.contentHeights.count; i++) {
        CGFloat h = self.contentHeights[i].doubleValue;
        if (h <= 0) h = stretchHeight;
        h = MIN(h, MAX(0.0, contentBottom - y));
        UIView *v = subviews[i];
        v.frame = CGRectMake(A2HomeCardInset, y, contentWidth, h);
        if (v.tag == 4100) [self layoutVersionRow:v];
        y += h;
    }
    _contentContainer.frame = CGRectMake(0, 0, CGRectGetWidth(bounds), CGRectGetHeight(bounds));
}

#pragma mark - 内容构建

- (void)rebuildContent {
    for (UIView *v in self.contentContainer.subviews) [v removeFromSuperview];
    [self.contentHeights removeAllObjects];

    _kindIconView.image = [UIImage systemImageNamed:A2HomeKindSymbolName(self.card.kind)];
    _titleLabel.text = A2HomeKindDisplayName(self.card.kind);

    // 自定义卡片：图标与标题是**用户数据**，优先于类型名（类型名只做兜底）。
    if (self.card.kind == A2HomeCardKindShortcutCustom) {
        A2HomeCardOptions *options = self.card.options;
        if (options.customSymbol.length) {
            _kindIconView.image = [UIImage systemImageNamed:options.customSymbol];
        }
        if (options.customTitle.length) _titleLabel.text = options.customTitle;
    }

    switch (self.card.kind) {
        case A2HomeCardKindGreeting:      [self buildGreeting]; break;
        case A2HomeCardKindRecent:        [self buildVersionList:NO]; break;
        case A2HomeCardKindCalendar:      [self buildCalendar]; break;
        case A2HomeCardKindPinnedVersions:[self buildVersionList:YES]; break;
        case A2HomeCardKindPinnedWorlds:
        case A2HomeCardKindPinnedServers:  [self buildUnavailableKind]; break;
        case A2HomeCardKindShortcutVersion:
        case A2HomeCardKindShortcutWorld:
        case A2HomeCardKindShortcutServer: [self buildShortcut]; break;
        case A2HomeCardKindShortcutCustom: [self buildCustomCard]; break;
    }
}

- (UILabel *)addLabelWithText:(NSString *)text font:(UIFont *)font color:(UIColor *)color height:(CGFloat)height {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = height > 0 ? 1 : 2;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentContainer addSubview:label];
    [self.contentHeights addObject:@(height)];
    return label;
}

/// 版本行：名字 + 副标题 + ▶。点行 = 启动这个版本（列表行必须带可点暗示）。
- (void)addVersionRow:(A2Version *)version {
    A2ColorScheme *s = A2ThemeManager.shared.scheme;

    UIControl *row = [[UIControl alloc] initWithFrame:CGRectZero];
    row.backgroundColor = s.cSurfaceContainerHigh;
    row.layer.cornerRadius = A2RadiusS;   // M3 L1 列表项（8）
    row.layer.cornerCurve = kCACornerCurveContinuous;
    row.tag = 4100;
    [self.contentContainer addSubview:row];
    [self.contentHeights addObject:@(A2HomeCardListRowHeight - 2)];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.text = version.name;
    name.font = [A2Typography body];
    name.textColor = s.cOnSurface;
    name.tag = 4101;
    [row addSubview:name];

    UILabel *meta = [[UILabel alloc] initWithFrame:CGRectZero];
    meta.text = [self metaTextForVersion:version];
    meta.font = [A2Typography caption];
    meta.textColor = s.cOnSurfaceVariant;
    meta.tag = 4102;
    [row addSubview:meta];

    UIImageView *play = [[UIImageView alloc] initWithFrame:CGRectZero];
    play.image = [UIImage systemImageNamed:@"play.fill"];
    play.tintColor = s.cPrimary;
    play.contentMode = UIViewContentModeScaleAspectFit;
    play.tag = 4103;
    [row addSubview:play];

    __weak typeof(self) weakSelf = self;
    __weak typeof(version) weakVersion = version;
    [row addAction:[UIAction actionWithHandler:^(UIAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        __strong typeof(weakVersion) strongVersion = weakVersion;
        if (!self || !strongVersion) return;
        [self.delegate homeCardView:self didActivateVersion:strongVersion];
    }] forControlEvents:UIControlEventTouchUpInside];
}

/// 版本行内部布局（行宽变化时由父视图调用）。
- (void)layoutVersionRow:(UIView *)row {
    CGFloat width = CGRectGetWidth(row.bounds);
    CGFloat height = CGRectGetHeight(row.bounds);
    UIView *play = [row viewWithTag:4103];
    UIView *name = [row viewWithTag:4101];
    UIView *meta = [row viewWithTag:4102];
    CGFloat playWidth = 12;
    play.frame = CGRectMake(width - playWidth - 12, (height - 12) / 2, playWidth, 12);
    name.frame = CGRectMake(12, 3, width - playWidth - 36, 18);
    meta.frame = CGRectMake(12, height - 17, width - playWidth - 36, 14);
}

- (NSString *)metaTextForVersion:(A2Version *)version {
    NSString *loader = version.loaderInfo.length ? version.loaderInfo : @"原版";
    NSDate *played = version.lastPlayed;
    if (!played) return loader;
    NSTimeInterval delta = -[played timeIntervalSinceNow];
    NSString *when = nil;
    if (delta < 60 * 60) when = [NSString stringWithFormat:@"%ld 分钟前", (long)MAX((NSInteger)1, (NSInteger)(delta / 60))];
    else if (delta < 60 * 60 * 24) when = [NSString stringWithFormat:@"%ld 小时前", (long)(delta / 3600)];
    else when = [NSString stringWithFormat:@"%ld 天前", (long)(delta / 86400)];
    return [NSString stringWithFormat:@"%@ · 上次 %@", loader, when];
}

- (void)buildGreeting {
    A2ColorScheme *s = A2ThemeManager.shared.scheme;
    // 字号来自用户档位（16…32），是唯一不走 A2Typography 阶梯的字号（用户可调）。
    NSInteger fontSize = self.card.options.greetingFontSize;
    if (fontSize < 16 || fontSize > 32) fontSize = 22;
    UIFont *greetingFont =
        [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:fontSize
                                                                          weight:UIFontWeightSemibold]];

    NSString *text = [A2HomeRuntime.shared greetingTextForMode:self.card.options.greetingMode
                                                    customText:self.card.options.greetingText];
    UILabel *hello = [self addLabelWithText:text font:greetingFont color:s.cOnSurface height:0];
    hello.numberOfLines = 1;
    hello.minimumScaleFactor = 0.6;
    hello.adjustsFontSizeToFitWidth = YES;

    NSString *account = [A2HomeRuntime.shared currentAccountName];
    NSString *sub = account.length ? [NSString stringWithFormat:@"%@ · 今天想玩点什么？", account]
                                   : @"还没有登录账号";
    [self addLabelWithText:sub font:[A2Typography caption] color:s.cOnSurfaceVariant height:16];
}

- (void)buildCalendar {
    A2ColorScheme *s = A2ThemeManager.shared.scheme;
    NSDate *now = NSDate.date;
    NSDateComponents *c = [NSCalendar.currentCalendar components:(NSCalendarUnitYear | NSCalendarUnitMonth |
                                                                  NSCalendarUnitDay | NSCalendarUnitWeekday)
                                                       fromDate:now];
    NSArray<NSString *> *weekdays = @[@"周日", @"周一", @"周二", @"周三", @"周四", @"周五", @"周六"];
    NSInteger weekdayIndex = MAX((NSInteger)0, MIN((NSInteger)6, c.weekday - 1));

    NSString *big = [NSString stringWithFormat:@"%ld", (long)c.day];
    UILabel *day = [self addLabelWithText:big font:[A2Typography titleLarge] color:s.cOnSurface height:0];
    day.textAlignment = NSTextAlignmentLeft;

    NSString *sub = [NSString stringWithFormat:@"%ld 月 · %@", (long)c.month, weekdays[weekdayIndex]];
    [self addLabelWithText:sub font:[A2Typography body] color:s.cOnSurfaceVariant height:22];
}

- (void)buildVersionList:(BOOL)pinned {
    A2ColorScheme *s = A2ThemeManager.shared.scheme;
    NSArray<A2Version *> *versions = pinned ? [A2HomeRuntime.shared pinnedVersions]
                                            : [A2HomeRuntime.shared recentVersionsLimitedTo:self.card.options.recentLimit];
    if (versions.count == 0) {
        // 空态：图标 + 文案（M3 空态；引导动作在卡片菜单里）。
        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectZero];
        icon.image = [UIImage systemImageNamed:(pinned ? @"pin" : @"clock")];
        icon.tintColor = s.cOnSurfaceVariant;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentContainer addSubview:icon];
        [self.contentHeights addObject:@(20)];
        [self addLabelWithText:(pinned ? @"还没有钉到主页的版本" : @"还没有游玩记录")
                          font:[A2Typography body]
                         color:s.cOnSurfaceVariant
                        height:0];
        return;
    }
    // 行数受「跨行数」限制：1 行高最多 2 条，2 行高最多 4 条（不滚动，避免嵌套手势打架）。
    NSInteger maxRows = A2HomeSpanForSize(self.card.size).rows >= 2 ? 4 : 2;
    NSInteger limit = MIN((NSInteger)versions.count, maxRows);
    for (NSInteger i = 0; i < limit; i++) {
        [self addVersionRow:versions[(NSUInteger)i]];
    }
}

- (void)buildUnavailableKind {
    A2ColorScheme *s = A2ThemeManager.shared.scheme;
    [self addLabelWithText:@"此卡片类型在当前版本暂不可用"
                      font:[A2Typography body]
                     color:s.cOnSurfaceVariant
                    height:0];
}

- (void)buildShortcut {
    A2ColorScheme *s = A2ThemeManager.shared.scheme;
    A2HomeCardTarget *target = self.card.target;
    A2HomeResolvedTarget *resolved = target ? [A2HomeRuntime.shared resolveTarget:target kind:self.card.kind] : nil;

    if (!resolved || !resolved.isUsable) {
        // ★软失败★：保留兜底名 + 原因，卡片不删、位置不动。
        UIImageView *warn = [[UIImageView alloc] initWithFrame:CGRectZero];
        warn.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
        warn.tintColor = s.cWarning;
        warn.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentContainer addSubview:warn];
        [self.contentHeights addObject:@(18)];

        UILabel *label = [self addLabelWithText:(resolved.label.length ? resolved.label : @"已失效的引用")
                                          font:[A2Typography body]
                                         color:s.cOnSurface
                                        height:0];
        label.numberOfLines = 1;
        NSString *why = resolved.message.length ? resolved.message : @"内容不可用";
        [self addLabelWithText:[NSString stringWithFormat:@"%@ · 点按重新指定", why]
                          font:[A2Typography caption]
                         color:s.cWarning
                        height:16];
        return;
    }

    BOOL wide = self.displayColumnSpan >= 2;
    UILabel *name = [self addLabelWithText:resolved.label
                                      font:[A2Typography titleCard]
                                     color:s.cOnSurface
                                    height:0];
    name.numberOfLines = wide ? 1 : 2;
    [self addLabelWithText:resolved.meta font:[A2Typography caption] color:s.cOnSurfaceVariant height:16];

    if (wide) {
        UILabel *launch = [self addLabelWithText:@"启动 ›"
                                            font:[A2Typography button]
                                           color:s.cPrimary
                                          height:18];
        launch.textAlignment = NSTextAlignmentLeft;
    }
}

#pragma mark - 自定义卡片

- (void)buildCustomCard {
    A2ColorScheme *s = A2ThemeManager.shared.scheme;
    A2HomeCardOptions *options = self.card.options;

    NSString *reason = nil;
    BOOL usable = [options isJumpUsableWithReason:&reason];

    if (!usable) {
        // ★软失败★：卡片留在原位，只把「跳转」这一步标成失效 —— 与引用类卡片同一口径
        // （删卡是用户没授权的布局变更；他可能只是暂时清空了网址）。
        UIImageView *warn = [[UIImageView alloc] initWithFrame:CGRectZero];
        warn.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
        warn.tintColor = s.cWarning;
        warn.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentContainer addSubview:warn];
        [self.contentHeights addObject:@(18)];

        UILabel *label = [self addLabelWithText:@"跳转目标已失效"
                                          font:[A2Typography body]
                                         color:s.cOnSurface
                                        height:0];
        label.numberOfLines = 1;
        [self addLabelWithText:[NSString stringWithFormat:@"%@ · 点按重新指定", reason ?: @"未知原因"]
                          font:[A2Typography caption]
                         color:s.cWarning
                        height:16];
        return;
    }

    BOOL isURL = (options.jumpKind == A2HomeJumpKindURL);
    NSString *headline = isURL ? (A2HomeWebURLFromString(options.jumpURLString).host ?: options.jumpURLString)
                               : A2HomeJumpPageDisplayName(options.jumpPage);

    BOOL wide = self.displayColumnSpan >= 2;
    UILabel *target = [self addLabelWithText:headline
                                        font:[A2Typography titleCard]
                                       color:s.cOnSurface
                                      height:0];
    target.numberOfLines = wide ? 1 : 2;
    [self addLabelWithText:(isURL ? @"在浏览器中打开" : @"App 内页面")
                      font:[A2Typography caption]
                     color:s.cOnSurfaceVariant
                    height:16];

    if (wide) {
        UILabel *open = [self addLabelWithText:@"打开 ›"
                                          font:[A2Typography button]
                                         color:s.cPrimary
                                        height:18];
        open.textAlignment = NSTextAlignmentLeft;
    }
}

#pragma mark - 交互

- (void)handleTap:(UITapGestureRecognizer *)recognizer {
    if (self.editing || recognizer.state != UIGestureRecognizerStateEnded) return;
    [self setPressed:NO];
    if (A2HomeKindRequiresTarget(self.card.kind)) {
        A2HomeCardTarget *target = self.card.target;
        A2HomeResolvedTarget *resolved = target ? [A2HomeRuntime.shared resolveTarget:target kind:self.card.kind] : nil;
        if (!resolved || !resolved.isUsable) {
            // 引用失效：点卡片进「重新指定」，而不是启动一个不存在的东西。
            [self.delegate homeCardViewDidRequestMenu:self];
            return;
        }
    }
    if (self.card.kind == A2HomeCardKindShortcutCustom) {
        // 跳转失效：点卡片进「编辑卡片」，不打开一个到不了的目标。
        if (![self.card.options isJumpUsableWithReason:NULL]) {
            [self.delegate homeCardViewDidRequestMenu:self];
            return;
        }
    }
    [self.delegate homeCardViewDidActivate:self];
}

- (void)handleMenuTap {
    [self.delegate homeCardViewDidRequestMenu:self];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (!self.editing) [self setPressed:YES];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [self setPressed:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [self setPressed:NO];
}

#pragma mark - M3 state layer

- (void)setPressed:(BOOL)pressed {
    _pressed = pressed;
    [self updateStateLayerAnimated:YES];
}

- (void)updateStateLayerAnimated:(BOOL)animated {
    // M3：按下 12%；拖动浮起按「dragged」16%。
    CGFloat target = 0.0;
    if (self.isLifted) target = A2HomeStateLayerDragged;
    else if (self.isPressed) target = A2HomeStateLayerPressed;

    void (^apply)(void) = ^{ self.stateLayer.alpha = target; };
    if (!animated) { apply(); return; }
    UIViewPropertyAnimator *animator = A2SpringAnimator(A2AnimDurationFast);
    [animator addAnimations:apply];
    [animator startAnimation];
}

@end
