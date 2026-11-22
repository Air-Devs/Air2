//
//  A2DownloadPanel.m
//  Air2
//

#import "A2DownloadPanel.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

#pragma mark - Item

@implementation A2DownloadPanelItem
@end

#pragma mark - Row

@interface A2DownloadPanelRow : UIView
@property (nonatomic, strong) A2DownloadPanelItem *item;
@property (nonatomic, copy, nullable) void (^onCancel)(void);
@property (nonatomic, copy, nullable) void (^onInstall)(void);
- (instancetype)initWithItem:(A2DownloadPanelItem *)item;
- (void)reload;
- (void)applyTheme;
@end

@implementation A2DownloadPanelRow {
    UILabel *_titleLabel;
    UILabel *_statusLabel;
    UILabel *_percentLabel;
    UILabel *_speedLabel;
    UIView *_track;
    UIView *_fill;
    NSLayoutConstraint *_fillWidth;
    UIButton *_actionButton;
}

- (instancetype)initWithItem:(A2DownloadPanelItem *)item {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _item = item;

    _titleLabel = [self label:13 weight:UIFontWeightMedium];
    _titleLabel.numberOfLines = 1;

    _percentLabel = [self label:11 weight:UIFontWeightSemibold];
    _percentLabel.textAlignment = NSTextAlignmentRight;

    _speedLabel = [self label:10 weight:UIFontWeightRegular];

    _statusLabel = [self label:10 weight:UIFontWeightRegular];
    _statusLabel.numberOfLines = 1;

    // 进度条
    _track = [[UIView alloc] initWithFrame:CGRectZero];
    _track.translatesAutoresizingMaskIntoConstraints = NO;
    _track.layer.cornerRadius = 2;
    _track.clipsToBounds = YES;

    _fill = [[UIView alloc] initWithFrame:CGRectZero];
    _fill.translatesAutoresizingMaskIntoConstraints = NO;
    _fill.layer.cornerRadius = 2;
    [_track addSubview:_fill];

    _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_actionButton setImage:[UIImage systemImageNamed:@"xmark"]
                   forState:UIControlStateNormal];
    [_actionButton.widthAnchor constraintEqualToConstant:28].active = YES;
    [_actionButton.heightAnchor constraintEqualToConstant:28].active = YES;
    [_actionButton addTarget:self action:@selector(actionTapped)
            forControlEvents:UIControlEventTouchUpInside];

    // 布局：标题行（标题 + 百分比 + 动作）
    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:
                           @[_titleLabel, _percentLabel, _actionButton]];
    topRow.translatesAutoresizingMaskIntoConstraints = NO;
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.spacing = 6;
    topRow.alignment = UIStackViewAlignmentCenter;
    [_titleLabel setContentHuggingPriority:UILayoutPriorityDefaultLow
                                    forAxis:UILayoutConstraintAxisHorizontal];

    // 状态行（状态文字 + 速率）
    UIStackView *statusRow = [[UIStackView alloc] initWithArrangedSubviews:
                              @[_statusLabel, _speedLabel]];
    statusRow.translatesAutoresizingMaskIntoConstraints = NO;
    statusRow.axis = UILayoutConstraintAxisHorizontal;
    statusRow.spacing = 8;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[topRow, _track, statusRow]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 5;
    [self addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],

        [_track.heightAnchor constraintEqualToConstant:4],
        [_fill.topAnchor constraintEqualToAnchor:_track.topAnchor],
        [_fill.bottomAnchor constraintEqualToAnchor:_track.bottomAnchor],
        [_fill.leadingAnchor constraintEqualToAnchor:_track.leadingAnchor],
    ]];
    _fillWidth = [_fill.widthAnchor constraintEqualToConstant:0];
    _fillWidth.active = YES;

    [self reload];
    return self;
}

- (UILabel *)label:(CGFloat)size weight:(UIFontWeight)weight {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    return l;
}

- (void)reload {
    A2DownloadPanelItem *it = self.item;

    _titleLabel.text = it.title;
    _statusLabel.text = it.isReadyToInstall ? @"待安装 · 点击安装"
                                            : (it.statusText ?: @"");

    if (it.isReadyToInstall) {
        _percentLabel.text = @"完成";
        _speedLabel.text = @"";
        _fillWidth.constant = _track.bounds.size.width;
        [_actionButton setImage:[UIImage systemImageNamed:@"xmark"]
                       forState:UIControlStateNormal];
    } else if (it.hasFailed) {
        _percentLabel.text = @"失败";
        _speedLabel.text = @"";
        _fillWidth.constant = 0;
    } else {
        _percentLabel.text = [NSString stringWithFormat:@"%.0f%%", it.progress * 100];
        _speedLabel.text = it.speedBytesPerSec > 0
            ? [NSString stringWithFormat:@"%@/s", [self formatBytes:it.speedBytesPerSec]]
            : @"";
        [self setNeedsLayout];
        [self layoutIfNeeded];
        _fillWidth.constant = _track.bounds.size.width * MAX(0, MIN(1, it.progress));
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.item.isReadyToInstall) {
        _fillWidth.constant = _track.bounds.size.width;
    } else if (!self.item.hasFailed) {
        _fillWidth.constant = _track.bounds.size.width * MAX(0, MIN(1, self.item.progress));
    }
}

