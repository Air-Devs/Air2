//
//  A2DownloadListViewController.m
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
//  资源列表 —— 接真实 Modrinth API。
//
//  搜索 + 筛选 + 分页，结果项显示项目名、说明、下载量、加载器标签。
//

#import "A2DownloadListViewController.h"
#import "A2CurseForgeAPI.h"
#import "A2CurseForgeKeyPrompt.h"
#import "A2DownloadManifest.h"
#import "A2GlassCard.h"
#import "A2Log.h"
#import "A2ModLoaderAPI.h"
#import "A2ProjectDetailViewController.h"
#import "A2RemoteVersions.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2ContentSource.h"
#import "A2FilterChip.h"

static NSString *const kCellID = @"A2DownloadCell";

#pragma mark - 列表项

@interface A2DownloadListCell : UITableViewCell
@property (nonatomic, strong) A2GlassCard *card;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *tagLabel;
@property (nonatomic, strong) UILabel *statsLabel;
- (void)configureWithProject:(A2ContentItem *)project;
@end

@implementation A2DownloadListCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _card.cornerRadius = A2RadiusL;
    _card.elevation = A2CardElevationLow;
    [self.contentView addSubview:_card];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _titleLabel.numberOfLines = 1;

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _subtitleLabel.numberOfLines = 2;

    _statsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statsLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:
                              @[_titleLabel, _subtitleLabel, _statsLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 3;

    _tagLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _tagLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _tagLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    _tagLabel.textAlignment = NSTextAlignmentCenter;
    _tagLabel.layer.cornerRadius = 8;
    _tagLabel.layer.cornerCurve = kCACornerCurveContinuous;
    _tagLabel.clipsToBounds = YES;

    [_card.contentView addSubview:textStack];
    [_card.contentView addSubview:_tagLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:3],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3],
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],

        [textStack.topAnchor constraintEqualToAnchor:_card.contentView.topAnchor],
        [textStack.bottomAnchor constraintEqualToAnchor:_card.contentView.bottomAnchor],
        [textStack.leadingAnchor constraintEqualToAnchor:_card.contentView.leadingAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_tagLabel.leadingAnchor
                                                           constant:-A2SpaceS],

        [_tagLabel.trailingAnchor constraintEqualToAnchor:_card.contentView.trailingAnchor],
        [_tagLabel.topAnchor constraintEqualToAnchor:_card.contentView.topAnchor],
        [_tagLabel.widthAnchor constraintGreaterThanOrEqualToConstant:52],
        [_tagLabel.heightAnchor constraintEqualToConstant:22],
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

- (void)configureWithProject:(A2ContentItem *)project {
    _titleLabel.text = project.title;
    _subtitleLabel.text = project.summary;

    // 下载量用易读格式
    _statsLabel.text = [NSString stringWithFormat:@"%@ 次下载 · %@ 关注",
                        [self formatCount:project.downloadCount],
                        [self formatCount:project.followCount]];

    // 已装优先于分类标签（用户先看自己装没装，再看它属哪类）。
    if ([A2DownloadManifest.shared isProjectInstalled:project.projectID]) {
        _tagLabel.text = @"已安装";
        _tagLabel.hidden = NO;
    } else {
        // 标签取前两个分类
        NSArray *cats = project.categories;
        if (cats.count > 0) {
            NSString *tag = cats.firstObject;
            _tagLabel.text = [tag capitalizedString];
            _tagLabel.hidden = NO;
        } else {
            _tagLabel.hidden = YES;
        }
    }
    [self applyTheme];
}

- (NSString *)formatCount:(long long)count {
    if (count >= 1000000) return [NSString stringWithFormat:@"%.1fM", count / 1000000.0];
    if (count >= 1000) return [NSString stringWithFormat:@"%.1fK", count / 1000.0];
    return [NSString stringWithFormat:@"%lld", count];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _titleLabel.textColor = t.cOnSurface;
    _subtitleLabel.textColor = t.cOnSurfaceVariant;
    _statsLabel.textColor = [t.cOnSurfaceVariant colorWithAlphaComponent:0.8];
    _tagLabel.textColor = t.cPrimary;
    _tagLabel.backgroundColor = [t.cPrimary colorWithAlphaComponent:0.15];
}

@end

#pragma mark - 列表页

