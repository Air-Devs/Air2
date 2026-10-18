//
//  A2AggregateSearchViewController.m
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
//
//  聚合搜索页实现 —— MD3（填充式输入框 / 分段按钮 / 筛选胶囊 / 卡片列表），
//  刻意不使用液态玻璃：底板是主题 surface，结果卡片沿用既有卡片组件。
//
//  页面结构（自上而下，一条竖线）：
//    [检索范围分段]  聚合 · Modrinth · CurseForge
//    [搜索输入框][搜索按钮]
//    [游戏版本输入框]（可选，留空表示不限）
//    [加载器胶囊] 全部 / Fabric / Quilt / Forge / NeoForge
//    [排序胶囊]   相关 / 下载量 / 最新
//    [统计行]     Modrinth N · CurseForge M → 合并 K 条（单源降级时在这里说明）
//    [结果列表]   + [分页条]
//
//  为什么把筛选放在顶部而不是右侧面板：本页是「一屏看两个源」，
//  结果区要尽量宽；筛选只有三组、每组不超过 5 个值，顶部一行放得下。
//

#import "A2AggregateSearchViewController.h"

#import "A2AggregateSearchService.h"
#import "A2ContentSource.h"
#import "A2FilterChip.h"
#import "A2Log.h"
#import "A2Metrics.h"
#import "A2PaginationBar.h"
#import "A2PrimaryButton.h"
#import "A2ResourceDetailViewController.h"
#import "A2ResourceResultCell.h"
#import "A2SegmentedControl.h"
#import "A2TextField.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"

static NSString *const kAggregateResultCellID = @"A2AggregateResultCell";
static const NSInteger kAggregatePageSize = 20;

/// 结果区状态 —— 四态各走独立文案（不共用一个「加载失败」）
typedef NS_ENUM(NSInteger, A2AggregateSearchState) {
    A2AggregateSearchStateLoading = 0,
    A2AggregateSearchStateResults,
    A2AggregateSearchStateEmpty,
    A2AggregateSearchStateError,
};

#pragma mark - 序号 ↔ 检索范围

static A2AggregateSourceMode A2AggregateModeFromIndex(NSInteger index) {
    switch (index) {
        case 1: return A2AggregateSourceModeModrinth;
        case 2: return A2AggregateSourceModeCurseForge;
        default: return A2AggregateSourceModeBoth;
    }
}

static NSString *A2AggregateSourceLabel(A2ContentPlatform platform) {
    return (platform == A2ContentPlatformModrinth) ? @"Modrinth" : @"CurseForge";
}

#pragma mark - 页面

@interface A2AggregateSearchViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, assign) A2ContentClass contentClass;

// 筛选条件
@property (nonatomic, assign) A2AggregateSourceMode mode;
@property (nonatomic, assign) A2ContentSortField sortField;
@property (nonatomic, copy, nullable) NSString *loader;

// 控件
@property (nonatomic, strong) A2SegmentedControl *modeControl;
@property (nonatomic, strong) A2TextField *searchField;
@property (nonatomic, strong) A2PrimaryButton *searchButton;
@property (nonatomic, strong) A2TextField *gameVersionField;
@property (nonatomic, strong) UIStackView *loaderChips;
@property (nonatomic, strong) UIStackView *sortChips;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) A2PaginationBar *paginationBar;
/// 结果区容器（表格 / 状态文案 / 分页条的共同父视图）
@property (nonatomic, strong) UIView *resultContainer;

// 数据
@property (nonatomic, strong) NSMutableArray<A2ContentItem *> *items;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<A2ContentItem *> *> *pageCache;
@property (nonatomic, assign) NSInteger page;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL reachedEnd;
@property (nonatomic, assign) A2AggregateSearchState state;
/// 请求代号：只认最后一次请求的回调（快速连点搜索时旧响应不许覆盖新结果）
@property (nonatomic, assign) NSUInteger requestToken;

#pragma mark - 内部方法（实现顺序靠后，先声明）

- (void)setupHeader;
- (void)setupResultList;
- (void)setupPaginationBar;
- (UIStackView *)chipRowWithTitles:(NSArray<NSString *> *)titles
                            values:(NSArray<NSString *> *)values
                          selected:(NSString *)selectedValue
                            action:(SEL)action;
