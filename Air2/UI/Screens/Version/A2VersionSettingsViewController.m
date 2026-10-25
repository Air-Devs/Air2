//
//  A2VersionSettingsViewController.m
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
//  单版本设置 —— 隔离档位是全局的，这里只做展示。
//
//  隔离档位在「设置 → 游戏」里选（关闭 / 仅 Mod / 全部）。
//  本页显示的是「本版本的生效档位」：全局选「仅 Mod」时，只有能装模组的版本
//  才会隔离，原版与仅装 OptiFine 的版本按「关闭」处理。
//  只展示、不提供修改入口，避免两处设置互相打架。
//
//  版本的启动配置仍存在 {版本目录}/.air_version/config.json。
//

#import "A2VersionSettingsViewController.h"
#import "A2VersionTabBar.h"
#import "A2VersionIsolation.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2GlassCard.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2VersionManager.h"
#import "A2InputDialog.h"
#import "A2ModListViewController.h"

@interface A2VersionSettingsViewController ()
/// 版本名（在 init 里赋值，后续只读）
@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, strong) A2Version *version;
@property (nonatomic, strong) A2SettingsRow *modeRow;
@property (nonatomic, strong) A2SettingsRow *pathRow;
@property (nonatomic, strong) A2SettingsSection *folderSection;
@property (nonatomic, strong) NSMutableArray<A2SettingsRow *> *folderRows;
/// 左侧标签栏（对照 ZL2 的 TabMenu）
@property (nonatomic, strong) A2VersionTabBar *tabBar;
/// 右栏自己的滚动容器（不用基类那个，见 setupTabLayout 的说明）
@property (nonatomic, strong) UIScrollView *contentScroll;
@property (nonatomic, strong) UIStackView *contentStack;
@end

@implementation A2VersionSettingsViewController

