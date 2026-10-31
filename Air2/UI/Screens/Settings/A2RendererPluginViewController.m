//
//  A2RendererPluginViewController.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
//
//  A2RendererPluginViewController.m
//  Air2
//

#import "A2RendererPluginViewController.h"
#import "A2Renderer.h"
#import "A2RendererCatalog.h"
#import "A2RendererPlugin.h"
#import "A2RendererLibraryLayout.h"
#import "A2RendererImporter.h"
#import "A2GlassCard.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface A2RendererPluginViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) A2SettingsSection *importSection;
@property (nonatomic, strong) A2SettingsSection *importedSection;
@property (nonatomic, strong) UIStackView *pluginStack;
@property (nonatomic, strong) UILabel *emptyLabel;
/// 正在导入时禁止再点「导入」——两次导入会抢同一个目录名（导入器内部也串行，但 UI 上不该给出这个入口）
@property (nonatomic, assign) BOOL importing;
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
    __weak typeof(self) weakSelf = self;

    // ---- 说明 + 导入 ----
    A2SettingsSection *hint = [[A2SettingsSection alloc] initWithTitle:@"说明"];
    hint.footerText = [self environmentNote];

    A2SettingsRow *importRow = [[A2SettingsRow alloc] init];
    importRow.symbolName = @"square.and.arrow.down";
    importRow.title = @"导入渲染器…";
    importRow.subtitle = @"选择 .air2plugin 或 .zip 文件";
    importRow.accessory = A2SettingsRowAccessoryDisclosure;
    importRow.showsSeparator = NO;
    importRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self presentPicker];
    };
    [hint addRow:importRow];
    _importSection = hint;
    [self addSection:hint];

    // ---- 内置渲染器（只读，不可卸载）----
    // ★数据来自 A2RendererCatalog（候选表的唯一真相源）★，本页不另抄一份名单。
    A2SettingsSection *builtinSection = [[A2SettingsSection alloc] initWithTitle:@"内置渲染器"];
    builtinSection.footerText = @"内置渲染器随 App 一起分发，只能选择、不能删除；"
                                 "「未内置」表示包里没有这个库，选中会在启动时如实阻断。";
    NSString *frameworks = [NSBundle.mainBundle.bundlePath
                            stringByAppendingPathComponent:@"Frameworks"];
    for (A2Renderer *cand in [A2RendererCatalog allCandidates]) {
        BOOL bundled = [A2RendererCatalog isBundled:cand frameworksPath:frameworks];
        A2SettingsRow *builtinRow = [[A2SettingsRow alloc] init];
        builtinRow.symbolName = @"cube.transparent.fill";
        builtinRow.title = cand.displayName;
        builtinRow.subtitle = cand.identifier;
        builtinRow.valueText = bundled ? @"包内已内置" : @"包内未内置";
        builtinRow.accessory = A2SettingsRowAccessoryNone;
        builtinRow.enabled = NO;     // 只读：这里不是第二个选择入口
        [builtinSection addRow:builtinRow];
    }
    [self addSection:builtinSection];

    // ---- 已导入 ----
    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLabel.font = [A2Typography caption];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.text = @"还没有导入任何渲染器插件。\n导入后会出现在这里，并按实测结果标出能不能用。";

    _pluginStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _pluginStack.axis = UILayoutConstraintAxisVertical;
    _pluginStack.spacing = A2CardSpacing;

    A2SettingsSection *listSection = [[A2SettingsSection alloc] initWithTitle:@"已导入"];
    listSection.footerText = @"卸载只删插件目录；已选中的渲染器不受影响。";
    [listSection addCustomView:_emptyLabel];
    [listSection addCustomView:_pluginStack];
    _importedSection = listSection;
    [self addSection:listSection];
}

/// 当前环境的可用性说明 —— 这决定了用户导入的插件能不能直接用。
///
/// 不猜环境（不做「探测一下 dlopen」那种会崩的判定）：只把事实写清楚，
/// 具体能不能用由导入后的静态校验结果告诉用户。
- (NSString *)environmentNote {
    return @"iOS 要求动态库与 App 使用相同签名。"
            "TrollStore / 越狱环境下导入的库可以直接使用；"
            "其他环境需要把库注入 Air2 后重新签名才能加载。"
            "导入前会校验清单字段、库架构（必须是 iOS arm64 dylib）与导出符号。";
}

#pragma mark - 选文件

