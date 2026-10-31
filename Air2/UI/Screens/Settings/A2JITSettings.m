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
#import "A2JITAutomaticPairingProvider.h"
#import "A2JITExternalToolProvider.h"
#import "A2JITReadinessProbe.h"
#import "A2JITExternalToolLauncher.h"
#import "A2JITPairingFileStore.h"
#import "A2JITVerdictGuidance.h"
#import "A2JITAutoPairing.h"
#import "A2JITAutoPairingGuidance.h"
#import "A2JITStrings.h"
#import "A2Log.h"     // [A2Log criterion:]：判据行的统一出口（控制台 + 会话日志文件）
#import "A2JITSystemToolLauncher.h"
#import "A2JITEnvironmentProbe.h"
#import "A2JITEnabler.h"        // [JIT-DETACH-STIKDEBUG] A2JITLauncherEnabledKey（开关写入点用）
#import "A2JITEnvironment.h"   // ★[A2PROBE]★ A2JITProbeGLKey（GL 断点探针开关的键，写入点 = 本文件）
#import "A2JITAutoPairingEngineBridge.h"
// [JIT-AUTOPAIR-3] 配对码来源（可选项表）与设备发起档的 6 位码会话
#import "A2JITPairingPinSource.h"
#import "A2JITPairingCodeSession.h"
#import "A2PairingNotifier.h"
#import "A2PairingKeepAlive.h"      // [PAIRWIRE-KEEPALIVE] 配对期间保活      // [PAIRWIRE-NOTIFY] 码/结果发本地通知
#import "A2LaunchContract.h"   // A2SelectedPairingPinSourcePrefKey（写入点=本文件）
// [JIT-DDI-1] DDI：本地镜像存储 / 判定缝 / 分流表 / 设备侧 Bridge 骨架
#import "A2JITDDI.h"
#import "A2JITDDIStore.h"
#import "A2JITDDIProbe.h"
#import "A2JITDDIGuidance.h"
#import "A2JITDDIDeviceBridge.h"
#import "A2Toast.h"
#import "A2OptionSheet.h"

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

/// [JIT-AUTOPAIR-4] 设备发起配对阶段 → 四语文案 key（★四语齐：见 A2JITStrings 的 jit.pairwire.stage.*★）。
static NSString *A2JITPairWireStageKey(A2JITDeviceInitiatedPairingStage stage) {
    switch (stage) {
        case A2JITDeviceInitiatedPairingStageIdle:        return @"jit.pairwire.stage.idle";
        case A2JITDeviceInitiatedPairingStagePreparing:   return @"jit.pairwire.stage.preparing";
        case A2JITDeviceInitiatedPairingStageAdvertising: return @"jit.pairwire.stage.advertising";
        case A2JITDeviceInitiatedPairingStageConnected:   return @"jit.pairwire.stage.connected";
        case A2JITDeviceInitiatedPairingStageVerifying:   return @"jit.pairwire.stage.verifying";
        case A2JITDeviceInitiatedPairingStageSucceeded:   return @"jit.pairwire.stage.succeeded";
        case A2JITDeviceInitiatedPairingStageFailed:      return @"jit.pairwire.stage.failed";
        case A2JITDeviceInitiatedPairingStageCancelled:   return @"jit.pairwire.stage.cancelled";
    }
    return @"jit.pairwire.stage.idle";
}

@interface A2JITPanelPresenter : NSObject <UIDocumentPickerDelegate>

@property (nonatomic, weak, nullable) UIViewController *host;
@property (nonatomic, strong) A2JITFacts *facts;
@property (nonatomic, strong) A2JITCoordinator *coordinator;
@property (nonatomic, strong) A2JITPairingFileStore *store;
@property (nonatomic, strong, nullable) id<A2JITReadinessProbe> probe;
/// [JIT-AUTOPAIR-1] ① 自动配对 Provider（用于显示前置 / 新鲜度 / 失败分类）。
@property (nonatomic, strong, nullable) A2JITAutomaticPairingProvider *autoProvider;
/// [JIT-AUTOPAIR-4] ② 自动配对引擎（设备发起档的★唯一驱动入口★就在这里）。
@property (nonatomic, strong, nullable) A2JITAutoPairingEngineBridge *autoEngine;
/// [JIT-DDI-1] DDI 判定（本地镜像 + 设备侧骨架）与本地镜像存储。
@property (nonatomic, strong, nullable) A2JITLocalDDIProbe *ddiProbe;
@property (nonatomic, strong, nullable) A2JITDDIStore *ddiStore;

// 行（section 持有它们；这里只用弱引用，避免与行内 block 形成环）
@property (nonatomic, weak, nullable) A2SettingsRow *statusRow;
@property (nonatomic, weak, nullable) A2SettingsRow *strategyRow;
@property (nonatomic, weak, nullable) A2SettingsRow *nextRow;
@property (nonatomic, weak, nullable) A2SettingsRow *autopairRow;
// [JIT-AUTOPAIR-3] 配对码来源行 + 设备发起档的 6 位码显示行
@property (nonatomic, weak, nullable) A2SettingsRow *pairpinRow;
@property (nonatomic, weak, nullable) A2SettingsRow *paircodeRow;
@property (nonatomic, weak, nullable) A2SettingsRow *ddiRow;
@property (nonatomic, weak, nullable) A2SettingsRow *ddiImportRow;
@property (nonatomic, weak, nullable) A2SettingsRow *ddiFetchRow;
@property (nonatomic, weak, nullable) A2SettingsRow *importRow;
@property (nonatomic, weak, nullable) A2SettingsRow *toolRow;
@property (nonatomic, weak, nullable) A2SettingsRow *evidenceRow;
@property (nonatomic, weak, nullable) A2SettingsRow *enableRow;

/// 当前正在等哪一类文件（0 = 配对文件；1 = DDI 镜像）。
@property (nonatomic, assign) NSInteger pendingPickerKind;

/// 按当前事实 / 状态 / 判据刷新所有行的文字与启用态。
- (void)apply;
/// [JIT-DDI-1] 刷新 DDI 行（状态 + 下一步动作 + 取证）。
- (void)applyDDIRow;
/// 起系统文档选择器挑选配对文件。
- (void)presentImportPicker;
/// [JIT-DDI-1] 起系统文档选择器挑选 DDI 镜像（与配对文件同机制）。
- (void)presentDDIImportPicker;
/// [JIT-DDI-1] 「联网取 DDI」：开关关着就提示去开；开着才真呼叫机制（如实失败）。
- (void)runDDIFetch;
/// [JIT-DDI-1] 挂载本地 DDI（未接线 / 缺能力 ⇒ 如实失败并点名缺什么）。
- (void)runDDIMount;
/// [JIT-DDI-1] DDI 镜像导入落盘（与配对文件同机制）。
- (void)importDDIImageAtURL:(NSURL *)url;
/// [JIT-AUTOPAIR-1] 后台队列开展自动配对（有界），完成后回主线程刷新。
- (void)runAutoPair;
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

    // ---- [JIT-AUTOPAIR-1] 自动配对（iOS 27+ 推荐）----
    [self applyAutopairRowForDecision:decision];

    // ---- [JIT-DDI-1] DDI 状态与下一步动作 ----
    [self applyDDIRow];

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

