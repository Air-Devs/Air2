//
//  A2JITSettings.m
//  Air2
//
//  运行环境 › JIT —— ★6 行★（顺序即显示顺序）：
//    ① 状态       只读：就绪 / 未就绪 + 来源（内建 / StikDebug / TrollStore / 越狱）+ 一句原因
//    ② 启动器     单选：内建（StikJIT）｜StikDebug｜自动 —— 写 a2jit.preferredSource
//    ③ 配对文件   已导入 / 未导入（+ 文件名）；点击 = 系统文档选择器 → A2JITPairingFileStore
//    ④ 开发者镜像 已挂载 / 未挂载 / 未知；点击 = 重置 DDI 缓存（A2JITHelperBridge resetDDI）
//    ⑤ 证据       最近一次判据 + 原因（只读；★长按复制日志路径★）
//    ⑥ 诊断日志   开关：JIT / 启动链逐项细节写进 lastlog
//
//  ★本页不判 JIT★（分层：UI 只显示与写偏好）：
//    · 就绪判据 = `A2JITEnabler isJITReadyNowWithReason:`（Natives/Support 的唯一入口，
//      UI 侧只把它的结论与原因原样上屏，不新增任何判定条件）；
//    · 区域取证 = `A2JITEnvironmentProbe`（Bridge → Natives/Support/A2JITEnvironment）；
//    · DDI 三态 = `A2JITLocalDDIProbe`（本地镜像 + 设备侧查询的合成，无法确认就报未知）。
//
//  ★已删除的入口★（含四语文案 key，见 git 历史）：调试暂停 / GL 断点探针 /
//    JIT 启动器总开关（detach）/ 自研 RSD 自动配对（pairwire + pairpin）/ 外部工具多选 /
//    DDI 手动导入与联网获取 / 分级策略 / 下一步动作 / 开启 JIT / 启动链 runtime 开关。
//    删 UI 后变孤儿的类（编排层 / 四路 Provider / 分级表 / 状态机 / 自动配对引擎 Bridge）
//    已一并删除，见交付的 grep 证据（单测里 ⑪ 接线不变量 用负断言守着「不得回流」）。
//
//  文案：A2JITStrings（zh-Hans / zh-Hant / en / ja 四语齐）。
//

#import "A2SettingsSections.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2StikJITProvider.h"   // 内建 JIT：开启 / 下载 DDI
#import "A2Toast.h"
#import "A2OptionSheet.h"
#import "A2Log.h"                  // [JIT-V] / 判据行的统一出口（控制台 + lastlog）
#import "A2JITStrings.h"
#import "A2JITFacts.h"
#import "A2JITLocalFactsSource.h"
#import "A2JITPairingFileStore.h"
#import "A2JITReadinessProbe.h"
#import "A2JITVerdictGuidance.h"
#import "A2JITDDI.h"
#import "A2JITDDIStore.h"
#import "A2JITDDIProbe.h"
#import "A2JITDDIDeviceBridge.h"
#import "A2JITEnabler.h"          // Natives/Support —— 就绪判据 + 日志键约定
#import "A2JITEnvironmentProbe.h" // Bridge —— 真判据（区域取证）
#import "A2JITHelperBridge.h"     // Bridge —— resetDDI（拉起内建 helper appex）

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - 常量 / 纯函数

/// JIT 启动器的偏好键（★写入点唯一 = 本文件★）。
/// 取值是跨层契约：`builtin` / `stikdebug` / `auto` 逐字存进 NSUserDefaults，
/// 由 `Natives/Support/A2JITEnabler.m` 的 `a2jit_preferred_source()` 解析（唯一读取点）。
/// ★改这里的取值必须同时改那边★。
static NSString *const kA2JITLauncherPrefKey = @"a2jit.preferredSource";

