//
//  A2OnDevicePairingViewController.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  「设备内配对」页（口径与边界见头文件）。
//
//  页面组成（全部读自 Player 的状态机 / Bridge 的隧道状态，页面本身无业务逻辑）：
//    · 配对码分组：状态 / 主机名 / 6 位码（★大字号等宽，用户要切到系统设置去输★）
//    · 操作分组  ：开始配对（生成码）/ 复制码 / 结束并作废
//    · 隧道分组  ：后端与开关的如实状态行 / 「运行自检」（回环真握手）
//
//  ★码不写日志★：判据行由 A2JITPairingCodeSession 自己打（[A2-PAIRPIN]），本页只显示。
//

#import "A2OnDevicePairingViewController.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Log.h"
#import "A2JITPairingCodeSession.h"
#import "A2TLSPskTunnelBridge.h"

@interface A2OnDevicePairingViewController ()
@property (nonatomic, strong) A2SettingsRow *stateRow;
@property (nonatomic, strong) A2SettingsRow *hostRow;
@property (nonatomic, strong) A2SettingsRow *codeRow;
@property (nonatomic, strong) A2SettingsRow *tunnelRow;
@property (nonatomic, strong) A2SettingsRow *selfTestRow;
@end

@implementation A2OnDevicePairingViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"设备内配对";

    // ---- 分组 ①：配对码与状态（只读状态机）----
    A2SettingsSection *codeSection = [[A2SettingsSection alloc] initWithTitle:@"配对码"];
    _stateRow = [[A2SettingsRow alloc] init];
    _stateRow.symbolName = @"wave.3.right";
    _stateRow.title = @"状态";
    _stateRow.accessory = A2SettingsRowAccessoryNone;
    [codeSection addRow:_stateRow];

    _hostRow = [[A2SettingsRow alloc] init];
    _hostRow.symbolName = @"desktopcomputer";
    _hostRow.title = @"主机名（设备列表里显示这个）";
    _hostRow.accessory = A2SettingsRowAccessoryNone;
    [codeSection addRow:_hostRow];

    _codeRow = [[A2SettingsRow alloc] init];
    _codeRow.symbolName = @"number.square";
    _codeRow.title = @"配对码";
    _codeRow.accessory = A2SettingsRowAccessoryNone;
    [codeSection addRow:_codeRow];
    codeSection.footerText =
        @"设备上打开：设置 › 隐私与安全性 › 开发者模式 › 与 <主机名> 配对，输入上面这 6 位码。"
        @"码只在本次配对内有效；点「结束并作废」后立刻失效。";
    [self addSection:codeSection];

    // ---- 分组 ②：操作 ----
    A2SettingsSection *actionSection = [[A2SettingsSection alloc] initWithTitle:@"操作"];
    __weak typeof(self) weakSelf = self;
    A2SettingsRow *startRow = [[A2SettingsRow alloc] init];
    startRow.symbolName = @"play.circle";
    startRow.title = @"开始配对（生成配对码）";
    startRow.subtitle = @"生成新的 6 位码并开始等待设备连入";
    startRow.accessory = A2SettingsRowAccessoryDisclosure;
    startRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self startPairing];
    };
    [actionSection addRow:startRow];

    A2SettingsRow *copyRow = [[A2SettingsRow alloc] init];
    copyRow.symbolName = @"doc.on.doc";
    copyRow.title = @"复制配对码";
    copyRow.accessory = A2SettingsRowAccessoryNone;
    copyRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self copyCode];
    };
    [actionSection addRow:copyRow];

    A2SettingsRow *endRow = [[A2SettingsRow alloc] init];
    endRow.symbolName = @"xmark.circle";
    endRow.title = @"结束并作废";
    endRow.subtitle = @"清掉屏幕上的码（作废后必须重新开始，旧码不可再用）";
    endRow.accessory = A2SettingsRowAccessoryNone;
    endRow.destructive = YES;
    endRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [A2JITPairingCodeSession.sharedSession endPairing];
        [self refresh];
    };
    [actionSection addRow:endRow];
    [self addSection:actionSection];

    // ---- 分组 ③：TLS-PSK 隧道（配对之后连 RSD 用）----
    A2SettingsSection *tunnelSection = [[A2SettingsSection alloc] initWithTitle:@"隧道（TLS-PSK）"];
    _tunnelRow = [[A2SettingsRow alloc] init];
    _tunnelRow.symbolName = @"lock.shield";
    _tunnelRow.title = @"隧道后端";
    _tunnelRow.accessory = A2SettingsRowAccessoryNone;
    [tunnelSection addRow:_tunnelRow];

    _selfTestRow = [[A2SettingsRow alloc] init];
    _selfTestRow.symbolName = @"checkmark.seal";
    _selfTestRow.title = @"运行自检（回环真握手）";
    _selfTestRow.accessory = A2SettingsRowAccessoryDisclosure;
    _selfTestRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self runTunnelSelfTest];
    };
    [tunnelSection addRow:_selfTestRow];
    tunnelSection.footerText =
        @"自检在本机 127.0.0.1 起一个 PSK 服务端，用同一条生产路径握手并回显一帧。"
        @"通过 ⇒ 隧道本体（TLS 1.2 / 0x00AF、0x008C）可用；不通过 ⇒ 原因写在这一行。"
        @"★设备侧是否接受我们发的 PSK identity 只能用真机验，本页不代替那一步★。";
    [self addSection:tunnelSection];

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    [self refresh];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