- (instancetype)initWithVersionName:(NSString *)versionName {
    self = [super init];
    if (!self) return nil;
    _versionName = [versionName copy];
    _folderRows = [NSMutableArray array];

    // 从管理器里找到对应版本（拿到真实的隔离配置）
    for (A2Version *v in A2VersionManager.shared.versions) {
        if ([v.name isEqualToString:versionName]) {
            _version = v;
            break;
        }
    }
    if (!_version) {
        _version = [[A2Version alloc] initWithName:versionName
                                          gameHome:A2VersionManager.shared.gameHome];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = _version.name;

    // 左侧标签栏 + 右侧内容（对照 ZL2 的 TabMenu + NavigationUI）
    [self setupTabLayout];
    [self refreshIsolationUI];
}

#pragma mark - 标签布局

/// 左侧标签栏 + 右侧内容。
///
/// ⚠️ 不能用基类的 scrollView —— 它在 updateViewConstraints 里
/// 被钉死成「贴满全屏」（leading/trailing 都到 self.view 边缘）。
/// 我再加一条 leading 到标签栏右边，两者冲突，结果是
/// 标签栏和内容重叠（截图里左边能看到被切掉一半的「总览」「启动」）。
///
/// 所以这里自建一套：self.view 上直接放 tabBar + 一个独立的 scrollView。
/// 基类那个用不上了（它会自己加约束，但我们不往里放东西，
/// 内容为零所以看不见）。
- (void)setupTabLayout {
    self.usesScrollContent = NO;

    UIView *host = self.view;

    // ---- 左栏 ----
    _tabBar = [[A2VersionTabBar alloc] initWithFrame:CGRectZero];
    _tabBar.selectedTab = A2VersionTabOverview;

    __weak typeof(self) weakSelf = self;
    _tabBar.onTabChanged = ^(A2VersionTab tab) {
        __strong typeof(weakSelf) self = weakSelf;
        [self showTab:tab];
    };
    [host addSubview:_tabBar];

    // ---- 右栏：自己的滚动容器 ----
    _contentScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _contentScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _contentScroll.showsVerticalScrollIndicator = NO;
    _contentScroll.contentInsetAdjustmentBehavior =
        UIScrollViewContentInsetAdjustmentNever;
    [host addSubview:_contentScroll];

    _contentStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    _contentStack.axis = UILayoutConstraintAxisVertical;
    _contentStack.spacing = A2SpaceL;
    [_contentScroll addSubview:_contentStack];

    [NSLayoutConstraint activateConstraints:@[
        // 标签栏：固定宽 96（88 太窄，四字标题会被裁）
        [_tabBar.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor
                                          constant:A2SpaceM],
        [_tabBar.leadingAnchor constraintEqualToAnchor:host.leadingAnchor
                                             constant:A2SpaceM],
        [_tabBar.widthAnchor constraintEqualToConstant:96],

        // 内容区：从标签栏右侧到屏幕右边
        [_contentScroll.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor],
        [_contentScroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [_contentScroll.leadingAnchor constraintEqualToAnchor:_tabBar.trailingAnchor
                                                    constant:A2SpaceM],
        [_contentScroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor
                                                     constant:-A2SpaceM],

        // 内容栈
        [_contentStack.topAnchor constraintEqualToAnchor:_contentScroll.contentLayoutGuide.topAnchor],
        [_contentStack.bottomAnchor constraintEqualToAnchor:_contentScroll.contentLayoutGuide.bottomAnchor],
        [_contentStack.leadingAnchor constraintEqualToAnchor:_contentScroll.frameLayoutGuide.leadingAnchor],
        [_contentStack.trailingAnchor constraintEqualToAnchor:_contentScroll.frameLayoutGuide.trailingAnchor],
    ]];

    [self showTab:A2VersionTabOverview];
}

/// 切换标签：清空右栏，重建对应内容
- (void)showTab:(A2VersionTab)tab {
    for (UIView *v in [self.contentStack.arrangedSubviews copy]) {
        [self.contentStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    switch (tab) {
        case A2VersionTabOverview:
            [self setupHeaderCard];
            [self setupIsolationSection];
            break;
        case A2VersionTabLaunch:
            [self setupLaunchSection];
            break;
        case A2VersionTabFolder:
            [self setupFolderSection];
            break;
        case A2VersionTabDanger:
            [self setupDangerSection];
            break;
        default:
            break;
    }

    [self refreshIsolationUI];
}

/// 子类自己的 addSection（基类的 addSection 加的是基类 contentStack）
- (void)addSection:(UIView *)section {
    [self.contentStack addArrangedSubview:section];
}

#pragma mark - 顶部信息

- (void)setupHeaderCard {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationLow;

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    name.textColor = t.cOnSurface;
    name.text = _version.name;

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectZero];
    status.font = [A2Typography caption];
    status.textColor = _version.isValid ? t.cSuccess : t.cError;
    status.text = _version.isValid ? @"版本文件完整" : @"版本文件不完整";

    UILabel *path = [[UILabel alloc] initWithFrame:CGRectZero];
    path.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    path.textColor = t.cOnSurfaceVariant;
    path.numberOfLines = 3;
    path.lineBreakMode = NSLineBreakByTruncatingMiddle;
    path.text = _version.versionPath;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[name, status, path]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceS;
    [stack setCustomSpacing:A2SpaceM afterView:status];

    [card.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [self addSection:card];
}

#pragma mark - 版本隔离

- (void)setupIsolationSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"版本隔离"];
    section.footerText = @"隔离档位是全局设置，在「设置 → 游戏」里修改。"
                          "依赖库与资源文件始终共用，不会重复占用空间。";

    _modeRow = [[A2SettingsRow alloc] init];
    _modeRow.symbolName = @"square.split.2x1.fill";
    _modeRow.title = @"隔离档位";
    _modeRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:_modeRow];

    _pathRow = [[A2SettingsRow alloc] init];
    _pathRow.symbolName = @"folder.fill";
    _pathRow.title = @"当前游戏目录";
    _pathRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:_pathRow];

    [self addSection:section];
}

/// 实时刷新隔离相关文案 —— 档位或版本变化都要重算路径
- (void)refreshIsolationUI {
    A2IsolationMode mode = _version.effectiveIsolationMode;

    _modeRow.valueText = A2IsolationModeDisplayName(mode);
    if (mode == A2IsolationModeMod) {
        _modeRow.subtitle = @"只隔离本版本的模组，其余目录共用";
    } else if (mode == A2IsolationModeFull) {
        _modeRow.subtitle = @"整个游戏目录按版本隔离";
    } else if (_version.isolationMode == A2IsolationModeMod) {
        // 全局档位是「仅 Mod」，但本版本不能装模组，实际按关闭处理。
        _modeRow.subtitle = @"本版本不能装模组，不隔离";
    } else {
        _modeRow.subtitle = @"所有数据共用，不隔离";
    }

    _pathRow.subtitle = [_version gameDirectory];

    // 各可隔离目录的实际路径
    for (NSUInteger i = 0; i < _folderRows.count && i < A2VersionFolderCount; i++) {
        NSString *dir = [_version directoryForFolder:(A2VersionFolder)i];
        _folderRows[i].valueText = [self shortenPath:dir];
    }

    switch (mode) {
        case A2IsolationModeFull:
            _folderSection.footerText = [NSString stringWithFormat:
                @"这些目录当前位于 versions/%@/ 下。", _version.name];
            break;
        case A2IsolationModeMod:
            _folderSection.footerText = @"只有模组位于版本目录下，其余目录在游戏根目录共用。";
            break;
        default:
            _folderSection.footerText = @"这些目录当前位于游戏根目录下，与其他版本共用。";
            break;
    }
}

