//
//  A2LoaderCard.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  见头文件：一张卡 = 一个加载器（或原版）的完整选择界面。
//

#import "A2LoaderCard.h"
#import "A2ModLoaderAPI.h"
#import "A2GlassCard.h"
#import "A2ThemeManager.h"
#import "A2ColorScheme.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import "A2Log.h"

#pragma mark - 常量

/// 图标方块边长。与选版页同尺寸，两页并排看列是对齐的。
static const CGFloat kA2LoaderIconBox = 34;
/// 图标符号点数。
static const CGFloat kA2LoaderIconPoint = 17;
/// 卡头最小高度。
static const CGFloat kA2LoaderHeaderMinHeight = 54;
/// 版本行高。定高，才能直接按条数算出内嵌列表该占多高。
static const CGFloat kA2LoaderRowHeight = 46;
/// 展开后版本列表的最大高度：约 5 行半，再多就在卡内滚动。
static const CGFloat kA2LoaderListMaxHeight = 256;

static NSString *const kA2LoaderCellID = @"A2LoaderVersionCell";

typedef NS_ENUM(NSInteger, A2LoaderCardState) {
    A2LoaderCardStateIdle = 0,   ///< 还没拉过
    A2LoaderCardStateLoading,    ///< 正在拉
    A2LoaderCardStateLoaded,     ///< 拉到了（可能为空）
    A2LoaderCardStateFailed,     ///< 拉失败，可重试
};

/// 加载器 → 图标符号。本项目自定，不套用任何上游的配图。
static NSString *A2LoaderSymbol(A2ModLoaderType type) {
    switch (type) {
        case A2ModLoaderTypeFabric:       return @"puzzlepiece.extension.fill";
        case A2ModLoaderTypeQuilt:        return @"square.grid.3x3.fill";
        case A2ModLoaderTypeLegacyFabric: return @"clock.arrow.circlepath";
        case A2ModLoaderTypeForge:        return @"hammer.fill";
        case A2ModLoaderTypeNeoForge:     return @"flame.fill";
        case A2ModLoaderTypeOptiFine:     return @"wand.and.stars";
    }
    return @"cube.fill";
}

/// 强调色只从主/次/第三三档容器色里轮转 —— 六个加载器发六种颜色会花，
/// 而且和选版页的类型配色不再是一套体系。
static void A2LoaderAccent(A2ModLoaderType type, A2ColorScheme *t,
                           UIColor **box, UIColor **symbol) {
    switch (type) {
        case A2ModLoaderTypeQuilt:
        case A2ModLoaderTypeNeoForge:
            *box = t.cSecondaryContainer;
            *symbol = t.cSecondary;
            return;
        case A2ModLoaderTypeLegacyFabric:
        case A2ModLoaderTypeOptiFine:
            *box = t.cTertiaryContainer;
            *symbol = t.cTertiary;
            return;
        default:
            break;
    }
    *box = t.cPrimaryContainer;
    *symbol = t.cPrimary;
}

#pragma mark - 卡头

/// 卡头：整块可点，按下时整体变淡作为反馈。
@interface A2LoaderCardHeader : UIControl
@end

@implementation A2LoaderCardHeader

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.55 : 1.0;
}

@end

#pragma mark - 版本行

/// 版本行：版本号 + 稳定/预览标签 + 选中勾。
@interface A2LoaderVersionCell : UITableViewCell
- (void)configureWithVersion:(A2ModLoaderVersion *)version selected:(BOOL)selected;
@end

