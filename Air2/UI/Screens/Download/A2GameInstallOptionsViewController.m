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
//  见头文件：加载器候选限定安装器能解析的四种；OptiFine 不支持自动装，
//  LegacyFabric 过于小众，两者都不给入口（2.5 宁缺毋滥）。
//  显示名必须包含 identifier 子串（安装页靠它推断类型），改名时同步改。
//

#import "A2GameInstallOptionsViewController.h"
#import "A2InstallingViewController.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

@interface A2GameInstallOptionsViewController ()
@property (nonatomic, copy) NSString *versionID;
@property (nonatomic, strong) A2SettingsSection *loaderSection;
@property (nonatomic, strong) NSMutableArray<A2SettingsRow *> *loaderRows;
/// 选中项在候选数组中的下标，0 = 原版
@property (nonatomic, assign) NSInteger selectedLoader;
@end

@implementation A2GameInstallOptionsViewController

// 显示名与 identifier 的对应（安装页用 containsString 推断，必须包含子串）。
+ (NSArray<NSString *> *)loaderDisplayNames {
    return @[@"原版（不装加载器）", @"Fabric", @"Forge", @"NeoForge", @"Quilt"];
}

+ (nullable NSString *)loaderStringForIndex:(NSInteger)index {
    // 0 为原版传 nil；其余原样透出（已含 identifier 子串）。
    if (index <= 0) return nil;
    NSArray<NSString *> *names = [self loaderDisplayNames];
    if (index >= (NSInteger)names.count) return nil;
    return names[(NSUInteger)index];
}

- (instancetype)initWithVersionID:(NSString *)versionID {
    self = [super init];
    if (!self) return nil;
    _versionID = [versionID copy];
    _selectedLoader = 0;
    _loaderRows = [NSMutableArray array];
    return self;
}

- (void)viewDidLoad {
    // 滚动模式：内容可能超一屏，用基类的 scroll stacking。
    [super viewDidLoad];
    self.pageTitle = _versionID;

    A2SettingsSection *loaderSection = [[A2SettingsSection alloc] initWithTitle:@"模组加载器"];
    NSArray<NSString *> *names = [A2GameInstallOptionsViewController loaderDisplayNames];
    for (NSUInteger i = 0; i < names.count; i++) {
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.title = names[i];
        row.accessory = (i == 0) ? A2SettingsRowAccessoryCheckmark : A2SettingsRowAccessoryNone;
        NSInteger captured = (NSInteger)i;
        __weak typeof(self) weakSelf = self;
        row.onTap = ^{
            [weakSelf selectLoader:captured];
        };
        [_loaderRows addObject:row];
        [loaderSection addRow:row];
    }
    loaderSection.footerText = @"OptiFine 无公开安装接口，需手动安装，此处不提供。";
    [self addSection:loaderSection];

    A2PrimaryButton *install = [[A2PrimaryButton alloc] initWithTitle:@"安装"
                                                                style:A2ButtonStylePrimary];
    [install addTarget:self action:@selector(startInstall)
      forControlEvents:UIControlEventTouchUpInside];
    // 按钮进 section 走 addCustomView（卡片内的标准做法，不手写容器）。
    A2SettingsSection *actionSection = [[A2SettingsSection alloc] initWithTitle:nil];
    [actionSection addCustomView:install];
    [NSLayoutConstraint activateConstraints:@[
        [install.heightAnchor constraintEqualToConstant:A2ButtonHeight],
    ]];
    [self addSection:actionSection];
}

- (void)selectLoader:(NSInteger)index {
    _selectedLoader = index;
    for (NSUInteger i = 0; i < _loaderRows.count; i++) {
        _loaderRows[i].accessory = ((NSInteger)i == index)
            ? A2SettingsRowAccessoryCheckmark : A2SettingsRowAccessoryNone;
    }
}

- (void)startInstall {
    NSString *loader = [A2GameInstallOptionsViewController loaderStringForIndex:_selectedLoader];
    A2InstallingViewController *vc = [[A2InstallingViewController alloc] initWithVersionName:_versionID
                                                                                     loader:loader];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
