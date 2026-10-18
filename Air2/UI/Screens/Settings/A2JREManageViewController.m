//
//  A2JREManageViewController.m
//  Air2
//

#import "A2JREManageViewController.h"
#import "A2JREManager.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface A2JREManageViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) A2SettingsSection *listSection;
@end

@implementation A2JREManageViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"Java 运行时";

    [self buildUI];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(reloadList)
                                              name:A2JREsDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - UI

- (void)buildUI {
    // ---- 安装位置说明 ----
    A2SettingsSection *hint = [[A2SettingsSection alloc] initWithTitle:@"说明"];
    hint.footerText = @"内置的 4 个 Java 版本（8/17/21/25）已随 App 打包，"
                       "覆盖了所有 Minecraft 版本的需求。"
                       "如果使用的是自定义构建的 JRE，可以导入。";
    [self addSection:hint];

    // ---- JRE 列表 ----
    _listSection = [[A2SettingsSection alloc] initWithTitle:@"已安装"];
    [self addSection:_listSection];
    [self reloadList];

    // ---- 导入入口 ----
    A2SettingsSection *importSec = [[A2SettingsSection alloc] initWithTitle:nil];
    A2SettingsRow *importRow = [[A2SettingsRow alloc] init];
    importRow.symbolName = @"square.and.arrow.down";
    importRow.title = @"导入 JRE";
    importRow.subtitle = @"选择包含 lib/server/libjvm.dylib 的目录";
    importRow.accessory = A2SettingsRowAccessoryDisclosure;
    importRow.showsSeparator = NO;
    __weak typeof(self) weakSelf = self;
    importRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self presentPicker];
    };
    [importSec addRow:importRow];
    [self addSection:importSec];
}

- (void)reloadList {
    if (_listSection) {
        [_listSection removeFromSuperview];
        _listSection = nil;
    }

    A2JREManager *mgr = A2JREManager.shared;
    NSArray<A2JRE *> *jres = mgr.allJREs;

    _listSection = [[A2SettingsSection alloc] initWithTitle:@"已安装"];
    if (jres.count == 0) {
        _listSection.footerText = @"还没有可用的 Java 运行时。"
                                   "请先跑 make jre 下载，或导入自定义 JRE。";
    }

    for (NSUInteger i = 0; i < jres.count; i++) {
        A2JRE *jre = jres[i];

        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = jre.valid ? @"cup.and.saucer.fill" : @"exclamationmark.triangle";
        row.title = jre.displayName;

        NSMutableArray *bits = [NSMutableArray array];
        if (jre.builtin) [bits addObject:@"内置"];
        if (jre.arch.length) [bits addObject:jre.arch];
        if (!jre.valid) {
            [bits addObject:jre.invalidReason ?: @"不可用"];
        } else {
            [bits addObject:jre.identifier];
        }
        row.subtitle = [bits componentsJoinedByString:@" · "];

        if (jre.valid) {
            row.accessory = A2SettingsRowAccessoryCheckmark;
        } else {
            row.accessory = A2SettingsRowAccessoryWarning;
        }
        if (i == jres.count - 1) row.showsSeparator = NO;

        __weak typeof(self) weakSelf = self;
        row.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self showActionsForJRE:jre];
        };

        [_listSection addRow:row];
    }

    [self insertSectionBefore:nil];
}

/// 把列表插到正确位置（在「说明」之后、「导入」之前）
- (void)insertSectionBefore:(UIView *)before {
    (void)before;
    if (!self.contentStack) {
        [self addSection:_listSection];
        return;
    }
    NSUInteger idx = [self.contentStack.arrangedSubviews indexOfObject:_listSection];
    if (idx != NSNotFound) return;   // 已在栈里
    [self.contentStack addArrangedSubview:_listSection];
}

#pragma mark - 操作

- (void)showActionsForJRE:(A2JRE *)jre {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:jre.displayName
                                            message:jre.path
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    if (!jre.builtin) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"删除"
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *a) {
            NSError *err = nil;
            if ([A2JREManager.shared removeJRE:jre error:&err]) {
                [A2Toast show:@"已删除" inView:self.view];
            } else {
                [A2Toast show:(err.localizedDescription ?: @"删除失败") inView:self.view];
            }
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentPicker {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc]
                  initForOpeningContentTypes:@[UTTypeFolder]];
    } else {
        picker = [[UIDocumentPickerViewController alloc]
                  initWithDocumentTypes:@[@"public.folder"]
                                 inMode:UIDocumentPickerModeOpen];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    [A2Toast show:@"正在导入…" inView:self.view];

    NSError *err = nil;
    if ([A2JREManager.shared importJREFromURL:url error:&err]) {
        [A2Toast show:@"导入成功" inView:self.view];
    } else {
        [A2Toast show:(err.localizedDescription ?: @"导入失败") inView:self.view];
    }
}

@end