@interface A2DownloadListViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIView *filterBar;
/// 主筛选维度（加载器 / 游戏版本）的胶囊容器，数据异步到达后可整体重建
@property (nonatomic, strong) UIStackView *dimensionStack;
/// 动态拉取到的游戏版本号（最新在前）；加载器维度用不到
@property (nonatomic, copy) NSArray<NSString *> *gameVersionOptions;
/// 当前选中的主维度筛选值（@"" 表示「全部」）
@property (nonatomic, copy) NSString *selectedDimensionValue;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSMutableArray<A2ContentItem *> *items;
@property (nonatomic, assign) NSInteger offset;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL reachedEnd;
/// 当前资源来源（Modrinth / CurseForge）
@property (nonatomic, assign) A2ContentPlatform platform;
@property (nonatomic, strong) A2ContentSource *source;
@property (nonatomic, strong) UISegmentedControl *platformSwitch;
/// 当前排序方式
@property (nonatomic, assign) A2ContentSortField sortField;
@property (nonatomic, copy) NSString *gameVersionFilter;
@property (nonatomic, copy) NSString *loaderFilter;
@end

@implementation A2DownloadListViewController

- (void)viewDidLoad {
    self.usesScrollContent = NO;
    [super viewDidLoad];

    _items = [NSMutableArray array];
    _offset = 0;
    _gameVersionOptions = @[];
    _selectedDimensionValue = @"";
    self.pageTitle = [self titleForCategory];

    [self setupSearchBar];
    [self setupFilterBar];
    [self setupTable];

    // 游戏版本维度要真实版本号，拉清单是异步的；加载器维度 meanwhile 已有真实枚举。
    [self loadGameVersionOptions];

    [self reload];
}

- (NSString *)titleForCategory {
    switch (self.category) {
        case A2DownloadCategoryGame:         return @"安装新版本";
        case A2DownloadCategoryMod:          return @"模组";
        case A2DownloadCategoryShader:       return @"光影包";
        case A2DownloadCategoryResourcePack: return @"资源包";
        case A2DownloadCategoryModpack:      return @"整合包";
        case A2DownloadCategoryWorld:        return @"存档";
    }
    return @"下载";
}

/// 下载分类 → 统一资源分类
- (A2ContentClass)contentClass {
    switch (self.category) {
        case A2DownloadCategoryModpack:      return A2ContentClassModPack;
        case A2DownloadCategoryResourcePack: return A2ContentClassResourcePack;
        case A2DownloadCategoryShader:       return A2ContentClassShader;
        case A2DownloadCategoryWorld:        return A2ContentClassWorld;
        case A2DownloadCategoryMod:
        case A2DownloadCategoryGame:
        default:                             return A2ContentClassMod;
    }
}

#pragma mark - UI

- (void)setupSearchBar {
    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    _searchBar.placeholder = @"搜索…";
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.tintColor = A2ThemeManager.shared.scheme.cPrimary;
    _searchBar.backgroundImage = [UIImage new];

    // 搜索框文字配色（UISearchBar 不跟随我们的色板，需手动设）
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    for (UIView *v in _searchBar.subviews) {
        for (UIView *sv in v.subviews) {
            if ([sv isKindOfClass:UITextField.class]) {
                UITextField *tf = (UITextField *)sv;
                tf.textColor = t.cOnSurface;
                tf.attributedPlaceholder =
                    [[NSAttributedString alloc] initWithString:@"搜索…"
                                                    attributes:@{NSForegroundColorAttributeName:
                                                                     t.cOnSurfaceVariant}];
            }
        }
    }
    [self.plainContentView addSubview:_searchBar];
}

