//
//  A2GameVersionListViewController.m
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
//  见头文件：只列清单、不安装；无网/坏清单给可重试的错误卡，不进空页面。
//
//  头部形态参考 ZalithLauncher2 的 SelectGameVersionScreen：类型筛选、搜索、
//  刷新收在同一行，下面压一条全宽分隔线，剩下的高度整块让给列表。
//  之前这里排了三行（筛选 / 搜索+刷新 / 计数），计数行除了占地方没有别的作用，
//  列表被挤矮了一截，所以去掉。
//
//  筛选仍用可多选的胶囊而不是分段控件：清单里四类版本量差别极大
//  （正式版数百条，旧版两档几乎没人看），胶囊能横向滚动又允许同时勾选多档，
//  比分段控件更省地方也更灵活。
//

#import "A2GameVersionListViewController.h"
#import "A2GameInstallOptionsViewController.h"
#import "A2RemoteVersions.h"
#import "A2GlassCard.h"
#import "A2TextField.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2ColorScheme.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import "A2Log.h"

static NSString *const kVersionCellID = @"A2GameVersionCell";

/// 图标方块边长。与 ZL2 的版本配图同尺寸，比正文略大一圈，方便一眼扫到。
static const CGFloat kA2VersionIconBoxSize = 32;

/// 图标方块内符号的点数。
static const CGFloat kA2VersionIconPointSize = 18;

#pragma mark - 类型筛选胶囊

/// 可多选的筛选胶囊。选中态用主色填充 + 白字，未选中用容器底 + 次要文字色。
@interface A2VersionTypeChip : UIControl
/// 清单里的原始 type：release / snapshot / old_beta / old_alpha
@property (nonatomic, copy) NSString *typeKey;
- (instancetype)initWithTitle:(NSString *)title typeKey:(NSString *)typeKey;
- (void)refreshTheme;
@end

@implementation A2VersionTypeChip {
    UILabel *_chipLabel;
}

- (instancetype)initWithTitle:(NSString *)title typeKey:(NSString *)typeKey {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _typeKey = [typeKey copy];
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;

    _chipLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _chipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _chipLabel.text = title;
    _chipLabel.font = [A2Typography caption];
    _chipLabel.userInteractionEnabled = NO;
    [self addSubview:_chipLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_chipLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:A2SpaceS],
        [_chipLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-A2SpaceS],
        [_chipLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceM],
        [_chipLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceM],
    ]];

    [self refreshTheme];
    return self;
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self refreshTheme];
}

- (void)refreshTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    if (self.isSelected) {
        self.backgroundColor = t.cPrimary;
        _chipLabel.textColor = t.cOnPrimary;
    } else {
        self.backgroundColor = t.cSurfaceContainerHighest;
        _chipLabel.textColor = t.cOnSurfaceVariant;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 胶囊：圆角取半高
    self.layer.cornerRadius = CGRectGetHeight(self.bounds) / 2.0;
}

@end

#pragma mark - 版本行单元

/// 类型 → 图标符号。
/// 参考 ZL2「按版本类型给不同配图」的做法，符号本身用本项目自定的。
static NSString *A2VersionSymbolForType(NSString *type) {
    if ([type isEqualToString:@"release"]) return @"cube.fill";
    if ([type isEqualToString:@"snapshot"]) return @"hammer.fill";
    if ([type isEqualToString:@"old_beta"]) return @"archivebox.fill";
    return @"archivebox";
}

/// 版本行：图标方块 + （版本号 + 类型徽标）/ 发布时间 + 右侧箭头。
///
/// 类型语义只由图标方块承载（底色 + 符号），徽标保持中性文字色 ——
/// 一行里放两处彩色会让整列看起来花，反而分不清哪个是重点。
@interface A2GameVersionCell : UITableViewCell
- (void)configureWithVersion:(A2RemoteVersion *)version;
+ (NSString *)displayNameForType:(NSString *)type;
@end

