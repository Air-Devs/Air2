//
//  A2VersionListViewController.m
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
//  版本管理 —— 左侧游戏目录 + 右侧版本列表。
//
//  布局（左侧目录 + 右侧列表）：
//    ┌──────────┬──────────────────────────────────────┐
//    │ 游戏目录  │  ○ [1] 1.21.5-fabric    📌 ⚙️ ⋯      │
//    │ (当前)   │     Fabric 0.16.10 · 隔离·仅 Mod       │
//    │          │  ○ [1] 1.20.1-forge     📌 ⚙️ ⋯      │
//    │          │     Forge 47.2.0 · 隔离·仅 Mod         │
//    └──────────┴──────────────────────────────────────┘
//
//  列表行间距 12，页面内边距 12。
//

#import "A2VersionListViewController.h"
#import "A2VersionSettingsViewController.h"
#import "A2GameVersionListViewController.h"
#import "A2InputDialog.h"
#import "A2TextField.h"
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
@property (nonatomic, strong) A2TextField *searchField;
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *versions;
@property (nonatomic, copy) NSString *filterText;
@property (nonatomic, strong) NSMutableArray<A2VersionRowView *> *rowViews;
@property (nonatomic, weak, nullable) UILabel *emptyTitleLabel;
@property (nonatomic, weak, nullable) UILabel *emptySubtitleLabel;
@end

@implementation A2VersionListViewController

- (void)viewDidLoad {
    // 必须写在 super 之前：基类在 [super viewDidLoad] 里就按它决定建 scroll 还是
    // plain 内容容器。晚设会让 plainContentView 一直是 nil。
    self.usesScrollContent = NO;   // 自己管布局
    [super viewDidLoad];
    self.pageTitle = @"版本管理";
    _rowViews = [NSMutableArray array];
    _filterText = @"";
    _searchField = [self makeSearchField];

    __weak typeof(self) weakSelf = self;
    [self addTrailingButtonWithSymbol:@"plus" action:^{
        __strong typeof(weakSelf) self = weakSelf;
        [self openGameVersionList];
    }];

    [self setupLayout];
    [self buildPathList];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(refreshEmptyStateTheme)
                                               name:A2ThemeDidChangeNotification
                                             object:nil];
}

/// 主题通知常驻，退出时摘掉（与行组件的 dealloc 摘除同理）。
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// 每次回到本页都重刷（设置页改名/删除、安装页装完回来时列表不能是旧的）。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadVersionList];
}

/// 从 A2VersionManager 读真实数据拼行。
- (void)loadVersions {
    A2VersionManager *mgr = A2VersionManager.shared;
    NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];

    for (A2Version *v in mgr.versions) {
        // meta 文案：加载器 + 隔离档位（档位是全局的，所有版本一致）。
        // 无效版本直接给原因（缺 json / 缺 jar / 解析失败），比档位更有用。
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (v.loaderInfo.length) [parts addObject:v.loaderInfo];
        if (v.isValid) {
            [parts addObject:[NSString stringWithFormat:@"隔离·%@",
                              A2IsolationModeDisplayName(v.isolationMode)]];
        } else {
            [parts addObject:(v.invalidReason ?: @"文件不完整")];
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
    [self.plainContentView addSubview:_searchField];
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

        // 搜索框（固定右上，不随列表滚动）
        [_searchField.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_searchField.leadingAnchor constraintEqualToAnchor:_pathScroll.trailingAnchor
                                                   constant:A2SpaceM],
        [_searchField.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                    constant:-A2SpaceL],

        // 右侧列表（顶端留给搜索框）
        [_listScroll.topAnchor constraintEqualToAnchor:_searchField.bottomAnchor
                                             constant:A2SpaceM],
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

/// 搜索框只创建装配，加屏与约束在 setupLayout（它依赖左侧栏定宽）。
- (A2TextField *)makeSearchField {
    A2TextField *field = [[A2TextField alloc] initWithLabel:@"搜索版本"];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    field.onTextChange = ^(NSString *text) {
        __strong typeof(weakSelf) self = weakSelf;
        self.filterText = text ?: @"";
        [self reloadVersionList];
    };
    field.onReturn = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self.view endEditing:YES];
    };
    return field;
}

