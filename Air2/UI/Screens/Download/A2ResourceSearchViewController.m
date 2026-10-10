//
//  A2ResourceSearchViewController.m
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
//  共用资源搜索页 —— 搜索栏 + 可展开筛选卡 + 分页结果列表。
//
//  设计取舍：
//    · 筛选用一张可展开的卡片承载，收起时只留一行摘要（平台 · 排序 · 筛选数），
//      展开后四组筛选（平台 / 分类 / 加载器 / 游戏版本 / 排序）同时可用、可叠加，
//      其中加载器与游戏版本是【两个独立维度】，同时生效而非二选一。
//    · 平台切换时分类标识两家不通用，所以切换平台会清空已选分类并重新拉取。
//    · 平台只列【支持本资源大类】的项（Modrinth 不提供存档），
//      切到 CurseForge 但没配 Key 会走 Key 弹框，取消则回退原平台，不留坏状态。
//    · 空态 / 加载中 / 请求失败 / 平台不支持，四态各走独立文案，不共用一个「加载失败」。
//

#import "A2ResourceSearchViewController.h"
#import "A2ContentSource.h"
#import "A2CurseForgeAPI.h"
#import "A2CurseForgeKeyPrompt.h"
#import "A2DownloadFavorites.h"
#import "A2DownloadManifest.h"
#import "A2FilterChip.h"
#import "A2GlassCard.h"
#import "A2Log.h"
#import "A2Metrics.h"
#import "A2ModLoaderAPI.h"
#import "A2RemoteImageView.h"
#import "A2RemoteVersions.h"
#import "A2ResourceDetailViewController.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"

static NSString *const kResultCellID = @"A2ResourceResultCell";

/// 下载量易读格式
static NSString *A2RSFormatCount(long long count) {
    if (count >= 1000000) return [NSString stringWithFormat:@"%.1fM", count / 1000000.0];
    if (count >= 1000) return [NSString stringWithFormat:@"%.1fK", count / 1000.0];
    return [NSString stringWithFormat:@"%lld", count];
}

/// 结果区状态 —— 各自独立文案
typedef NS_ENUM(NSInteger, A2ResourceSearchState) {
    A2ResourceSearchStateLoading = 0,
    A2ResourceSearchStateEmpty,
    A2ResourceSearchStateError,
    A2ResourceSearchStateUnsupported,
};

#pragma mark - 结果行

@interface A2ResourceResultCell : UITableViewCell
@property (nonatomic, strong) A2GlassCard *card;
@property (nonatomic, strong) A2RemoteImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *authorLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UILabel *installedBadge;
@property (nonatomic, strong) UIImageView *starView;
@property (nonatomic, assign) BOOL favorite;
- (void)configureWithItem:(A2ContentItem *)item;
@end

@implementation A2ResourceResultCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.cornerRadius = A2RadiusL;
    _card.elevation = A2CardElevationLow;
    _card.contentInsets = UIEdgeInsetsMake(A2SpaceM, A2SpaceM, A2SpaceM, A2SpaceM);
    [self.contentView addSubview:_card];

    _iconView = [[A2RemoteImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.cornerRadius = A2RadiusM;
    _iconView.contentMode = UIViewContentModeScaleAspectFill;
    _iconView.clipsToBounds = YES;

    _starView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _starView.translatesAutoresizingMaskIntoConstraints = NO;
    _starView.contentMode = UIViewContentModeCenter;

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [A2Typography titleCard];
    _titleLabel.numberOfLines = 1;

    _authorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _authorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _authorLabel.font = [A2Typography caption];
    _authorLabel.numberOfLines = 1;

    _summaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _summaryLabel.font = [A2Typography subtitleCard];
    _summaryLabel.numberOfLines = 2;

    _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metaLabel.font = [A2Typography caption];
    _metaLabel.numberOfLines = 1;
    [_metaLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                forAxis:UILayoutConstraintAxisHorizontal];

    _installedBadge = [[UILabel alloc] initWithFrame:CGRectZero];
    _installedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _installedBadge.font = [A2Typography caption];
    _installedBadge.text = @"已安装";
    _installedBadge.textAlignment = NSTextAlignmentCenter;
    _installedBadge.layer.cornerRadius = 9;
    _installedBadge.layer.cornerCurve = kCACornerCurveContinuous;
    _installedBadge.clipsToBounds = YES;
    _installedBadge.hidden = YES;

    UIStackView *metaRow = [[UIStackView alloc] initWithArrangedSubviews:
                            @[_installedBadge, _metaLabel]];
    metaRow.translatesAutoresizingMaskIntoConstraints = NO;
    metaRow.axis = UILayoutConstraintAxisHorizontal;
    metaRow.spacing = A2SpaceS;
    metaRow.alignment = UIStackViewAlignmentCenter;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:
                              @[_titleLabel, _authorLabel, _summaryLabel, metaRow]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 3;

    [_card.contentView addSubview:_iconView];
    [_card.contentView addSubview:_starView];
    [_card.contentView addSubview:textStack];

    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:3],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3],
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],

        [_iconView.leadingAnchor constraintEqualToAnchor:_card.contentView.leadingAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_card.contentView.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:56],
        [_iconView.heightAnchor constraintEqualToConstant:56],

        [_starView.trailingAnchor constraintEqualToAnchor:_card.contentView.trailingAnchor],
        [_starView.topAnchor constraintEqualToAnchor:_card.contentView.topAnchor],
        [_starView.widthAnchor constraintEqualToConstant:20],
        [_starView.heightAnchor constraintEqualToConstant:20],

        [_installedBadge.heightAnchor constraintEqualToConstant:18],
        [_installedBadge.widthAnchor constraintGreaterThanOrEqualToConstant:44],

        [textStack.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:A2SpaceM],
        [textStack.trailingAnchor constraintEqualToAnchor:_card.contentView.trailingAnchor],
        [textStack.topAnchor constraintGreaterThanOrEqualToAnchor:_card.contentView.topAnchor],
        [textStack.bottomAnchor constraintLessThanOrEqualToAnchor:_card.contentView.bottomAnchor],
        [textStack.centerYAnchor constraintEqualToAnchor:_card.contentView.centerYAnchor],
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

