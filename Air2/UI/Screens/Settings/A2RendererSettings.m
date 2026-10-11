//
//  A2RendererSettings.m
//  Air2
//
//  渲染设置 —— 对照 ZL2 的 RendererSettingsScreen。
//
//  设置项（截图里读到的全部）：
//    · 全局渲染器         下载图标 + 下拉
//    · Vulkan 驱动器      下载图标 + 下拉
//    · 图形 API           下拉
//    · 分辨率规则         下拉
//    · 游戏窗口分辨率      滑杆 + 数值胶囊
//    · 游戏页面全屏化      开关
//    · 持续性能模式        开关
//    · 使用系统 Vulkan 驱动 开关
//    · Zink 垂直同步       开关
//    · 使用独立渲染层      开关
//    · 着色器日志输出      开关
//
//  所有项都通过 A2Settings 的类型化属性读写并持久化。
//

#import "A2SettingsSections.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Slider.h"
#import "A2Settings.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@implementation A2RendererSettings

/// 返回该分类下的所有分组。
///
/// 注意与 A2AppearanceSettings 的差异：那边是单个 section，
/// 这里因为内容多，拆成三个 section（渲染 / 分辨率 / 行为）。
+ (NSArray<A2SettingsSection *> *)buildSectionsWithHost:(UIViewController *)host {
    return @[
        [self buildMainSectionWithHost:host],
        [self buildResolutionSection],
        [self buildBehaviorSection],
    ];
}

+ (A2SettingsSection *)buildMainSectionWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"渲染"];
    section.footerText = @"不同渲染器在不同设备上表现差异明显，"
                          "建议逐个尝试后选择最稳定的一个。";

    A2Settings *s = A2Settings.shared;

    // ---- 全局渲染器 ----
    A2SettingsRow *rendererRow = [[A2SettingsRow alloc] init];
    rendererRow.symbolName = @"cube.transparent";
    rendererRow.title = @"全局渲染器";
    rendererRow.subtitle = @"全局默认的渲染器，通过动态库转换层确保游戏能在移动端运行";
    rendererRow.valueText = [self valueLine:@"renderer" value:s.renderer];
    rendererRow.accessory = A2SettingsRowAccessoryDownloadable;
    __weak A2SettingsRow *weakRendererRow = rendererRow;
    rendererRow.onTap = ^{
        [self showPickerWithTitle:@"全局渲染器"
                            items:@[@"Krypton Wrapper", @"Zink (Kopper)", @"VirGL",
                                    @"GL4ES", @"NG-GL4ES", @"原版 OpenGL"]
                         selected:s.renderer ?: @"Krypton Wrapper"
                          currentRow:weakRendererRow
                                from:host
                          onSelected:^(NSString *v) { A2Settings.shared.renderer = v; }];
    };
    [section addRow:rendererRow];

    // ---- Vulkan 驱动器 ----
    A2SettingsRow *driverRow = [[A2SettingsRow alloc] init];
    driverRow.symbolName = @"bolt.horizontal.circle";
    driverRow.title = @"Vulkan 驱动器";
    driverRow.valueText = [self valueLine:@"vulkanDriver" value:s.vulkanDriver];
    driverRow.accessory = A2SettingsRowAccessoryDownloadable;
    __weak A2SettingsRow *weakDriverRow = driverRow;
    driverRow.onTap = ^{
        [self showPickerWithTitle:@"Vulkan 驱动器"
                            items:@[@"mainline-turnip-sync-V32",
                                    @"mainline-turnip-V31",
                                    @"系统默认驱动"]
                         selected:s.vulkanDriver
                          currentRow:weakDriverRow
                                from:host
                          onSelected:^(NSString *v) { A2Settings.shared.vulkanDriver = v; }];
    };
    [section addRow:driverRow];

    // ---- 图形 API ----
    A2SettingsRow *apiRow = [[A2SettingsRow alloc] init];
    apiRow.symbolName = @"square.stack.3d.down.right";
    apiRow.title = @"图形 API";
    apiRow.subtitle = @"设置 Minecraft 26.2+ 将使用的图形 API";
    apiRow.valueText = [self valueLine:@"graphicsApi" value:s.graphicsApi];
    apiRow.accessory = A2SettingsRowAccessoryDropdown;
    __weak A2SettingsRow *weakApiRow = apiRow;
    apiRow.onTap = ^{
        [self showPickerWithTitle:@"图形 API"
                            items:@[@"仅首次启动时设置为 OpenGL", @"强制 OpenGL",
                                    @"强制 Vulkan", @"跟随游戏设置"]
                         selected:s.graphicsApi
                          currentRow:weakApiRow
                                from:host
                          onSelected:^(NSString *v) { A2Settings.shared.graphicsApi = v; }];
    };
    [section addRow:apiRow];

    // ---- 分辨率规则 ----
    A2SettingsRow *ruleRow = [[A2SettingsRow alloc] init];
    ruleRow.symbolName = @"rectangle.compress.vertical";
    ruleRow.title = @"分辨率规则";
    ruleRow.subtitle = @"选择游戏窗口分辨率的计算规则";
    ruleRow.valueText = [self valueLine:@"resolutionRule" value:s.resolutionRule];
    ruleRow.showsBottomSeparator = NO;
    ruleRow.accessory = A2SettingsRowAccessoryDropdown;
    __weak A2SettingsRow *weakRuleRow = ruleRow;
    ruleRow.onTap = ^{
        [self showPickerWithTitle:@"分辨率规则"
                            items:@[@"百分比", @"固定分辨率", @"跟随设备"]
                         selected:s.resolutionRule
                          currentRow:weakRuleRow
                                from:host
                          onSelected:^(NSString *v) { A2Settings.shared.resolutionRule = v; }];
    };
    [section addRow:ruleRow];

    return section;
}