- (void)setupFilterBar {
    _filterBar = [[UIView alloc] initWithFrame:CGRectZero];
    _filterBar.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    [_filterBar addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = A2SpaceS;
    stack.alignment = UIStackViewAlignmentCenter;
    [scroll addSubview:stack];

    // 第一组：该分类的主筛选维度（加载器或游戏版本），内容由 rebuildDimensionChips 填
    _dimensionStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _dimensionStack.axis = UILayoutConstraintAxisHorizontal;
    _dimensionStack.spacing = A2SpaceS;
    _dimensionStack.alignment = UIStackViewAlignmentCenter;
    [stack addArrangedSubview:_dimensionStack];

    // 分组分隔线
    UIView *sep = [[UIView alloc] initWithFrame:CGRectZero];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.backgroundColor = [A2ThemeManager.shared.scheme.cOutlineVariant colorWithAlphaComponent:0.5];
    [NSLayoutConstraint activateConstraints:@[
        [sep.widthAnchor constraintEqualToConstant:1],
        [sep.heightAnchor constraintEqualToConstant:18],
    ]];
    [stack addArrangedSubview:sep];

    // 第二组：排序方式（用 A2ContentSortField 统一映射）
    UIStackView *sortStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    sortStack.axis = UILayoutConstraintAxisHorizontal;
    sortStack.spacing = A2SpaceS;
    sortStack.alignment = UIStackViewAlignmentCenter;
    for (NSNumber *n in A2AllSortFields()) {
        A2ContentSortField f = (A2ContentSortField)n.integerValue;
        UIButton *chip = [self makeSortChip:f];
        [sortStack addArrangedSubview:chip];
    }
    [stack addArrangedSubview:sortStack];

    [self rebuildDimensionChips];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:_filterBar.topAnchor constant:18],
        [scroll.bottomAnchor constraintEqualToAnchor:_filterBar.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:_filterBar.leadingAnchor constant:A2PageMargin],
        [scroll.trailingAnchor constraintEqualToAnchor:_filterBar.trailingAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-A2PageMargin],
        [stack.heightAnchor constraintEqualToAnchor:scroll.heightAnchor],
    ]];

    // 筛选维度说明
    UILabel *dimLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    dimLabel.translatesAutoresizingMaskIntoConstraints = NO;
    dimLabel.text = [self filterDimensionName];
    dimLabel.font = [A2Typography caption];
    dimLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    dimLabel.tag = 802;
    [_filterBar addSubview:dimLabel];

    [NSLayoutConstraint activateConstraints:@[
        [dimLabel.leadingAnchor constraintEqualToAnchor:_filterBar.leadingAnchor constant:A2PageMargin],
        [dimLabel.topAnchor constraintEqualToAnchor:_filterBar.topAnchor],
    ]];

    [self.plainContentView addSubview:_filterBar];
    [self setupPlatformSwitch];
}

/// 资源来源切换。只有 CurseForge 有 Key 时才可选第二项。
- (void)setupPlatformSwitch {
    _platformSwitch = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    _platformSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    _platformSwitch.selectedSegmentIndex = ([A2ContentSource preferredPlatform] == A2ContentPlatformCurseForge) ? 1 : 0;
    [_platformSwitch addTarget:self action:@selector(platformChanged)
              forControlEvents:UIControlEventValueChanged];
    [self.plainContentView addSubview:_platformSwitch];

    [NSLayoutConstraint activateConstraints:@[
        [_platformSwitch.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor],
        [_platformSwitch.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                      constant:A2PageMargin],
        [_platformSwitch.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                       constant:-A2PageMargin],
        [_platformSwitch.heightAnchor constraintEqualToConstant:32]
    ]];
}

/// 切换资源来源。选择会被记住。
- (void)platformChanged {
    A2ContentPlatform picked = (_platformSwitch.selectedSegmentIndex == 0)
        ? A2ContentPlatformModrinth : A2ContentPlatformCurseForge;
    // 切 CurseForge 但无 Key：弹框要 Key，取消则回退 Modrinth，不留不可用态。
    if (picked == A2ContentPlatformCurseForge && ![A2CurseForgeAPI hasAPIKey]) {
        [A2CurseForgeKeyPrompt promptFrom:self completion:^(BOOL saved) {
            if (saved) {
                [self applyPlatform:A2ContentPlatformCurseForge];
            } else {
                self.platformSwitch.selectedSegmentIndex = 0;
                [self applyPlatform:A2ContentPlatformModrinth];
            }
        }];
        return;
    }
    [self applyPlatform:picked];
}

// 平台切换的实际生效（选择记忆 + 可用性提示 + 重载），弹窗回调与直接切换共用。
- (void)applyPlatform:(A2ContentPlatform)platform {
    self.platform = platform;
    self.source = [A2ContentSource sourceForPlatform:self.platform];
    [A2ContentSource setPreferredPlatform:self.platform];

    // 切到 CurseForge 但没配 Key 时明确提示，不静默失败
    if (!self.source.isAvailable) {
        [A2Toast show:self.source.unavailableReason ?: @"该资源源不可用" inView:self.view];
    }
    [self reload];
}

/// 切换排序方式
- (void)sortTapped:(UIButton *)sender {
    A2ContentSortField field = (A2ContentSortField)sender.tag;
    if (self.sortField == field) return;
    self.sortField = field;

    for (UIView *v in sender.superview.subviews) {
        if (![v isKindOfClass:A2FilterChip.class]) continue;
        A2FilterChip *b = (A2FilterChip *)v;
        b.selected = (b.tag == (NSInteger)field);
    }
    [self reload];
}

/// 该分类的主筛选维度是否为加载器（模组 / 整合包）
- (BOOL)dimensionIsLoader {
    return self.category == A2DownloadCategoryMod || self.category == A2DownloadCategoryModpack;
}

