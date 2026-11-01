//
//  A2PluginListViewController.m
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
//  本文件两个类：
//    A2PluginListViewController    列表（见头文件）
//    A2PluginDetailViewController  详情（同一个 .m 里，只被列表页 push）
//
//  动作只有三条路径，且**每条只有一份实现**，两个页面都调同一份：
//    启用 / 禁用 → A2PluginSetEnabled     → A2PluginInstaller.applyEnabled:（写 registry 的 enabled）
//    卸载        → A2PluginConfirmUninstall → A2PluginInstaller.uninstallPluginId:
//    授权        → A2PluginPermissionSheet（③）
//  两个页面各自的 -reload / -rebuildSections 只负责重画，不参与判定 ——
//  「这一条算不算已授权」只由 A2PluginPermissionStore 回答，「能不能卸」只由安装器回答。

#import "A2PluginListViewController.h"

#import "A2Dialog.h"
#import "A2PluginBootGuard.h"
#import "A2PluginInstaller.h"
#import "A2PluginLaunchChainConfirm.h"
#import "A2PluginManifest.h"
#import "A2PluginPermissionSheet.h"
#import "A2PluginRegistry.h"
#import "A2PrimaryButton.h"
#import "A2SettingsRow.h"
#import "A2SettingsSection.h"
#import "A2Switch.h"
#import "A2Toast.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - 展示用的纯函数

/// ISO-8601 → 本地时间的人话日期。解析不了就原样显示 —— 不猜、不编。
static NSString *A2PluginDisplayDate(NSString *isoTimestamp) {
    if (isoTimestamp.length == 0) return @"未记录";
    static NSISO8601DateFormatter *parser;
    static NSDateFormatter *display;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        parser = [[NSISO8601DateFormatter alloc] init];
        display = [[NSDateFormatter alloc] init];
        display.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        display.dateFormat = @"yyyy-MM-dd HH:mm";
    });
    NSDate *date = [parser dateFromString:isoTimestamp];
    if (!date) return isoTimestamp;
    return [display stringFromDate:date];
}

/// 包哈希去掉 `sha256:` 前缀（注册表允许两种写法）。
static NSString *A2PluginNormalizedHash(NSString *hash) {
    if ([hash hasPrefix:@"sha256:"]) return [hash substringFromIndex:7];
    return hash ?: @"";
}

/// 管理页要求的「包哈希短串」= 前 8 位。完整值看 ③ 的授权页（那边有完整 64 位的展示）。
static NSString *A2PluginShortHash(NSString *hash) {
    NSString *value = A2PluginNormalizedHash(hash);
    if (value.length == 0) return @"未记录";
    if (value.length <= 8) return value;
    return [value substringToIndex:8];
}

/// 来源事实文本（PLUGIN-SECURITY 3.5 的四种写法逐字照抄）。
/// 只写「从哪里来」，不写「可不可信」；detail 为空时连括号都不出现。
static NSString *A2PluginSourceFactText(NSString *kind, NSString *detail) {
    NSString *verb = nil;
    if ([kind isEqualToString:@"local-import"]) {
        verb = @"从本地文件导入";
    } else if ([kind isEqualToString:@"url"]) {
        verb = @"从网址安装";
    } else if ([kind isEqualToString:@"share-sheet"]) {
        verb = @"从分享面板导入";
    } else if ([kind isEqualToString:@"dev-dir"]) {
        verb = @"开发目录";
    } else if (kind.length) {
        // 枚举外的值不该出现（注册表写入时就拦了）；真出现也只陈述原文，不翻译成评价。
        verb = [NSString stringWithFormat:@"来源 %@", kind];
    } else {
        verb = @"来源未记录";
    }
    if (detail.length == 0) return verb;
    return [NSString stringWithFormat:@"%@（%@）", verb, detail];
}

/// 错误 → 人话 + 机器码。机器码（`E_*`）是管理页的定位依据，别吞掉。
static NSString *A2PluginErrorText(NSError *error, NSString *fallback) {
    if (!error) return fallback;
    NSString *reason = error.localizedDescription ?: fallback;
    NSString *code = error.userInfo[A2PluginErrorCodeKey];
    if ([code isKindOfClass:NSString.class] && code.length) {
        return [NSString stringWithFormat:@"%@（%@）", reason, code];
    }
    return reason;
}

/// manifest 里申请的权限是否**全部**已授予。
static BOOL A2PluginAllPermissionsGranted(A2PluginPermissionStore *store,
                                          A2PluginManifest *manifest) {
    for (NSString *permissionId in manifest.permissions) {
        if (![store isGranted:permissionId forPlugin:manifest.pluginId]) return NO;
    }
    return YES;
}