@implementation A2LoaderVersionCell {
    UILabel *_versionLabel;
    UILabel *_tagLabel;
    UIImageView *_checkView;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _versionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionLabel.font = [A2Typography body];
    _versionLabel.numberOfLines = 1;
    [_versionLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                   forAxis:UILayoutConstraintAxisHorizontal];
    [self.contentView addSubview:_versionLabel];

    _tagLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _tagLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _tagLabel.font = [A2Typography caption];
    _tagLabel.numberOfLines = 1;
    [self.contentView addSubview:_tagLabel];

    _checkView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _checkView.translatesAutoresizingMaskIntoConstraints = NO;
    _checkView.contentMode = UIViewContentModeCenter;
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
    _checkView.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:cfg];
    [self.contentView addSubview:_checkView];

    [NSLayoutConstraint activateConstraints:@[
        [_versionLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                    constant:A2SpaceM],
        [_versionLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],

        [_tagLabel.leadingAnchor constraintEqualToAnchor:_versionLabel.trailingAnchor
                                                constant:A2SpaceS],
        [_tagLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_tagLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_checkView.leadingAnchor
                                                           constant:-A2SpaceS],

        [_checkView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                  constant:-A2SpaceM],
        [_checkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_checkView.widthAnchor constraintEqualToConstant:20],
        [_checkView.heightAnchor constraintEqualToConstant:20],
    ]];

    return self;
}

- (void)configureWithVersion:(A2ModLoaderVersion *)version selected:(BOOL)selected {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _versionLabel.text = version.version;
    _versionLabel.textColor = selected ? t.cPrimary : t.cOnSurface;
    _tagLabel.text = version.stable ? @"稳定版" : @"预览版";
    _tagLabel.textColor = t.cOnSurfaceVariant;
    _checkView.hidden = !selected;
    _checkView.tintColor = t.cPrimary;
}

@end

#pragma mark - 加载器卡

@interface A2LoaderCard () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, assign, readwrite) BOOL isVanilla;
@property (nonatomic, assign, readwrite) A2ModLoaderType loaderType;
@property (nonatomic, strong, readwrite, nullable) A2ModLoaderVersion *selectedVersion;

@property (nonatomic, copy) NSString *mcVersion;
@property (nonatomic, assign) A2LoaderCardState state;
@property (nonatomic, strong) NSArray<A2ModLoaderVersion *> *versions;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic, assign) BOOL expanded;

@property (nonatomic, strong) A2GlassCard *card;
@property (nonatomic, strong) A2LoaderCardHeader *header;
@property (nonatomic, strong) UIView *iconBox;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UIImageView *trailingIcon;

@property (nonatomic, strong) UIStackView *bodyStack;
@property (nonatomic, strong) UIStackView *loadingRow;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *loadingLabel;
@property (nonatomic, strong) UIStackView *messageRow;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSLayoutConstraint *tableHeight;

@end

@implementation A2LoaderCard

#pragma mark - 构造

- (instancetype)initAsVanilla {
    // 原版不是加载器，借用同一个类是为了让「一组选项卡」外观完全一致；
    // 它没有版本可选，展开体恒为空。
    return [self initWithLoaderType:A2ModLoaderTypeFabric mcVersion:@"" vanilla:YES];
}

- (instancetype)initWithLoaderType:(A2ModLoaderType)type mcVersion:(NSString *)mcVersion {
    return [self initWithLoaderType:type mcVersion:mcVersion vanilla:NO];
}

// 与头文件 NS_UNAVAILABLE 对应：加载器卡必须走上面两个初始化器，
// 否则拿不到类型/mcVersion。保留实现体是因为声明/实现一致性检查
// 要求每个声明都有实现；编译期已拦截，走到这里即返回 nil。
- (instancetype)initWithFrame:(CGRect)frame { return nil; }
- (instancetype)initWithCoder:(NSCoder *)coder { return nil; }

