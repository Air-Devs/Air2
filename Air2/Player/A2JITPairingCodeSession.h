//
//  A2JITPairingCodeSession.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Player —— 【设备发起档（iOS 27）】的配对码会话：生成 6 位码、显示所需信息、状态与判据行。
//
//  用户口径（真机 UX，以用户确认的流程为准）：
//    ① 我们（本 App）广告可配对主机 + 生成并★持续显示★6 位码；
//    ② 用户去 设置 › 通用 › VPN 与设备管理 找到「与 <我们的主机名> 配对」，★输入我们显示的码★；
//    ③ 我们收到设备发起的会话后跑 SRP pair-setup（accessory / responder 角色），成功后落配对文件。
//
//  ★码必须「看得见、记得住」★：用户要切到系统设置去输码 ⇒ 只在 App 内闪一下不够。
//    本类做到：★把码与主机名持久化到 NSUserDefaults★ ⇒ App 切后台 / 用户去设置期间，
//    回到本 App（或设置页刷新）仍能读到同一个码（见 `restoredFromDefaults`）。
//    本类并提供状态与判据行，供设置页大字号显示。
//
//  ★如实标注（本会话未做，含唯一改点）★：
//    · 真正起 mDNS 广告（`_remotepairing-pairable-host._tcp`）与 responder 传输【未接线】：
//      Info.plist 已登记该服务类型（见 tests/JIT 的门禁），但本类只到「生成码 + 记账 + 判据行」。
//      唯一改点：在本类 `beginDeviceInitiatedWithHostName:error:` 里起 NWListener(该服务类型)，
//      并把设备发起的 pairingData TLV 转交给 Natives 的 A2RPPairSetupSession（Device/responder 角色）。
//    · 「切后台仍可见」若要【锁屏/切 App 时也持续可见】，需 Live Activity（ActivityKit）
//      —— 需额外 entitlement（NSSupportsLiveActivities）与系统授权，本会话未做。
//      唯一改点：在设置页显示行旁加 ActivityKit 的 Live Activity，内容取本类的 code/hostName。
//      ★当前保证的是「回到本 App 就能读到同一个码」，不是锁屏常显★。
//
//  ★纯逻辑、无 UIKit、无 Natives★（可单测；UI 只读本类）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 会话状态（判据行逐条打，便于照单核对）。
typedef NS_ENUM(NSInteger, A2JITPairingCodeState) {
    A2JITPairingCodeStateIdle        = 0,  ///< 未开始
    A2JITPairingCodeStateAdvertising = 1,  ///< 已生成码、正在等设备发起（广告）
    A2JITPairingCodeStateConnected   = 2,  ///< 设备已连入
    A2JITPairingCodeStateVerifying   = 3,  ///< 正在跑 SRP 验码
    A2JITPairingCodeStateSucceeded   = 4,  ///< 配对成功
    A2JITPairingCodeStateFailed      = 5,  ///< 失败（原因在 lastDetail）
};

@interface A2JITPairingCodeSession : NSObject

/// 进程内单例（设置页显示与解析共用同一份）。
+ (instancetype)sharedSession;

/// 从 NSUserDefaults 恢复上次的会话（★切后台 / 切到系统设置后仍可读到同一个码★）。
+ (nullable instancetype)restoredFromDefaults;

@property (nonatomic, readonly, copy) NSString *code;                 ///< 6 位码（未开始时为空）
@property (nonatomic, readonly, copy) NSString *hostName;             ///< 广告的主机名（用户在设置列表里要靠它认出）
@property (nonatomic, readonly) A2JITPairingCodeState state;
@property (nonatomic, readonly, copy, nullable) NSString *lastDetail; ///< 最近一次状态说明 / 失败原因

/// 开始设备发起档：生成 6 位码 + 持久化 + 置 Advertising，并打判据行。
/// ★hostName 为空 ⇒ 失败并回填 error（不猜主机名）★。
- (BOOL)beginDeviceInitiatedWithHostName:(NSString *)hostName error:(NSError *_Nullable *_Nullable)error;

/// 推进状态并打判据行（连接 / 验码 / 成功 / 失败）。
- (void)advanceToState:(A2JITPairingCodeState)state detail:(nullable NSString *)detail;

/// 结束本轮（清掉持久化的码 ⇒ ★屏幕上不再显示一个已经作废的码★）。
- (void)endPairing;

/// 状态的稳定英文名（日志可搜）。
+ (NSString *)stateName:(A2JITPairingCodeState)state;

/// 判据行（稳定前缀 `[A2-PAIRPIN]`）。
+ (NSString *)criterionLineForState:(A2JITPairingCodeState)state
                               host:(NSString *)host
                               code:(NSString *)code
                             detail:(nullable NSString *)detail;

/// 本档广告的 Bonjour 服务类型（★与 Info.plist 的 NSBonjourServices 必须一致★，tests/JIT 有门禁）。
+ (NSString *)pairableHostServiceType;

@end

NS_ASSUME_NONNULL_END