/// 启用 / 禁用。启用前先确认「申请的权限都还授权着」，没齐就先打开 ③ 的授权页。
/// completion 在**主线程**回调；被拦下时 ok = NO 且 message 说明原因。
static void A2PluginSetEnabled(UIViewController *presenter,
                               A2PluginRegistry *registry,
                               A2PluginInstaller *installer,
                               A2PluginPermissionStore *store,
                               A2PluginMilestone hostMilestone,
                               NSString *pluginId,
                               BOOL enabled,
                               void (^completion)(BOOL ok, NSString *message)) {
    // 写开关只有一处：安装器管注册表写入（含 updatedAt），界面只负责问与展示。
    // 关闭不需要任何确认：能力变少，用户已经明确表态。
    if (!enabled) {
        NSError *error = nil;
        BOOL ok = [installer applyEnabled:NO forPluginId:pluginId error:&error];
        completion(ok, ok ? nil : A2PluginErrorText(error, @"写入失败"));
        return;
    }

    NSError *manifestError = nil;
    A2PluginManifest *manifest = [installer installedManifestForPluginId:pluginId
                                                                  error:&manifestError];
    if (!manifest) {
        // 连「这个插件要什么权限」都不知道的时候不放行：那时候授权页也打不开，
        // 「先跑起来再说」等于绕过整个授权流程。
        completion(NO, [NSString stringWithFormat:
                        @"读不出这个插件的 manifest，无法确认权限：%@",
                        A2PluginErrorText(manifestError, @"未知原因")]);
        return;
    }

    if (A2PluginAllPermissionsGranted(store, manifest)) {
        NSError *error = nil;
        BOOL ok = [installer applyEnabled:YES forPluginId:pluginId error:&error];
        completion(ok, ok ? nil : A2PluginErrorText(error, @"写入失败"));
        return;
    }

    // 有一项没授权 → 先让用户过一遍授权页，关掉之后再按他的意思启用。
    // 一项都不授权也允许启用（与安装页同一口径：装得上、功能受限）。
    A2PluginRegistryEntry *entry = [registry entryForPluginId:pluginId];
    [A2PluginPermissionSheet presentForManifest:manifest
                                          store:store
                                    packageHash:entry.packageHash
                                  hostMilestone:hostMilestone
                             fromViewController:presenter
                                     completion:^(NSArray<NSString *> *grantedPermissions) {
        NSError *writeError = nil;
        BOOL ok = [installer applyEnabled:YES forPluginId:pluginId error:&writeError];
        completion(ok, ok ? nil : A2PluginErrorText(writeError, @"写入失败"));
    }];
}

/// 卸载：二次确认 → 安装器删条目 + 删目录。
static void A2PluginConfirmUninstall(UIViewController *presenter,
                                     A2PluginInstaller *installer,
                                     NSString *pluginId,
                                     NSString *displayName,
                                     void (^completion)(BOOL ok, NSString *message)) {
    if ([installer.builtinPluginIds containsObject:pluginId]) {
        // 调用方已经把按钮置灰了，这里再兜一次：绕不过去。
        completion(NO, @"这个插件随 Air2 一起提供，不能卸载");
        return;
    }

    NSString *message = [NSString stringWithFormat:
                         @"「%@」（id：%@）的插件目录与注册表条目都会被删除，"
                         @"已经授予的权限记录一并消失。",
                         displayName.length ? displayName : pluginId, pluginId];
    [A2Dialog showInView:presenter.view
                   title:@"卸载这个插件？"
                 message:message
                 actions:@[
        [A2DialogAction actionWithTitle:@"取消" style:A2DialogActionStyleText handler:nil],
        [A2DialogAction actionWithTitle:@"卸载" style:A2DialogActionStyleDestructive handler:^{
            NSError *error = nil;
            BOOL ok = [installer uninstallPluginId:pluginId error:&error];
            completion(ok, ok ? nil : A2PluginErrorText(error, @"卸载失败"));
        }],
    ]];
}

#pragma mark - 详情页（只被列表页 push）

@interface A2PluginDetailViewController : A2BaseViewController

- (instancetype)initWithPluginId:(NSString *)pluginId
                        registry:(A2PluginRegistry *)registry
                       installer:(A2PluginInstaller *)installer
                           store:(A2PluginPermissionStore *)store
                   hostMilestone:(A2PluginMilestone)hostMilestone
                       didChange:(nullable void (^)(void))didChange NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

#pragma mark - 列表页

@interface A2PluginListViewController () <UIDocumentPickerDelegate>

@property (nonatomic, strong) A2PluginRegistry *registry;
@property (nonatomic, strong) A2PluginInstaller *installer;
@property (nonatomic, strong) A2PluginPermissionStore *store;

/// ★P1 第⑤块★ 进页面时结算出来的「因连续启动失败被自动停用」的条目。
/// 只是提示素材：某个插件是否仍然停用，一律以 reload 时读到的注册表为准。
@property (nonatomic, copy) NSArray<A2PluginRegistryEntry *> *autoDisabledEntries;

/// 安装结束（主线程）：报结果 / 重画 / 进授权页。
/// 安装跑在后台队列上（会改启动链的插件要在闸门里等 10 次确认），所以收尾单列一个方法。
- (void)finishImportWithResult:(nullable A2PluginInstallResult *)result
                         error:(nullable NSError *)error;

@end

@implementation A2PluginListViewController

