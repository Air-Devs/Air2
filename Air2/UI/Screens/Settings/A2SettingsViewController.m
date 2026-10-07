//
//  A2SettingsViewController.m
//  Air2
//
//  设置主页 —— 分组列表。各分组的具体项目较多，
//  按主题/游戏/渲染/存储/关于拆到分类文件实现。
//

#import "A2SettingsViewController.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Toast.h"

#import "A2SettingsSections.h"

@implementation A2SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"设置";

    [self buildAppearanceSection];
    [self buildGameSection];
    [self buildRendererSection];
    [self buildStorageSection];
    [self buildJITSection];
    [self buildAboutSection];
}

#pragma mark - 各分组组装

- (void)buildAppearanceSection {
    [self addSection:[A2AppearanceSettings buildWithHost:self]];
}

- (void)buildGameSection {
    [self addSection:[A2GameSettings buildWithHost:self]];
}

- (void)buildRendererSection {
    [self addSection:[A2RendererSettings buildWithHost:self]];
}

- (void)buildStorageSection {
    [self addSection:[A2StorageSettings buildWithHost:self]];
}

- (void)buildAboutSection {
    [self addSection:[A2AboutSettings buildWithHost:self]];
}

- (void)buildJITSection {
    [self addSection:[A2JITSettings buildWithHost:self]];
}

@end