- (instancetype)initWithLoaderType:(A2ModLoaderType)type
                         mcVersion:(NSString *)mcVersion
                           vanilla:(BOOL)vanilla {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _isVanilla = vanilla;
    _loaderType = type;
    _mcVersion = [mcVersion copy];
    _versions = @[];
    _state = A2LoaderCardStateIdle;

    [self buildCard];
    [self refreshTheme];
    [self refreshBody];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(refreshTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 视图

- (void)buildCard {
    _card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.cornerRadius = A2RadiusL;
    _card.elevation = A2CardElevationLow;
    _card.contentInsets = UIEdgeInsetsMake(A2SpaceS, A2SpaceM, A2SpaceS, A2SpaceM);
    [self addSubview:_card];
    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];

    UIView *cv = _card.contentView;
    UIStackView *content = [[UIStackView alloc] initWithFrame:CGRectZero];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = A2SpaceS;
    [cv addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:cv.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
    ]];

    [content addArrangedSubview:[self buildHeader]];

    _bodyStack = [self buildBody];
    _bodyStack.hidden = YES;
    [content addArrangedSubview:_bodyStack];
}

- (UIView *)buildHeader {
    _header = [[A2LoaderCardHeader alloc] initWithFrame:CGRectZero];
    _header.translatesAutoresizingMaskIntoConstraints = NO;
    [_header addTarget:self action:@selector(headerTapped)
      forControlEvents:UIControlEventTouchUpInside];

    _iconBox = [[UIView alloc] initWithFrame:CGRectZero];
    _iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBox.layer.cornerRadius = A2RadiusS;
    _iconBox.layer.cornerCurve = kCACornerCurveContinuous;
    _iconBox.clipsToBounds = YES;
    _iconBox.userInteractionEnabled = NO;
    [_header addSubview:_iconBox];

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeCenter;
    [_iconBox addSubview:_iconView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [A2Typography titleCard];
    _titleLabel.numberOfLines = 1;

    _summaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _summaryLabel.font = [A2Typography caption];
    _summaryLabel.numberOfLines = 1;
    [_summaryLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                  forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _summaryLabel]];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;
    text.alignment = UIStackViewAlignmentLeading;
    text.userInteractionEnabled = NO;
    [_header addSubview:text];

    _trailingIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _trailingIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _trailingIcon.contentMode = UIViewContentModeCenter;
    [_header addSubview:_trailingIcon];

    [NSLayoutConstraint activateConstraints:@[
        [_header.heightAnchor constraintGreaterThanOrEqualToConstant:kA2LoaderHeaderMinHeight],

        [_iconBox.leadingAnchor constraintEqualToAnchor:_header.leadingAnchor constant:A2SpaceS],
        [_iconBox.centerYAnchor constraintEqualToAnchor:_header.centerYAnchor],
        [_iconBox.widthAnchor constraintEqualToConstant:kA2LoaderIconBox],
        [_iconBox.heightAnchor constraintEqualToConstant:kA2LoaderIconBox],

        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBox.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBox.centerYAnchor],

        [text.leadingAnchor constraintEqualToAnchor:_iconBox.trailingAnchor constant:A2SpaceM],
        [text.centerYAnchor constraintEqualToAnchor:_header.centerYAnchor],
        [text.topAnchor constraintGreaterThanOrEqualToAnchor:_header.topAnchor constant:A2SpaceS],
        [text.bottomAnchor constraintLessThanOrEqualToAnchor:_header.bottomAnchor constant:-A2SpaceS],
        [text.trailingAnchor constraintLessThanOrEqualToAnchor:_trailingIcon.leadingAnchor
                                                      constant:-A2SpaceS],

        [_trailingIcon.trailingAnchor constraintEqualToAnchor:_header.trailingAnchor constant:-A2SpaceS],
        [_trailingIcon.centerYAnchor constraintEqualToAnchor:_header.centerYAnchor],
        [_trailingIcon.widthAnchor constraintEqualToConstant:22],
        [_trailingIcon.heightAnchor constraintEqualToConstant:22],
    ]];
    return _header;
}

