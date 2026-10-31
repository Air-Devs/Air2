//
//  A2VersionSettingsViewController.m
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
//  单版本设置 —— 隔离档位是全局的，这里只做展示。
//
//  隔离档位在「设置 → 游戏」里选（关闭 / 仅 Mod / 全部）。
//  本页显示的是「本版本的生效档位」：全局选「仅 Mod」时，只有能装模组的版本
//  才会隔离，原版与仅装 OptiFine 的版本按「关闭」处理。
//  只展示、不提供修改入口，避免两处设置互相打架。
//
//  版本的启动配置仍存在 {版本目录}/.air_version/config.json。
//
//  ★关闭交互★（本页是「单个版本」的唯一入口，从主页齿轮与版本列表齿轮两处进）：
//    · 本页能改的四项（Java 运行时 / 渲染器 / JVM 参数 / 游戏参数 / 跳过完整性检查）
//      先改在内存里的 isolation 对象上，页面自己判断「和打开时比有没有变」；
//      一改动右上角的「保存」就亮起、标题卡下出现「有未保存的修改」提示。
//    · 点返回（左上箭头）关页时，若有未保存修改 → 弹仓内 A2OptionSheet：
//      「保存并关闭」/「放弃修改」，点遮罩或「取消」= 继续编辑。
//      ★不用系统 UIAlertController 的 ActionSheet★（半透明系统材质、不跟主题，
//      且 scripts/check_no_glass.py 会拦）。
//    · 任何别的离开路径（侧滑返回、被上层页面盖住、页面销毁）都会在
//      viewWillDisappear 里静默落盘 —— 只有用户明确点「放弃修改」才会丢改动。
//

#import "A2VersionSettingsViewController.h"
#import "A2VersionIsolation.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2GlassCard.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2VersionManager.h"
#import "A2InputDialog.h"
#import "A2ModListViewController.h"
#import "A2OptionSheet.h"          // 实例级「Java 运行时 / 渲染器」单选（MD3 弹窗）
#import "A2JavaRuntimeCatalog.h"    // JRE 档位清单
#import "A2RendererCatalog.h"       // 渲染器清单
#import "A2Renderer.h"             // 渲染器取值的唯一来源（A2Renderer 类型）
#import "A2RuntimeStrings.h"        // 渲染器显示名（缺 key 回退技术名）
#import "A2Log.h"                  // 关闭/落盘事件落日志（[A2-VERCFG]）

@interface A2VersionSettingsViewController ()
/// 版本名（在 init 里赋值，后续只读）
@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, strong) A2Version *version;
@property (nonatomic, strong) A2SettingsRow *modeRow;
@property (nonatomic, strong) A2SettingsRow *pathRow;
@property (nonatomic, strong) A2SettingsSection *folderSection;
@property (nonatomic, strong) NSMutableArray<A2SettingsRow *> *folderRows;

/// 打开页面时的配置快照（只含本页能改的项）。
/// 「有没有未保存的修改」= 当前值与该快照逐项比较，不额外维护一个易走样的布尔标记。
@property (nonatomic, copy) NSDictionary<NSString *, id> *savedConfigSnapshot;
/// 刻意丢弃改动（点「放弃修改」/ 删除版本）：抑制 viewWillDisappear 的静默落盘。
@property (nonatomic, assign) BOOL discardsChangesOnExit;
/// 顶栏「保存」按钮（脏了才亮）与标题卡里的「未保存」提示。
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) UILabel *dirtyLabel;

/// 「启动配置」四行 + 完整性开关：放弃修改后要把它们按 isolation 的值刷回去。
/// 只存引用，不缓存值 —— 值永远从 isolation 读，避免两处状态打架。
@property (nonatomic, strong) A2SettingsRow *javaRuntimeRow;
@property (nonatomic, strong) A2SettingsRow *rendererRow;
@property (nonatomic, strong) A2SettingsRow *jvmRow;
@property (nonatomic, strong) A2SettingsRow *gameArgsRow;
@property (nonatomic, strong) A2SettingsRow *integrityRow;
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

    // 左上返回不再直接出页：先过「有没有未保存的修改」这一关。
    __weak typeof(self) weakSelf = self;
    self.onBack = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self requestClose];
    };

    [self setupHeaderCard];
    [self setupIsolationSection];
    [self setupFolderSection];
    [self setupLaunchSection];
    [self setupDangerSection];
    [self setupSaveButton];

    [self refreshIsolationUI];

    // 快照最后取：上面几个 setup 只读数据，不写配置。
    self.savedConfigSnapshot = [self configSnapshot];
    [self refreshDirtyUI];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // 出页兜底：除「放弃修改」之外的任何离开路径（侧滑返回、上层盖住、销毁）
    // 都把改动落盘，避免用户改了设置却因为退出方式不同而静默丢失。
    if (!self.discardsChangesOnExit && [self hasUnsavedChanges]) {
        [self commitConfigWithReason:@"view_disappear"];
    }
}