// ---- [JIT-AUTOPAIR-1] 自动配对行的文案与启用态（按策略 / 前置 / blocker 分流）----
- (void)applyAutopairRowForDecision:(A2JITStrategyDecision *)decision {
    BOOL applicable = (decision.strategy == A2JITStrategyAutomatic);
    A2JITAutomaticPairingProvider *ap = self.autoProvider;

    if (!applicable) {
        // 仅 iOS 27+ 适用：其它档位置灰并写明原因（不做成点了没反应的按钮）。
        self.autopairRow.enabled = NO;
        self.autopairRow.valueText = @"";
        self.autopairRow.subtitle = [self text:@"jit.row.autopair.notApplicable"];
        return;
    }

    self.autopairRow.enabled = YES;
    self.autopairRow.valueText = [self text:@"jit.row.autopair.recommended"];

    if (ap.isPairingReady) {
        self.autopairRow.subtitle = [self text:@"jit.row.autopair.ready"];
        return;
    }

    // 前置未满足 / 未确认 ⇒ ★缺哪项说哪项★（不谎报为「可用」；且未确认 ≠ 未满足）。
    NSNumber *blocking = [ap firstBlockingPrecondition];
    if (blocking) {
        A2JITAutoPairingPrecondition pc = (A2JITAutoPairingPrecondition)blocking.integerValue;
        NSString *name = [self text:[A2JITAutoPairingGuidance nameKeyForPrecondition:pc]];
        NSString *reasonKey = [ap blockingPreconditionReasonKey] ?: @"jit.row.autopair.precondMissing";
        self.autopairRow.subtitle = [NSString stringWithFormat:[self text:reasonKey], name];
        return;
    }

    // 上次开展失败的分类（按 blocker 分流，不写万能文案）。
    if (ap.lastBlocker != A2JITAutoPairingBlockerNone) {
        NSString *reason = [self text:[A2JITAutoPairingGuidance reasonKeyForBlocker:ap.lastBlocker]];
        NSString *action = [self text:[A2JITAutoPairingGuidance actionKeyForBlocker:ap.lastBlocker]];
        self.autopairRow.subtitle = [NSString stringWithFormat:@"%@；%@", reason, action];
        return;
    }

    self.autopairRow.subtitle = [self text:@"jit.row.autopair.needRun"];
}

#pragma mark [JIT-DDI-1] DDI 行（状态 + 下一步动作 + 取证）

- (void)applyDDIRow {
    A2JITLocalDDIProbe *probe = self.ddiProbe;
    if (probe == nil) {
        // 未注入探测 ⇒ 如实写「无法确认」（★不写「已就位」，也不写「缺失」★）。
        self.ddiRow.enabled = NO;
        self.ddiRow.valueText = @"";
        self.ddiRow.subtitle = [self text:@"jit.ddi.status.unknown"];
        self.ddiImportRow.enabled = NO;
        self.ddiFetchRow.enabled = NO;
        return;
    }
    // ★[PAIRFIX-DDI]★ 联网取件【不可用】是唯一事实（机制未接线，见 A2JITDDIDeviceBridge）——
    //   原来这里读那个「DDI 联网取的调试开关」偏好，让「下一步动作」按开关值分流；
    //   开关已被如实态行取代 ⇒ 恒按「取件不可用」分流（不再指引用户去开一个不存在的开关）。
    BOOL fetchAvailable = NO;
    A2JITDDIStatus *st = [probe ddiStatus];

    // 状态（短文案）+ 原因 + 下一步动作 + 取证（一行定成败，便于照单核对）。
    self.ddiRow.enabled = YES;
    self.ddiRow.valueText = [self text:[A2JITDDIGuidance statusKeyForVerdict:st.verdict]];
    NSString *reason = [self text:[A2JITDDIGuidance reasonKeyForVerdict:st.verdict]];
    NSString *next = [self text:[A2JITDDIGuidance nextActionKeyForVerdict:st.verdict
                                                            fetchEnabled:fetchAvailable]];
    self.ddiRow.subtitle = [NSString stringWithFormat:@"%@；%@｜%@", reason, next, st.evidence ?: @""];

    // 导入 DDI 行（与配对文件同机制：系统文档选择器 → 本机校验）。★这条路是真的，且不联网★。
    self.ddiImportRow.enabled = YES;
    self.ddiImportRow.subtitle = (st.verdict == A2JITDDIVerdictPresent)
        ? [self text:@"jit.ddi.status.present"]
        : [self text:@"jit.row.ddiImport.needFile"];

    // ★[PAIRFIX-DDI]★ 「联网取 DDI」行：不再是开关（开关 = 装样子）。
    //   如实写「未实现」+ 为什么 + 替代路径；行可点 ⇒ 点了走真机制调用点、如实报缺什么。
    self.ddiFetchRow.enabled = YES;
    self.ddiFetchRow.valueText = [self text:@"jit.ddi.fetch.value.unimplemented"];
    self.ddiFetchRow.subtitle = [NSString stringWithFormat:@"%@；%@",
                                 [self text:[A2JITDDIGuidance fetchUnsupportedReasonKey]],
                                 [self text:[A2JITDDIGuidance fetchUnsupportedActionKey]]];
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
    self.pendingPickerKind = 0;   // 配对文件
    // asCopy:YES ⇒ 系统先把文件拷进本 App 的临时目录，省掉 security-scoped 的长时间持有。
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeData, UTTypePropertyList ]
                                                                  asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self.host presentViewController:picker animated:YES completion:nil];
}

// [JIT-DDI-1] 导入 DDI 镜像：与配对文件【同一机制】（同一个 delegate / 同一个落盘思路）。
- (void)presentDDIImportPicker {
    if (self.host == nil) {
        return;
    }
    self.pendingPickerKind = 1;   // DDI 镜像
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeData ]
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
    if (self.pendingPickerKind == 1) {
        [self importDDIImageAtURL:url];
    } else {
        [self importPairingFileAtURL:url];
    }
}

// [JIT-DDI-1] 导入 DDI：真校验（UDIF 尾标）→ 落盘 + 元数据 → 刷新（判定会立刻反映）。
- (void)importDDIImageAtURL:(NSURL *)url {
    UIViewController *host = self.host;
    [A2Toast show:[self text:@"jit.toast.ddiImporting"] inView:host.view];

    A2JITDDIStore *store = self.ddiStore;
    if (store == nil) {
        [A2Toast show:[self text:@"jit.toast.ddiImportFail"] inView:host.view];
        return;
    }
    NSError *importErr = nil;
    NSString *path = [store importImageFromURL:url sourceName:url.lastPathComponent error:&importErr];
    if (path == nil) {
        NSString *why = importErr.localizedDescription ?: @"未知原因";
        NSLog(@"[A2JIT] DDI 导入失败 url=%@ reason=%@", url.absoluteString, why);
        [A2Toast show:[NSString stringWithFormat:@"%@：%@", [self text:@"jit.toast.ddiImportFail"], why]
               inView:host.view];
        [self apply];
        return;
    }
    [A2Toast show:[self text:@"jit.toast.ddiImportOK"] inView:host.view];
    [self apply];
}

