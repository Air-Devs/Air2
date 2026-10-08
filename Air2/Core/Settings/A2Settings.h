//
//  A2Settings.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  全局设置注册表 —— Core 层唯一允许直接读写 NSUserDefaults 的地方。
//
//  为什么需要：
//    设置曾散在 A2GlobalGameSettings 与各处的裸 NSUserDefaults key 里，
//    每加一个设置要改三处，且默认值/类型无人收敛（ZL2 用 AllSettings +
//    SettingsRegistry 收敛了同一问题，这里学它的设计决策，用 ObjC 重写，
//    不照抄实现）。
//
//  约束：
//    · 只 import Foundation，保持 Core 不依赖 UIKit（CI 会查）。
//    · 只存 Foundation 类型，不 import Addons 头文件，避免
//      Settings ↔ Addons 循环依赖；枚举以 NSInteger 传递，调用方转换。
//    · Key 与旧实现完全一致，老用户升级不丢值。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 设置变更通知。userInfo 带 A2SettingsChangedKeyKey = 变更的 key。
FOUNDATION_EXPORT NSNotificationName const A2SettingsDidChangeNotification;
FOUNDATION_EXPORT NSString *const A2SettingsChangedKeyKey;

/// 全部托管 key（与历史 key 一致，保证迁移无损）。
FOUNDATION_EXPORT NSString *const A2SettingsKeyVersionIsolation;
FOUNDATION_EXPORT NSString *const A2SettingsKeySkipIntegrityCheck;
FOUNDATION_EXPORT NSString *const A2SettingsKeyRAMAllocationMB;
FOUNDATION_EXPORT NSString *const A2SettingsKeyRenderer;
FOUNDATION_EXPORT NSString *const A2SettingsKeyPreferredContentPlatform;
FOUNDATION_EXPORT NSString *const A2SettingsKeyMirrorPriority;
FOUNDATION_EXPORT NSString *const A2SettingsKeyMirrorEnabled;
FOUNDATION_EXPORT NSString *const A2SettingsKeyCurrentAccountID;
FOUNDATION_EXPORT NSString *const A2SettingsKeyCurrentVersionName;

/// 内容平台取值（对应 A2ContentPlatform，存 NSInteger 避免跨层 import）。
static const NSInteger A2SettingsPlatformModrinth = 0;
static const NSInteger A2SettingsPlatformCurseForge = 1;

/// 镜像优先级取值（对应 A2MirrorPriority）。
static const NSInteger A2SettingsMirrorOfficialFirst = 0;
static const NSInteger A2SettingsMirrorFirst = 1;

/// RAM 下限（对应 ZL2 ramAllocation min = 256，避免配出开不了的值）。
static const NSInteger A2SettingsMinRAMMB = 256;

@interface A2Settings : NSObject

+ (instancetype)shared;

/// 重读 NSUserDefaults（多进程/测试改完 defaults 后同步内存值）。
- (void)reloadAll;

/// 清掉全部托管 key，回到默认值（注销/恢复默认用）。
- (void)resetAllToDefaults;

/// 全局版本隔离开关。历史默认 NO（ZL2 默认 YES，但 Air2 已发布行为是 NO，
/// 改默认值会改变老用户隔离目录，保持 NO，仅注释说明差异）。
@property (nonatomic, assign) BOOL versionIsolation;

/// 全局跳过完整性检查。默认 NO。
@property (nonatomic, assign) BOOL skipIntegrityCheck;

/// 全局内存分配（MB）。默认 2048，写入时钳到 >= 256。
@property (nonatomic, assign) NSInteger ramAllocationMB;

/// 全局渲染器标识。默认 nil（未选择）。
@property (nonatomic, copy, nullable) NSString *renderer;

/// 首选资源平台（见上方取值常量）。默认 Modrinth。
@property (nonatomic, assign) NSInteger preferredContentPlatform;

/// 镜像优先级（见上方取值常量）。默认官方优先。
@property (nonatomic, assign) NSInteger mirrorPriority;

/// 是否允许镜像。默认 YES（是否真正生效还看网络检测）。
@property (nonatomic, assign) BOOL mirrorEnabled;

/// 当前账号 uniqueID。默认 nil。
@property (nonatomic, copy, nullable) NSString *currentAccountID;

/// 当前版本名。默认 nil。
@property (nonatomic, copy, nullable) NSString *currentVersionName;

@end

NS_ASSUME_NONNULL_END
