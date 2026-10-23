//
//  A2ResourceDetailViewController.m
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
//  资源详情页 —— MD3 布局：头卡 + 简介 + 适配当前版本的社区资源 + 版本筛选与列表。
//  静态部分全部塞进 tableHeaderView，跟着版本列表一起滚，避免小屏上
//  上半屏被固定卡片占满、下面一行版本都看不到。
//  真实图标走 A2RemoteImageView；版本全量拉回后客户端筛选（不发二次请求）；
//  下载一律交给 A2DownloadTaskCenter（清单回写由中心负责，本页不碰 A2DownloadManifest 写接口）。
//  禁分发项目（CurseForge 部分作者）不请求版本，给专属空态并禁用主按钮。
//

#import "A2ResourceDetailViewController.h"
#import "A2ContentSource.h"
#import "A2DownloadManifest.h"
#import "A2DownloadFavorites.h"
#import "A2DownloadTaskCenter.h"
#import "A2DownloadEngine.h"
#import "A2ModPackInstaller.h"
#import "A2InstallingViewController.h"
#import "A2VersionIsolation.h"
#import "A2GlassCard.h"
#import "A2RemoteImageView.h"
#import "A2PrimaryButton.h"
#import "A2FilterChip.h"
#import "A2ResourceVersionCell.h"
#import "A2RelatedResourceCard.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import "A2Log.h"

static NSString *const kResourceVersionCellID = @"A2ResourceVersionCell";
static const CGFloat kHeaderIconSize = 72;
static const CGFloat kRelatedCardWidth = 152;
static const CGFloat kRelatedStripHeight = 160;
static const CGFloat kVersionRowHeight = 78;

#pragma mark - 详情页

@interface A2ResourceDetailViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) A2ContentItem *project;
@property (nonatomic, assign) A2ContentClass contentClass;
@property (nonatomic, copy) NSString *targetSubdir;
/// 列表页当前选中的游戏版本，只用于「适配当前版本」区块，不预置版本筛选。
@property (nonatomic, copy, nullable) NSString *preferredGameVersion;

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *headerContainer;
@property (nonatomic, strong) UIStackView *topStack;

@property (nonatomic, strong) A2GlassCard *emptyCard;
@property (nonatomic, strong) UIImageView *emptyIcon;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) A2PrimaryButton *downloadButton;
@property (nonatomic, strong) UIButton *favoriteButton;

@property (nonatomic, strong) A2GlassCard *headerCard;
@property (nonatomic, strong) A2RemoteImageView *iconView;
@property (nonatomic, strong) UILabel *headerTitleLabel;
@property (nonatomic, strong) UILabel *headerMetaLabel;
@property (nonatomic, strong) UILabel *headerSummaryLabel;
@property (nonatomic, strong) UIScrollView *categoryScroll;
@property (nonatomic, strong) UIStackView *categoryChipStack;
@property (nonatomic, strong) NSLayoutConstraint *categoryHeight;
@property (nonatomic, copy) NSArray<A2FilterChip *> *categoryChips;

@property (nonatomic, strong) A2GlassCard *summaryCard;
@property (nonatomic, strong) UILabel *summaryBodyLabel;

@property (nonatomic, strong) A2GlassCard *relatedCard;
@property (nonatomic, strong) UILabel *relatedTitleLabel;
@property (nonatomic, strong) UIActivityIndicatorView *relatedSpinner;
@property (nonatomic, strong) UIScrollView *relatedScroll;
@property (nonatomic, strong) UIStackView *relatedStack;
@property (nonatomic, copy) NSArray<A2RelatedResourceCard *> *relatedCards;

@property (nonatomic, strong) A2GlassCard *filterCard;
@property (nonatomic, strong) UILabel *versionCountLabel;
@property (nonatomic, strong) UIStackView *filterStack;
@property (nonatomic, strong) UIStackView *gameVersionRow;
@property (nonatomic, strong) UIStackView *gameVersionChipStack;
@property (nonatomic, strong) UIStackView *loaderRow;
@property (nonatomic, strong) UIStackView *loaderChipStack;

/// 全部版本（筛选前）。更新检测与「下载最新版」都以它为准，避免筛选后误判。
@property (nonatomic, strong) NSArray<A2ContentVersion *> *allVersions;
/// 当前展示（已按筛选条件过滤）的版本。
@property (nonatomic, strong) NSArray<A2ContentVersion *> *versions;

@property (nonatomic, copy, nullable) NSString *selectedGameVersion;
@property (nonatomic, copy, nullable) NSString *selectedLoader;

// 私有方法前置声明，避免跨段落调用时出现隐式 id 返回值警告。
- (void)updateTableHeaderHeight;
- (void)rebuildCategoryChips;
- (void)clearStack:(UIStackView *)stack;
- (UIScrollView *)scrollerForChips:(UIStackView *)chips height:(CGFloat)height;
- (UIStackView *)makeChipStack;
- (UIStackView *)makeFilterRowWithLabel:(NSString *)text chipsStack:(UIStackView *)chips;
- (void)rebuildFilterChips;
- (void)applyFilter;
- (void)showEmptyWithText:(NSString *)text;
- (void)buildRelatedCards:(NSArray<A2ContentItem *> *)items;
- (void)openRelatedItem:(A2ContentItem *)item;
- (NSString *)formatCount:(long long)count;
- (NSString *)displaySize:(long long)n;

@end

@implementation A2ResourceDetailViewController