- (void)presentPicker {
    if (self.importing) {
        [A2Toast show:@"正在导入，请稍候" inView:self.view];
        return;
    }

    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        // 插件包是 .air2plugin / .zip，系统没有对应的 UTType，用 UTTypeData 兜底
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
    if (url == nil) return;

    // 复制到沙盒里的**独立**临时目录：系统给的是临时授权路径，
    // 导入读取会持续若干步；用 uuid 目录避免与上一次导入的同名文件互相覆盖。
    NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"renderer_plugin_%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:tmpDir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmp = [tmpDir stringByAppendingPathComponent:url.lastPathComponent];

    NSError *copyError = nil;
    if (![NSFileManager.defaultManager copyItemAtURL:url
                                              toURL:[NSURL fileURLWithPath:tmp]
                                              error:&copyError]) {
        [A2Toast show:(copyError.localizedDescription ?: @"无法读取文件") inView:self.view];
        [NSFileManager.defaultManager removeItemAtPath:tmpDir error:nil];
        return;
    }

    [self beginImportAtPath:tmp tempDir:tmpDir];
}

#pragma mark - 导入

- (void)beginImportAtPath:(NSString *)path tempDir:(NSString *)tempDir {
    self.importing = YES;
    [A2Toast show:@"正在导入…" inView:self.view];

    __weak typeof(self) weakSelf = self;
    [A2RendererImporter.shared importPluginAtPath:path
        progress:^(double progress, NSString *message) {
            (void)progress;
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil) return;
            // 进度只在空列表时借 emptyLabel 显示，避免导入过程中列表跳动
            if (self.emptyLabel.hidden == NO && message.length > 0) {
                self.emptyLabel.text = message;
            }
        }
        completion:^(A2RendererImportResult *result) {
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil) return;

            self.importing = NO;
            [NSFileManager.defaultManager removeItemAtPath:tempDir error:nil];

            if (!result.success) {
                [A2Toast show:(result.errorMessage ?: @"导入失败") inView:self.view];
                [self reloadPlugins];
                return;
            }

            A2RendererPlugin *plugin = result.plugin;
            if (result.alreadyInstalled) {
                [A2Toast show:[NSString stringWithFormat:@"「%@」已经装过同样的内容",
                               plugin.displayName ?: @"插件"] inView:self.view];
            } else if (plugin.availability == A2RendererAvailabilityAvailable) {
                NSString *verb = result.replacedExisting ? @"已更新" : @"导入成功";
                [A2Toast show:[NSString stringWithFormat:@"「%@」%@",
                               plugin.displayName ?: @"插件", verb] inView:self.view];
            } else {
                // 导入闸门会拦掉不可用的库，正常走不到这里；
                // 真走到了（比如校验口径变化）就如实说原因，不假装成功。
                [A2Toast show:[NSString stringWithFormat:@"「%@」已导入，但暂时无法加载：%@",
                               plugin.displayName ?: @"插件",
                               plugin.unavailableReason ?: @"未知原因"]
                       inView:self.view];
            }
            [self reloadPlugins];
        }];
}

#pragma mark - 列表

