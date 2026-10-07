//
//  A2VersionListViewController.m
//  Air2
//
//  版本管理 —— 左侧游戏目录 + 右侧版本列表。
//
//  结构对齐 ZL2 的 VersionsManageScreen：
//    ┌──────────┬──────────────────────────────────────┐
//    │ 默认目录  │  ○ [1] 1.21.5-fabric    📌 ⚙️ ⋯      │
//    │ 自定义目录│     Fabric 0.16.10 · Java 21          │
//    │          │  ○ [1] 1.20.1-forge     📌 ⚙️ ⋯      │
//    │          │     Forge 47.2.0                      │
//    │ [+ 添加] │                                       │
//    │ [清理]   │                                       │
//    └──────────┴──────────────────────────────────────┘
//
//  列表行间距 12，页面内边距 12。
//

#import "A2VersionListViewController.h"
#import "A2VersionSettingsViewController.h"
#import "A2VersionManager.h"
#import "A2VersionRowView.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

/// 游戏目录项
@interface A2GamePathRow : UIControl
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *pathLabel;
@property (nonatomic, assign, getter=isCurrent) BOOL current;
- (instancetype)initWithTitle:(NSString *)title path:(NSString *)path;
- (void)applyTheme;
@end

@implementation A2GamePathRow

- (instancetype)initWithTitle:(NSString *)title path:(NSString *)path {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = A2RadiusM;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _titleLabel.text = title;
    _titleLabel.numberOfLines = 1;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.8;

    _pathLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _pathLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _pathLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _pathLabel.text = path;
    _pathLabel.numberOfLines = 2;
    _pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    [self addSubview:_titleLabel];
    [self addSubview:_pathLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:A2SpaceS],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceM],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceM],

        [_pathLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_pathLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceM],
        [_pathLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceM],
        [_pathLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-A2SpaceS],
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

- (void)setCurrent:(BOOL)current {
    _current = current;
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    self.backgroundColor = self.isCurrent ? t.cSecondaryContainer : t.cSurfaceContainerLow;
    _titleLabel.textColor = self.isCurrent ? t.cOnSecondaryContainer : t.cOnSurface;
    _pathLabel.textColor = self.isCurrent
        ? [t.cOnSecondaryContainer colorWithAlphaComponent:0.75]
        : t.cOnSurfaceVariant;
}

@end

#pragma mark - 版本管理页

@interface A2VersionListViewController ()
@property (nonatomic, strong) UIScrollView *pathScroll;
@property (nonatomic, strong) UIStackView *pathStack;
@property (nonatomic, strong) UIScrollView *listScroll;
@property (nonatomic, strong) UIStackView *listStack;
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *versions;
@property (nonatomic, strong) NSMutableArray<A2VersionRowView *> *rowViews;
@end

@implementation A2VersionListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.usesScrollContent = NO;   // 自己管布局
    self.pageTitle = @"版本管理";
    _rowViews = [NSMutableArray array];

    __weak typeof(self) weakSelf = self;
    [self addTrailingButtonWithSymbol:@"plus" action:^{
        __strong typeof(weakSelf) self = weakSelf;
        [A2Toast show:@"安装新版本" inView:self.view];
    }];

    [self loadVersions];
    [self setupLayout];
    [self buildPathList];
    [self buildVersionList];
}

/// 从 A2VersionManager 读真实数据。
/// 之前这里是硬编码的示例数据 —— 现在接上了真实的版本扫描。
- (void)loadVersions {
    A2VersionManager *mgr = A2VersionManager.shared;
    NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];

    for (A2Version *v in mgr.versions) {
        // meta 文案：加载器 + 隔离状态
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (v.loaderInfo.length) [parts addObject:v.loaderInfo];
        // 用解析后的实际状态，而不是原始的 SettingState ——
        // FOLLOW_GLOBAL 时要显示「全局设置决定的结果」
        if (v.isolation.isolationType == A2SettingStateFollowGlobal) {
            [parts addObject:(v.isIsolationEnabled ? @"隔离·跟随全局" : @"共用·跟随全局")];
        } else {
            [parts addObject:(v.isIsolationEnabled ? @"隔离开启" : @"共用目录")];
        }

        [out addObject:@{
            @"name": v.name,
            @"meta": [parts componentsJoinedByString:@" · "],
            @"current": @(mgr.currentVersion == v),
            @"pinned": @(v.isolation.isPinned),
            @"valid": @(v.isValid),
            @"model": v,
        }];
    }

    _versions = out;
}

