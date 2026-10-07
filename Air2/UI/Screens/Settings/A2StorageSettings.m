//
//  A2StorageSettings.m
//  Air2
//
//  存储分组 —— 游戏目录、占用统计、缓存清理。
//

#import "A2SettingsSections.h"
#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Toast.h"

@implementation A2StorageSettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"存储"];

    // ---- 游戏目录 ----
    A2SettingsRow *dirRow = [[A2SettingsRow alloc] init];
    dirRow.symbolName = @"folder.fill";
    dirRow.title = @"游戏目录";
    dirRow.subtitle = @"App 沙盒 / Documents/.minecraft";
    dirRow.accessory = A2SettingsRowAccessoryDisclosure;
    dirRow.onTap = ^{ [A2Toast show:@"目录选择" inView:host.view]; };
    [section addRow:dirRow];

    // ---- 占用 ----
    A2SettingsRow *sizeRow = [[A2SettingsRow alloc] init];
    sizeRow.symbolName = @"internaldrive";
    sizeRow.title = @"已占用空间";
    sizeRow.subtitle = @"游戏文件 + 资源缓存";
    sizeRow.valueText = @"—";
    sizeRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:sizeRow];

    // ---- 缓存清理 ----
    A2SettingsRow *cacheRow = [[A2SettingsRow alloc] init];
    cacheRow.symbolName = @"trash.slash";
    cacheRow.title = @"清理下载缓存";
    cacheRow.subtitle = @"删除未完成的下载与临时文件";
    cacheRow.accessory = A2SettingsRowAccessoryDisclosure;
    cacheRow.showsBottomSeparator = NO;
    cacheRow.onTap = ^{ [A2Toast show:@"缓存已清理" inView:host.view]; };
    [section addRow:cacheRow];

    return section;
}

@end