- (void)reloadPlugins {
    for (UIView *v in [_pluginStack.arrangedSubviews copy]) {
        [_pluginStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    NSArray<A2RendererPlugin *> *plugins = [A2RendererImporter.shared installedPlugins];
    _emptyLabel.hidden = (plugins.count > 0);
    if (!_emptyLabel.hidden) {
        _emptyLabel.text = @"还没有导入任何渲染器插件。\n导入后会出现在这里，并按实测结果标出能不能用。";
    }
    _emptyLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;

    _importedSection.sectionTitle = [NSString stringWithFormat:@"已导入（%lu）",
                                     (unsigned long)plugins.count];

    for (A2RendererPlugin *plugin in plugins) {
        [_pluginStack addArrangedSubview:[self cardForPlugin:plugin]];
    }
}

- (UIView *)cardForPlugin:(A2RendererPlugin *)plugin {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusL;
    card.elevation = A2CardElevationLow;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    A2ColorScheme *theme = A2ThemeManager.shared.scheme;

    // ---- 图标 ----
    UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.layer.cornerRadius = A2RadiusS;
    iconView.clipsToBounds = YES;
    if (plugin.iconPath.length > 0 &&
        [NSFileManager.defaultManager fileExistsAtPath:plugin.iconPath]) {
        iconView.image = [UIImage imageWithContentsOfFile:plugin.iconPath];
        iconView.contentMode = UIViewContentModeScaleAspectFill;
    } else {
        // 没有图标时用符号占位，不留一个空白方块
        iconView.image = [UIImage systemImageNamed:@"cube.transparent"];
        iconView.tintColor = theme.cPrimary;
        iconView.contentMode = UIViewContentModeCenter;
    }

    // ---- 名称 ----
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.textColor = theme.cOnSurface;
    title.text = plugin.displayName;

    // ---- 状态（能否加载 + 原因）----
    UILabel *status = [[UILabel alloc] initWithFrame:CGRectZero];
    status.font = [A2Typography caption];
    status.numberOfLines = 2;
    if (plugin.availability == A2RendererAvailabilityAvailable) {
        status.text = @"✓ 可用";
        status.textColor = theme.cPrimary;
    } else {
        status.text = [NSString stringWithFormat:@"⚠ %@", plugin.unavailableReason ?: @"不可用"];
        status.textColor = theme.cError;
    }

    // ---- 说明（作者自述，可为空）----
    UILabel *desc = [[UILabel alloc] initWithFrame:CGRectZero];
    desc.font = [A2Typography caption];
    desc.numberOfLines = 2;
    desc.textColor = theme.cOnSurfaceVariant;
    desc.text = plugin.pluginDescription;
    desc.hidden = (plugin.pluginDescription.length == 0);

    // ---- 元信息：版本 · 作者 · 库布局 · MC 范围 · 来源 ----
    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitle.font = [A2Typography caption];
    subtitle.numberOfLines = 3;
    subtitle.textColor = theme.cOnSurfaceVariant;
    NSMutableArray<NSString *> *bits = [NSMutableArray array];
    if (plugin.version.length) [bits addObject:[@"v" stringByAppendingString:plugin.version]];
    if (plugin.author.length) [bits addObject:plugin.author];
    [bits addObject:A2RendererLayoutDescription(plugin.libraryLayout)];
    if (plugin.minMCVer.length || plugin.maxMCVer.length) {
        [bits addObject:[NSString stringWithFormat:@"MC %@–%@",
                         plugin.minMCVer ?: @"?",
                         plugin.maxMCVer ?: @"?"]];
    }
    if (plugin.requiresJIT) [bits addObject:@"需要 JIT"];
    // 「是否内置」：本卡片只列导入项，内置那栏在页面上半部分 —— 这里写清来源
    [bits addObject:plugin.isImported ? @"用户导入" : @"内置"];
    if (plugin.sourceFileName.length) [bits addObject:plugin.sourceFileName];
    subtitle.text = [bits componentsJoinedByString:@" · "];

    // ---- 作者注意事项（ios.notes，可为空）----
    UILabel *notes = [[UILabel alloc] initWithFrame:CGRectZero];
    notes.font = [A2Typography caption];
    notes.numberOfLines = 2;
    notes.textColor = theme.cOnSurfaceVariant;
    notes.text = plugin.iosNotes.length ? [@"注意：" stringByAppendingString:plugin.iosNotes] : nil;
    notes.hidden = (plugin.iosNotes.length == 0);

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:
                              @[title, desc, status, subtitle, notes]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;

    // ---- 卸载（内置不可删：内置项根本不会走到这个卡片）----
    UIButton *remove = [UIButton buttonWithType:UIButtonTypeSystem];
    remove.translatesAutoresizingMaskIntoConstraints = NO;
    [remove setTitle:@"卸载" forState:UIControlStateNormal];
    remove.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [remove setTitleColor:theme.cError forState:UIControlStateNormal];
    remove.hidden = !plugin.isImported;
    __weak typeof(self) weakSelf = self;
    [remove addAction:[UIAction actionWithHandler:^(UIAction *action) {
        (void)action;
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
        [card.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:72],

        [textStack.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor
                                                constant:A2SpaceM],
        [textStack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [textStack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:remove.leadingAnchor
                                                           constant:-A2SpaceS],

        [remove.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [remove.centerYAnchor constraintEqualToAnchor:card.contentView.centerYAnchor],
        [remove.widthAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];

    return card;
}

- (void)confirmRemove:(A2RendererPlugin *)plugin {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"卸载插件"
                                            message:[NSString stringWithFormat:
                                                     @"确定要卸载「%@」吗？插件目录会被删除。",
                                                     plugin.displayName]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"卸载"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *action) {
        (void)action;
        __strong typeof(weakSelf) self = weakSelf;
        NSError *removeError = nil;
        if ([A2RendererImporter.shared removePlugin:plugin error:&removeError]) {
            [A2Toast show:@"已卸载" inView:self.view];
        } else {
            [A2Toast show:(removeError.localizedDescription ?: @"卸载失败") inView:self.view];
        }
        [self reloadPlugins];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
