//
//  A2JITSettings.m
//  Air2
//
//  运行环境分组 —— JIT 供给面板（[JIT-IMPL-2] 接真实现）。
//
//  组成：
//    · 状态行      ：A2JITStateMachine 当前状态 + 说明；
//    · 分级策略行  ：A2JITStrategySelector 选出的档位 + iOS 版本；
//    · 下一步动作行：按 状态 / 判据 verdict 给出【该做哪一件事】；
//    · 导入配对文件：★真的起 UIDocumentPicker★ → A2JITPairingFileStore 落盘 + 记录；
//    · 外部工具行  ：未安装则【置灰并写「未安装」】；
//    · 判据取证行  ：A2JITRegionVerdict 的**分流文案**（四种原因四种动作，不写万能文案）；
//    · 开启 JIT 行  ：★后台队列★跑 A2JITCoordinator.enableJITWithError:（外部工具要「有界等待」，
//                    放主线程会卡界面）；完成后回主线程刷新 + Toast。
//
//  装配（★只在本文件发生，Player 只收协议★）：
//    facts   = A2JITLocalFactsSource（Foundation）＋ UIKit 补 canOpenURL；
//    probe   = A2JITEnvironmentProbe（Bridge → Natives/Support/A2JITEnvironment）★真判据★；
//    launcher= A2JITSystemToolLauncher（UIApplication URL scheme）；
//    store   = A2JITPairingFileStore（容器约定位置 Library/Application Support/Pairing）；
//    coordinator = 四路 Provider + 状态机。
//
//  文案：A2JITStrings（zh-Hans / zh-Hant / en / ja 四语齐）。
//

#import "A2SettingsSections.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2JITFacts.h"
#import "A2JITLocalFactsSource.h"
#import "A2JITCoordinator.h"
#import "A2JITStateMachine.h"
#import "A2JITStrategySelector.h"
#import "A2JITProvider.h"
#import "A2JITImportedPairingProvider.h"
#import "A2JITExternalToolProvider.h"
#import "A2JITReadinessProbe.h"
#import "A2JITExternalToolLauncher.h"
#import "A2JITPairingFileStore.h"
#import "A2JITVerdictGuidance.h"
#import "A2JITStrings.h"
#import "A2JITSystemToolLauncher.h"
#import "A2JITEnvironmentProbe.h"
#import "A2Toast.h"

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - 事实来源：Foundation 薄探测 + UIKit 补 canOpenURL

/// ★装配处的事实来源★：委托 A2JITLocalFactsSource（Foundation-only），
/// 只用 UIKit 补它取不到的 `hasExternalEnablerInstalled`（canOpenURL 属 UIKit，
/// 不能写进 Player —— 见 A2JITLocalFactsSource 的说明）。
@interface A2JITUIKitFactsSource : NSObject <A2JITFactsSource>
@property (nonatomic, strong) A2JITLocalFactsSource *base;
@property (nonatomic, strong, nullable) id<A2JITExternalToolLauncher> launcher;
@end

@implementation A2JITUIKitFactsSource

- (NSInteger)osMajorVersion { return [self.base osMajorVersion]; }
- (NSInteger)osMinorVersion { return [self.base osMinorVersion]; }
- (A2JITEnvironmentKind)environment { return [self.base environment]; }
- (BOOL)hasImportedPairingFile { return [self.base hasImportedPairingFile]; }
- (BOOL)hasGetTaskAllow { return [self.base hasGetTaskAllow]; }
- (BOOL)hasDynamicCodesigning { return [self.base hasDynamicCodesigning]; }

- (BOOL)hasExternalEnablerInstalled {
    // 探测面宽（登记表全部试一遍），返回值窄（是/否）。
    for (NSString *scheme in [A2JITExternalToolProvider registeredToolSchemes]) {
        NSURL *url = [A2JITExternalToolProvider launchURLForScheme:scheme];
        if (url && [self.launcher canOpenToolURL:url]) {
            NSLog(@"[A2JIT] facts: 检测到外部使能器 scheme=%@", scheme);
            return YES;
        }
    }
    return NO;
}

@end

#pragma mark - 面板呈现器（行引用 + 动作 + 文案）

@interface A2JITPanelPresenter : NSObject <UIDocumentPickerDelegate>

@property (nonatomic, weak, nullable) UIViewController *host;
@property (nonatomic, strong) A2JITFacts *facts;
@property (nonatomic, strong) A2JITCoordinator *coordinator;
@property (nonatomic, strong) A2JITPairingFileStore *store;
@property (nonatomic, strong, nullable) id<A2JITReadinessProbe> probe;