- (void)prepareForReuse {
    [super prepareForReuse];
    [_iconView cancelLoading];
    _iconView.image = nil;
}

- (void)configureWithItem:(A2ContentItem *)item {
    _titleLabel.text = item.title.length ? item.title : item.projectID;
    _authorLabel.text = item.author.length ? [@"by " stringByAppendingString:item.author] : @"";
    _summaryLabel.text = item.summary.length ? item.summary : @"暂无简介";

    // 简介旁的元信息：分类取前 1~2 个 + 下载量
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *category in item.categories) {
        if (parts.count >= 2) break;
        [parts addObject:[category capitalizedString]];
    }
    NSString *downloads = [A2RSFormatCount(item.downloadCount) stringByAppendingString:@" 次下载"];
    NSString *cats = [parts componentsJoinedByString:@" · "];
    _metaLabel.text = cats.length ? [cats stringByAppendingFormat:@"  ·  %@", downloads] : downloads;

    // 已安装角标
    _installedBadge.hidden = ![A2DownloadManifest.shared isProjectInstalled:item.projectID];

    // 收藏星标：实心 = 已收藏
    _favorite = [A2DownloadFavorites.shared isFavorite:item.projectID];
    _starView.image = [UIImage systemImageNamed:(_favorite ? @"star.fill" : @"star")];

    // 图标：复用前先取消上一次请求，避免回调落到新内容上
    [_iconView cancelLoading];
    [_iconView setImageURL:item.iconURL placeholder:nil];

    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _titleLabel.textColor = t.cOnSurface;
    _authorLabel.textColor = t.cOnSurfaceVariant;
    _summaryLabel.textColor = t.cOnSurfaceVariant;
    _metaLabel.textColor = [t.cOnSurfaceVariant colorWithAlphaComponent:0.8];
    _installedBadge.textColor = t.cPrimary;
    _installedBadge.backgroundColor = [t.cPrimary colorWithAlphaComponent:0.15];
    _starView.tintColor = _favorite ? t.cPrimary : t.cOnSurfaceVariant;
}

@end

#pragma mark - 搜索页

@interface A2ResourceSearchViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>

@property (nonatomic, assign) A2ContentClass contentClass;

// 搜索栏
@property (nonatomic, strong) UISearchBar *searchBar;

// 可展开筛选卡
@property (nonatomic, strong) A2GlassCard *filterCard;
@property (nonatomic, strong) UILabel *filterSummaryLabel;
@property (nonatomic, strong) UIImageView *filterChevron;
@property (nonatomic, strong) UIStackView *filterBody;
@property (nonatomic, assign) BOOL filterExpanded;
@property (nonatomic, strong) NSMutableArray<UILabel *> *sectionLabels;

@property (nonatomic, strong) UISegmentedControl *platformControl;
@property (nonatomic, copy) NSArray<NSNumber *> *platformOptions;

@property (nonatomic, strong) UIStackView *categoryChipsStack;
@property (nonatomic, strong) UIStackView *loaderChipsStack;
@property (nonatomic, strong) UIStackView *versionChipsStack;
@property (nonatomic, strong) UIStackView *sortChipsStack;
@property (nonatomic, strong) UIButton *resetButton;

// 结果区
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UITableView *tableView;