- (void)actionTapped {
    // 完成态 → 点击安装；进行中 → 点击取消（对照 FCL 的行为）
    if (self.item.isReadyToInstall) {
        if (self.onInstall) self.onInstall();
    } else {
        if (self.onCancel) self.onCancel();
    }
}

- (NSString *)formatBytes:(double)bytes {
    if (bytes >= 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes / 1048576];
    if (bytes >= 1024) return [NSString stringWithFormat:@"%.0f KB", bytes / 1024];
    return [NSString stringWithFormat:@"%.0f B", bytes];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _titleLabel.textColor = t.cOnSurface;
    _percentLabel.textColor = t.cOnSurfaceVariant;
    _statusLabel.textColor = t.cOnSurfaceVariant;
    _speedLabel.textColor = t.cOnSurfaceVariant;
    _track.backgroundColor = [t.cPrimary colorWithAlphaComponent:0.15];
    _fill.backgroundColor = self.item.hasFailed ? t.cError : t.cPrimary;
    _actionButton.tintColor = t.cOnSurfaceVariant;
}

@end

#pragma mark - Panel

@interface A2DownloadPanel ()
@property (nonatomic, strong) UIView *collapsedBar;
@property (nonatomic, strong) UILabel *collapsedLabel;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UILabel *panelTitle;
@property (nonatomic, strong) UIStackView *listStack;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSArray<A2DownloadPanelItem *> *items;
@property (nonatomic, assign, readwrite, getter=isExpanded) BOOL expanded;
@property (nonatomic, strong) NSLayoutConstraint *panelWidth;
@property (nonatomic, strong) NSLayoutConstraint *panelTrailing;
@end

@implementation A2DownloadPanel