// 行（section 持有它们；这里只用弱引用，避免与行内 block 形成环）
@property (nonatomic, weak, nullable) A2SettingsRow *statusRow;
@property (nonatomic, weak, nullable) A2SettingsRow *strategyRow;
@property (nonatomic, weak, nullable) A2SettingsRow *nextRow;
@property (nonatomic, weak, nullable) A2SettingsRow *importRow;
@property (nonatomic, weak, nullable) A2SettingsRow *toolRow;
@property (nonatomic, weak, nullable) A2SettingsRow *evidenceRow;
@property (nonatomic, weak, nullable) A2SettingsRow *enableRow;

/// 按当前事实 / 状态 / 判据刷新所有行的文字与启用态。
- (void)apply;
/// 起系统文档选择器挑选配对文件。
- (void)presentImportPicker;
/// 后台队列开启 JIT（有界等待），完成后回主线程刷新。
- (void)runEnable;

@end

@implementation A2JITPanelPresenter

#pragma mark 文案小工具

- (NSString *)text:(NSString *)key {
    return [A2JITStrings stringForKey:key language:[A2JITStrings languageForSystemLocale]];
}

- (A2JITReadinessVerdict)currentVerdict {
    return self.probe ? [self.probe lastVerdict] : A2JITReadinessVerdictUnknown;
}

- (nullable NSString *)currentEvidence {
    return self.probe ? [self.probe lastEvidence] : nil;
}

#pragma mark 刷新

- (void)apply {
    A2JITStrategyDecision *decision = [A2JITStrategySelector decisionForFacts:self.facts];
    BOOL needsPairingFile = (decision.strategy == A2JITStrategyBuiltInManual ||
                             decision.strategy == A2JITStrategyAutomatic ||
                             decision.strategy == A2JITStrategyImportedExternal);

    // ---- 状态 ----
    self.statusRow.valueText = [A2JITStateMachine displayNameForState:self.coordinator.state];
    self.statusRow.subtitle = self.coordinator.statusDetail.length > 0
        ? self.coordinator.statusDetail
        : [A2JITStateMachine displayNameForFailureReason:self.coordinator.failureReason];

    // ---- 档位 ----
    self.strategyRow.valueText = [A2JITStrategySelector displayNameForStrategy:decision.strategy];
    self.strategyRow.subtitle = [NSString stringWithFormat:@"iOS %ld.%ld",
                                 (long)self.facts.osMajorVersion, (long)self.facts.osMinorVersion];

    // ---- 判据取证（失败原因★按 verdict 分流★）----
    A2JITReadinessVerdict verdict = [self currentVerdict];
    self.evidenceRow.valueText = [self text:[A2JITVerdictGuidance reasonKeyForVerdict:verdict]];
    NSString *evidence = [self currentEvidence];
    self.evidenceRow.subtitle = [NSString stringWithFormat:@"%@%@",
                                 [A2JITVerdictGuidance diagnosticForVerdict:verdict],
                                 evidence.length ? [NSString stringWithFormat:@"｜%@", evidence] : @""];

    // ---- 下一步动作 ----
    self.nextRow.valueText = [self nextActionTextForVerdict:verdict decision:decision];

    // ---- 导入配对文件（按档位启用/禁用）----
    self.importRow.enabled = needsPairingFile;
    if (!needsPairingFile) {
        self.importRow.subtitle = [self text:@"jit.row.import.notNeeded"];
    } else if (self.store.hasUsablePairingFile) {
        NSString *src = [self.store importedMetadata][A2JITPairingFileStoreSourceNameKey];
        self.importRow.subtitle = [NSString stringWithFormat:@"%@%@", [self text:@"jit.row.import.ready"],
                                   src.length ? [NSString stringWithFormat:@"（%@）", src] : @""];
    } else {
        self.importRow.subtitle = [self text:@"jit.row.import.needFile"];
    }

    // ---- 外部工具（★未安装 ⇒ 置灰 + 写「未安装」★）----
    BOOL installed = self.facts.hasExternalEnablerInstalled;
    self.toolRow.enabled = installed;
    self.toolRow.valueText = [self text:installed ? @"jit.row.tool.installed" : @"jit.row.tool.notInstalled"];
    self.toolRow.subtitle = [NSString stringWithFormat:@"%@://enable-jit",
                             [[A2JITExternalToolProvider registeredToolSchemes] componentsJoinedByString:@", "]];

    // ---- 开启 JIT（按是否有可用路径启用/禁用）----
    BOOL canEnable = self.coordinator.hasActiveProvider && decision.strategy != A2JITStrategyUnavailable;
    self.enableRow.enabled = canEnable;
    self.enableRow.subtitle = [self text:canEnable ? @"jit.row.enable.ready" : @"jit.row.enable.noPath"];
}

