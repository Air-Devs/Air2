//
//  A2AppearanceSettings.m
//  Air2
//
//  外观分组 —— 主题、亮暗模式、玻璃强度。
//  主题行用一个小色块展示当前配色，比纯文字直观得多。
//

#import "A2SettingsSections.h"
#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Toast.h"
#import "A2ThemePickerViewController.h"
#import "A2BackgroundSettingsViewController.h"

@implementation A2AppearanceSettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"外观"];

    A2ThemeManager *tm = A2ThemeManager.shared;

    // ---- 主题选择 ----
    A2SettingsRow *themeRow = [[A2SettingsRow alloc] init];
    themeRow.symbolName = @"paintpalette.fill";
    themeRow.title = @"主题配色";
    themeRow.valueText = tm.theme.displayName;
    themeRow.accessory = A2SettingsRowAccessoryDisclosure;
    themeRow.onTap = ^{
        A2ThemePickerViewController *vc = [[A2ThemePickerViewController alloc] init];
        [host.navigationController pushViewController:vc animated:YES];
    };

    // 右侧加一个当前主题的色块预览
    UIView *swatch = [[UIView alloc] initWithFrame:CGRectZero];
    swatch.translatesAutoresizingMaskIntoConstraints = NO;
    swatch.layer.cornerRadius = 5;
    swatch.layer.cornerCurve = kCACornerCurveContinuous;
    [NSLayoutConstraint activateConstraints:@[
        [swatch.widthAnchor constraintEqualToConstant:22],
        [swatch.heightAnchor constraintEqualToConstant:22],
    ]];
    themeRow.customAccessoryView = swatch;

    // 主题变化时同步色块与文字
    [NSNotificationCenter.defaultCenter addObserverForName:A2ThemeDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        A2ColorTheme *t = A2ThemeManager.shared.theme;
        themeRow.valueText = t.displayName;
        swatch.backgroundColor = A2ThemeManager.shared.scheme.primary;
    }];
    swatch.backgroundColor = tm.scheme.primary;

    [section addRow:themeRow];

    // ---- 亮暗模式 ----
    A2SettingsRow *appearanceRow = [[A2SettingsRow alloc] init];
    appearanceRow.symbolName = @"circle.lefthalf.filled";
    appearanceRow.title = @"外观模式";
    switch (tm.appearanceMode) {
        case A2AppearanceModeLight: appearanceRow.valueText = @"浅色"; break;
        case A2AppearanceModeDark:  appearanceRow.valueText = @"深色"; break;
        default:                    appearanceRow.valueText = @"跟随系统"; break;
    }
    appearanceRow.accessory = A2SettingsRowAccessoryDisclosure;
    appearanceRow.onTap = ^{
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"外观模式"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray<NSString *> *names = @[@"跟随系统", @"浅色", @"深色"];
        for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
            NSInteger mode = i;
            [sheet addAction:[UIAlertAction actionWithTitle:names[i]
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) {
                A2ThemeManager.shared.appearanceMode = (A2AppearanceMode)mode;
                A2ThemeManager.shared.selectedKind = A2ThemeManager.shared.selectedKind;
                [A2Toast show:[NSString stringWithFormat:@"外观：%@", names[mode]] inView:host.view];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = appearanceRow;
        sheet.popoverPresentationController.sourceRect = appearanceRow.bounds;
        [host presentViewController:sheet animated:YES completion:nil];
    };
    [section addRow:appearanceRow];

    // ---- 自定义背景 ----
    A2SettingsRow *bgRow = [[A2SettingsRow alloc] init];
    bgRow.symbolName = @"photo.fill";
    bgRow.title = @"自定义背景";
    bgRow.subtitle = tm.backgroundImage ? @"已设置" : @"当前使用主题渐变";
    bgRow.accessory = A2SettingsRowAccessoryDisclosure;
    bgRow.showsBottomSeparator = NO;
    bgRow.onTap = ^{
        A2BackgroundSettingsViewController *vc = [[A2BackgroundSettingsViewController alloc] init];
        [host.navigationController pushViewController:vc animated:YES];
    };
    [section addRow:bgRow];

    return section;
}

@end