- (void)buildPathList {
    // 只显示真实的游戏目录。目录切换没有实现，不放假条目。
    NSString *home = A2VersionManager.shared.gameHome;
    A2GamePathRow *row = [[A2GamePathRow alloc] initWithTitle:@"游戏目录" path:home];
    row.current = YES;
    row.userInteractionEnabled = NO;
    [_pathStack addArrangedSubview:row];

    // 撑起剩余空间
    UIView *filler = [[UIView alloc] initWithFrame:CGRectZero];
    filler.translatesAutoresizingMaskIntoConstraints = NO;
    [filler setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisVertical];
    [_pathStack addArrangedSubview:filler];
}

- (void)buildVersionList {
    if (_versions.count == 0) {
        [self buildEmptyState];
        return;
    }
    NSArray<NSDictionary<NSString *, id> *> *visible = [self filteredVersions];
    if (visible.count == 0) {
        [self buildNoMatchState];
        return;
    }
    for (NSDictionary<NSString *, id> *v in visible) {
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

            // 落盘失败时回滚，行状态不动（applyPinnedAndSave 内已恢复 model）。
            if (![model applyPinnedAndSave:newValue]) {
                [A2Toast show:@"置顶保存失败" inView:self.view];
                return;
            }
            weakRow.pinned = newValue;

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
            [self showMoreMenuForVersion:model meta:meta fromView:weakRow];
        };

        [_rowViews addObject:row];
        [_listStack addArrangedSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:_listStack.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:_listStack.trailingAnchor],
        ]];
    }
}

/// 空列表：给一句话 + 一个真入口，不留白屏。
- (void)buildEmptyState {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusM;
    card.elevation = A2CardElevationLow;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [A2Typography titleCard];
    title.textAlignment = NSTextAlignmentCenter;
    title.text = @"还没有安装任何版本";

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.font = [A2Typography subtitleCard];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;
    subtitle.text = @"点下方按钮安装第一个版本";

    A2PrimaryButton *installBtn = [[A2PrimaryButton alloc] initWithTitle:@"安装新版本"
                                                                   style:A2ButtonStylePrimary];
    installBtn.minHeight = 44;
    [installBtn addTarget:self action:@selector(openGameVersionList) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle, installBtn]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceM;
    stack.alignment = UIStackViewAlignmentFill;

    [card.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [_listStack addArrangedSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:_listStack.leadingAnchor],
        [card.trailingAnchor constraintEqualToAnchor:_listStack.trailingAnchor],
    ]];

    _emptyTitleLabel = title;
    _emptySubtitleLabel = subtitle;
    [self refreshEmptyStateTheme];
}

/// 空态文案跟主题走（注册一次，常驻观察；标签重建后刷新一次即可）。
- (void)refreshEmptyStateTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _emptyTitleLabel.textColor = t.cOnSurface;
    _emptySubtitleLabel.textColor = t.cOnSurfaceVariant;
}
/// 关键字过滤（大小写不敏感，空关键字即全部）。行与选中共用同一份可见集。
- (NSArray<NSDictionary<NSString *, id> *> *)filteredVersions {
    if (_filterText.length == 0) return _versions;
    NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *v in _versions) {
        NSString *name = v[@"name"];
        if ([name rangeOfString:_filterText options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [out addObject:v];
        }
    }
    return out;
}

/// 有版本但关键字无命中：纯提示行，不复用空态卡（那张卡带安装按钮，语义不对）。
- (void)buildNoMatchState {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [A2Typography subtitleCard];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.text = [NSString stringWithFormat:@"没有匹配“%@”的版本", _filterText];
    [_listStack addArrangedSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:_listStack.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:_listStack.trailingAnchor],
    ]];
    [self refreshNoMatchTheme:label];
}

/// 无命中提示跟主题走（只在构建时取一次，随列表重建刷新）。
- (void)refreshNoMatchTheme:(UILabel *)label {
    label.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
}
/// 切换当前版本。
/// 无效版本不允许选中（缺 jar 或 json 的版本启动必然失败）。
- (void)selectVersion:(A2VersionRowView *)selected {
    NSArray<NSDictionary<NSString *, id> *> *visible = [self filteredVersions];
    NSInteger index = [_rowViews indexOfObject:selected];
    if (index == NSNotFound || index >= (NSInteger)visible.count) return;

    A2Version *model = visible[index][@"model"];
    if (!model.isValid) {
        [A2Toast show:[NSString stringWithFormat:@"无法选择：%@",
                       model.invalidReason ?: @"版本文件不完整"] inView:self.view];
        return;
    }

    if (![A2VersionManager.shared selectCurrentVersion:model]) return;

    for (A2VersionRowView *r in _rowViews) {
        r.current = (r == selected);
    }
    [A2Toast show:[NSString stringWithFormat:@"已切换到 %@", model.name] inView:self.view];
}