#pragma mark - 刷新

/// 每次刷新都从「持久化 + 单例」两侧取（用户切到系统设置再回来，码必须还在）。
- (void)refresh {
    A2JITPairingCodeSession *live = A2JITPairingCodeSession.sharedSession;
    A2JITPairingCodeSession *persisted = [A2JITPairingCodeSession restoredFromDefaults];
    NSString *code = live.code.length > 0 ? live.code : (persisted.code ?: @"");
    NSString *host = live.hostName.length > 0 ? live.hostName : (persisted.hostName ?: @"");
    A2JITPairingCodeState state = live.code.length > 0 ? live.state
                                                      : (persisted ? persisted.state
                                                                   : A2JITPairingCodeStateIdle);
    NSString *detail = live.lastDetail ?: persisted.lastDetail;

    _stateRow.valueText = [self stateTextFor:state];
    _stateRow.subtitle = detail.length ? detail : @"点「开始配对」生成码";
    _hostRow.valueText = host.length ? host : @"（未开始）";
    // ★6 位码：进 valueText 用大字号（行内右侧），空的时候如实写「—」★
    _codeRow.valueText = code.length ? code : @"—";
    _codeRow.subtitle = code.length
        ? @"★输码期间不要点「结束并作废」★"
        : @"还没有有效的码";

    NSString *tunnelStatus = [A2TLSPskTunnelBridge statusLine];
    _tunnelRow.valueText = [A2TLSPskTunnelBridge lastSelfTestPassed] ? @"可用" : @"";
    _tunnelRow.subtitle = tunnelStatus;
    _selfTestRow.subtitle = [A2TLSPskTunnelBridge lastSelfTestSummary];

    [A2Log log:@"[A2-PAIRUI] 刷新 state=%@ code=%@ tunnel=%@",
          [A2JITPairingCodeSession stateName:state],
          code.length ? @"(有)" : @"(无)", tunnelStatus];
}

/// 状态 → 用户能读的中文（同时保留状态机的英文名，便于对照日志）。
- (NSString *)stateTextFor:(A2JITPairingCodeState)state {
    NSString *name = [A2JITPairingCodeSession stateName:state];
    NSString *zh = nil;
    switch (state) {
        case A2JITPairingCodeStateIdle:        zh = @"未开始"; break;
        case A2JITPairingCodeStateAdvertising: zh = @"等待设备连入"; break;
        case A2JITPairingCodeStateConnected:   zh = @"设备已连入"; break;
        case A2JITPairingCodeStateVerifying:   zh = @"正在验码"; break;
        case A2JITPairingCodeStateSucceeded:   zh = @"配对成功"; break;
        case A2JITPairingCodeStateFailed:      zh = @"失败"; break;
    }
    return [NSString stringWithFormat:@"%@（%@）", zh ?: @"未知", name];
}

#pragma mark - 动作

- (void)startPairing {
    NSString *hostName = [NSString stringWithFormat:@"Air2 (%@)",
                          NSProcessInfo.processInfo.hostName ?: @"iPhone"];
    NSError *error = nil;
    if (![A2JITPairingCodeSession.sharedSession beginDeviceInitiatedWithHostName:hostName
                                                                         error:&error]) {
        [A2Toast show:(error.localizedDescription ?: @"生成配对码失败") inView:self.view];
        return;
    }
    [self refresh];
    // ★不谎报「已连上设备」★：这一步只到「已生成码 + 等设备连入」。
    [A2Toast show:[NSString stringWithFormat:@"已生成配对码，去设备设置里与 %@ 配对", hostName]
           inView:self.view];
}

- (void)copyCode {
    A2JITPairingCodeSession *live = A2JITPairingCodeSession.sharedSession;
    NSString *code = live.code.length > 0 ? live.code
                                          : ([A2JITPairingCodeSession restoredFromDefaults].code ?: @"");
    if (code.length == 0) {
        [A2Toast show:@"还没有有效的配对码" inView:self.view];
        return;
    }
    UIPasteboard.generalPasteboard.string = code;
    [A2Toast show:@"配对码已复制" inView:self.view];
}

/// 自检要真跑一次 TLS 握手（几百毫秒到 8 秒）⇒ ★后台队列★，回来再刷新 UI。
- (void)runTunnelSelfTest {
    _selfTestRow.subtitle = @"正在自检（回环握手）…";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *line = [A2TLSPskTunnelBridge runSelfTestCriterionLine];
        BOOL passed = [A2TLSPskTunnelBridge lastSelfTestPassed];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil) { return; }
            [self refresh];
            [A2Toast show:[NSString stringWithFormat:@"隧道自检%@", passed ? @"通过" : @"未通过"]
                   inView:self.view];
            [A2Log criterion:@"[A2-PAIRUI] 自检结果 %@", line];
        });
    });
}

#pragma mark - 主题

- (void)applyTheme {
    // 行内的颜色由 A2SettingsRow / A2SettingsSection 自己按主题画；
    // 本页没有自绘文字，所以这里只需把主题变化通知接住（保持与其它页一致）。
}

@end