- (void)handleSearchTapped;
- (void)handleLoaderChip:(A2FilterChip *)sender;
- (void)handleSortChip:(A2FilterChip *)sender;
- (A2ContentSortField)sortFieldForValue:(NSString *)value;
- (A2ContentFilter *)currentFilterForPage:(NSInteger)page;
- (void)reload;
- (void)loadPage:(NSInteger)page;
- (void)updateStatusWithOutcome:(A2AggregateSearchOutcome *)outcome;
- (void)setState:(A2AggregateSearchState)state;

@end

@implementation A2AggregateSearchViewController

- (instancetype)initWithContentClass:(A2ContentClass)contentClass {
    self = [super init];
    if (self) {
        _contentClass = contentClass;
        _mode = A2AggregateSourceModeBoth;
        _sortField = A2ContentSortFieldRelevance;
        _items = [NSMutableArray array];
        _pageCache = [NSMutableDictionary dictionary];
        _page = 1;
        _state = A2AggregateSearchStateLoading;
    }
    return self;
}

- (void)viewDidLoad {
    // 本页是「固定头部 + 滚动表格」，不用基类的滚动容器
    self.usesScrollContent = NO;
    [super viewDidLoad];

    self.pageTitle = [NSString stringWithFormat:@"聚合搜索 · %@", A2ClassDisplayName(self.contentClass)];

    [self setupHeader];
    [self setupResultList];
    [self setupPaginationBar];
    [self applyTheme];

    // 存档只有 CurseForge 一家：不支持聚合 ⇒ 直接锁到单源，避免给用户一个永远空一半的结果页
    if (![A2AggregateSearchService supportsAggregateForContentClass:self.contentClass]) {
        self.mode = A2AggregateSourceModeCurseForge;
        self.modeControl.selectedIndex = 2;
        self.statusLabel.text = @"Modrinth 不提供该资源：本页只检索 CurseForge";
    }

    [self loadPage:1];
}

#pragma mark - UI

- (void)setupHeader {
    UIStackView *header = [[UIStackView alloc] initWithFrame:CGRectZero];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = A2SpaceM;
    header.alignment = UIStackViewAlignmentFill;
    [self.plainContentView addSubview:header];

    // ① 检索范围：MD3 分段按钮（互斥三选一）
    _modeControl = [[A2SegmentedControl alloc] initWithTitles:@[@"聚合", @"Modrinth", @"CurseForge"]];
    _modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    _modeControl.selectedIndex = 0;
    __weak typeof(self) weakSelf = self;
    _modeControl.onSegmentChange = ^(NSInteger index) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.mode = A2AggregateModeFromIndex(index);
        [A2Log log:@"[AGG-UI] 检索范围切换 -> mode=%ld", (long)self.mode];
        [self reload];
    };
    [header addArrangedSubview:_modeControl];
    [_modeControl.heightAnchor constraintEqualToConstant:40].active = YES;

    // ② 搜索行：输入框 + 按钮
    UIStackView *searchRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    searchRow.axis = UILayoutConstraintAxisHorizontal;
    searchRow.spacing = A2SpaceS;
    searchRow.alignment = UIStackViewAlignmentCenter;

    _searchField = [[A2TextField alloc] initWithLabel:@"搜索名称"];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.compactHeight = 44;
    _searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchField.textField.returnKeyType = UIReturnKeySearch;
    _searchField.onReturn = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self reload];
    };
    [searchRow addArrangedSubview:_searchField];

    _searchButton = [[A2PrimaryButton alloc] initWithTitle:@"搜索" style:A2ButtonStyleSecondary];
    _searchButton.translatesAutoresizingMaskIntoConstraints = NO;
    _searchButton.minHeight = 44;
    [_searchButton addTarget:self action:@selector(handleSearchTapped)
            forControlEvents:UIControlEventTouchUpInside];
    [searchRow addArrangedSubview:_searchButton];
    [_searchButton.widthAnchor constraintEqualToConstant:96].active = YES;
    [_searchButton.heightAnchor constraintEqualToConstant:44].active = YES;

    [header addArrangedSubview:searchRow];

    // ③ 游戏版本（可选）
    _gameVersionField = [[A2TextField alloc] initWithLabel:@"游戏版本（如 1.21.5，留空不限）"];
    _gameVersionField.translatesAutoresizingMaskIntoConstraints = NO;
    _gameVersionField.compactHeight = 44;
    _gameVersionField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _gameVersionField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    _gameVersionField.onReturn = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self reload];
    };
    [header addArrangedSubview:_gameVersionField];

    // ④ 加载器 / 排序胶囊
    _loaderChips = [self chipRowWithTitles:@[@"全部加载器", @"Fabric", @"Quilt", @"Forge", @"NeoForge"]
                                    values:@[@"", @"fabric", @"quilt", @"forge", @"neoforge"]
                                  selected:@""
                                    action:@selector(handleLoaderChip:)];
    [header addArrangedSubview:_loaderChips];

    _sortChips = [self chipRowWithTitles:@[@"相关", @"下载量", @"最新"]
                                  values:@[@"relevance", @"downloads", @"newest"]
                                selected:@"relevance"
                                  action:@selector(handleSortChip:)];
    [header addArrangedSubview:_sortChips];

    // ⑤ 统计行
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.numberOfLines = 0;
    _statusLabel.font = [A2Typography caption];
    _statusLabel.text = @"正在检索…";
    [header addArrangedSubview:_statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor
                                         constant:A2SpaceM],
        [header.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                             constant:A2PageMargin],
        [header.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                              constant:-A2PageMargin],
    ]];

    // 结果区从这个 header 底部开始
    UIView *resultContainer = [[UIView alloc] initWithFrame:CGRectZero];
    resultContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.plainContentView addSubview:resultContainer];
    [NSLayoutConstraint activateConstraints:@[
        [resultContainer.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:A2SpaceM],
        [resultContainer.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor],
        [resultContainer.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],
        [resultContainer.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
    ]];
    _resultContainer = resultContainer;
}