+ (instancetype)defaultController {
    // P1 还没有插件运行时装配处：按默认目录建一套，注册表与安装器共用同一个实例。
    A2PluginRegistry *registry = [[A2PluginRegistry alloc] initWithPluginsDirectory:nil];
    A2PluginInstaller *installer = [[A2PluginInstaller alloc] initWithRegistry:registry];
    return [[self alloc] initWithRegistry:registry installer:installer];
}

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：没有注册表的列表页是非法状态。
    // 声明/实现一致性检查要求每个声明都有实现；正常代码走不到这里。
    return nil;
}

- (instancetype)initWithRegistry:(A2PluginRegistry *)registry
                       installer:(A2PluginInstaller *)installer {
    self = [super init];
    if (self) {
        _registry = registry;
        _installer = installer;
        _store = [[A2PluginPermissionStore alloc] initWithRegistry:registry];
        _hostMilestone = A2PluginMilestoneP1;
    }
    return self;
}

#pragma mark 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"插件";
    // ★P1 第⑤块★ 插件页是用户唯一能自救的地方：进来先把上一次启动留下的账
    // 结算掉（第 1、2 次只累加；第 3 次在这里把插件停用），再把结果做成首屏提示。
    // 只在 viewDidLoad 结算一次：viewWillAppear 会反复来，重复结算虽然幂等，
    // 但没必要每次都读盘写盘。
    self.autoDisabledEntries = [A2PluginBootGuard evaluatePreviousLaunch];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 详情页里可能刚启停 / 卸载过，回来一律按磁盘重画。
    [self reload];
}

#pragma mark 重画

- (void)reload {
    for (UIView *view in [self.contentStack.arrangedSubviews copy]) {
        [self.contentStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSError *error = nil;
    if (![self.registry loadWithError:&error]) {
        // ① 的约定：读失败绝不覆写原文件。这一页因此只读，一个字节都不写。
        [self addSection:[self registryErrorSection:error]];
        return;
    }

    NSArray<A2PluginRegistryEntry *> *entries = [self.registry allEntries];
    if (entries.count == 0) {
        [self addSection:[self emptySection]];
        return;
    }

    // ★P1 第⑤块★ 自动停用的提示放最上面：用户进这一页多半就是来找
    // 「为什么游戏起不来」，答案不该藏在列表末尾。
    NSArray<A2PluginRegistryEntry *> *autoDisabled = [self currentlyAutoDisabledEntries];
    if (autoDisabled.count > 0) {
        [self addSection:[self autoDisableSectionWithEntries:autoDisabled]];
    }

    A2SettingsSection *listSection = [[A2SettingsSection alloc] initWithTitle:@"已安装"];
    listSection.footerText = @"点一行看详情。开关只决定插件要不要被加载，不改变已经授予的权限。";
    for (A2PluginRegistryEntry *entry in entries) {
        // 每个插件读一次它自己的 manifest：名字、作者、功能是否受限都要它。
        // 安装器这一步会重读注册表，条目内容不变（只是对象换了），
        // 所以这里继续用手里这份快照显示是安全的；写入一律按 id 现查。
        A2PluginManifest *manifest = [self.installer installedManifestForPluginId:entry.pluginId
                                                                           error:NULL];
        [listSection addRow:[self rowForEntry:entry manifest:manifest]];
    }
    [self addSection:listSection];
    [self addSection:[self importSection]];
}

- (A2SettingsSection *)registryErrorSection:(NSError *)error {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"插件"];
    section.footerText = @"注册表读不出来时这一页不做任何写入 —— 重建空表等于在没有任何副本的情况下"
                         "把用户的插件记录抹掉。";

    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = @"exclamationmark.triangle";
    row.title = @"注册表读不出来";
    row.subtitle = error.localizedDescription ?: @"未知原因";
    row.accessory = A2SettingsRowAccessoryNone;
    [section addRow:row];
    return section;
}

- (A2SettingsSection *)emptySection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"插件"];
    section.footerText = @"插件包是 .air2plugin 文件。安装之后可以在这里启用、逐项看权限、卸载。";

    A2SettingsRow *emptyRow = [[A2SettingsRow alloc] init];
    emptyRow.symbolName = @"puzzlepiece.extension";
    emptyRow.title = @"还没有安装插件";
    emptyRow.subtitle = @"导入的插件会出现在这个列表里";
    emptyRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:emptyRow];

    A2PrimaryButton *importButton =
        [[A2PrimaryButton alloc] initWithTitle:@"导入插件…" style:A2ButtonStylePrimary];
    [importButton addTarget:self
                     action:@selector(handleImportTap)
           forControlEvents:UIControlEventTouchUpInside];
    [section addCustomView:importButton];
    return section;
}

- (A2SettingsSection *)importSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:nil];
    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = @"square.and.arrow.down";
    row.title = @"导入插件…";
    row.subtitle = @"选择 .air2plugin 文件";
    row.accessory = A2SettingsRowAccessoryDisclosure;
    __weak typeof(self) weakSelf = self;
    row.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self presentPluginPicker];
    };
    [section addRow:row];
    return section;
}

#pragma mark 启动保护提示（P1 第⑤块）