// 数据
@property (nonatomic, strong) A2ContentSource *source;
@property (nonatomic, assign) A2ContentPlatform platform;
@property (nonatomic, strong) NSMutableArray<A2ContentItem *> *items;
@property (nonatomic, assign) NSInteger offset;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL reachedEnd;
@property (nonatomic, strong, nullable) NSError *lastError;

@property (nonatomic, copy) NSArray<NSString *> *gameVersionOptions;
@property (nonatomic, copy, nullable) NSString *selectedLoader;
@property (nonatomic, copy, nullable) NSString *selectedGameVersion;
@property (nonatomic, assign) A2ContentSortField sortField;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedCategories;

@end

@implementation A2ResourceSearchViewController

- (instancetype)initWithContentClass:(A2ContentClass)contentClass {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _contentClass = contentClass;
    return self;
}

- (void)viewDidLoad {
    self.usesScrollContent = NO;
    [super viewDidLoad];

    self.pageTitle = [NSString stringWithFormat:@"搜索%@", A2ClassDisplayName(self.contentClass)];

    _items = [NSMutableArray array];
    _selectedCategories = [NSMutableSet set];
    _gameVersionOptions = @[];
    _sectionLabels = [NSMutableArray array];
    _sortField = A2ContentSortFieldRelevance;

    // 平台默认取记住的那个；若它不支持本资源大类（如存档 + Modrinth）则退回首个支持的平台。
    _platform = [self initialPlatform];
    _source = [A2ContentSource sourceForPlatform:_platform];

    [self setupSearchBar];
    [self setupFilterCard];
    [self buildLoaderChips];
    [self buildSortChips];
    [self renderPlaceholderInStack:_versionChipsStack text:@"版本加载中…"];
    [self setupResultList];
    [self applyTheme];

    [self loadCategories];
    [self loadGameVersions];
    [self reload];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleFavoritesChanged:)
                                              name:A2FavoritesDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 平台

/// 支持本资源大类的平台列表（Modrinth 不提供存档）。
- (NSArray<NSNumber *> *)supportedPlatforms {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    for (NSNumber *n in @[@(A2ContentPlatformModrinth), @(A2ContentPlatformCurseForge)]) {
        A2ContentPlatform platform = (A2ContentPlatform)n.integerValue;
        if ([[A2ContentSource sourceForPlatform:platform] supportsContentClass:self.contentClass]) {
            [out addObject:n];
        }
    }
    return out;
}

- (A2ContentPlatform)initialPlatform {
    A2ContentPlatform preferred = [A2ContentSource preferredPlatform];
    if ([[A2ContentSource sourceForPlatform:preferred] supportsContentClass:self.contentClass]) {
        return preferred;
    }
    // 记住的平台不支持本资源大类（如存档 + Modrinth）时，退回首个支持的平台
    NSArray<NSNumber *> *options = [self supportedPlatforms];
    if (options.count > 0) {
        NSNumber *n = options.firstObject;
        return (A2ContentPlatform)n.integerValue;
    }
    return preferred;
}

- (NSInteger)indexForPlatform:(A2ContentPlatform)platform {
    for (NSInteger i = 0; i < _platformOptions.count; i++) {
        NSNumber *n = _platformOptions[i];
        if (n.integerValue == (NSInteger)platform) return i;
    }
    return 0;
}

- (void)selectPlatformControlForPlatform:(A2ContentPlatform)platform {
    NSInteger idx = [self indexForPlatform:platform];
    if (idx >= 0 && idx < (NSInteger)_platformControl.numberOfSegments) {
        _platformControl.selectedSegmentIndex = idx;
    }
}

- (void)platformControlChanged {
    NSInteger idx = _platformControl.selectedSegmentIndex;
    if (idx < 0 || idx >= (NSInteger)_platformOptions.count) return;
    NSNumber *pickedNumber = _platformOptions[idx];
    A2ContentPlatform picked = (A2ContentPlatform)pickedNumber.integerValue;
    A2ContentPlatform previous = self.platform;
    if (picked == previous) return;

    // 切 CurseForge 但没 Key：弹框要 Key，取消则回退原平台，不留不可用态。
    if (picked == A2ContentPlatformCurseForge && ![A2CurseForgeAPI hasAPIKey]) {
        __weak typeof(self) weakSelf = self;
        [A2CurseForgeKeyPrompt promptFrom:self completion:^(BOOL saved) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (saved) {
                [self applyPlatform:A2ContentPlatformCurseForge remember:YES];
            } else {
                [self selectPlatformControlForPlatform:previous];
            }
        }];
        return;
    }
    [self applyPlatform:picked remember:YES];
}