/// 诊断日志开关的键。★复用既有实现★：`Natives/Context/a2_launch.m:126` 的
/// `a2_launch_verbose_enabled()` 读的就是这个键（`a2_log_detail` 的 verbose 桶）。
/// 本页只负责写它，并在同一开关下把本页的逐项判定也写成 `[JIT-V]` 行（进 lastlog）。
static NSString *const kA2JITVerboseLogPrefKey = @"debug.rt_p1_verbose";

static NSString *A2JITText(NSString *key) {
    return [A2JITStrings stringForKey:key language:[A2JITStrings languageForSystemLocale]];
}

/// 启动器可选项（★顺序即弹窗顺序★）：{ 取值, 四语文案 key }。
/// 取值串必须与 `a2jit_preferred_source()` 逐字一致（含 `auto` 的缺省口径）。
static NSArray<NSArray<NSString *> *> *A2JITLauncherOptions(void) {
    return @[
        @[ @"builtin",   @"jit.launcher.builtin" ],
        @[ @"stikdebug", @"jit.launcher.stikdebug" ],
        @[ @"auto",      @"jit.launcher.auto" ],
    ];
}

/// 当前生效的取值（缺键 / 空串 ⇒ auto；与 Natives 侧的缺省口径一致）。
static NSString *A2JITCurrentLauncherSource(void) {
    NSString *raw = [NSUserDefaults.standardUserDefaults stringForKey:kA2JITLauncherPrefKey];
    return raw.length > 0 ? raw : @"auto";
}

/// 取值 → 四语文案；★不认识的取值（旧枚举项）回传 known=NO★，
/// 由调用方如实点名「存的是旧取值」，绝不把它显示成「自动」（那会谎报来源）。
static NSString *A2JITLauncherLabelForSource(NSString *source, BOOL *_Nullable knownOut) {
    for (NSArray<NSString *> *opt in A2JITLauncherOptions()) {
        if ([opt[0] isEqualToString:source]) {
            if (knownOut) *knownOut = YES;
            return A2JITText(opt[1]);
        }
    }
    if (knownOut) *knownOut = NO;
    return A2JITText(@"jit.launcher.auto");
}

/// StikDebug 是否可拉起。canOpenURL 属 UIKit（不能写进 Player），
/// scheme 已登记在 Info.plist 的 LSApplicationQueriesSchemes 白名单里。
static BOOL A2JITCanOpenStikDebug(void) {
    NSURL *url = [NSURL URLWithString:@"stikdebug://"];
    return url != nil && [UIApplication.sharedApplication canOpenURL:url];
}

/// 诊断日志开关此刻是否开着（缺键当关）。
static BOOL A2JITVerboseLogEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:kA2JITVerboseLogPrefKey];
}

#pragma mark - 长按手势载体

/// 长按手势的 target 是【非持有】引用（UIGestureRecognizer 不 retain target），
/// 所以必须有人在生命周期内强持有它 —— 由呈现器持有（presenter.longPressTargets）。
@interface A2JITLongPressTarget : NSObject
@property (nonatomic, copy, nullable) void (^handler)(void);
- (void)a2_handleLongPress:(UILongPressGestureRecognizer *)recognizer;
@end

@implementation A2JITLongPressTarget
- (void)a2_handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    if (self.handler) {
        self.handler();
    }
}
@end

#pragma mark - 面板呈现器（行引用 + 动作 + 文案）

@interface A2JITPanelPresenter : NSObject <UIDocumentPickerDelegate>

@property (nonatomic, weak, nullable) UIViewController *host;
@property (nonatomic, strong) A2JITFacts *facts;
@property (nonatomic, strong) A2JITPairingFileStore *store;
@property (nonatomic, strong) A2JITLocalDDIProbe *ddiProbe;
@property (nonatomic, strong, nullable) id<A2JITReadinessProbe> probe;

/// 行（section 持有它们；这里只用弱引用，避免与行内 block 成环）
@property (nonatomic, weak, nullable) A2SettingsRow *statusRow;
@property (nonatomic, weak, nullable) A2SettingsRow *pairingRow;
@property (nonatomic, weak, nullable) A2SettingsRow *ddiRow;
@property (nonatomic, weak, nullable) A2SettingsRow *evidenceRow;