@implementation A2GameVersionCell {
    A2GlassCard *_card;
    UIView *_iconBox;
    UIImageView *_iconView;
    UILabel *_nameLabel;
    UIView *_pill;
    UILabel *_pillLabel;
    UILabel *_timeLabel;
    UIImageView *_chevron;
    NSDateFormatter *_dateFormatter;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _card.cornerRadius = A2RadiusL;
    _card.elevation = A2CardElevationLow;
    _card.contentInsets = UIEdgeInsetsMake(A2SpaceM, A2SpaceM, A2SpaceM, A2SpaceM);
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_card];

    UIView *cv = _card.contentView;

    _iconBox = [[UIView alloc] initWithFrame:CGRectZero];
    _iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBox.layer.cornerRadius = A2RadiusS;
    _iconBox.layer.cornerCurve = kCACornerCurveContinuous;
    _iconBox.clipsToBounds = YES;
    [cv addSubview:_iconBox];

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeCenter;
    [_iconBox addSubview:_iconView];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [A2Typography titleCard];
    _nameLabel.numberOfLines = 1;
    [_nameLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                               forAxis:UILayoutConstraintAxisHorizontal];

    _pill = [[UIView alloc] initWithFrame:CGRectZero];
    _pill.translatesAutoresizingMaskIntoConstraints = NO;
    _pill.layer.cornerRadius = A2RadiusS;
    _pill.layer.cornerCurve = kCACornerCurveContinuous;
    _pill.clipsToBounds = YES;

    _pillLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _pillLabel.font = [A2Typography caption];
    [_pill addSubview:_pillLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_pillLabel.topAnchor constraintEqualToAnchor:_pill.topAnchor constant:A2SpaceXS],
        [_pillLabel.bottomAnchor constraintEqualToAnchor:_pill.bottomAnchor constant:-A2SpaceXS],
        [_pillLabel.leadingAnchor constraintEqualToAnchor:_pill.leadingAnchor constant:A2SpaceS],
        [_pillLabel.trailingAnchor constraintEqualToAnchor:_pill.trailingAnchor constant:-A2SpaceS],
    ]];

    _timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _timeLabel.font = [A2Typography caption];
    _timeLabel.numberOfLines = 1;

    // 版本号与类型徽标同一行，发布时间单独一行。
    UIStackView *titleRow = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel, _pill]];
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.spacing = A2SpaceS;
    titleRow.alignment = UIStackViewAlignmentCenter;

    UIStackView *textColumn = [[UIStackView alloc] initWithArrangedSubviews:@[titleRow, _timeLabel]];
    textColumn.translatesAutoresizingMaskIntoConstraints = NO;
    textColumn.axis = UILayoutConstraintAxisVertical;
    textColumn.spacing = A2SpaceXS;
    textColumn.alignment = UIStackViewAlignmentLeading;
    [cv addSubview:textColumn];

    _chevron = [[UIImageView alloc] initWithFrame:CGRectZero];
    _chevron.translatesAutoresizingMaskIntoConstraints = NO;
    _chevron.contentMode = UIViewContentModeCenter;
    UIImageSymbolConfiguration *chevronCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightMedium];
    _chevron.image = [UIImage systemImageNamed:@"chevron.right" withConfiguration:chevronCfg];
    [cv addSubview:_chevron];

    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:A2PageMargin],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-A2PageMargin],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-A2CardSpacing],

        [_iconBox.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
        [_iconBox.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
        [_iconBox.widthAnchor constraintEqualToConstant:kA2VersionIconBoxSize],
        [_iconBox.heightAnchor constraintEqualToConstant:kA2VersionIconBoxSize],

        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBox.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBox.centerYAnchor],

        [textColumn.leadingAnchor constraintEqualToAnchor:_iconBox.trailingAnchor constant:A2SpaceM],
        [textColumn.topAnchor constraintEqualToAnchor:cv.topAnchor],
        [textColumn.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor],
        [textColumn.trailingAnchor constraintLessThanOrEqualToAnchor:_chevron.leadingAnchor
                                                            constant:-A2SpaceM],

        [_chevron.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
        [_chevron.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
        [_chevron.widthAnchor constraintEqualToConstant:20],
        [_chevron.heightAnchor constraintEqualToConstant:20],
    ]];

    _dateFormatter = [[NSDateFormatter alloc] init];
    _dateFormatter.dateFormat = @"yyyy-MM-dd";

    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // 入场动画会先设 alpha/位移，被复用的单元必须回到静止态，
    // 否则上一轮的中间状态会被带到新的一行上。
    self.alpha = 1;
    self.transform = CGAffineTransformIdentity;
}