/// 结算结果里**现在仍然停用**的那些（用户可能刚在详情页手动打开了）。
- (NSArray<A2PluginRegistryEntry *> *)currentlyAutoDisabledEntries {
    NSMutableArray<A2PluginRegistryEntry *> *result = [NSMutableArray array];
    for (A2PluginRegistryEntry *recorded in self.autoDisabledEntries) {
        A2PluginRegistryEntry *current = [self.registry entryForPluginId:recorded.pluginId];
        if (current && !current.isEnabled) [result addObject:current];
    }
    return result;
}

/// 一行提示：哪些插件被自动停用了、为什么。
- (A2SettingsSection *)autoDisableSectionWithEntries:
        (NSArray<A2PluginRegistryEntry *> *)entries {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"启动保护"];
    section.footerText = [NSString stringWithFormat:
        @"这些插件连续 %ld 次启动都没有进入游戏画面，宿主已先把它们停用，好让游戏能起来。"
         @"确认是插件的问题就保持停用；想再试一次，回详情页手动打开即可。",
        (long)A2PluginBootGuardAutoDisableThreshold];

    for (A2PluginRegistryEntry *entry in entries) {
        A2PluginManifest *manifest = [self.installer installedManifestForPluginId:entry.pluginId
                                                                           error:NULL];
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = @"exclamationmark.triangle.fill";
        row.title = [NSString stringWithFormat:@"已自动停用：%@",
                     manifest.name.length ? manifest.name : entry.pluginId];
        row.subtitle = entry.lastAutoDisabledReason.length ? entry.lastAutoDisabledReason
                                                           : @"启动多次失败";
        row.accessory = A2SettingsRowAccessoryNone;
        [section addRow:row];
    }
    return section;
}

/// 列表行：图标 + 名称 + 版本 + 来源事实 + 启用开关。
///
/// 开关走 `customAccessoryView` 而不是 `A2SettingsRowAccessorySwitch`：
/// 后者会让整行变成「点哪都切开关」，没有地方点进详情。
/// 用自定义附件时，开关自己接收点击，行的其余部分仍然可以点开详情。
- (A2SettingsRow *)rowForEntry:(A2PluginRegistryEntry *)entry
                      manifest:(nullable A2PluginManifest *)manifest {
    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = @"puzzlepiece.extension.fill";
    row.title = manifest.name.length ? manifest.name : entry.pluginId;

    NSMutableArray<NSString *> *facts = [NSMutableArray array];
    [facts addObject:[NSString stringWithFormat:@"v%@", entry.version]];
    [facts addObject:A2PluginSourceFactText(entry.sourceKind, entry.sourceDetail)];
    if (manifest && !A2PluginAllPermissionsGranted(self.store, manifest)) {
        // 与安装页同一口径：没授权齐也能用，只是功能受限。
        [facts addObject:@"功能受限"];
    }
    row.subtitle = [facts componentsJoinedByString:@" · "];
    row.accessibilityIdentifier = entry.pluginId;

    A2Switch *toggle = [[A2Switch alloc] initWithFrame:CGRectZero];
    [toggle setOn:entry.isEnabled animated:NO];
    row.customAccessoryView = toggle;

    NSString *pluginId = [entry.pluginId copy];
    __weak typeof(self) weakSelf = self;
    toggle.onChange = ^(BOOL isOn) {
        __strong typeof(weakSelf) self = weakSelf;
        [self applyEnabled:isOn forPluginId:pluginId];
    };
    row.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self showDetailForPluginId:pluginId];
    };
    return row;
}

#pragma mark 动作

- (void)applyEnabled:(BOOL)enabled forPluginId:(NSString *)pluginId {
    __weak typeof(self) weakSelf = self;
    A2PluginSetEnabled(self, self.registry, self.installer, self.store, self.hostMilestone,
                       pluginId, enabled,
                       ^(BOOL ok, NSString *message) {
        // 下一轮 runloop 再重画：这个回调是从开关（行的子视图）的点击里出来的，
        // 当场把那一行拆掉等于在控件自己的方法栈里释放它的父视图。
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!ok) [A2Toast show:(message ?: @"操作失败") inView:self.view];
            // 无论成功、被拦下还是失败，都按磁盘重画：开关停在错误的位置比报错更糟。
            [self reload];
        });
    });
}

- (void)showDetailForPluginId:(NSString *)pluginId {
    A2PluginDetailViewController *detail =
        [[A2PluginDetailViewController alloc] initWithPluginId:pluginId
                                                      registry:self.registry
                                                     installer:self.installer
                                                         store:self.store
                                                 hostMilestone:self.hostMilestone
                                                     didChange:nil];
    [self.navigationController pushViewController:detail animated:YES];
}

#pragma mark 导入

- (void)handleImportTap {
    [self presentPluginPicker];
}

