//
//  A2GameInstallOptionsViewController.m
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
//  见头文件：加载器候选覆盖安装器能自动装的全部类型；OptiFine 无公开安装接口，
//  给出入口但置灰，副标题说明原因，不假装能装。
//  版本名默认取 MC 版本号，未手动改过时随加载器选择自动改成 {mc}-{loader}。
//

#import "A2GameInstallOptionsViewController.h"
#import "A2InstallingViewController.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2TextField.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2ColorScheme.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import "A2ModLoaderAPI.h"
#import "A2ModLoaderInstaller.h"
#import "A2VersionManager.h"
#import "A2Log.h"

@interface A2GameInstallOptionsViewController ()

@property (nonatomic, copy) NSString *versionID;

@property (nonatomic, strong) A2TextField *nameField;
@property (nonatomic, assign) BOOL nameValid;
/// 用户是否手动编辑过版本名；编辑过就不再自动改
@property (nonatomic, assign) BOOL userEditedName;

@property (nonatomic, strong) A2SettingsSection *loaderSection;
@property (nonatomic, strong) NSMutableArray<A2SettingsRow *> *loaderRows;
/// 与 loaderRows 的第 1 行起一一对应的加载器类型（第 0 行是「原版」）
@property (nonatomic, strong) NSArray<NSNumber *> *loaderTypeList;
/// nil 表示原版
@property (nonatomic, strong, nullable) NSNumber *selectedLoaderType;

@property (nonatomic, strong, nullable) A2SettingsSection *loaderVersionSection;
@property (nonatomic, strong) NSMutableArray<A2SettingsRow *> *loaderVersionRows;
@property (nonatomic, strong) NSArray<A2ModLoaderVersion *> *loaderVersions;
@property (nonatomic, assign) NSInteger selectedLoaderVersionIndex;

@property (nonatomic, strong) A2SettingsSection *actionSection;
@property (nonatomic, strong) A2PrimaryButton *installButton;

@end

@implementation A2GameInstallOptionsViewController

- (instancetype)initWithVersionID:(NSString *)versionID {
    self = [super init];
    if (!self) return nil;
    _versionID = [versionID copy];
    _loaderRows = [NSMutableArray array];
    _loaderVersionRows = [NSMutableArray array];
    _loaderVersions = @[];
    _selectedLoaderType = nil;
    _selectedLoaderVersionIndex = -1;
    _nameValid = YES;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = _versionID;

    [self setupNameSection];
    [self setupLoaderSection];
    [self setupActionSection];
    [self setupThemeObserver];

    [self applyTheme];
    [self validateName];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setupThemeObserver {
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

#pragma mark - 布局

- (void)setupNameSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"版本名"];

    _nameField = [[A2TextField alloc] initWithLabel:@"版本名"];
    _nameField.text = _versionID;
    _nameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    __weak typeof(self) weakSelf = self;
    _nameField.onTextChange = ^(NSString *text) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.userEditedName = YES;
        [self validateName];
    };
    [section addCustomView:_nameField];

    [self addSection:section];
}

- (void)setupLoaderSection {
    _loaderSection = [[A2SettingsSection alloc] initWithTitle:@"模组加载器"];

    // 第 0 行是「原版」，其余与 loaderTypeList 对齐。
    _loaderTypeList = @[
        @(A2ModLoaderTypeFabric),
        @(A2ModLoaderTypeQuilt),
        @(A2ModLoaderTypeLegacyFabric),
        @(A2ModLoaderTypeForge),
        @(A2ModLoaderTypeNeoForge),
        @(A2ModLoaderTypeOptiFine),
    ];

    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithObject:@"原版"];
    for (NSNumber *n in _loaderTypeList) {
        [titles addObject:[A2ModLoaderAPI displayNameForType:(A2ModLoaderType)n.integerValue]];
    }

    for (NSUInteger i = 0; i < titles.count; i++) {
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.title = titles[i];

        BOOL isVanilla = (i == 0);
        BOOL autoInstallable = YES;
        if (!isVanilla) {
            A2ModLoaderType type = (A2ModLoaderType)_loaderTypeList[i - 1].integerValue;
            autoInstallable = [A2ModLoaderInstaller supportsAutoInstall:type];
        }

        if (isVanilla) {
            row.subtitle = @"不安装任何加载器";
        } else if (!autoInstallable) {
            row.subtitle = @"官方无自动安装接口";
            row.enabled = NO;
            row.alpha = 0.45;
        }
        row.accessory = A2SettingsRowAccessoryNone;

        NSInteger captured = (NSInteger)i;
        __weak typeof(self) weakSelf = self;
        row.onTap = ^{
            [weakSelf selectLoaderAtIndex:captured];
        };

        [_loaderRows addObject:row];
        [_loaderSection addRow:row];
    }

    [self addSection:_loaderSection];
    [self refreshLoaderCheckmarks];
}