- (void)configureWithVersion:(A2RemoteVersion *)version {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    _nameLabel.text = version.versionID;
    _nameLabel.textColor = t.cOnSurface;

    _pillLabel.text = [A2GameVersionCell displayNameForType:version.type];
    _pill.backgroundColor = t.cSurfaceVariant;
    _pillLabel.textColor = t.cOnSurfaceVariant;

    [self applyIconForType:version.type scheme:t];

    // 发布时间缺失时整行收起，不留空行也不出现 "nil"。
    if (version.releaseTime) {
        _timeLabel.text = [_dateFormatter stringFromDate:version.releaseTime];
        _timeLabel.hidden = NO;
    } else {
        _timeLabel.text = @"";
        _timeLabel.hidden = YES;
    }
    _timeLabel.textColor = t.cOnSurfaceVariant;

    _chevron.tintColor = t.cOnSurfaceVariant;
}

/// 类型 → 图标方块底色与符号色：
///   release            → primary 系
///   snapshot           → tertiary 系
///   old_beta/old_alpha → surfaceVariant 系
- (void)applyIconForType:(NSString *)type scheme:(A2ColorScheme *)t {
    UIColor *boxColor;
    UIColor *symbolColor;
    if ([type isEqualToString:@"release"]) {
        boxColor = t.cPrimaryContainer;
        symbolColor = t.cPrimary;
    } else if ([type isEqualToString:@"snapshot"]) {
        boxColor = t.cTertiaryContainer;
        symbolColor = t.cTertiary;
    } else {
        boxColor = t.cSurfaceVariant;
        symbolColor = t.cOnSurfaceVariant;
    }
    _iconBox.backgroundColor = boxColor;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:kA2VersionIconPointSize
                                                        weight:UIImageSymbolWeightMedium];
    _iconView.image = [UIImage systemImageNamed:A2VersionSymbolForType(type) withConfiguration:cfg];
    _iconView.tintColor = symbolColor;
}

+ (NSString *)displayNameForType:(NSString *)type {
    if ([type isEqualToString:@"release"]) return @"正式版";
    if ([type isEqualToString:@"snapshot"]) return @"快照";
    if ([type isEqualToString:@"old_beta"]) return @"旧版 Beta";
    if ([type isEqualToString:@"old_alpha"]) return @"旧版 Alpha";
    return type;
}

@end

#pragma mark - 选版页

@interface A2GameVersionListViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UIView *headerRow;
@property (nonatomic, strong) UIScrollView *chipScroll;
@property (nonatomic, strong) UIStackView *chipStack;
@property (nonatomic, strong) NSMutableDictionary<NSString *, A2VersionTypeChip *> *chipByType;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedTypes;
@property (nonatomic, strong) A2TextField *searchField;
@property (nonatomic, strong) UIButton *refreshButton;
@property (nonatomic, strong) UIView *divider;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@property (nonatomic, strong) A2GlassCard *stateCard;
@property (nonatomic, strong) UILabel *stateTitleLabel;
@property (nonatomic, strong) UILabel *stateDetailLabel;

@property (nonatomic, strong) NSArray<A2RemoteVersion *> *allVersions;
@property (nonatomic, strong, nullable) NSError *loadError;

/// 入场动画只放一次：新拿到清单时打开，用户一开始滚动或改筛选就关掉，
/// 否则每敲一个搜索字、每换一次筛选，整列都在抖。
@property (nonatomic, assign) BOOL entranceEnabled;
@property (nonatomic, strong) NSMutableSet<NSIndexPath *> *entrancePlayed;

@end

@implementation A2GameVersionListViewController

static NSArray<NSString *> *A2VersionTypeOrder(void) {
    return @[@"release", @"snapshot", @"old_beta", @"old_alpha"];
}

