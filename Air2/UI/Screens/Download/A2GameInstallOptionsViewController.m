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
//  「请求加载器版本列表」与「选择加载器版本」都收在同一张可展开卡里完成
//  （见 A2LoaderCard）：点卡头就地展开、选完自动收起，不另开页面。
//  版本名默认取 MC 版本号，未手动改过时随加载器选择自动改成 {mc}-{loader}。
//

#import "A2GameInstallOptionsViewController.h"
#import "A2InstallingViewController.h"
#import "A2LoaderCard.h"
#import "A2SettingsSection.h"
#import "A2TextField.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2ModLoaderAPI.h"
#import "A2ModLoaderInstaller.h"
#import "A2VersionManager.h"
#import "A2Log.h"

@interface A2GameInstallOptionsViewController () <A2LoaderCardDelegate>

@property (nonatomic, copy) NSString *versionID;

@property (nonatomic, strong) A2TextField *nameField;
@property (nonatomic, assign) BOOL nameValid;
/// 用户是否手动编辑过版本名；编辑过就不再自动改
@property (nonatomic, assign) BOOL userEditedName;

@property (nonatomic, strong) A2SettingsSection *loaderSection;
@property (nonatomic, strong) UIStackView *loaderStack;
/// 全部加载器卡（含原版卡）
@property (nonatomic, strong) NSMutableArray<A2LoaderCard *> *loaderCards;
/// 当前选中的卡。原版卡默认选中，因此不为 nil。
@property (nonatomic, strong, nullable) A2LoaderCard *chosenLoaderCard;

@property (nonatomic, strong) A2SettingsSection *actionSection;
@property (nonatomic, strong) A2PrimaryButton *installButton;

@end

@implementation A2GameInstallOptionsViewController

- (instancetype)initWithVersionID:(NSString *)versionID {
    self = [super init];
    if (!self) return nil;
    _versionID = [versionID copy];
    _loaderCards = [NSMutableArray array];
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
    _loaderSection.footerText =
        @"不选择加载器即为原版。OptiFine 官方无自动安装接口，需自行手动安装。";

    _loaderStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _loaderStack.axis = UILayoutConstraintAxisVertical;
    _loaderStack.spacing = A2CardSpacing;

    // 原版排第一：它就是「不装加载器」，是默认态，放最前符合阅读顺序。
    A2LoaderCard *vanilla = [[A2LoaderCard alloc] initAsVanilla];
    vanilla.delegate = self;
    vanilla.chosen = YES;
    _chosenLoaderCard = vanilla;
    [_loaderCards addObject:vanilla];
    [_loaderStack addArrangedSubview:vanilla];

    for (NSNumber *n in [A2ModLoaderAPI allLoaderTypes]) {
        A2ModLoaderType type = (A2ModLoaderType)n.integerValue;
        A2LoaderCard *card = [[A2LoaderCard alloc] initWithLoaderType:type mcVersion:_versionID];
        card.delegate = self;
        // 官方没有稳定自动化接口的加载器只给入口、不给假希望。
        if (![A2ModLoaderInstaller supportsAutoInstall:type]) {
            card.unavailableReason = @"官方无自动安装接口";
        }
        [_loaderCards addObject:card];
        [_loaderStack addArrangedSubview:card];
    }

    [_loaderSection addCustomView:_loaderStack];
    [self addSection:_loaderSection];
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

- (void)loaderCardSelectionDidChange:(A2LoaderCard *)card {
    _chosenLoaderCard = card;

    for (A2LoaderCard *c in _loaderCards) {
        if (c == card) continue;
        c.chosen = NO;      // 置 NO 会一并清掉它已选的版本
        [c collapse];
    }

    if (card.isVanilla) {
        [A2Log log:@"download: 选择加载器 原版"];
        [self syncNameForLoaderType:nil];
        return;
    }

    [A2Log log:@"download: 选择加载器 %@（%@）",
        [A2ModLoaderAPI displayNameForType:card.loaderType], _versionID];
    [self syncNameForLoaderType:@(card.loaderType)];
}

- (void)loaderCardDidExpand:(A2LoaderCard *)card {
    // 同时只允许一张卡展开，免得全部打开后页面被拉得很长。
    for (A2LoaderCard *c in _loaderCards) {
        if (c != card) [c collapse];
    }
}

/// 未手动改过版本名时，跟随加载器自动改名（原版还原为 MC 版本号）。
- (void)syncNameForLoaderType:(nullable NSNumber *)type {
    if (_userEditedName) return;
    if (type) {
        NSString *ident = [A2ModLoaderAPI identifierForType:(A2ModLoaderType)type.integerValue];
        _nameField.text = [NSString stringWithFormat:@"%@-%@", _versionID, ident];
    } else {
        _nameField.text = _versionID;
    }
    [self validateName];
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

    NSNumber *loaderType = nil;
    NSString *loaderVersion = nil;
    A2LoaderCard *card = _chosenLoaderCard;
    if (card && !card.isVanilla) {
        A2ModLoaderVersion *picked = card.selectedVersion;
        if (!picked) {
            [A2Toast show:[NSString stringWithFormat:@"请先选择 %@ 的版本",
                           [A2ModLoaderAPI displayNameForType:card.loaderType]]
                   inView:self.view];
            return;
        }
        loaderType = @(card.loaderType);
        loaderVersion = picked.version;
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

@end
