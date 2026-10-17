//
//  A2RendererPluginViewController.m
//  Air2
//

#import "A2RendererPluginViewController.h"
#import "A2RendererPlugin.h"
#import "A2RendererImporter.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface A2RendererPluginViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) UIStackView *pluginStack;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *envLabel;
@end

@implementation A2RendererPluginViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"渲染器插件";

    [self setupUI];
    [self reloadPlugins];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(reloadPlugins)
                                              name:A2RendererPluginsDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - UI

- (void)setupUI {
    // ---- 环境说明 ----
    A2SettingsSection *hint = [[A2SettingsSection alloc] initWithTitle:@"说明"];
    hint.footerText = [self environmentNote];

    A2SettingsRow *importRow = [[A2SettingsRow alloc] init];
    importRow.symbolName = @"square.and.arrow.down";
    importRow.title = @"导入插件包";
    importRow.subtitle = @"选择 .air2plugin 或 .zip 文件";
    importRow.accessory = A2SettingsRowAccessoryDisclosure;
    importRow.showsSeparator = NO;
    __weak typeof(self) weakSelf = self;
    importRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self presentPicker];
    };
    [hint addRow:importRow];
    [self addSection:hint];

    // ---- 已安装列表 ----
    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLabel.font = [A2Typography caption];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.text = @"还没有导入任何渲染器插件。\n导入后会出现在「设置 → 渲染」的渲染器列表里。";

    _pluginStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _pluginStack.axis = UILayoutConstraintAxisVertical;
    _pluginStack.spacing = A2CardSpacing;

    A2SettingsSection *listSection = [[A2SettingsSection alloc] initWithTitle:@"已导入"];
    [listSection addCustomView:_emptyLabel];
    [listSection addCustomView:_pluginStack];
    [self addSection:listSection];
}

/// 当前环境的可用性说明 —— 这决定了用户导入的插件能不能直接用
- (NSString *)environmentNote {
    // 能否加载未与 App 同签名的 dylib，取决于系统是否强制代码签名校验。
    // TrollStore 与越狱环境不强制；正常签名的 App 会。
    //
    // 这里的判断方式：尝试 dlopen 一个系统里必然不存在的路径 —— 不行。
    // 更实际的做法是让用户在导入后看到实测结果（validate 已经会给出）。
    // 所以文案只说事实，不猜环境。
    return @"iOS 要求动态库与 App 使用相同签名。"
            "TrollStore / 越狱环境下导入即可使用；"
            "其他环境需要在电脑上把库注入 Air2 后重新签名。"
            "导入后会显示每个库的实测结果。";
}

#pragma mark - 选文件

