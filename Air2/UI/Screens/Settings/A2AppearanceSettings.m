//
//  A2AppearanceSettings.m
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
//  外观分组 —— 主题配色、外观模式、自定义背景。
//
//  主题配色用「大色盘弹窗」选择（对应 ZL2 的颜色主题对话框）：
//  用户在二维色盘上选一个种子色，再选配色风格，
//  由此推导出完整的亮暗两套色板。
//

#import "A2SettingsSections.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2PaletteStyle.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Toast.h"
#import "A2BackgroundSettingsViewController.h"
#import "A2ColorThemeDialog.h"
#import "A2CurseForgeAPI.h"
#import "A2MirrorResolver.h"
#import "A2RendererPluginViewController.h"
#import "A2Toast.h"

@implementation A2AppearanceSettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"主题"];

    A2ThemeManager *tm = A2ThemeManager.shared;

    // ---- 颜色主题 ----
    A2SettingsRow *themeRow = [[A2SettingsRow alloc] init];
    themeRow.symbolName = @"paintpalette.fill";
    themeRow.title = @"颜色主题";
    themeRow.subtitle = @"更改启动器的整体颜色";
    themeRow.valueText = tm.theme.displayName;
    themeRow.accessory = A2SettingsRowAccessoryDisclosure;

    // 右侧放当前主题的主色块
    UIView *swatch = [[UIView alloc] initWithFrame:CGRectZero];
    swatch.translatesAutoresizingMaskIntoConstraints = NO;
    swatch.layer.cornerRadius = 6;
    swatch.layer.cornerCurve = kCACornerCurveContinuous;
    [NSLayoutConstraint activateConstraints:@[
        [swatch.widthAnchor constraintEqualToConstant:24],
        [swatch.heightAnchor constraintEqualToConstant:24],
    ]];
    themeRow.customAccessoryView = swatch;
    swatch.backgroundColor = tm.scheme.cPrimary;

    __weak A2SettingsRow *weakRow = themeRow;
    __weak UIView *weakSwatch = swatch;
    themeRow.onTap = ^{
        A2ColorThemeDialog *dialog = nil;
        (void)dialog;
        [A2ColorThemeDialog presentFrom:host
                              seedColor:A2ThemeManager.shared.scheme.cPrimary
                                  style:(A2PaletteStyle)A2ThemeManager.shared.paletteStyle
                             onComplete:^(UIColor *color, A2PaletteStyle style) {
            A2ThemeManager *m = A2ThemeManager.shared;
            m.paletteStyle = style;
            m.customSeedColor = color;
            weakRow.valueText = m.theme.displayName;
            weakSwatch.backgroundColor = m.scheme.cPrimary;
            [A2Toast show:@"主题已更新" inView:host.view];
        }];
    };
    [section addRow:themeRow];

    // ---- 外观模式 ----
    A2SettingsRow *appearanceRow = [[A2SettingsRow alloc] init];
    appearanceRow.symbolName = @"circle.lefthalf.filled";
    appearanceRow.title = @"深色模式";
    switch (tm.appearanceMode) {
        case A2AppearanceModeLight: appearanceRow.valueText = @"浅色"; break;
        case A2AppearanceModeDark:  appearanceRow.valueText = @"深色"; break;
        default:                    appearanceRow.valueText = @"跟随系统"; break;
    }
    appearanceRow.accessory = A2SettingsRowAccessoryDisclosure;
    // row 持有 block，block 里若强引用 row 会循环 —— 用 weak
    __weak A2SettingsRow *weakAppearanceRow = appearanceRow;
    appearanceRow.onTap = ^{
        UIAlertController *sheet =
            [UIAlertController alertControllerWithTitle:@"深色模式"
                                                message:nil
                                         preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray<NSString *> *names = @[@"跟随系统", @"浅色", @"深色"];
        for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
            NSInteger mode = i;
            [sheet addAction:[UIAlertAction actionWithTitle:names[i]
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) {
                A2ThemeManager.shared.appearanceMode = (A2AppearanceMode)mode;
                weakAppearanceRow.valueText = names[mode];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                                style:UIAlertActionStyleCancel
                                              handler:nil]];
        sheet.popoverPresentationController.sourceView = weakAppearanceRow;
        sheet.popoverPresentationController.sourceRect = weakAppearanceRow.bounds;
        [host presentViewController:sheet animated:YES completion:nil];
    };
    [section addRow:appearanceRow];

    // ---- 自定义背景 ----
    A2SettingsRow *bgRow = [[A2SettingsRow alloc] init];
    bgRow.symbolName = @"photo.fill";
    bgRow.title = @"自定义背景";
    bgRow.subtitle = tm.backgroundImage ? @"已设置" : @"当前使用主题渐变";
    bgRow.accessory = A2SettingsRowAccessoryDisclosure;
    bgRow.showsSeparator = NO;
    bgRow.onTap = ^{
        A2BackgroundSettingsViewController *vc = [[A2BackgroundSettingsViewController alloc] init];
        [host.navigationController pushViewController:vc animated:YES];
    };
    [section addRow:bgRow];

    // 主题变化时同步色块
    [NSNotificationCenter.defaultCenter addObserverForName:A2ThemeDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        A2ThemeManager *m = A2ThemeManager.shared;
        weakRow.valueText = m.theme.displayName;
        weakSwatch.backgroundColor = m.scheme.cPrimary;
    }];

    return section;
}

