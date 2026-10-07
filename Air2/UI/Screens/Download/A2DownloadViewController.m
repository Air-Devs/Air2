//
//  A2DownloadViewController.m
//  Air2
//
//  下载中心。上部分是资源来源切换（Modrinth / CurseForge），
//  下面按分类列出入口。
//

#import "A2DownloadViewController.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2GlassCard.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2DownloadListViewController.h"

typedef NS_ENUM(NSInteger, A2ContentSource) {
    A2ContentSourceModrinth = 0,
    A2ContentSourceCurseForge,
};

@interface A2DownloadViewController ()
@property (nonatomic, assign) A2ContentSource source;
@property (nonatomic, strong) UISegmentedControl *sourceSwitch;
@property (nonatomic, strong) UILabel *sourceHint;
@end

@implementation A2DownloadViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"下载";
    self.source = A2ContentSourceModrinth;

    [self setupSourcePicker];
    [self setupGameSection];
    [self setupContentSection];
    [self setupMiscSection];
}

#pragma mark - 来源切换

- (void)setupSourcePicker {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusL;
    card.contentInsets = UIEdgeInsetsMake(A2SpaceM, A2SpaceM, A2SpaceM, A2SpaceM);

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.text = @"资源来源";

    _sourceSwitch = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    _sourceSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    _sourceSwitch.selectedSegmentIndex = 0;
    [_sourceSwitch addTarget:self action:@selector(sourceChanged) forControlEvents:UIControlEventValueChanged];

    _sourceHint = [[UILabel alloc] initWithFrame:CGRectZero];
    _sourceHint.translatesAutoresizingMaskIntoConstraints = NO;
    _sourceHint.font = [A2Typography caption];
    _sourceHint.numberOfLines = 0;
    _sourceHint.text = @"Modrinth 免费开放；CurseForge 部分作者禁止第三方分发，需要 API Key。";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, _sourceSwitch, _sourceHint]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceS;
    [stack setCustomSpacing:A2SpaceM afterView:_sourceSwitch];

    [card.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [self addSection:card];
}

- (void)sourceChanged {
    self.source = (A2ContentSource)_sourceSwitch.selectedSegmentIndex;
    _sourceHint.text = (self.source == A2ContentSourceModrinth)
        ? @"Modrinth 免费开放；CurseForge 部分作者禁止第三方分发，需要 API Key。"
        : @"CurseForge 资源更全，但需要在设置中填入 API Key 才能使用。";
    [A2Toast show:(self.source == A2ContentSourceModrinth ? @"已切换到 Modrinth" : @"已切换到 CurseForge")
           inView:self.view];
}

#pragma mark - 游戏版本

- (void)setupGameSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"游戏"];
    section.footerText = @"安装时可同时选择模组加载器，会自动匹配对应的版本。";

    A2SettingsRow *gameRow = [[A2SettingsRow alloc] init];
    gameRow.symbolName = @"cube.fill";
    gameRow.title = @"安装新版本";
    gameRow.subtitle = @"选择游戏版本与模组加载器";
    gameRow.accessory = A2SettingsRowAccessoryDisclosure;
    gameRow.onTap = ^{
        A2DownloadListViewController *vc = [[A2DownloadListViewController alloc] init];
        vc.category = A2DownloadCategoryGame;
        [self.navigationController pushViewController:vc animated:YES];
    };
    [section addRow:gameRow];

    A2SettingsRow *loaderRow = [[A2SettingsRow alloc] init];
    loaderRow.symbolName = @"shippingbox.fill";
    loaderRow.title = @"模组加载器";
    loaderRow.subtitle = @"Fabric / Forge / NeoForge / Quilt / OptiFine";
    loaderRow.valueText = @"Fabric";
    loaderRow.accessory = A2SettingsRowAccessoryDisclosure;
    loaderRow.showsBottomSeparator = NO;
    loaderRow.onTap = ^{ [A2Toast show:@"加载器选择" inView:self.view]; };
    [section addRow:loaderRow];

    [self addSection:section];
}

#pragma mark - 内容资源

- (void)setupContentSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"资源"];

    NSArray<NSArray<NSString *> *> *items = @[
        @[@"模组",     @"puzzlepiece.extension.fill", @"Install mods into a version"],
        @[@"光影包",   @"sun.max.fill",               @"Shaders"],
        @[@"资源包",   @"photo.stack.fill",           @"Resource packs"],
        @[@"整合包",   @"shippingbox.and.arrow.backward.fill", @"Modpacks"],
        @[@"存档",     @"map.fill",                   @"Worlds"],
    ];
    A2DownloadCategory categories[] = {
        A2DownloadCategoryMod,
        A2DownloadCategoryShader,
        A2DownloadCategoryResourcePack,
        A2DownloadCategoryModpack,
        A2DownloadCategoryWorld,
    };

    for (NSUInteger i = 0; i < items.count; i++) {
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = items[i][1];
        row.title = items[i][0];
        row.accessory = A2SettingsRowAccessoryDisclosure;
        A2DownloadCategory cat = categories[i];
        row.onTap = ^{
            A2DownloadListViewController *vc = [[A2DownloadListViewController alloc] init];
            vc.category = cat;
            [self.navigationController pushViewController:vc animated:YES];
        };
        if (i == items.count - 1) row.showsBottomSeparator = NO;
        [section addRow:row];
    }

    [self addSection:section];
}

#pragma mark - 其他

- (void)setupMiscSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"其他"];

    A2SettingsRow *taskRow = [[A2SettingsRow alloc] init];
    taskRow.symbolName = @"arrow.down.circle.dotted";
    taskRow.title = @"下载任务";
    taskRow.subtitle = @"查看进行中与已完成的任务";
    taskRow.accessory = A2SettingsRowAccessoryDisclosure;
    taskRow.onTap = ^{ [A2Toast show:@"下载任务列表" inView:self.view]; };
    [section addRow:taskRow];

    A2SettingsRow *importRow = [[A2SettingsRow alloc] init];
    importRow.symbolName = @"square.and.arrow.down";
    importRow.title = @"从本地导入整合包";
    importRow.subtitle = @".mrpack / .zip";
    importRow.accessory = A2SettingsRowAccessoryDisclosure;
    importRow.showsBottomSeparator = NO;
    importRow.onTap = ^{ [A2Toast show:@"选择文件" inView:self.view]; };
    [section addRow:importRow];

    [self addSection:section];
}

@end
