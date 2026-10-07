//
//  A2AppearanceSettings.m
//  Air2
//
//  外观分组 —— 主题配色、外观模式、自定义背景。
//
//  主题配色用「大色盘弹窗」选择（对应 ZL2 的颜色主题对话框）：
//  用户在二维色盘上选一个种子色，再选配色风格，
//  由此推导出完整的亮暗两套色板。
//

#import "A2SettingsSections.h"
#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2PaletteStyle.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Toast.h"
#import "A2BackgroundSettingsViewController.h"
#import "A2ColorThemeDialog.h"

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
                appearanceRow.valueText = names[mode];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                                style:UIAlertActionStyleCancel
                                              handler:nil]];
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

@end
