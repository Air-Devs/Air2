//
//  A2AboutSettings.m
//  Air2
//
//  关于分组 —— 对照 ZL2 的 AboutInfoScreen。
//  版本信息、开源许可、运行日志、源代码、更新检查。
//

#import "A2SettingsSections.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Toast.h"
#import "A2Typography.h"
#import "A2LicenseViewController.h"
#import "A2LogViewController.h"

@implementation A2AboutSettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"关于"];
    section.footerText = @"Air2 基于 pojav 系后端开发，遵循 GPL-3.0 许可。"
                          "Minecraft 是 Mojang Studios 的商标，"
                          "本项目与其无隶属关系。";

    // 版本信息
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];

    A2SettingsRow *versionRow = [[A2SettingsRow alloc] init];
    versionRow.symbolName = @"info.circle.fill";
    versionRow.title = @"Air2 版本";
    versionRow.valueText = [NSString stringWithFormat:@"%@ (%@)",
                            version ?: @"0.1.0", build ?: @"1"];
    versionRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:versionRow];

    // 开源许可
    A2SettingsRow *licenseRow = [[A2SettingsRow alloc] init];
    licenseRow.symbolName = @"doc.text.fill";
    licenseRow.title = @"开源许可";
    licenseRow.subtitle = @"上游项目与其许可协议";
    licenseRow.accessory = A2SettingsRowAccessoryDisclosure;
    licenseRow.onTap = ^{
        [host.navigationController pushViewController:[[A2LicenseViewController alloc] init]
                                             animated:YES];
    };
    [section addRow:licenseRow];

    // 运行日志
    A2SettingsRow *logRow = [[A2SettingsRow alloc] init];
    logRow.symbolName = @"list.bullet.rectangle";
    logRow.title = @"运行日志";
    logRow.subtitle = @"查看启动器运行时的日志";
    logRow.accessory = A2SettingsRowAccessoryDisclosure;
    logRow.onTap = ^{
        [host.navigationController pushViewController:[[A2LogViewController alloc] init]
                                             animated:YES];
    };
    [section addRow:logRow];

    // 源代码
    A2SettingsRow *sourceRow = [[A2SettingsRow alloc] init];
    sourceRow.symbolName = @"chevron.left.forwardslash.chevron.right";
    sourceRow.title = @"源代码";
    sourceRow.subtitle = @"github.com/Air-Devs/Air2";
    sourceRow.accessory = A2SettingsRowAccessoryDisclosure;
    sourceRow.onTap = ^{
        NSURL *url = [NSURL URLWithString:@"https://github.com/Air-Devs/Air2"];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    };
    [section addRow:sourceRow];

    // 检查更新（暂未实现对应后端，明确提示而不是假装成功）
    A2SettingsRow *updateRow = [[A2SettingsRow alloc] init];
    updateRow.symbolName = @"arrow.triangle.2.circlepath";
    updateRow.title = @"检查更新";
    updateRow.accessory = A2SettingsRowAccessoryDisclosure;
    updateRow.showsBottomSeparator = NO;
    updateRow.onTap = ^{
        [A2Toast show:@"更新检查尚未实现" inView:host.view];
    };
    [section addRow:updateRow];

    return section;
}

@end