- (void)setupActionSection {
    _actionSection = [[A2SettingsSection alloc] initWithTitle:nil];

    _installButton = [[A2PrimaryButton alloc] initWithTitle:@"安装" style:A2ButtonStylePrimary];
    [_installButton addTarget:self action:@selector(startInstall)
             forControlEvents:UIControlEventTouchUpInside];
    [_actionSection addCustomView:_installButton];
    [NSLayoutConstraint activateConstraints:@[
        [_installButton.heightAnchor constraintEqualToConstant:A2ButtonHeight],
    ]];

    [self addSection:_actionSection];
}

#pragma mark - 加载器选择

- (void)selectLoaderAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_loaderRows.count) return;
    A2SettingsRow *row = _loaderRows[index];
    if (!row.enabled) return;   // 置灰项不可选

    NSNumber *type = (index == 0) ? nil : _loaderTypeList[index - 1];
    _selectedLoaderType = type;
    [self refreshLoaderCheckmarks];

    // 未手动改过版本名时，跟随加载器自动改名（原版则还原为 MC 版本号）。
    if (!_userEditedName) {
        if (type) {
            NSString *ident = [A2ModLoaderAPI identifierForType:(A2ModLoaderType)type.integerValue];
            _nameField.text = [NSString stringWithFormat:@"%@-%@", _versionID, ident];
        } else {
            _nameField.text = _versionID;
        }
    }
    [self validateName];

    if (!type) {
        [A2Log log:@"download: 选择加载器 原版"];
        [self clearLoaderVersionSection];
        return;
    }

    A2ModLoaderType loaderType = (A2ModLoaderType)type.integerValue;
    [A2Log log:@"download: 选择加载器 %@（%@）",
        [A2ModLoaderAPI displayNameForType:loaderType], _versionID];
    [self fetchLoaderVersionsForType:loaderType];
}

- (void)refreshLoaderCheckmarks {
    for (NSUInteger i = 0; i < _loaderRows.count; i++) {
        A2SettingsRow *row = _loaderRows[i];
        NSNumber *type = (i == 0) ? nil : _loaderTypeList[i - 1];
        BOOL selected = (type == _selectedLoaderType) ||
                        (type && _selectedLoaderType && [type isEqualToNumber:_selectedLoaderType]);
        row.accessory = selected ? A2SettingsRowAccessoryCheckmark : A2SettingsRowAccessoryNone;
    }
}

#pragma mark - 加载器版本

- (void)fetchLoaderVersionsForType:(A2ModLoaderType)type {
    [self clearLoaderVersionSection];
    __weak typeof(self) weakSelf = self;
    [[A2ModLoaderAPI shared] versionsForLoader:type
                                     mcVersion:_versionID
                                    completion:^(NSArray<A2ModLoaderVersion *> *versions,
                                                 NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // 期间又切了加载器就丢弃过期结果
        if (!self.selectedLoaderType ||
            self.selectedLoaderType.integerValue != type) {
            return;
        }
        NSString *name = [A2ModLoaderAPI displayNameForType:type];
        if (error) {
            [A2Toast show:[NSString stringWithFormat:@"%@ 版本获取失败", name] inView:self.view];
            [A2Log log:@"download: %@ 版本获取失败：%@", name, error.localizedDescription];
            [self selectLoaderAtIndex:0];
            return;
        }
        if (versions.count == 0) {
            [A2Toast show:[NSString stringWithFormat:@"该版本不支持 %@", name] inView:self.view];
            [A2Log log:@"download: 该版本不支持 %@（%@）", name, self.versionID];
            [self selectLoaderAtIndex:0];
            return;
        }
        [A2Log log:@"download: %@ 可用版本 %lu 个",
            name, (unsigned long)versions.count];
        [self showLoaderVersions:versions];
    }];
}

