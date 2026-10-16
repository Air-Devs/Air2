//
//  A2MemorySettings.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  设置 · 游戏 —— ★内存分组：档位（自动/手动）+ 手动堆上限预设★。
//
//  为什么现在才有：A2SettingsSections.h 的「宁缺毋滥」教训 —— 设置项必须有真实实现。
//  本分组的两个取值都被启动链真正消费：
//    · memoryMode      → Player 的启动会话（自动 = 按设备可用内存动态算 -Xmx；手动 = 用固定值）；
//    · ramAllocationMB → 手动档的堆上限（★仍受设备安全顶钳制★，见 A2LaunchMemory）。
//  真机判据行：启动日志里的
//    `[MEM] probe available=…MB physical=…MB source=…`（Bridge 采集）
//    `[MEM] ceiling=…MB -> -Xmx…MB (source=…) mode=… jre=… gc=…`（Player 决策）。
//
//  ★持久化★：A2Settings（Documents/config.json，全局设置的唯一读写点）—— ★不在本文件另开存储★。
//  ★分层★：本文件只依赖 Core（A2Settings / A2LaunchMemory 的枚举）+ UI 组件；不 import Bridge/Natives。
//

#import "A2SettingsSections.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Settings.h"
#import "A2LaunchMemory.h"   // 内存档位枚举（A2LaunchMemoryMode）—— 本文件直接用它的取值
#import "A2Toast.h"
#import "A2Log.h"

/// 手动档的堆上限预设（MB）。★边界与启动侧同源★：下限 = A2LaunchMemoryMinXmxMB、
/// 上限 = A2LaunchMemoryMaxXmxMB（本组预设都落在 [256, 4096] 内）—— 不在这里另定一套边界。
static NSArray<NSNumber *> *A2MemoryPresetMB(void) {
    return @[ @512, @1024, @1536, @2048, @3072, @4096 ];
}

@implementation A2MemorySettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"内存"];
    section.footerText = @"自动：按设备可用内存动态定堆上限（推荐）。手动：固定堆上限，"
                         @"仍受设备安全顶钳制——堆超顶会被系统直接杀掉，不是变慢。";

    A2SettingsRow *modeRow = [[A2SettingsRow alloc] init];
    modeRow.symbolName = @"memorychip.fill";
    modeRow.title = @"内存档位";
    modeRow.accessory = A2SettingsRowAccessoryDisclosure;

    A2SettingsRow *amountRow = [[A2SettingsRow alloc] init];
    amountRow.symbolName = @"arrow.up.arrow.down.circle.fill";
    amountRow.title = @"堆上限";
    amountRow.accessory = A2SettingsRowAccessoryDisclosure;

    __weak A2SettingsRow *weakMode = modeRow;
    __weak A2SettingsRow *weakAmount = amountRow;
    void (^refresh)(void) = ^{
        A2LaunchMemoryMode mode = A2Settings.shared.memoryMode;
        BOOL manual = (mode == A2LaunchMemoryModeManual);
        NSInteger mb = A2Settings.shared.ramAllocationMB;
        weakMode.valueText = manual ? @"手动" : @"自动";
        weakMode.subtitle = manual ? @"用固定堆上限（仍受设备安全顶钳制）"
                                   : @"按设备可用内存动态算 -Xmx";
        weakAmount.valueText = [NSString stringWithFormat:@"%ld MB", (long)mb];
        weakAmount.subtitle = manual ? @"点这里在预设里改" : @"自动档下不参与取值";
        // 自动档下这一行不生效：变暗且不响应点击（沿用既有「按状态启停」的做法）。
        weakAmount.enabled = manual;
    };
    refresh();

    __weak UIViewController *weakHost = host;

    modeRow.onTap = ^{
        UIViewController *hostVC = weakHost;
        if (hostVC == nil) return;

        UIAlertController *sheet =
            [UIAlertController alertControllerWithTitle:@"内存档位"
                                                message:@"自动按设备可用内存动态定 -Xmx；手动固定堆上限（仍受安全顶钳制）"
                                         preferredStyle:UIAlertControllerStyleActionSheet];

        NSArray<NSString *> *titles = @[ @"自动（推荐）", @"手动" ];
        NSArray<NSNumber *> *modes = @[ @(A2LaunchMemoryModeAuto), @(A2LaunchMemoryModeManual) ];
        A2LaunchMemoryMode cur = A2Settings.shared.memoryMode;
        for (NSUInteger i = 0; i < titles.count; i++) {
            A2LaunchMemoryMode mode = (A2LaunchMemoryMode)modes[i].integerValue;
            NSString *title = (mode == cur) ? [@"✓ " stringByAppendingString:titles[i]] : titles[i];
            [sheet addAction:[UIAlertAction actionWithTitle:title
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) {
                A2Settings.shared.memoryMode = mode;
                [A2Log log:@"settings: 内存档位 → %@",
                 (mode == A2LaunchMemoryModeManual ? @"manual" : @"auto")];
                refresh();
                [A2Toast show:[NSString stringWithFormat:@"已切换到「%@」", titles[i]]
                       inView:hostVC.view];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                                 style:UIAlertActionStyleCancel handler:nil]];
        A2SettingsRow *r = weakMode;
        sheet.popoverPresentationController.sourceView = r ?: hostVC.view;
        sheet.popoverPresentationController.sourceRect = r ? r.bounds : hostVC.view.bounds;
        [hostVC presentViewController:sheet animated:YES completion:nil];
    };

    amountRow.onTap = ^{
        UIViewController *hostVC = weakHost;
        if (hostVC == nil) return;

        UIAlertController *sheet =
            [UIAlertController alertControllerWithTitle:@"堆上限"
                                                message:@"手动档的 -Xmx（MB）；下发前仍会压回设备安全顶"
                                         preferredStyle:UIAlertControllerStyleActionSheet];

        NSInteger cur = A2Settings.shared.ramAllocationMB;
        for (NSNumber *value in A2MemoryPresetMB()) {
            NSInteger mb = value.integerValue;
            NSString *title = [NSString stringWithFormat:@"%ld MB", (long)mb];
            if (mb == cur) title = [@"✓ " stringByAppendingString:title];
            [sheet addAction:[UIAlertAction actionWithTitle:title
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) {
                A2Settings.shared.ramAllocationMB = mb;
                [A2Log log:@"settings: 堆上限 → %ld MB", (long)mb];
                refresh();
                [A2Toast show:[NSString stringWithFormat:@"堆上限 %ld MB", (long)mb]
                       inView:hostVC.view];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                                 style:UIAlertActionStyleCancel handler:nil]];
        A2SettingsRow *r = weakAmount;
        sheet.popoverPresentationController.sourceView = r ?: hostVC.view;
        sheet.popoverPresentationController.sourceRect = r ? r.bounds : hostVC.view.bounds;
        [hostVC presentViewController:sheet animated:YES completion:nil];
    };

    [section addRow:modeRow];
    [section addRow:amountRow];
    return section;
}

@end