#pragma mark - 分辨率滑杆

+ (A2SettingsSection *)buildResolutionSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"分辨率"];

    A2Slider *slider = [[A2Slider alloc] initWithFrame:CGRectZero];
    slider.minimumValue = 10;
    slider.maximumValue = 200;
    slider.step = 5;
    slider.valueFormat = @"%.0f%%";
    [slider setValue:A2Settings.shared.renderScale animated:NO];
    slider.onValueChange = ^(CGFloat value) {
        A2Settings.shared.renderScale = (NSInteger)value;
    };

    [section addCustomView:[self sliderBlockWithTitle:@"游戏窗口分辨率"
                                             subtitle:@"数值越低性能越高，数值越高画质越清晰，根据实际需求进行调整"
                                               slider:slider]];
    return section;
}

/// 整行宽的滑杆块：标题 + 副标题 + 滑杆
+ (UIView *)sliderBlockWithTitle:(NSString *)title
                        subtitle:(NSString *)subtitle
                          slider:(A2Slider *)slider {
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    titleLabel.text = title;

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.font = [A2Typography caption];
    subtitleLabel.text = subtitle;
    subtitleLabel.numberOfLines = 0;

    [container addSubview:titleLabel];
    [container addSubview:subtitleLabel];
    [container addSubview:slider];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:container.topAnchor constant:A2SpaceM],
        [titleLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:A2SpaceL],
        [titleLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-A2SpaceL],

        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],

        [slider.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:A2SpaceM],
        [slider.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:A2SpaceL],
        [slider.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-A2SpaceL],
        [slider.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-A2SpaceM],
    ]];

    // 主题刷新
    [NSNotificationCenter.defaultCenter addObserverForName:A2ThemeDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        A2ColorScheme *t = A2ThemeManager.shared.scheme;
        titleLabel.textColor = t.cOnSurface;
        subtitleLabel.textColor = t.cOnSurfaceVariant;
    }];
    titleLabel.textColor = A2ThemeManager.shared.scheme.cOnSurface;
    subtitleLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;

    return container;
}

#pragma mark - 行为开关

