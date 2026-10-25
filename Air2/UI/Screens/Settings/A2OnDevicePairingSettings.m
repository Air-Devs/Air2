//
//  A2OnDevicePairingSettings.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  「诊断 › 设备内配对」分组（口径见头文件）。
//
//  本文件只做三件事：
//    ① 渲染调试开关 + 入口行（入口行 → A2OnDevicePairingViewController）；
//    ② 如实写出系统门槛（iOS 27+）与当前状态（从 A2JITPairingCodeSession 读，不自己造）；
//    ③ 隧道自检入口（→ Bridge 的 A2TLSPskTunnelBridge，★后台跑，不卡界面★）。
//

#import "A2OnDevicePairingSettings.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2OnDevicePairingViewController.h"
#import "A2Toast.h"
#import "A2Log.h"
#import "A2JITPairingCodeSession.h"
#import "A2TLSPskTunnelBridge.h"

NSNotificationName const A2OnDevicePairingEntryDidChangeNotification =
    @"A2OnDevicePairingEntryDidChangeNotification";
NSString *const A2OnDevicePairingEntryEnabledKey = @"A2OnDevicePairingEntryEnabled";

@implementation A2OnDevicePairingSettings

+ (BOOL)isEntryEnabled {
    // ★默认关★：没写过键 ⇒ NO（诊断页保持原样）。
    return [NSUserDefaults.standardUserDefaults boolForKey:A2OnDevicePairingEntryEnabledKey];
}

+ (BOOL)isDeviceInitiatedPairingSupportedOnThisOS {
    // 规格 §7：设备内生成配对文件需要 iOS 27+。用 NSProcessInfo 的主版本号判断（不猜）。
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
}

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"设备内配对（调试）"];

    BOOL enabled = [self isEntryEnabled];
    BOOL osOK = [self isDeviceInitiatedPairingSupportedOnThisOS];
    NSInteger osMajor = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;

    // ---- 行 ①：调试开关（永远在；关掉后本分组只剩它）----
    A2SettingsRow *switchRow = [[A2SettingsRow alloc] init];
    switchRow.symbolName = @"wrench.and.screwdriver";
    switchRow.title = @"显示「设备内配对」入口";
    switchRow.subtitle = enabled
        ? @"入口已显示在下方（本开关只影响这一个入口，不改其它设置）"
        : @"默认关闭；打开后在下方出现入口（用于 iOS 27 真机验证）";
    switchRow.accessory = A2SettingsRowAccessorySwitch;
    switchRow.on = enabled;
    switchRow.onToggle = ^(BOOL isOn) {
        [NSUserDefaults.standardUserDefaults setBool:isOn
                                              forKey:A2OnDevicePairingEntryEnabledKey];
        [A2Log log:@"[A2-PAIRUI] 设备内配对入口 → %@", isOn ? @"显示" : @"隐藏"];
        // 让设置页重建诊断分组（入口要么出现、要么消失；不留死行）。
        [NSNotificationCenter.defaultCenter postNotificationName:A2OnDevicePairingEntryDidChangeNotification
                                                          object:nil];
    };
    [section addRow:switchRow];

    if (!enabled) {
        section.footerText =
            @"设备内配对需要有 iOS 27 真机才能走通（docs/STIKPAIR-SPEC.md §7）。"
            @"开关关闭时本分组不显示任何入口，其它设置不受影响。";
        return section;
    }

    // ---- 行 ②：入口（→ 详情页：码 + 状态）----
    A2JITPairingCodeSession *live = A2JITPairingCodeSession.sharedSession;
    A2JITPairingCodeSession *persisted = [A2JITPairingCodeSession restoredFromDefaults];
    NSString *code = live.code.length > 0 ? live.code : (persisted.code ?: @"");
    A2JITPairingCodeState state = live.code.length > 0 ? live.state
                                                      : (persisted ? persisted.state
                                                                   : A2JITPairingCodeStateIdle);

    A2SettingsRow *entryRow = [[A2SettingsRow alloc] init];
    entryRow.symbolName = @"iphone.and.arrow.forward";
    entryRow.title = @"设备内配对";
    entryRow.valueText = code.length ? code : @"未开始";
    entryRow.accessory = A2SettingsRowAccessoryDisclosure;
    entryRow.subtitle = osOK
        ? [NSString stringWithFormat:@"状态：%@｜本机发起配对并生成配对文件",
           [A2JITPairingCodeSession stateName:state]]
        : [NSString stringWithFormat:@"状态：%@｜★本机 iOS %ld，设备发起档需 iOS 27+（此入口可看码，连入需真机）★",
           [A2JITPairingCodeSession stateName:state], (long) osMajor];
    __weak UIViewController *weakHost = host;
    entryRow.onTap = ^{
        UIViewController *hvc = weakHost;
        if (hvc == nil) { return; }
        A2OnDevicePairingViewController *vc = [[A2OnDevicePairingViewController alloc] init];
        [hvc.navigationController pushViewController:vc animated:YES];
    };
    [section addRow:entryRow];

    // ---- 行 ③：隧道自检（回环真握手；不连外网）----
    A2SettingsRow *selfTestRow = [[A2SettingsRow alloc] init];
    selfTestRow.symbolName = @"lock.shield";
    selfTestRow.title = @"TLS-PSK 隧道自检";
    selfTestRow.subtitle = [NSString stringWithFormat:@"%@｜%@",
                            [A2TLSPskTunnelBridge statusLine],
                            [A2TLSPskTunnelBridge lastSelfTestSummary]];
    selfTestRow.accessory = A2SettingsRowAccessoryDisclosure;
    selfTestRow.onTap = ^{
        UIViewController *hvc = weakHost;
        [A2Toast show:@"正在回环握手…" inView:hvc.view];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [A2TLSPskTunnelBridge runSelfTestCriterionLine];
            BOOL passed = [A2TLSPskTunnelBridge lastSelfTestPassed];
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *v = weakHost;
                if (v) {
                    [A2Toast show:[NSString stringWithFormat:@"隧道自检%@", passed ? @"通过" : @"未通过"]
                           inView:v.view];
                }
                // 让分组重建以显示最新结论（不猜：结论从 Bridge 再读一遍）。
                [NSNotificationCenter.defaultCenter postNotificationName:A2OnDevicePairingEntryDidChangeNotification
                                                                  object:nil];
            });
        });
    };
    [section addRow:selfTestRow];

    section.footerText =
        @"设备内配对：本机起可配对主机广告 + 6 位码，用户在设备「设置 › 隐私与安全性 › "
        @"开发者模式 › 与 <主机名> 配对」输码。★当前只到「生成码 + 显示状态」★："
        @"mDNS 广告与 responder 传输仍是 A2JITPairingCodeSession.h:20-28 记的那个「唯一改点」。";
    return section;
}

@end
