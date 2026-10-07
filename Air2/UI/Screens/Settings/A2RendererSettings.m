//
//  A2RendererSettings.m
//  Air2
//
//  渲染分组 —— 渲染器选择、分辨率、帧率。
//
//  渲染器列表参考 ZL2 的 game/renderer/renderers，
//  但对齐 iOS 上实际可用的后端（Mesa kopper / VirGL / GL4ES 系）。
//

#import "A2SettingsSections.h"
#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Toast.h"

@implementation A2RendererSettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"渲染"];
    section.footerText = @"不同渲染器在不同设备上表现差异明显，建议逐个尝试后选择最稳定的一个。";

    // ---- 渲染器 ----
    A2SettingsRow *rendererRow = [[A2SettingsRow alloc] init];
    rendererRow.symbolName = @"cube.transparent";
    rendererRow.title = @"渲染器";
    rendererRow.valueText = @"Kopper (Zink)";
    rendererRow.accessory = A2SettingsRowAccessoryDisclosure;
    rendererRow.onTap = ^{ [A2Toast show:@"渲染器选择" inView:host.view]; };
    [section addRow:rendererRow];

    // ---- 图形 API ----
    A2SettingsRow *apiRow = [[A2SettingsRow alloc] init];
    apiRow.symbolName = @"square.stack.3d.down.right";
    apiRow.title = @"图形 API";
    apiRow.subtitle = @"覆盖游戏自身的图形设置";
    apiRow.valueText = @"跟随游戏";
    apiRow.accessory = A2SettingsRowAccessoryDisclosure;
    apiRow.onTap = ^{ [A2Toast show:@"图形 API 选择" inView:host.view]; };
    [section addRow:apiRow];

    // ---- 分辨率 ----
    A2SettingsRow *resRow = [[A2SettingsRow alloc] init];
    resRow.symbolName = @"rectangle.compress.vertical";
    resRow.title = @"渲染分辨率";
    resRow.subtitle = @"降低可提升帧率";
    resRow.valueText = @"100%";
    resRow.accessory = A2SettingsRowAccessoryDisclosure;
    resRow.onTap = ^{ [A2Toast show:@"分辨率选择" inView:host.view]; };
    [section addRow:resRow];

    // ---- 帧率 ----
    A2SettingsRow *fpsRow = [[A2SettingsRow alloc] init];
    fpsRow.symbolName = @"speedometer";
    fpsRow.title = @"解锁帧率";
    fpsRow.subtitle = @"关闭垂直同步，帧率大幅提升但耗电增加";
    fpsRow.accessory = A2SettingsRowAccessorySwitch;
    fpsRow.on = NO;
    fpsRow.onToggle = ^(BOOL isOn) {};
    [section addRow:fpsRow];

    // ---- 帧率显示 ----
    A2SettingsRow *fpsDisplayRow = [[A2SettingsRow alloc] init];
    fpsDisplayRow.symbolName = @"gauge.with.dots.needle.bottom.50percent";
    fpsDisplayRow.title = @"游戏内帧率显示";
    fpsDisplayRow.showsBottomSeparator = NO;
    fpsDisplayRow.accessory = A2SettingsRowAccessorySwitch;
    fpsDisplayRow.on = YES;
    fpsDisplayRow.onToggle = ^(BOOL isOn) {};
    [section addRow:fpsDisplayRow];

    return section;
}

@end