// ★[PAIRFIX-DDI]★ 「联网取 DDI」：机制【未接线】⇒ 这里没有「开关」可开（开关是摆设，已去掉）。
// 本方法直接走真机制调用点，如实失败并点名缺什么（绝不假成功，也不给「能下」的期待）。
- (void)runDDIFetch {
    UIViewController *host = self.host;
    NSLog(@"[A2JIT] DDI 联网取：走真机制调用点（未接线则如实报缺什么；这是访问 Apple 官方服务，非「上云」）");

    A2JITLocalDDIProbe *probe = self.ddiProbe;
    if (probe == nil) {
        [A2Toast show:[self text:@"jit.toast.ddiFetchFail"] inView:host.view];
        return;
    }
    [A2Toast show:[self text:@"jit.toast.ddiFetching"] inView:host.view];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *why = nil;
        BOOL ok = [probe fetchPersonalizedImageWithReason:&why];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *head = ok ? [weakSelf text:@"jit.toast.ddiImportOK"] : [weakSelf text:@"jit.toast.ddiFetchFail"];
            NSString *detail = @"";
            if (!ok) {
                NSString *reason = [weakSelf text:[A2JITDDIGuidance fetchUnsupportedReasonKey]];
                NSString *action = [weakSelf text:[A2JITDDIGuidance fetchUnsupportedActionKey]];
                detail = [NSString stringWithFormat:@"：%@；%@%@", reason, action,
                          why.length ? [NSString stringWithFormat:@"（取证：%@）", why] : @""];
            }
            NSLog(@"[A2JIT] DDI 联网取结果 ok=%d detail=%@", (int)ok, why ?: @"(无)");
            [A2Toast show:[NSString stringWithFormat:@"%@%@", head, detail] inView:host.view];
            [weakSelf apply];
        });
    });
}

// [JIT-DDI-1] 挂载本地 DDI：未接线 / 缺能力 ⇒ ★如实失败并点名缺什么（不假成功）★。
- (void)runDDIMount {
    UIViewController *host = self.host;
    A2JITLocalDDIProbe *probe = self.ddiProbe;
    if (probe == nil) {
        [A2Toast show:[self text:@"jit.ddi.status.unknown"] inView:host.view];
        [self apply];
        return;
    }
    NSString *why = nil;
    BOOL ok = [probe mountCurrentImageWithReason:&why];
    NSString *head = [self text:ok ? @"jit.toast.ddiMountOK" : @"jit.ddi.mount.unavailable.reason"];
    NSString *detail = @"";
    if (!ok) {
        NSString *action = [self text:[A2JITDDIGuidance mountUnavailableActionKey]];
        detail = [NSString stringWithFormat:@"；%@%@", action,
                  why.length ? [NSString stringWithFormat:@"（取证：%@）", why] : @""];
    }
    NSLog(@"[A2JIT] DDI 挂载结果 ok=%d detail=%@", (int)ok, why ?: @"(无)");
    [A2Toast show:[NSString stringWithFormat:@"%@%@", head, detail] inView:host.view];
    [self apply];
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

#pragma mark [JIT-AUTOPAIR-1] 自动配对（后台队列 + 有界）

- (void)runAutoPair {
    UIViewController *host = self.host;
    NSString *running = [self text:@"jit.toast.autopairing"];
    NSString *okText = [self text:@"jit.toast.autopairOK"];
    NSString *failText = [self text:@"jit.toast.autopairFail"];
    [A2Toast show:running inView:host.view];

    A2JITCoordinator *coordinator = self.coordinator;
    __weak typeof(self) weakSelf = self;
    // ★必须在后台队列★：自动配对要「发现 → RSD → pair-verify → TLS-PSK → 写文件」（有界），
    // 在主线程会直接卡住界面（Provider 侧也有主线程收紧预算的保护）。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        BOOL ok = [coordinator acquirePairingWithError:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *head = ok ? okText : failText;
            NSString *detail = ok ? @"" : [NSString stringWithFormat:@"：%@",
                                           err.localizedDescription ?: coordinator.statusDetail];
            NSLog(@"[A2JIT] autopair 结果 ok=%d state=%@ detail=%@",
                  (int)ok, [A2JITStateMachine displayNameForState:coordinator.state],
                  err.localizedDescription ?: coordinator.statusDetail);
            [A2Toast show:[NSString stringWithFormat:@"%@%@", head, detail] inView:host.view];
            [weakSelf apply];
        });
    });
}

@end

#pragma mark - [JIT-SRC] 「JIT 启动器」可选项（★写入点唯一 = 本文件★）

//  ★六个取值是跨层契约★：逐字存进 NSUserDefaults 的 `a2jit.preferredSource`，由
//  `Natives/Support/A2JITEnabler.m` 的 `a2jit_preferred_source()` 解析（那边是唯一读取点，
//  且只认这六个串 —— 别的值一律按 auto 处理并落一行判据）。
//  ★改这里的取值必须同时改那边★（NSUserDefaults 里存的就是这些串）。
//  ★本页只负责写与显示★：判据 / 回退 / 失败原因全在 Natives 那一处（分层：UI 不判 JIT）。
static NSString *const kA2JITLauncherPrefKey = @"a2jit.preferredSource";

/// 选项表 = { 取值, 四语文案 key }。顺序 = 弹窗里的顺序（默认档在前）。
static NSArray<NSArray<NSString *> *> *A2JITLauncherOptionTable(void) {
    return @[
        @[ @"auto",       @"jit.launcher.auto" ],
        @[ @"debugger",   @"jit.launcher.debugger" ],
        @[ @"jailbreak",  @"jit.launcher.jailbreak" ],
        @[ @"trollstore", @"jit.launcher.trollstore" ],
        @[ @"stikdebug",  @"jit.launcher.stikdebug" ],
        @[ @"sidestore",  @"jit.launcher.sidestore" ],
    ];
}

/// 当前生效的取值（缺键 / 空串 ⇒ auto；★与 Natives 侧的缺省口径一致★）。
static NSString *A2JITCurrentLauncherSource(void) {
    NSString *raw = [NSUserDefaults.standardUserDefaults stringForKey:kA2JITLauncherPrefKey];
    return raw.length > 0 ? raw : @"auto";
}

