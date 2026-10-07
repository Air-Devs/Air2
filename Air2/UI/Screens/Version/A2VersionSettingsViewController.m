//
//  A2VersionSettingsViewController.m
//  Air2
//
//  单版本设置。隔离逻辑与 ZL2 对齐：
//    开启隔离 → 游戏目录 = {gameHome}/versions/{版本名}/
//    未开启   → 自定义路径非空则用它，否则用 {gameHome}/
//

#import "A2VersionSettingsViewController.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2VersionSettingsViewController ()
@property (nonatomic, copy) NSString *versionName;
/// 隔离状态：0 跟随全局 / 1 开启 / 2 关闭
@property (nonatomic, assign) NSInteger isolationState;
@property (nonatomic, strong) A2SettingsRow *isolationRow;
@property (nonatomic, strong) A2SettingsRow *customPathRow;
@property (nonatomic, strong) A2SettingsSection *folderSection;
@end

@implementation A2VersionSettingsViewController

- (instancetype)initWithVersionName:(NSString *)versionName {
    self = [super init];
    if (!self) return nil;
    _versionName = [versionName copy];
    _isolationState = 0;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = _versionName;

    [self setupHeaderCard];
    [self setupIsolationSection];
    [self setupFolderSection];
    [self setupLaunchSection];
    [self setupDangerSection];

    [self updateIsolationUI];
}

#pragma mark - 顶部信息

- (void)setupHeaderCard {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    name.text = _versionName;
    name.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    name.textColor = t.cOnSurface;

    UILabel *path = [[UILabel alloc] initWithFrame:CGRectZero];
    path.translatesAutoresizingMaskIntoConstraints = NO;
    path.font = [A2Typography numeric];
    path.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    path.numberOfLines = 2;
    path.text = [NSString stringWithFormat:@"%@/versions/%@",
                 @"Documents/.minecraft", _versionName];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[name, path]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceS;

    [card.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [self addSection:card];
}

#pragma mark - 版本隔离

- (void)setupIsolationSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"版本隔离"];
    section.footerText = @"开启后，模组、存档、资源包、光影、截图都会放进这个版本自己的文件夹，"
                          "与其他版本互不影响。依赖库与资源文件始终共用，不会重复占用空间。";

    _isolationRow = [[A2SettingsRow alloc] init];
    _isolationRow.symbolName = @"square.split.2x1.fill";
    _isolationRow.title = @"隔离状态";
    _isolationRow.accessory = A2SettingsRowAccessoryDisclosure;
    __weak typeof(self) weakSelf = self;
    _isolationRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self showIsolationPicker];
    };
    [section addRow:_isolationRow];

    _customPathRow = [[A2SettingsRow alloc] init];
    _customPathRow.symbolName = @"folder.badge.questionmark";
    _customPathRow.title = @"自定义游戏目录";
    _customPathRow.subtitle = @"仅在未开启隔离时生效";
    _customPathRow.valueText = @"未设置";
    _customPathRow.accessory = A2SettingsRowAccessoryDisclosure;
    _customPathRow.showsBottomSeparator = NO;
    _customPathRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [A2Toast show:@"目录选择器" inView:self.view];
    };
    [section addRow:_customPathRow];

    [self addSection:section];
}