#pragma mark - 未保存修改与关闭

/// 本页能改的所有项 —— 只收这五项，隔离档位等全局项不在内。
- (NSDictionary<NSString *, id> *)configSnapshot {
    A2VersionIsolation *iso = _version.isolation;
    return @{
        @"javaRuntime": iso.javaRuntime ?: @"",
        @"renderer": iso.renderer ?: @"",
        @"jvmArgs": iso.jvmArgs ?: @"",
        @"gameArgs": iso.gameArgs ?: @"",
        @"skipGameIntegrityCheck": @(iso.skipGameIntegrityCheck),
    };
}

- (BOOL)hasUnsavedChanges {
    if (!self.savedConfigSnapshot) return NO;
    return ![[self configSnapshot] isEqualToDictionary:self.savedConfigSnapshot];
}

/// 编辑动作统一走这里：不立刻写盘，只刷新「保存」按钮与「未保存」提示。
/// 落盘时机 = 点保存 / 点返回时选「保存并关闭」/ 任何离开路径的兜底。
- (void)markConfigEdited {
    [self refreshDirtyUI];
}

/// 落盘并把快照对齐成当前值（之后 hasUnsavedChanges 自然为 NO）。
- (void)commitConfigWithReason:(NSString *)reason {
    if (![self hasUnsavedChanges]) {
        [self refreshDirtyUI];
        return;
    }
    [_version saveConfig];
    self.savedConfigSnapshot = [self configSnapshot];
    [self refreshDirtyUI];
    [A2Log log:@"[A2-VERCFG] 保存版本配置 %@ reason=%@", _version.name, reason ?: @"?"];
}

/// 「保存」按钮只在有改动时可用；提示文字同理。
- (void)refreshDirtyUI {
    BOOL dirty = [self hasUnsavedChanges];
    self.saveButton.enabled = dirty;
    self.saveButton.alpha = dirty ? 1.0 : 0.35;
    self.dirtyLabel.hidden = !dirty;
}

- (void)setupSaveButton {
    __weak typeof(self) weakSelf = self;
    self.saveButton = [self addTrailingButtonWithSymbol:@"checkmark" action:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self commitConfigWithReason:@"save_button"];
        [A2Toast show:@"已保存" inView:self.view];
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
    }];
    // 顶部另有「保存」这一明确出口；返回箭头则是「关页」，两件事不混。
    self.saveButton.accessibilityLabel = @"保存";
}

/// 关闭本页的唯一出口：没有改动直接出页；有改动先问。
- (void)requestClose {
    if (![self hasUnsavedChanges]) {
        [A2Log log:@"[A2-VERCFG] 关闭 %@（无未保存修改，直接返回）", _version.name];
        [self closeSelf];
        return;
    }

    [A2Log log:@"[A2-VERCFG] 关闭 %@ 时存在未保存修改 ⇒ 询问保存或放弃", _version.name];
    // 弹窗由本页 present（UIKit 强持有），handler 里必须弱引用 self，
    // 否则 self → 弹窗 → handler → self 成环，关页后整页都不释放。
    __weak typeof(self) weakSelf = self;
    A2OptionSheet *sheet = [A2OptionSheet sheetWithTitle:@"有未保存的修改"
                                                 message:@"关闭前要先保存这些设置吗？"];
    [sheet addOptionWithTitle:@"保存并关闭"
                     selected:YES
                  destructive:NO
                      handler:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self commitConfigWithReason:@"close_save"];
        [self closeSelf];
    }];
    [sheet addOptionWithTitle:@"放弃修改"
                     selected:NO
                  destructive:YES
                      handler:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // 丢弃：把内存里的改动还原成快照值，再抑制离开时的自动落盘。
        self.discardsChangesOnExit = YES;
        [self revertToSavedSnapshot];
        [A2Log log:@"[A2-VERCFG] 放弃未保存修改 %@", self.version.name];
        [self closeSelf];
    }];
    [sheet presentFrom:self];
}