/// 长按手势的 target（手势不持有 target ⇒ 必须有人持有；与 section 同寿）
@property (nonatomic, strong) NSMutableArray<A2JITLongPressTarget *> *longPressTargets;

/// 刷新 ③④⑤（同步、纯读取；就绪判定见 refreshStatus，它在后台跑）。
- (void)apply;
/// 后台判一次「本进程现在能不能建 VM」，回主线程上屏。
- (void)refreshStatus;
/// 起系统文档选择器挑选配对文件。
- (void)presentImportPicker;
/// 重置内建 helper 的 DDI 缓存（真拉起 appex，成败如实上屏）。
- (void)resetDDICache;

@end

@implementation A2JITPanelPresenter

#pragma mark 文案小工具

- (NSString *)text:(NSString *)key {
    return A2JITText(key);
}

/// 当前设置下的【来源】。★这是推断，不是判据★：
/// 顺序与 `A2JITEnabler` 的 auto 解析顺序一致（越狱/巨魔 → 外部工具 → 内建兜底），
/// 目的是让用户一眼知道「现在这条链是谁在给 JIT」，结论本身仍以 ① 的就绪判定为准。
- (NSString *)sourceLabel {
    NSString *pref = A2JITCurrentLauncherSource();
    if ([pref isEqualToString:@"builtin"]) {
        return [self text:@"jit.source.builtin"];
    }
    if ([pref isEqualToString:@"stikdebug"]) {
        return [self text:@"jit.source.stikdebug"];
    }
    if ([pref isEqualToString:@"trollstore"]) {
        return [self text:@"jit.source.trollstore"];
    }
    if ([pref isEqualToString:@"jailbreak"]) {
        return [self text:@"jit.source.jailbreak"];
    }
    // auto（以及 debugger / sidestore 这类旧取值）：按本机形态排到哪条就是哪条。
    if (self.facts.environment == A2JITEnvironmentKindTrollStore) {
        return [self text:@"jit.source.trollstore"];
    }
    if (self.facts.environment == A2JITEnvironmentKindJailbroken) {
        return [self text:@"jit.source.jailbreak"];
    }
    if (A2JITCanOpenStikDebug()) {
        return [self text:@"jit.source.stikdebug"];
    }
    return [self text:@"jit.source.builtin"];
}

#pragma mark 刷新

- (void)apply {
    // ---- ③ 配对文件 ----
    BOOL hasFile = [self.store hasUsablePairingFile];
    self.pairingRow.valueText = [self text:hasFile ? @"jit.pairing.imported" : @"jit.pairing.notImported"];
    if (hasFile) {
        NSDictionary<NSString *, id> *meta = [self.store importedMetadata];
        NSString *name = meta[A2JITPairingFileStoreSourceNameKey];
        if (name.length == 0) {
            name = [self.store importedFilePath].lastPathComponent;
        }
        self.pairingRow.subtitle = name.length > 0
            ? [NSString stringWithFormat:@"%@｜%@", name, [self text:@"jit.pairing.subtitle.ready"]]
            : [self text:@"jit.pairing.subtitle.ready"];
    } else {
        self.pairingRow.subtitle = [self text:@"jit.pairing.subtitle.needFile"];
    }

    // ---- ④ 开发者镜像 ----
    [self applyDDIRow];

    // ---- ⑤ 证据（最近一次判据 + 原因；只读）----
    A2JITReadinessVerdict verdict = self.probe ? [self.probe lastVerdict] : A2JITReadinessVerdictUnknown;
    NSString *evidence = self.probe ? [self.probe lastEvidence] : nil;
    self.evidenceRow.valueText = [self text:[A2JITVerdictGuidance reasonKeyForVerdict:verdict]];
    self.evidenceRow.subtitle = [NSString stringWithFormat:@"%@｜%@｜%@",
                                 [A2JITVerdictGuidance displayNameForVerdict:verdict],
                                 evidence.length > 0 ? evidence : [self text:@"jit.evidence.none"],
                                 [self text:@"jit.evidence.hint"]];

    [self logVerboseDetailWithVerdict:verdict evidence:evidence];
}

