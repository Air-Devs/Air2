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
//  为什么用可多选的胶囊筛选而不是 UISegmentedControl：
//  清单里四类版本量差别极大（正式版数百条，旧版两个档位几乎没人看），
//  胶囊能横向滚动又允许同时勾选多档，比分段更省地方也更灵活。
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

/// 版本列表单元：圆角卡片包住 版本号 + 类型徽标（左）与发布时间（右）。
@interface A2GameVersionCell : UITableViewCell
- (void)configureWithVersion:(A2RemoteVersion *)version;
+ (NSString *)displayNameForType:(NSString *)type;
@end

@implementation A2GameVersionCell {
    A2GlassCard *_card;
    UILabel *_nameLabel;
    UIView *_pill;
    UILabel *_pillLabel;
    UILabel *_timeLabel;
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
    _card.contentInsets = UIEdgeInsetsMake(A2SpaceM, A2SpaceL, A2SpaceM, A2SpaceL);
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_card];

    UIView *cv = _card.contentView;

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [A2Typography titleCard];
    _nameLabel.numberOfLines = 1;
    [cv addSubview:_nameLabel];

    _pill = [[UIView alloc] initWithFrame:CGRectZero];
    _pill.translatesAutoresizingMaskIntoConstraints = NO;
    _pill.layer.cornerRadius = A2RadiusS;
    _pill.layer.cornerCurve = kCACornerCurveContinuous;
    _pill.clipsToBounds = YES;
    [cv addSubview:_pill];

    _pillLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _pillLabel.font = [A2Typography caption];
    [_pill addSubview:_pillLabel];

    _timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _timeLabel.font = [A2Typography caption];
    _timeLabel.numberOfLines = 1;
    _timeLabel.textAlignment = NSTextAlignmentRight;
    [_timeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                               forAxis:UILayoutConstraintAxisHorizontal];
    [cv addSubview:_timeLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:A2PageMargin],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-A2PageMargin],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-A2CardSpacing],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
        [_nameLabel.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],

        [_pill.leadingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor constant:A2SpaceS],
        [_pill.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],

        [_pillLabel.topAnchor constraintEqualToAnchor:_pill.topAnchor constant:2],
        [_pillLabel.bottomAnchor constraintEqualToAnchor:_pill.bottomAnchor constant:-2],
        [_pillLabel.leadingAnchor constraintEqualToAnchor:_pill.leadingAnchor constant:A2SpaceS],
        [_pillLabel.trailingAnchor constraintEqualToAnchor:_pill.trailingAnchor constant:-A2SpaceS],

        [_timeLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_pill.trailingAnchor
                                                              constant:A2SpaceS],
        [_timeLabel.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
        [_timeLabel.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
    ]];

    _dateFormatter = [[NSDateFormatter alloc] init];
    _dateFormatter.dateFormat = @"yyyy-MM-dd";

    return self;
}

- (void)configureWithVersion:(A2RemoteVersion *)version {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _nameLabel.text = version.versionID;
    _nameLabel.textColor = t.cOnSurface;

    [self applyPillForType:version.type scheme:t];

    // 发布时间缺失时整段留空，避免"nil"字符串或错位。
    if (version.releaseTime) {
        _timeLabel.text = [_dateFormatter stringFromDate:version.releaseTime];
    } else {
        _timeLabel.text = @"";
    }
    _timeLabel.textColor = t.cOnSurfaceVariant;
}

