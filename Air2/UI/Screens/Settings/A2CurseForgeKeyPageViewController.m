//
//  A2CurseForgeKeyPageViewController.m
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
//  见头文件：输入框用 MD3 填充式 A2TextField（label/error/support 三件套），
//  校验存走共享 saveValidatedKey（与弹窗同一份逻辑，不各写一份验证）。
//  Key 从不明文展示：只显示“已配置/未配置”，不回显、不进日志。
//

#import "A2CurseForgeKeyPageViewController.h"
#import "A2CurseForgeAPI.h"
#import "A2CurseForgeKeyPrompt.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2TextField.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

@interface A2CurseForgeKeyPageViewController ()
@property (nonatomic, strong) A2TextField *keyField;
@property (nonatomic, strong) A2SettingsRow *statusRow;
@property (nonatomic, strong) A2PrimaryButton *saveButton;
@end

@implementation A2CurseForgeKeyPageViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"CurseForge API Key";

    // ---- 输入 ----
    A2SettingsSection *inputSection = [[A2SettingsSection alloc] initWithTitle:@"填写 Key"];
    inputSection.footerText = @"在 console.curseforge.com 免费申请。保存前会联网验证，"
                               "无效不存；Key 只进本机钥匙串。";
    _keyField = [[A2TextField alloc] initWithLabel:@"API Key"];
    _keyField.secure = YES;
    _keyField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _keyField.supportText = @"粘贴后点保存";
    __weak typeof(self) weakSelf = self;
    _keyField.onReturn = ^{
        [weakSelf saveKey];
    };
    [inputSection addCustomView:_keyField];
    [self addSection:inputSection];

    // ---- 状态 ----
    A2SettingsSection *statusSection = [[A2SettingsSection alloc] initWithTitle:@"状态"];
    _statusRow = [[A2SettingsRow alloc] init];
    _statusRow.symbolName = @"key.fill";
    _statusRow.title = @"当前状态";
    _statusRow.accessory = A2SettingsRowAccessoryNone;
    [statusSection addRow:_statusRow];
    [self addSection:statusSection];

    // ---- 保存 ----
    A2SettingsSection *actionSection = [[A2SettingsSection alloc] initWithTitle:nil];
    _saveButton = [[A2PrimaryButton alloc] initWithTitle:@"保存并验证"
                                                   style:A2ButtonStylePrimary];
    [_saveButton addTarget:self action:@selector(saveKey)
          forControlEvents:UIControlEventTouchUpInside];
    [actionSection addCustomView:_saveButton];
    [NSLayoutConstraint activateConstraints:@[
        [_saveButton.heightAnchor constraintEqualToConstant:A2ButtonHeight],
    ]];
    [self addSection:actionSection];

    // ---- 清除 ----
    A2SettingsSection *dangerSection = [[A2SettingsSection alloc] initWithTitle:nil];
    A2SettingsRow *clearRow = [[A2SettingsRow alloc] init];
    clearRow.symbolName = @"trash";
    clearRow.title = @"清除 Key";
    clearRow.destructive = YES;
    clearRow.accessory = A2SettingsRowAccessoryNone;
    clearRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [A2CurseForgeAPI setAPIKey:nil];
        [self refreshStatus];
        [A2Toast show:@"已清除" inView:self.view];
    };
    [dangerSection addRow:clearRow];
    [self addSection:dangerSection];

    [self refreshStatus];
}

#pragma mark - 状态与保存

- (void)refreshStatus {
    BOOL has = [A2CurseForgeAPI hasAPIKey];
    _statusRow.subtitle = has ? @"已配置，可用 CurseForge 资源" : @"未配置";
    _statusRow.valueText = has ? @"已设置" : @"未设置";
}

- (void)saveKey {
    NSString *key = _keyField.text;
    if (key.length == 0) {
        _keyField.errorText = @"Key 不能为空";
        return;
    }
    _keyField.errorText = nil;
    _saveButton.enabled = NO;
    [A2Toast show:@"正在验证…" inView:self.view];
    [A2CurseForgeKeyPrompt saveValidatedKey:key completion:^(BOOL valid, NSError *error) {
        // saveValidatedKey 已切主线程。
        self.saveButton.enabled = YES;
        if (valid) {
            self.keyField.text = @"";
            [self refreshStatus];
            [A2Toast show:@"已保存到钥匙串" inView:self.view];
        } else {
            self.keyField.errorText = error.localizedDescription ?: @"Key 无效";
        }
    }];
}

@end