/// 平台切换的实际生效：记忆选择 + 重建分类 + 重载结果。
- (void)applyPlatform:(A2ContentPlatform)platform remember:(BOOL)remember {
    self.platform = platform;
    self.source = [A2ContentSource sourceForPlatform:platform];
    if (remember) [A2ContentSource setPreferredPlatform:platform];
    [self selectPlatformControlForPlatform:platform];
    [self updateFilterSummary];
    [A2Log log:@"resource-search: 平台切换 class=%ld → %@",
          (long)self.contentClass, self.source.displayName];

    // 分类标识两家不通用，切换平台后清空已选分类并重新拉取
    [self loadCategories];
    [self reload];
}

#pragma mark - UI：搜索栏

- (void)setupSearchBar {
    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    _searchBar.placeholder = @"搜索资源…";
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.tintColor = A2ThemeManager.shared.scheme.cPrimary;
    _searchBar.backgroundImage = [UIImage new];
    _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchBar.autocorrectionType = UITextAutocorrectionTypeNo;

    // 搜索框文字配色（UISearchBar 不跟随我们的色板，需手动设）
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    for (UIView *v in _searchBar.subviews) {
        for (UIView *sv in v.subviews) {
            if ([sv isKindOfClass:UITextField.class]) {
                UITextField *tf = (UITextField *)sv;
                tf.textColor = t.cOnSurface;
                tf.attributedPlaceholder =
                    [[NSAttributedString alloc] initWithString:@"搜索资源…"
                                                    attributes:@{NSForegroundColorAttributeName:
                                                                     t.cOnSurfaceVariant}];
            }
        }
    }
    [self.plainContentView addSubview:_searchBar];
}

#pragma mark - UI：可展开筛选卡

- (void)setupFilterCard {
    self.platformOptions = [self supportedPlatforms];

    _filterCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _filterCard.translatesAutoresizingMaskIntoConstraints = NO;
    _filterCard.cornerRadius = A2RadiusL;
    _filterCard.elevation = A2CardElevationLow;
    _filterCard.contentInsets = UIEdgeInsetsMake(A2CardPadding, A2CardPadding, A2CardPadding, A2CardPadding);

    // —— 卡头：一行摘要 + 展开箭头，点这里展开 / 收起 ——
    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.userInteractionEnabled = YES;
    [header addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(toggleFilterExpanded)]];

    _filterSummaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _filterSummaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _filterSummaryLabel.font = [A2Typography caption];
    _filterSummaryLabel.numberOfLines = 1;

    _filterChevron = [[UIImageView alloc] initWithFrame:CGRectZero];
    _filterChevron.translatesAutoresizingMaskIntoConstraints = NO;
    _filterChevron.contentMode = UIViewContentModeCenter;
    _filterChevron.image = [UIImage systemImageNamed:@"chevron.down"];

    [header addSubview:_filterSummaryLabel];
    [header addSubview:_filterChevron];

    // —— 卡体：五组筛选 + 重置 ——
    _filterBody = [[UIStackView alloc] initWithFrame:CGRectZero];
    _filterBody.axis = UILayoutConstraintAxisVertical;
    _filterBody.spacing = A2SpaceM;
    _filterBody.hidden = YES;
    [self buildFilterGroups];

    UIStackView *root = [[UIStackView alloc] initWithArrangedSubviews:@[header, _filterBody]];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = A2SpaceM;
    [_filterCard.contentView addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [header.heightAnchor constraintGreaterThanOrEqualToConstant:24],
        [_filterSummaryLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [_filterSummaryLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_filterSummaryLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_filterChevron.leadingAnchor
                                                                    constant:-A2SpaceS],
        [_filterChevron.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [_filterChevron.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_filterChevron.widthAnchor constraintEqualToConstant:18],
        [_filterChevron.heightAnchor constraintEqualToConstant:18],

        [root.topAnchor constraintEqualToAnchor:_filterCard.contentView.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:_filterCard.contentView.bottomAnchor],
        [root.leadingAnchor constraintEqualToAnchor:_filterCard.contentView.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:_filterCard.contentView.trailingAnchor],
    ]];

    self.filterExpanded = NO;
    [self updateFilterSummary];
    [self.plainContentView addSubview:_filterCard];
}

- (void)buildFilterGroups {
    _platformControl = [self makePlatformControl];
    [_filterBody addArrangedSubview:[self groupTitled:@"平台" content:_platformControl]];

    _categoryChipsStack = [self horizontalChipStack];
    [_filterBody addArrangedSubview:
        [self groupTitled:@"资源分类" content:[self scrollRowWithStack:_categoryChipsStack]]];

    _loaderChipsStack = [self horizontalChipStack];
    [_filterBody addArrangedSubview:
        [self groupTitled:@"加载器" content:[self scrollRowWithStack:_loaderChipsStack]]];

    _versionChipsStack = [self horizontalChipStack];
    [_filterBody addArrangedSubview:
        [self groupTitled:@"游戏版本" content:[self scrollRowWithStack:_versionChipsStack]]];

    _sortChipsStack = [self horizontalChipStack];
    [_filterBody addArrangedSubview:
        [self groupTitled:@"排序" content:[self scrollRowWithStack:_sortChipsStack]]];

    _resetButton = [self makeResetButton];
    [_filterBody addArrangedSubview:_resetButton];
}