/// 一行胶囊：titles/values 一一对应，values 里 @"" 表示「不筛选」。
- (UIStackView *)chipRowWithTitles:(NSArray<NSString *> *)titles
                            values:(NSArray<NSString *> *)values
                          selected:(NSString *)selectedValue
                            action:(SEL)action {
    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = A2SpaceS;
    row.alignment = UIStackViewAlignmentLeading;
    row.distribution = UIStackViewDistributionFill;   // UIStackView 没有 Leading 分布（只有 Fill/FillEqually/FillProportionally/EqualSpacing/EqualCentering）

    for (NSUInteger i = 0; i < titles.count; i++) {
        A2FilterChip *chip = [A2FilterChip chip];
        chip.filterValue = (i < values.count) ? values[i] : @"";
        [chip setTitle:titles[i] forState:UIControlStateNormal];
        chip.selected = [chip.filterValue isEqualToString:selectedValue];
        [chip addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:chip];
    }
    return row;
}

- (void)setupResultList {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.rowHeight = 120;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [_tableView registerClass:A2ResourceResultCell.class forCellReuseIdentifier:kAggregateResultCellID];
    [_resultContainer addSubview:_tableView];

    _stateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stateLabel.numberOfLines = 0;
    _stateLabel.textAlignment = NSTextAlignmentCenter;
    _stateLabel.font = [A2Typography body];
    _stateLabel.hidden = YES;
    [_resultContainer addSubview:_stateLabel];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    [_resultContainer addSubview:_spinner];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:_resultContainer.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:_resultContainer.leadingAnchor
                                                 constant:A2PageMargin],
        [_tableView.trailingAnchor constraintEqualToAnchor:_resultContainer.trailingAnchor
                                                  constant:-A2PageMargin],
        // 底边由 setupPaginationBar 接到分页条顶（两处都写会互相冲突）

        [_stateLabel.centerXAnchor constraintEqualToAnchor:_resultContainer.centerXAnchor],
        [_stateLabel.centerYAnchor constraintEqualToAnchor:_resultContainer.centerYAnchor],
        [_stateLabel.leadingAnchor constraintEqualToAnchor:_resultContainer.leadingAnchor
                                                  constant:A2PageMargin * 2],
        [_stateLabel.trailingAnchor constraintEqualToAnchor:_resultContainer.trailingAnchor
                                                   constant:-A2PageMargin * 2],

        [_spinner.centerXAnchor constraintEqualToAnchor:_resultContainer.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:_resultContainer.centerYAnchor],
    ]];
}