/// 取值 → 四语文案（未知取值回落 auto 的文案，不显示空行 / 不显示裸标识符）。
static NSString *A2JITLauncherLabelForSource(NSString *source) {
    for (NSArray<NSString *> *opt in A2JITLauncherOptionTable()) {
        if ([opt[0] isEqualToString:source]) {
            return [A2JITStrings stringForKey:opt[1]];
        }
    }
    return [A2JITStrings stringForKey:@"jit.launcher.auto"];
}

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

    // ★[JIT-AUTOPAIR-1] 自动配对（iOS 27+）引擎 + 前置条件★：真机引擎 = Bridge → Natives；
    // 本单为【骨架】：engineAvailable=NO 且前置全 Unknown ⇒ Provider 会【如实】报「未接入 / 未确认」，
    // 绝不假成功（RPPairing 真实现见 docs/JIT-PROVISIONING.md §4.2）。
    A2JITAutoPairingEngineBridge *autoEngine = [[A2JITAutoPairingEngineBridge alloc] init];
    // ★[JIT-AUTOPAIR-2] 把落盘目标注入引擎★：pair-verify 成功后由 Bridge 直接写进容器约定位置
    // （Provider 侧仍会独立复验 store.hasUsablePairingFile —— 不凭引擎一面之词）。
    autoEngine.pairingFileStore = store;
    // ★[JIT-AUTOPAIR-3] 把「配对码来源」这一【用户可见选项】解析成 Natives 的 pin provider★
    // （用户口径：底层保留 A2RPPairSetupPinProvider 缝，但入口必须是可选择项 —— 选择项 → 解析 → 喂缝）。
    // ★未选择 / 选到未实现的档 ⇒ 返回 nil（Bridge 会如实拒绝并点名）★，绝不静默回退。
    autoEngine.pairSetupPinProvider = ^NSString *(A2RPPairSetupPinPrompt prompt) {
        (void)prompt;
        NSString *why = nil;
        NSString *pin = [A2JITPairingPinResolver resolvedPinForDisplayedCode:
                         [A2JITPairingCodeSession sharedSession].code reason:&why];
        // ★不把码本身写进日志★（只记长度 / 是否取到）。
        [A2Log criterion:@"[A2JIT] pair-setup 取配对码：%@ ⇒ %@", [A2JITPairingPinResolver criterionLine],
              pin.length > 0 ? [NSString stringWithFormat:@"用码（%lu 位）", (unsigned long)pin.length]
                             : [NSString stringWithFormat:@"拒绝（%@）", why ?: @"-"]];
        return pin;
    };
    A2JITAutoPairingPreconditions *preconditions = [autoEngine readPreconditions];

    // ★[JIT-DDI-1] DDI 真探测★：本地镜像存储（容器约定目录）+ 设备侧查询（Bridge 骨架）+ 系统要求。
    // 系统构建号取自 NSProcessInfo（取不到就是 nil ⇒ 判定按「无法对齐」如实报 Unknown，不猜）。
    A2JITDDIDeviceBridge *ddiDevice = [[A2JITDDIDeviceBridge alloc] init];
    NSString *osBuild = [A2JITDDI buildFromOperatingSystemVersionString:
                         NSProcessInfo.processInfo.operatingSystemVersionString];
    A2JITDDIRequirement *ddiRequirement =
        [A2JITDDIRequirement requirementWithOSMajorVersion:facts.osMajorVersion
                                              minorVersion:facts.osMinorVersion
                                                     build:osBuild];
    A2JITDDIStore *ddiStore = [A2JITDDIStore defaultStore];
    A2JITLocalDDIProbe *ddiProbe = [[A2JITLocalDDIProbe alloc] initWithStore:ddiStore
                                                                 requirement:ddiRequirement
                                                                 deviceQuery:ddiDevice];

    NSArray<id<A2JITProvider>> *providers = [A2JITCoordinator providersWithFacts:facts
                                                                  preconditions:preconditions
                                                                         engine:autoEngine
                                                                       ddiProbe:ddiProbe
                                                                          probe:probe
                                                                       launcher:launcher
                                                              pairingFileStore:store];
    A2JITCoordinator *coordinator = [[A2JITCoordinator alloc] initWithFacts:facts providers:providers];

    // 取回 ① 自动配对 Provider（面板要显示它的前置 / 新鲜度 / 失败分类）。
    A2JITAutomaticPairingProvider *autoProvider = nil;
    for (id<A2JITProvider> p in providers) {
        if (p.kind == A2JITProviderKindAutomaticPairing) {
            autoProvider = (A2JITAutomaticPairingProvider *)p;
            break;
        }
    }

    NSLog(@"[A2JIT] 装配完成：strategy=%@ state=%@ 外部工具=%@ 配对文件=%@ 自动配对=%@ DDI=%@",
          [A2JITStrategySelector displayNameForStrategy:[A2JITStrategySelector strategyForFacts:facts]],
          [A2JITStateMachine displayNameForState:coordinator.state],
          facts.hasExternalEnablerInstalled ? @"已安装" : @"未安装",
          store.hasUsablePairingFile ? @"已导入" : @"未导入",
          autoProvider ? (autoProvider.canGeneratePairingFile ? @"可生成" : @"未就绪") : @"无",
          [A2JITDDI displayNameForVerdict:[ddiProbe ddiStatus].verdict]);

    return [self buildWithHost:host facts:facts coordinator:coordinator store:store
                         probe:probe launcher:launcher autoProvider:autoProvider
                      autoEngine:autoEngine ddiProbe:ddiProbe ddiStore:ddiStore];
}