- (UISegmentedControl *)makePlatformControl {
    UISegmentedControl *control = [[UISegmentedControl alloc] initWithFrame:CGRectZero];
    control.translatesAutoresizingMaskIntoConstraints = NO;
    NSInteger index = 0;
    for (NSNumber *n in _platformOptions) {
        A2ContentPlatform platform = (A2ContentPlatform)n.integerValue;
        [control insertSegmentWithTitle:[A2ContentSource sourceForPlatform:platform].displayName
                                atIndex:index animated:NO];
        index++;
    }
    control.selectedSegmentIndex = [self indexForPlatform:self.platform];
    [control addTarget:self
                action:@selector(platformControlChanged)
      forControlEvents:UIControlEventValueChanged];
    [control.heightAnchor constraintEqualToConstant:32].active = YES;
    return control;
}

/// 一组筛选 = 小标题 + 内容
- (UIView *)groupTitled:(NSString *)title content:(UIView *)content {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [A2Typography caption];
    label.text = title;
    [self.sectionLabels addObject:label];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, content]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    return stack;
}

- (UIStackView *)horizontalChipStack {
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = A2SpaceS;
    stack.alignment = UIStackViewAlignmentCenter;
    return stack;
}

/// 把胶囊横向排进一个可横滑的行
- (UIScrollView *)scrollRowWithStack:(UIStackView *)stack {
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [stack.heightAnchor constraintEqualToAnchor:scroll.heightAnchor],
        [scroll.heightAnchor constraintEqualToConstant:32],
    ]];
    return scroll;
}

- (UIButton *)makeResetButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:@"重置筛选" forState:UIControlStateNormal];
    button.titleLabel.font = [A2Typography button];
    button.layer.cornerRadius = A2RadiusS;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.borderWidth = 1;
    [button addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:38].active = YES;
    return button;
}

- (void)toggleFilterExpanded {
    self.filterExpanded = !self.filterExpanded;
    _filterChevron.image = [UIImage systemImageNamed:(self.filterExpanded ? @"chevron.up" : @"chevron.down")];
    [UIView animateWithDuration:A2AnimDurationFast animations:^{
        self.filterBody.hidden = !self.filterExpanded;
        [self.view layoutIfNeeded];
    }];
    [A2Log log:@"resource-search: 筛选卡%@", self.filterExpanded ? @"展开" : @"收起"];
}

#pragma mark - 筛选：平台 / 加载器 / 游戏版本 / 分类 / 排序

