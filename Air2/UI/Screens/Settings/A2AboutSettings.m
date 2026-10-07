//
//  A2AboutSettings.m
//  Air2
//
//  关于分组 —— 版本信息、开源许可、日志。
//

#import "A2SettingsSections.h"
#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Toast.h"

@implementation A2AboutSettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"关于"];
    section.footerText = @"Air2 基于 pojav 系后端开发，遵循 GPL-3.0 许可。\n上游依赖各自遵循其原始许可。";

    A2SettingsRow *versionRow = [[A2SettingsRow alloc] init];
    versionRow.symbolName = @"info.circle.fill";
    versionRow.title = @"Air2 版本";
    versionRow.valueText = @"0.1.0";
    versionRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:versionRow];

    A2SettingsRow *licenseRow = [[A2SettingsRow alloc] init];
    licenseRow.symbolName = @"doc.text.fill";
    licenseRow.title = @"开源许可";
    licenseRow.subtitle = @"GPL-3.0 与第三方依赖声明";
    licenseRow.accessory = A2SettingsRowAccessoryDisclosure;
    licenseRow.onTap = ^{ [A2Toast show:@"开源许可" inView:host.view]; };
    [section addRow:licenseRow];

    A2SettingsRow *logRow = [[A2SettingsRow alloc] init];
    logRow.symbolName = @"list.bullet.rectangle";
    logRow.title = @"查看运行日志";
    logRow.accessory = A2SettingsRowAccessoryDisclosure;
    logRow.onTap = ^{ [A2Toast show:@"日志查看" inView:host.view]; };
    [section addRow:logRow];

    A2SettingsRow *sourceRow = [[A2SettingsRow alloc] init];
    sourceRow.symbolName = @"chevron.left.forwardslash.chevron.right";
    sourceRow.title = @"源代码";
    sourceRow.subtitle = @"github.com/Air-Devs/Air2";
    sourceRow.accessory = A2SettingsRowAccessoryDisclosure;
    sourceRow.showsBottomSeparator = NO;
    sourceRow.onTap = ^{
        NSURL *url = [NSURL URLWithString:@"https://github.com/Air-Devs/Air2"];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    };
    [section addRow:sourceRow];

    return section;
}

@end