- (void)viewDidLoad {
    // 非滚动页：顶部固定筛选 + 下面一个可滚动的列表。
    // 必须在 super 之前设置，基类据此决定内容容器（设晚了 plainContentView 为 nil）。
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = @"安装新版本";

    _chipByType = [NSMutableDictionary dictionary];
    _selectedTypes = [NSMutableSet setWithObject:@"release"];
    _allVersions = @[];
    _entrancePlayed = [NSMutableSet set];

    [self setupHeader];
    [self setupTable];
    [self setupStateCard];
    [self setupThemeObserver];

    [self applyTheme];
    [self fetchManifest];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setupThemeObserver {
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

#pragma mark - 布局

/// 顶部一行：类型胶囊（最多占六成宽，超出横向滚动）+ 搜索框 + 刷新；下面一条全宽分隔线。
- (void)setupHeader {
    UIView *host = self.plainContentView;

    _headerRow = [[UIView alloc] initWithFrame:CGRectZero];
    _headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:_headerRow];

    _chipScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _chipScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _chipScroll.showsHorizontalScrollIndicator = NO;
    _chipScroll.alwaysBounceHorizontal = YES;
    [_headerRow addSubview:_chipScroll];

    _chipStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _chipStack.translatesAutoresizingMaskIntoConstraints = NO;
    _chipStack.axis = UILayoutConstraintAxisHorizontal;
    _chipStack.spacing = A2SpaceS;
    _chipStack.alignment = UIStackViewAlignmentCenter;
    [_chipScroll addSubview:_chipStack];

    for (NSString *type in A2VersionTypeOrder()) {
        NSString *title = [A2GameVersionCell displayNameForType:type];
        A2VersionTypeChip *chip = [[A2VersionTypeChip alloc] initWithTitle:title typeKey:type];
        chip.selected = [_selectedTypes containsObject:type];
        [chip addTarget:self action:@selector(chipTapped:)
       forControlEvents:UIControlEventTouchUpInside];
        _chipByType[type] = chip;
        [_chipStack addArrangedSubview:chip];
    }

    _searchField = [[A2TextField alloc] initWithLabel:@"搜索版本号"];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    __weak typeof(self) weakSelf = self;
    _searchField.onTextChange = ^(NSString *text) {
        [weakSelf searchTextChanged];
    };
    [_headerRow addSubview:_searchField];

    _refreshButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *refreshCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    [_refreshButton setImage:[UIImage systemImageNamed:@"arrow.clockwise" withConfiguration:refreshCfg]
                    forState:UIControlStateNormal];
    _refreshButton.accessibilityLabel = @"刷新";
    [_refreshButton addTarget:self action:@selector(refreshTapped)
             forControlEvents:UIControlEventTouchUpInside];
    [_headerRow addSubview:_refreshButton];

    _divider = [[UIView alloc] initWithFrame:CGRectZero];
    _divider.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:_divider];

    UILayoutGuide *chipContent = _chipScroll.contentLayoutGuide;

    // 胶囊区优先贴合自身内容宽度；放不下时才在六成宽处截断并横向滚动。
    // 优先级降到 999，避免和下面的「不超过六成」硬约束打架。
    NSLayoutConstraint *chipsFitWidth =
        [_chipScroll.widthAnchor constraintEqualToAnchor:_chipStack.widthAnchor];
    chipsFitWidth.priority = 999;

    // 内容宽度超出上限时 999 那条会被硬约束压掉，宽度就只剩「≤ 六成」一个条件，
    // 欠约束时 Auto Layout 可能解出 0 宽。再补一条「撑到上限」的约束兜底。
    NSLayoutConstraint *chipsMaxWidth =
        [_chipScroll.widthAnchor constraintEqualToAnchor:_headerRow.widthAnchor multiplier:0.6];
    chipsMaxWidth.priority = 900;

    [NSLayoutConstraint activateConstraints:@[
        [_headerRow.topAnchor constraintEqualToAnchor:host.topAnchor constant:A2SpaceM],
        [_headerRow.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:A2PageMargin],
        [_headerRow.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-A2PageMargin],

        [_chipScroll.leadingAnchor constraintEqualToAnchor:_headerRow.leadingAnchor],
        [_chipScroll.centerYAnchor constraintEqualToAnchor:_headerRow.centerYAnchor],
        [_chipScroll.heightAnchor constraintEqualToConstant:36],
        [_chipScroll.widthAnchor constraintLessThanOrEqualToAnchor:_headerRow.widthAnchor
                                                        multiplier:0.6],
        chipsFitWidth,
        chipsMaxWidth,

        [_chipStack.topAnchor constraintEqualToAnchor:chipContent.topAnchor],
        [_chipStack.bottomAnchor constraintEqualToAnchor:chipContent.bottomAnchor],
        [_chipStack.leadingAnchor constraintEqualToAnchor:chipContent.leadingAnchor],
        [_chipStack.trailingAnchor constraintEqualToAnchor:chipContent.trailingAnchor],
        [_chipStack.heightAnchor constraintEqualToAnchor:_chipScroll.heightAnchor],

        // 搜索框撑满「胶囊区之后到刷新按钮之前」，同时它的高度决定整行高度。
        [_searchField.topAnchor constraintEqualToAnchor:_headerRow.topAnchor],
        [_searchField.bottomAnchor constraintEqualToAnchor:_headerRow.bottomAnchor],
        [_searchField.leadingAnchor constraintEqualToAnchor:_chipScroll.trailingAnchor
                                                   constant:A2SpaceM],
        [_searchField.trailingAnchor constraintEqualToAnchor:_refreshButton.leadingAnchor
                                                    constant:-A2SpaceS],

        [_refreshButton.centerYAnchor constraintEqualToAnchor:_headerRow.centerYAnchor],
        [_refreshButton.trailingAnchor constraintEqualToAnchor:_headerRow.trailingAnchor],
        [_refreshButton.widthAnchor constraintEqualToConstant:A2MinTouchTarget],
        [_refreshButton.heightAnchor constraintEqualToConstant:A2MinTouchTarget],

        [_divider.topAnchor constraintEqualToAnchor:_headerRow.bottomAnchor constant:A2SpaceM],
        [_divider.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [_divider.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [_divider.heightAnchor constraintEqualToConstant:1],
    ]];
}

- (void)setupTable {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 72;
    _tableView.contentInset = UIEdgeInsetsMake(A2SpaceS, 0, A2SpaceXXL, 0);
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [_tableView registerClass:A2GameVersionCell.class forCellReuseIdentifier:kVersionCellID];
    [self.plainContentView addSubview:_tableView];

    _spinner = [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    [self.plainContentView addSubview:_spinner];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:_divider.bottomAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],

        [_spinner.centerXAnchor constraintEqualToAnchor:_tableView.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:_tableView.centerYAnchor],
    ]];
}

