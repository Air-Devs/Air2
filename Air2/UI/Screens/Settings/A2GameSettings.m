//
//  A2GameSettings.m
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
//  游戏分组 —— 版本隔离档位（关闭 / 仅 Mod / 全部）。
//
//  档位是全局的：改一次对所有版本生效。改动后要立刻重算目录，
//  因为「仅 Mod」还要把共享 mods 换成指向当前版本的符号链接。
//  注意：「仅 Mod」只作用于能装模组的版本（装了 Fabric / Forge 等加载器的版本），
//  原版与仅装 OptiFine 的版本在该档位下不隔离。
//

#import "A2SettingsSections.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Settings.h"
#import "A2VersionIsolation.h"
#import "A2VersionManager.h"
#import "A2Toast.h"
#import "A2Log.h"

@implementation A2GameSettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"版本隔离"];
    section.footerText = @"依赖库与资源文件始终共用；「仅 Mod」只隔离能装模组的版本。";

    A2SettingsRow *modeRow = [[A2SettingsRow alloc] init];
    modeRow.symbolName = @"square.split.2x1.fill";
    modeRow.title = @"隔离档位";
    modeRow.showsSeparator = NO;

    __weak A2SettingsRow *weakRow = modeRow;
    void (^refresh)(void) = ^{
        A2IsolationMode mode = (A2IsolationMode)A2Settings.shared.versionIsolationMode;
        weakRow.valueText = A2IsolationModeDisplayName(mode);
        switch (mode) {
            case A2IsolationModeMod:
                weakRow.subtitle = @"只隔离能装模组的版本"; break;
            case A2IsolationModeFull:
                weakRow.subtitle = @"所有版本的整个游戏目录都隔离"; break;
            default:
                weakRow.subtitle = @"所有数据共用，不隔离"; break;
        }
    };
    refresh();

    modeRow.accessory = A2SettingsRowAccessoryDisclosure;
    modeRow.onTap = ^{
        UIAlertController *sheet =
            [UIAlertController alertControllerWithTitle:@"版本隔离"
                                                message:@"选择后对所有版本统一生效"
                                         preferredStyle:UIAlertControllerStyleActionSheet];

        NSArray<NSNumber *> *modes = @[@(A2IsolationModeNone),
                                       @(A2IsolationModeMod),
                                       @(A2IsolationModeFull)];
        for (NSNumber *value in modes) {
            A2IsolationMode mode = (A2IsolationMode)value.integerValue;
            NSString *title = A2IsolationModeDisplayName(mode);
            [sheet addAction:[UIAlertAction actionWithTitle:title
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) {
                A2Settings.shared.versionIsolationMode = mode;
                // 档位变了必须立刻重算目录与共享 mods 链接，否则要等下次扫描。
                [A2VersionManager.shared applyIsolation];
                [A2Log log:@"settings: 版本隔离档位 → %@", A2IsolationModeToString(mode)];
                refresh();
                [A2Toast show:[NSString stringWithFormat:@"已切换到「%@」", title]
                       inView:host.view];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                                style:UIAlertActionStyleCancel handler:nil]];

        sheet.popoverPresentationController.sourceView = weakRow;
        sheet.popoverPresentationController.sourceRect = weakRow.bounds;
        [host presentViewController:sheet animated:YES completion:nil];
    };
    [section addRow:modeRow];

    return section;
}

@end