- (void)showLoaderVersions:(NSArray<A2ModLoaderVersion *> *)versions {
    _loaderVersions = [versions copy];
    // 默认选最新稳定版；没有稳定版就取第一个。
    _selectedLoaderVersionIndex = 0;
    for (NSUInteger i = 0; i < _loaderVersions.count; i++) {
        if (_loaderVersions[i].stable) {
            _selectedLoaderVersionIndex = (NSInteger)i;
            break;
        }
    }
    [self rebuildLoaderVersionSection];
}

- (void)rebuildLoaderVersionSection {
    [self clearLoaderVersionSection];
    if (_loaderVersions.count == 0) return;

    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"加载器版本"];

    for (NSUInteger i = 0; i < _loaderVersions.count; i++) {
        A2ModLoaderVersion *lv = _loaderVersions[i];
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.title = lv.version;
        row.subtitle = lv.stable ? @"稳定版" : @"预览版";
        row.accessory = ((NSInteger)i == _selectedLoaderVersionIndex)
            ? A2SettingsRowAccessoryCheckmark : A2SettingsRowAccessoryNone;

        NSInteger captured = (NSInteger)i;
        __weak typeof(self) weakSelf = self;
        row.onTap = ^{
            [weakSelf selectLoaderVersionAtIndex:captured];
        };

        [_loaderVersionRows addObject:row];
        [section addRow:row];
    }

    _loaderVersionSection = section;
    // 插到「安装」按钮之前，保证顺序稳定。
    NSUInteger idx = [self.contentStack.arrangedSubviews indexOfObject:_actionSection];
    if (idx == NSNotFound) idx = self.contentStack.arrangedSubviews.count;
    [self.contentStack insertArrangedSubview:section atIndex:idx];
}

- (void)clearLoaderVersionSection {
    if (_loaderVersionSection) {
        [_loaderVersionSection removeFromSuperview];
        _loaderVersionSection = nil;
    }
    [_loaderVersionRows removeAllObjects];
    _loaderVersions = @[];
    _selectedLoaderVersionIndex = -1;
}

- (void)selectLoaderVersionAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_loaderVersionRows.count) return;
    _selectedLoaderVersionIndex = index;
    for (NSUInteger i = 0; i < _loaderVersionRows.count; i++) {
        _loaderVersionRows[i].accessory = ((NSInteger)i == index)
            ? A2SettingsRowAccessoryCheckmark : A2SettingsRowAccessoryNone;
    }
    [A2Log log:@"download: 选择加载器版本 %@", _loaderVersions[index].version];
}

#pragma mark - 校验

- (void)validateName {
    NSString *name = _nameField.text;
    if (name.length == 0) {
        _nameValid = NO;
        _nameField.errorText = @"内容不能为空！";
        return;
    }
    for (A2Version *v in A2VersionManager.shared.versions) {
        if ([v.name isEqualToString:name]) {
            _nameValid = NO;
            _nameField.errorText = @"此名称的版本已经存在！";
            return;
        }
    }
    _nameValid = YES;
    _nameField.errorText = nil;
}

#pragma mark - 安装

- (void)startInstall {
    [self validateName];
    if (!_nameValid) {
        [A2Toast show:@"请先修正版本名" inView:self.view];
        return;
    }

    NSNumber *loaderType = _selectedLoaderType;
    NSString *loaderVersion = nil;
    if (loaderType) {
        if (_selectedLoaderVersionIndex < 0 ||
            _selectedLoaderVersionIndex >= (NSInteger)_loaderVersions.count) {
            [A2Toast show:@"加载器版本尚未就绪，请稍候" inView:self.view];
            return;
        }
        loaderVersion = _loaderVersions[_selectedLoaderVersionIndex].version;
    }

    [A2Log log:@"download: 开始安装 mc=%@ 版本名=%@ 加载器=%@ 加载器版本=%@",
        _versionID, _nameField.text,
        loaderType ? [A2ModLoaderAPI displayNameForType:(A2ModLoaderType)loaderType.integerValue]
                   : @"原版",
        loaderVersion ?: @"-"];

    A2InstallingViewController *vc =
        [[A2InstallingViewController alloc] initWithMCVersion:_versionID
                                                  versionName:_nameField.text
                                                   loaderType:loaderType
                                                loaderVersion:loaderVersion];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 主题

- (void)applyTheme {
    [super applyTheme];
    [self refreshLoaderCheckmarks];
}

@end
