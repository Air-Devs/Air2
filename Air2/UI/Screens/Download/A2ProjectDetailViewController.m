//
//  A2ProjectDetailViewController.m
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
//  详情页只干三件事：讲清这是什么（头信息）、有哪些版本、下到哪。
//  无 icon 时首字母占位（列表页同款做法，不引入图片库）；
//  禁分发与空版本各走独立空态，不共用“加载失败”。
//

#import "A2ProjectDetailViewController.h"
#import "A2ContentSource.h"
#import "A2DownloadManifest.h"
#import "A2DownloadFavorites.h"
#import "A2VersionIsolation.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import "A2DownloadEngine.h"
#import "A2FilterChip.h"
#import "A2Log.h"

static NSString *const kVersionCellID = @"A2ProjectVersionCell";

@interface A2ProjectDetailViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) A2ContentItem *project;
@property (nonatomic, copy) NSString *targetSubdir;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) A2PrimaryButton *downloadButton;
@property (nonatomic, strong) UIButton *favoriteButton;
@property (nonatomic, strong) A2GlassCard *headerCard;
/// 远端拉回的全部版本（筛选前），更新检测与「下载最新版」都以它为准。
@property (nonatomic, strong) NSArray<A2ContentVersion *> *allVersions;
/// 当前展示（已按筛选条件过滤）的版本。
@property (nonatomic, strong) NSArray<A2ContentVersion *> *versions;
/// 文件级筛选：游戏版本 / 加载器。nil 表示不限。
@property (nonatomic, copy, nullable) NSString *selectedGameVersion;
@property (nonatomic, copy, nullable) NSString *selectedLoader;
@property (nonatomic, strong) UIStackView *filterStack;
@property (nonatomic, strong) UIStackView *gameVersionRow;
@property (nonatomic, strong) UIStackView *gameVersionChipStack;
@property (nonatomic, strong) UIStackView *loaderRow;
@property (nonatomic, strong) UIStackView *loaderChipStack;
@end

@implementation A2ProjectDetailViewController

- (instancetype)initWithProject:(A2ContentItem *)project targetSubdir:(NSString *)subdir {
    self = [super init];
    if (!self) return nil;
    _project = project;
    _targetSubdir = [subdir copy] ?: @"downloads";
    _allVersions = @[];
    _versions = @[];
    return self;
}

