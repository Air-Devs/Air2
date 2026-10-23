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
//  单版本设置 —— 左侧分类导航 + 右侧内容，和设置页同一个骨架。
//
//  导航结构（对照 ZL2 的版本设置）：
//    信息 / 启动配置
//    ────────────
//    mod / 材质 / 存档 / 光影
//
//  隔离档位是全局的，这里只展示：全局选「仅 Mod」时，只有能装模组的版本
//  才会隔离，原版与仅装 OptiFine 的版本按「关闭」处理。
//  版本的启动配置仍存在 {版本目录}/.air_version/config.json。
//

#import "A2VersionSettingsViewController.h"
#import "A2VersionIsolation.h"
#import "A2CategoryNavView.h"
#import "A2FilesViewController.h"
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

// 左侧分类导航
@property (nonatomic, strong) A2CategoryNavView *nav;
@property (nonatomic, strong) UIScrollView *detailScroll;
@property (nonatomic, strong) UIStackView *detailStack;

// 信息页里需要实时刷新的几行
@property (nonatomic, strong) A2SettingsRow *modeRow;
@property (nonatomic, strong) A2SettingsRow *pathRow;
@property (nonatomic, strong) UILabel *headerNameLabel;
@end

@implementation A2VersionSettingsViewController

- (instancetype)initWithVersionName:(NSString *)versionName {
    self = [super init];
    if (!self) return nil;
    _versionName = [versionName copy];

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
    // 自己搭「左导航 + 右滚动内容」，不用基类的单栏滚动
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = _version.name;

    [self setupSidebar];
    [self refreshIsolationUI];
}

#pragma mark - 左侧导航

- (void)setupSidebar {
    // 只列有真实内容的分类：信息 / 启动配置，以及四个版本内容目录
    NSArray<A2NavCategory *> *cats = @[
        [A2NavCategory title:@"信息"     symbol:@"info.circle.fill"],
        [A2NavCategory title:@"启动配置" symbol:@"gearshape.fill"],

        [A2NavCategory title:@"mod"  symbol:@"puzzlepiece.extension.fill" division:YES],
        [A2NavCategory title:@"材质" symbol:@"photo.stack.fill"],
        [A2NavCategory title:@"存档" symbol:@"map.fill"],
        [A2NavCategory title:@"光影" symbol:@"sun.max.fill"],
    ];

    __weak typeof(self) weakSelf = self;
    _nav = [[A2CategoryNavView alloc] initWithCategories:cats];
    _nav.onSelect = ^(NSInteger index) {
        __strong typeof(weakSelf) self = weakSelf;
        [self rebuildContentForIndex:index];
    };
    [self.plainContentView addSubview:_nav];

    _detailScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _detailScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _detailScroll.showsVerticalScrollIndicator = NO;
    _detailScroll.showsHorizontalScrollIndicator = NO;
    _detailScroll.alwaysBounceHorizontal = NO;
    _detailScroll.directionalLockEnabled = YES;
    _detailScroll.alwaysBounceVertical = YES;
    _detailScroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;

    _detailStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _detailStack.translatesAutoresizingMaskIntoConstraints = NO;
    _detailStack.axis = UILayoutConstraintAxisVertical;
    _detailStack.spacing = A2SpaceXL;

    [_detailScroll addSubview:_detailStack];
    [self.plainContentView addSubview:_detailScroll];

    [NSLayoutConstraint activateConstraints:@[
        [_nav.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_nav.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_nav.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                           constant:A2SpaceS],

        [_detailScroll.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_detailScroll.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_detailScroll.leadingAnchor constraintEqualToAnchor:_nav.trailingAnchor
                                                    constant:A2SpaceM],
        [_detailScroll.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],

        [_detailStack.topAnchor constraintEqualToAnchor:_detailScroll.contentLayoutGuide.topAnchor
                                               constant:A2SpaceS],
        [_detailStack.bottomAnchor constraintEqualToAnchor:_detailScroll.contentLayoutGuide.bottomAnchor
                                                 constant:-A2SpaceXXL],
        [_detailStack.centerXAnchor constraintEqualToAnchor:_detailScroll.frameLayoutGuide.centerXAnchor],
        [_detailStack.widthAnchor constraintEqualToAnchor:_detailScroll.frameLayoutGuide.widthAnchor
                                                constant:-(A2SpaceM + A2SpaceXL)],
        [_detailScroll.contentLayoutGuide.widthAnchor
            constraintEqualToAnchor:_detailScroll.frameLayoutGuide.widthAnchor],
    ]];

    [_nav selectIndex:0 animated:NO];
}