+ (A2SettingsSection *)buildBehaviorSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"行为"];

    [self addSwitchToSection:section
                       title:@"游戏页面全屏化"
                    subtitle:@"使游戏页面全屏化，忽略刘海屏、挖孔屏等屏幕的安全区"
                         get:^BOOL{ return A2Settings.shared.fullscreenGame; }
                         set:^(BOOL v){ A2Settings.shared.fullscreenGame = v; }];

    [self addSwitchToSection:section
                       title:@"启用持续性能模式"
                    subtitle:@"启用后系统会为游戏提供更稳定的性能输出，"
                              "适用于长时间游玩，但可能略微降低设备响应速度以防止过热"
                         get:^BOOL{ return A2Settings.shared.sustainedPerformance; }
                         set:^(BOOL v){ A2Settings.shared.sustainedPerformance = v; }];

    [self addSwitchToSection:section
                       title:@"使用系统 Vulkan 驱动"
                    subtitle:@"启用后强制使用系统自带的 Vulkan 驱动，而不使用默认的 Turnip 驱动"
                         get:^BOOL{ return A2Settings.shared.useSystemVulkan; }
                         set:^(BOOL v){ A2Settings.shared.useSystemVulkan = v; }];

    [self addSwitchToSection:section
                       title:@"启用 Zink 垂直同步"
                    subtitle:@"通过系统接口为 Zink 渲染器启用垂直同步"
                         get:^BOOL{ return A2Settings.shared.zinkVSync; }
                         set:^(BOOL v){ A2Settings.shared.zinkVSync = v; }];

    [self addSwitchToSection:section
                       title:@"使用独立渲染层"
                    subtitle:@"使用独立于界面之外的图层进行渲染"
                         get:^BOOL{ return A2Settings.shared.useSurfaceView; }
                         set:^(BOOL v){ A2Settings.shared.useSurfaceView = v; }];

    [self addSwitchToSection:section
                       title:@"着色器日志输出"
                    subtitle:@"输出着色器编译日志，便于排查渲染问题"
                         get:^BOOL{ return A2Settings.shared.shaderLog; }
                         set:^(BOOL v){ A2Settings.shared.shaderLog = v; }];

    return section;
}

+ (void)addSwitchToSection:(A2SettingsSection *)section
                     title:(NSString *)title
                  subtitle:(NSString *)subtitle
                       get:(BOOL (^)(void))getter
                       set:(void (^)(BOOL))setter {
    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.title = title;
    row.subtitle = subtitle;
    row.accessory = A2SettingsRowAccessorySwitch;
    row.on = getter();
    row.onToggle = ^(BOOL isOn) { setter(isOn); };
    [section addRow:row];
}

#pragma mark - 工具

/// 「当前选择项：xxx」格式（ZL2 就是这么显示的）
+ (NSString *)valueLine:(NSString *)unused value:(NSString *)value {
    (void)unused;
    return [NSString stringWithFormat:@"当前选择项：%@",
            value.length ? value : @"未设置"];
}

/// 通用选择器。选中后更新行文案，并调 onSelected 持久化。
+ (void)showPickerWithTitle:(NSString *)title
                      items:(NSArray<NSString *> *)items
                   selected:(NSString *)selected
                 currentRow:(A2SettingsRow *)row
                       from:(UIViewController *)host
                 onSelected:(void (^)(NSString *))onSelected {

    __weak A2SettingsRow *weakRow = row;
    __weak UIViewController *weakHost = host;

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:title
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *item in items) {
        // 当前项前面打勾
        BOOL isCurrent = [item isEqualToString:selected];
        NSString *display = isCurrent ? [@"✓ " stringByAppendingString:item] : item;

        [sheet addAction:[UIAlertAction actionWithTitle:display
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            onSelected(item);
            weakRow.valueText = [NSString stringWithFormat:@"当前选择项：%@", item];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    sheet.popoverPresentationController.sourceView = weakRow;
    sheet.popoverPresentationController.sourceRect = weakRow.bounds;
    [weakHost presentViewController:sheet animated:YES completion:nil];
}

@end