/// 把 isolation 还原成快照值（「放弃修改」用）。
- (void)revertToSavedSnapshot {
    NSDictionary<NSString *, id> *snapshot = self.savedConfigSnapshot;
    if (!snapshot) return;

    A2VersionIsolation *iso = _version.isolation;
    NSString *javaRuntime = snapshot[@"javaRuntime"];
    NSString *renderer = snapshot[@"renderer"];
    NSString *jvmArgs = snapshot[@"jvmArgs"];
    NSString *gameArgs = snapshot[@"gameArgs"];
    NSNumber *skipIntegrity = snapshot[@"skipGameIntegrityCheck"];

    iso.javaRuntime = javaRuntime.length ? javaRuntime : nil;
    iso.renderer = renderer.length ? renderer : nil;
    iso.jvmArgs = jvmArgs.length ? jvmArgs : nil;
    iso.gameArgs = gameArgs.length ? gameArgs : nil;
    iso.skipGameIntegrityCheck = (A2SettingState)skipIntegrity.integerValue;

    [self refreshIsolationUI];
    [self refreshLaunchConfigUI];
    [self refreshDirtyUI];
}

/// 按 isolation 的当前值刷「启动配置」那几行的显示（放弃修改后还原界面用）。
- (void)refreshLaunchConfigUI {
    A2VersionIsolation *iso = _version.isolation;
    _javaRuntimeRow.valueText = iso.javaRuntime.length ? iso.javaRuntime : @"跟随全局";
    _rendererRow.valueText = [self rendererDisplayNameForIdentifier:iso.renderer];
    _jvmRow.valueText = iso.jvmArgs.length ? iso.jvmArgs : @"跟随全局";
    _gameArgsRow.valueText = iso.gameArgs.length ? iso.gameArgs : @"跟随全局";
    _integrityRow.on = (iso.skipGameIntegrityCheck == A2SettingStateEnable);
}

/// 渲染器标识 → 界面显示名（缺本地化 key 时回退技术名/标识）。
/// 选项列表与「放弃修改」后的回刷共用同一份映射，不各拼一次。
- (NSString *)rendererDisplayNameForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return @"跟随全局";
    for (A2Renderer *r in [A2RendererCatalog allCandidates]) {
        if (![r.identifier isEqualToString:identifier]) continue;
        NSString *key = [A2RendererCatalog nameLocalizationKeyForIdentifier:r.identifier];
        NSString *name = [A2RuntimeStrings stringForKey:key];
        if (name.length == 0 || [name isEqualToString:key]) name = r.displayName ?: r.identifier;
        return name;
    }
    return identifier;
}

- (void)closeSelf {
    UINavigationController *nav = self.navigationController;
    if (!nav) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    [nav popViewControllerAnimated:YES];
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

    // 「未保存」提示：只在真的有改动时出现（refreshDirtyUI 控制显隐），
    // 让「右上角保存亮了」这件事有文字对应，不用用户去猜按钮为什么变灰。
    _dirtyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _dirtyLabel.font = [A2Typography caption];
    _dirtyLabel.textColor = t.cWarning;
    _dirtyLabel.numberOfLines = 1;
    _dirtyLabel.text = @"有未保存的修改 · 关闭前会提示保存";
    _dirtyLabel.hidden = YES;

    UILabel *path = [[UILabel alloc] initWithFrame:CGRectZero];
    path.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    path.textColor = t.cOnSurfaceVariant;
    path.numberOfLines = 3;
    path.lineBreakMode = NSLineBreakByTruncatingMiddle;
    path.text = _version.versionPath;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[name, status, _dirtyLabel, path]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceS;
    [stack setCustomSpacing:A2SpaceM afterView:_dirtyLabel];

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
    section.footerText = @"隔离档位是全局设置，在「设置 → 游戏」里修改。"
                          "依赖库与资源文件始终共用，不会重复占用空间。";

    _modeRow = [[A2SettingsRow alloc] init];
    _modeRow.symbolName = @"square.split.2x1.fill";
    _modeRow.title = @"隔离档位";
    _modeRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:_modeRow];

    _pathRow = [[A2SettingsRow alloc] init];
    _pathRow.symbolName = @"folder.fill";
    _pathRow.title = @"当前游戏目录";
    _pathRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:_pathRow];

    [self addSection:section];
}

