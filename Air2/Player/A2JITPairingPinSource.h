//
//  A2JITPairingPinSource.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Player —— 【配对码来源】的可选项与解析（★用户可见的「设置项」，不是纯代码缝★）。
//
//  照 `A2SelectedRenderer` / `A2SelectedJavaRuntime` 的写法：一张列表 + 持久化
//  （键 = A2LaunchContract.h 的跨层契约常量）+ 写入点唯一（设置页）+ 读取点唯一（本文件）+ 判据行。
//
//  为什么要有这些档（协议事实，来源见 Natives/Support/a2_rppairing_pairsetup.h 顶部）：
//    · 信任弹窗档（iOS 常规）：主机发起 pair-setup，设备弹「信任」框，
//      ★PIN 固定 "000000"，不需要用户输入★（JK Coxson RPPairing 规格 §9：awaitingUserConsent ⇒
//      "The PIN is 000000 for iOS"）。
//    · 设备发起档（★iOS 27★）：本机广告 `_remotepairing-pairable-host._tcp` 并★显示 6 位码★，
//      用户在设备的「设置 › 通用 › VPN 与设备管理」里输入我们显示的码 ⇒ 我们演 accessory(responder) 角色。
//    · 已有配对记录档：设备已认识本机 ⇒ 走 pair-verify 快路径，★跳过 pair-setup★。
//    · 设备屏显码档（Apple TV / Vision Pro）：★照列但未实现★（本仓不面向该场景）。
//
//  ★未选择 / 选到未实现的档 ⇒ 一律如实拒绝并点名原因，绝不静默回退到别的档★。
//  ★纯逻辑、无 UIKit、无 Natives★（Natives 的 A2RPPairSetupPinProvider 由装配处按本解析结果构造）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 配对码来源档（选择项的语义）。
typedef NS_ENUM(NSInteger, A2JITPairingPinMode) {
    A2JITPairingPinModeUnselected      = 0,  ///< 键缺失 = 未选择 ⇒ 如实拒绝
    A2JITPairingPinModeTrustDialog     = 1,  ///< 信任弹窗档（iOS 常规）：PIN 固定 000000，自动
    A2JITPairingPinModeDeviceInitiated = 2,  ///< 设备发起档（iOS 27）：本机显示 6 位码
    A2JITPairingPinModeExistingRecord  = 3,  ///< 已有配对记录档：pair-verify 快路径（跳过 pair-setup）
    A2JITPairingPinModeOnScreenCode    = 4,  ///< 设备屏显码档（Apple TV / Vision Pro）：★未实现★
    A2JITPairingPinModeUnknown         = 5,  ///< 键值不认识
};

/// 候选档（值对象）。
@interface A2JITPairingPinSourceItem : NSObject
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly) A2JITPairingPinMode mode;
/// ★本仓是否已实现★：NO 的档照列不误，但选中即「如实拒绝 + 点名未实现」。
@property (nonatomic, readonly) BOOL implemented;
/// 文案 key（四语，见 A2JITStrings）。
@property (nonatomic, readonly, copy) NSString *nameKey;
+ (instancetype)itemWithIdentifier:(NSString *)identifier
                              mode:(A2JITPairingPinMode)mode
                       implemented:(BOOL)implemented
                           nameKey:(NSString *)nameKey;
@end

/// 候选表（★照列不误★：未实现的也入表）。
@interface A2JITPairingPinSourceCatalog : NSObject
+ (NSArray<A2JITPairingPinSourceItem *> *)allItems;
/// 缺省档（键缺失时的「推荐」；★注意：推荐 ≠ 已选择★ —— 未选择仍如实拒绝）。
+ (NSString *)defaultIdentifier;
+ (nullable A2JITPairingPinSourceItem *)itemForIdentifier:(NSString *)identifier;
+ (A2JITPairingPinMode)modeForIdentifier:(NSString *)identifier;
+ (NSString *)displayNameForMode:(A2JITPairingPinMode)mode;   ///< 稳定英文名（日志可搜）
@end

/// 解析（★读取点唯一★）：把「用户选择的档」解析成 pair-setup 需要的配对码 / 或「该走哪条路」。
@interface A2JITPairingPinResolver : NSObject

/// 当前选择的档（读 NSUserDefaults；键缺失 ⇒ Unselected）。
+ (A2JITPairingPinMode)selectedMode;
/// 标准判据行（供日志逐条打；形如 `[A2-PAIRPIN] source=… mode=… implemented=…`）。
+ (NSString *)criterionLine;

/// 解析出本轮 pair-setup 要用的配对码。
/// @param displayedCode 设备发起档下本机**显示**的 6 位码（其它档忽略）。
/// @return 非 nil ⇒ 直接用这个码；nil ⇒ *reason 说明为什么不能做（该走别条路 / 未实现 / 未选择）。
+ (nullable NSString *)resolvedPinForDisplayedCode:(nullable NSString *)displayedCode
                                            reason:(NSString *_Nullable *_Nullable)reason;

@end

NS_ASSUME_NONNULL_END