- (A2FilterChip *)makeSingleChip:(NSString *)title
                           value:(NSString *)value
                        selected:(BOOL)selected
                          action:(SEL)action {
    A2FilterChip *chip = [A2FilterChip chip];
    chip.filterValue = value;
    [chip setTitle:title forState:UIControlStateNormal];
    chip.selected = selected;
    [chip addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return chip;
}

- (void)clearStack:(UIStackView *)stack {
    for (UIView *v in [stack.arrangedSubviews copy]) {
        [stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
}

- (void)renderPlaceholderInStack:(UIStackView *)stack text:(NSString *)text {
    [self clearStack:stack];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [A2Typography caption];
    label.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    label.text = text;
    [stack addArrangedSubview:label];
}

- (void)styleSingleSelectStack:(UIStackView *)stack value:(NSString *)value {
    for (UIView *v in stack.arrangedSubviews) {
        if (![v isKindOfClass:A2FilterChip.class]) continue;
        A2FilterChip *chip = (A2FilterChip *)v;
        chip.selected = [chip.filterValue isEqualToString:value];
    }
}

/// 分类是多选，重置时把全部胶囊置为未选
- (void)clearCategoryChipSelection {
    for (UIView *v in _categoryChipsStack.arrangedSubviews) {
        if (![v isKindOfClass:A2FilterChip.class]) continue;
        A2FilterChip *chip = (A2FilterChip *)v;
        chip.selected = NO;
    }
}

- (void)buildLoaderChips {
    [self clearStack:_loaderChipsStack];
    [_loaderChipsStack addArrangedSubview:[self makeSingleChip:@"全部"
                                                         value:@""
                                                      selected:(self.selectedLoader == nil)
                                                        action:@selector(loaderChipTapped:)]];
    for (NSNumber *n in [A2ModLoaderAPI allLoaderTypes]) {
        A2ModLoaderType type = (A2ModLoaderType)n.integerValue;
        NSString *identifier = [A2ModLoaderAPI identifierForType:type];
        A2FilterChip *chip = [self makeSingleChip:[A2ModLoaderAPI displayNameForType:type]
                                            value:identifier
                                         selected:[identifier isEqualToString:self.selectedLoader ?: @""]
                                           action:@selector(loaderChipTapped:)];
        [_loaderChipsStack addArrangedSubview:chip];
    }
}

- (void)buildSortChips {
    [self clearStack:_sortChipsStack];
    for (NSNumber *n in A2AllSortFields()) {
        A2ContentSortField field = (A2ContentSortField)n.integerValue;
        A2FilterChip *chip = [A2FilterChip chip];
        chip.translatesAutoresizingMaskIntoConstraints = NO;
        chip.filterValue = [NSString stringWithFormat:@"%ld", (long)field];
        [chip setTitle:A2SortDisplayName(field) forState:UIControlStateNormal];
        chip.tag = field;
        chip.selected = (field == self.sortField);
        [chip addTarget:self action:@selector(sortChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_sortChipsStack addArrangedSubview:chip];
    }
}

- (void)loadGameVersions {
    __weak typeof(self) weakSelf = self;
    [A2RemoteVersions fetchVersionsWithCompletion:^(NSArray<A2RemoteVersion *> *versions,
                                                    NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) {
            [A2Log log:@"resource-search: 游戏版本拉取失败：%@", error.localizedDescription];
            [self renderPlaceholderInStack:self.versionChipsStack text:@"版本加载失败"];
            return;
        }
        NSMutableArray<NSString *> *out = [NSMutableArray array];
        for (A2RemoteVersion *version in versions) {
            if (![version.type isEqualToString:@"release"]) continue;
            [out addObject:version.versionID];
            if (out.count >= 8) break;
        }
        self.gameVersionOptions = out;
        [self rebuildVersionChips];
    }];
}

- (void)rebuildVersionChips {
    [self clearStack:_versionChipsStack];
    [_versionChipsStack addArrangedSubview:[self makeSingleChip:@"全部"
                                                          value:@""
                                                       selected:(self.selectedGameVersion == nil)
                                                         action:@selector(versionChipTapped:)]];
    for (NSString *version in self.gameVersionOptions) {
        A2FilterChip *chip = [self makeSingleChip:version
                                            value:version
                                         selected:[version isEqualToString:self.selectedGameVersion ?: @""]
                                           action:@selector(versionChipTapped:)];
        [_versionChipsStack addArrangedSubview:chip];
    }
}

- (void)loadCategories {
    [self renderPlaceholderInStack:_categoryChipsStack text:@"分类加载中…"];
    [self.selectedCategories removeAllObjects];

    __weak typeof(self) weakSelf = self;
    [self.source categoriesForContentClass:self.contentClass
                               completion:^(NSArray<A2ContentCategory *> *categories,
                                            NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error || categories.count == 0) {
            [A2Log log:@"resource-search: 分类拉取失败：%@",
                  error.localizedDescription ?: @"空结果"];
            // 分类失败不阻塞其它筛选
            [self renderPlaceholderInStack:self.categoryChipsStack text:@"分类加载失败"];
            return;
        }
        [self clearStack:self.categoryChipsStack];
        for (A2ContentCategory *category in categories) {
            A2FilterChip *chip = [A2FilterChip chip];
            chip.translatesAutoresizingMaskIntoConstraints = NO;
            chip.filterValue = category.identifier;
            [chip setTitle:category.displayName forState:UIControlStateNormal];
            [chip addTarget:self
                     action:@selector(categoryChipTapped:)
           forControlEvents:UIControlEventTouchUpInside];
            [self.categoryChipsStack addArrangedSubview:chip];
        }
    }];
}

- (void)categoryChipTapped:(A2FilterChip *)chip {
    NSString *identifier = chip.filterValue ?: @"";
    if (identifier.length == 0) return;
    if ([self.selectedCategories containsObject:identifier]) {
        [self.selectedCategories removeObject:identifier];
    } else {
        [self.selectedCategories addObject:identifier];
    }
    chip.selected = [self.selectedCategories containsObject:identifier];
    [self updateFilterSummary];
    [A2Log log:@"resource-search: 分类筛选变更 categories=%lu",
          (unsigned long)self.selectedCategories.count];
    [self reload];
}

- (void)loaderChipTapped:(A2FilterChip *)chip {
    NSString *value = chip.filterValue ?: @"";
    self.selectedLoader = value.length ? value : nil;
    [self styleSingleSelectStack:_loaderChipsStack value:value];
    [self updateFilterSummary];
    [A2Log log:@"resource-search: 加载器筛选 = %@", value.length ? value : @"全部"];
    [self reload];
}

- (void)versionChipTapped:(A2FilterChip *)chip {
    NSString *value = chip.filterValue ?: @"";
    self.selectedGameVersion = value.length ? value : nil;
    [self styleSingleSelectStack:_versionChipsStack value:value];
    [self updateFilterSummary];
    [A2Log log:@"resource-search: 游戏版本筛选 = %@", value.length ? value : @"全部"];
    [self reload];
}

- (void)sortChipTapped:(A2FilterChip *)chip {
    A2ContentSortField field = (A2ContentSortField)chip.tag;
    self.sortField = field;
    [self styleSingleSelectStack:_sortChipsStack value:chip.filterValue];
    [self updateFilterSummary];
    [A2Log log:@"resource-search: 排序 = %@", A2SortDisplayName(field)];
    [self reload];
}

- (void)resetTapped {
    [self.selectedCategories removeAllObjects];
    self.selectedLoader = nil;
    self.selectedGameVersion = nil;
    self.sortField = A2ContentSortFieldRelevance;
    [self clearCategoryChipSelection];
    [self styleSingleSelectStack:_loaderChipsStack value:@""];
    [self styleSingleSelectStack:_versionChipsStack value:@""];
    [self styleSingleSelectStack:_sortChipsStack
                           value:[NSString stringWithFormat:@"%ld", (long)self.sortField]];
    [self updateFilterSummary];
    [A2Log log:@"resource-search: 重置全部筛选"];
    [self reload];
}

- (void)updateFilterSummary {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:self.source.displayName];
    [parts addObject:A2SortDisplayName(self.sortField)];
    NSInteger count = self.selectedCategories.count;
    if (self.selectedLoader.length) count++;
    if (self.selectedGameVersion.length) count++;
    [parts addObject:[NSString stringWithFormat:@"筛选 %ld", (long)count]];
    _filterSummaryLabel.text = [parts componentsJoinedByString:@" · "];
}

#pragma mark - UI：结果列表

- (void)setupResultList {
    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [A2Typography caption];
    [self.plainContentView addSubview:_countLabel];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.rowHeight = 120;
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, A2SpaceXXL, 0);
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [_tableView registerClass:A2ResourceResultCell.class forCellReuseIdentifier:kResultCellID];
    [self.plainContentView addSubview:_tableView];

    _stateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stateLabel.font = [A2Typography body];
    _stateLabel.textAlignment = NSTextAlignmentCenter;
    _stateLabel.numberOfLines = 0;
    _stateLabel.hidden = YES;
    [self.plainContentView addSubview:_stateLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_searchBar.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor constant:A2SpaceS],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor constant:-A2SpaceS],
        [_searchBar.heightAnchor constraintEqualToConstant:44],

        [_filterCard.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor constant:A2SpaceS],
        [_filterCard.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                  constant:A2PageMargin],
        [_filterCard.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                   constant:-A2PageMargin],

        [_countLabel.topAnchor constraintEqualToAnchor:_filterCard.bottomAnchor constant:A2SpaceS],
        [_countLabel.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                  constant:A2PageMargin],
        [_countLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.plainContentView.trailingAnchor
                                                             constant:-A2PageMargin],

        [_tableView.topAnchor constraintEqualToAnchor:_countLabel.bottomAnchor constant:A2SpaceS],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                 constant:A2PageMargin],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                  constant:-A2PageMargin],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],

        [_stateLabel.centerXAnchor constraintEqualToAnchor:self.plainContentView.centerXAnchor],
        [_stateLabel.centerYAnchor constraintEqualToAnchor:self.plainContentView.centerYAnchor],
        [_stateLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.plainContentView.leadingAnchor
                                                               constant:A2PageMargin],
        [_stateLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.plainContentView.trailingAnchor
                                                             constant:-A2PageMargin],
    ]];
}

