//
//  A2ModPackImportViewController.m
//  Air2
//

#import "A2ModPackImportViewController.h"
#import "A2ModPackInstaller.h"
#import "A2InstallingViewController.h"
#import "A2GlassCard.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

@interface A2ModPackImportViewController () <UIDocumentPickerDelegate>
@property (nonatomic, copy, nullable) NSString *pickedPath;
@property (nonatomic, strong, nullable) A2ModPackManifest *manifest;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) A2PrimaryButton *installButton;
@property (nonatomic, strong) A2SettingsSection *infoSection;
@end

@implementation A2ModPackImportViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"导入整合包";

    [self setupUI];
}

- (void)setupUI {
    // ---- 说明 ----
    A2SettingsSection *hint = [[A2SettingsSection alloc] initWithTitle:nil];
    hint.footerText = @"支持 Modrinth（.mrpack）与 CurseForge（.zip）两种格式。"
                       "文件可以来自任何地方 —— 网盘、群聊、其他设备的导出。";
    [self addSection:hint];

    // ---- 选文件 ----
    A2SettingsSection *pickSection = [[A2SettingsSection alloc] initWithTitle:@"选择文件"];
    A2SettingsRow *pickRow = [[A2SettingsRow alloc] init];
    pickRow.symbolName = @"doc.badge.plus";
    pickRow.title = @"选择整合包文件";
    pickRow.subtitle = @"从「文件」App 中选取 .mrpack 或 .zip";
    pickRow.accessory = A2SettingsRowAccessoryDisclosure;
    pickRow.showsBottomSeparator = NO;
    __weak typeof(self) weakSelf = self;
    pickRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self presentPicker];
    };
    [pickSection addRow:pickRow];
    [self addSection:pickSection];

    // ---- 解析结果 ----
    _infoSection = [[A2SettingsSection alloc] initWithTitle:@"整合包信息"];
    [self addSection:_infoSection];

    // ---- 安装按钮 ----
    _installButton = [[A2PrimaryButton alloc] initWithTitle:@"开始安装"
                                                      style:A2ButtonStylePrimary];
    _installButton.enabled = NO;
    _installButton.alpha = 0.5;
    [_installButton addTarget:self action:@selector(startInstall)
             forControlEvents:UIControlEventTouchUpInside];
    [self addSection:_installButton];
}

#pragma mark - 选文件

- (void)presentPicker {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data"]
                                                               inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    // 复制到沙盒 —— 系统给的是临时授权路径，安装过程会持续读它
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
    [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    NSError *copyErr = nil;
    if (![NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp]
                                               error:&copyErr]) {
        [A2Toast show:(copyErr.localizedDescription ?: @"无法读取文件") inView:self.view];
        return;
    }

    _pickedPath = tmp;
    [self parseAndShow];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // 用户取消，什么都不做
}

#pragma mark - 解析

- (void)parseAndShow {
    A2ModPackFormat fmt = [A2ModPackInstaller detectFormatAtPath:_pickedPath];
    if (fmt == A2ModPackFormatUnknown) {
        [A2Toast show:@"无法识别此整合包格式" inView:self.view];
        _installButton.enabled = NO;
        _installButton.alpha = 0.5;
        return;
    }

    [A2Toast show:@"正在解析…" inView:self.view];
    __weak typeof(self) weakSelf = self;
    [[A2ModPackInstaller new] parseManifestAtPath:_pickedPath
        completion:^(A2ModPackManifest *manifest, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (!manifest) {
            [A2Toast show:(error.localizedDescription ?: @"清单解析失败") inView:self.view];
            return;
        }

        self.manifest = manifest;
        [self renderManifest:manifest];

        self.installButton.enabled = YES;
        self.installButton.alpha = 1.0;
    }];
}

- (void)renderManifest:(A2ModPackManifest *)manifest {
    // 清空旧内容
    for (UIView *v in _infoSection.subviews) [v removeFromSuperview];

    NSArray<NSArray<NSString *> *> *rows = @[
        @[@"名称",       manifest.name ?: @"未命名"],
        @[@"格式",       manifest.format == A2ModPackFormatModrinth ? @"Modrinth" : @"CurseForge"],
        @[@"游戏版本",   manifest.gameVersion ?: @"未知"],
        @[@"加载器",     manifest.loaderIdentifier.length
                            ? [NSString stringWithFormat:@"%@ %@",
                               manifest.loaderIdentifier, manifest.loaderVersion ?: @""]
                            : @"原版（无加载器）"],
        @[@"待下载文件", [NSString stringWithFormat:@"%lu 个",
                            (unsigned long)manifest.files.count]],
    ];

    for (NSUInteger i = 0; i < rows.count; i++) {
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.title = rows[i][0];
        row.valueText = rows[i][1];
        row.accessory = A2SettingsRowAccessoryNone;
        if (i == rows.count - 1) row.showsBottomSeparator = NO;
        [_infoSection addRow:row];
    }
}

#pragma mark - 安装

- (void)startInstall {
    if (!_pickedPath || !_manifest) return;

    NSString *versionName = _manifest.name.length ? _manifest.name : @"Imported Pack";
    // 去掉路径不合法字符
    versionName = [versionName stringByReplacingOccurrencesOfString:@"/" withString:@"-"];

    A2InstallingViewController *vc =
        [[A2InstallingViewController alloc] initWithModPackPath:_pickedPath
                                                    versionName:versionName];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
