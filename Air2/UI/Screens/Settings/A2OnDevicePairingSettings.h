//
//  A2OnDevicePairingSettings.h
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  UI —— [A2-PAIR-ONDEVICE] 「诊断 › 设备内配对」分组构建器。
//
//  ★为什么带调试开关★（用户拍板：第一阶段可先用开关控制显示）：
//    设备内配对要有 iOS 27 真机 + 后台保活才可能真的跑起来（docs/STIKPAIR-SPEC.md §5/§7）。
//    在那之前，入口不该出现在所有人的设置页里当「点了没用」的死行
//    （仓内口径见 A2SettingsSection.h 头注释「只放已经有实现的设置项」）。
//  ⇒ 开关默认关；关了之后本分组**只剩开关这一行**，原有设置页一行都不变。
//
//  入口是否「存在」由两件事决定（都在本文件里如实呈现）：
//    ① 调试开关（NSUserDefaults: A2OnDevicePairingEntryEnabled，默认 NO）
//    ② 系统是否 iOS 27+（设备发起档的必要条件；不是就如实写出来，不假装能用）
//

#import <UIKit/UIKit.h>
#import "A2SettingsSection.h"

NS_ASSUME_NONNULL_BEGIN

/// 开关变化通知：设置页收到后重建「诊断」页（入口要么出现、要么消失）。
FOUNDATION_EXPORT NSNotificationName const A2OnDevicePairingEntryDidChangeNotification;

/// 调试开关的持久化键（默认关）。
FOUNDATION_EXPORT NSString *const A2OnDevicePairingEntryEnabledKey;

@interface A2OnDevicePairingSettings : NSObject

/// 「诊断」页里的一个分组：开关行（永远在）+ 入口行/隧道自检行（开关打开才在）。
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host;

/// 调试开关当前值（默认 NO）。
+ (BOOL)isEntryEnabled;

/// 设备发起档的系统门槛（iOS 27+，见 docs/STIKPAIR-SPEC.md §7）。
+ (BOOL)isDeviceInitiatedPairingSupportedOnThisOS;

@end

NS_ASSUME_NONNULL_END