/// ④ 三态：只有「本地有一份通过校验的镜像」才算已挂载；目录不可读 ⇒ 未知（不报缺失）。
- (void)applyDDIRow {
    A2JITDDIStatus *status = [self.ddiProbe ddiStatus];
    NSString *stateKey = @"jit.ddi.state.unknown";
    NSString *detail = [self text:@"jit.ddi.subtitle.unknown"];
    switch (status.verdict) {
        case A2JITDDIVerdictPresent: {
            stateKey = @"jit.ddi.state.mounted";
            NSString *name = status.imagePath.lastPathComponent;
            detail = [NSString stringWithFormat:[self text:@"jit.ddi.subtitle.mirror"],
                      name.length > 0 ? name : @"DDI"];
            break;
        }
        case A2JITDDIVerdictMissing:
        case A2JITDDIVerdictVersionMismatch:
        case A2JITDDIVerdictStale:
            stateKey = @"jit.ddi.state.notMounted";
            detail = [self text:@"jit.ddi.subtitle.none"];
            break;
        case A2JITDDIVerdictUnknown:
            break;
    }
    self.ddiRow.valueText = [self text:stateKey];
    self.ddiRow.subtitle = detail;
}

/// ① 就绪判定放后台：判据要读调试器/区域状态（iOS 26+ 上还可能发一发 brk），
/// 绝不能在主线程把界面卡住。回主线程只做「上屏」。
- (void)refreshStatus {
    A2SettingsRow *row = self.statusRow;
    if (row == nil) {
        return;
    }
    row.valueText = [self text:@"jit.status.pending"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *why = nil;
        BOOL ready = [A2JITEnabler isJITReadyNowWithReason:&why];
        dispatch_async(dispatch_get_main_queue(), ^{
            A2JITPanelPresenter *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.statusRow == nil) {
                return;
            }
            NSString *source = [strongSelf sourceLabel];
            NSString *sourceLine = [NSString stringWithFormat:
                                    [strongSelf text:@"jit.status.sourceFormat"], source];
            strongSelf.statusRow.valueText = [strongSelf text:ready ? @"jit.status.ready"
                                                                 : @"jit.status.notReady"];
            strongSelf.statusRow.subtitle = why.length > 0
                ? [NSString stringWithFormat:@"%@｜%@", sourceLine, why]
                : sourceLine;
            [A2Log criterion:@"[JIT-V] 状态: ready=%d source=%@ reason=%@",
             (int)ready, source, why ?: @"—"];
        });
    });
}

#pragma mark 诊断日志（复用 debug.rt_p1_verbose）

/// 开关开着时，把本页每一行的判定依据写成 `[JIT-V]` 行（[A2Log criterion:] ⇒ 控制台 + lastlog）。
/// 关着（默认）⇒ 一行都不写（正常使用安静）。
- (void)logVerboseDetailWithVerdict:(A2JITReadinessVerdict)verdict evidence:(nullable NSString *)evidence {
    if (!A2JITVerboseLogEnabled()) {
        return;
    }
    NSDictionary<NSString *, id> *meta = [self.store importedMetadata];
    A2JITDDIStatus *ddi = [self.ddiProbe ddiStatus];
    [A2Log criterion:@"[JIT-V] 配对文件: usable=%d path=%@ source=%@",
     (int)[self.store hasUsablePairingFile], [self.store importedFilePath] ?: @"—",
     meta[A2JITPairingFileStoreSourceNameKey] ?: @"—"];
    [A2Log criterion:@"[JIT-V] DDI: verdict=%@ evidence=%@",
     [A2JITDDI displayNameForVerdict:ddi.verdict], ddi.evidence ?: @"—"];
    [A2Log criterion:@"[JIT-V] 判据: verdict=%@ 取证=%@",
     [A2JITVerdictGuidance displayNameForVerdict:verdict], evidence ?: @"—"];
}