/// 路径太长，只显示最后两段
- (NSString *)shortenPath:(NSString *)path {
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count <= 2) return path;
    return [NSString stringWithFormat:@"…/%@/%@",
            parts[parts.count - 2], parts[parts.count - 1]];
}

#pragma mark - 可隔离目录

- (void)setupFolderSection {
    _folderSection = [[A2SettingsSection alloc] initWithTitle:@"版本内容"];

    NSArray<NSString *> *symbols = @[@"puzzlepiece.extension.fill", @"photo.stack.fill",
                                     @"map.fill", @"sun.max.fill", @"photo.fill"];

    for (NSUInteger i = 0; i < A2VersionFolderCount; i++) {
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = symbols[i];
        row.title = A2VersionFolderDisplayName((A2VersionFolder)i);
        row.accessory = A2SettingsRowAccessoryDisclosure;

        // 模组行进专用管理页，其余目录维持通用浏览（各管各的，不混）。
        if ((A2VersionFolder)i == A2VersionFolderMods) {
            __weak typeof(self) weakSelf = self;
            row.onTap = ^{
                __strong typeof(weakSelf) self = weakSelf;
                A2ModListViewController *vc =
                    [[A2ModListViewController alloc] initWithVersion:self.version];
                [self.navigationController pushViewController:vc animated:YES];
            };
        } else {
            NSString *folderName = A2VersionFolderDisplayName((A2VersionFolder)i);
            NSString *dir = [_version directoryForFolder:(A2VersionFolder)i];
            row.onTap = ^{
                NSURL *url = [NSURL fileURLWithPath:dir];
                (void)url;
                [A2Toast show:[NSString stringWithFormat:@"%@：%@", folderName, dir]
                       inView:self.view];
            };
        }

        [_folderRows addObject:row];
        [_folderSection addRow:row];
    }

    [self addSection:_folderSection];
}

#pragma mark - 启动配置

- (void)setupLaunchSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"启动配置"];
    section.footerText = @"留空则使用全局设置。这些配置存在版本的 .air_version/config.json 里。";

    A2VersionIsolation *iso = _version.isolation;

    A2SettingsRow *jvmRow = [[A2SettingsRow alloc] init];
    jvmRow.symbolName = @"terminal";
    jvmRow.title = @"JVM 参数";
    jvmRow.valueText = iso.jvmArgs.length ? iso.jvmArgs : @"跟随全局";
    jvmRow.accessory = A2SettingsRowAccessoryDisclosure;
    // 注意：row 持有 onTap，onTap 里若再强引用 row 就会形成循环。
    // 这里对 row 也用 weak 捕获。
    __weak A2SettingsRow *weakJvmRow = jvmRow;
    jvmRow.onTap = ^{
        __weak typeof(self) weakSelf = self;
        A2InputDialog *dlg = [A2InputDialog dialogWithTitle:@"JVM 参数"
                                                    message:@"留空则使用全局设置"
                                                      label:@"JVM 参数"
                                                initialText:weakSelf.version.isolation.jvmArgs];
        dlg.keyboardType = UIKeyboardTypeASCIICapable;
        dlg.autocapitalizationType = UITextAutocapitalizationTypeNone;
        dlg.onFinish = ^(BOOL committed, NSString *text) {
            if (!committed) return;
            weakSelf.version.isolation.jvmArgs = text;
            [weakSelf.version saveConfig];
            weakJvmRow.valueText = weakSelf.version.isolation.jvmArgs.length
                ? weakSelf.version.isolation.jvmArgs : @"跟随全局";
        };
        [dlg presentFrom:weakSelf];
    };
    [section addRow:jvmRow];

    A2SettingsRow *gameArgsRow = [[A2SettingsRow alloc] init];
    gameArgsRow.symbolName = @"text.alignleft";
    gameArgsRow.title = @"游戏参数";
    gameArgsRow.valueText = iso.gameArgs.length ? iso.gameArgs : @"跟随全局";
    gameArgsRow.accessory = A2SettingsRowAccessoryDisclosure;
    __weak A2SettingsRow *weakGameArgsRow = gameArgsRow;
    gameArgsRow.onTap = ^{
        __weak typeof(self) weakSelf = self;
        A2InputDialog *dlg = [A2InputDialog dialogWithTitle:@"游戏参数"
                                                    message:@"留空则使用全局设置"
                                                      label:@"游戏参数"
                                                initialText:weakSelf.version.isolation.gameArgs];
        dlg.keyboardType = UIKeyboardTypeASCIICapable;
        dlg.autocapitalizationType = UITextAutocapitalizationTypeNone;
        dlg.onFinish = ^(BOOL committed, NSString *text) {
            if (!committed) return;
            weakSelf.version.isolation.gameArgs = text;
            [weakSelf.version saveConfig];
            weakGameArgsRow.valueText = weakSelf.version.isolation.gameArgs.length
                ? weakSelf.version.isolation.gameArgs : @"跟随全局";
        };
        [dlg presentFrom:weakSelf];
    };
    [section addRow:gameArgsRow];

    A2SettingsRow *integrityRow = [[A2SettingsRow alloc] init];
    integrityRow.symbolName = @"checkmark.shield";
    integrityRow.title = @"跳过完整性检查";
    integrityRow.subtitle = @"启动更快，但可能掩盖文件损坏";
    integrityRow.accessory = A2SettingsRowAccessorySwitch;
    integrityRow.on = (iso.skipGameIntegrityCheck == A2SettingStateEnable);
    integrityRow.onToggle = ^(BOOL isOn) {
        __weak typeof(self) weakSelf = self;
        weakSelf.version.isolation.skipGameIntegrityCheck =
            isOn ? A2SettingStateEnable : A2SettingStateDisable;
        [weakSelf.version saveConfig];
    };
    [section addRow:integrityRow];

    [self addSection:section];
}

