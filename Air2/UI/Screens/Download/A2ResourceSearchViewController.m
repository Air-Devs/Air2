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
#import "A2DownloadFavorites.h"
#import "A2DownloadManifest.h"
#import "A2FilterChip.h"
#import "A2GlassCard.h"
#import "A2ModPackImportCoordinator.h"
#import "A2PrimaryButton.h"
#import "A2ResourceCard.h"
#import "A2TextField.h"
#import "A2PaginationBar.h"
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

/// 结果区状态 —— 各自独立文案
typedef NS_ENUM(NSInteger, A2ResourceSearchState) {
    A2ResourceSearchStateLoading = 0,
    A2ResourceSearchStateEmpty,
    A2ResourceSearchStateError,
    A2ResourceSearchStateUnsupported,
};

#import "A2ResourceResultCell.h"

#pragma mark - 搜索页

@interface A2ResourceSearchViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, assign) A2ContentClass contentClass;

// 左右分栏
@property (nonatomic, strong) UIView *resultContainer;
@property (nonatomic, strong) UIView *sidePanel;

// 筛选栏内容（对照 ZL2 的 SearchFilter）
@property (nonatomic, strong) A2TextField *searchField;

// 游戏版本：MD3 的可展开下拉 —— 点一下在下面列出全部可选版本
@property (nonatomic, strong) UIButton *gameVersionSelector;
@property (nonatomic, strong) UILabel *gameVersionValueLabel;
@property (nonatomic, strong) UIImageView *gameVersionChevron;
@property (nonatomic, strong) UIView *gameVersionMenu;
@property (nonatomic, strong) UIStackView *gameVersionMenuStack;
@property (nonatomic, strong) NSLayoutConstraint *gameVersionMenuHeight;
/// 下拉行对应的真实筛选值（下标即行按钮的 tag，@"" 表示「全部版本」）
@property (nonatomic, copy) NSArray<NSString *> *gameVersionMenuValues;
@property (nonatomic, strong) UIView *loaderSection;

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
/// 分页控件（对照 ZL2 的经典分页，取代原先的无限滚动）
@property (nonatomic, strong) A2PaginationBar *paginationBar;
/// 页面缓存：页号 → 结果（已看过的页不重查）
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<A2ContentItem *> *> *pageCache;
@property (nonatomic, strong, nullable) NSError *lastError;

@property (nonatomic, copy) NSArray<NSString *> *gameVersionOptions;
@property (nonatomic, copy, nullable) NSString *selectedLoader;
@property (nonatomic, copy, nullable) NSString *selectedGameVersion;
@property (nonatomic, assign) A2ContentSortField sortField;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedCategories;

/// 本地整合包导入流程协调器（运行期间由本页强持有，结束置 nil —— 见 A2ModPackImportCoordinator）
@property (nonatomic, strong, nullable) A2ModPackImportCoordinator *modPackImporter;

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

    // 布局对照 ZL2 的 SearchAssetsScreen：
    //   Row { ResultListLayout(weight=7)  SearchFilter(weight=3) }
    // 即【左侧结果列表 70%，右侧筛选面板 30%】，筛选是常驻面板而非顶部展开。
    [self setupSplitLayout];
    [self buildSidePanel];
    [self setupResultList];
    [self setupPaginationBar];
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

    // Key 是内置的，两个平台都开箱可用，不需要任何拦截。
    (void)previous;
    [self applyPlatform:picked remember:YES];
}

/// 平台切换的实际生效：记忆选择 + 重建分类 + 重载结果。
- (void)applyPlatform:(A2ContentPlatform)platform remember:(BOOL)remember {
    self.platform = platform;
    self.source = [A2ContentSource sourceForPlatform:platform];
    if (remember) [A2ContentSource setPreferredPlatform:platform];
    [self selectPlatformControlForPlatform:platform];
    [A2Log log:@"resource-search: 平台切换 class=%ld → %@",
          (long)self.contentClass, self.source.displayName];

    // 分类标识两家不通用，切换平台后清空已选分类并重新拉取
    [self loadCategories];
    [self reload];
}