- (instancetype)initWithProject:(A2ContentItem *)project
                   contentClass:(A2ContentClass)contentClass
                    gameVersion:(NSString *)gameVersion {
    self = [super init];
    if (!self) return nil;
    _project = project;
    _contentClass = contentClass;
    _preferredGameVersion = [gameVersion copy];
    /// 版本隔离目录由分类唯一出口推导（统一映射只留一处）。
    _targetSubdir = A2VersionFolderForClass(contentClass);
    _allVersions = @[];
    _versions = @[];
    _categoryChips = @[];
    _relatedCards = @[];
    return self;
}

- (void)viewDidLoad {
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = _project.title;

    [self setupFavoriteButton];
    [self setupTable];
    [self setupHeaderContainer];
    [self loadRelatedResources];
    [self reloadVersions];
    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateTableHeaderHeight];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 收藏

- (void)setupFavoriteButton {
    __weak typeof(self) weakSelf = self;
    _favoriteButton = [self addTrailingButtonWithSymbol:@"star" action:^{
        __strong typeof(weakSelf) self = weakSelf;
        [self toggleFavorite];
    }];
    [self refreshFavoriteButton];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleFavoritesChanged:)
                                              name:A2FavoritesDidChangeNotification
                                            object:nil];
}

- (void)toggleFavorite {
    A2DownloadFavorites *store = [A2DownloadFavorites shared];
    BOOL nowFavorite;
    if ([store isFavorite:_project.projectID]) {
        [store removeFavoriteWithID:_project.projectID];
        nowFavorite = NO;
    } else {
        [store addFavorite:[A2FavoriteItem itemWithContentItem:_project]];
        nowFavorite = YES;
    }
    [A2Log log:@"resource-detail: %@收藏 project=%@", nowFavorite ? @"加入" : @"取消", _project.projectID];
    [self refreshFavoriteButton];
    [A2Toast show:(nowFavorite ? @"已加入收藏" : @"已取消收藏") inView:self.view];
}

- (void)refreshFavoriteButton {
    BOOL favorite = [[A2DownloadFavorites shared] isFavorite:_project.projectID];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    UIImage *image = [UIImage systemImageNamed:(favorite ? @"star.fill" : @"star")
                             withConfiguration:cfg];
    [_favoriteButton setImage:image forState:UIControlStateNormal];
    _favoriteButton.accessibilityLabel = favorite ? @"已收藏" : @"收藏";
}

- (void)handleFavoritesChanged:(NSNotification *)note {
    [self refreshFavoriteButton];
}

#pragma mark - 表格与空态

- (void)setupTable {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.rowHeight = kVersionRowHeight;
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, A2SpaceXXL, 0);
    [_tableView registerClass:A2ResourceVersionCell.class forCellReuseIdentifier:kResourceVersionCellID];
    [self.plainContentView addSubview:_tableView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    [self.plainContentView addSubview:_spinner];

    // 空态：MD3 里空状态也是一张卡片，不做成裸文字浮在中间。
    _emptyCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _emptyCard.elevation = A2CardElevationSurface;
    _emptyCard.contentInsets = UIEdgeInsetsMake(A2SpaceL, A2SpaceL, A2SpaceL, A2SpaceL);
    _emptyCard.hidden = YES;
    [self.plainContentView addSubview:_emptyCard];

    _emptyIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _emptyIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyIcon.contentMode = UIViewContentModeCenter;
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightRegular];
    _emptyIcon.image = [UIImage systemImageNamed:@"tray" withConfiguration:cfg];
    [_emptyCard.contentView addSubview:_emptyIcon];

    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.font = [A2Typography caption];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    [_emptyCard.contentView addSubview:_emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],

        [_emptyCard.centerXAnchor constraintEqualToAnchor:_tableView.centerXAnchor],
        [_emptyCard.centerYAnchor constraintEqualToAnchor:_tableView.centerYAnchor
                                                 constant:-40],
        [_emptyCard.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.plainContentView.leadingAnchor
                                                              constant:A2PageMargin],
        [_emptyCard.trailingAnchor constraintLessThanOrEqualToAnchor:self.plainContentView.trailingAnchor
                                                            constant:-A2PageMargin],

        [_emptyIcon.topAnchor constraintEqualToAnchor:_emptyCard.contentView.topAnchor],
        [_emptyIcon.centerXAnchor constraintEqualToAnchor:_emptyCard.contentView.centerXAnchor],

        [_emptyLabel.topAnchor constraintEqualToAnchor:_emptyIcon.bottomAnchor
                                              constant:A2SpaceS],
        [_emptyLabel.leadingAnchor constraintEqualToAnchor:_emptyCard.contentView.leadingAnchor],
        [_emptyLabel.trailingAnchor constraintEqualToAnchor:_emptyCard.contentView.trailingAnchor],
        [_emptyLabel.bottomAnchor constraintEqualToAnchor:_emptyCard.contentView.bottomAnchor],
        [_emptyLabel.widthAnchor constraintLessThanOrEqualToConstant:280],

        [_spinner.centerXAnchor constraintEqualToAnchor:_tableView.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:_tableView.centerYAnchor
                                               constant:-40],
    ]];
}