/// 按导航索引重建右侧内容。
/// 0 信息 / 1 启动配置 / 2 mod / 3 材质 / 4 存档 / 5 光影
- (void)rebuildContentForIndex:(NSInteger)index {
    [self clearDetailStack];

    switch (index) {
        case 0: {
            [_detailStack addArrangedSubview:[self buildHeaderCard]];
            [_detailStack addArrangedSubview:[self buildIsolationSection]];
            [_detailStack addArrangedSubview:[self buildDangerSection]];
            [self refreshIsolationUI];
            break;
        }
        case 1: {
            [_detailStack addArrangedSubview:[self buildLaunchSection]];
            break;
        }
        default: {
            A2VersionFolder folder = (A2VersionFolder)(index - 2);
            [_detailStack addArrangedSubview:[self buildFolderPaneForFolder:folder]];
            break;
        }
    }
}

- (void)clearDetailStack {
    for (UIView *v in _detailStack.arrangedSubviews.copy) {
        [_detailStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
}

#pragma mark - 信息：版本概况

- (A2GlassCard *)buildHeaderCard {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationLow;

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    name.textColor = t.cOnSurface;
    name.text = _version.name;
    _headerNameLabel = name;

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
    return card;
}

#pragma mark - 信息：版本隔离

- (A2SettingsSection *)buildIsolationSection {
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

    return section;
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
}

/// 路径太长，只显示最后两段
- (NSString *)shortenPath:(NSString *)path {
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count <= 2) return path;
    return [NSString stringWithFormat:@"…/%@/%@",
            parts[parts.count - 2], parts[parts.count - 1]];
}

#pragma mark - 版本内容：mod / 材质 / 存档 / 光影

- (A2SettingsSection *)buildFolderPaneForFolder:(A2VersionFolder)folder {
    NSString *displayName = A2VersionFolderDisplayName(folder);
    NSString *dir = [_version directoryForFolder:folder];

    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:displayName];
    section.footerText = [self folderFooterForFolder:folder];

    A2SettingsRow *dirRow = [[A2SettingsRow alloc] init];
    dirRow.symbolName = @"folder.fill";
    dirRow.title = @"目录";
    dirRow.subtitle = [self shortenPath:dir];
    dirRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:dirRow];

    __weak typeof(self) weakSelf = self;
    A2SettingsRow *openRow = [[A2SettingsRow alloc] init];
    openRow.accessory = A2SettingsRowAccessoryDisclosure;

    if (folder == A2VersionFolderMods) {
        // 模组走专用管理页（启用/停用、删除），其它目录走通用文件浏览
        openRow.symbolName = @"puzzlepiece.extension.fill";
        openRow.title = @"管理 mod";
        openRow.subtitle = @"启用 / 停用、删除已安装的模组";
        openRow.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            A2ModListViewController *vc =
                [[A2ModListViewController alloc] initWithVersion:self.version];
            [self.navigationController pushViewController:vc animated:YES];
        };
    } else {
        openRow.symbolName = @"folder";
        openRow.title = @"浏览文件";
        openRow.subtitle = @"打开文件夹查看 / 导入内容";
        openRow.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            A2FilesViewController *vc =
                [[A2FilesViewController alloc] initWithRootPath:dir
                                                   displayName:displayName];
            [self.navigationController pushViewController:vc animated:YES];
        };
    }
    [section addRow:openRow];

    return section;
}

/// 目录位置的说明随隔离档位变化
- (NSString *)folderFooterForFolder:(A2VersionFolder)folder {
    NSString *folderName = A2VersionFolderName(folder);
    switch (_version.effectiveIsolationMode) {
        case A2IsolationModeFull:
            return [NSString stringWithFormat:@"该目录位于 versions/%@/%@ 下。",
                    _version.name, folderName];
        case A2IsolationModeMod:
            if (folder == A2VersionFolderMods) {
                return [NSString stringWithFormat:@"该目录位于 versions/%@/mods 下。",
                        _version.name];
            }
            return @"该目录在游戏根目录，与其他版本共用。";
        default:
            return @"该目录在游戏根目录，与其他版本共用。";
    }
}

#pragma mark - 启动配置

- (A2SettingsSection *)buildLaunchSection {
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

    return section;
}

#pragma mark - 信息：管理

- (A2SettingsSection *)buildDangerSection {
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
                self.headerNameLabel.text = newName;
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

    return section;
}

@end