/// 失败/空结果时的提示卡，默认隐藏。
- (void)setupStateCard {
    _stateCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _stateCard.cornerRadius = A2RadiusL;
    _stateCard.elevation = A2CardElevationLow;
    _stateCard.hidden = YES;
    [self.plainContentView addSubview:_stateCard];

    UIView *cv = _stateCard.contentView;

    _stateTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stateTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stateTitleLabel.font = [A2Typography titleCard];
    _stateTitleLabel.textAlignment = NSTextAlignmentCenter;
    _stateTitleLabel.numberOfLines = 0;

    _stateDetailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stateDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stateDetailLabel.font = [A2Typography caption];
    _stateDetailLabel.textAlignment = NSTextAlignmentCenter;
    _stateDetailLabel.numberOfLines = 0;

    A2PrimaryButton *retry = [[A2PrimaryButton alloc] initWithTitle:@"点击重试"
                                                              style:A2ButtonStyleSecondary];
    [retry addTarget:self action:@selector(fetchManifest)
    forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        _stateTitleLabel, _stateDetailLabel, retry,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceM;
    stack.alignment = UIStackViewAlignmentFill;
    [cv addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:cv.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],

        [_stateCard.centerXAnchor constraintEqualToAnchor:self.plainContentView.centerXAnchor],
        [_stateCard.centerYAnchor constraintEqualToAnchor:_tableView.centerYAnchor],
        [_stateCard.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.plainContentView.leadingAnchor
                                                              constant:A2PageMargin],
        [_stateCard.trailingAnchor constraintLessThanOrEqualToAnchor:self.plainContentView.trailingAnchor
                                                           constant:-A2PageMargin],
    ]];
}

#pragma mark - 数据

- (void)fetchManifest {
    [_spinner startAnimating];
    _stateCard.hidden = YES;
    [A2Log log:@"download: 拉取版本清单"];
    __weak typeof(self) weakSelf = self;
    [A2RemoteVersions fetchVersionsWithCompletion:^(NSArray<A2RemoteVersion *> *versions,
                                                    NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self.spinner stopAnimating];
        if (error || versions.count == 0) {
            self.loadError = error;
            self.allVersions = @[];
            [A2Log log:@"download: 版本清单拉取失败：%@",
                error.localizedDescription ?: @"空清单"];
        } else {
            self.loadError = nil;
            self.allVersions = versions;
            // 新清单一律重放一次入场，筛选/搜索造成的重排不重放。
            self.entranceEnabled = YES;
            [self.entrancePlayed removeAllObjects];
            [A2Log log:@"download: 版本清单拉取到 %lu 个版本",
                (unsigned long)versions.count];
        }
        [self refreshList];
    }];
}

- (void)refreshList {
    [self.tableView reloadData];
    [self updateStateCard];
}