/// 把表头（头卡 / 简介 / 相关资源 / 筛选）的高度按内容算出来。
/// tableHeaderView 不参与 Auto Layout，必须手动回填 frame。
- (void)updateTableHeaderHeight {
    UIView *header = _tableView.tableHeaderView;
    if (!header) return;
    CGFloat width = CGRectGetWidth(_tableView.bounds);
    if (width <= 0) return;

    CGSize size = [header systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                       withHorizontalFittingPriority:UILayoutPriorityRequired
                             verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGRect frame = header.frame;
    frame.size = CGSizeMake(width, size.height);
    if (CGRectEqualToRect(header.frame, frame)) return;
    header.frame = frame;
    _tableView.tableHeaderView = header;
}

#pragma mark - 表头容器

- (void)setupHeaderContainer {
    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    _headerContainer = header;

    _topStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _topStack.translatesAutoresizingMaskIntoConstraints = NO;
    _topStack.axis = UILayoutConstraintAxisVertical;
    _topStack.alignment = UIStackViewAlignmentFill;
    _topStack.spacing = A2CardSpacing;
    [header addSubview:_topStack];

    [NSLayoutConstraint activateConstraints:@[
        [_topStack.topAnchor constraintEqualToAnchor:header.topAnchor constant:A2SpaceS],
        [_topStack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor
                                                constant:A2PageMargin],
        [_topStack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor
                                                 constant:-A2PageMargin],
        [_topStack.bottomAnchor constraintEqualToAnchor:header.bottomAnchor
                                               constant:-A2SpaceS],
    ]];

    [self setupHeader];
    [self setupSummaryCard];
    [self setupRelatedCard];
    [self setupFilter];

    _tableView.tableHeaderView = header;
    [self updateTableHeaderHeight];
}

#pragma mark - 头卡

- (void)setupHeader {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationLow;
    card.contentInsets = UIEdgeInsetsMake(A2SpaceL, A2SpaceL, A2SpaceL, A2SpaceL);
    [_topStack addArrangedSubview:card];
    _headerCard = card;

    // 真实图标：远端拉取，无图时由 A2RemoteImageView 直接显示占位底。
    _iconView = [[A2RemoteImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.cornerRadius = A2RadiusL;
    _iconView.contentMode = UIViewContentModeScaleAspectFill;
    _iconView.clipsToBounds = YES;
    _iconView.fallbackText = _project.title.length ? [_project.title substringToIndex:1] : nil;
    [_iconView setImageURL:_project.iconURL placeholder:nil];

    _headerTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _headerTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _headerTitleLabel.font = [A2Typography titleCard];
    _headerTitleLabel.numberOfLines = 2;
    _headerTitleLabel.text = _project.title;

    _headerMetaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _headerMetaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _headerMetaLabel.font = [A2Typography caption];
    _headerMetaLabel.numberOfLines = 2;
    NSMutableArray<NSString *> *bits = [NSMutableArray array];
    if (_project.author.length) [bits addObject:_project.author];
    if (_project.downloadCount > 0) {
        [bits addObject:[NSString stringWithFormat:@"%@ 次下载", [self formatCount:_project.downloadCount]]];
    }
    if (_project.followCount > 0) {
        [bits addObject:[NSString stringWithFormat:@"%@ 关注", [self formatCount:_project.followCount]]];
    }
    _headerMetaLabel.text = [bits componentsJoinedByString:@" · "];

    // 分类标签：复用筛选胶囊样式，仅作展示（关闭交互）。
    _categoryChipStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _categoryChipStack.axis = UILayoutConstraintAxisHorizontal;
    _categoryChipStack.spacing = A2SpaceS;
    _categoryChipStack.alignment = UIStackViewAlignmentCenter;

    _categoryScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _categoryScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _categoryScroll.showsHorizontalScrollIndicator = NO;
    _categoryScroll.showsVerticalScrollIndicator = NO;
    _categoryScroll.alwaysBounceVertical = NO;
    [_categoryScroll addSubview:_categoryChipStack];
    _categoryChipStack.translatesAutoresizingMaskIntoConstraints = NO;
    _categoryHeight = [_categoryScroll.heightAnchor constraintEqualToConstant:30];
    [NSLayoutConstraint activateConstraints:@[
        [_categoryChipStack.topAnchor constraintEqualToAnchor:_categoryScroll.contentLayoutGuide.topAnchor],
        [_categoryChipStack.bottomAnchor constraintEqualToAnchor:_categoryScroll.contentLayoutGuide.bottomAnchor],
        [_categoryChipStack.leadingAnchor constraintEqualToAnchor:_categoryScroll.contentLayoutGuide.leadingAnchor],
        [_categoryChipStack.trailingAnchor constraintEqualToAnchor:_categoryScroll.contentLayoutGuide.trailingAnchor],
        [_categoryChipStack.heightAnchor constraintEqualToAnchor:_categoryScroll.frameLayoutGuide.heightAnchor],
        _categoryHeight,
    ]];
    [self rebuildCategoryChips];

    UIStackView *rightStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    rightStack.translatesAutoresizingMaskIntoConstraints = NO;
    rightStack.axis = UILayoutConstraintAxisVertical;
    rightStack.alignment = UIStackViewAlignmentFill;
    rightStack.spacing = A2SpaceXS;
    [rightStack addArrangedSubview:_headerTitleLabel];
    [rightStack addArrangedSubview:_headerMetaLabel];

    UIStackView *topRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    topRow.translatesAutoresizingMaskIntoConstraints = NO;
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.alignment = UIStackViewAlignmentCenter;
    topRow.spacing = A2SpaceL;
    [topRow addArrangedSubview:_iconView];
    [topRow addArrangedSubview:rightStack];

    // 头卡内简介摘要（截断到两行；正文全文在下方独立「简介」卡）。
    _headerSummaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _headerSummaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _headerSummaryLabel.font = [A2Typography body];
    _headerSummaryLabel.numberOfLines = 2;
    _headerSummaryLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _headerSummaryLabel.text = _project.summary.length ? _project.summary : @"暂无简介";

    _downloadButton = [[A2PrimaryButton alloc] initWithTitle:@"下载最新版"
                                                      style:A2ButtonStylePrimary];
    _downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_downloadButton addTarget:self
                        action:@selector(downloadLatest)
              forControlEvents:UIControlEventTouchUpInside];

    [card.contentView addSubview:topRow];
    [card.contentView addSubview:_categoryScroll];
    [card.contentView addSubview:_headerSummaryLabel];
    [card.contentView addSubview:_downloadButton];

    [NSLayoutConstraint activateConstraints:@[
        [topRow.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [topRow.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [topRow.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:kHeaderIconSize],
        [_iconView.heightAnchor constraintEqualToConstant:kHeaderIconSize],

        [_categoryScroll.topAnchor constraintEqualToAnchor:topRow.bottomAnchor
                                                  constant:A2SpaceM],
        [_categoryScroll.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [_categoryScroll.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],

        [_headerSummaryLabel.topAnchor constraintEqualToAnchor:_categoryScroll.bottomAnchor
                                                      constant:A2SpaceM],
        [_headerSummaryLabel.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [_headerSummaryLabel.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],

        [_downloadButton.topAnchor constraintEqualToAnchor:_headerSummaryLabel.bottomAnchor
                                                  constant:A2SpaceM],
        [_downloadButton.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [_downloadButton.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [_downloadButton.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [_downloadButton.heightAnchor constraintEqualToConstant:A2ButtonHeight],
    ]];
}

/// 用已拉回的分类聚合出标签胶囊（仅展示）。
- (void)rebuildCategoryChips {
    [self clearStack:_categoryChipStack];
    NSMutableArray<A2FilterChip *> *made = [NSMutableArray array];
    for (NSString *name in _project.categories) {
        if (!name.length) continue;
        A2FilterChip *chip = [A2FilterChip chip];
        chip.userInteractionEnabled = NO;
        chip.filterValue = name;
        [chip setTitle:name forState:UIControlStateNormal];
        [_categoryChipStack addArrangedSubview:chip];
        [made addObject:chip];
    }
    _categoryChips = made;
    // 没有分类（CurseForge 搜索结果不带分类）时整行收起，不留空白。
    _categoryHeight.constant = made.count ? 30 : 0;
    [self updateTableHeaderHeight];
}

#pragma mark - 简介卡

- (void)setupSummaryCard {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationSurface;
    card.contentInsets = UIEdgeInsetsMake(A2SpaceL, A2SpaceL, A2SpaceL, A2SpaceL);
    [_topStack addArrangedSubview:card];
    _summaryCard = card;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [A2Typography titleCard];
    title.text = @"简介";
    [card.contentView addSubview:title];

    _summaryBodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _summaryBodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _summaryBodyLabel.font = [A2Typography body];
    _summaryBodyLabel.numberOfLines = 0;
    _summaryBodyLabel.text = _project.summary.length ? _project.summary : @"暂无简介";
    [card.contentView addSubview:_summaryBodyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [title.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [_summaryBodyLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:A2SpaceS],
        [_summaryBodyLabel.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [_summaryBodyLabel.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [_summaryBodyLabel.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
    ]];
}

#pragma mark - 适配当前版本的社区资源

/// 「简介」下方自动列出与列表页所选游戏版本匹配的同类资源。
/// 整合包不参与（整包装完就是一套实例，推荐同类包没意义）。
- (void)setupRelatedCard {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationLow;
    card.contentInsets = UIEdgeInsetsMake(A2CardPadding, A2CardPadding, A2CardPadding, A2CardPadding);
    card.hidden = YES;
    [_topStack addArrangedSubview:card];
    _relatedCard = card;

    _relatedTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _relatedTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _relatedTitleLabel.font = [A2Typography subtitleCard];
    _relatedTitleLabel.text = @"相关资源";

    _relatedSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _relatedSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    _relatedSpinner.hidesWhenStopped = YES;

    UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow - 1
                              forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *titleRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    titleRow.translatesAutoresizingMaskIntoConstraints = NO;
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.alignment = UIStackViewAlignmentCenter;
    titleRow.spacing = A2SpaceS;
    [titleRow addArrangedSubview:_relatedTitleLabel];
    [titleRow addArrangedSubview:spacer];
    [titleRow addArrangedSubview:_relatedSpinner];

    _relatedStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _relatedStack.axis = UILayoutConstraintAxisHorizontal;
    _relatedStack.spacing = A2SpaceS;
    _relatedStack.alignment = UIStackViewAlignmentFill;
    _relatedScroll = [self scrollerForChips:_relatedStack height:kRelatedStripHeight];

    [card.contentView addSubview:titleRow];
    [card.contentView addSubview:_relatedScroll];

    [NSLayoutConstraint activateConstraints:@[
        [titleRow.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [titleRow.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [titleRow.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [_relatedScroll.topAnchor constraintEqualToAnchor:titleRow.bottomAnchor
                                                 constant:A2SpaceM],
        [_relatedScroll.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [_relatedScroll.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [_relatedScroll.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
    ]];
}

- (void)loadRelatedResources {
    // 整合包不算；没有选中游戏版本时也不猜。
    if (_contentClass == A2ContentClassModPack) return;
    if (_preferredGameVersion.length == 0) return;
    if (!_project.downloadable) return;

    A2ContentSource *source = [A2ContentSource sourceForPlatform:_project.platform];
    if (!source.isAvailable) return;
    if (![source supportsContentClass:_contentClass]) return;

    _relatedTitleLabel.text =
        [NSString stringWithFormat:@"适配 %@ 的%@", _preferredGameVersion,
         A2ClassDisplayName(_contentClass)];
    _relatedCard.hidden = NO;
    [_relatedSpinner startAnimating];
    [self updateTableHeaderHeight];

    A2ContentFilter *filter = [A2ContentFilter defaultFilter];
    filter.gameVersion = _preferredGameVersion;
    filter.sortField = A2ContentSortFieldDownloads;
    filter.limit = 12;

    [A2Log log:@"resource-detail: 拉取适配 %@ 的相关%@ project=%@",
        _preferredGameVersion, A2ClassDisplayName(_contentClass), _project.projectID];

    __weak typeof(self) weakSelf = self;
    [source searchWithFilter:filter
                contentClass:_contentClass
                  completion:^(NSArray<A2ContentItem *> *results, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.relatedSpinner stopAnimating];

            NSMutableArray<A2ContentItem *> *kept = [NSMutableArray array];
            for (A2ContentItem *item in results) {
                if (!item.projectID.length) continue;
                if ([item.projectID isEqualToString:self.project.projectID]) continue;
                [kept addObject:item];
            }

            if (error || kept.count == 0) {
                self.relatedCard.hidden = YES;
                [self updateTableHeaderHeight];
                [A2Log log:@"resource-detail: 相关资源为空 err=%@",
                    error.localizedDescription ?: @"无错误"];
                return;
            }

            [self buildRelatedCards:kept];
            [self updateTableHeaderHeight];
        });
    }];
}

- (void)buildRelatedCards:(NSArray<A2ContentItem *> *)items {
    [self clearStack:_relatedStack];
    NSMutableArray<A2RelatedResourceCard *> *made = [NSMutableArray array];
    for (A2ContentItem *item in items) {
        A2RelatedResourceCard *card = [[A2RelatedResourceCard alloc] initWithFrame:CGRectZero];
        [card configureWithItem:item];
        [card.widthAnchor constraintEqualToConstant:kRelatedCardWidth].active = YES;

        __weak typeof(self) weakSelf = self;
        __weak A2ContentItem *weakItem = item;
        card.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            A2ContentItem *strongItem = weakItem;
            if (!self || !strongItem) return;
            [self openRelatedItem:strongItem];
        };

        [_relatedStack addArrangedSubview:card];
        [made addObject:card];
        [card applyTheme];
    }
    _relatedCards = made;
}

- (void)openRelatedItem:(A2ContentItem *)item {
    A2ResourceDetailViewController *vc =
        [[A2ResourceDetailViewController alloc] initWithProject:item
                                                   contentClass:_contentClass
                                                    gameVersion:_preferredGameVersion];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 版本筛选

/// 一行 chip：游戏版本 / 加载器。选项从已拉回的版本聚合，客户端过滤。
- (void)setupFilter {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationLow;
    card.contentInsets = UIEdgeInsetsMake(A2CardPadding, A2CardPadding, A2CardPadding, A2CardPadding);
    [_topStack addArrangedSubview:card];
    _filterCard = card;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [A2Typography subtitleCard];
    title.text = @"版本";

    _versionCountLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionCountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionCountLabel.font = [A2Typography caption];
    _versionCountLabel.textAlignment = NSTextAlignmentRight;
    [_versionCountLabel setContentHuggingPriority:UILayoutPriorityRequired
                                          forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *titleRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    titleRow.translatesAutoresizingMaskIntoConstraints = NO;
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.alignment = UIStackViewAlignmentCenter;
    titleRow.spacing = A2SpaceS;
    [titleRow addArrangedSubview:title];
    [titleRow addArrangedSubview:_versionCountLabel];

    _filterStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _filterStack.translatesAutoresizingMaskIntoConstraints = NO;
    _filterStack.axis = UILayoutConstraintAxisVertical;
    _filterStack.spacing = A2SpaceS;

    _gameVersionChipStack = [self makeChipStack];
    _gameVersionRow = [self makeFilterRowWithLabel:@"游戏版本" chipsStack:_gameVersionChipStack];
    _gameVersionRow.hidden = YES;
    [_filterStack addArrangedSubview:_gameVersionRow];

    _loaderChipStack = [self makeChipStack];
    _loaderRow = [self makeFilterRowWithLabel:@"加载器" chipsStack:_loaderChipStack];
    _loaderRow.hidden = YES;
    [_filterStack addArrangedSubview:_loaderRow];

    [card.contentView addSubview:titleRow];
    [card.contentView addSubview:_filterStack];

    [NSLayoutConstraint activateConstraints:@[
        [titleRow.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [titleRow.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [titleRow.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],

        [_filterStack.topAnchor constraintEqualToAnchor:titleRow.bottomAnchor
                                               constant:A2SpaceS],
        [_filterStack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [_filterStack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [_filterStack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
    ]];
}

- (UIStackView *)makeChipStack {
    UIStackView *s = [[UIStackView alloc] initWithFrame:CGRectZero];
    s.axis = UILayoutConstraintAxisHorizontal;
    s.spacing = A2SpaceS;
    s.alignment = UIStackViewAlignmentCenter;
    return s;
}

/// 横向可滚动的胶囊容器。
- (UIScrollView *)scrollerForChips:(UIStackView *)chips height:(CGFloat)height {
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.showsVerticalScrollIndicator = NO;
    scroll.alwaysBounceVertical = NO;
    [scroll addSubview:chips];

    chips.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [chips.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [chips.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [chips.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [chips.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [chips.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
        [scroll.heightAnchor constraintEqualToConstant:height],
    ]];
    return scroll;
}

/// 一行筛选：左边定宽标签，右边横向滚动的一排 chip。
- (UIStackView *)makeFilterRowWithLabel:(NSString *)text chipsStack:(UIStackView *)chips {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [A2Typography caption];
    label.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    [label setContentHuggingPriority:UILayoutPriorityRequired
                             forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired
                                          forAxis:UILayoutConstraintAxisHorizontal];

    UIScrollView *scroll = [self scrollerForChips:chips height:30];

    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = A2SpaceM;
    [row addArrangedSubview:label];
    [row addArrangedSubview:scroll];
    return row;
}

/// 用已拉回的版本聚合出两行选项，并恢复当前选中态。
- (void)rebuildFilterChips {
    NSMutableSet<NSString *> *gvSet = [NSMutableSet set];
    NSMutableOrderedSet<NSString *> *loaderSet = [NSMutableOrderedSet orderedSet];
    for (A2ContentVersion *v in _allVersions) {
        for (NSString *g in v.gameVersions) if (g.length) [gvSet addObject:g];
        for (NSString *l in v.loaders) if (l.length) [loaderSet addObject:l];
    }
    // 版本号降序（新版在前）；数字感知比较，避免 1.9 > 1.21 的字符串误判。
    NSArray<NSString *> *gameVersions =
        [gvSet.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [b compare:a options:NSNumericSearch];
        }];

    [self clearStack:_gameVersionChipStack];
    [self addChipToStack:_gameVersionChipStack title:@"全部" value:@""
                selected:(_selectedGameVersion.length == 0)
                  action:@selector(gameVersionChipTapped:)];
    for (NSString *g in gameVersions) {
        [self addChipToStack:_gameVersionChipStack title:g value:g
                    selected:[g isEqualToString:_selectedGameVersion]
                      action:@selector(gameVersionChipTapped:)];
    }

    [self clearStack:_loaderChipStack];
    [self addChipToStack:_loaderChipStack title:@"全部" value:@""
                selected:(_selectedLoader.length == 0)
                  action:@selector(loaderChipTapped:)];
    for (NSString *l in loaderSet) {
        [self addChipToStack:_loaderChipStack title:l value:l
                    selected:[l isEqualToString:_selectedLoader]
                      action:@selector(loaderChipTapped:)];
    }
    // 该维度没有任何可选项时整行隐去（资源包/光影/存档一般无加载器）。
    _gameVersionRow.hidden = (gameVersions.count == 0);
    _loaderRow.hidden = (loaderSet.count == 0);
}

- (void)clearStack:(UIStackView *)stack {
    for (UIView *v in [stack.arrangedSubviews copy]) {
        [stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
}

- (void)addChipToStack:(UIStackView *)stack
                 title:(NSString *)title
                 value:(NSString *)value
              selected:(BOOL)selected
                action:(SEL)action {
    A2FilterChip *chip = [A2FilterChip chip];
    chip.filterValue = value;
    [chip setTitle:title forState:UIControlStateNormal];
    chip.selected = selected;
    [chip addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:chip];
}

- (void)gameVersionChipTapped:(A2FilterChip *)chip {
    NSString *value = chip.filterValue;
    _selectedGameVersion = value.length ? value : nil;
    [self rebuildFilterChips];
    [self applyFilter];
}

- (void)loaderChipTapped:(A2FilterChip *)chip {
    NSString *value = chip.filterValue;
    _selectedLoader = value.length ? value : nil;
    [self rebuildFilterChips];
    [self applyFilter];
}

/// 按当前筛选条件过滤已拉回的版本（客户端过滤，不发二次请求）。
- (void)applyFilter {
    NSMutableArray<A2ContentVersion *> *out = [NSMutableArray array];
    for (A2ContentVersion *v in _allVersions) {
        if (_selectedGameVersion.length && ![v.gameVersions containsObject:_selectedGameVersion]) continue;
        if (_selectedLoader.length && ![v.loaders containsObject:_selectedLoader]) continue;
        [out addObject:v];
    }
    _versions = out;
    [_tableView reloadData];
    _versionCountLabel.text = [NSString stringWithFormat:@"%lu 个版本", (unsigned long)out.count];
    [A2Log log:@"resource-detail: 筛选 gameVersion=%@ loader=%@ -> %lu 个版本",
        _selectedGameVersion ?: @"全部", _selectedLoader ?: @"全部", (unsigned long)out.count];

    if (out.count == 0) {
        [self showEmptyWithText:@"没有符合筛选条件的版本"];
    } else {
        _emptyCard.hidden = YES;
    }
    [self updateTableHeaderHeight];
}

- (void)showEmptyWithText:(NSString *)text {
    _emptyLabel.text = text;
    _emptyCard.hidden = NO;
}

#pragma mark - 版本列表数据

- (void)reloadVersions {
    // 禁分发项目不请求版本列表，直接给专属空态（不共用“加载失败”）。
    if (!_project.downloadable) {
        _allVersions = @[];
        _versions = @[];
        [_tableView reloadData];
        _gameVersionRow.hidden = YES;
        _loaderRow.hidden = YES;
        _versionCountLabel.text = @"";
        [self showEmptyWithText:@"该作者禁止第三方分发，请前往官网下载"];
        _downloadButton.enabled = NO;
        [self updateTableHeaderHeight];
        [A2Log log:@"resource-detail: 禁分发 project=%@，不请求版本", _project.projectID];
        return;
    }

    [A2Log log:@"resource-detail: 拉取版本 project=%@ class=%ld",
        _project.projectID, (long)_contentClass];
    [_spinner startAnimating];
    _emptyCard.hidden = YES;
    __weak typeof(self) weakSelf = self;
    [[A2ContentSource sourceForPlatform:_project.platform] versionsForProject:_project.projectID
                                                                  gameVersion:nil
                                                                       loader:nil
                                                                   completion:^(NSArray<A2ContentVersion *> *versions,
                                                                                NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            if (versions.count == 0) {
                self.allVersions = @[];
                self.versions = @[];
                [self.tableView reloadData];
                self.gameVersionRow.hidden = YES;
                self.loaderRow.hidden = YES;
                self.versionCountLabel.text = @"";
                // 请求失败与「确实没有版本」文案分离。
                [self showEmptyWithText:error
                    ? [NSString stringWithFormat:@"版本加载失败：%@", error.localizedDescription]
                    : @"没有可用的版本"];
                self.downloadButton.enabled = NO;
                [self updateTableHeaderHeight];
                [A2Log log:@"resource-detail: 版本为空 project=%@ err=%@",
                    self.project.projectID, error.localizedDescription ?: @"无错误"];
                return;
            }
            self.allVersions = versions;
            self.downloadButton.enabled = YES;
            [self rebuildFilterChips];
            [self applyFilter];
            [self refreshUpdateState];
        });
    }];
}

// 更新提示：装过该项目、且最新版没装 → 主按钮改「更新到 x」。
// 用 allVersions（未筛选）首元素判最新版，避免用户筛了旧版本就误判「有新版本」。
- (void)refreshUpdateState {
    A2ContentVersion *latest = _allVersions.firstObject;
    if (!latest) return;
    BOOL installedProject = [[A2DownloadManifest shared] isProjectInstalled:_project.projectID];
    BOOL latestInstalled = [[A2DownloadManifest shared] isVersionInstalled:_project.projectID
                                                                versionID:latest.versionID];
    if (installedProject && !latestInstalled) {
        _downloadButton.title = [NSString stringWithFormat:@"更新到 %@", latest.versionNumber];
    } else {
        _downloadButton.title = @"下载最新版";
    }
}

#pragma mark - 下载（统一下载任务中心）

- (void)downloadLatest {
    // 始终下最新版，与筛选条件无关。
    A2ContentVersion *v = _allVersions.firstObject;
    if (!v) {
        [A2Toast show:@"没有可用的版本" inView:self.view];
        return;
    }
    [self downloadVersion:v];
}

- (void)downloadVersion:(A2ContentVersion *)version {
    if (version.candidateURLs.count == 0) {
        [A2Toast show:@"此版本没有可下载的文件（可能作者禁止第三方分发）" inView:self.view];
        return;
    }

    // 整合包走完整安装流程（装本体+加载器+所有文件），不是单纯下载一个 jar。
    if (_contentClass == A2ContentClassModPack) {
        [self installModPackVersion:version];
        return;
    }

    NSString *fileName = version.fileName.length ? version.fileName
        : [NSString stringWithFormat:@"%@-%@.jar", _project.projectID, version.versionNumber];
    // 落盘路径走唯一出口（A2GamePath），View 不手拼 Documents 路径。
    // 该出口会在目录不存在时先建目录，所以第一次下载也能直接成功。
    A2GamePath *path = [A2GamePath pathWithGameHome:A2GamePath.defaultGameHome];
    NSError *pathErr = nil;
    NSString *dest = [path downloadDestinationInSubdir:_targetSubdir
                                              fileName:fileName
                                                 error:&pathErr];
    if (!dest) {
        [A2Toast show:(pathErr.localizedDescription ?: @"目标目录不可用") inView:self.view];
        return;
    }

    [A2Toast show:[NSString stringWithFormat:@"开始下载 %@", fileName] inView:self.view];

    A2DownloadRequest *req = [A2DownloadRequest new];
    // candidateURLs 里已含镜像候选（按设置排序），下载引擎会依次尝试。
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *u in version.candidateURLs) {
        NSURL *url = [NSURL URLWithString:u];
        if (url) [urls addObject:url];
    }
    req.candidateURLs = urls;
    req.destinationPath = dest;
    req.expectedSize = version.fileSize;
    req.allowZipFallbackCheck = YES;

    __weak typeof(self) weakSelf = self;
    NSString *taskID = [[A2DownloadTaskCenter shared]
        enqueueWithTitle:_project.title
                subtitle:(version.versionNumber.length ? version.versionNumber : fileName)
                 request:req
               projectID:_project.projectID
               versionID:version.versionID
                  subdir:_targetSubdir
              completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [A2Toast show:[NSString stringWithFormat:@"已下载 %@", fileName] inView:self.view];
            } else {
                [A2Toast show:[NSString stringWithFormat:@"下载失败：%@",
                               error.localizedDescription ?: @"未知错误"] inView:self.view];
            }
            // 清单已由中心回写，这里只需刷新勾选与更新态。
            [self.tableView reloadData];
            [self refreshUpdateState];
        });
    }];
    [A2Log log:@"resource-detail: 下载入队 taskID=%@ project=%@ version=%@ file=%@",
        taskID, _project.projectID, version.versionID, fileName];
}

#pragma mark - 整合包安装

/// 安装整合包。
///
/// 与普通资源下载的区别：整合包是一整个游戏实例 ——
/// 要建版本目录、装对应加载器、下载清单里的所有文件、解压 overrides。
/// A2ModPackInstaller 负责这些，这里只处理「先下 zip 再交给它」。
- (void)installModPackVersion:(A2ContentVersion *)version {
    if (version.candidateURLs.count == 0) {
        [A2Toast show:@"此整合包暂无可用下载地址" inView:self.view];
        return;
    }

    NSString *fileName = version.fileName.length ? version.fileName
        : [NSString stringWithFormat:@"%@.mrpack", _project.projectID];

    // 临时下载到 Caches —— 整合包 zip 是中间产物，装完即弃，
    // 不该留在游戏目录里占空间。
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *zipPath = [tmpDir stringByAppendingPathComponent:fileName];

    A2DownloadRequest *req = [A2DownloadRequest new];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *u in version.candidateURLs) {
        NSURL *url = [NSURL URLWithString:u];
        if (url) [urls addObject:url];
    }
    req.candidateURLs = urls;
    req.destinationPath = zipPath;
    req.expectedSize = version.fileSize;

    [A2Toast show:@"正在下载整合包…" inView:self.view];

    __weak typeof(self) weakSelf = self;
    [[A2DownloadEngine sharedClient] startRequest:req
        progress:nil
           speed:nil
      completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [A2Toast show:[NSString stringWithFormat:@"下载失败：%@",
                               error.localizedDescription ?: @"未知错误"] inView:self.view];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self runPackInstallerWithZip:zipPath packName:self.project.title];
        });
    }];
}

/// 下载完成后执行安装，并把进度显示在安装进度页。
- (void)runPackInstallerWithZip:(NSString *)zipPath packName:(NSString *)packName {
    A2ModPackFormat fmt = [A2ModPackInstaller detectFormatAtPath:zipPath];
    if (fmt == A2ModPackFormatUnknown) {
        [A2Toast show:@"无法识别的整合包格式" inView:self.view];
        return;
    }

    // 版本名用整合包名（去掉不合法字符）
    NSString *versionName = [packName stringByReplacingOccurrencesOfString:@"/" withString:@"-"];

    // 进安装进度页，由它展示安装过程
    A2InstallingViewController *vc =
        [[A2InstallingViewController alloc] initWithModPackPath:zipPath
                                                    versionName:versionName];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _versions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    A2ResourceVersionCell *cell =
        [tableView dequeueReusableCellWithIdentifier:kResourceVersionCellID forIndexPath:indexPath];
    A2ContentVersion *v = _versions[indexPath.row];
    // 装过的版本打勾（按 versionID 查清单，文件被手删则不算装过）。
    BOOL installed = [[A2DownloadManifest shared] isVersionInstalled:_project.projectID
                                                           versionID:v.versionID];
    BOOL latest = (indexPath.row == 0);
    [cell configureWithVersion:v
                      sizeText:(v.fileSize > 0 ? [self displaySize:v.fileSize] : @"")
                        latest:latest
                     installed:installed];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self downloadVersion:_versions[indexPath.row]];
}

#pragma mark - 主题

- (void)applyTheme {
    [super applyTheme];
    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;

    _headerCard.cornerRadius = A2RadiusXL;
    [_headerCard applyTheme];
    [_summaryCard applyTheme];
    [_relatedCard applyTheme];
    [_filterCard applyTheme];
    [_emptyCard applyTheme];
    [_iconView applyTheme];
    [_downloadButton applyTheme];

    _headerTitleLabel.textColor = scheme.cOnSurface;
    _headerMetaLabel.textColor = scheme.cOnSurfaceVariant;
    _headerSummaryLabel.textColor = scheme.cOnSurfaceVariant;
    _summaryBodyLabel.textColor = scheme.cOnSurface;
    _relatedTitleLabel.textColor = scheme.cOnSurface;
    _versionCountLabel.textColor = scheme.cOnSurfaceVariant;
    _emptyLabel.textColor = scheme.cOnSurfaceVariant;
    _emptyIcon.tintColor = scheme.cOnSurfaceVariant;
    _spinner.color = scheme.cPrimary;
    _relatedSpinner.color = scheme.cPrimary;
    _tableView.backgroundColor = UIColor.clearColor;

    for (A2FilterChip *chip in _categoryChips) {
        [chip applyTheme];
    }
    for (A2RelatedResourceCard *card in _relatedCards) {
        [card applyTheme];
    }
    [_tableView reloadData];
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
    // chip 的选中态底色由组件自己按主题重绘，这里重建一次确保配色刷新。
    [self rebuildFilterChips];
    [self rebuildCategoryChips];
    [self updateTableHeaderHeight];
}

#pragma mark - 工具

- (NSString *)formatCount:(long long)count {
    if (count >= 1000000) return [NSString stringWithFormat:@"%.1fM", count / 1000000.0];
    if (count >= 1000) return [NSString stringWithFormat:@"%.1fK", count / 1000.0];
    return [NSString stringWithFormat:@"%lld", count];
}

- (NSString *)displaySize:(long long)n {
    if (n < 1024) return [NSString stringWithFormat:@"%lld B", n];
    if (n < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", n / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", n / 1048576.0];
}

@end