/// 实时刷新隔离相关文案 —— 档位或版本变化都要重算路径
- (void)refreshIsolationUI {
    A2IsolationMode mode = _version.effectiveIsolationMode;

    _modeRow.valueText = A2IsolationModeDisplayName(mode);
    if (mode == A2IsolationModeMod) {
        _modeRow.subtitle = @"只隔离本版本的模组，其余目录共用";
    } else if (mode == A2IsolationModeFull) {
        _modeRow.subtitle = @"整个游戏目录按版本隔离";
    } else if (_version.isolationMode == A2IsolationModeMod) {
        // 全局档位是「仅 Mod」，但本版本不能装模组，实际按关闭处理。
        _modeRow.subtitle = @"本版本不能装模组，不隔离";
    } else {
        _modeRow.subtitle = @"所有数据共用，不隔离";
    }

    _pathRow.subtitle = [_version gameDirectory];

    // 各可隔离目录的实际路径
    for (NSUInteger i = 0; i < _folderRows.count && i < A2VersionFolderCount; i++) {
        NSString *dir = [_version directoryForFolder:(A2VersionFolder)i];
        _folderRows[i].valueText = [self shortenPath:dir];
    }

    switch (mode) {
        case A2IsolationModeFull:
            _folderSection.footerText = [NSString stringWithFormat:
                @"这些目录当前位于 versions/%@/ 下。", _version.name];
            break;
        case A2IsolationModeMod:
            _folderSection.footerText = @"只有模组位于版本目录下，其余目录在游戏根目录共用。";
            break;
        default:
            _folderSection.footerText = @"这些目录当前位于游戏根目录下，与其他版本共用。";
            break;
    }
}

/// 路径太长，只显示最后两段
- (NSString *)shortenPath:(NSString *)path {
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count <= 2) return path;
    return [NSString stringWithFormat:@"…/%@/%@",
            parts[parts.count - 2], parts[parts.count - 1]];
}

#pragma mark - 可隔离目录

