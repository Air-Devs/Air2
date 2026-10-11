//
//  A2VersionExportViewController.m
//  Air2
//

#import "A2VersionExportViewController.h"
#import "A2ModPackExporter.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2Typography.h"
#import "A2Metrics.h"

@interface A2VersionExportViewController ()
@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, copy) NSString *versionPath;

@property (nonatomic, assign) A2PackExportFormat format;
@property (nonatomic, copy) NSString *packName;
@property (nonatomic, copy) NSString *packAuthor;
@property (nonatomic, copy) NSString *packVersion;
@property (nonatomic, copy) NSString *packSummary;

@property (nonatomic, strong) A2SettingsRow *formatRow;
@property (nonatomic, strong) NSMutableArray<A2SettingsRow *> *infoRows;
@property (nonatomic, strong) NSArray<NSString *> *allFiles;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedFiles;
@property (nonatomic, strong) UILabel *countLabel;
@end

@implementation A2VersionExportViewController

- (instancetype)initWithVersionName:(NSString *)versionName
                        versionPath:(NSString *)versionPath {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _versionName = [versionName copy];
    _versionPath = [versionPath copy];
    _format = A2PackExportFormatModrinth;
    _packName = [versionName copy];
    _packAuthor = @"";
    _packVersion = @"1.0.0";
    _packSummary = @"";
    _selectedFiles = [NSMutableSet set];
    _infoRows = [NSMutableArray array];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"导出整合包";

    [self setupFormatSection];
    [self setupInfoSection];
    [self setupFilesSection];
    [self setupExportButton];
    [self scanFiles];
}

#pragma mark - 格式

- (void)setupFormatSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"导出格式"];
    section.footerText = @"Modrinth 的 .mrpack 是通用格式，多数启动器都支持；"
                          "CurseForge 的格式需要其客户端配合才能自动识别。";

    _formatRow = [[A2SettingsRow alloc] init];
    _formatRow.symbolName = @"shippingbox.fill";
    _formatRow.title = @"格式";
    _formatRow.valueText = @"Modrinth (.mrpack)";
    _formatRow.accessory = A2SettingsRowAccessoryDropdown;
    _formatRow.showsBottomSeparator = NO;

    __weak typeof(self) weakSelf = self;
    _formatRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self showFormatPicker];
    };

    [section addRow:_formatRow];
    [self addSection:section];
}

- (void)showFormatPicker {
    __weak typeof(self) weakSelf = self;
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"导出格式"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Modrinth (.mrpack)"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) self = weakSelf;
        self.format = A2PackExportFormatModrinth;
        self.formatRow.valueText = @"Modrinth (.mrpack)";
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"CurseForge (.zip)"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) self = weakSelf;
        self.format = A2PackExportFormatCurseForge;
        self.formatRow.valueText = @"CurseForge (.zip)";
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    sheet.popoverPresentationController.sourceView = _formatRow;
    sheet.popoverPresentationController.sourceRect = _formatRow.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 信息

- (void)setupInfoSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"整合包信息"];

    NSArray<NSArray<NSString *> *> *fields = @[
        @[@"名称", _packName],
        @[@"作者", _packAuthor],
        @[@"版本", _packVersion],
        @[@"简介", _packSummary],
    ];

    for (NSUInteger i = 0; i < fields.count; i++) {
        NSString *title = fields[i][0];
        NSString *value = fields[i][1];

        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.title = title;
        row.valueText = value.length ? value : @"未填写";
        row.accessory = A2SettingsRowAccessoryDisclosure;
        if (i == fields.count - 1) row.showsBottomSeparator = NO;

        __weak typeof(self) weakSelf = self;
        NSString *capturedTitle = [title copy];
        row.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self editField:capturedTitle];
        };

        [_infoRows addObject:row];
        [section addRow:row];
    }

    [self addSection:section];
}