+ (instancetype)attachToView:(UIView *)host {
    A2DownloadPanel *p = [[A2DownloadPanel alloc] initWithFrame:CGRectZero];
    p.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:p];
    [NSLayoutConstraint activateConstraints:@[
        [p.topAnchor constraintEqualToAnchor:host.topAnchor],
        [p.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [p.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [p.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
    ]];
    p.userInteractionEnabled = NO;   // 只有子视图接收触摸
    [p build];
    return p;
}

- (void)build {
    self.autoHideWhenEmpty = YES;

    // ---- 收起态胶囊 ----
    _collapsedBar = [[UIView alloc] initWithFrame:CGRectZero];
    _collapsedBar.translatesAutoresizingMaskIntoConstraints = NO;
    _collapsedBar.layer.cornerRadius = 22;
    _collapsedBar.layer.cornerCurve = kCACornerCurveContinuous;
    _collapsedBar.userInteractionEnabled = YES;
    _collapsedBar.clipsToBounds = YES;
    [self addSubview:_collapsedBar];

    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectZero];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.image = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
    icon.contentMode = UIViewContentModeScaleAspectFit;

    _collapsedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _collapsedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _collapsedLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];

    UIStackView *barStack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, _collapsedLabel]];
    barStack.translatesAutoresizingMaskIntoConstraints = NO;
    barStack.axis = UILayoutConstraintAxisHorizontal;
    barStack.spacing = 6;
    barStack.alignment = UIStackViewAlignmentCenter;
    [_collapsedBar addSubview:barStack];

    [NSLayoutConstraint activateConstraints:@[
        [_collapsedBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [_collapsedBar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16],
        [_collapsedBar.heightAnchor constraintEqualToConstant:44],

        [barStack.topAnchor constraintEqualToAnchor:_collapsedBar.topAnchor],
        [barStack.bottomAnchor constraintEqualToAnchor:_collapsedBar.bottomAnchor],
        [barStack.leadingAnchor constraintEqualToAnchor:_collapsedBar.leadingAnchor constant:14],
        [barStack.trailingAnchor constraintEqualToAnchor:_collapsedBar.trailingAnchor constant:-14],
        [icon.widthAnchor constraintEqualToConstant:16],
        [icon.heightAnchor constraintEqualToConstant:16],
    ]];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(expand)];
    [_collapsedBar addGestureRecognizer:tap];

    // ---- 展开态面板 ----
    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    _panel.translatesAutoresizingMaskIntoConstraints = NO;
    _panel.userInteractionEnabled = YES;
    // MD3：左侧大圆角（贴右边缘）
    _panel.layer.cornerRadius = A2RadiusXL;
    _panel.layer.cornerCurve = kCACornerCurveContinuous;
    _panel.hidden = YES;
    [self addSubview:_panel];

    _panelTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _panelTitle.translatesAutoresizingMaskIntoConstraints = NO;
    _panelTitle.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setImage:[UIImage systemImageNamed:@"chevron.right"]
           forState:UIControlStateNormal];
    [close addTarget:self action:@selector(collapse) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[_panelTitle, close]];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.axis = UILayoutConstraintAxisHorizontal;
    header.spacing = 8;

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.showsVerticalScrollIndicator = YES;

    _listStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _listStack.translatesAutoresizingMaskIntoConstraints = NO;
    _listStack.axis = UILayoutConstraintAxisVertical;
    _listStack.spacing = 0;
    [_scroll addSubview:_listStack];

    [_panel addSubview:header];
    [_panel addSubview:_scroll];

    _panelWidth = [_panel.widthAnchor constraintEqualToConstant:320];
    _panelTrailing = [_panel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:340];

    [NSLayoutConstraint activateConstraints:@[
        _panelWidth, _panelTrailing,
        [_panel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [_panel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],

        [header.topAnchor constraintEqualToAnchor:_panel.topAnchor constant:14],
        [header.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor constant:16],
        [header.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor constant:-12],

        [_scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
        [_scroll.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:_panel.bottomAnchor constant:-8],

        [_listStack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor],
        [_listStack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor],
        [_listStack.leadingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.leadingAnchor],
        [_listStack.trailingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.trailingAnchor],
    ]];

    [self applyTheme];
}

#pragma mark - 数据

- (void)updateItems:(NSArray<A2DownloadPanelItem *> *)items {
    self.items = items ?: @[];

    // 重建列表（任务数量通常不多，直接重建比 diff 简单可靠）
    for (UIView *v in [self.listStack.arrangedSubviews copy]) {
        [self.listStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    __weak typeof(self) weakSelf = self;
    for (A2DownloadPanelItem *it in self.items) {
        A2DownloadPanelRow *row = [[A2DownloadPanelRow alloc] initWithItem:it];
        row.onCancel = ^{
            __strong typeof(weakSelf) self = weakSelf;
            if ([self.delegate respondsToSelector:@selector(downloadPanelDidTapCancel:)]) {
                [self.delegate downloadPanelDidTapCancel:it];
            }
        };
        row.onInstall = ^{
            __strong typeof(weakSelf) self = weakSelf;
            if ([self.delegate respondsToSelector:@selector(downloadPanelDidTapInstall:)]) {
                [self.delegate downloadPanelDidTapInstall:it];
            }
        };
        [row applyTheme];
        [self.listStack addArrangedSubview:row];

        // 分隔线
        UIView *sep = [[UIView alloc] initWithFrame:CGRectZero];
        sep.translatesAutoresizingMaskIntoConstraints = NO;
        [sep.heightAnchor constraintEqualToConstant:1].active = YES;
        sep.backgroundColor = A2ThemeManager.shared.scheme.cOutlineVariant;
        [self.listStack addArrangedSubview:sep];
    }

    // 汇总
    NSUInteger active = 0;
    double totalSpeed = 0;
    for (A2DownloadPanelItem *it in self.items) {
        if (!it.isReadyToInstall && !it.hasFailed) {
            active++;
            totalSpeed += it.speedBytesPerSec;
        }
    }

    _panelTitle.text = [NSString stringWithFormat:@"下载中 (%lu)", (unsigned long)self.items.count];

    if (self.items.count == 0) {
        self.hidden = self.autoHideWhenEmpty;
        return;
    }
    self.hidden = NO;

    NSString *speedText = totalSpeed > 0
        ? [NSString stringWithFormat:@" · %@/s", [self formatBytes:totalSpeed]]
        : @"";
    _collapsedLabel.text = [NSString stringWithFormat:@"%lu 个任务%@",
                            (unsigned long)active, speedText];

    // 让胶囊宽度自适应内容
    [_collapsedBar.superview setNeedsLayout];
}

- (NSString *)formatBytes:(double)bytes {
    if (bytes >= 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes / 1048576];
    if (bytes >= 1024) return [NSString stringWithFormat:@"%.0f KB", bytes / 1024];
    return [NSString stringWithFormat:@"%.0f B", bytes];
}

#pragma mark - 展开收起

- (void)expand {
    if (self.expanded || self.items.count == 0) return;
    self.expanded = YES;
    _panel.hidden = NO;

    _panelTrailing.constant = -8;
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.82
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_collapsedBar.alpha = 0;
        [self layoutIfNeeded];
    } completion:nil];
}

- (void)collapse {
    if (!self.expanded) return;
    self.expanded = NO;

    _panelTrailing.constant = 340;
    [UIView animateWithDuration:0.24
                          delay:0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self->_collapsedBar.alpha = 1;
        [self layoutIfNeeded];
    } completion:^(BOOL finished) {
        self->_panel.hidden = YES;
    }];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    _collapsedBar.backgroundColor = t.cSurfaceContainerHigh;
    _collapsedLabel.textColor = t.cOnSurface;
    _panel.backgroundColor = t.cSurfaceContainer;
    _panelTitle.textColor = t.cOnSurface;

    for (UIView *v in self.listStack.arrangedSubviews) {
        if ([v isKindOfClass:A2DownloadPanelRow.class]) {
            [(A2DownloadPanelRow *)v applyTheme];
        } else {
            v.backgroundColor = t.cOutlineVariant;
        }
    }
}

@end