#pragma mark - UI：左右分栏

/// 建立分栏骨架：左侧结果区 + 右侧筛选栏。
- (void)setupSplitLayout {
    // 左侧：结果区容器
    _resultContainer = [[UIView alloc] initWithFrame:CGRectZero];
    _resultContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.plainContentView addSubview:_resultContainer];

    // 右侧：筛选栏（不滚动 —— 内容本身放得下，ZL2 也是固定高度）
    _sidePanel = [[UIView alloc] initWithFrame:CGRectZero];
    _sidePanel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.plainContentView addSubview:_sidePanel];

    [NSLayoutConstraint activateConstraints:@[
        // 左 70%
        [_resultContainer.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_resultContainer.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_resultContainer.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor],
        [_resultContainer.widthAnchor constraintEqualToAnchor:self.plainContentView.widthAnchor
                                                    multiplier:0.7],

        // 右 30%
        [_sidePanel.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_sidePanel.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_sidePanel.leadingAnchor constraintEqualToAnchor:_resultContainer.trailingAnchor],
        [_sidePanel.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],
    ]];
}

/// 右侧筛选栏的内容。
///
/// 对照 ZL2 的 SearchFilter：从上到下依次为
///   搜索名称输入框 / 游戏版本下拉 / 平台切换 /
///   排序 / 加载器 / 分类 / 重置
- (void)buildSidePanel {
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceL;
    [_sidePanel addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:_sidePanel.topAnchor constant:A2SpaceM],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:_sidePanel.bottomAnchor
                                                      constant:-A2SpaceM],
        [stack.leadingAnchor constraintEqualToAnchor:_sidePanel.leadingAnchor constant:A2SpaceM],
        [stack.trailingAnchor constraintEqualToAnchor:_sidePanel.trailingAnchor
                                             constant:-A2PageMargin],
    ]];

    __weak typeof(self) weakSelf = self;

    // ---- 搜索名称 ----
    _searchField = [[A2TextField alloc] initWithLabel:@"搜索资源"];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.textField.returnKeyType = UIReturnKeySearch;
    // 回车即搜。之前只设了 returnKeyType、没接 onReturn，
    // 敲回车没有任何反应，只能等别的筛选变化顺带刷新。
    _searchField.onReturn = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self.view endEditing:YES];
        [self reload];
    };
    [stack addArrangedSubview:[self labeledBlock:@"名称" content:_searchField]];

    // ---- 游戏版本（点击展开的版本列表）----
    [stack addArrangedSubview:[self labeledBlock:@"游戏版本"
                                         content:[self makeGameVersionSelectorGroup]]];

    // ---- 平台切换 ----
    _platformControl = [self makePlatformControl];
    _platformControl.selectedSegmentIndex = (_platform == A2ContentPlatformCurseForge) ? 1 : 0;
    [stack addArrangedSubview:[self labeledBlock:@"平台" content:_platformControl]];
    _platformControl.translatesAutoresizingMaskIntoConstraints = NO;

    // ---- 排序 ----
    _sortChipsStack = [self horizontalChipStack];
    [stack addArrangedSubview:[self labeledBlock:@"排序" content:
                            [self scrollRowWithStack:_sortChipsStack]]];

    // ---- 加载器 ----
    _loaderChipsStack = [self horizontalChipStack];
    _loaderSection = [self labeledBlock:@"加载器" content:
                      [self scrollRowWithStack:_loaderChipsStack]];
    [stack addArrangedSubview:_loaderSection];

    // ---- 分类 ----
    _categoryChipsStack = [self horizontalChipStack];
    [stack addArrangedSubview:[self labeledBlock:@"分类" content:
                            [self scrollRowWithStack:_categoryChipsStack]]];

    // ---- 重置 ----
    _resetButton = [self makeResetButton];
    [stack addArrangedSubview:_resetButton];

    // ---- 导入本地整合包 ----
    // 位置对齐 ZL2 的 SearchModPackScreen：导入入口长在筛选面板里，
    // 不在下载区另开一个分类页 —— 用户「手上已经有文件」的场景，
    // 本来就发生在挑整合包的地方。
    if (_contentClass == A2ContentClassModPack) {
        [stack addArrangedSubview:[self makeImportButton]];
    }

    // 把筛选构建放在侧栏之后执行（依赖上面的 stack 已就绪）
    [self buildLoaderChips];
    [self buildSortChips];
}