- (UIStackView *)buildBody {
    UIStackView *body = [[UIStackView alloc] initWithFrame:CGRectZero];
    body.axis = UILayoutConstraintAxisVertical;
    body.spacing = A2SpaceS;

    // —— 加载中 ——
    _spinner = [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _loadingLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingLabel.font = [A2Typography caption];
    _loadingLabel.text = @"正在获取版本…";
    _loadingRow = [[UIStackView alloc] initWithArrangedSubviews:@[_spinner, _loadingLabel]];
    _loadingRow.axis = UILayoutConstraintAxisHorizontal;
    _loadingRow.spacing = A2SpaceS;
    _loadingRow.alignment = UIStackViewAlignmentCenter;
    _loadingRow.layoutMarginsRelativeArrangement = YES;
    _loadingRow.layoutMargins = UIEdgeInsetsMake(A2SpaceS, A2SpaceS, A2SpaceS, A2SpaceS);

    // —— 失败 ——
    _messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _messageLabel.font = [A2Typography caption];
    _messageLabel.numberOfLines = 0;
    _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_retryButton setTitle:@"重试" forState:UIControlStateNormal];
    _retryButton.titleLabel.font = [A2Typography button];
    [_retryButton addTarget:self action:@selector(retryTapped)
           forControlEvents:UIControlEventTouchUpInside];
    [_retryButton setContentHuggingPriority:UILayoutPriorityRequired
                                    forAxis:UILayoutConstraintAxisHorizontal];
    _messageRow = [[UIStackView alloc] initWithArrangedSubviews:@[_messageLabel, _retryButton]];
    _messageRow.axis = UILayoutConstraintAxisVertical;
    _messageRow.spacing = A2SpaceS;
    _messageRow.alignment = UIStackViewAlignmentLeading;
    _messageRow.layoutMarginsRelativeArrangement = YES;
    _messageRow.layoutMargins = UIEdgeInsetsMake(A2SpaceS, A2SpaceS, A2SpaceS, A2SpaceS);

    // —— 版本列表 ——
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = kA2LoaderRowHeight;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorInset = UIEdgeInsetsMake(0, A2SpaceM, 0, 0);
    _tableView.alwaysBounceVertical = NO;
    [_tableView registerClass:A2LoaderVersionCell.class forCellReuseIdentifier:kA2LoaderCellID];

    [body addArrangedSubview:_loadingRow];
    [body addArrangedSubview:_messageRow];
    [body addArrangedSubview:_tableView];

    _tableHeight = [_tableView.heightAnchor constraintEqualToConstant:kA2LoaderRowHeight];
    _tableHeight.active = YES;
    return body;
}

#pragma mark - 交互

- (void)headerTapped {
    // 原版没有版本可选，点一下就是「选中它」。
    if (_isVanilla) {
        _chosen = YES;
        [A2Log log:@"download: 选择加载器 原版"];
        [self refreshHeader];
        [self notifySelection];
        return;
    }
    if (_unavailableReason.length > 0) return;

    if (_expanded) {
        [self setExpanded:NO animated:YES];
        return;
    }
    [self setExpanded:YES animated:YES];
    if (_state == A2LoaderCardStateIdle || _state == A2LoaderCardStateFailed) {
        [self fetchVersions];
    }
}

- (void)retryTapped {
    [self setExpanded:YES animated:YES];
    [self fetchVersions];
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (_isVanilla || _unavailableReason.length > 0) expanded = NO;
    BOOL didOpen = (expanded && !_expanded);
    _expanded = expanded;
    _bodyStack.hidden = !expanded;
    [self refreshHeader];
    [self refreshBody];

    if (didOpen) {
        id<A2LoaderCardDelegate> d = self.delegate;
        if ([d respondsToSelector:@selector(loaderCardDidExpand:)]) {
            [d loaderCardDidExpand:self];
        }
    }

    if (!animated) return;
    UIView *root = self;
    while (root.superview) root = root.superview;
    UIViewPropertyAnimator *a = A2StandardSpring();
    [a addAnimations:^{ [root layoutIfNeeded]; }];
    [a startAnimation];
}

- (void)collapse {
    if (!_expanded) return;
    [self setExpanded:NO animated:NO];
}