- (void)setupLayout {
    // ---- 左侧目录 ----
    _pathScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _pathScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _pathScroll.showsVerticalScrollIndicator = NO;

    _pathStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _pathStack.translatesAutoresizingMaskIntoConstraints = NO;
    _pathStack.axis = UILayoutConstraintAxisVertical;
    _pathStack.spacing = A2SpaceS;
    [_pathScroll addSubview:_pathStack];

    // ---- 右侧列表 ----
    _listScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _listScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _listScroll.showsVerticalScrollIndicator = NO;

    _listStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _listStack.translatesAutoresizingMaskIntoConstraints = NO;
    _listStack.axis = UILayoutConstraintAxisVertical;
    _listStack.spacing = A2SpaceM;   // 行间距 12
    [_listScroll addSubview:_listStack];

    [self.plainContentView addSubview:_pathScroll];
    [self.plainContentView addSubview:_listScroll];

    [NSLayoutConstraint activateConstraints:@[
        // 左侧固定 200
        [_pathScroll.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_pathScroll.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_pathScroll.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                  constant:A2SpaceM],
        [_pathScroll.widthAnchor constraintEqualToConstant:200],

        [_pathStack.topAnchor constraintEqualToAnchor:_pathScroll.topAnchor],
        [_pathStack.bottomAnchor constraintEqualToAnchor:_pathScroll.bottomAnchor],
        [_pathStack.leadingAnchor constraintEqualToAnchor:_pathScroll.leadingAnchor],
        [_pathStack.trailingAnchor constraintEqualToAnchor:_pathScroll.trailingAnchor],
        [_pathStack.widthAnchor constraintEqualToAnchor:_pathScroll.widthAnchor],

        // 右侧列表
        [_listScroll.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_listScroll.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_listScroll.leadingAnchor constraintEqualToAnchor:_pathScroll.trailingAnchor
                                                  constant:A2SpaceM],
        [_listScroll.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                   constant:-A2SpaceL],

        [_listStack.topAnchor constraintEqualToAnchor:_listScroll.topAnchor],
        [_listStack.bottomAnchor constraintEqualToAnchor:_listScroll.bottomAnchor],
        [_listStack.leadingAnchor constraintEqualToAnchor:_listScroll.leadingAnchor],
        [_listStack.trailingAnchor constraintEqualToAnchor:_listScroll.trailingAnchor],
        [_listStack.widthAnchor constraintEqualToAnchor:_listScroll.widthAnchor],
    ]];
}

- (void)buildPathList {
    NSArray<NSArray<NSString *> *> *paths = @[
        @[@"默认目录", @"Documents/.minecraft"],
        @[@"外置存储", @"/var/mobile/Air2/games"],
    ];

    for (NSUInteger i = 0; i < paths.count; i++) {
        A2GamePathRow *row = [[A2GamePathRow alloc] initWithTitle:paths[i][0] path:paths[i][1]];
        row.current = (i == 0);
        __weak typeof(self) weakSelf = self;
        [row addAction:[UIAction actionWithHandler:^(UIAction *action) {
            [weakSelf refreshPathSelection:action.sender];
        }] forControlEvents:UIControlEventTouchUpInside];
        [_pathStack addArrangedSubview:row];
    }

    // 底部两个操作按钮
    [_pathStack addArrangedSubview:[self makeSpacer:A2SpaceL]];

    A2PrimaryButton *addBtn = [[A2PrimaryButton alloc] initWithTitle:@"添加目录"
                                                             style:A2ButtonStyleSecondary];
    addBtn.minHeight = 44;
    [addBtn addTarget:self action:@selector(addPath) forControlEvents:UIControlEventTouchUpInside];
    [_pathStack addArrangedSubview:addBtn];

    A2PrimaryButton *cleanBtn = [[A2PrimaryButton alloc] initWithTitle:@"清理缓存"
                                                               style:A2ButtonStyleSecondary];
    cleanBtn.minHeight = 44;
    [cleanBtn addTarget:self action:@selector(cleanup) forControlEvents:UIControlEventTouchUpInside];
    [_pathStack addArrangedSubview:cleanBtn];

    // 撑起剩余空间
    UIView *filler = [[UIView alloc] initWithFrame:CGRectZero];
    filler.translatesAutoresizingMaskIntoConstraints = NO;
    [filler setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisVertical];
    [_pathStack addArrangedSubview:filler];
}