/// 「小标题 + 内容」的纵向块 —— 筛选栏里每一组的统一样式。
- (UIView *)labeledBlock:(NSString *)title content:(UIView *)content {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    label.text = title;
    [_sectionLabels addObject:label];

    UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:@[label, content]];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = A2SpaceS;
    v.alignment = UIStackViewAlignmentFill;
    return v;
}

#pragma mark - 游戏版本：点击展开的选择列表

/// MD3 的「点开再选」下拉。
/// 收起时是一枚填充式选择框（当前版本 + 箭头），点击后在下面展开
/// 可滚动的版本列表；选中某行后自动收起并重新查询。
/// 相比原来的手输框：版本号不必背，也不会输错导致查不到结果。
- (UIView *)makeGameVersionSelectorGroup {
    _gameVersionSelector = [UIButton buttonWithType:UIButtonTypeCustom];
    _gameVersionSelector.translatesAutoresizingMaskIntoConstraints = NO;
    _gameVersionSelector.layer.cornerRadius = A2RadiusL;
    _gameVersionSelector.layer.cornerCurve = kCACornerCurveContinuous;
    _gameVersionSelector.clipsToBounds = YES;
    [_gameVersionSelector addTarget:self
                             action:@selector(toggleGameVersionMenu)
                   forControlEvents:UIControlEventTouchUpInside];
    [_gameVersionSelector.heightAnchor constraintEqualToConstant:48].active = YES;

    _gameVersionValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _gameVersionValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _gameVersionValueLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    _gameVersionValueLabel.text = @"全部版本";
    _gameVersionValueLabel.userInteractionEnabled = NO;
    [_gameVersionSelector addSubview:_gameVersionValueLabel];

    _gameVersionChevron = [[UIImageView alloc] initWithImage:
        [[UIImage systemImageNamed:@"chevron.down"]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    _gameVersionChevron.translatesAutoresizingMaskIntoConstraints = NO;
    _gameVersionChevron.contentMode = UIViewContentModeScaleAspectFit;
    _gameVersionChevron.userInteractionEnabled = NO;
    [_gameVersionSelector addSubview:_gameVersionChevron];

    [NSLayoutConstraint activateConstraints:@[
        [_gameVersionValueLabel.leadingAnchor constraintEqualToAnchor:_gameVersionSelector.leadingAnchor
                                                             constant:A2SpaceM],
        [_gameVersionValueLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_gameVersionChevron.leadingAnchor
                                                                       constant:-A2SpaceS],
        [_gameVersionValueLabel.centerYAnchor constraintEqualToAnchor:_gameVersionSelector.centerYAnchor],

        [_gameVersionChevron.trailingAnchor constraintEqualToAnchor:_gameVersionSelector.trailingAnchor
                                                            constant:-A2SpaceM],
        [_gameVersionChevron.centerYAnchor constraintEqualToAnchor:_gameVersionSelector.centerYAnchor],
        [_gameVersionChevron.widthAnchor constraintEqualToConstant:16],
        [_gameVersionChevron.heightAnchor constraintEqualToConstant:16],
    ]];

    _gameVersionMenu = [[UIView alloc] initWithFrame:CGRectZero];
    _gameVersionMenu.translatesAutoresizingMaskIntoConstraints = NO;
    _gameVersionMenu.layer.cornerRadius = A2RadiusM;
    _gameVersionMenu.layer.cornerCurve = kCACornerCurveContinuous;
    _gameVersionMenu.clipsToBounds = YES;
    _gameVersionMenu.hidden = YES;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
    [_gameVersionMenu addSubview:scroll];

    _gameVersionMenuStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _gameVersionMenuStack.translatesAutoresizingMaskIntoConstraints = NO;
    _gameVersionMenuStack.axis = UILayoutConstraintAxisVertical;
    _gameVersionMenuStack.spacing = 0;
    _gameVersionMenuStack.alignment = UIStackViewAlignmentFill;
    [scroll addSubview:_gameVersionMenuStack];

    // 高度由 rebuildGameVersionMenu 按行数算，超过上限就滚动
    _gameVersionMenuHeight = [_gameVersionMenu.heightAnchor constraintEqualToConstant:0];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:_gameVersionMenu.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:_gameVersionMenu.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:_gameVersionMenu.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:_gameVersionMenu.trailingAnchor],

        [_gameVersionMenuStack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [_gameVersionMenuStack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [_gameVersionMenuStack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [_gameVersionMenuStack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [_gameVersionMenuStack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],

        _gameVersionMenuHeight,
    ]];

    UIStackView *group =
        [[UIStackView alloc] initWithArrangedSubviews:@[_gameVersionSelector, _gameVersionMenu]];
    group.translatesAutoresizingMaskIntoConstraints = NO;
    group.axis = UILayoutConstraintAxisVertical;
    group.spacing = A2SpaceS;
    return group;
}

- (void)toggleGameVersionMenu {
    [self setGameVersionMenuExpanded:_gameVersionMenu.isHidden];
}

- (void)setGameVersionMenuExpanded:(BOOL)expanded {
    if (expanded == !_gameVersionMenu.hidden) return;
    _gameVersionMenu.hidden = !expanded;

    CGAffineTransform target = expanded
        ? CGAffineTransformMakeRotation((CGFloat)M_PI)
        : CGAffineTransformIdentity;
    [UIView animateWithDuration:A2AnimDurationFast animations:^{
        self.gameVersionChevron.transform = target;
    }];
}

/// 重建下拉列表：第一行固定是「全部版本」，后面跟接口返回的正式版本。
- (void)rebuildGameVersionMenu {
    [self clearStack:_gameVersionMenuStack];

    NSMutableArray<NSString *> *values = [NSMutableArray arrayWithObject:@""];
    [values addObjectsFromArray:self.gameVersionOptions];
    self.gameVersionMenuValues = values;

    for (NSInteger i = 0; i < (NSInteger)values.count; i++) {
        UIButton *row = [self makeGameVersionRowWithValue:values[i] index:i];
        [_gameVersionMenuStack addArrangedSubview:row];
    }

    // 每行 44pt；超过 220pt 就滚动，避免把侧栏顶出屏幕
    _gameVersionMenuHeight.constant = MIN(values.count * 44.0, 220);
    [self updateGameVersionSelectorTitle];
}

- (UIButton *)makeGameVersionRowWithValue:(NSString *)value index:(NSInteger)index {
    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.tag = index;
    row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    row.contentEdgeInsets = UIEdgeInsetsMake(0, A2SpaceM, 0, A2SpaceM);
    row.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    [row setTitle:(value.length > 0 ? value : @"全部版本") forState:UIControlStateNormal];
    [row.heightAnchor constraintEqualToConstant:44].active = YES;
    [row addTarget:self
            action:@selector(gameVersionRowTapped:)
  forControlEvents:UIControlEventTouchUpInside];
    return row;
}

- (void)gameVersionRowTapped:(UIButton *)row {
    if (row.tag >= 0 && row.tag < (NSInteger)_gameVersionMenuValues.count) {
        NSString *value = _gameVersionMenuValues[row.tag];
        self.selectedGameVersion = value.length > 0 ? value : nil;
        [A2Log log:@"resource-search: 游戏版本筛选 = %@",
              value.length > 0 ? value : @"全部"];
    }
    [self setGameVersionMenuExpanded:NO];
    [self updateGameVersionSelectorTitle];
    [self reload];
}

- (void)updateGameVersionSelectorTitle {
    _gameVersionValueLabel.text = self.selectedGameVersion.length > 0
        ? self.selectedGameVersion
        : @"全部版本";
    [self applyTheme];
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


#pragma mark - 筛选栏辅助

/// 横向 chip 容器
- (UIStackView *)horizontalChipStack {
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = A2SpaceS;
    stack.alignment = UIStackViewAlignmentCenter;
    return stack;
}

/// 把 chip 容器包进横向滚动区 —— 选项多时（如分类列表）不会挤成一团
- (UIView *)scrollRowWithStack:(UIStackView *)stack {
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.alwaysBounceHorizontal = YES;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.heightAnchor constraintEqualToConstant:34],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
    ]];
    return scroll;
}

/// 平台切换控件
- (UISegmentedControl *)makePlatformControl {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSNumber *n in _platformOptions) {
        [titles addObject:A2PlatformDisplayName((A2ContentPlatform)n.integerValue)];
    }
    UISegmentedControl *c = [[UISegmentedControl alloc] initWithItems:titles];
    c.selectedSegmentIndex = 0;
    [c addTarget:self action:@selector(platformChanged)
        forControlEvents:UIControlEventValueChanged];
    [c.heightAnchor constraintEqualToConstant:32].active = YES;
    return c;
}