- (void)setupPaginationBar {
    _paginationBar = [[A2PaginationBar alloc] initWithFrame:CGRectZero];
    _paginationBar.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    _paginationBar.onNavigate = ^(NSInteger page) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self loadPage:page];
    };
    [_resultContainer addSubview:_paginationBar];
    [NSLayoutConstraint activateConstraints:@[
        [_paginationBar.leadingAnchor constraintEqualToAnchor:_resultContainer.leadingAnchor
                                                     constant:A2PageMargin],
        [_paginationBar.trailingAnchor constraintEqualToAnchor:_resultContainer.trailingAnchor
                                                      constant:-A2PageMargin],
        [_paginationBar.bottomAnchor constraintEqualToAnchor:_resultContainer.bottomAnchor
                                                    constant:-A2SpaceS],
    ]];

    // 表格给分页条留出高度（分页条自身高 44，见其内部约束）
    [_tableView.bottomAnchor constraintEqualToAnchor:_paginationBar.topAnchor
                                            constant:-A2SpaceS].active = YES;
}

#pragma mark - 筛选动作

- (void)handleSearchTapped {
    [self reload];
}

- (void)handleLoaderChip:(A2FilterChip *)sender {
    for (UIView *view in self.loaderChips.arrangedSubviews) {
        if (![view isKindOfClass:A2FilterChip.class]) continue;
        A2FilterChip *chip = (A2FilterChip *)view;
        chip.selected = (chip == sender);
    }
    self.loader = sender.filterValue.length > 0 ? sender.filterValue : nil;
    [self reload];
}

- (void)handleSortChip:(A2FilterChip *)sender {
    for (UIView *view in self.sortChips.arrangedSubviews) {
        if (![view isKindOfClass:A2FilterChip.class]) continue;
        A2FilterChip *chip = (A2FilterChip *)view;
        chip.selected = (chip == sender);
    }
    self.sortField = [self sortFieldForValue:sender.filterValue];
    [self reload];
}

- (A2ContentSortField)sortFieldForValue:(NSString *)value {
    if ([value isEqualToString:@"downloads"]) return A2ContentSortFieldDownloads;
    if ([value isEqualToString:@"newest"])    return A2ContentSortFieldNewest;
    return A2ContentSortFieldRelevance;
}

#pragma mark - 检索

- (A2ContentFilter *)currentFilterForPage:(NSInteger)page {
    A2ContentFilter *filter = [A2ContentFilter defaultFilter];
    NSString *query = self.searchField.text;
    filter.query = query.length > 0 ? query : nil;
    NSString *gameVersion = self.gameVersionField.text;
    filter.gameVersion = gameVersion.length > 0 ? gameVersion : nil;
    filter.loader = self.loader;
    filter.categories = @[];
    filter.sortField = self.sortField;
    filter.limit = kAggregatePageSize;
    filter.offset = (page - 1) * kAggregatePageSize;
    return filter;
}

/// 条件变化 ⇒ 清缓存、回到第 1 页。
- (void)reload {
    [self.pageCache removeAllObjects];
    self.reachedEnd = NO;
    // 条件变了：作废在途请求（token 递增 ⇒ 它的回调按 token 丢弃），同时解除加载锁，
    // 否则「上一页还没回来时改筛选」会被 `loadPage:` 的 loading 判据整条吞掉。
    self.requestToken += 1;
    self.loading = NO;
    [self loadPage:1];
}

- (void)loadPage:(NSInteger)page {
    if (page < 1) page = 1;

    NSArray<A2ContentItem *> *cached = self.pageCache[@(page)];
    if (cached != nil) {
        self.page = page;
        [self.items setArray:cached];
        [self setState:A2AggregateSearchStateResults];
        [self.tableView reloadData];
        [self.paginationBar setCurrentPage:page totalPages:0];
        return;
    }

    if (self.loading) return;   // 同时只允许一个在途请求（分页条点击不会叠加）
    self.loading = YES;
    self.page = page;
    self.requestToken += 1;
    NSUInteger token = self.requestToken;

    [self setState:A2AggregateSearchStateLoading];

    A2ContentFilter *filter = [self currentFilterForPage:page];
    __weak typeof(self) weakSelf = self;
    [A2AggregateSearchService.shared searchWithFilter:filter
                                         contentClass:self.contentClass
                                                 mode:self.mode
                                           completion:^(A2AggregateSearchOutcome *outcome) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // 只认最后一次请求：连点搜索时旧响应直接丢弃（否则新旧结果会互相覆盖）
        if (token != self.requestToken) return;

        self.loading = NO;

        if (outcome.error != nil) {
            self.items = [NSMutableArray array];
            [self.tableView reloadData];
            NSString *message = [NSString stringWithFormat:@"检索失败：%@",
                                 outcome.error.localizedDescription ?: @"未知错误"];
            if (outcome.degradedReason.length > 0) {
                message = [message stringByAppendingFormat:@"\n%@", outcome.degradedReason];
            }
            self.stateLabel.text = message;
            [self setState:A2AggregateSearchStateError];
            [self.paginationBar setCurrentPage:page totalPages:0];
            return;
        }

        self.pageCache[@(page)] = outcome.items ?: @[];
        [self.items setArray:outcome.items ?: @[]];

        // 任一路取满一页 ⇒ 还可能有下一页
        self.reachedEnd = (outcome.modrinthCount < kAggregatePageSize &&
                           outcome.curseForgeCount < kAggregatePageSize);

        [self updateStatusWithOutcome:outcome];
        [self.tableView reloadData];
        self.paginationBar.isLastPage = self.reachedEnd;
        [self.paginationBar setCurrentPage:page totalPages:0];
        [self setState:(self.items.count > 0 ? A2AggregateSearchStateResults
                                            : A2AggregateSearchStateEmpty)];
    }];
}

