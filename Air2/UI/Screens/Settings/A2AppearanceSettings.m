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

#pragma mark - 资源来源（CurseForge Key）

+ (A2SettingsSection *)buildSourceSectionWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"资源下载"];
    section.footerText = @"Modrinth 无需配置。CurseForge 需要 API Key，"
                          "可在 console.curseforge.com 免费申请。"
                          "Key 保存在设备钥匙串中，不会随备份外传。";

    BOOL hasKey = [A2CurseForgeAPI hasAPIKey];

    A2SettingsRow *cfRow = [[A2SettingsRow alloc] init];
    cfRow.symbolName = @"flame.fill";
    cfRow.title = @"CurseForge API Key";
    cfRow.subtitle = hasKey ? @"已配置" : @"未配置，无法使用 CurseForge 资源";
    cfRow.valueText = hasKey ? @"已设置" : @"未设置";
    cfRow.accessory = A2SettingsRowAccessoryDisclosure;
    __weak A2SettingsRow *weakCfRow = cfRow;
    cfRow.onTap = ^{
        [self showKeyEditorFrom:host row:weakCfRow];
    };
    [section addRow:cfRow];

    A2SettingsRow *testRow = [[A2SettingsRow alloc] init];
    testRow.symbolName = @"checkmark.seal";
    testRow.title = @"验证 Key";
    testRow.subtitle = @"向 CurseForge 发一次请求确认有效";
    testRow.accessory = A2SettingsRowAccessoryDisclosure;
    testRow.onTap = ^{
        if (![A2CurseForgeAPI hasAPIKey]) {
            [A2Toast show:@"请先填写 API Key" inView:host.view];
            return;
        }
        [A2Toast show:@"正在验证…" inView:host.view];
        [[A2CurseForgeAPI shared] validateKeyWithCompletion:^(BOOL valid, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (valid) {
                    [A2Toast show:@"Key 有效" inView:host.view];
                } else {
                    [A2Toast show:(error.localizedDescription ?: @"Key 无效") inView:host.view];
                }
            });
        }];
    };
    [section addRow:testRow];

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

    A2SettingsRow *clearRow = [[A2SettingsRow alloc] init];
    clearRow.symbolName = @"trash";
    clearRow.title = @"清除 Key";
    clearRow.destructive = YES;
    clearRow.accessory = A2SettingsRowAccessoryNone;
    clearRow.onTap = ^{
        [A2CurseForgeAPI setAPIKey:nil];
        weakCfRow.subtitle = @"未配置，无法使用 CurseForge 资源";
        weakCfRow.valueText = @"未设置";
        [A2Toast show:@"已清除" inView:host.view];
    };
    [section addRow:clearRow];

    return section;
}

+ (void)showKeyEditorFrom:(UIViewController *)host row:(A2SettingsRow *)row {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"CurseForge API Key"
                                            message:@"粘贴从 console.curseforge.com 获取的 Key"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"$2a$10$...";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        // Key 是凭据，输入时不显示明文
        tf.secureTextEntry = YES;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        NSString *key = alert.textFields.firstObject.text;
        if (key.length == 0) {
            [A2Toast show:@"Key 不能为空" inView:host.view];
            return;
        }
        [A2CurseForgeAPI setAPIKey:key];
        row.subtitle = @"已配置";
        row.valueText = @"已设置";
        [A2Toast show:@"已保存到钥匙串" inView:host.view];
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

@end