- (void)notifySelection {
    id<A2LoaderCardDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(loaderCardSelectionDidChange:)]) {
        [d loaderCardSelectionDidChange:self];
    }
}

#pragma mark - 拉取

- (void)fetchVersions {
    NSString *name = [A2ModLoaderAPI displayNameForType:_loaderType];
    _state = A2LoaderCardStateLoading;
    _errorMessage = nil;
    [self refreshBody];
    [self refreshHeader];

    [A2Log log:@"download: 拉取 %@ 版本列表（%@）", name, _mcVersion];
    __weak typeof(self) weakSelf = self;
    [[A2ModLoaderAPI shared] versionsForLoader:_loaderType
                                     mcVersion:_mcVersion
                                    completion:^(NSArray<A2ModLoaderVersion *> *versions,
                                                 NSError *error) {
        A2LoaderCard *s = weakSelf;
        if (!s) return;

        if (error) {
            s->_state = A2LoaderCardStateFailed;
            s->_errorMessage = @"版本获取失败，请检查网络后重试";
            [A2Log log:@"download: %@ 版本获取失败：%@", name, error.localizedDescription];
            [s refreshBody];
            [s refreshHeader];
            return;
        }
        if (versions.count == 0) {
            [A2Log log:@"download: %@ 在 %@ 无可用版本", name, s->_mcVersion];
            // 置不可用即收起并灰显，与 OptiFine 的呈现一致：
            // 不给出假列表，也不留一个点了没反应的展开体。
            s.unavailableReason = @"该版本不支持此加载器";
            return;
        }
        s->_versions = [versions copy];
        s->_state = A2LoaderCardStateLoaded;
        [A2Log log:@"download: %@ 可用版本 %lu 个", name, (unsigned long)versions.count];
        [s refreshBody];
        [s refreshHeader];
    }];
}

#pragma mark - 渲染

- (void)refreshBody {
    BOOL loading = (_state == A2LoaderCardStateLoading);
    BOOL failed  = (_state == A2LoaderCardStateFailed);
    BOOL hasList = (_state == A2LoaderCardStateLoaded && _versions.count > 0);
    BOOL open    = _expanded;

    _loadingRow.hidden = !(loading && open);
    _messageRow.hidden = !(failed && open);
    _tableView.hidden  = !(hasList && open);

    if (loading) [_spinner startAnimating];
    else [_spinner stopAnimating];

    if (failed && open) _messageLabel.text = _errorMessage ?: @"版本获取失败";

    if (hasList && open) {
        [_tableView reloadData];
        CGFloat wanted = _versions.count * kA2LoaderRowHeight;
        _tableHeight.constant = MIN(wanted, kA2LoaderListMaxHeight);
        // 装得下就让页面接管滚动，避免卡内截走手势又滚不动。
        _tableView.scrollEnabled = (wanted > kA2LoaderListMaxHeight);
    } else {
        // 收起或未就绪时把内嵌列表收成 0 高。UIStackView 会给隐藏的
        // arrangedSubview 补一条 required 的 0 高约束，若不归零，
        // 会和这里的定高约束互斥，刷出 Autolayout 冲突日志。
        _tableHeight.constant = 0;
        _tableView.scrollEnabled = NO;
    }
}

