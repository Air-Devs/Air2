//
//  A2DownloadListViewController.m
//  Air2
//
//  资源列表页。带搜索栏、筛选条、结果计数。
//  列表用 UITableView 而非 StackView —— 数据量大时需要复用。
//

#import "A2DownloadListViewController.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2DownloadListViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIView *filterBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, NSString *> *> *items;
@end

@implementation A2DownloadListViewController

- (void)viewDidLoad {
    self.usesScrollContent = NO;
    [super viewDidLoad];

    self.pageTitle = [self titleForCategory];
    [self setupSearchBar];
    [self setupFilterBar];
    [self setupTable];
    [self loadSampleData];
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

#pragma mark - 搜索

- (void)setupSearchBar {
    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    _searchBar.placeholder = @"搜索…";
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.tintColor = A2ThemeManager.shared.scheme.primary;
    _searchBar.backgroundImage = [UIImage new];

    for (UIView *v in _searchBar.subviews) {
        for (UIView *sv in v.subviews) {
            if ([sv isKindOfClass:UITextField.class]) {
                UITextField *tf = (UITextField *)sv;
                tf.textColor = UIColor.whiteColor;
                tf.attributedPlaceholder =
                    [[NSAttributedString alloc] initWithString:@"搜索…"
                                                    attributes:@{NSForegroundColorAttributeName:
                                                                     [UIColor colorWithWhite:1.0 alpha:0.4]}];
            }
        }
    }

    [self.plainContentView addSubview:_searchBar];
}

#pragma mark - 筛选条

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
        UIButton *chip = [self makeChip:filters[i] selected:(i == 0)];
        [stack addArrangedSubview:chip];
    }

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:_filterBar.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:_filterBar.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:_filterBar.leadingAnchor constant:A2PageMargin],
        [scroll.trailingAnchor constraintEqualToAnchor:_filterBar.trailingAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-A2PageMargin],
        [stack.heightAnchor constraintEqualToAnchor:scroll.heightAnchor],
    ]];

    [self.plainContentView addSubview:_filterBar];
}

- (NSArray<NSString *> *)filtersForCategory {
    switch (self.category) {
        case A2DownloadCategoryGame:
            return @[@"全部", @"正式版", @"快照", @"旧版"];
        case A2DownloadCategoryMod:
            return @[@"热度", @"最新", @"Fabric", @"Forge", @"NeoForge"];
        default:
            return @[@"热度", @"最新", @"最近更新", @"下载量"];
    }
}

- (UIButton *)makeChip:(NSString *)title selected:(BOOL)selected {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b.layer.cornerRadius = 15;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
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
    chip.backgroundColor = selected ? t.primary : [UIColor colorWithWhite:1.0 alpha:0.12];
    [chip setTitleColor:(selected ? UIColor.blackColor : [UIColor colorWithWhite:1.0 alpha:0.82])
               forState:UIControlStateNormal];
}

- (void)chipTapped:(UIButton *)sender {
    UIView *stack = sender.superview;
    for (UIView *v in stack.subviews) {
        if (![v isKindOfClass:UIButton.class]) continue;
        [self styleChip:(UIButton *)v selected:((UIButton *)v == sender)];
    }
    // 弹簧回弹：放大再收回，给选中有个明确的手感
    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationFast);
    [a addAnimations:^{ sender.transform = CGAffineTransformMakeScale(1.06, 1.06); }];
    [a addCompletion:^(UIViewAnimatingPosition pos) {
        UIViewPropertyAnimator *b = A2SpringAnimator(A2AnimDurationFast);
        [b addAnimations:^{ sender.transform = CGAffineTransformIdentity; }];
        [b startAnimation];
    }];
    [a startAnimation];
}

#pragma mark - 列表

- (void)setupTable {
    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [A2Typography caption];
    _countLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    [self.plainContentView addSubview:_countLabel];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.rowHeight = 76;
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, A2SpaceXXL, 0);
    [_tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"cell"];
    [self.plainContentView addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_searchBar.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor constant:A2SpaceS],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor constant:-A2SpaceS],
        [_searchBar.heightAnchor constraintEqualToConstant:44],

        [_filterBar.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor],
        [_filterBar.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor],
        [_filterBar.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],
        [_filterBar.heightAnchor constraintEqualToConstant:36],

        [_countLabel.topAnchor constraintEqualToAnchor:_filterBar.bottomAnchor constant:A2SpaceS],
        [_countLabel.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor constant:A2PageMargin],

        [_tableView.topAnchor constraintEqualToAnchor:_countLabel.bottomAnchor constant:A2SpaceS],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
    ]];
}

- (void)loadSampleData {
    _items = @[
        @{@"title": @"Sodium",       @"sub": @"渲染优化 · 1200 万下载", @"tag": @"Fabric"},
        @{@"title": @"Lithium",      @"sub": @"服务端优化 · 890 万下载",  @"tag": @"Fabric"},
        @{@"title": @"Iris Shaders", @"sub": @"光影加载器 · 450 万下载",  @"tag": @"Fabric"},
        @{@"title": @"JEI",          @"sub": @"物品查询 · 380 万下载",    @"tag": @"Forge"},
        @{@"title": @"Create",       @"sub": @"机械动力 · 320 万下载",    @"tag": @"Forge"},
    ];
    _countLabel.text = [NSString stringWithFormat:@"共 %lu 项", (unsigned long)_items.count];
    [_tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    for (UIView *v in cell.contentView.subviews) { [v removeFromSuperview]; }

    NSDictionary<NSString *, NSString *> *item = _items[indexPath.row];

    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusL;
    card.tappable = YES;
    card.contentInsets = UIEdgeInsetsMake(A2SpaceM, A2SpaceM, A2SpaceM, A2SpaceM);
    __weak typeof(self) weakSelf = self;
    card.onTap = ^{
        [A2Toast show:[NSString stringWithFormat:@"查看 %@", item[@"title"]] inView:weakSelf.view];
    };
    [cell.contentView addSubview:card];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = item[@"title"];
    title.font = [A2Typography titleCard];
    title.textColor = t.onSurface;

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectZero];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    sub.text = item[@"sub"];
    sub.font = [A2Typography caption];
    sub.textColor = t.onSurfaceVariant;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[title, sub]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 3;

    UILabel *tag = [[UILabel alloc] initWithFrame:CGRectZero];
    tag.translatesAutoresizingMaskIntoConstraints = NO;
    tag.text = item[@"tag"];
    tag.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    tag.textColor = t.primary;
    tag.backgroundColor = [t.primary colorWithAlphaComponent:0.16];
    tag.textAlignment = NSTextAlignmentCenter;
    tag.layer.cornerRadius = 8;
    tag.layer.cornerCurve = kCACornerCurveContinuous;
    tag.clipsToBounds = YES;

    [card.contentView addSubview:textStack];
    [card.contentView addSubview:tag];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:3],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-3],
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:A2PageMargin],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-A2PageMargin],

        [textStack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [textStack.centerYAnchor constraintEqualToAnchor:card.contentView.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:tag.leadingAnchor constant:-A2SpaceS],

        [tag.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [tag.centerYAnchor constraintEqualToAnchor:card.contentView.centerYAnchor],
        [tag.widthAnchor constraintGreaterThanOrEqualToConstant:52],
        [tag.heightAnchor constraintEqualToConstant:22],
    ]];

    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - UISearchBarDelegate

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [A2Toast show:[NSString stringWithFormat:@"搜索：%@", searchBar.text] inView:self.view];
}

@end
