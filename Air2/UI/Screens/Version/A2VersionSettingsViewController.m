//
//  A2VersionSettingsViewController.m
//  Air2
//
//  单版本设置 —— 真实读写版本的隔离配置。
//
//  隔离规则（与 ZL2 一致）：
//    开启隔离 → 游戏目录 = {gameHome}/versions/{版本名}/
//    未开启   → 自定义路径非空则用它，否则用 {gameHome}/
//
//  配置持久化在 {版本目录}/.air_version/config.json。
//

#import "A2VersionSettingsViewController.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2GlassCard.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2VersionManager.h"

@interface A2VersionSettingsViewController ()
/// 版本名（在 init 里赋值，后续只读）
@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, strong) A2Version *version;
@property (nonatomic, strong) A2SettingsRow *isolationRow;
@property (nonatomic, strong) A2SettingsRow *customPathRow;
@property (nonatomic, strong) A2SettingsRow *pathRow;
@property (nonatomic, strong) A2SettingsSection *folderSection;
@property (nonatomic, strong) NSMutableArray<A2SettingsRow *> *folderRows;
@end

@implementation A2VersionSettingsViewController

- (instancetype)initWithVersionName:(NSString *)versionName {
    self = [super init];
    if (!self) return nil;
    _versionName = [versionName copy];
    _folderRows = [NSMutableArray array];

    // 从管理器里找到对应版本（拿到真实的隔离配置）
    for (A2Version *v in A2VersionManager.shared.versions) {
        if ([v.name isEqualToString:versionName]) {
            _version = v;
            break;
        }
    }
    if (!_version) {
        _version = [[A2Version alloc] initWithName:versionName
                                          gameHome:A2VersionManager.shared.gameHome];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = _version.name;

    [self setupHeaderCard];
    [self setupIsolationSection];
    [self setupFolderSection];
    [self setupLaunchSection];
    [self setupDangerSection];

    [self refreshIsolationUI];
}

#pragma mark - 顶部信息

- (void)setupHeaderCard {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationLow;

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    name.textColor = t.cOnSurface;
    name.text = _version.name;

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectZero];
    status.font = [A2Typography caption];
    status.textColor = _version.isValid ? t.cSuccess : t.cError;
    status.text = _version.isValid ? @"版本文件完整" : @"版本文件不完整";

    UILabel *path = [[UILabel alloc] initWithFrame:CGRectZero];
    path.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    path.textColor = t.cOnSurfaceVariant;
    path.numberOfLines = 3;
    path.lineBreakMode = NSLineBreakByTruncatingMiddle;
    path.text = _version.versionPath;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[name, status, path]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceS;
    [stack setCustomSpacing:A2SpaceM afterView:status];

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
    _customPathRow.accessory = A2SettingsRowAccessoryDisclosure;
    _customPathRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [A2Toast show:@"目录选择器" inView:self.view];
    };
    [section addRow:_customPathRow];

    _pathRow = [[A2SettingsRow alloc] init];
    _pathRow.symbolName = @"folder.fill";
    _pathRow.title = @"当前游戏目录";
    _pathRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:_pathRow];

    [self addSection:section];
}

/// 实时刷新隔离相关文案 —— 每次改动都要重算路径
- (void)refreshIsolationUI {
    A2VersionIsolation *iso = _version.isolation;

    switch (iso.isolationType) {
        case A2SettingStateEnable:  _isolationRow.valueText = @"已开启"; break;
        case A2SettingStateDisable: _isolationRow.valueText = @"已关闭"; break;
        default:                    _isolationRow.valueText = @"跟随全局"; break;
    }

    BOOL customEnabled = (iso.isolationType != A2SettingStateEnable);
    _customPathRow.alpha = customEnabled ? 1.0 : 0.45;
    _customPathRow.subtitle = customEnabled
        ? @"仅在未开启隔离时生效"
        : @"已开启隔离，此设置不生效";
    _customPathRow.valueText = iso.customPath.length ? @"已设置" : @"未设置";

    // 显示实际生效的游戏目录
    NSString *dir = [_version gameDirectory];
    _pathRow.subtitle = dir;

    // 各可隔离目录的实际路径
    A2GamePath *path = [A2GamePath pathWithGameHome:A2VersionManager.shared.gameHome];
    for (NSUInteger i = 0; i < _folderRows.count && i < A2VersionFolderCount; i++) {
        NSString *d = [path directoryForFolder:(A2VersionFolder)i
                                   versionName:_version.name
                                     isolation:iso];
        _folderRows[i].valueText = [self shortenPath:d];
    }

    if (iso.isolationType == A2SettingStateEnable) {
        _folderSection.footerText = [NSString stringWithFormat:
            @"这些目录当前位于 versions/%@/ 下。", _version.name];
    } else if (iso.isolationType == A2SettingStateDisable) {
        _folderSection.footerText = @"这些目录当前位于游戏根目录下，与其他版本共用。";
    } else {
        _folderSection.footerText = @"实际位置取决于全局的版本隔离设置。";
    }
}