- (void)presentPluginPicker {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        // .air2plugin 是自定义扩展名，没有系统声明的 UTType：按扩展名换一个动态类型，
        // 拿不到时退回 UTTypeData（不能因此什么都选不了）。
        UTType *type = [UTType typeWithFilenameExtension:@"air2plugin"] ?: UTTypeData;
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[type]
                                                                            asCopy:YES];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data"]
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

    NSError *error = nil;
    // 来源只记事实：kind = 本地文件导入，detail = 文件名（② 的安装器写入注册表）。
    A2PluginInstallSource *source =
        [A2PluginInstallSource sourceWithKind:@"local-import"
                                       detail:url.lastPathComponent
                                        error:&error];
    if (!source) {
        [A2Toast show:A2PluginErrorText(error, @"无法记录安装来源") inView:self.view];
        return;
    }

    // ★安装放到后台线程★：会修改启动链的插件要在闸门里等用户点完 10 次免责确认，
    //   闸门是同步返回的（`A2PluginLaunchChainGate`），主线程上做不了这件事
    //   （弹窗自己跳主线程，见 A2PluginLaunchChainConfirm）。
    A2PluginInstaller *installer = self.installer;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *installError = nil;
        A2PluginInstallResult *result = [installer
            installPackageAtURL:url
                         source:source
                launchChainGate:^BOOL(A2PluginManifest *manifest,
                                      NSArray<NSString *> *permissions) {
            // 闸门可能在后台线程被调用；同步版内部派发到主线程弹窗并等结果。
            // ★self 只作宿主控制器用★：控制器已释放（用户退回上一页）⇒ 传 nil ⇒ 确认失败 ⇒ 不安装。
            return [A2PluginLaunchChainConfirm confirmSynchronouslyForManifest:manifest
                                                                   permissions:permissions
                                                                          from:weakSelf];
        }
                          error:&installError];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self finishImportWithResult:result error:installError];
        });
    });
}

