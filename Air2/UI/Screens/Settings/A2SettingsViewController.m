//
//  A2SettingsViewController.m
//  Air2
//
//  设置页。
//
//  目前只有外观一组 —— 因为它背后的东西是真做过的
//  （主题色板、亮暗模式、自定义背景处理链）。
//  其余设置项等对应功能实现后再加。
//

#import "A2SettingsViewController.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

#import "A2SettingsSections.h"

@implementation A2SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"设置";

    [self addSection:[A2AppearanceSettings buildWithHost:self]];
}

@end