#pragma mark - 资源来源（CurseForge Key）

+ (A2SettingsSection *)buildSourceSectionWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"资源下载"];
    // Key 已内置，不再让用户申请 —— 文案必须与实际一致
    section.footerText = @"Modrinth 与 CurseForge 均可直接使用，无需额外配置。"
                          "国内网络建议保持镜像加速开启。";

    BOOL hasKey = [A2CurseForgeAPI hasAPIKey];

        // Key 是内置的（参考 ZL2 的构建期注入），
    // 用户无需配置，因此这里不再有「填写 / 验证 / 清除 Key」的入口。

    // ---- 镜像加速 ----
    A2SettingsRow *mirrorRow = [[A2SettingsRow alloc] init];
    mirrorRow.symbolName = @"arrow.triangle.2.circlepath";
    mirrorRow.title = @"使用国内镜像加速";
    mirrorRow.subtitle = @"通过 MCIM 镜像下载 CurseForge / Modrinth 的文件，"
                          "仅在中国大陆网络下生效";
    mirrorRow.accessory = A2SettingsRowAccessorySwitch;
    mirrorRow.on = [A2MirrorResolver shared].enabled;
    mirrorRow.onToggle = ^(BOOL isOn) {
        [A2MirrorResolver shared].enabled = isOn;
    };
    [section addRow:mirrorRow];

    A2SettingsRow *priorityRow = [[A2SettingsRow alloc] init];
    priorityRow.symbolName = @"arrow.up.arrow.down";
    priorityRow.title = @"镜像优先级";
    priorityRow.valueText = ([A2MirrorResolver shared].priority == A2MirrorPriorityMirrorFirst)
        ? @"镜像优先" : @"官方优先";
    priorityRow.accessory = A2SettingsRowAccessoryDisclosure;
    __weak A2SettingsRow *weakPriorityRow = priorityRow;
    priorityRow.onTap = ^{
        UIAlertController *sheet =
            [UIAlertController alertControllerWithTitle:@"镜像优先级"
                                                message:@"下载引擎会依次尝试候选地址，失败自动切换"
                                         preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"官方优先"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            [A2MirrorResolver shared].priority = A2MirrorPriorityOfficialFirst;
            weakPriorityRow.valueText = @"官方优先";
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"镜像优先"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            [A2MirrorResolver shared].priority = A2MirrorPriorityMirrorFirst;
            weakPriorityRow.valueText = @"镜像优先";
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                                 style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = weakPriorityRow;
        sheet.popoverPresentationController.sourceRect = weakPriorityRow.bounds;
        [host presentViewController:sheet animated:YES completion:nil];
    };
    [section addRow:priorityRow];


    return section;
}

@end