- (NSString *)nextActionTextForVerdict:(A2JITReadinessVerdict)verdict
                              decision:(A2JITStrategyDecision *)decision {
    if (self.coordinator.state == A2JITStateEnabled) {
        return [self text:@"jit.verdict.usable.action"];
    }
    if (decision.strategy == A2JITStrategyUnavailable || !self.coordinator.hasActiveProvider) {
        return [self text:@"jit.row.enable.noPath"];
    }
    if (self.coordinator.state == A2JITStatePaired) {
        return [self text:@"jit.row.enable.ready"];
    }
    if (verdict != A2JITReadinessVerdictUnknown) {
        return [self text:[A2JITVerdictGuidance actionKeyForVerdict:verdict]];
    }
    return [self text:@"jit.verdict.unknown.action"];
}

#pragma mark 导入

- (void)presentImportPicker {
    if (self.host == nil) {
        return;
    }
    // asCopy:YES ⇒ 系统先把文件拷进本 App 的临时目录，省掉 security-scoped 的长时间持有。
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeData, UTTypePropertyList ]
                                                                  asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self.host presentViewController:picker animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    NSLog(@"[A2JIT] 导入被取消（未选择文件）");
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (url == nil) {
        return;
    }
    [self importPairingFileAtURL:url];
}

- (void)importPairingFileAtURL:(NSURL *)url {
    UIViewController *host = self.host;
    [A2Toast show:[self text:@"jit.toast.importing"] inView:host.view];

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *readErr = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&readErr];
    if (scoped) {
        [url stopAccessingSecurityScopedResource];
    }

    NSError *importErr = nil;
    NSString *path = data.length ? [self.store importData:data sourceName:url.lastPathComponent error:&importErr] : nil;
    if (path == nil) {
        NSString *why = importErr.localizedDescription ?: readErr.localizedDescription ?: @"未知原因";
        NSLog(@"[A2JIT] 导入失败 url=%@ reason=%@", url.absoluteString, why);
        [A2Toast show:[NSString stringWithFormat:@"%@：%@", [self text:@"jit.toast.importFail"], why]
               inView:host.view];
        return;
    }

    // 文件落盘后，事实探测会立即变化 ⇒ 重算一次状态机，再刷新面板。
    [self.coordinator refreshState];
    [A2Toast show:[self text:@"jit.toast.importOK"] inView:host.view];
    [self apply];
}

#pragma mark 开启（后台队列 + 有界等待）

- (void)runEnable {
    UIViewController *host = self.host;
    NSString *enabling = [self text:@"jit.toast.enabling"];
    NSString *enabledText = [self text:@"jit.toast.enabled"];
    NSString *failedText = [self text:@"jit.toast.enableFail"];
    [A2Toast show:enabling inView:host.view];

    A2JITCoordinator *coordinator = self.coordinator;
    __weak typeof(self) weakSelf = self;
    // ★必须在后台队列★：外部工具路径要「有界等待 + 轮询判据」（最长 20s），
    // 在主线程会直接卡住界面（Provider 侧也有主线程收紧预算的保护）。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        BOOL ok = [coordinator enableJITWithError:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *head = ok ? enabledText : failedText;
            NSString *detail = ok ? @"" : [NSString stringWithFormat:@"：%@",
                                           err.localizedDescription ?: coordinator.statusDetail];
            NSLog(@"[A2JIT] enableJIT 结果 ok=%d state=%@ detail=%@",
                  (int)ok, [A2JITStateMachine displayNameForState:coordinator.state],
                  err.localizedDescription ?: coordinator.statusDetail);
            [A2Toast show:[NSString stringWithFormat:@"%@%@", head, detail] inView:host.view];
            [weakSelf apply];
        });
    });
}

@end

#pragma mark - 面板

@implementation A2JITSettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    // ---- 装配（★只在此处发生★）----
    A2JITSystemToolLauncher *launcher = [[A2JITSystemToolLauncher alloc] init];

    A2JITUIKitFactsSource *source = [[A2JITUIKitFactsSource alloc] init];
    source.base = [[A2JITLocalFactsSource alloc] init];
    source.launcher = launcher;
    A2JITFacts *facts = [A2JITFacts factsWithSource:source];

    A2JITPairingFileStore *store = [A2JITPairingFileStore defaultStore];
    // ★判据内核★：Bridge → Natives/Support/A2JITEnvironment（真发 brk #0x69 + 区域取证）。
    A2JITEnvironmentProbe *probe = [[A2JITEnvironmentProbe alloc] init];

    NSArray<id<A2JITProvider>> *providers = [A2JITCoordinator providersWithFacts:facts
                                                                          probe:probe
                                                                       launcher:launcher
                                                              pairingFileStore:store];
    A2JITCoordinator *coordinator = [[A2JITCoordinator alloc] initWithFacts:facts providers:providers];

    NSLog(@"[A2JIT] 装配完成：strategy=%@ state=%@ 外部工具=%@ 配对文件=%@",
          [A2JITStrategySelector displayNameForStrategy:[A2JITStrategySelector strategyForFacts:facts]],
          [A2JITStateMachine displayNameForState:coordinator.state],
          facts.hasExternalEnablerInstalled ? @"已安装" : @"未安装",
          store.hasUsablePairingFile ? @"已导入" : @"未导入");

    return [self buildWithHost:host facts:facts coordinator:coordinator store:store probe:probe launcher:launcher];
}