/// 路径太长，只显示最后两段
- (NSString *)shortenPath:(NSString *)path {
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count <= 2) return path;
    return [NSString stringWithFormat:@"…/%@/%@",
            parts[parts.count - 2], parts[parts.count - 1]];
}

- (void)showIsolationPicker {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"版本隔离"
                                            message:@"选择这个版本使用的隔离策略"
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSArray<NSString *> *> *options = @[
        @[@"跟随全局设置", @"使用启动器的全局隔离设置"],
        @[@"开启隔离",     @"此版本使用独立目录"],
        @[@"关闭隔离",     @"与其他版本共用目录"],
    ];

    for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
        __weak typeof(self) weakSelf = self;
        NSInteger state = i;
        [sheet addAction:[UIAlertAction actionWithTitle:options[i][0]
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            __strong typeof(weakSelf) self = weakSelf;
            self.version.isolation.isolationType = (A2SettingState)state;
            [self.version saveConfig];
            [self refreshIsolationUI];
            [A2Toast show:[NSString stringWithFormat:@"已设置为「%@」", options[state][0]]
                   inView:self.view];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = _isolationRow;
    sheet.popoverPresentationController.sourceRect = _isolationRow.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 可隔离目录

- (void)setupFolderSection {
    _folderSection = [[A2SettingsSection alloc] initWithTitle:@"版本内容"];
    A2VersionIsolation *iso = _version.isolation;
    A2GamePath *path = [A2GamePath pathWithGameHome:A2VersionManager.shared.gameHome];

    NSArray<NSString *> *symbols = @[@"puzzlepiece.extension.fill", @"photo.stack.fill",
                                     @"map.fill", @"sun.max.fill", @"photo.fill"];

    for (NSUInteger i = 0; i < A2VersionFolderCount; i++) {
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = symbols[i];
        row.title = A2VersionFolderDisplayName((A2VersionFolder)i);
        row.accessory = A2SettingsRowAccessoryDisclosure;

        NSString *folderName = A2VersionFolderDisplayName((A2VersionFolder)i);
        NSString *dir = [path directoryForFolder:(A2VersionFolder)i
                                     versionName:_version.name
                                       isolation:iso];
        row.onTap = ^{
            NSURL *url = [NSURL fileURLWithPath:dir];
            (void)url;
            [A2Toast show:[NSString stringWithFormat:@"%@：%@", folderName, dir]
                   inView:self.view];
        };

        [_folderRows addObject:row];
        [_folderSection addRow:row];
    }

    [self addSection:_folderSection];
}

#pragma mark - 启动配置

- (void)setupLaunchSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"启动配置"];
    section.footerText = @"留空则使用全局设置。这些配置存在版本的 .air_version/config.json 里。";

    A2VersionIsolation *iso = _version.isolation;

    A2SettingsRow *jvmRow = [[A2SettingsRow alloc] init];
    jvmRow.symbolName = @"terminal";
    jvmRow.title = @"JVM 参数";
    jvmRow.valueText = iso.jvmArgs.length ? iso.jvmArgs : @"跟随全局";
    jvmRow.accessory = A2SettingsRowAccessoryDisclosure;
    // 注意：row 持有 onTap，onTap 里若再强引用 row 就会形成循环。
    // 这里对 row 也用 weak 捕获。
    __weak A2SettingsRow *weakJvmRow = jvmRow;
    jvmRow.onTap = ^{
        __weak typeof(self) weakSelf = self;
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"JVM 参数"
                                                message:@"留空则使用全局设置"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = weakSelf.version.isolation.jvmArgs;
            tf.placeholder = @"-Xmx2G -XX:+UseG1GC";
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            weakSelf.version.isolation.jvmArgs = alert.textFields.firstObject.text;
            [weakSelf.version saveConfig];
            weakJvmRow.valueText = weakSelf.version.isolation.jvmArgs.length
                ? weakSelf.version.isolation.jvmArgs : @"跟随全局";
        }]];
        [weakSelf presentViewController:alert animated:YES completion:nil];
    };
    [section addRow:jvmRow];

    A2SettingsRow *gameArgsRow = [[A2SettingsRow alloc] init];
    gameArgsRow.symbolName = @"text.alignleft";
    gameArgsRow.title = @"游戏参数";
    gameArgsRow.valueText = iso.gameArgs.length ? iso.gameArgs : @"跟随全局";
    gameArgsRow.accessory = A2SettingsRowAccessoryDisclosure;
    __weak A2SettingsRow *weakGameArgsRow = gameArgsRow;
    gameArgsRow.onTap = ^{
        __weak typeof(self) weakSelf = self;
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"游戏参数"
                                                message:@"留空则使用全局设置"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = weakSelf.version.isolation.gameArgs;
            tf.placeholder = @"--width 1920 --height 1080";
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            weakSelf.version.isolation.gameArgs = alert.textFields.firstObject.text;
            [weakSelf.version saveConfig];
            weakGameArgsRow.valueText = weakSelf.version.isolation.gameArgs.length
                ? weakSelf.version.isolation.gameArgs : @"跟随全局";
        }]];
        [weakSelf presentViewController:alert animated:YES completion:nil];
    };
    [section addRow:gameArgsRow];

    A2SettingsRow *integrityRow = [[A2SettingsRow alloc] init];
    integrityRow.symbolName = @"checkmark.shield";
    integrityRow.title = @"跳过完整性检查";
    integrityRow.subtitle = @"启动更快，但可能掩盖文件损坏";
    integrityRow.accessory = A2SettingsRowAccessorySwitch;
    integrityRow.on = (iso.skipGameIntegrityCheck == A2SettingStateEnable);
    integrityRow.onToggle = ^(BOOL isOn) {
        __weak typeof(self) weakSelf = self;
        weakSelf.version.isolation.skipGameIntegrityCheck =
            isOn ? A2SettingStateEnable : A2SettingStateDisable;
        [weakSelf.version saveConfig];
    };
    [section addRow:integrityRow];

    [self addSection:section];
}