/// 该分类的筛选维度说明
- (NSString *)filterDimensionName {
    return [self dimensionIsLoader] ? @"加载器" : @"游戏版本";
}

/// 重建主维度胶囊。加载器用真实枚举，其它分类用动态拉取到的游戏版本；
/// 数据异步到达后调用它会保留当前选中项。
- (void)rebuildDimensionChips {
    for (UIView *v in [_dimensionStack.arrangedSubviews copy]) {
        [_dimensionStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    [self.dimensionStack addArrangedSubview:[self makeDimensionChip:@"全部" value:@""]];
    if ([self dimensionIsLoader]) {
        for (NSNumber *n in [A2ModLoaderAPI allLoaderTypes]) {
            A2ModLoaderType type = (A2ModLoaderType)n.integerValue;
            [self.dimensionStack addArrangedSubview:
                [self makeDimensionChip:[A2ModLoaderAPI displayNameForType:type]
                                  value:[A2ModLoaderAPI identifierForType:type]]];
        }
    } else {
        for (NSString *v in self.gameVersionOptions) {
            [self.dimensionStack addArrangedSubview:[self makeDimensionChip:v value:v]];
        }
    }
    [self styleDimensionChipsSelected:self.selectedDimensionValue];
}

/// 主维度胶囊。filterValue 存真实筛选值（@"" = 全部）。
- (A2FilterChip *)makeDimensionChip:(NSString *)title value:(NSString *)value {
    A2FilterChip *b = [A2FilterChip chip];
    b.filterValue = value;
    [b setTitle:title forState:UIControlStateNormal];
    b.selected = [value isEqualToString:self.selectedDimensionValue];
    [b addAction:[UIAction actionWithHandler:^(UIAction *action) {
        [self chipTapped:(UIButton *)action.sender];
    }] forControlEvents:UIControlEventTouchUpInside];
    return b;
}

/// 把维度胶囊的选中态刷成 value 对应项（重建后恢复选中用）
- (void)styleDimensionChipsSelected:(NSString *)value {
    for (UIView *v in self.dimensionStack.arrangedSubviews) {
        if (![v isKindOfClass:A2FilterChip.class]) continue;
        A2FilterChip *chip = (A2FilterChip *)v;
        chip.selected = [chip.filterValue isEqualToString:value];
    }
}

#pragma mark - 游戏版本维度（动态拉取）

/// 游戏版本维度不用硬编码版本号，改从 Mojang 清单动态拉取最新若干正式版。
/// 拉取失败时维持「全部」，不阻塞列表本身。
- (void)loadGameVersionOptions {
    if ([self dimensionIsLoader]) return;   // 加载器维度不需要版本清单

    __weak typeof(self) weakSelf = self;
    [A2RemoteVersions fetchVersionsWithCompletion:^(NSArray<A2RemoteVersion *> *versions,
                                                    NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) {
            [A2Log log:@"download-list: 游戏版本维度拉取失败：%@", error.localizedDescription];
            return;
        }
        self.gameVersionOptions = [self recentReleaseVersionIDsFrom:versions];
        [self rebuildDimensionChips];
    }];
}

/// 取清单里最新若干正式版（清单已按新版在前）。
- (NSArray<NSString *> *)recentReleaseVersionIDsFrom:(NSArray<A2RemoteVersion *> *)versions {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (A2RemoteVersion *v in versions) {
        if (![v.type isEqualToString:@"release"]) continue;
        [out addObject:v.versionID];
        if (out.count >= 8) break;
    }
    return [out copy];
}

/// 排序 chip。tag 存排序枚举值，点击走 sortTapped:
- (A2FilterChip *)makeSortChip:(A2ContentSortField)field {
    A2FilterChip *b = [A2FilterChip chip];
    [b setTitle:A2SortDisplayName(field) forState:UIControlStateNormal];
    b.tag = field;
    // 默认按相关度，所以只有 RELEVANCE 是选中的
    b.selected = (field == A2ContentSortFieldRelevance);
    [b addAction:[UIAction actionWithHandler:^(UIAction *action) {
        [self sortTapped:(UIButton *)action.sender];
    }] forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)chipTapped:(UIButton *)sender {
    A2FilterChip *chip = (A2FilterChip *)sender;
    // 用胶囊携带的真实筛选值，而不是展示文案
    NSString *value = chip.filterValue ?: @"";
    self.selectedDimensionValue = value;
    [self styleDimensionChipsSelected:value];

    // 按分类更新对应维度的筛选条件（@"" 即「全部」）
    if ([self dimensionIsLoader]) {
        self.loaderFilter = value.length ? value : nil;
    } else {
        self.gameVersionFilter = value.length ? value : nil;
    }
    [self reload];

    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationFast);
    [a addAnimations:^{ sender.transform = CGAffineTransformMakeScale(1.06, 1.06); }];
    [a addCompletion:^(UIViewAnimatingPosition pos) {
        UIViewPropertyAnimator *b = A2SpringAnimator(A2AnimDurationFast);
        [b addAnimations:^{ sender.transform = CGAffineTransformIdentity; }];
        [b startAnimation];
    }];
    [a startAnimation];
}

- (void)setupTable {
    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [A2Typography caption];
    _countLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    [self.plainContentView addSubview:_countLabel];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.rowHeight = 88;
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, A2SpaceXXL, 0);
    [_tableView registerClass:A2DownloadListCell.class forCellReuseIdentifier:kCellID];
    [self.plainContentView addSubview:_tableView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    _spinner.color = A2ThemeManager.shared.scheme.cPrimary;
    [self.plainContentView addSubview:_spinner];

    [NSLayoutConstraint activateConstraints:@[
        [_searchBar.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor constant:A2SpaceS],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor constant:-A2SpaceS],
        [_searchBar.heightAnchor constraintEqualToConstant:44],

        [_filterBar.topAnchor constraintEqualToAnchor:_platformSwitch.bottomAnchor
                                            constant:A2SpaceS],
        [_filterBar.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor],
        [_filterBar.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],
        [_filterBar.heightAnchor constraintEqualToConstant:56],

        [_countLabel.topAnchor constraintEqualToAnchor:_filterBar.bottomAnchor constant:A2SpaceS],
        [_countLabel.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                  constant:A2PageMargin],

        [_tableView.topAnchor constraintEqualToAnchor:_countLabel.bottomAnchor constant:A2SpaceS],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                 constant:A2PageMargin],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                  constant:-A2PageMargin],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],

        [_spinner.centerXAnchor constraintEqualToAnchor:self.plainContentView.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:self.plainContentView.centerYAnchor],
    ]];
}