/// 重置按钮
- (UIButton *)makeResetButton {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:@"重置筛选" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b.layer.cornerRadius = A2RadiusM;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.layer.borderWidth = 1;
    [b.heightAnchor constraintEqualToConstant:40].active = YES;
    [b addTarget:self action:@selector(resetAllFilters) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

/// 平台显示名（两家平台的中文/英文名）
static NSString *A2PlatformDisplayName(A2ContentPlatform platform) {
    return (platform == A2ContentPlatformModrinth) ? @"Modrinth" : @"CurseForge";
}

/// 导入本地整合包入口 —— 只有整合包分类有这个按钮。
/// 后续流程（免责提示 / 选文件 / 命名 / 进度 / 结果）全在 MD3 弹窗里，
/// 见 A2ModPackImportCoordinator。
- (UIView *)makeImportButton {
    A2PrimaryButton *button =
        [[A2PrimaryButton alloc] initWithTitle:@"导入整合包"
                                         style:A2ButtonStyleSecondary];
    button.icon = [UIImage systemImageNamed:@"square.and.arrow.down"];
    // 与重置按钮同高，避免在矮屏机型把侧栏撑出可视区
    button.minHeight = 40;
    [button addTarget:self
               action:@selector(importLocalModPackTapped)
     forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)importLocalModPackTapped {
    // 已有一条在跑就忽略，避免叠出两个流程
    if (self.modPackImporter) return;

    A2ModPackImportCoordinator *coordinator =
        [[A2ModPackImportCoordinator alloc] initWithHost:self];
    self.modPackImporter = coordinator;

    __weak typeof(self) weakSelf = self;
    coordinator.onFinish = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.modPackImporter = nil;
    };
    [coordinator start];
}

#pragma mark - 筛选交互

/// 侧栏的平台切换。
/// 切换平台后分类体系不同，需要清空已选分类并重新拉取。
- (void)platformChanged {
    NSInteger idx = _platformControl.selectedSegmentIndex;
    if (idx < 0 || idx >= (NSInteger)_platformOptions.count) return;

    A2ContentPlatform picked = (A2ContentPlatform)_platformOptions[idx].integerValue;
    if (picked == _platform) return;

    _platform = picked;
    _source = [A2ContentSource sourceForPlatform:picked];
    [A2ContentSource setPreferredPlatform:picked];

    // 分类标识两家不通用，切换后清空
    [_selectedCategories removeAllObjects];
    [self clearCategoryChipSelection];

    [self loadCategories];
    [self reload];
}

- (void)resetAllFilters {
    [_selectedCategories removeAllObjects];
    _selectedLoader = nil;
    _selectedGameVersion = nil;
    _searchField.text = @"";
    [self clearCategoryChipSelection];
    [self styleSingleSelectStack:_loaderChipsStack value:nil];
    [self setGameVersionMenuExpanded:NO];
    [self updateGameVersionSelectorTitle];
    [self reload];
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
            self.gameVersionOptions = @[];
            [self rebuildGameVersionMenu];
            return;
        }
        NSMutableArray<NSString *> *out = [NSMutableArray array];
        for (A2RemoteVersion *version in versions) {
            if (![version.type isEqualToString:@"release"]) continue;
            [out addObject:version.versionID];
            // 下拉本身可滚动，只留一个兜底上限防止行数失控
            if (out.count >= 100) break;
        }
        self.gameVersionOptions = out;
        [self rebuildGameVersionMenu];
    }];
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
    [A2Log log:@"resource-search: 分类筛选变更 categories=%lu",
          (unsigned long)self.selectedCategories.count];
    [self reload];
}