/// 类型筛选 + 版本号包含匹配（大小写不敏感），按发布时间倒序、无时间的排最后。
- (NSArray<A2RemoteVersion *> *)visibleVersions {
    NSString *query = _searchField.text.lowercaseString;
    NSMutableArray<A2RemoteVersion *> *out = [NSMutableArray array];
    for (A2RemoteVersion *v in _allVersions) {
        if (![_selectedTypes containsObject:v.type]) continue;
        if (query.length &&
            [v.versionID.lowercaseString rangeOfString:query].location == NSNotFound) {
            continue;
        }
        [out addObject:v];
    }
    [out sortUsingComparator:^NSComparisonResult(A2RemoteVersion *a, A2RemoteVersion *b) {
        NSDate *da = a.releaseTime;
        NSDate *db = b.releaseTime;
        if (da && db) return [db compare:da];
        if (da && !db) return NSOrderedAscending;
        if (!da && db) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return [out copy];
}

- (void)updateStateCard {
    // 有数据或加载中就交给列表展示，不弹提示卡。
    if (self.visibleVersions.count > 0 || _spinner.isAnimating) {
        _stateCard.hidden = YES;
        return;
    }
    _stateCard.hidden = NO;
    if (_loadError) {
        _stateTitleLabel.text = @"获取版本失败";
        _stateDetailLabel.text = _loadError.localizedDescription ?: @"请检查网络后重试";
    } else {
        _stateTitleLabel.text = @"没有符合条件的版本";
        _stateDetailLabel.text = @"请调整筛选类型或搜索关键词";
    }
    [self applyTheme];
}

#pragma mark - 交互

- (void)chipTapped:(A2VersionTypeChip *)chip {
    // 换筛选就是一次重排，不再重放入场动画。
    _entranceEnabled = NO;
    if (chip.isSelected) {
        // 至少保留一个类型，否则列表会空得莫名其妙。
        if (_selectedTypes.count <= 1) {
            [A2Toast show:@"至少保留一个筛选类型" inView:self.view];
            return;
        }
        chip.selected = NO;
        [_selectedTypes removeObject:chip.typeKey];
        [A2Log log:@"download: 取消筛选类型 %@", chip.typeKey];
    } else {
        chip.selected = YES;
        [_selectedTypes addObject:chip.typeKey];
        [A2Log log:@"download: 增加筛选类型 %@", chip.typeKey];
    }
    [self refreshList];
}

- (void)searchTextChanged {
    _entranceEnabled = NO;
    [self refreshList];
}

- (void)refreshTapped {
    [A2Log log:@"download: 手动刷新版本清单"];
    [self fetchManifest];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleVersions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    A2GameVersionCell *cell =
        [tableView dequeueReusableCellWithIdentifier:kVersionCellID forIndexPath:indexPath];
    A2RemoteVersion *v = self.visibleVersions[indexPath.row];
    [cell configureWithVersion:v];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
        forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!_entranceEnabled || [_entrancePlayed containsObject:indexPath]) return;
    [_entrancePlayed addObject:indexPath];

    cell.alpha = 0;
    cell.transform = CGAffineTransformMakeTranslation(0, A2SpaceS);
    // 延迟按行号错开，但封顶：滚动到很靠后的行时不该等半秒才出现。
    NSUInteger maxStaggeredRows = 8;
    NSUInteger staggerIndex = MIN((NSUInteger)indexPath.row, maxStaggeredRows);
    NSTimeInterval delay = A2CardStaggerDelay * (NSTimeInterval)staggerIndex;
    [UIView animateWithDuration:A2AnimDurationCard
                          delay:delay
         usingSpringWithDamping:A2SpringDamping
          initialSpringVelocity:A2SpringVelocity
                        options:UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        cell.alpha = 1;
        cell.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    // 用户开始滚动了，后面新进屏的行不必再补入场动画。
    _entranceEnabled = NO;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    A2RemoteVersion *v = self.visibleVersions[indexPath.row];
    [A2Log log:@"download: 选中版本 %@（%@）", v.versionID, v.type];
    A2GameInstallOptionsViewController *vc =
        [[A2GameInstallOptionsViewController alloc] initWithVersionID:v.versionID];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 主题

- (void)applyTheme {
    [super applyTheme];
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    _spinner.color = t.cPrimary;
    _divider.backgroundColor = t.cOutlineVariant;
    _stateTitleLabel.textColor = t.cOnSurface;
    _stateDetailLabel.textColor = t.cOnSurfaceVariant;

    _refreshButton.tintColor = t.cPrimary;

    for (A2VersionTypeChip *chip in _chipByType.allValues) {
        [chip refreshTheme];
    }
    [_searchField applyTheme];
    // 行内颜色写在 configureWithVersion: 里，重载一次让主题切换落到每张卡片上。
    [self.tableView reloadData];
}

@end