#pragma mark - 数据

- (void)reload {
    _offset = 0;
    _reachedEnd = NO;
    [_items removeAllObjects];
    [_tableView reloadData];
    [self loadMore];
}

- (void)loadMore {
    if (_loading || _reachedEnd) return;
    _loading = YES;
    [_spinner startAnimating];

    // 源不可用时给出明确提示（CurseForge 缺 Key）
    if (!self.source.isAvailable) {
        self.loading = NO;
        [self.spinner stopAnimating];
        self.countLabel.text = self.source.unavailableReason;
        return;
    }

    __weak typeof(self) weakSelf = self;
    A2ContentFilter *filter = [A2ContentFilter defaultFilter];
    filter.query = _searchBar.text;
    filter.gameVersion = _gameVersionFilter;
    filter.loader = _loaderFilter;
    filter.sortField = self.sortField;
    filter.offset = _offset;
    filter.limit = 20;

    [self.source searchWithFilter:filter
                    contentClass:[self contentClass]
                      completion:^(NSArray<A2ContentItem *> *results, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        self.loading = NO;
        [self.spinner stopAnimating];

        if (error) {
            [A2Toast show:[NSString stringWithFormat:@"搜索失败：%@", error.localizedDescription]
                   inView:self.view];
            return;
        }

        if (results.count == 0) {
            self.reachedEnd = YES;
        } else {
            [self.items addObjectsFromArray:results];
            self.offset += results.count;
        }

        [self.tableView reloadData];
        self.countLabel.text = [NSString stringWithFormat:@"共 %lu 项", (unsigned long)self.items.count];
    }];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    A2DownloadListCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID forIndexPath:indexPath];
    [cell configureWithProject:_items[indexPath.row]];
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
    A2ContentItem *p = _items[indexPath.row];
    // 详情页负责禁分发空态与版本下载，列表只路由。
    A2ProjectDetailViewController *vc = [[A2ProjectDetailViewController alloc]
                                         initWithProject:p
                                         targetSubdir:[self directoryNameForCategory]];
    [self.navigationController pushViewController:vc animated:YES];
}

/// 目标目录用统一映射，避免各处硬编码字符串
- (NSString *)directoryNameForCategory {
    if (self.category == A2DownloadCategoryGame) return @"downloads";
    return A2VersionFolderForClass([self contentClass]);
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

@end