- (void)loaderChipTapped:(A2FilterChip *)chip {
    NSString *value = chip.filterValue ?: @"";
    self.selectedLoader = value.length ? value : nil;
    [self styleSingleSelectStack:_loaderChipsStack value:value];
    [A2Log log:@"resource-search: 加载器筛选 = %@", value.length ? value : @"全部"];
    [self reload];
}

- (void)sortChipTapped:(A2FilterChip *)chip {
    A2ContentSortField field = (A2ContentSortField)chip.tag;
    self.sortField = field;
    [self styleSingleSelectStack:_sortChipsStack value:chip.filterValue];
    [A2Log log:@"resource-search: 排序 = %@", A2SortDisplayName(field)];
    [self reload];
}

#pragma mark - UI：结果列表

- (void)setupPaginationBar {
    _pageCache = [NSMutableDictionary dictionary];

    _paginationBar = [[A2PaginationBar alloc] initWithFrame:CGRectZero];
    __weak typeof(self) weakSelf = self;
    _paginationBar.onNavigate = ^(NSInteger page) {
        __strong typeof(weakSelf) self = weakSelf;
        [self loadPage:page];
    };
    [self.resultContainer addSubview:_paginationBar];

    [NSLayoutConstraint activateConstraints:@[
        [_paginationBar.leadingAnchor constraintEqualToAnchor:self.resultContainer.leadingAnchor],
        [_paginationBar.trailingAnchor constraintEqualToAnchor:self.resultContainer.trailingAnchor],
        [_paginationBar.bottomAnchor constraintEqualToAnchor:self.resultContainer.bottomAnchor],
    ]];
}