#pragma mark 导入配对文件

- (void)presentImportPicker {
    UIViewController *host = self.host;
    if (host == nil) {
        return;
    }
    // asCopy:YES ⇒ 系统先把文件拷进本 App 的临时目录，省掉 security-scoped 的长时间持有。
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeData, UTTypePropertyList ]
                                                                  asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [host presentViewController:picker animated:YES completion:nil];
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
    NSString *path = data.length > 0
        ? [self.store importData:data sourceName:url.lastPathComponent error:&importErr]
        : nil;
    if (path == nil) {
        NSString *why = importErr.localizedDescription ?: readErr.localizedDescription ?: @"未知原因";
        NSLog(@"[A2JIT] 导入失败 url=%@ reason=%@", url.absoluteString, why);
        [A2Log criterion:@"[JIT-V] 导入失败: %@", why];
        [A2Toast show:[NSString stringWithFormat:@"%@：%@", [self text:@"jit.toast.importFail"], why]
               inView:host.view];
        return;
    }
    NSLog(@"[A2JIT] 导入成功 path=%@", path);
    [A2Toast show:[self text:@"jit.toast.importOK"] inView:host.view];
    [self apply];
}

#pragma mark 重置 DDI 缓存

- (void)resetDDICache {
    UIViewController *host = self.host;
    // 判据先于动作：helper 不可用（低版本 / LiveContainer / 扩展 API 不在）就如实说，不假成功。
    NSString *unavailable = [A2JITHelperBridge unavailableReason];
    if (unavailable.length > 0) {
        [A2Toast show:[NSString stringWithFormat:[self text:@"jit.toast.ddiResetUnavailable"], unavailable]
               inView:host.view];
        [A2Log criterion:@"[JIT-V] 重置 DDI 缓存: 不可用（%@）", unavailable];
        return;
    }
    NSError *requestErr = nil;
    NSData *request = [A2JITHelperBridge requestDataWithOperation:A2JITHelperOperationResetDDI
                                                        targetPID:0
                                                      pairingData:nil
                                                     scriptBase64:nil
                                                          rsdPort:nil
                                                     deviceAddress:@"10.7.0.1"
                                                            error:&requestErr];
    if (request == nil) {
        [A2Toast show:[self text:@"jit.toast.ddiResetFail"] inView:host.view];
        [A2Log criterion:@"[JIT-V] 重置 DDI 缓存: 请求编不出来（%@）",
         requestErr.localizedDescription ?: @"—"];
        return;
    }
    [A2Toast show:[self text:@"jit.toast.ddiResetting"] inView:host.view];

    __weak typeof(self) weakSelf = self;
    BOOL started = [A2JITHelperBridge startWithRequestData:request
                                                completion:^(NSDictionary<NSString *, id> *_Nullable response,
                                                             NSError *_Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            A2JITPanelPresenter *strongSelf = weakSelf;
            UIViewController *hvc = strongSelf.host;
            if (strongSelf == nil || hvc == nil) {
                return;
            }
            BOOL ok = (error == nil) && [response[A2JITHelperResponseSuccessKey] boolValue];
            NSString *detail = error.localizedDescription
                ?: (response[A2JITHelperResponseMessageKey] ?: @"");
            [A2Log criterion:@"[JIT-V] 重置 DDI 缓存结果 ok=%d detail=%@", (int)ok, detail];
            NSString *head = [strongSelf text:ok ? @"jit.toast.ddiResetOK" : @"jit.toast.ddiResetFail"];
            NSString *message = detail.length > 0
                ? [NSString stringWithFormat:@"%@：%@", head, detail] : head;
            [A2Toast show:message inView:hvc.view];
            [strongSelf apply];
        });
    }];
    if (!started) {
        [A2Toast show:[self text:@"jit.toast.ddiResetFail"] inView:host.view];
        [A2Log criterion:@"[JIT-V] 重置 DDI 缓存: 拉起 appex 失败（start 返回 NO）"];
    }
}