/// 安装结束（主线程）：报结果 → 重画 → 进授权页。
/// ★从「后台装完」这条路上来★：所以这里是独立方法，不在 documentPicker 的栈里。
- (void)finishImportWithResult:(nullable A2PluginInstallResult *)result
                         error:(nullable NSError *)error {
    if (!result) {
        // ★用户取消不是失败★：10 次免责确认里点了「取消」时，如实说「已取消」，
        // 不报「安装失败」（那会让用户以为包坏了，回头又装一遍）。
        NSString *code = error.userInfo[A2PluginErrorCodeKey];
        if ([code isEqualToString:A2PluginErrorCodeString(A2PluginErrorUserCancelled)]) {
            [A2Toast show:@"已取消安装（这个插件会修改启动链）" inView:self.view];
        } else {
            [A2Toast show:A2PluginErrorText(error, @"安装失败") inView:self.view];
        }
        [self reload];
        return;
    }

    [self reload];

    if (result.reusedExisting) {
        [A2Toast show:@"已经装过这一版，没有改动" inView:self.view];
        return;
    }

    // 装完直接进 ③ 的授权页：低/中默认已开、critical 默认关，用户可以当场过一遍。
    NSError *manifestError = nil;
    A2PluginManifest *manifest = [self.installer installedManifestForPluginId:result.entry.pluginId
                                                                       error:&manifestError];
    if (!manifest) {
        [A2Toast show:[NSString stringWithFormat:@"已安装，但读不出它的 manifest：%@",
                       A2PluginErrorText(manifestError, @"未知原因")]
               inView:self.view];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [A2PluginPermissionSheet presentForManifest:manifest
                                          store:self.store
                                    packageHash:result.contentHash
                                  hostMilestone:self.hostMilestone
                             fromViewController:self
                                     completion:^(NSArray<NSString *> *grantedPermissions) {
        __strong typeof(weakSelf) self = weakSelf;
        [self reload];
    }];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
}

@end

#pragma mark - 详情页

@interface A2PluginDetailViewController ()

@property (nonatomic, copy) NSString *pluginId;
/// 宿主里程碑：决定哪些权限显示「当前版本不可用」，与列表页的 hostMilestone 同值。
@property (nonatomic, assign) A2PluginMilestone milestone;
@property (nonatomic, strong) A2PluginRegistry *registry;
@property (nonatomic, strong) A2PluginInstaller *installer;
@property (nonatomic, strong) A2PluginPermissionStore *store;
@property (nonatomic, copy, nullable) void (^didChange)(void);
@property (nonatomic, assign) BOOL didPushOnce;

@end

@implementation A2PluginDetailViewController

- (instancetype)init {
    // 与类扩展里的 NS_UNAVAILABLE 对应；见列表页同名方法。
    return nil;
}

- (instancetype)initWithPluginId:(NSString *)pluginId
                        registry:(A2PluginRegistry *)registry
                       installer:(A2PluginInstaller *)installer
                           store:(A2PluginPermissionStore *)store
                   hostMilestone:(A2PluginMilestone)hostMilestone
                       didChange:(nullable void (^)(void))didChange {
    self = [super init];
    if (self) {
        _pluginId = [pluginId copy];
        _registry = registry;
        _installer = installer;
        _store = store;
        _milestone = hostMilestone;
        _didChange = [didChange copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = self.pluginId;
    [self rebuildSections];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 授权页可能刚改过权限，回来按磁盘重画。
    if (self.didPushOnce) [self rebuildSections];
    self.didPushOnce = YES;
}

- (void)rebuildSections {
    for (UIView *view in [self.contentStack.arrangedSubviews copy]) {
        [self.contentStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSError *loadError = nil;
    if (![self.registry loadWithError:&loadError]) {
        [self addSection:[self messageSectionWithSectionTitle:@"这个插件"
                                                       title:@"注册表读不出来"
                                                    subtitle:(loadError.localizedDescription ?: @"未知原因")]];
        return;
    }
    A2PluginRegistryEntry *entry = [self.registry entryForPluginId:self.pluginId];
    if (!entry) {
        // 条目没了 = 这个插件已经不在了（本页之外被卸载）。留在一个空页面上没有意义。
        if (self.navigationController.topViewController == self) {
            [self.navigationController popViewControllerAnimated:YES];
        }
        return;
    }

    NSError *manifestError = nil;
    A2PluginManifest *manifest = [self.installer installedManifestForPluginId:self.pluginId
                                                                       error:&manifestError];
    self.pageTitle = manifest.name.length ? manifest.name : entry.pluginId;

    [self addSection:[self identitySectionWithEntry:entry
                                           manifest:manifest
                                      manifestError:manifestError]];
    [self addSection:[self sourceSectionWithEntry:entry]];
    for (A2SettingsSection *section in [self permissionSectionsWithManifest:manifest
                                                                manifestError:manifestError]) {
        [self addSection:section];
    }
    [self addSection:[self actionSectionWithEntry:entry manifest:manifest]];
}

/// 一段只有一行说明的卡（读表失败 / manifest 读不出来这类「如实说」的地方）。
- (A2SettingsSection *)messageSectionWithSectionTitle:(NSString *)sectionTitle
                                                title:(NSString *)title
                                             subtitle:(NSString *)subtitle {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:sectionTitle];
    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = @"exclamationmark.triangle";
    row.title = title;
    row.subtitle = subtitle;
    row.accessory = A2SettingsRowAccessoryNone;
    [section addRow:row];
    return section;
}

#pragma mark 基本信息

- (A2SettingsSection *)identitySectionWithEntry:(A2PluginRegistryEntry *)entry
                                       manifest:(nullable A2PluginManifest *)manifest
                                  manifestError:(nullable NSError *)manifestError {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"这个插件"];
    section.footerText = @"Air2 不验证作者身份。哈希只能证明「包没变」，不能证明「是谁做的」。";

    if (!manifest) {
        A2SettingsRow *brokenRow = [[A2SettingsRow alloc] init];
        brokenRow.symbolName = @"exclamationmark.triangle";
        brokenRow.title = @"安装目录里的 manifest 读不出来";
        brokenRow.subtitle = [NSString stringWithFormat:@"%@。这个插件现在不能启用。",
                              A2PluginErrorText(manifestError, @"未知原因")];
        brokenRow.accessory = A2SettingsRowAccessoryNone;
        [section addRow:brokenRow];
    }

    [section addRow:[self infoRowWithTitle:@"插件 id" value:entry.pluginId]];
    [section addRow:[self infoRowWithTitle:@"版本" value:entry.version]];
    [section addRow:[self infoRowWithTitle:@"作者（自述）"
                                     value:(manifest.authorName.length ? manifest.authorName
                                                                        : @"未填写")]];
    [section addRow:[self infoRowWithTitle:@"安装时间"
                                     value:A2PluginDisplayDate(entry.installedAt)]];
    // 完整 64 位在 ③ 的授权页里（那边可以复制）；这里只要「前 8 位」这个可对照的短串。
    [section addRow:[self infoRowWithTitle:@"包哈希（前 8 位）"
                                     value:A2PluginShortHash(entry.packageHash)]];
    return section;
}

- (A2SettingsSection *)sourceSectionWithEntry:(A2PluginRegistryEntry *)entry {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"来源"];
    section.footerText = @"来源只记录安装方式，不表示 Air2 对这个插件的任何判断。";

    NSString *fact = A2PluginSourceFactText(entry.sourceKind, entry.sourceDetail);
    A2SettingsRow *sourceRow = [[A2SettingsRow alloc] init];
    sourceRow.symbolName = @"tray.and.arrow.down";
    sourceRow.title = @"来源";
    sourceRow.subtitle = fact;      // 完整句子；文件名太长被截断时点开看全文
    sourceRow.accessory = A2SettingsRowAccessoryDisclosure;
    __weak typeof(self) weakSelf = self;
    sourceRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self presentSourceDetail:fact];
    };
    [section addRow:sourceRow];

    // kind 与 sourceDetail 分开摆一次：事实文本是给人读的，这两行是给人对的。
    [section addRow:[self infoRowWithTitle:@"来源种类" value:entry.sourceKind]];
    [section addRow:[self infoRowWithTitle:@"来源细节" value:entry.sourceDetail]];
    [section addRow:[self infoRowWithTitle:@"本次安装"
                                     value:A2PluginDisplayDate(entry.sourceInstalledAt)]];
    return section;
}