#pragma mark - 危险操作

- (void)setupDangerSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"管理"];

    A2SettingsRow *renameRow = [[A2SettingsRow alloc] init];
    renameRow.symbolName = @"square.and.pencil";
    renameRow.title = @"重命名版本";
    renameRow.accessory = A2SettingsRowAccessoryDisclosure;
    renameRow.onTap = ^{
        __weak typeof(self) weakSelf = self;
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"重命名版本"
                                                message:nil
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = weakSelf.version.name;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) self = weakSelf;
            NSString *newName = alert.textFields.firstObject.text;
            NSError *err = nil;
            if ([A2VersionManager.shared renameVersion:self.version to:newName error:&err]) {
                self.pageTitle = newName;
                [A2Toast show:@"已重命名" inView:self.view];
            } else {
                [A2Toast show:(err.localizedDescription ?: @"重命名失败") inView:self.view];
            }
        }]];
        [weakSelf presentViewController:alert animated:YES completion:nil];
    };
    [section addRow:renameRow];

    A2SettingsRow *deleteRow = [[A2SettingsRow alloc] init];
    deleteRow.symbolName = @"trash";
    deleteRow.title = @"删除此版本";
    deleteRow.subtitle = @"该操作不可撤销";
    deleteRow.destructive = YES;
    deleteRow.onTap = ^{
        __weak typeof(self) weakSelf = self;
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"删除版本"
                                                message:[NSString stringWithFormat:
                    @"将删除 %@ 及其所有文件，不可撤销。", weakSelf.version.name]
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) self = weakSelf;
            NSError *err = nil;
            if ([A2VersionManager.shared deleteVersion:self.version error:&err]) {
                [A2Toast show:@"已删除" inView:self.view];
                [self.navigationController popViewControllerAnimated:YES];
            } else {
                [A2Toast show:(err.localizedDescription ?: @"删除失败") inView:self.view];
            }
        }]];
        [weakSelf presentViewController:alert animated:YES completion:nil];
    };
    [section addRow:deleteRow];

    [self addSection:section];
}

@end