- (void)viewDidLoad {
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = _project.title;

    [self setupFavoriteButton];
    [self setupHeader];
    [self setupFilter];
    [self setupTable];
    [self reloadVersions];
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
    [A2Log log:@"download: %@收藏 %@", nowFavorite ? @"加入" : @"取消", _project.projectID];
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

#pragma mark - 头信息

- (void)setupHeader {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.cornerRadius = A2RadiusL;
    card.elevation = A2CardElevationLow;
    [self.plainContentView addSubview:card];
    _headerCard = card;

    // 首字母占位（无图库依赖；有 iconURL 也不拉，列表页同样处理）。
    UILabel *avatar = [[UILabel alloc] initWithFrame:CGRectZero];
    avatar.translatesAutoresizingMaskIntoConstraints = NO;
    avatar.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    avatar.textAlignment = NSTextAlignmentCenter;
    NSString *first = _project.title.length ? [_project.title substringToIndex:1] : @"?";
    avatar.text = first.uppercaseString;
    avatar.textColor = A2ThemeManager.shared.scheme.cPrimary;
    [card.contentView addSubview:avatar];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.text = _project.title;
    title.numberOfLines = 2;
    title.textColor = A2ThemeManager.shared.scheme.cOnSurface;
    [card.contentView addSubview:title];

    UILabel *meta = [[UILabel alloc] initWithFrame:CGRectZero];
    meta.translatesAutoresizingMaskIntoConstraints = NO;
    meta.font = [A2Typography caption];
    meta.numberOfLines = 0;
    meta.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    NSMutableArray<NSString *> *bits = [NSMutableArray array];
    if (_project.author.length) [bits addObject:_project.author];
    if (_project.downloadCount > 0) {
        [bits addObject:[NSString stringWithFormat:@"%@ 次下载", [self formatCount:_project.downloadCount]]];
    }
    if (_project.followCount > 0) {
        [bits addObject:[NSString stringWithFormat:@"%@ 关注", [self formatCount:_project.followCount]]];
    }
    meta.text = [bits componentsJoinedByString:@" · "];
    [card.contentView addSubview:meta];

    UILabel *summary = [[UILabel alloc] initWithFrame:CGRectZero];
    summary.translatesAutoresizingMaskIntoConstraints = NO;
    summary.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    summary.numberOfLines = 0;
    summary.text = _project.summary.length ? _project.summary : @"暂无简介";
    summary.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    [card.contentView addSubview:summary];

    _downloadButton = [[A2PrimaryButton alloc] initWithTitle:@"下载最新版"
                                                      style:A2ButtonStylePrimary];
    _downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_downloadButton addTarget:self
                        action:@selector(downloadLatest)
              forControlEvents:UIControlEventTouchUpInside];
    [card.contentView addSubview:_downloadButton];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor constant:A2SpaceS],
        [card.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                           constant:A2PageMargin],
        [card.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                            constant:-A2PageMargin],
        [avatar.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [avatar.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [avatar.widthAnchor constraintEqualToConstant:56],
        [avatar.heightAnchor constraintEqualToConstant:56],
        [title.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [title.leadingAnchor constraintEqualToAnchor:avatar.trailingAnchor constant:A2SpaceM],
        [title.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [meta.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [meta.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [meta.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [summary.topAnchor constraintEqualToAnchor:avatar.bottomAnchor constant:A2SpaceM],
        [summary.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [summary.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [_downloadButton.topAnchor constraintEqualToAnchor:summary.bottomAnchor constant:A2SpaceM],
        [_downloadButton.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [_downloadButton.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [_downloadButton.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [_downloadButton.heightAnchor constraintEqualToConstant:A2ButtonHeight],
    ]];
}

#pragma mark - 文件级筛选

/// 详情页两行 chip：游戏版本 / 加载器。选项从已拉回的版本聚合，客户端过滤 ——
/// 版本已全量在手，再发请求是浪费（ZL2 详情页同为本地筛选）。
- (void)setupFilter {
    _filterStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _filterStack.translatesAutoresizingMaskIntoConstraints = NO;
    _filterStack.axis = UILayoutConstraintAxisVertical;
    _filterStack.spacing = A2SpaceS;
    [self.plainContentView addSubview:_filterStack];

    // 两行各自可隐藏：整行 hidden 时外层竖直 stack 会连高度一起收掉，
    // 不占位（不能靠隐藏 _filterStack 本身，那只藏不缩）。
    _gameVersionChipStack = [self makeChipStack];
    _gameVersionRow = [self makeFilterRowWithLabel:@"游戏版本" chipsStack:_gameVersionChipStack];
    _gameVersionRow.hidden = YES;
    [_filterStack addArrangedSubview:_gameVersionRow];

    _loaderChipStack = [self makeChipStack];
    _loaderRow = [self makeFilterRowWithLabel:@"加载器" chipsStack:_loaderChipStack];
    _loaderRow.hidden = YES;
    [_filterStack addArrangedSubview:_loaderRow];

    [NSLayoutConstraint activateConstraints:@[
        [_filterStack.topAnchor constraintEqualToAnchor:_headerCard.bottomAnchor
                                               constant:A2SpaceM],
        [_filterStack.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                   constant:A2PageMargin],
        [_filterStack.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                    constant:-A2PageMargin],
    ]];
}

- (UIStackView *)makeChipStack {
    UIStackView *s = [[UIStackView alloc] initWithFrame:CGRectZero];
    s.axis = UILayoutConstraintAxisHorizontal;
    s.spacing = A2SpaceS;
    s.alignment = UIStackViewAlignmentCenter;
    return s;
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
        [scroll.heightAnchor constraintEqualToConstant:30],
    ]];

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
    // 版本号降序（新版在前）；数字感知比较，避免 1.9 > 1.21 的字符串误判
    NSArray<NSString *> *gameVersions =
        [gvSet.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [b compare:a options:NSNumericSearch];
        }];

    [self clearChipStack:_gameVersionChipStack];
    [self addChipToStack:_gameVersionChipStack title:@"全部" value:@""
                selected:(_selectedGameVersion.length == 0)
                  action:@selector(gameVersionChipTapped:)];
    for (NSString *g in gameVersions) {
        [self addChipToStack:_gameVersionChipStack title:g value:g
                    selected:[g isEqualToString:_selectedGameVersion]
                      action:@selector(gameVersionChipTapped:)];
    }

    [self clearChipStack:_loaderChipStack];
    [self addChipToStack:_loaderChipStack title:@"全部" value:@""
                selected:(_selectedLoader.length == 0)
                  action:@selector(loaderChipTapped:)];
    for (NSString *l in loaderSet) {
        [self addChipToStack:_loaderChipStack title:l value:l
                    selected:[l isEqualToString:_selectedLoader]
                      action:@selector(loaderChipTapped:)];
    }
    // 该维度没有任何可选项时整行隐去（资源包/光影/存档一般无加载器）
    _gameVersionRow.hidden = (gameVersions.count == 0);
    _loaderRow.hidden = (loaderSet.count == 0);
}

- (void)clearChipStack:(UIStackView *)stack {
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

/// 按当前筛选条件过滤已拉回的版本。
- (void)applyFilter {
    NSMutableArray<A2ContentVersion *> *out = [NSMutableArray array];
    for (A2ContentVersion *v in _allVersions) {
        if (_selectedGameVersion.length && ![v.gameVersions containsObject:_selectedGameVersion]) continue;
        if (_selectedLoader.length && ![v.loaders containsObject:_selectedLoader]) continue;
        [out addObject:v];
    }
    _versions = out;
    [_tableView reloadData];

    if (out.count == 0) {
        _emptyLabel.hidden = NO;
        _emptyLabel.text = @"没有符合筛选条件的版本";
    } else {
        _emptyLabel.hidden = YES;
    }
}

#pragma mark - 版本列表

- (void)setupTable {
    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.font = [A2Typography caption];
    _emptyLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.hidden = YES;
    [self.plainContentView addSubview:_emptyLabel];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.rowHeight = 64;
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, A2SpaceXXL, 0);
    [_tableView registerClass:UITableViewCell.class forCellReuseIdentifier:kVersionCellID];
    [self.plainContentView addSubview:_tableView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    _spinner.color = A2ThemeManager.shared.scheme.cPrimary;
    [self.plainContentView addSubview:_spinner];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:_filterStack.bottomAnchor constant:A2SpaceS],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_emptyLabel.centerXAnchor constraintEqualToAnchor:_tableView.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:_tableView.centerYAnchor
                                                  constant:-40],
        [_spinner.centerXAnchor constraintEqualToAnchor:_tableView.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:_tableView.centerYAnchor
                                               constant:-40],
    ]];
}

- (void)reloadVersions {
    // 禁分发的项目不请求版本列表，直接给专属空态（计划 P1 四空态之一）。
    if (!_project.downloadable) {
        _allVersions = @[];
        _versions = @[];
        [_tableView reloadData];
        _gameVersionRow.hidden = YES;
        _loaderRow.hidden = YES;
        _emptyLabel.hidden = NO;
        _emptyLabel.text = @"该作者禁止第三方分发，请前往官网下载";
        _downloadButton.enabled = NO;
        return;
    }
    [_spinner startAnimating];
    _emptyLabel.hidden = YES;
    [[A2ContentSource sourceForPlatform:_project.platform] versionsForProject:_project.projectID
                                                                 gameVersion:nil
                                                                      loader:nil
                                                                  completion:^(NSArray<A2ContentVersion *> *versions, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            if (error || versions.count == 0) {
                self.allVersions = @[];
                self.versions = @[];
                [self.tableView reloadData];
                self.gameVersionRow.hidden = YES;
                self.loaderRow.hidden = YES;
                self.emptyLabel.hidden = NO;
                self.emptyLabel.text = error ? [NSString stringWithFormat:@"加载失败：%@",
                                                error.localizedDescription] : @"没有可用的版本";
                self.downloadButton.enabled = NO;
                return;
            }
            self.allVersions = versions;
            [self rebuildFilterChips];
            [self applyFilter];
            self.downloadButton.enabled = YES;
            [self refreshUpdateState];
        });
    }];
}

// 更新提示：装过该项目、且最新版没装 → 主按钮改“更新到 x”。
// 不在列表页做行级提示：那需要每行一次版本请求（N+1），
// 又贵又抖；详情页版本已拉到手，对比零成本。
// 用 allVersions（未筛选）判最新版，避免用户筛了旧版本就误判成「有新版本」。
- (void)refreshUpdateState {
    A2ContentVersion *latest = _allVersions.firstObject;
    if (!latest) return;
    BOOL installedProject = [[A2DownloadManifest shared] isProjectInstalled:_project.projectID];
    BOOL latestInstalled = [[A2DownloadManifest shared] isVersionInstalled:_project.projectID
                                                                versionID:latest.versionID];
    if (installedProject && !latestInstalled) {
        _downloadButton.title = [NSString stringWithFormat:@"更新到 %@",
                                 latest.versionNumber];
    } else {
        _downloadButton.title = @"下载最新版";
    }
}

#pragma mark - 下载（从列表页搬家，逻辑逐行未改）

- (void)downloadLatest {
    // 始终下最新版，与筛选条件无关
    A2ContentVersion *v = _allVersions.firstObject;
    if (!v) {
        [A2Toast show:@"没有可用的版本" inView:self.view];
        return;
    }
    [self downloadVersion:v];
}

- (void)downloadVersion:(A2ContentVersion *)version {
    if (version.candidateURLs.count == 0) {
        [A2Toast show:@"此版本没有可下载的文件（可能作者禁止第三方分发）"
               inView:self.view];
        return;
    }

    NSString *fileName = version.fileName.length ? version.fileName
        : [NSString stringWithFormat:@"%@-%@.jar", _project.projectID, version.versionNumber];
    // 落盘路径走唯一出口（A2GamePath），View 不手拼 Documents 路径。
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
    // candidateURLs 里已含镜像候选（按设置排序），下载引擎会依次尝试
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *u in version.candidateURLs) {
        NSURL *url = [NSURL URLWithString:u];
        if (url) [urls addObject:url];
    }
    req.candidateURLs = urls;
    req.destinationPath = dest;
    req.expectedSize = version.fileSize;
    req.allowZipFallbackCheck = YES;

    [[A2DownloadEngine sharedClient] startRequest:req
        progress:nil
           speed:nil
      completion:^(BOOL success, NSError *error) {
        // 落盘成功才记清单（失败不记，避免角标撒谎）。
        if (success) {
            [[A2DownloadManifest shared] recordDownloadWithProjectID:self->_project.projectID
                                                           versionID:version.versionID
                                                            fileName:fileName
                                                              subdir:self->_targetSubdir];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [A2Toast show:[NSString stringWithFormat:@"已下载 %@", fileName] inView:self.view];
            } else {
                [A2Toast show:[NSString stringWithFormat:@"下载失败：%@", error.localizedDescription]
                       inView:self.view];
            }
        });
    }];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _versions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kVersionCellID
                                                           forIndexPath:indexPath];
    A2ContentVersion *v = _versions[indexPath.row];
    cell.backgroundColor = UIColor.clearColor;
    cell.textLabel.text = v.versionNumber;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.textLabel.textColor = A2ThemeManager.shared.scheme.cOnSurface;
    NSMutableArray<NSString *> *bits = [NSMutableArray array];
    if (indexPath.row == 0) [bits addObject:@"最新"];
    if (v.loaders.count) [bits addObject:v.loaders.firstObject];
    if (v.fileSize > 0) [bits addObject:[self displaySize:v.fileSize]];
    if (v.gameVersions.count) [bits addObject:[v.gameVersions componentsJoinedByString:@", "]];
    cell.detailTextLabel.text = [bits componentsJoinedByString:@" · "];
    cell.detailTextLabel.font = [A2Typography caption];
    cell.detailTextLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    // 装过的版本打勾（按 versionID 查清单，文件被手删则不算装过）。
    BOOL installed = [[A2DownloadManifest shared] isVersionInstalled:_project.projectID
                                                           versionID:v.versionID];
    cell.accessoryType = installed ? UITableViewCellAccessoryCheckmark
                                   : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self downloadVersion:_versions[indexPath.row]];
}

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