- (void)editField:(NSString *)field {
    NSString *current = @"";
    if ([field isEqualToString:@"名称"]) current = _packName;
    else if ([field isEqualToString:@"作者"]) current = _packAuthor;
    else if ([field isEqualToString:@"版本"]) current = _packVersion;
    else if ([field isEqualToString:@"简介"]) current = _packSummary;

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:field
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = current;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSString *text = alert.textFields.firstObject.text ?: @"";

        if ([field isEqualToString:@"名称"]) self.packName = text;
        else if ([field isEqualToString:@"作者"]) self.packAuthor = text;
        else if ([field isEqualToString:@"版本"]) self.packVersion = text;
        else if ([field isEqualToString:@"简介"]) self.packSummary = text;

        [self refreshInfoRows];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

/// 更新信息行的显示值（不重建页面，避免丢焦点）
- (void)refreshInfoRows {
    NSDictionary<NSString *, NSString *> *map = @{
        @"名称": _packName.length ? _packName : @"未填写",
        @"作者": _packAuthor.length ? _packAuthor : @"未填写",
        @"版本": _packVersion.length ? _packVersion : @"未填写",
        @"简介": _packSummary.length ? _packSummary : @"未填写",
    };
    for (A2SettingsRow *row in _infoRows) {
        NSString *v = map[row.title];
        if (v) row.valueText = v;
    }
}

#pragma mark - 文件

- (void)setupFilesSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"导出内容"];

    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [A2Typography caption];
    _countLabel.numberOfLines = 0;
    _countLabel.text = @"正在扫描版本目录…";
    [section addCustomView:_countLabel];

    [self addSection:section];
}

- (void)scanFiles {
    __weak typeof(self) weakSelf = self;
    [[A2ModPackExporter new] scanVersionAtPath:_versionPath
        completion:^(NSArray<NSString *> *paths) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        self.allFiles = paths;
        [self.selectedFiles addObjectsFromArray:paths];

        self.countLabel.text = [NSString stringWithFormat:
            @"共 %lu 个文件，默认全部导出。\n"
            @"日志、崩溃报告、截图与启动器私有数据会自动排除。",
            (unsigned long)paths.count];
    }];
}

#pragma mark - 导出

- (void)setupExportButton {
    A2PrimaryButton *btn = [[A2PrimaryButton alloc] initWithTitle:@"导出"
                                                            style:A2ButtonStylePrimary];
    [btn addTarget:self action:@selector(doExport) forControlEvents:UIControlEventTouchUpInside];
    [self addSection:btn];
}

- (void)doExport {
    if (_packName.length == 0) {
        [A2Toast show:@"请填写整合包名称" inView:self.view];
        return;
    }

    A2PackExportOptions *opts = [A2PackExportOptions new];
    opts.packName = _packName;
    opts.summary = _packSummary;
    opts.author = _packAuthor;
    opts.version = _packVersion;
    opts.selectedPaths = _selectedFiles.allObjects;

    NSString *ext = (_format == A2PackExportFormatModrinth) ? @"mrpack" : @"zip";
    NSString *fileName = [NSString stringWithFormat:@"%@.%@", _packName, ext];
    NSString *outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];

    [A2Toast show:@"正在导出…" inView:self.view];

    __weak typeof(self) weakSelf = self;
    [[A2ModPackExporter new] exportVersionAtPath:_versionPath
                                          format:_format
                                         options:opts
                                      outputPath:outputPath
                                        progress:^(double p, NSString *message) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self) self.countLabel.text = message;
    }
                                      completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (!success) {
            [A2Toast show:(error.localizedDescription ?: @"导出失败") inView:self.view];
            return;
        }

        [A2Toast show:@"导出完成" inView:self.view];
        [self shareFileAtPath:outputPath];
    }];
}

- (void)shareFileAtPath:(NSString *)path {
    UIActivityViewController *vc =
        [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]]
                                          applicationActivities:nil];
    vc.popoverPresentationController.sourceView = self.view;
    vc.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:vc animated:YES completion:nil];
}

@end