- (UIView *)makeSpacer:(CGFloat)height {
    UIView *v = [[UIView alloc] initWithFrame:CGRectZero];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [v.heightAnchor constraintEqualToConstant:height].active = YES;
    return v;
}

- (void)refreshPathSelection:(UIView *)sender {
    for (UIView *v in _pathStack.arrangedSubviews) {
        if ([v isKindOfClass:A2GamePathRow.class]) {
            ((A2GamePathRow *)v).current = (v == sender);
        }
    }
}

- (void)buildVersionList {
    for (NSDictionary<NSString *, id> *v in _versions) {
        A2VersionRowView *row = [[A2VersionRowView alloc] initWithVersionName:v[@"name"]
                                                                        meta:v[@"meta"]];
        row.current = [v[@"current"] boolValue];
        row.pinned = [v[@"pinned"] boolValue];
        row.valid = [v[@"valid"] boolValue];

        __weak typeof(self) weakSelf = self;
        __weak A2VersionRowView *weakRow = row;
        NSString *name = v[@"name"];
        NSString *meta = v[@"meta"];

        row.onSelect = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self selectVersion:weakRow];
        };
        A2Version *model = v[@"model"];
        row.onPin = ^{
            __strong typeof(weakSelf) self = weakSelf;
            BOOL newValue = !weakRow.isPinned;
            weakRow.pinned = newValue;

            // 真实写入版本的隔离配置
            model.isolation.pinned = newValue;
            [model saveConfig];

            [A2Toast show:(newValue ? @"已置顶" : @"已取消置顶") inView:self.view];
        };
        row.onSettings = ^{
            __strong typeof(weakSelf) self = weakSelf;
            A2VersionSettingsViewController *vc =
                [[A2VersionSettingsViewController alloc] initWithVersionName:name];
            [self.navigationController pushViewController:vc animated:YES];
        };
        row.onMore = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self showMoreMenuForName:name meta:meta fromView:weakRow];
        };

        [_rowViews addObject:row];
        [_listStack addArrangedSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:_listStack.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:_listStack.trailingAnchor],
        ]];
    }
}

/// 切换当前版本。
/// 无效版本不允许选中（缺 jar 或 json 的版本启动必然失败）。
- (void)selectVersion:(A2VersionRowView *)selected {
    NSInteger index = [_rowViews indexOfObject:selected];
    if (index == NSNotFound || index >= (NSInteger)_versions.count) return;

    A2Version *model = _versions[index][@"model"];
    if (!model.isValid) {
        [A2Toast show:@"此版本文件不完整，无法选择" inView:self.view];
        return;
    }

    if (![A2VersionManager.shared selectCurrentVersion:model]) return;

    for (A2VersionRowView *r in _rowViews) {
        r.current = (r == selected);
    }
    [A2Toast show:[NSString stringWithFormat:@"已切换到 %@", model.name] inView:self.view];
}

- (void)showMoreMenuForName:(NSString *)name meta:(NSString *)meta fromView:(UIView *)source {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:name
                                            message:meta
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSArray<NSString *> *> *actions = @[
        @[@"重命名", @"square.and.pencil"],
        @[@"复制", @"doc.on.doc"],
        @[@"导出为整合包", @"square.and.arrow.up"],
        @[@"删除", @"trash"],
    ];
    for (NSArray<NSString *> *a in actions) {
        BOOL destructive = [a[0] isEqualToString:@"删除"];
        [sheet addAction:[UIAlertAction actionWithTitle:a[0]
                                                 style:(destructive ? UIAlertActionStyleDestructive
                                                                    : UIAlertActionStyleDefault)
                                               handler:^(UIAlertAction *action) {
            [A2Toast show:[NSString stringWithFormat:@"%@：%@", a[0], name] inView:self.view];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    sheet.popoverPresentationController.sourceView = source;
    sheet.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 动作

- (void)addPath {
    [A2Toast show:@"选择游戏目录" inView:self.view];
}

- (void)cleanup {
    [A2Toast show:@"清理未使用的游戏文件" inView:self.view];
}

@end