#pragma mark - 数据

- (void)reload {
    _offset = 0;
    _reachedEnd = NO;
    _loading = NO;
    _lastError = nil;
    [_items removeAllObjects];
    [_tableView reloadData];
    [self loadMore];
}

- (void)loadMore {
    if (_loading || _reachedEnd) return;

    if (!self.source.isAvailable) {
        [self updateStateView];
        return;
    }
    if (![self.source supportsContentClass:self.contentClass]) {
        [self updateStateView];
        return;
    }

    _loading = YES;
    [self updateStateView];

    A2ContentFilter *filter = [A2ContentFilter defaultFilter];
    filter.query = self.searchBar.text.length ? self.searchBar.text : nil;
    filter.gameVersion = self.selectedGameVersion;
    filter.loader = self.selectedLoader;
    filter.categories = self.selectedCategories.allObjects;
    filter.sortField = self.sortField;
    filter.offset = _offset;
    filter.limit = 20;

    __weak typeof(self) weakSelf = self;
    [self.source searchWithFilter:filter
                     contentClass:self.contentClass
                       completion:^(NSArray<A2ContentItem *> *results, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.loading = NO;

        if (error) {
            self.lastError = error;
            [A2Log log:@"resource-search: 搜索失败 class=%ld platform=%ld：%@",
                  (long)self.contentClass, (long)self.platform, error.localizedDescription];
            [self updateStateView];
            return;
        }

        [A2Log log:@"resource-search: 搜索返回 %lu 条 class=%ld offset=%ld",
              (unsigned long)results.count, (long)self.contentClass, (long)self.offset];

        if (results.count == 0) {
            self.reachedEnd = YES;
        } else {
            [self.items addObjectsFromArray:results];
            self.offset += results.count;
        }
        [self.tableView reloadData];
        [self updateStateView];
    }];
}