@end

#pragma mark - 面板

@implementation A2JITSettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    // ---- 装配（★只在此处发生★）----
    A2JITFacts *facts = [A2JITFacts factsWithSource:[[A2JITLocalFactsSource alloc] init]];
    A2JITPairingFileStore *store = [A2JITPairingFileStore defaultStore];
    // ★判据内核★：Bridge → Natives/Support/A2JITEnvironment（真发 brk #0x69 + 区域取证）。
    A2JITEnvironmentProbe *probe = [[A2JITEnvironmentProbe alloc] init];

    // DDI：本地镜像存储 + 设备侧查询（Bridge 骨架，未接线就如实回 Unknown）+ 系统要求。
    A2JITDDIStore *ddiStore = [A2JITDDIStore defaultStore];
    A2JITDDIDeviceBridge *ddiDevice = [[A2JITDDIDeviceBridge alloc] init];
    NSString *osBuild = [A2JITDDI buildFromOperatingSystemVersionString:
                         NSProcessInfo.processInfo.operatingSystemVersionString];
    A2JITDDIRequirement *ddiRequirement =
        [A2JITDDIRequirement requirementWithOSMajorVersion:facts.osMajorVersion
                                             minorVersion:facts.osMinorVersion
                                                    build:osBuild];
    A2JITLocalDDIProbe *ddiProbe = [[A2JITLocalDDIProbe alloc] initWithStore:ddiStore
                                                                requirement:ddiRequirement
                                                                deviceQuery:ddiDevice];

    A2JITPanelPresenter *presenter = [[A2JITPanelPresenter alloc] init];
    presenter.host = host;
    presenter.facts = facts;
    presenter.store = store;
    presenter.ddiProbe = ddiProbe;
    presenter.probe = probe;
    presenter.longPressTargets = [NSMutableArray array];

    A2SettingsSection *section =
        [[A2SettingsSection alloc] initWithTitle:[A2JITStrings stringForKey:@"jit.section.title"]];
    section.footerText = [A2JITStrings stringForKey:@"jit.section.footer"];

    // ---- ① 状态（只读）----
    A2SettingsRow *statusRow = [[A2SettingsRow alloc] init];
    statusRow.symbolName = @"bolt.horizontal.circle.fill";
    statusRow.title = [A2JITStrings stringForKey:@"jit.row.status"];
    statusRow.valueText = [A2JITStrings stringForKey:@"jit.status.pending"];
    [section addRow:statusRow];

    // ---- ② 启动器（单选）----
    A2SettingsRow *launcherRow = [[A2SettingsRow alloc] init];
    launcherRow.symbolName = @"arrow.up.forward.app.fill";
    launcherRow.title = [A2JITStrings stringForKey:@"jit.row.launcher"];
    launcherRow.accessory = A2SettingsRowAccessoryDisclosure;
    [section addRow:launcherRow];

    // ---- ③ 配对文件 ----
    A2SettingsRow *pairingRow = [[A2SettingsRow alloc] init];
    pairingRow.symbolName = @"doc.badge.plus";
    pairingRow.title = [A2JITStrings stringForKey:@"jit.row.pairing"];
    pairingRow.accessory = A2SettingsRowAccessoryDisclosure;
    [section addRow:pairingRow];

    // ---- ④ 开发者镜像 ----
    // ---- ③b 开启 JIT（动作行）----
    A2SettingsRow *enableRow = [[A2SettingsRow alloc] init];
    enableRow.symbolName = @"bolt.fill";
    enableRow.title = [A2JITStrings stringForKey:@"jit.row.enable"];
    enableRow.subtitle = [A2JITStrings stringForKey:@"jit.row.enable.subtitle"];
    enableRow.accessory = A2SettingsRowAccessoryDisclosure;
    [section addRow:enableRow];

    A2SettingsRow *ddiRow = [[A2SettingsRow alloc] init];
    ddiRow.symbolName = @"externaldrive.fill";
    ddiRow.title = [A2JITStrings stringForKey:@"jit.row.ddi"];
    ddiRow.accessory = A2SettingsRowAccessoryDisclosure;
    [section addRow:ddiRow];

    // ---- ⑤ 证据（只读；长按复制日志路径）----
    A2SettingsRow *evidenceRow = [[A2SettingsRow alloc] init];
    evidenceRow.symbolName = @"doc.text.magnifyingglass";
    evidenceRow.title = [A2JITStrings stringForKey:@"jit.row.evidence"];
    [section addRow:evidenceRow];

    // ---- ⑥ 诊断日志（开关）----
    BOOL verboseOn = A2JITVerboseLogEnabled();
    A2SettingsRow *diagRow = [[A2SettingsRow alloc] init];
    diagRow.symbolName = @"text.alignleft";
    diagRow.title = [A2JITStrings stringForKey:@"jit.row.diaglog"];
    diagRow.subtitle = [A2JITStrings stringForKey:@"jit.diaglog.subtitle"];
    diagRow.accessory = A2SettingsRowAccessorySwitch;
    diagRow.on = verboseOn;
    [section addRow:diagRow];
    diagRow.onToggle = ^(BOOL isOn) {
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:kA2JITVerboseLogPrefKey];
        [NSUserDefaults.standardUserDefaults synchronize];
        [A2Log criterion:@"[JIT-V] 诊断日志 → %@（键 %@；verbose 桶，写进 lastlog）",
         isOn ? @"开" : @"关", kA2JITVerboseLogPrefKey];
        UIViewController *hvc = host;
        if (hvc != nil) {
            [A2Toast show:A2JITText(isOn ? @"jit.toast.diaglogOn" : @"jit.toast.diaglogOff")
                   inView:hvc.view];
        }
    };

    presenter.statusRow = statusRow;
    presenter.pairingRow = pairingRow;
    presenter.ddiRow = ddiRow;
    presenter.evidenceRow = evidenceRow;

    // ★为什么行内 block 强持有 presenter★：presenter 只在本方法是栈上局部变量，
    //   捕 __weak 的话方法一返回它就没了 ⇒ 行点了没有任何反应（真机踩过）。
    //   presenter 对行只持 weak（见上面的行声明）⇒ 不成环，寿命 = section。
    A2JITPanelPresenter *panelPresenter = presenter;

    // ② 启动器：值一变就刷新本行；生效点是「下次启动游戏」（判据在 Natives 那一处）。
    __weak A2SettingsRow *weakLauncherRow = launcherRow;
    void (^refreshLauncherRow)(void) = ^{
        A2SettingsRow *row = weakLauncherRow;
        if (row == nil) {
            return;
        }
        NSString *current = A2JITCurrentLauncherSource();
        BOOL known = YES;
        NSString *label = A2JITLauncherLabelForSource(current, &known);
        row.valueText = label;
        row.subtitle = known
            ? A2JITText(@"jit.launcher.subtitle")
            : [NSString stringWithFormat:A2JITText(@"jit.launcher.legacy"), current];
    };
    refreshLauncherRow();

    launcherRow.onTap = ^{
        UIViewController *hvc = panelPresenter.host;
        if (hvc == nil) {
            return;
        }
        NSString *current = A2JITCurrentLauncherSource();
        A2OptionSheet *sheet =
            [A2OptionSheet sheetWithTitle:A2JITText(@"jit.row.launcher")
                                  message:A2JITText(@"jit.launcher.subtitle")];
        for (NSArray<NSString *> *opt in A2JITLauncherOptions()) {
            NSString *value = opt[0];
            NSString *label = A2JITText(opt[1]);
            [sheet addOptionWithTitle:label
                             selected:[value isEqualToString:current]
                          destructive:NO
                              handler:^{
                // ★写入点唯一★：键 = kA2JITLauncherPrefKey，值 = 三个契约串之一。
                [NSUserDefaults.standardUserDefaults setObject:value forKey:kA2JITLauncherPrefKey];
                [NSUserDefaults.standardUserDefaults synchronize];
                [A2Log criterion:@"[JIT-SRC] settings: JIT 启动器 → %@（键 %@；下次启动游戏生效）",
                 value, kA2JITLauncherPrefKey];
                refreshLauncherRow();
                [A2Toast show:[NSString stringWithFormat:A2JITText(@"jit.launcher.toast.selected"), label]
                       inView:hvc.view];
            }];
        }
        [sheet presentFrom:hvc];
    };

    // ③ 配对文件：点击 = 导入（系统文档选择器）。
    pairingRow.onTap = ^{
        [panelPresenter presentImportPicker];
    };

    // ③b 开启 JIT：真的去拉起扩展进程 attach 本 App（后台执行，回主线程反馈）
    enableRow.onTap = ^{
        UIViewController *hvc = panelPresenter.host;
        if (hvc != nil) { [A2Toast show:A2JITText(@"jit.toast.enabling") inView:hvc.view]; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            __block NSString *why = nil;
            __block BOOL ok = NO;
            @autoreleasepool {
                ok = [A2StikJITProvider enableBuiltInJITWithBudget:60.0 reason:&why];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *v = panelPresenter.host;
                if (v == nil) return;
                if (ok) {
                    [A2Toast show:A2JITText(@"jit.toast.enableOK") inView:v.view];
                } else {
                    [A2Toast show:[NSString stringWithFormat:@"%@：%@",
                                    A2JITText(@"jit.toast.enableFail"), why ?: @"—"]
                           inView:v.view];
                }
                [panelPresenter apply];
            });
        });
    };

    // ④ 开发者镜像：点击 = 下载/挂载 DDI（helper 里的 StikJIT.prepareDevice）。
    //    已就绪时再次点击 = 重置缓存并重新准备。
    ddiRow.onTap = ^{
        UIViewController *hvc = panelPresenter.host;
        if (hvc != nil) { [A2Toast show:A2JITText(@"jit.toast.ddiWorking") inView:hvc.view]; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            __block NSString *why = nil;
            __block BOOL ok = NO;
            @autoreleasepool {
                ok = [A2StikJITProvider prepareDDIWithBudget:180.0 reason:&why];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *v = panelPresenter.host;
                if (v == nil) return;
                [A2Toast show:ok ? A2JITText(@"jit.toast.ddiOK")
                                 : [NSString stringWithFormat:@"%@：%@", A2JITText(@"jit.toast.enableFail"), why ?: @"—"]
                       inView:v.view];
                [panelPresenter apply];
            });
        });
    };

    // ⑤ 证据：长按复制日志路径（写剪贴板 + Toast）。
    A2JITLongPressTarget *copyTarget = [[A2JITLongPressTarget alloc] init];
    copyTarget.handler = ^{
        NSString *path = [A2Log currentLogPath];
        if (path.length == 0) {
            return;
        }
        UIPasteboard.generalPasteboard.string = path;
        UIViewController *hvc = panelPresenter.host;
        if (hvc != nil) {
            [A2Toast show:[NSString stringWithFormat:@"%@\n%@", A2JITText(@"jit.evidence.copied"), path]
                   inView:hvc.view];
        }
        [A2Log criterion:@"[JIT-V] 证据: 复制日志路径 %@", path];
    };
    [presenter.longPressTargets addObject:copyTarget];
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:copyTarget
                                                      action:@selector(a2_handleLongPress:)];
    longPress.minimumPressDuration = 0.6;
    [evidenceRow addGestureRecognizer:longPress];

    // 首屏刷新 + 后台判一次就绪。
    [presenter apply];
    [presenter refreshStatus];
    return section;
}

@end