/// 改名/复制/删除后重建列表（管理器内部已 reload，这里只重刷 UI）。
- (void)reloadVersionList {
    for (UIView *v in _listStack.arrangedSubviews) {
        [v removeFromSuperview];
    }
    [_rowViews removeAllObjects];
    _emptyTitleLabel = nil;
    _emptySubtitleLabel = nil;
    [self loadVersions];
    [self buildVersionList];
}

- (void)showMoreMenuForVersion:(A2Version *)version meta:(NSString *)meta fromView:(UIView *)source {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:version.name
                                            message:meta
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"重命名"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        [self showRenameDialogForVersion:version];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        [self showCopyDialogForVersion:version fromView:source];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        [self showDeleteConfirmForVersion:version];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = source;
    sheet.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

/// 重命名弹窗：非法名由管理器校验，这里只透出错误文案。
- (void)showRenameDialogForVersion:(A2Version *)version {
    __weak typeof(self) weakSelf = self;
    [A2InputDialog presentFrom:self
                        title:@"重命名版本"
                        label:@"新版本名"
                  initialText:version.name
                     onFinish:^(BOOL committed, NSString *text) {
        if (!committed) return;
        __strong typeof(weakSelf) self = weakSelf;
        NSError *err = nil;
        if ([A2VersionManager.shared renameVersion:version to:text error:&err]) {
            [self reloadVersionList];
            [A2Toast show:@"已重命名" inView:self.view];
        } else {
            [A2Toast show:(err.localizedDescription ?: @"重命名失败") inView:self.view];
        }
    }];
}

/// 复制：先选粒度（无输入框的 sheet，锚在行上防 iPad 崩），再输新名，两步都合规。
- (void)showCopyDialogForVersion:(A2Version *)version fromView:(UIView *)source {
    __weak typeof(self) weakSelf = self;
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"复制版本"
                                            message:@"仅版本文件只拷 json 与 jar；全部文件连存档模组一起拷"
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"仅版本文件" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) self = weakSelf;
        [self requestCopyNameForVersion:version mode:A2VersionCopyModeMinimal];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"全部文件" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) self = weakSelf;
        [self requestCopyNameForVersion:version mode:A2VersionCopyModeFull];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source ?: self.view;
    sheet.popoverPresentationController.sourceRect = source ? source.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

/// 复制第二步：输新名并执行（粒度由上一步定，不用开关传）。
- (void)requestCopyNameForVersion:(A2Version *)version mode:(A2VersionCopyMode)mode {
    __weak typeof(self) weakSelf = self;
    [A2InputDialog presentFrom:self
                        title:@"复制版本"
                        label:@"新版本名"
                  initialText:[version.name stringByAppendingString:@" 副本"]
                     onFinish:^(BOOL committed, NSString *text) {
        if (!committed) return;
        __strong typeof(weakSelf) self = weakSelf;
        NSError *err = nil;
        if (mode == A2VersionCopyModeFull) {
            [A2VersionManager.shared copyVersionFully:version to:text error:&err];
        } else {
            [A2VersionManager.shared copyVersionMinimal:version to:text error:&err];
        }
        [self completeCopyWithError:err];
    }];
}

/// 复制收尾：成功重刷列表，失败透出原因（Cocoa 的 error 惯例，nil 即成功）。
- (void)completeCopyWithError:(nullable NSError *)error {
    if (!error) {
        [self reloadVersionList];
        [A2Toast show:@"已复制" inView:self.view];
    } else {
        [A2Toast show:(error.localizedDescription ?: @"复制失败") inView:self.view];
    }
}

/// 删除二次确认：版本目录含用户存档模组，不可撤销。
- (void)showDeleteConfirmForVersion:(A2Version *)version {
    __weak typeof(self) weakSelf = self;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"删除版本"
                                            message:[NSString stringWithFormat:
                @"将删除 %@ 及其所有文件，不可撤销。", version.name]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) self = weakSelf;
        NSError *err = nil;
        if ([A2VersionManager.shared deleteVersion:version error:&err]) {
            [self reloadVersionList];
            [A2Toast show:@"已删除" inView:self.view];
        } else {
            [A2Toast show:(err.localizedDescription ?: @"删除失败") inView:self.view];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 安装入口

/// 进游戏版本选版页挑版安装（清单里选，不手输版本号）。
- (void)openGameVersionList {
    A2GameVersionListViewController *vc = [[A2GameVersionListViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