#pragma mark - 危险操作

- (void)setupDangerSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"管理"];

    A2SettingsRow *renameRow = [[A2SettingsRow alloc] init];
    renameRow.symbolName = @"square.and.pencil";
    renameRow.title = @"重命名版本";
    renameRow.accessory = A2SettingsRowAccessoryDisclosure;
    renameRow.onTap = ^{
        __weak typeof(self) weakSelf = self;
        A2InputDialog *dlg = [A2InputDialog dialogWithTitle:@"重命名版本"
                                                    message:nil
                                                      label:@"版本名"
                                                initialText:weakSelf.version.name];
        dlg.autocapitalizationType = UITextAutocapitalizationTypeNone;
        // 重名 / 非法名由 A2VersionManager 判定，失败时弹窗内报错并保留
        dlg.onCommit = ^(NSString *text, void (^done)(BOOL, NSString *)) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) { done(NO, @"操作已取消"); return; }
            NSString *newName = [text stringByTrimmingCharactersInSet:
                                 NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (newName.length == 0) { done(NO, @"名称不能为空"); return; }
            NSError *err = nil;
            if ([A2VersionManager.shared renameVersion:self.version to:newName error:&err]) {
                self.pageTitle = newName;
                done(YES, nil);
            } else {
                done(NO, err.localizedDescription ?: @"重命名失败");
            }
        };
        dlg.onFinish = ^(BOOL committed, NSString *text) {
            if (committed) [A2Toast show:@"已重命名" inView:weakSelf.view];
        };
        [dlg presentFrom:weakSelf];
    };
    [section addRow:renameRow];

    A2SettingsRow *deleteRow = [[A2SettingsRow alloc] init];
    deleteRow.symbolName = @"trash";
    deleteRow.title = @"删除此版本";
    deleteRow.subtitle = @"该操作不可撤销";
    deleteRow.destructive = YES;
    deleteRow.onTap = ^{
        __weak typeof(self) weakSelf = self;
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"删除版本"
                                                message:[NSString stringWithFormat:
                    @"将删除 %@ 及其所有文件，不可撤销。", weakSelf.version.name]
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) self = weakSelf;
            NSError *err = nil;
            if ([A2VersionManager.shared deleteVersion:self.version error:&err]) {
                [A2Toast show:@"已删除" inView:self.view];
                [self.navigationController popViewControllerAnimated:YES];
            } else {
                [A2Toast show:(err.localizedDescription ?: @"删除失败") inView:self.view];
            }
        }]];
        [weakSelf presentViewController:alert animated:YES completion:nil];
    };
    [section addRow:deleteRow];

    [self addSection:section];
}

@end