- (void)updateStateView {
    if (self.items.count > 0) {
        _stateLabel.hidden = YES;
        _countLabel.text = [NSString stringWithFormat:@"共 %lu 项", (unsigned long)self.items.count];
        return;
    }

    A2ResourceSearchState state = A2ResourceSearchStateLoading;
    NSString *message = @"正在搜索…";

    if (!self.source.isAvailable) {
        state = A2ResourceSearchStateError;
        message = self.source.unavailableReason ?: @"资源源当前不可用";
    } else if (![self.source supportsContentClass:self.contentClass]) {
        state = A2ResourceSearchStateUnsupported;
        message = [NSString stringWithFormat:@"%@ 暂不支持%@，请切换其它平台",
                   self.source.displayName, A2ClassDisplayName(self.contentClass)];
    } else if (self.loading) {
        state = A2ResourceSearchStateLoading;
        message = @"正在搜索…";
    } else if (self.lastError) {
        state = A2ResourceSearchStateError;
        message = [NSString stringWithFormat:@"请求失败：%@", self.lastError.localizedDescription];
    } else if (self.reachedEnd) {
        state = A2ResourceSearchStateEmpty;
        message = @"没有找到相关资源";
    }

    _countLabel.text = @"";
    _stateLabel.hidden = NO;
    _stateLabel.text = message;
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _stateLabel.textColor = (state == A2ResourceSearchStateError) ? t.cError : t.cOnSurfaceVariant;
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    A2ResourceResultCell *cell = [tableView dequeueReusableCellWithIdentifier:kResultCellID
                                                                 forIndexPath:indexPath];
    [cell configureWithItem:_items[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    // 滚到接近底部时加载下一页
    if (indexPath.row >= (NSInteger)_items.count - 4) {
        [self loadMore];
    }
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    A2ContentItem *item = _items[indexPath.row];
    A2ResourceDetailViewController *vc =
        [[A2ResourceDetailViewController alloc] initWithProject:item contentClass:self.contentClass];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - UISearchBarDelegate

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [self reload];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    // 清空时立刻恢复完整列表
    if (searchText.length == 0) [self reload];
}

#pragma mark - 通知

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)handleFavoritesChanged:(NSNotification *)note {
    // 收藏变了，刷新可见行的星标
    NSArray<NSIndexPath *> *visible = [self.tableView indexPathsForVisibleRows];
    if (visible.count == 0) return;
    [self.tableView reloadRowsAtIndexPaths:visible withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    _searchBar.tintColor = t.cPrimary;
    for (UIView *v in _searchBar.subviews) {
        for (UIView *sv in v.subviews) {
            if ([sv isKindOfClass:UITextField.class]) {
                UITextField *tf = (UITextField *)sv;
                tf.textColor = t.cOnSurface;
                tf.attributedPlaceholder =
                    [[NSAttributedString alloc] initWithString:@"搜索资源…"
                                                    attributes:@{NSForegroundColorAttributeName:
                                                                     t.cOnSurfaceVariant}];
            }
        }
    }

    _filterSummaryLabel.textColor = t.cOnSurfaceVariant;
    _filterChevron.tintColor = t.cOnSurfaceVariant;
    for (UILabel *label in _sectionLabels) {
        label.textColor = t.cOnSurfaceVariant;
    }

    _platformControl.selectedSegmentTintColor = t.cPrimary;
    _platformControl.tintColor = t.cOnSurfaceVariant;
    [_platformControl setTitleTextAttributes:@{NSForegroundColorAttributeName: t.cOnSurfaceVariant}
                                    forState:UIControlStateNormal];
    [_platformControl setTitleTextAttributes:@{NSForegroundColorAttributeName: t.cOnPrimary}
                                    forState:UIControlStateSelected];

    [_resetButton setTitleColor:t.cPrimary forState:UIControlStateNormal];
    _resetButton.layer.borderColor = t.cOutlineVariant.CGColor;

    _countLabel.textColor = t.cOnSurfaceVariant;
    _stateLabel.textColor = t.cOnSurfaceVariant;

    [_filterCard applyTheme];
}

@end