/// 可注入重载（单测 / 装配处可传自制事实、编排器、存储、判据与拉起器）。
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host
                               facts:(A2JITFacts *)facts
                         coordinator:(A2JITCoordinator *)coordinator
                               store:(A2JITPairingFileStore *)store
                               probe:(nullable id<A2JITReadinessProbe>)probe
                            launcher:(nullable id<A2JITExternalToolLauncher>)launcher {
    A2JITPanelPresenter *presenter = [[A2JITPanelPresenter alloc] init];
    presenter.host = host;
    presenter.facts = facts;
    presenter.coordinator = coordinator;
    presenter.store = store;
    presenter.probe = probe;
    (void)launcher;   // 拉起器只被 Provider 使用；此处保留形参便于装配处换实现。

    A2JITStrategyDecision *decision = [A2JITStrategySelector decisionForFacts:facts];
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:[A2JITStrings stringForKey:@"jit.section.title"]];
    section.footerText = [NSString stringWithFormat:@"%@（%@）",
                          [A2JITStrings stringForKey:@"jit.section.footer"],
                          [A2JITStrategySelector displayNameForStrategy:decision.strategy]];

    // ---- 行 ----
    A2SettingsRow *statusRow = [[A2SettingsRow alloc] init];
    statusRow.symbolName = @"bolt.horizontal.circle.fill";
    statusRow.title = [A2JITStrings stringForKey:@"jit.row.status"];
    [section addRow:statusRow];

    A2SettingsRow *strategyRow = [[A2SettingsRow alloc] init];
    strategyRow.symbolName = @"slider.horizontal.3";
    strategyRow.title = [A2JITStrings stringForKey:@"jit.row.strategy"];
    [section addRow:strategyRow];

    A2SettingsRow *nextRow = [[A2SettingsRow alloc] init];
    nextRow.symbolName = @"arrow.right.circle.fill";
    nextRow.title = [A2JITStrings stringForKey:@"jit.row.next"];
    [section addRow:nextRow];

    A2SettingsRow *evidenceRow = [[A2SettingsRow alloc] init];
    evidenceRow.symbolName = @"doc.text.magnifyingglass";
    evidenceRow.title = [A2JITStrings stringForKey:@"jit.row.evidence"];
    [section addRow:evidenceRow];

    A2SettingsRow *importRow = [[A2SettingsRow alloc] init];
    importRow.symbolName = @"doc.badge.plus";
    importRow.title = [A2JITStrings stringForKey:@"jit.row.import"];
    importRow.accessory = A2SettingsRowAccessoryDisclosure;
    [section addRow:importRow];

    A2SettingsRow *toolRow = [[A2SettingsRow alloc] init];
    toolRow.symbolName = @"wrench.and.screwdriver.fill";
    toolRow.title = [A2JITStrings stringForKey:@"jit.row.tool"];
    [section addRow:toolRow];

    A2SettingsRow *enableRow = [[A2SettingsRow alloc] init];
    enableRow.symbolName = @"play.circle.fill";
    enableRow.title = [A2JITStrings stringForKey:@"jit.row.enable"];
    [section addRow:enableRow];

    presenter.statusRow = statusRow;
    presenter.strategyRow = strategyRow;
    presenter.nextRow = nextRow;
    presenter.evidenceRow = evidenceRow;
    presenter.importRow = importRow;
    presenter.toolRow = toolRow;
    presenter.enableRow = enableRow;

    // ---- 交互 ----
    __weak typeof(presenter) weakPresenter = presenter;
    importRow.onTap = ^{
        [weakPresenter presentImportPicker];
    };
    enableRow.onTap = ^{
        [weakPresenter runEnable];
    };

    // ---- 启动链开关（runtime chain）[RT-P1-SWITCH]（本单不改其语义）----
    BOOL chainOn = [NSUserDefaults.standardUserDefaults boolForKey:@"debug.rt_p1_runtime"];
    A2SettingsRow *chainRow = [[A2SettingsRow alloc] init];
    chainRow.symbolName = @"point.3.connected.trianglepath.dotted";
    chainRow.title = @"启动链 · runtime";
    chainRow.subtitle = @"用自研 runtime 链启动（默认关 ⇒ 旧链；仅供调试）";
    chainRow.accessory = A2SettingsRowAccessorySwitch;
    chainRow.on = chainOn;
    chainRow.onToggle = ^(BOOL isOn) {
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"debug.rt_p1_runtime"];
    };
    [section addRow:chainRow];

    [presenter apply];
    return section;
}

@end