/// 类型徽标配色：
///   release            → primary 系
///   snapshot           → tertiary 系
///   old_beta/old_alpha → surfaceVariant 系
- (void)applyPillForType:(NSString *)type scheme:(A2ColorScheme *)t {
    _pillLabel.text = [A2GameVersionCell displayNameForType:type];
    if ([type isEqualToString:@"release"]) {
        _pill.backgroundColor = t.cPrimaryContainer;
        _pillLabel.textColor = t.cPrimary;
    } else if ([type isEqualToString:@"snapshot"]) {
        _pill.backgroundColor = t.cTertiaryContainer;
        _pillLabel.textColor = t.cTertiary;
    } else {
        _pill.backgroundColor = t.cSurfaceVariant;
        _pillLabel.textColor = t.cOnSurfaceVariant;
    }
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

@property (nonatomic, strong) UIScrollView *chipScroll;
@property (nonatomic, strong) UIStackView *chipStack;
@property (nonatomic, strong) NSMutableDictionary<NSString *, A2VersionTypeChip *> *chipByType;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedTypes;
@property (nonatomic, strong) A2TextField *searchField;
@property (nonatomic, strong) UIButton *refreshButton;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@property (nonatomic, strong) A2GlassCard *stateCard;
@property (nonatomic, strong) UILabel *stateTitleLabel;
@property (nonatomic, strong) UILabel *stateDetailLabel;

@property (nonatomic, strong) NSArray<A2RemoteVersion *> *allVersions;
@property (nonatomic, strong, nullable) NSError *loadError;

@end

@implementation A2GameVersionListViewController

/// 胶囊顺序即展示顺序，也是计数文案里的拼接顺序。
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

    [self setupFilterArea];
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

- (void)setupFilterArea {
    UIView *host = self.plainContentView;

    _chipScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _chipScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _chipScroll.showsHorizontalScrollIndicator = NO;
    _chipScroll.alwaysBounceHorizontal = YES;
    [host addSubview:_chipScroll];

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
    _searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    __weak typeof(self) weakSelf = self;
    _searchField.onTextChange = ^(NSString *text) {
        [weakSelf refreshList];
    };
    [host addSubview:_searchField];

    _refreshButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_refreshButton setTitle:@"刷新" forState:UIControlStateNormal];
    [_refreshButton addTarget:self action:@selector(fetchManifest)
             forControlEvents:UIControlEventTouchUpInside];
    [host addSubview:_refreshButton];

    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [A2Typography caption];
    _countLabel.numberOfLines = 1;
    [host addSubview:_countLabel];

    UILayoutGuide *chipContent = _chipScroll.contentLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_chipScroll.topAnchor constraintEqualToAnchor:host.topAnchor constant:A2SpaceS],
        [_chipScroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:A2PageMargin],
        [_chipScroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-A2PageMargin],
        [_chipScroll.heightAnchor constraintEqualToConstant:36],

        [_chipStack.topAnchor constraintEqualToAnchor:chipContent.topAnchor],
        [_chipStack.bottomAnchor constraintEqualToAnchor:chipContent.bottomAnchor],
        [_chipStack.leadingAnchor constraintEqualToAnchor:chipContent.leadingAnchor],
        [_chipStack.trailingAnchor constraintEqualToAnchor:chipContent.trailingAnchor],
        [_chipStack.heightAnchor constraintEqualToAnchor:_chipScroll.heightAnchor],

        [_searchField.topAnchor constraintEqualToAnchor:_chipScroll.bottomAnchor constant:A2SpaceM],
        [_searchField.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:A2PageMargin],
        [_searchField.trailingAnchor constraintEqualToAnchor:_refreshButton.leadingAnchor
                                                    constant:-A2SpaceS],

        [_refreshButton.centerYAnchor constraintEqualToAnchor:_searchField.centerYAnchor],
        [_refreshButton.trailingAnchor constraintEqualToAnchor:host.trailingAnchor
                                                      constant:-A2PageMargin],
        [_refreshButton.widthAnchor constraintGreaterThanOrEqualToConstant:56],
        [_refreshButton.heightAnchor constraintEqualToConstant:A2MinTouchTarget],

        [_countLabel.topAnchor constraintEqualToAnchor:_searchField.bottomAnchor constant:A2SpaceS],
        [_countLabel.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:A2PageMargin],
        [_countLabel.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-A2PageMargin],
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
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, A2SpaceXXL, 0);
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [_tableView registerClass:A2GameVersionCell.class forCellReuseIdentifier:kVersionCellID];
    [self.plainContentView addSubview:_tableView];

    _spinner = [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    [self.plainContentView addSubview:_spinner];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:_countLabel.bottomAnchor constant:A2SpaceS],
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
            [A2Log log:@"download: 版本清单拉取到 %lu 个版本",
                (unsigned long)versions.count];
        }
        [self refreshList];
    }];
}

- (void)refreshList {
    [self.tableView reloadData];
    [self updateCountLabel];
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

- (void)updateCountLabel {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *type in A2VersionTypeOrder()) {
        if ([_selectedTypes containsObject:type]) {
            [names addObject:[A2GameVersionCell displayNameForType:type]];
        }
    }
    _countLabel.text = [NSString stringWithFormat:@"%@ · %lu 个版本",
                        [names componentsJoinedByString:@"、"],
                        (unsigned long)self.visibleVersions.count];
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

    _countLabel.textColor = t.cOnSurfaceVariant;
    _spinner.color = t.cPrimary;
    _stateTitleLabel.textColor = t.cOnSurface;
    _stateDetailLabel.textColor = t.cOnSurfaceVariant;

    [_refreshButton setTitleColor:t.cPrimary forState:UIControlStateNormal];
    _refreshButton.titleLabel.font = [A2Typography button];

    for (A2VersionTypeChip *chip in _chipByType.allValues) {
        [chip refreshTheme];
    }
    [self.tableView reloadData];
}

@end