- (void)presentPicker {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        // 插件包通常是 .zip 或自定义扩展名，用 UTTypeData 兜底
        picker = [[UIDocumentPickerViewController alloc]
                  initForOpeningContentTypes:@[UTTypeData]
                                     asCopy:YES];
    } else {
        picker = [[UIDocumentPickerViewController alloc]
                  initWithDocumentTypes:@[@"public.data"]
                                 inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    // 复制到沙盒 —— 系统给的是临时授权路径，导入过程会持续读
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
    [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    NSError *copyErr = nil;
    if (![NSFileManager.defaultManager copyItemAtURL:url
                                              toURL:[NSURL fileURLWithPath:tmp]
                                              error:&copyErr]) {
        [A2Toast show:(copyErr.localizedDescription ?: @"无法读取文件") inView:self.view];
        return;
    }

    [A2Toast show:@"正在导入…" inView:self.view];

    __weak typeof(self) weakSelf = self;
    [A2RendererImporter.shared importPluginAtPath:tmp
        progress:^(double p, NSString *message) {
            __strong typeof(weakSelf) self = weakSelf;
            if (self) self.emptyLabel.text = message;
        }
        completion:^(A2RendererImportResult *result) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;

            if (!result.success) {
                [A2Toast show:(result.errorMessage ?: @"导入失败") inView:self.view];
                [self reloadPlugins];
                return;
            }

            // 导入成功 —— 按实测结果给不同的反馈
            A2RendererPlugin *p = result.plugin;
            if (p.availability == A2RendererAvailabilityAvailable) {
                [A2Toast show:[NSString stringWithFormat:@"「%@」导入成功，可以使用",
                               p.displayName] inView:self.view];
            } else {
                [A2Toast show:[NSString stringWithFormat:@"「%@」已导入，但暂时无法加载：%@",
                               p.displayName, p.unavailableReason ?: @"未知原因"]
                       inView:self.view];
            }

            [self reloadPlugins];
        }];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
}

#pragma mark - 列表

- (void)reloadPlugins {
    for (UIView *v in [_pluginStack.arrangedSubviews copy]) {
        [_pluginStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    NSArray<A2RendererPlugin *> *plugins = [A2RendererImporter.shared installedPlugins];
    _emptyLabel.hidden = (plugins.count > 0);

    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _emptyLabel.textColor = t.cOnSurfaceVariant;

    for (A2RendererPlugin *p in plugins) {
        [_pluginStack addArrangedSubview:[self cardForPlugin:p]];
    }
}

- (UIView *)cardForPlugin:(A2RendererPlugin *)plugin {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusL;
    card.elevation = A2CardElevationLow;

    // 图标 / 首字母
    UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFill;
    iconView.layer.cornerRadius = A2RadiusS;
    iconView.clipsToBounds = YES;

    if (plugin.iconPath && [NSFileManager.defaultManager fileExistsAtPath:plugin.iconPath]) {
        iconView.image = [UIImage imageWithContentsOfFile:plugin.iconPath];
    }

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.text = plugin.displayName;

    // 状态
    UILabel *status = [[UILabel alloc] initWithFrame:CGRectZero];
    status.font = [A2Typography caption];
    status.numberOfLines = 2;

    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    if (plugin.availability == A2RendererAvailabilityAvailable) {
        status.text = @"✓ 可用";
        status.textColor = t.cPrimary;
    } else {
        status.text = [NSString stringWithFormat:@"⚠ %@", plugin.unavailableReason ?: @"不可用"];
        status.textColor = t.cError;
    }

    // 副标题（描述 + 版本）
    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitle.font = [A2Typography caption];
    subtitle.numberOfLines = 2;
    subtitle.textColor = t.cOnSurfaceVariant;
    NSMutableArray *bits = [NSMutableArray array];
    if (plugin.pluginDescription.length) [bits addObject:plugin.pluginDescription];
    if (plugin.version.length) [bits addObject:[@"v" stringByAppendingString:plugin.version]];
    if (plugin.author.length) [bits addObject:plugin.author];
    subtitle.text = [bits componentsJoinedByString:@" · "];

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[title, status, subtitle]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;

    // 卸载按钮
    UIButton *remove = [UIButton buttonWithType:UIButtonTypeSystem];
    remove.translatesAutoresizingMaskIntoConstraints = NO;
    [remove setTitle:@"卸载" forState:UIControlStateNormal];
    remove.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [remove setTitleColor:t.cError forState:UIControlStateNormal];
    __weak typeof(self) weakSelf = self;
    [remove addAction:[UIAction actionWithHandler:^(UIAction *a) {
        __strong typeof(weakSelf) self = weakSelf;
        [self confirmRemove:plugin];
    }] forControlEvents:UIControlEventTouchUpInside];

    [card.contentView addSubview:iconView];
    [card.contentView addSubview:textStack];
    [card.contentView addSubview:remove];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:card.contentView.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:44],
        [iconView.heightAnchor constraintEqualToConstant:44],
        [card.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:60],

        [textStack.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor
                                                constant:A2SpaceM],
        [textStack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [textStack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:remove.leadingAnchor
                                                           constant:-A2SpaceS],

        [remove.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [remove.centerYAnchor constraintEqualToAnchor:card.contentView.centerYAnchor],
    ]];

    return card;
}

- (void)confirmRemove:(A2RendererPlugin *)plugin {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"卸载插件"
                                            message:[NSString stringWithFormat:
                                                     @"确定要卸载「%@」吗？", plugin.displayName]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"卸载"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) self = weakSelf;
        NSError *err = nil;
        if ([A2RendererImporter.shared removePlugin:plugin error:&err]) {
            [A2Toast show:@"已卸载" inView:self.view];
        } else {
            [A2Toast show:(err.localizedDescription ?: @"卸载失败") inView:self.view];
        }
        [self reloadPlugins];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