- (A2SettingsSection *)actionSectionWithEntry:(A2PluginRegistryEntry *)entry
                                     manifest:(nullable A2PluginManifest *)manifest {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"操作"];
    section.footerText = @"卸载会删除插件目录与注册表条目，已经授予的权限记录一并消失。";
    __weak typeof(self) weakSelf = self;

    // ---- 启用 / 禁用 ----
    A2SettingsRow *enabledRow = [[A2SettingsRow alloc] init];
    enabledRow.symbolName = @"power";
    enabledRow.title = @"启用";
    enabledRow.subtitle = @"关闭后插件不会被加载，权限记录保留";
    enabledRow.accessory = A2SettingsRowAccessorySwitch;
    enabledRow.on = entry.isEnabled;
    enabledRow.onToggle = ^(BOOL isOn) {
        __strong typeof(weakSelf) self = weakSelf;
        [self applyEnabled:isOn];
    };
    [section addRow:enabledRow];

    // ---- 重新审查权限 ----
    A2SettingsRow *reviewRow = [[A2SettingsRow alloc] init];
    reviewRow.symbolName = @"checklist";
    reviewRow.title = @"重新审查权限";
    if (manifest) {
        reviewRow.subtitle = @"打开授权页，逐项确认或关掉";
        reviewRow.accessory = A2SettingsRowAccessoryDisclosure;
        reviewRow.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self presentPermissionReview];
        };
    } else {
        // 没有 manifest 就没有「申请的权限」可审查：不挂一个点了没反应的箭头。
        reviewRow.subtitle = @"manifest 读不出来，无法审查";
        reviewRow.valueText = @"不可用";
        reviewRow.accessory = A2SettingsRowAccessoryNone;
    }
    [section addRow:reviewRow];

    // ---- 卸载 ----
    BOOL builtin = [self.installer.builtinPluginIds containsObject:entry.pluginId];
    A2SettingsRow *removeRow = [[A2SettingsRow alloc] init];
    removeRow.symbolName = @"trash";
    removeRow.title = @"卸载";
    if (builtin) {
        // 置灰 + 原因：点了没反应的红色按钮最糟。
        removeRow.subtitle = @"随 Air2 一起提供，不能卸载";
        removeRow.valueText = @"内置";
        removeRow.accessory = A2SettingsRowAccessoryNone;
    } else {
        removeRow.subtitle = @"删除插件目录与注册表条目";
        removeRow.destructive = YES;
        removeRow.accessory = A2SettingsRowAccessoryNone;
        removeRow.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self presentUninstall];
        };
    }
    [section addRow:removeRow];

    return section;
}

- (A2SettingsRow *)infoRowWithTitle:(NSString *)title value:(NSString *)value {
    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.title = title;
    row.valueText = value.length ? value : @"未记录";
    row.accessory = A2SettingsRowAccessoryNone;
    return row;
}

#pragma mark 权限

/// 权限按 ③ 的 5 组分组。组顺序固定（按枚举顺序），空组隐藏。
/// 每项都带 §9 的人话后果整句 —— 「凡是出现权限的地方都显示同一句」是硬要求，
/// 所以这里不写自己的文案，名称与后果全部来自 A2PluginPermissionStore 的目录表。
- (NSArray<A2SettingsSection *> *)permissionSectionsWithManifest:(nullable A2PluginManifest *)manifest
                                                   manifestError:(nullable NSError *)manifestError {
    if (!manifest) {
        return @[[self messageSectionWithSectionTitle:@"权限"
                                                title:@"读不出申请的权限"
                                             subtitle:[NSString stringWithFormat:@"%@。要改授权请先修好这个插件。",
                                                       A2PluginErrorText(manifestError, @"未知原因")]]];
    }

    NSUInteger total = manifest.permissions.count;
    NSUInteger grantedCount = 0;
    NSUInteger criticalCount = 0;
    NSUInteger unavailableCount = 0;
    for (NSString *permissionId in manifest.permissions) {
        if ([self.store isGranted:permissionId forPlugin:manifest.pluginId]) grantedCount += 1;
        if (A2PluginRiskForPermission(permissionId) == A2PluginRiskCritical) criticalCount += 1;
        A2PluginPermissionInfo *info = A2PluginPermissionInfoForId(permissionId);
        if (info && info.milestone > self.milestone) unavailableCount += 1;
    }

    NSMutableArray<A2SettingsSection *> *sections = [NSMutableArray array];

    A2SettingsSection *overview = [[A2SettingsSection alloc] initWithTitle:@"权限"];
    A2SettingsRow *summaryRow = [[A2SettingsRow alloc] init];
    summaryRow.title = [NSString stringWithFormat:@"已授权 %lu / 申请 %lu 项",
                        (unsigned long)grantedCount, (unsigned long)total];
    if (criticalCount == 0) {
        summaryRow.subtitle = @"这个插件没有申请高危权限";
    } else {
        summaryRow.subtitle = [NSString stringWithFormat:@"其中 %lu 项高危，默认关闭、需连续三次确认",
                               (unsigned long)criticalCount];
    }
    summaryRow.accessory = A2SettingsRowAccessoryNone;
    [overview addRow:summaryRow];
    if (unavailableCount > 0) {
        // 说清楚「现在为什么还不起作用」：否则用户会以为开关坏了。
        // 授权记录仍然记在注册表里，到那个版本会自动生效。
        overview.footerText = [NSString stringWithFormat:
                               @"其中 %lu 项要到更高版本才生效（当前是 %@），标「当前版本不可用」；"
                               @"授权记录会保留。",
                               (unsigned long)unavailableCount,
                               A2PluginMilestoneName(self.milestone)];
    }
    [sections addObject:overview];

    for (NSInteger group = 0; group < A2PluginPermissionGroupCount; group++) {
        NSMutableArray<A2PluginPermissionInfo *> *items = [NSMutableArray array];
        for (NSString *permissionId in manifest.permissions) {
            A2PluginPermissionInfo *info = A2PluginPermissionInfoForId(permissionId);
            if (!info || info.group != (A2PluginPermissionGroup)group) continue;
            [items addObject:info];
        }
        if (items.count == 0) continue;   // 空组隐藏

        A2SettingsSection *section =
            [[A2SettingsSection alloc] initWithTitle:A2PluginPermissionGroupTitle((A2PluginPermissionGroup)group)];
        section.footerText = A2PluginPermissionGroupConsequence((A2PluginPermissionGroup)group);
        for (A2PluginPermissionInfo *info in items) {
            A2SettingsRow *row = [[A2SettingsRow alloc] init];
            row.title = info.shortName;
            row.subtitle = info.consequence;   // §9 人话后果整句（原文）
            row.valueText = [self statusTextForInfo:info];
            row.accessory = A2SettingsRowAccessoryNone;
            row.accessibilityIdentifier = info.permissionId;
            [section addRow:row];
        }
        [sections addObject:section];
    }
    return sections;
}

