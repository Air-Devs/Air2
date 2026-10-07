//
//  A2GameSettings.m
//  Air2
//
//  游戏分组 —— 内存、Java、启动参数、版本隔离默认值。
//

#import "A2SettingsSections.h"
#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Toast.h"

@implementation A2GameSettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"游戏"];
    section.footerText = @"这里的设置是全局默认值，单个版本可以在「版本设置」中覆盖。";

    // ---- 内存分配 ----
    A2SettingsRow *ramRow = [[A2SettingsRow alloc] init];
    ramRow.symbolName = @"memorychip";
    ramRow.title = @"内存分配";
    ramRow.subtitle = @"设备可用内存的 50%，过高可能导致闪退";
    ramRow.valueText = @"2048 MB";

    UISlider *ramSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    ramSlider.translatesAutoresizingMaskIntoConstraints = NO;
    ramSlider.minimumValue = 512;
    ramSlider.maximumValue = 8192;
    ramSlider.value = 2048;
    ramSlider.minimumTrackTintColor = A2ThemeManager.shared.scheme.cPrimary;
    [NSLayoutConstraint activateConstraints:@[
        [ramSlider.widthAnchor constraintEqualToConstant:130],
    ]];
    [ramSlider addAction:[UIAction actionWithHandler:^(UIAction *action) {
        UISlider *s = (UISlider *)action.sender;
        NSInteger mb = ((NSInteger)s.value / 256) * 256;   // 按 256MB 对齐
        ramRow.valueText = [NSString stringWithFormat:@"%ld MB", (long)mb];
    }] forControlEvents:UIControlEventValueChanged];
    ramRow.customAccessoryView = ramSlider;
    [section addRow:ramRow];

    // ---- Java 运行时 ----
    A2SettingsRow *javaRow = [[A2SettingsRow alloc] init];
    javaRow.symbolName = @"cup.and.saucer.fill";
    javaRow.title = @"Java 运行时";
    javaRow.valueText = @"JRE 21 (内置)";
    javaRow.accessory = A2SettingsRowAccessoryDisclosure;
    javaRow.onTap = ^{ [A2Toast show:@"Java 运行时管理" inView:host.view]; };
    [section addRow:javaRow];

    // ---- JVM 参数 ----
    A2SettingsRow *jvmRow = [[A2SettingsRow alloc] init];
    jvmRow.symbolName = @"terminal";
    jvmRow.title = @"JVM 参数";
    jvmRow.subtitle = @"留空使用默认值";
    jvmRow.valueText = @"默认";
    jvmRow.accessory = A2SettingsRowAccessoryDisclosure;
    jvmRow.onTap = ^{ [A2Toast show:@"JVM 参数编辑" inView:host.view]; };
    [section addRow:jvmRow];

    // ---- 版本隔离 ----
    A2SettingsRow *isoRow = [[A2SettingsRow alloc] init];
    isoRow.symbolName = @"square.split.2x1";
    isoRow.title = @"默认开启版本隔离";
    isoRow.subtitle = @"每个版本独立 mods / 存档 / 资源包";
    isoRow.accessory = A2SettingsRowAccessorySwitch;
    isoRow.on = NO;
    isoRow.onToggle = ^(BOOL isOn) {};
    [section addRow:isoRow];

    // ---- 完整性检查 ----
    A2SettingsRow *integrityRow = [[A2SettingsRow alloc] init];
    integrityRow.symbolName = @"checkmark.shield";
    integrityRow.title = @"跳过游戏完整性检查";
    integrityRow.subtitle = @"启动更快，但可能掩盖文件损坏";
    integrityRow.accessory = A2SettingsRowAccessorySwitch;
    integrityRow.showsBottomSeparator = NO;
    integrityRow.on = NO;
    integrityRow.onToggle = ^(BOOL isOn) {};
    [section addRow:integrityRow];

    return section;
}

@end