- (void)showIsolationPicker {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"版本隔离"
                                                                  message:@"选择这个版本使用的隔离策略"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSString *> *titles = @[@"跟随全局设置", @"开启隔离", @"关闭隔离"];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        __weak typeof(self) weakSelf = self;
        NSInteger index = i;
        [sheet addAction:[UIAlertAction actionWithTitle:titles[i]
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            __strong typeof(weakSelf) self = weakSelf;
            self.isolationState = index;
            [self updateIsolationUI];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = _isolationRow;
    sheet.popoverPresentationController.sourceRect = _isolationRow.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

/// 隔离状态变化时更新文案与可隔离目录的显示
- (void)updateIsolationUI {
    switch (_isolationState) {
        case 1:
            _isolationRow.valueText = @"已开启";
            _folderSection.footerText = [NSString stringWithFormat:
                @"这些目录当前位于 versions/%@/ 下。", _versionName];
            break;
        case 2:
            _isolationRow.valueText = @"已关闭";
            _folderSection.footerText = @"这些目录当前位于游戏根目录下，与其他版本共用。";
            break;
        default:
            _isolationRow.valueText = @"跟随全局";
            _folderSection.footerText = @"实际位置取决于全局的版本隔离设置。";
            break;
    }
    BOOL customEnabled = (_isolationState != 1);
    _customPathRow.alpha = customEnabled ? 1.0 : 0.4;
    _customPathRow.subtitle = customEnabled
        ? @"仅在未开启隔离时生效"
        : @"已开启隔离，此设置不生效";
}

#pragma mark - 可隔离目录

- (void)setupFolderSection {
    _folderSection = [[A2SettingsSection alloc] initWithTitle:@"版本内容"];

    NSArray<NSArray<NSString *> *> *folders = @[
        @[@"模组",   @"puzzlepiece.extension.fill"],
        @[@"资源包", @"photo.stack.fill"],
        @[@"存档",   @"map.fill"],
        @[@"光影包", @"sun.max.fill"],
        @[@"截图",   @"photo.fill"],
    ];

    for (NSUInteger i = 0; i < folders.count; i++) {
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = folders[i][1];
        row.title = folders[i][0];
        row.accessory = A2SettingsRowAccessoryDisclosure;
        NSString *name = folders[i][0];
        row.onTap = ^{
            [A2Toast show:[NSString stringWithFormat:@"打开%@目录", name] inView:self.view];
        };
        if (i == folders.count - 1) row.showsBottomSeparator = NO;
        [_folderSection addRow:row];
    }

    [self addSection:_folderSection];
}

#pragma mark - 启动配置

- (void)setupLaunchSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"启动配置"];
    section.footerText = @"留空则使用全局设置。";

    A2SettingsRow *ramRow = [[A2SettingsRow alloc] init];
    ramRow.symbolName = @"memorychip";
    ramRow.title = @"内存分配";
    ramRow.valueText = @"跟随全局";
    ramRow.accessory = A2SettingsRowAccessoryDisclosure;
    ramRow.onTap = ^{ [A2Toast show:@"内存分配" inView:self.view]; };
    [section addRow:ramRow];

    A2SettingsRow *rendererRow = [[A2SettingsRow alloc] init];
    rendererRow.symbolName = @"cube.transparent";
    rendererRow.title = @"渲染器";
    rendererRow.valueText = @"跟随全局";
    rendererRow.accessory = A2SettingsRowAccessoryDisclosure;
    rendererRow.onTap = ^{ [A2Toast show:@"渲染器选择" inView:self.view]; };
    [section addRow:rendererRow];

    A2SettingsRow *jvmRow = [[A2SettingsRow alloc] init];
    jvmRow.symbolName = @"terminal";
    jvmRow.title = @"JVM 参数";
    jvmRow.valueText = @"跟随全局";
    jvmRow.accessory = A2SettingsRowAccessoryDisclosure;
    jvmRow.onTap = ^{ [A2Toast show:@"JVM 参数" inView:self.view]; };
    [section addRow:jvmRow];

    A2SettingsRow *pinRow = [[A2SettingsRow alloc] init];
    pinRow.symbolName = @"pin.fill";
    pinRow.title = @"置顶此版本";
    pinRow.subtitle = @"在主页优先显示";
    pinRow.accessory = A2SettingsRowAccessorySwitch;
    pinRow.on = NO;
    pinRow.onToggle = ^(BOOL isOn) {};
    [section addRow:pinRow];

    A2SettingsRow *integrityRow = [[A2SettingsRow alloc] init];
    integrityRow.symbolName = @"checkmark.shield";
    integrityRow.title = @"跳过完整性检查";
    integrityRow.accessory = A2SettingsRowAccessorySwitch;
    integrityRow.showsBottomSeparator = NO;
    integrityRow.on = NO;
    integrityRow.onToggle = ^(BOOL isOn) {};
    [section addRow:integrityRow];

    [self addSection:section];
}

#pragma mark - 危险操作

- (void)setupDangerSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"管理"];

    A2SettingsRow *exportRow = [[A2SettingsRow alloc] init];
    exportRow.symbolName = @"square.and.arrow.up";
    exportRow.title = @"导出为整合包";
    exportRow.subtitle = @".mrpack 或 .zip";
    exportRow.accessory = A2SettingsRowAccessoryDisclosure;
    exportRow.onTap = ^{ [A2Toast show:@"导出整合包" inView:self.view]; };
    [section addRow:exportRow];

    A2SettingsRow *deleteRow = [[A2SettingsRow alloc] init];
    deleteRow.symbolName = @"trash";
    deleteRow.title = @"删除此版本";
    deleteRow.subtitle = @"可选择是否保留存档与模组";
    deleteRow.destructive = YES;
    deleteRow.showsBottomSeparator = NO;
    deleteRow.onTap = ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除版本"
                                                                       message:@"该操作不可撤销"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *a) {
            [A2Toast show:@"已删除" inView:self.view];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    };
    [section addRow:deleteRow];

    [self addSection:section];
}

@end