- (void)refreshHeader {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    BOOL unavailable = (_unavailableReason.length > 0);

    _titleLabel.text = _isVanilla ? @"原版" : [A2ModLoaderAPI displayNameForType:_loaderType];
    _summaryLabel.text = [self summaryTextForUnavailable:unavailable];

    _titleLabel.textColor = unavailable ? t.cOnSurfaceVariant : t.cOnSurface;
    BOOL highlight = (_chosen && !unavailable);
    _summaryLabel.textColor = highlight ? t.cPrimary : t.cOnSurfaceVariant;
    _iconBox.alpha = unavailable ? 0.5 : 1.0;
    _header.userInteractionEnabled = !unavailable;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    _trailingIcon.hidden = NO;
    if (unavailable) {
        _trailingIcon.hidden = YES;
    } else if (!_isVanilla && _expanded) {
        _trailingIcon.image = [UIImage systemImageNamed:@"chevron.up" withConfiguration:cfg];
        _trailingIcon.tintColor = t.cOnSurfaceVariant;
    } else if (_chosen) {
        _trailingIcon.image = [UIImage systemImageNamed:@"checkmark.circle.fill" withConfiguration:cfg];
        _trailingIcon.tintColor = t.cPrimary;
    } else if (_isVanilla) {
        _trailingIcon.image = [UIImage systemImageNamed:@"circle" withConfiguration:cfg];
        _trailingIcon.tintColor = t.cOnSurfaceVariant;
    } else {
        _trailingIcon.image = [UIImage systemImageNamed:@"chevron.down" withConfiguration:cfg];
        _trailingIcon.tintColor = t.cOnSurfaceVariant;
    }
}

- (NSString *)summaryTextForUnavailable:(BOOL)unavailable {
    if (unavailable) return _unavailableReason;
    if (_isVanilla) return @"不安装任何加载器";
    if (_chosen && _selectedVersion) {
        return [NSString stringWithFormat:@"已选择 %@", _selectedVersion.version];
    }
    switch (_state) {
        case A2LoaderCardStateLoading: return @"正在获取版本…";
        case A2LoaderCardStateFailed:  return @"版本获取失败";
        default:                       return @"点开选择版本";
    }
}

- (void)refreshTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    UIColor *box = t.cPrimaryContainer;
    UIColor *symbol = t.cPrimary;
    if (_isVanilla) {
        box = t.cPrimaryContainer;
        symbol = t.cPrimary;
    } else {
        A2LoaderAccent(_loaderType, t, &box, &symbol);
    }
    _iconBox.backgroundColor = box;

    UIImageSymbolConfiguration *iconCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:kA2LoaderIconPoint
                                                        weight:UIImageSymbolWeightMedium];
    NSString *symbolName = _isVanilla ? @"cube.fill" : A2LoaderSymbol(_loaderType);
    _iconView.image = [UIImage systemImageNamed:symbolName withConfiguration:iconCfg];
    _iconView.tintColor = symbol;

    _loadingLabel.textColor = t.cOnSurfaceVariant;
    _messageLabel.textColor = t.cOnSurfaceVariant;
    [_retryButton setTitleColor:t.cPrimary forState:UIControlStateNormal];
    _spinner.color = t.cOnSurfaceVariant;
    _tableView.separatorColor = t.cOutlineVariant;

    [self refreshHeader];
}

#pragma mark - 属性

- (void)setChosen:(BOOL)chosen {
    _chosen = chosen;
    if (!chosen) _selectedVersion = nil;
    [self refreshHeader];
}

- (void)setUnavailableReason:(NSString *)unavailableReason {
    _unavailableReason = [unavailableReason copy];
    if (_unavailableReason.length > 0) [self collapse];
    [self refreshHeader];
}

#pragma mark - 版本列表

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _versions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    A2LoaderVersionCell *cell = [tableView dequeueReusableCellWithIdentifier:kA2LoaderCellID
                                                                forIndexPath:indexPath];
    A2ModLoaderVersion *v = _versions[indexPath.row];
    BOOL selected = (_selectedVersion != nil &&
                     [_selectedVersion.version isEqualToString:v.version]);
    [cell configureWithVersion:v selected:selected];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= (NSInteger)_versions.count) return;
    A2ModLoaderVersion *v = _versions[indexPath.row];
    _selectedVersion = v;
    _chosen = YES;
    [A2Log log:@"download: 选择加载器 %@ 版本 %@（%@）",
        [A2ModLoaderAPI displayNameForType:_loaderType], v.version, _mcVersion];
    [_tableView reloadData];
    [self setExpanded:NO animated:YES];
    [self notifySelection];
}

@end
