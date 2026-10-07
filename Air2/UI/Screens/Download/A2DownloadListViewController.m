//
//  A2DownloadListViewController.m
//  Air2
//
//  资源列表 —— 接真实 Modrinth API。
//
//  搜索 + 筛选 + 分页，结果项显示项目名、说明、下载量、加载器标签。
//

#import "A2DownloadListViewController.h"
#import "A2GlassCard.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2ContentSource.h"
#import "A2DownloadEngine.h"

static NSString *const kCellID = @"A2DownloadCell";

#pragma mark - 列表项

@interface A2DownloadListCell : UITableViewCell
@property (nonatomic, strong) A2GlassCard *card;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *tagLabel;
@property (nonatomic, strong) UILabel *statsLabel;
- (void)configureWithProject:(A2ModrinthProject *)project;
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
    _subtitleLabel.text = project.projectDescription;

    // 下载量用易读格式
    _statsLabel.text = [NSString stringWithFormat:@"%@ 次下载 · %@ 关注",
                        [self formatCount:project.downloads],
                        [self formatCount:project.followers]];

    // 标签取前两个分类
    NSArray *cats = project.categories;
    if (cats.count > 0) {
        NSString *tag = cats.firstObject;
        _tagLabel.text = [tag capitalizedString];
        _tagLabel.hidden = NO;
    } else {
        _tagLabel.hidden = YES;
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
@property (nonatomic, copy) NSString *gameVersionFilter;
@property (nonatomic, copy) NSString *loaderFilter;
@end

@implementation A2DownloadListViewController

- (void)viewDidLoad {
    self.usesScrollContent = NO;
    [super viewDidLoad];

    _items = [NSMutableArray array];
    _offset = 0;
    self.pageTitle = [self titleForCategory];

    [self setupSearchBar];
    [self setupFilterBar];
    [self setupTable];

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

- (NSInteger)categoryIndex {
    switch (self.category) {
        case A2DownloadCategoryModpack:      return 1;
        case A2DownloadCategoryResourcePack: return 2;
        case A2DownloadCategoryShader:       return 3;
        case A2DownloadCategoryWorld:        return 4;
        case A2DownloadCategoryMod:
        case A2DownloadCategoryGame:
        default:                             return 0;
    }
}

- (A2ModrinthProjectType)projectType {
    switch (self.category) {
        case A2DownloadCategoryShader:       return A2ModrinthProjectTypeShader;
        case A2DownloadCategoryResourcePack: return A2ModrinthProjectTypeResourcePack;
        case A2DownloadCategoryModpack:      return A2ModrinthProjectTypeModpack;
        case A2DownloadCategoryWorld:        return A2ModrinthProjectTypeDatapack;
        case A2DownloadCategoryMod:          return A2ModrinthProjectTypeMod;
        case A2DownloadCategoryGame:
        default:                             return A2ModrinthProjectTypeMod;
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

    NSArray<NSString *> *filters = [self filtersForCategory];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = A2SpaceS;
    [scroll addSubview:stack];

    for (NSUInteger i = 0; i < filters.count; i++) {
        UIButton *chip = [self makeChip:filters[i] selected:(i == 0) tag:i];
        [stack addArrangedSubview:chip];
    }

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
    _platformSwitch.selectedSegmentIndex = 0;
    [_platformSwitch addTarget:self action:@selector(platformChanged)
              forControlEvents:UIControlEventValueChanged];
    [self.plainContentView addSubview:_platformSwitch];

    [NSLayoutConstraint activateConstraints:@[
        [_platformSwitch.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor],
        [_platformSwitch.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                      constant:A2PageMargin],
        [_platformSwitch.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                       constant:-A2PageMargin],
        [_platformSwitch.heightAnchor constraintEqualToConstant:32];
    ]];
}

- (void)platformChanged {
    self.platform = (_platformSwitch.selectedSegmentIndex == 0)
        ? A2ContentPlatformModrinth : A2ContentPlatformCurseForge;
    self.source = [A2ContentSource sourceForPlatform:self.platform];

    // 切到 CurseForge 但没配 Key 时给出明确提示
    if (!self.source.isAvailable) {
        [A2Toast show:self.source.unavailableReason ?: @"该资源源不可用" inView:self.view];
    }
    [self reload];
}

/// 筛选条：加载器 + 游戏版本
- (NSArray<NSString *> *)filtersForCategory {
    switch (self.category) {
        case A2DownloadCategoryMod:
        case A2DownloadCategoryModpack:
            return @[@"全部", @"Fabric", @"Forge", @"NeoForge", @"Quilt"];
        case A2DownloadCategoryShader:
        case A2DownloadCategoryResourcePack:
        case A2DownloadCategoryWorld:
        default:
            return @[@"全部", @"1.21.5", @"1.21.1", @"1.20.1", @"1.19.2"];
    }
}

/// 该分类的筛选维度说明
- (NSString *)filterDimensionName {
    switch (self.category) {
        case A2DownloadCategoryMod:
        case A2DownloadCategoryModpack:
            return @"加载器";
        default:
            return @"游戏版本";
    }
}

- (UIButton *)makeChip:(NSString *)title selected:(BOOL)selected tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b.layer.cornerRadius = 15;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
    b.tag = tag;
    [NSLayoutConstraint activateConstraints:@[
        [b.heightAnchor constraintEqualToConstant:30],
    ]];
    [self styleChip:b selected:selected];
    [b addAction:[UIAction actionWithHandler:^(UIAction *action) {
        [self chipTapped:(UIButton *)action.sender];
    }] forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)styleChip:(UIButton *)chip selected:(BOOL)selected {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    chip.backgroundColor = selected ? t.cPrimary : t.cSurfaceContainerHigh;
    [chip setTitleColor:(selected ? t.cOnPrimary : t.cOnSurfaceVariant)
               forState:UIControlStateNormal];
}

- (void)chipTapped:(UIButton *)sender {
    UIView *stack = sender.superview;
    for (UIView *v in stack.subviews) {
        if (![v isKindOfClass:UIButton.class]) continue;
        [self styleChip:(UIButton *)v selected:((UIButton *)v == sender)];
    }

    // 按分类更新对应维度的筛选条件
    NSString *title = [sender titleForState:UIControlStateNormal];
    BOOL isAll = [title isEqualToString:@"全部"];

    switch (self.category) {
        case A2DownloadCategoryMod:
        case A2DownloadCategoryModpack:
            self.loaderFilter = isAll ? nil : title.lowercaseString;
            break;
        default:
            self.gameVersionFilter = isAll ? nil : title;
            break;
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
    [self.source searchWithQuery:_searchBar.text
                        category:[self categoryIndex]
                     gameVersion:_gameVersionFilter
                          loader:_loaderFilter
                          offset:_offset
                           limit:20
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

    if (!p.downloadable) {
        [A2Toast show:@"该作者禁止第三方分发，请前往官网下载" inView:self.view];
        return;
    }

    // 显示可下载的版本列表
    __weak typeof(self) weakSelf = self;
    [[A2ContentSource sourceForPlatform:p.platform] versionsForProject:p.projectID
                                                          gameVersion:_gameVersionFilter
                                                               loader:_loaderFilter
                                                           completion:^(NSArray<A2ContentVersion *> *versions, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error || versions.count == 0) {
            [A2Toast show:@"没有可用的版本" inView:self.view];
            return;
        }
        [self showVersionPicker:versions project:p];
    }];
}

- (void)showVersionPicker:(NSArray<A2ContentVersion *> *)versions project:(A2ContentItem *)project {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:project.title
                                            message:@"选择要下载的版本"
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    NSInteger max = MIN(10, (NSInteger)versions.count);
    for (NSInteger i = 0; i < max; i++) {
        A2ContentVersion *v = versions[i];
        NSString *title = [NSString stringWithFormat:@"%@%@", v.versionNumber,
                           v.loaders.count ? [NSString stringWithFormat:@" · %@", v.loaders.firstObject] : @""];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            [self downloadVersion:v project:project];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)downloadVersion:(A2ContentVersion *)version project:(A2ContentItem *)project {
    if (version.downloadURL.length == 0) {
        [A2Toast show:@"此版本没有可下载的文件" inView:self.view];
        return;
    }

    // 目标目录：按资源类型落盘
    NSString *subdir = [self directoryNameForCategory];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [[[docs stringByAppendingPathComponent:@".minecraft"]
                      stringByAppendingPathComponent:subdir] copy];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *fileName = version.fileName.length ? version.fileName
        : [NSString stringWithFormat:@"%@-%@.jar", project.slug, version.versionNumber];
    NSString *dest = [dir stringByAppendingPathComponent:fileName];

    [A2Toast show:[NSString stringWithFormat:@"开始下载 %@", fileName] inView:self.view];

    A2DownloadRequest *req = [A2DownloadRequest new];
    req.candidateURLs = @[[NSURL URLWithString:version.downloadURL]];
    req.destinationPath = dest;
    req.expectedSize = version.fileSize;
    req.allowZipFallbackCheck = YES;

    [[A2DownloadEngine sharedClient] startRequest:req
        progress:nil
           speed:nil
      completion:^(BOOL success, NSError *error) {
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

- (NSString *)directoryNameForCategory {
    switch (self.category) {
        case A2DownloadCategoryMod:          return @"mods";
        case A2DownloadCategoryShader:       return @"shaderpacks";
        case A2DownloadCategoryResourcePack: return @"resourcepacks";
        case A2DownloadCategoryWorld:        return @"saves";
        default:                             return @"downloads";
    }
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