- (void)updateStatusWithOutcome:(A2AggregateSearchOutcome *)outcome {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSNumber *box in outcome.engagedPlatforms) {
        A2ContentPlatform platform = (A2ContentPlatform)box.integerValue;
        NSInteger count = (platform == A2ContentPlatformModrinth)
            ? outcome.modrinthCount : outcome.curseForgeCount;
        [parts addObject:[NSString stringWithFormat:@"%@ %ld",
                          A2AggregateSourceLabel(platform), (long)count]];
    }

    NSString *head = parts.count > 0
        ? [NSString stringWithFormat:@"%@ → 合并 %ld 条",
           [parts componentsJoinedByString:@" · "], (long)outcome.items.count]
        : @"没有参与的源";

    if (outcome.degradedReason.length > 0) {
        head = [head stringByAppendingFormat:@"\n%@", outcome.degradedReason];
    }
    self.statusLabel.text = head;
}

#pragma mark - 状态

- (void)setState:(A2AggregateSearchState)state {
    _state = state;

    BOOL showsTable = (state == A2AggregateSearchStateResults);
    BOOL showsSpinner = (state == A2AggregateSearchStateLoading);

    self.tableView.hidden = !showsTable;
    self.stateLabel.hidden = showsTable;
    self.paginationBar.hidden = !showsTable;

    if (showsSpinner) {
        [self.spinner startAnimating];
        self.stateLabel.hidden = YES;
    } else {
        [self.spinner stopAnimating];
    }

    switch (state) {
        case A2AggregateSearchStateLoading:
            break;
        case A2AggregateSearchStateEmpty:
            self.stateLabel.text = @"两个源都没有匹配的结果\n换个关键词，或清掉游戏版本 / 加载器筛选";
            break;
        case A2AggregateSearchStateError:
            break;   // 文案已由调用方按具体错误写好
        case A2AggregateSearchStateResults:
            break;
    }
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    A2ResourceResultCell *cell = [tableView dequeueReusableCellWithIdentifier:kAggregateResultCellID
                                                                forIndexPath:indexPath];
    if (indexPath.row < (NSInteger)self.items.count) {
        [cell configureWithItem:self.items[indexPath.row]];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.items.count) return;

    A2ContentItem *item = self.items[indexPath.row];
    // 详情页按条目的 platform 取源（AG 的条目自带来源，单源/聚合两种模式都成立）
    A2ResourceDetailViewController *vc =
        [[A2ResourceDetailViewController alloc] initWithProject:item contentClass:self.contentClass];
    if (self.navigationController != nil) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:vc animated:YES completion:nil];
    }
}

#pragma mark - 主题

- (void)applyTheme {
    [super applyTheme];

    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    self.statusLabel.textColor = t.cOnSurfaceVariant;
    self.stateLabel.textColor = t.cOnSurfaceVariant;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.spinner.color = t.cPrimary;

    [self.modeControl applyTheme];
    [self.searchField applyTheme];
    [self.gameVersionField applyTheme];
    [self.searchButton applyTheme];
    for (UIView *view in self.loaderChips.arrangedSubviews) {
        if ([view isKindOfClass:A2FilterChip.class]) [(A2FilterChip *)view applyTheme];
    }
    for (UIView *view in self.sortChips.arrangedSubviews) {
        if ([view isKindOfClass:A2FilterChip.class]) [(A2FilterChip *)view applyTheme];
    }
}

@end