/// 三项状态与 §3.5 的写法一致；「当前版本不可用」优先于授权状态（那种授权现在也不会生效）。
- (NSString *)statusTextForInfo:(A2PluginPermissionInfo *)info {
    if (info.milestone > self.milestone) return @"当前版本不可用";
    if ([self.store isGranted:info.permissionId forPlugin:self.pluginId]) {
        return info.risk == A2PluginRiskCritical ? @"已授权 · 3 步" : @"已授权";
    }
    return @"未授权";
}

#pragma mark 交互

- (void)applyEnabled:(BOOL)enabled {
    __weak typeof(self) weakSelf = self;
    A2PluginSetEnabled(self, self.registry, self.installer, self.store, self.milestone,
                       self.pluginId, enabled,
                       ^(BOOL ok, NSString *message) {
        // 同列表页：回调来自开关自己的点击，重画放到下一轮 runloop。
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!ok) [A2Toast show:(message ?: @"操作失败") inView:self.view];
            void (^didChange)(void) = self.didChange;
            if (didChange) didChange();
            [self rebuildSections];
        });
    });
}

- (void)presentPermissionReview {
    NSError *error = nil;
    A2PluginManifest *manifest = [self.installer installedManifestForPluginId:self.pluginId
                                                                       error:&error];
    if (!manifest) {
        [A2Toast show:A2PluginErrorText(error, @"读不出这个插件的 manifest") inView:self.view];
        return;
    }
    A2PluginRegistryEntry *entry = [self.registry entryForPluginId:self.pluginId];
    if (!entry) {
        [A2Toast show:@"注册表里已经没有这个插件" inView:self.view];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [A2PluginPermissionSheet presentForManifest:manifest
                                          store:self.store
                                    packageHash:entry.packageHash
                                  hostMilestone:self.milestone
                             fromViewController:self
                                     completion:^(NSArray<NSString *> *grantedPermissions) {
        __strong typeof(weakSelf) self = weakSelf;
        void (^didChange)(void) = self.didChange;
        if (didChange) didChange();
        [self rebuildSections];
    }];
}

- (void)presentUninstall {
    NSString *displayName = self.pageTitle;
    __weak typeof(self) weakSelf = self;
    A2PluginConfirmUninstall(self, self.installer, self.pluginId, displayName,
                             ^(BOOL ok, NSString *message) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!ok) {
            [A2Toast show:(message ?: @"卸载失败") inView:self.view];
            return;
        }
        void (^didChange)(void) = self.didChange;
        if (didChange) didChange();
        UINavigationController *nav = self.navigationController;
        [nav popViewControllerAnimated:YES];
        // 本页紧接着就被移除，提示改挂在返回后的列表上，否则用户看不到。
        dispatch_async(dispatch_get_main_queue(), ^{
            [A2Toast show:@"已卸载" inView:nav.topViewController.view];
        });
    });
}

- (void)presentSourceDetail:(NSString *)fact {
    [A2Dialog showInView:self.view
                   title:@"来源"
                 message:fact
                 actions:@[
        [A2DialogAction actionWithTitle:@"关闭" style:A2DialogActionStyleText handler:nil],
        [A2DialogAction actionWithTitle:@"复制" style:A2DialogActionStyleFilled handler:^{
            UIPasteboard.generalPasteboard.string = fact;
        }],
    ]];
}

@end
