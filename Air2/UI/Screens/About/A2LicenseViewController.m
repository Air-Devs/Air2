//
//  A2LicenseViewController.m
//  Air2
//

#import "A2LicenseViewController.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Toast.h"

@implementation A2LicenseViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"开源许可";

    // 上游项目 —— 这些是 Air2 依赖的开源工作
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"上游项目"];
    section.footerText = @"Air2 基于 pojav 系后端开发，遵循 GPL-3.0 许可。"
                          "以下项目的许可协议各自独立，详见其仓库。";

    [self addLinkTo:section
              title:@"PojavLauncher"
           subtitle:@"启动核心与 Boardwalk"
                url:@"https://github.com/PojavLauncherTeam/PojavLauncher"];

    [self addLinkTo:section
              title:@"Amethyst-iOS-MyRemastered"
           subtitle:@"iOS 端 pojav 后端实现"
                url:@"https://github.com/herbrine8403/Amethyst-iOS-MyRemastered"];

    [self addLinkTo:section
              title:@"ZalithLauncher2"
           subtitle:@"架构与交互设计参考"
                url:@"https://github.com/ZalithLauncher/ZalithLauncher2"];

    [self addLinkTo:section
              title:@"Mesa"
           subtitle:@"OpenGL 实现（kopper / zink）"
                url:@"https://gitlab.freedesktop.org/mesa/mesa"];

    [self addLinkTo:section
              title:@"MoltenVK"
           subtitle:@"Vulkan → Metal 转译"
                url:@"https://github.com/KhronosGroup/MoltenVK"];

    [self addLinkTo:section
              title:@"LWJGL"
           subtitle:@"Java 图形与输入绑定"
                url:@"https://www.lwjgl.org"];

    [self addSection:section];

    // 本项目
    A2SettingsSection *selfSection = [[A2SettingsSection alloc] initWithTitle:@"本项目"];
    [self addLinkTo:selfSection
              title:@"Air2 源代码"
           subtitle:@"github.com/Air-Devs/Air2"
                url:@"https://github.com/Air-Devs/Air2"];
    [self addSection:selfSection];
}

- (void)addLinkTo:(A2SettingsSection *)section
            title:(NSString *)title
         subtitle:(NSString *)subtitle
              url:(NSString *)url {
    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.title = title;
    row.subtitle = subtitle;
    row.accessory = A2SettingsRowAccessoryDisclosure;
    row.onTap = ^{
        NSURL *u = [NSURL URLWithString:url];
        if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
    };
    [section addRow:row];
}

@end