/// 加载指定页。命中缓存就直接用 —— 这是分页相对无限滚动的优势：
/// 回退时不必重新请求。
- (void)loadPage:(NSInteger)page {
    if (page < 1) return;

    NSArray<A2ContentItem *> *cached = _pageCache[@(page)];
    if (cached) {
        _items = [cached mutableCopy];
        [_tableView reloadData];
        [_paginationBar setCurrentPage:page totalPages:0];
        return;
    }

    // 未缓存则请求。offset = (page - 1) * pageSize
    _offset = (page - 1) * 20;
    [self loadMoreWithPage:page];
}

- (void)setupResultList {
    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [A2Typography caption];
    [self.resultContainer addSubview:_countLabel];

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
    [self.resultContainer addSubview:_tableView];

    _stateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stateLabel.font = [A2Typography body];
    _stateLabel.textAlignment = NSTextAlignmentCenter;
    _stateLabel.numberOfLines = 0;
    _stateLabel.hidden = YES;
    [self.resultContainer addSubview:_stateLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_countLabel.topAnchor constraintEqualToAnchor:self.resultContainer.topAnchor],
        [_countLabel.leadingAnchor constraintEqualToAnchor:self.resultContainer.leadingAnchor
                                                  constant:A2PageMargin],
        [_countLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.resultContainer.trailingAnchor
                                                             constant:-A2PageMargin],

        [_tableView.topAnchor constraintEqualToAnchor:_countLabel.bottomAnchor constant:A2SpaceS],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.resultContainer.leadingAnchor
                                                 constant:A2PageMargin],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.resultContainer.trailingAnchor
                                                  constant:-A2PageMargin],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.resultContainer.bottomAnchor],

        [_stateLabel.centerXAnchor constraintEqualToAnchor:self.resultContainer.centerXAnchor],
        [_stateLabel.centerYAnchor constraintEqualToAnchor:self.resultContainer.centerYAnchor],
        [_stateLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.resultContainer.leadingAnchor
                                                               constant:A2PageMargin],
        [_stateLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.resultContainer.trailingAnchor
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

/// 加载指定页（分页模式）。
/// 与 loadMore 的区别：这里【替换】结果而不是追加，且结果会写进缓存。
- (void)loadMoreWithPage:(NSInteger)page {
    if (_loading) return;
    if (!self.source.isAvailable) { [self updateStateView]; return; }
    if (![self.source supportsContentClass:self.contentClass]) {
        [self updateStateView]; return;
    }

    _loading = YES;
    [self updateStateView];

    A2ContentFilter *filter = [A2ContentFilter defaultFilter];
    filter.query = self.searchField.text.length ? self.searchField.text : nil;
    filter.gameVersion = self.selectedGameVersion;
    filter.loader = self.selectedLoader;
    filter.categories = self.selectedCategories.allObjects;
    filter.sortField = self.sortField;
    filter.offset = (page - 1) * 20;
    filter.limit = 20;

    __weak typeof(self) weakSelf = self;
    [self.source searchWithFilter:filter
                     contentClass:self.contentClass
                       completion:^(NSArray<A2ContentItem *> *results, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.loading = NO;

        if (error) {
            [self updateStateView];
            return;
        }

        // 结果不足一页说明到底了
        BOOL lastPage = (results.count < 20);
        self.paginationBar.isLastPage = lastPage;

        // 写缓存 —— 回退时不必重查
        self.pageCache[@(page)] = results ?: @[];

        self.items = [results mutableCopy] ?: [NSMutableArray array];
        [self.tableView reloadData];
        [self.paginationBar setCurrentPage:page totalPages:0];
        [self updateStateView];

        // 回到顶部
        [self.tableView setContentOffset:CGPointZero animated:NO];
    }];
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
    filter.query = self.searchField.text.length ? self.searchField.text : nil;
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
    // 把当前选中的游戏版本带进详情页，供「适配当前版本」区块使用。
    A2ResourceDetailViewController *vc =
        [[A2ResourceDetailViewController alloc] initWithProject:item
                                                   contentClass:self.contentClass
                                                    gameVersion:self.selectedGameVersion];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - UISearchBarDelegate



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

    // 游戏版本下拉：选择框 / 展开列表 / 每行选中态
    _gameVersionSelector.backgroundColor = t.cSurfaceContainerHighest;
    _gameVersionValueLabel.textColor = _selectedGameVersion.length > 0
        ? t.cOnSurface
        : t.cOnSurfaceVariant;
    _gameVersionChevron.tintColor = t.cOnSurfaceVariant;
    _gameVersionMenu.backgroundColor = t.cSurfaceContainerHigh;
    for (UIView *v in _gameVersionMenuStack.arrangedSubviews) {
        if (![v isKindOfClass:UIButton.class]) continue;
        UIButton *row = (UIButton *)v;
        BOOL rowIsAll = (row.tag == 0);
        BOOL selected = rowIsAll ? (_selectedGameVersion.length == 0)
                                 : [row.titleLabel.text isEqualToString:_selectedGameVersion ?: @""];
        row.backgroundColor = selected ? t.cSecondaryContainer : UIColor.clearColor;
        [row setTitleColor:(selected ? t.cOnSecondaryContainer : t.cOnSurface)
                  forState:UIControlStateNormal];
    }

    _countLabel.textColor = t.cOnSurfaceVariant;
    _stateLabel.textColor = t.cOnSurfaceVariant;

}

@end