/// 可注入重载（单测 / 装配处可传自制事实、编排器、存储、判据、拉起器与 DDI 探测）。
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host
                               facts:(A2JITFacts *)facts
                         coordinator:(A2JITCoordinator *)coordinator
                               store:(A2JITPairingFileStore *)store
                               probe:(nullable id<A2JITReadinessProbe>)probe
                            launcher:(nullable id<A2JITExternalToolLauncher>)launcher
                        autoProvider:(nullable A2JITAutomaticPairingProvider *)autoProvider
                          autoEngine:(nullable A2JITAutoPairingEngineBridge *)autoEngine
                            ddiProbe:(nullable A2JITLocalDDIProbe *)ddiProbe
                            ddiStore:(nullable A2JITDDIStore *)ddiStore {
    A2JITPanelPresenter *presenter = [[A2JITPanelPresenter alloc] init];
    presenter.host = host;
    presenter.facts = facts;
    presenter.coordinator = coordinator;
    presenter.store = store;
    presenter.probe = probe;
    presenter.autoProvider = autoProvider;
    presenter.autoEngine = autoEngine;   // ★[JIT-AUTOPAIR-4] 设备发起档的★唯一驱动入口★载体★
    presenter.ddiProbe = ddiProbe;
    presenter.ddiStore = ddiStore;
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

    // ---- [JIT-SRC] JIT 启动器（★用户可选来源；写入点唯一 = 本段★）----
    //   放在「分级策略」下面：策略回答「这台机按系统分到哪一档」（只读结论），
    //   本行回答「这一档里具体用哪条来源去拿 JIT」（可选项）。两者不是一回事，不合并。
    A2SettingsRow *launcherRow = [[A2SettingsRow alloc] init];
    launcherRow.symbolName = @"arrow.up.forward.app.fill";
    launcherRow.title = [A2JITStrings stringForKey:@"jit.row.launcher"];
    launcherRow.accessory = A2SettingsRowAccessoryDisclosure;
    [section addRow:launcherRow];

    __weak A2SettingsRow *weakLauncherRow = launcherRow;
    __weak UIViewController *launcherHost = host;
    // 值一变就刷新本行（选完立刻显示新值；生效点是「下次启动游戏」，见副标题）。
    void (^refreshLauncherRow)(void) = ^{
        A2SettingsRow *row = weakLauncherRow;
        row.valueText = A2JITLauncherLabelForSource(A2JITCurrentLauncherSource());
        row.subtitle = [A2JITStrings stringForKey:@"jit.launcher.subtitle"];
    };
    refreshLauncherRow();

    launcherRow.onTap = ^{
        UIViewController *hvc = launcherHost;
        if (hvc == nil) { return; }
        NSString *cur = A2JITCurrentLauncherSource();
        // 与「配对码来源」同一套二级选择界面（A2OptionSheet + 选中勾），不另造控件。
        A2OptionSheet *sheet =
            [A2OptionSheet sheetWithTitle:[A2JITStrings stringForKey:@"jit.row.launcher"]
                                  message:[A2JITStrings stringForKey:@"jit.launcher.subtitle"]];
        for (NSArray<NSString *> *opt in A2JITLauncherOptionTable()) {
            NSString *value = opt[0];
            NSString *label = [A2JITStrings stringForKey:opt[1]];
            [sheet addOptionWithTitle:label
                             selected:[value isEqualToString:cur]
                          destructive:NO
                              handler:^{
                // ★写入点唯一★：键 = kA2JITLauncherPrefKey，值 = 六个契约串之一。
                [NSUserDefaults.standardUserDefaults setObject:value forKey:kA2JITLauncherPrefKey];
                [NSUserDefaults.standardUserDefaults synchronize];
                [A2Log criterion:@"[JIT-SRC] settings: JIT 启动器 → %@（键 %@；下次启动游戏生效）",
                 value, kA2JITLauncherPrefKey];
                refreshLauncherRow();
                [A2Toast show:[NSString stringWithFormat:
                                [A2JITStrings stringForKey:@"jit.launcher.toast.selected"], label]
                       inView:hvc.view];
            }];
        }
        [sheet presentFrom:hvc];
    };

    // ---- [JIT-DETACH-STIKDEBUG] 「JIT 启动器」总开关（★写入点唯一 = 本段★）----
    //   紧跟在上面那行来源选择后面：同一处能力、同一屏，开关关着 ⇒ A2JITEnvironment 里那两条
    //   新逻辑（JIT 就绪后主动 detach、调试器不认 detach 时 self-mmap 兜底）一个字节都不执行。
    //   ★还要来源严格 == stikdebug 才生效★：判据在 Natives/Support 的
    //   a2jit_detach_selfmmap_armed()（来源仍只由 a2jit_preferred_source() 读，本页只写值）。
    BOOL launcherArmOn = [NSUserDefaults.standardUserDefaults boolForKey:A2JITLauncherEnabledKey];
    A2SettingsRow *launcherArmRow = [[A2SettingsRow alloc] init];
    launcherArmRow.symbolName = @"bolt.badge.clock.fill";
    launcherArmRow.title = [A2JITStrings stringForKey:@"jit.launcher.detach.title"];
    launcherArmRow.subtitle = [A2JITStrings stringForKey:@"jit.launcher.detach.subtitle"];
    launcherArmRow.accessory = A2SettingsRowAccessorySwitch;
    launcherArmRow.on = launcherArmOn;
    launcherArmRow.onToggle = ^(BOOL isOn) {
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:A2JITLauncherEnabledKey];
        [NSUserDefaults.standardUserDefaults synchronize];
        [A2Log criterion:@"[JIT-SRC] settings: JIT 启动器开关 → %@（键 %@；来源须为 stikdebug 才生效，下次启动游戏生效）",
         isOn ? @"开" : @"关", A2JITLauncherEnabledKey];
    };
    [section addRow:launcherArmRow];

    // ---- [A2JIT-DEBUG-HOLD] 「调试暂停（JIT 就绪后）」开关（★写入点唯一 = 本段★）----
    //   紧跟在上面那行后面：同一处能力、同一屏。
    //   开着 ⇒ 启动链在【VM 已建好 + libjvm 的 code cache 已到手、还没派发 game main】那一点停住，
    //   弹「JIT 已就绪」，等用户 lldb 附加完点「继续」才跑游戏主类（300 秒无人点自动放行）。
    //   ★关着（默认）⇒ 启动链一个字节都不变★（判据与提示在 Natives/Support 的
    //   a2jit_debug_hold_before_main，调用点只有一个：Natives/Context/a2_launch.m）。
    BOOL debugHoldOn = ([NSUserDefaults.standardUserDefaults objectForKey:A2JITDebugHoldAfterJITKey] != nil) &&
        [NSUserDefaults.standardUserDefaults boolForKey:A2JITDebugHoldAfterJITKey];
    A2SettingsRow *debugHoldRow = [[A2SettingsRow alloc] init];
    debugHoldRow.symbolName = @"pause.circle.fill";
    debugHoldRow.title = [A2JITStrings stringForKey:@"jit.debughold.title"];
    debugHoldRow.subtitle = [A2JITStrings stringForKey:@"jit.debughold.subtitle"];
    debugHoldRow.accessory = A2SettingsRowAccessorySwitch;
    debugHoldRow.on = debugHoldOn;
    debugHoldRow.onToggle = ^(BOOL isOn) {
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:A2JITDebugHoldAfterJITKey];
        [NSUserDefaults.standardUserDefaults synchronize];
        [A2Log criterion:@"[A2JIT] settings: 调试暂停 → %@（键 %@；下次启动游戏生效）",
         isOn ? @"开" : @"关", A2JITDebugHoldAfterJITKey];
    };
    [section addRow:debugHoldRow];

    // ---- ★[A2PROBE]★ 「GL 断点探针」开关（★写入点唯一 = 本段★）----
    //   紧跟在上面那行后面：同一屏、同类调试开关。
    //   开着 ⇒ 启动时把「KW 的 glLoadIdentity」与「ANGLE 的 glLoadIdentity」两个地址交给
    //   StikDebug 脚本（brk #0xf00d x16=99），脚本各下一发 Z0；MC 第一次调到其中之一时脚本打
    //   `[A2PROBE] HIT pc=… lr=… x0=… x1=…`，回答「到底落到了哪个库」。
    //   ★关着（默认）⇒ 一个字节都不发★（判据与发点全在 Natives/Support 的
    //   a2_jit_probe_arm，调用点只有一个：Natives/Renderer/a2_gl_bridge.m）。
    //   ★还要求本进程有调试器 attach（CS_DEBUGGED）★：没有调试器就没有脚本应答，布点无处受理。
    BOOL probeGLOn = ([NSUserDefaults.standardUserDefaults objectForKey:A2JITProbeGLKey] != nil) &&
        [NSUserDefaults.standardUserDefaults boolForKey:A2JITProbeGLKey];
    A2SettingsRow *probeGLRow = [[A2SettingsRow alloc] init];
    probeGLRow.symbolName = @"target";
    probeGLRow.title = [A2JITStrings stringForKey:@"jit.probegl.title"];
    probeGLRow.subtitle = [A2JITStrings stringForKey:@"jit.probegl.subtitle"];
    probeGLRow.accessory = A2SettingsRowAccessorySwitch;
    probeGLRow.on = probeGLOn;
    probeGLRow.onToggle = ^(BOOL isOn) {
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:A2JITProbeGLKey];
        [NSUserDefaults.standardUserDefaults synchronize];
        [A2Log criterion:@"[A2PROBE] settings: GL 断点探针 → %@（键 %@；须有调试器 attach 才生效，下次启动游戏生效）",
         isOn ? @"开" : @"关", A2JITProbeGLKey];
    };
    [section addRow:probeGLRow];

    A2SettingsRow *nextRow = [[A2SettingsRow alloc] init];
    nextRow.symbolName = @"arrow.right.circle.fill";
    nextRow.title = [A2JITStrings stringForKey:@"jit.row.next"];
    [section addRow:nextRow];

    A2SettingsRow *evidenceRow = [[A2SettingsRow alloc] init];
    evidenceRow.symbolName = @"doc.text.magnifyingglass";
    evidenceRow.title = [A2JITStrings stringForKey:@"jit.row.evidence"];
    [section addRow:evidenceRow];

    A2SettingsRow *autopairRow = [[A2SettingsRow alloc] init];
    autopairRow.symbolName = @"wand.and.stars";
    autopairRow.title = [A2JITStrings stringForKey:@"jit.row.autopair"];
    autopairRow.accessory = A2SettingsRowAccessoryDisclosure;
    [section addRow:autopairRow];

    // ---- [JIT-DDI-1] DDI：状态行 / 导入行 / 「联网取 DDI」开关行 ----
    A2SettingsRow *ddiRow = [[A2SettingsRow alloc] init];
    ddiRow.symbolName = @"externaldrive.fill";
    ddiRow.title = [A2JITStrings stringForKey:@"jit.row.ddi"];
    ddiRow.accessory = A2SettingsRowAccessoryDisclosure;   // 可点：挂载本地 DDI（如实失败也会点名缺什么）
    [section addRow:ddiRow];

    A2SettingsRow *ddiImportRow = [[A2SettingsRow alloc] init];
    ddiImportRow.symbolName = @"square.and.arrow.down.on.square";
    ddiImportRow.title = [A2JITStrings stringForKey:@"jit.row.ddiImport"];
    ddiImportRow.accessory = A2SettingsRowAccessoryDisclosure;
    [section addRow:ddiImportRow];

    // ---- 「联网取 DDI」：★未接线 ⇒ 不做成可开关的假开关★ ----
    //   机制（个性化取件 + image_mounter 挂载）未接线、且取件来源尚未拍板（见
    //   A2JITDDIDeviceBridge 与 docs/JIT-PROVISIONING.md §3.4）⇒ 原来那个「只写偏好、
    //   什么也不做」的开关就是摆设（真机反馈「开关打开了也不会下」）。
    //   现在它是【如实态行】：valueText 写「未实现」，副标题写清为什么 + 替代路径；
    //   点它 = 走真实机制调用点，如实报缺什么（绝不假成功）。
    A2SettingsRow *ddiFetchRow = [[A2SettingsRow alloc] init];
    ddiFetchRow.symbolName = @"antenna.radiowaves.left.and.right";
    ddiFetchRow.title = [A2JITStrings stringForKey:@"jit.row.ddiFetch"];
    ddiFetchRow.accessory = A2SettingsRowAccessoryDisclosure;   // 可点：点了如实报未接线
    [section addRow:ddiFetchRow];

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
    presenter.autopairRow = autopairRow;
    presenter.ddiRow = ddiRow;
    presenter.ddiImportRow = ddiImportRow;
    presenter.ddiFetchRow = ddiFetchRow;
    presenter.importRow = importRow;
    presenter.toolRow = toolRow;
    presenter.enableRow = enableRow;

    // ---- 交互 ----
    // ★[PAIRFIX-LIFE]★ 面板呈现器必须【活到用户点完为止】。
    //   原来这里捕的是 __weak，而 presenter 在本方法里只是栈上局部变量 ⇒ 本方法一返回它就被释放，
    //   行内 block 里的 [weakPresenter …] 全成了「发给 nil」：
    //     ·「一键开展自动配对」「开启 JIT」「导入配对文件」「导入 DDI 镜像」「挂载 DDI」
    //       这些行点了【没有任何反应】（真机反馈「很多按钮点不进去」）；
    //     · 配对引擎（presenter.autoEngine）也随之释放 ⇒「开始配对」直接落进 engine==nil 分支，
    //       报一句「还没显示 6 位码 ⇒ 先选设备发起档」（真机反馈「我生成了配对码…说我还没生成」）——
    //       那一刻【码根本没生成/没显示】，用户「想输都输不了」。
    //   行内 block【强持有】它就修好了：presenter 对行只持 weak（见上面的行声明）⇒ 依旧不成环，
    //   生命周期 = section（section 挂在设置页 VC 的视图树上）。
    A2JITPanelPresenter *panelPresenter = presenter;
    autopairRow.onTap = ^{
        [panelPresenter runAutoPair];
    };
    ddiImportRow.onTap = ^{
        [panelPresenter presentDDIImportPicker];
    };
    ddiRow.onTap = ^{
        [panelPresenter runDDIMount];
    };
    // ★[PAIRFIX-DDI]★ 「联网取 DDI」不再是「开关」（机制未接线 ⇒ 开关是摆设）：
    //   这一行改成【如实态行】，点它 = 如实报缺什么（绝不假成功，也不给「能下」的期待）。
    ddiFetchRow.onTap = ^{
        [panelPresenter runDDIFetch];
    };
    importRow.onTap = ^{
        [panelPresenter presentImportPicker];
    };
    enableRow.onTap = ^{
        [panelPresenter runEnable];
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

    // ---- [JIT-AUTOPAIR-3] 配对码来源（★用户可见的可选项，不是代码缝★）+ 设备发起档的 6 位码显示 ----
    A2SettingsRow *pairpinRow = [[A2SettingsRow alloc] init];
    pairpinRow.symbolName = @"number.square.fill";
    pairpinRow.title = [A2JITStrings stringForKey:@"jit.row.pairpin"];
    pairpinRow.accessory = A2SettingsRowAccessoryDisclosure;
    [section addRow:pairpinRow];

    A2SettingsRow *paircodeRow = [[A2SettingsRow alloc] init];
    paircodeRow.symbolName = @"key.horizontal.fill";
    paircodeRow.title = [A2JITStrings stringForKey:@"jit.pairpin.row.code"];
    [section addRow:paircodeRow];

    __weak A2SettingsRow *weakPairpin = pairpinRow;
    __weak A2SettingsRow *weakPaircode = paircodeRow;
    // 主机名要能认出是 Air2（用户要在系统设置的配对列表里选它）。
    NSString *pairableHostName = [NSString stringWithFormat:@"Air2 (%@)",
                                  NSProcessInfo.processInfo.hostName ?: @"iPhone"];
    void (^refreshPairpin)(void) = ^{
        A2JITPairingPinMode mode = [A2JITPairingPinResolver selectedMode];
        NSString *sel = [NSUserDefaults.standardUserDefaults stringForKey:A2SelectedPairingPinSourcePrefKey] ?: @"";
        A2JITPairingPinSourceItem *item = [A2JITPairingPinSourceCatalog itemForIdentifier:sel];
        NSString *label = item ? [A2JITStrings stringForKey:item.nameKey]
                               : [A2JITStrings stringForKey:@"jit.pairpin.notselected"];
        A2SettingsRow *pr = weakPairpin;
        pr.valueText = [A2JITPairingPinSourceCatalog displayNameForMode:mode];
        pr.subtitle = [NSString stringWithFormat:@"%@｜%@", label, [A2JITPairingPinResolver criterionLine]];

        // 码行：只有设备发起档且已生成码才可点（点=复制）；否则如实写清楚。
        A2JITPairingCodeSession *cs = A2JITPairingCodeSession.sharedSession;
        A2JITPairingCodeSession *persisted = [A2JITPairingCodeSession restoredFromDefaults];
        NSString *shown = cs.code.length > 0 ? cs.code : (persisted.code ?: @"");
        NSString *host = cs.hostName.length > 0 ? cs.hostName : (persisted.hostName ?: pairableHostName);
        A2SettingsRow *cr = weakPaircode;
        // ★[PAIRWIRE-FIX] 有码就显示(不再绑死档位):真机反馈点了开始配对看不到码。★
    if (shown.length == 6) {
            cr.enabled = YES;
            cr.valueText = shown;   // ★6 位码：大字号显示（行内 valueText）★
            cr.subtitle = [NSString stringWithFormat:@"%@｜%@",
                           [NSString stringWithFormat:[A2JITStrings stringForKey:@"jit.pairpin.instruction"], host],
                           [A2JITStrings stringForKey:@"jit.pairpin.row.copy"]];
        } else if (mode == A2JITPairingPinModeDeviceInitiated) {
            cr.enabled = YES;
            cr.valueText = @"";
            cr.subtitle = [NSString stringWithFormat:@"%@｜%@", host,
                           [A2JITStrings stringForKey:@"jit.pairpin.row.copy"]];
        } else {
            cr.enabled = NO;
            cr.valueText = @"";
            cr.subtitle = [A2JITStrings stringForKey:@"jit.pairpin.notselected"];
        }
    };
    refreshPairpin();

    __weak UIViewController *weakHostVC = host;
    pairpinRow.onTap = ^{
        UIViewController *hvc = weakHostVC;
        if (hvc == nil) return;
        A2OptionSheet *sheet =
            [A2OptionSheet sheetWithTitle:[A2JITStrings stringForKey:@"jit.row.pairpin"]
                                  message:[A2JITPairingPinResolver criterionLine]];
        NSString *cur = [NSUserDefaults.standardUserDefaults stringForKey:A2SelectedPairingPinSourcePrefKey] ?: @"";
        for (A2JITPairingPinSourceItem *it in [A2JITPairingPinSourceCatalog allItems]) {
            NSString *title = [A2JITStrings stringForKey:it.nameKey];
            if (!it.implemented) {
                title = [NSString stringWithFormat:@"%@（%@）", title,
                         [A2JITStrings stringForKey:@"jit.pairpin.unsupported"]];
            }
            [sheet addOptionWithTitle:title
                             selected:[it.identifier isEqualToString:cur]
                          destructive:NO
                              handler:^{
                // ★写入点唯一点★：偏好键 = A2SelectedPairingPinSourcePrefKey。
                [NSUserDefaults.standardUserDefaults setObject:it.identifier
                                                        forKey:A2SelectedPairingPinSourcePrefKey];
                [A2Log criterion:@"[A2JIT] settings: 配对码来源 → %@", [A2JITPairingPinResolver criterionLine]];
                if (it.mode == A2JITPairingPinModeDeviceInitiated) {
                    // 设备发起档：立刻生成并显示 6 位码（用户要切到系统设置去输）。
                    NSError *e = nil;
                    [A2JITPairingCodeSession.sharedSession beginDeviceInitiatedWithHostName:pairableHostName error:&e];
                } else if (!it.implemented) {
                    // ★未实现的档：选中即如实拒绝并点名（不静默回退）★。
                    NSString *why = nil;
                    (void)[A2JITPairingPinResolver resolvedPinForDisplayedCode:nil reason:&why];
                    [A2Toast show:[NSString stringWithFormat:@"%@", why ?: @""] inView:hvc.view];
                }
                refreshPairpin();
                [A2Toast show:[NSString stringWithFormat:[A2JITStrings stringForKey:@"jit.pairpin.toast.selected"],
                               [A2JITPairingPinSourceCatalog displayNameForMode:it.mode]]
                       inView:hvc.view];
            }];
        }
        [sheet presentFrom:hvc];
    };

    paircodeRow.onTap = ^{
        UIViewController *hvc = weakHostVC;
        A2JITPairingCodeSession *cs = A2JITPairingCodeSession.sharedSession;
        A2JITPairingCodeSession *persisted = [A2JITPairingCodeSession restoredFromDefaults];
        NSString *shown = cs.code.length > 0 ? cs.code : (persisted.code ?: @"");
        if (shown.length != 6) {
            // 还没生成 ⇒ 现场生成（等价于点「设备发起档」的第一次）。
            NSError *e = nil;
            [cs beginDeviceInitiatedWithHostName:pairableHostName error:&e];
            shown = cs.code;
        }
        UIPasteboard.generalPasteboard.string = shown;
        [A2Toast show:[NSString stringWithFormat:@"%@: %@", [A2JITStrings stringForKey:@"jit.pairpin.row.copy"], shown]
               inView:hvc.view];
        refreshPairpin();
    };

    // ---- [JIT-AUTOPAIR-4] 设备发起档：★真实的「开始配对 / 取消」按钮 + 状态文字（四语齐）★ ----
    //   ① 生成 6 位码并交给已有 UI/持久化 = 上面那两行在用的 A2JITPairingCodeSession（Player 层）；
    //   ②–⑥ 全在 Bridge 的★唯一驱动入口★ startDeviceInitiatedPairingWithHostName:… 里。
    A2SettingsRow *pairwireStartRow = [[A2SettingsRow alloc] init];
    pairwireStartRow.symbolName = @"dot.radiowaves.left.and.right";
    pairwireStartRow.title = [A2JITStrings stringForKey:@"jit.pairwire.row.start"];
    pairwireStartRow.accessory = A2SettingsRowAccessoryDisclosure;
    [section addRow:pairwireStartRow];

    A2SettingsRow *pairwireCancelRow = [[A2SettingsRow alloc] init];
    pairwireCancelRow.symbolName = @"xmark.circle";
    pairwireCancelRow.title = [A2JITStrings stringForKey:@"jit.pairwire.row.cancel"];
    pairwireCancelRow.destructive = YES;
    [section addRow:pairwireCancelRow];

    __weak A2SettingsRow *weakPWStart = pairwireStartRow;
    __weak A2SettingsRow *weakPWCancel = pairwireCancelRow;
    // ★[PAIRFIX-LIFE]★ 引擎也【强捕获】：它原来只被 presenter 强持有（presenter.autoEngine），
    //   presenter 一没它就跟着没 ⇒「开始配对」会误报成「还没显示 6 位码」（真机反馈）。
    A2JITAutoPairingEngineBridge *panelEngine = presenter.autoEngine;

    // 阶段 → UI（★块可在任意线程被调用 ⇒ 内部自己回主线程★）。
    void (^applyPairwireStage)(A2JITDeviceInitiatedPairingStage, NSString *_Nullable) =
        ^(A2JITDeviceInitiatedPairingStage stage, NSString *detail) {
        dispatch_async(dispatch_get_main_queue(), ^{
            A2SettingsRow *s = weakPWStart;
            A2SettingsRow *c = weakPWCancel;
            if (s == nil || c == nil) { return; }
            BOOL running = (stage == A2JITDeviceInitiatedPairingStagePreparing ||
                            stage == A2JITDeviceInitiatedPairingStageAdvertising ||
                            stage == A2JITDeviceInitiatedPairingStageConnected ||
                            stage == A2JITDeviceInitiatedPairingStageVerifying);
            s.valueText = [A2JITStrings stringForKey:A2JITPairWireStageKey(stage)];
            s.subtitle = detail.length ? detail
                : [NSString stringWithFormat:[A2JITStrings stringForKey:@"jit.pairpin.instruction"], host];
            s.enabled = !running;
            c.enabled = running;

            // ★同步到既有 A2JITPairingCodeSession（不改它的语义；顺带打出它的 [A2-PAIRPIN] 判据行）★
            A2JITPairingCodeSession *cs = A2JITPairingCodeSession.sharedSession;
            switch (stage) {
                case A2JITDeviceInitiatedPairingStageAdvertising:
                    [cs advanceToState:A2JITPairingCodeStateAdvertising detail:detail]; break;
                case A2JITDeviceInitiatedPairingStageConnected:
                    [cs advanceToState:A2JITPairingCodeStateConnected detail:detail]; break;
                case A2JITDeviceInitiatedPairingStageVerifying:
                    [cs advanceToState:A2JITPairingCodeStateVerifying detail:detail]; break;
                case A2JITDeviceInitiatedPairingStageSucceeded:
                A2PairingNotifyPostDone(YES, nil);
                A2PairingKeepAliveStop();
                    [cs advanceToState:A2JITPairingCodeStateSucceeded detail:detail]; break;
                case A2JITDeviceInitiatedPairingStageFailed:
                A2PairingNotifyPostDone(NO, detail);
                A2PairingKeepAliveStop();
                    [cs advanceToState:A2JITPairingCodeStateFailed detail:detail]; break;
                case A2JITDeviceInitiatedPairingStageCancelled:
                    // 码会话没有「取消」态 ⇒ 回到 Idle（★码仍显示，可重试★），并如实记一条。
                    A2PairingKeepAliveStop();
                    [cs advanceToState:A2JITPairingCodeStateIdle
                                detail:detail.length ? detail : @"已取消（码仍在显示，可重试）"]; break;
                case A2JITDeviceInitiatedPairingStageIdle:
                case A2JITDeviceInitiatedPairingStagePreparing:
                default:
                    break;
            }
        });
    };
    applyPairwireStage(A2JITDeviceInitiatedPairingStageIdle, nil);
    pairwireCancelRow.enabled = NO;   // 没在跑时「取消」不可点（不做点了没反应的按钮）

    pairwireStartRow.onTap = ^{
        UIViewController *hvc = weakHostVC;
        A2JITPairingPinMode modeForThisRow = [A2JITPairingPinResolver selectedMode];
        A2JITAutoPairingEngineBridge *engine = panelEngine;
        if (hvc == nil) { return; }
        [A2Log criterion:@"[A2-PAIRPIN] step=tap row=start source=%@ engine=%@",
              [A2JITPairingPinSourceCatalog displayNameForMode:modeForThisRow],
              engine ? @"有" : @"★无（面板呈现器/引擎生命周期）★"];
        // ★[PAIRWIRE-FIX]「开始配对」这个按钮本身就是【设备发起档】的流程 ⇒
        //   先把来源档写成该档:否则 refreshPairpin() 里「码行只在设备发起档显示」的条件不成立,
        //   码虽然生成了但用户看不到(真机反馈:点了开始配对看不到 6 位码)。
        if (modeForThisRow != A2JITPairingPinModeDeviceInitiated) {
            [NSUserDefaults.standardUserDefaults setObject:[A2JITPairingPinSourceCatalog defaultIdentifier]
                                                    forKey:A2SelectedPairingPinSourcePrefKey];
            [A2Log criterion:@"[A2-PAIRPIN] step=source 写成 deviceInitiated（否则码行不显示）"];
        }
        // ★[PAIRFIX-ORDER]★ ① 先生成并显示 6 位码 —— 【与引擎可用与否无关】：
        //   码是给用户在设备上输的，先把它生成出来并显示，才不会出现「我想输都输不了」。
        //   原来的顺序是「先查引擎、后生成码」⇒ 引擎一旦不可用就提前 return，既不生成也不显示码，
        //   只报一句「还没显示 6 位码 ⇒ 先选设备发起档」——★那是误报（档早就选好了）★。
        A2JITPairingCodeSession *cs = A2JITPairingCodeSession.sharedSession;
        A2JITPairingCodeSession *persisted = [A2JITPairingCodeSession restoredFromDefaults];
        NSString *shown = cs.code.length > 0 ? cs.code : (persisted.code ?: @"");
        NSError *genErr = nil;
        if (shown.length != 6) {
            [cs beginDeviceInitiatedWithHostName:pairableHostName error:&genErr];
            A2JITPairingCodeSession *again = [A2JITPairingCodeSession restoredFromDefaults];
            shown = cs.code.length > 0 ? cs.code : (again.code ?: @"");
        }
        if (shown.length != 6) {
            // 走到这里说明【已经生成过】了 ⇒ 只剩「生成失败」一种可能：报真实原因（不再报误报）。
            NSString *why = genErr.localizedDescription ?: @"生成器没有给出 6 位码（内部不一致）";
            [A2Log criterion:@"[A2-PAIRPIN] step=gen ★失败★ reason=%@", why];
            [A2Toast show:[NSString stringWithFormat:@"生成配对码失败：%@", why] inView:hvc.view];
            refreshPairpin();
            return;
        }
        [A2Log criterion:@"[A2-PAIRPIN] step=gen 就绪 code=已生成(%lu 位) host=%@",
              (unsigned long)shown.length, pairableHostName];
        refreshPairpin();
        // ★[PAIRWIRE-NOTIFY] 把码同时发一条本地通知✗★ —— 用户切到系统设置里输码时仍能看到它。
        A2PairingNotifyPostCode(shown, pairableHostName);

        // ★[PAIRFIX-ORDER]★ 引擎不可用 = 【程序内部状态】，不是「你没选设备发起档」⇒ 报真实原因；
        //   而且【不】因为这一条就把刚显示出来的码藏起来（码已可复制，用户能先去设备上输）。
        if (engine == nil) {
            [A2Log criterion:@"[A2-PAIRPIN] step=engine ★不可用★（呈现器/引擎生命周期）⇒ 只显示码，不开始配对"];
            [A2Toast show:[A2JITStrings stringForKey:@"jit.pairwire.toast.noengine"] inView:hvc.view];
            return;
        }

        // ★[PAIRWIRE-KEEPALIVE] 保活✗★:用户马上要切到系统设置输码;不保活会被挂起 ⇒ listener 等不到连入。
        A2PairingKeepAliveStart(@"等待设备连入…");
        applyPairwireStage(A2JITDeviceInitiatedPairingStagePreparing, nil);
        [A2Toast show:[A2JITStrings stringForKey:@"jit.pairwire.toast.started"] inView:hvc.view];

        // ②–⑥ ★唯一驱动入口★（★必须在后台队列★：广告等待最长 budget 秒，主线程会卡界面）
        NSString *hostName = NSProcessInfo.processInfo.hostName ?: @"iPhone";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *why = nil;
            NSString *failure = nil;
            BOOL ok = [engine startDeviceInitiatedPairingWithHostName:hostName
                                                        displayedCode:shown
                                                               budget:300.0
                                                         stageHandler:^(A2JITDeviceInitiatedPairingStage stage,
                                                                        NSString *detail) {
                applyPairwireStage(stage, detail);
            }
                                                               reason:&why
                                                          failureName:&failure];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSLog(@"[A2JIT] 设备发起配对结果 ok=%d failure=%@ detail=%@",
                      (int)ok, failure ?: @"-", why ?: @"-");
                UIViewController *h = weakHostVC;
                if (h == nil) { return; }
                if (ok) {
                    [A2Toast show:[A2JITStrings stringForKey:@"jit.pairwire.toast.done"] inView:h.view];
                } else {
                    [A2Toast show:[NSString stringWithFormat:@"%@：%@",
                                   [A2JITStrings stringForKey:@"jit.pairwire.toast.failed"], why ?: @""]
                           inView:h.view];
                }
            });
        });
    };

    pairwireCancelRow.onTap = ^{
        UIViewController *hvc = weakHostVC;
        A2JITAutoPairingEngineBridge *engine = panelEngine;
        if (hvc == nil || engine == nil) { return; }
        [engine cancelDeviceInitiatedPairing];
        [A2Toast show:[A2JITStrings stringForKey:@"jit.pairwire.toast.cancelRequested"] inView:hvc.view];
    };

    presenter.pairpinRow = pairpinRow;
    presenter.paircodeRow = paircodeRow;

    [presenter apply];
    return section;
}

@end