- (void)setupFolderSection {
    _folderSection = [[A2SettingsSection alloc] initWithTitle:@"版本内容"];

    // 与侧栏 / 资源徽标统一：资源包用 iOS 13 就存在的 rectangle.stack.fill
    //（photo.stack.fill 是 iOS 16 起才有的符号，在 iOS 15 真机上取不到图）。
    NSArray<NSString *> *symbols = @[@"puzzlepiece.extension.fill", @"rectangle.stack.fill",
                                     @"map.fill", @"sun.max.fill", @"photo.fill"];

    for (NSUInteger i = 0; i < A2VersionFolderCount; i++) {
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = symbols[i];
        row.title = A2VersionFolderDisplayName((A2VersionFolder)i);
        row.accessory = A2SettingsRowAccessoryDisclosure;

        // 模组行进专用管理页，其余目录维持通用浏览（各管各的，不混）。
        if ((A2VersionFolder)i == A2VersionFolderMods) {
            __weak typeof(self) weakSelf = self;
            row.onTap = ^{
                __strong typeof(weakSelf) self = weakSelf;
                A2ModListViewController *vc =
                    [[A2ModListViewController alloc] initWithVersion:self.version];
                [self.navigationController pushViewController:vc animated:YES];
            };
        } else {
            NSString *folderName = A2VersionFolderDisplayName((A2VersionFolder)i);
            NSString *dir = [_version directoryForFolder:(A2VersionFolder)i];
            row.onTap = ^{
                NSURL *url = [NSURL fileURLWithPath:dir];
                (void)url;
                [A2Toast show:[NSString stringWithFormat:@"%@：%@", folderName, dir]
                       inView:self.view];
            };
        }

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

    // ---- ★实例级 Java 运行时★（空 = 跟随全局）----
    A2SettingsRow *javaRow = [[A2SettingsRow alloc] init];
    self.javaRuntimeRow = javaRow;
    javaRow.symbolName = @"cup.and.saucer";
    javaRow.title = @"Java 运行时";
    javaRow.valueText = iso.javaRuntime.length ? iso.javaRuntime : @"跟随全局";
    javaRow.accessory = A2SettingsRowAccessoryDisclosure;
    __weak A2SettingsRow *weakJavaRow = javaRow;
    javaRow.onTap = ^{
        __weak typeof(self) weakSelf = self;
        A2OptionSheet *sheet = [A2OptionSheet sheetWithTitle:@"Java 运行时"
                                                     message:@"实例级覆盖；「跟随全局」用设置 → 游戏 → 运行环境 里的那档"];
        [sheet addOptionWithTitle:@"跟随全局"
                         selected:(weakSelf.version.isolation.javaRuntime.length == 0)
                      destructive:NO
                          handler:^{
            weakSelf.version.isolation.javaRuntime = nil;
            [weakSelf markConfigEdited];
            weakJavaRow.valueText = @"跟随全局";
        }];
        for (NSString *dir in [A2JavaRuntimeCatalog allDirectoryNames]) {
            [sheet addOptionWithTitle:dir
                             selected:[dir isEqualToString:weakSelf.version.isolation.javaRuntime ?: @""]
                          destructive:NO
                              handler:^{
                weakSelf.version.isolation.javaRuntime = dir;
                [weakSelf markConfigEdited];
                weakJavaRow.valueText = dir;
            }];
        }
        [sheet presentFrom:weakSelf];
    };
    [section addRow:javaRow];

    // ---- ★实例级渲染器★（空 = 跟随全局）----
    A2SettingsRow *rendererRow = [[A2SettingsRow alloc] init];
    self.rendererRow = rendererRow;
    rendererRow.symbolName = @"paintbrush";
    rendererRow.title = @"渲染器";
    rendererRow.valueText = iso.renderer.length ? iso.renderer : @"跟随全局";
    rendererRow.accessory = A2SettingsRowAccessoryDisclosure;
    __weak A2SettingsRow *weakRendererRow = rendererRow;
    rendererRow.onTap = ^{
        __weak typeof(self) weakSelf = self;
        A2OptionSheet *sheet = [A2OptionSheet sheetWithTitle:@"渲染器"
                                                     message:@"实例级覆盖；「跟随全局」用设置 → 游戏 → 运行环境 里的那项"];
        [sheet addOptionWithTitle:@"跟随全局"
                         selected:(weakSelf.version.isolation.renderer.length == 0)
                      destructive:NO
                          handler:^{
            weakSelf.version.isolation.renderer = nil;
            [weakSelf markConfigEdited];
            weakRendererRow.valueText = @"跟随全局";
        }];
        for (A2Renderer *r in [A2RendererCatalog allCandidates]) {
            NSString *name = [weakSelf rendererDisplayNameForIdentifier:r.identifier] ?: r.identifier;
            [sheet addOptionWithTitle:name
                             selected:[r.identifier isEqualToString:weakSelf.version.isolation.renderer ?: @""]
                          destructive:NO
                              handler:^{
                weakSelf.version.isolation.renderer = r.identifier;
                [weakSelf markConfigEdited];
                weakRendererRow.valueText = name;
            }];
        }
        [sheet presentFrom:weakSelf];
    };
    [section addRow:rendererRow];

    A2SettingsRow *jvmRow = [[A2SettingsRow alloc] init];
    self.jvmRow = jvmRow;
    jvmRow.symbolName = @"terminal";
    jvmRow.title = @"JVM 参数";
    jvmRow.valueText = iso.jvmArgs.length ? iso.jvmArgs : @"跟随全局";
    jvmRow.accessory = A2SettingsRowAccessoryDisclosure;
    // 注意：row 持有 onTap，onTap 里若再强引用 row 就会形成循环。
    // 这里对 row 也用 weak 捕获。
    __weak A2SettingsRow *weakJvmRow = jvmRow;
    jvmRow.onTap = ^{
        __weak typeof(self) weakSelf = self;
        A2InputDialog *dlg = [A2InputDialog dialogWithTitle:@"JVM 参数"
                                                    message:@"留空则使用全局设置"
                                                      label:@"JVM 参数"
                                                initialText:weakSelf.version.isolation.jvmArgs];
        dlg.keyboardType = UIKeyboardTypeASCIICapable;
        dlg.autocapitalizationType = UITextAutocapitalizationTypeNone;
        dlg.onFinish = ^(BOOL committed, NSString *text) {
            if (!committed) return;
            weakSelf.version.isolation.jvmArgs = text;
            [weakSelf markConfigEdited];
            weakJvmRow.valueText = weakSelf.version.isolation.jvmArgs.length
                ? weakSelf.version.isolation.jvmArgs : @"跟随全局";
        };
        [dlg presentFrom:weakSelf];
    };
    [section addRow:jvmRow];

    A2SettingsRow *gameArgsRow = [[A2SettingsRow alloc] init];
    self.gameArgsRow = gameArgsRow;
    gameArgsRow.symbolName = @"text.alignleft";
    gameArgsRow.title = @"游戏参数";
    gameArgsRow.valueText = iso.gameArgs.length ? iso.gameArgs : @"跟随全局";
    gameArgsRow.accessory = A2SettingsRowAccessoryDisclosure;
    __weak A2SettingsRow *weakGameArgsRow = gameArgsRow;
    gameArgsRow.onTap = ^{
        __weak typeof(self) weakSelf = self;
        A2InputDialog *dlg = [A2InputDialog dialogWithTitle:@"游戏参数"
                                                    message:@"留空则使用全局设置"
                                                      label:@"游戏参数"
                                                initialText:weakSelf.version.isolation.gameArgs];
        dlg.keyboardType = UIKeyboardTypeASCIICapable;
        dlg.autocapitalizationType = UITextAutocapitalizationTypeNone;
        dlg.onFinish = ^(BOOL committed, NSString *text) {
            if (!committed) return;
            weakSelf.version.isolation.gameArgs = text;
            [weakSelf markConfigEdited];
            weakGameArgsRow.valueText = weakSelf.version.isolation.gameArgs.length
                ? weakSelf.version.isolation.gameArgs : @"跟随全局";
        };
        [dlg presentFrom:weakSelf];
    };
    [section addRow:gameArgsRow];

    A2SettingsRow *integrityRow = [[A2SettingsRow alloc] init];
    self.integrityRow = integrityRow;
    integrityRow.symbolName = @"checkmark.shield";
    integrityRow.title = @"跳过完整性检查";
    integrityRow.subtitle = @"启动更快，但可能掩盖文件损坏";
    integrityRow.accessory = A2SettingsRowAccessorySwitch;
    integrityRow.on = (iso.skipGameIntegrityCheck == A2SettingStateEnable);
    integrityRow.onToggle = ^(BOOL isOn) {
        __weak typeof(self) weakSelf = self;
        weakSelf.version.isolation.skipGameIntegrityCheck =
            isOn ? A2SettingStateEnable : A2SettingStateDisable;
        [weakSelf markConfigEdited];
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
        A2InputDialog *dlg = [A2InputDialog dialogWithTitle:@"重命名版本"
                                                    message:nil
                                                      label:@"版本名"
                                                initialText:weakSelf.version.name];
        dlg.autocapitalizationType = UITextAutocapitalizationTypeNone;
        // 重名 / 非法名由 A2VersionManager 判定，失败时弹窗内报错并保留
        dlg.onCommit = ^(NSString *text, void (^done)(BOOL, NSString *)) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) { done(NO, @"操作已取消"); return; }
            NSString *newName = [text stringByTrimmingCharactersInSet:
                                 NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (newName.length == 0) { done(NO, @"名称不能为空"); return; }
            NSError *err = nil;
            if ([A2VersionManager.shared renameVersion:self.version to:newName error:&err]) {
                self.pageTitle = newName;
                // 改名后配置目录也跟着换了：把待保存的改动落到新路径上。
                [self commitConfigWithReason:@"rename"];
                done(YES, nil);
            } else {
                done(NO, err.localizedDescription ?: @"重命名失败");
            }
        };
        dlg.onFinish = ^(BOOL committed, NSString *text) {
            if (committed) [A2Toast show:@"已重命名" inView:weakSelf.view];
        };
        [dlg presentFrom:weakSelf];
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
            if (!self) return;
            // 版本目录都要删了：先掐掉「离开时自动落盘」，
            // 否则 saveConfig 会在删除后再把 .air_version/ 建出来（留下空壳）。
            self.discardsChangesOnExit = YES;
            NSError *err = nil;
            if ([A2VersionManager.shared deleteVersion:self.version error:&err]) {
                [A2Toast show:@"已删除" inView:self.view];
                [self closeSelf];
            } else {
                // 删除失败：恢复自动落盘，待保存的改动不能因为一次失败就丢掉。
                self.discardsChangesOnExit = NO;
                [A2Toast show:(err.localizedDescription ?: @"删除失败") inView:self.view];
            }
        }]];
        [weakSelf presentViewController:alert animated:YES completion:nil];
    };
    [section addRow:deleteRow];

    [self addSection:section];
}

@end
