//
//  A2PluginBootGuard.h
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
//  ★P1 第⑤块：boot marker + 连续 3 次未跨首帧自动停用★
//
//  ## 解决的场景
//
//  插件把游戏启动搞坏时，用户看到的是「点启动 → 闪回桌面」，而且每次重启都会
//  重演 —— 用户没有任何办法在 UI 里自救（插件列表还没点进去就崩在启动链上）。
//  这里做最小的一档：**记仇**。连续 3 次启动都没走到首帧，就把可疑插件停掉，
//  让第 4 次启动大概率能起来；完整的安全模式归 P2。
//
//  ## 三档口径（不得改）
//
//    · 第 1、2 次未跨首帧 ⇒ 只记录（failureCount 累加，不停用）
//    · 第 3 次            ⇒ 自动停用该插件（enabled = NO）+ 记 lastAutoDisabledReason
//    · 第 4 次及以后      ⇒ 本块不管（P2 才做完整安全模式；这里**不会**再动手）
//    · 某次启动跨过了首帧 ⇒ 该插件的 failureCount 清零、marker 删除
//
//  ## 为什么是 marker 文件而不是「启动成功写一次日志」
//
//  判据必须是「上一次启动有没有走完」，而这个判断发生在**下一次**启动里，
//  中间隔着一次进程崩溃 —— 进程内存留不住任何东西，只能落盘。
//  marker 的含义刻意做成「我开始了但没收到首帧」：写 marker 是启动前的最后一个
//  动作，删 marker 是首帧回调的第一个动作，因此**任何**崩溃点都会留下 marker，
//  不需要枚举崩溃原因。
//
//  ## 位置
//
//    <App 容器>/Library/Application Support/Air2/Plugins/.state/boot.json
//
//  与 registry.json 同目录（同一份事实来源），点开头 ⇒ 不出现在插件的目录扫描里。
//  原子写走 Foundation 的 NSDataWritingAtomic（同目录 tmp + rename），
//  理由见 .m；这份文件丢了最坏只是少记一次，不值得照抄注册表那套 fsync 代码。
//
//  ## 幂等
//
//  `evaluatePreviousLaunch` 与 `markLaunchStarted` 都会消费上一次的 marker，
//  所以 marker 里带 `counted` 位：谁先跑谁计数，后跑的那个只看到 counted=YES
//  就不再累加 —— 否则「启动器启动」和「点启动」两条路径会把计数翻倍。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class A2PluginRegistryEntry;

/// 连续多少次「启动了没到首帧」就把插件自动停用（三档口径里的第 3 档）。
/// 引用点：A2PluginBootGuard.m 的计数判定、tests/Plugin/plugin_boot_guard_tests.m。
FOUNDATION_EXPORT const NSInteger A2PluginBootGuardAutoDisableThreshold;

/// 启动看门狗。**没有单例式的隐藏状态**：marker 与注册表都在磁盘上，
/// 单测因此可以各自指向临时目录（同 A2PluginRegistry 的理由）。
@interface A2PluginBootGuard : NSObject

/// 宿主用的那一份（默认插件目录）。
@property (class, nonatomic, readonly) A2PluginBootGuard *sharedGuard;

/// @param pluginsDirectory `.../Air2/Plugins`；传 nil 用容器内的默认路径。
- (instancetype)initWithPluginsDirectory:(nullable NSString *)pluginsDirectory
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// `.../Plugins/.state/boot.json`。
@property (nonatomic, copy, readonly) NSString *bootMarkerPath;

/// 接线点 A：每次「开始启动」（建 VM 之前）调一次。
/// 先把上一次的 marker 结算掉（见 evaluatePreviousLaunch），再为所有**已启用**
/// 插件写一份新的 marker。注册表读不出来时返回 NO 且不写 marker（宁可不保护，
/// 也不要把一份「谁都没启用」的空 marker 盖在真 marker 上）。
- (BOOL)markLaunchStarted;

/// 接线点 B：首帧到达时调一次。所有插件 failureCount 归零 + 删除 marker。
/// 没有 marker 时是空操作（同一次启动里重复调用安全）。
- (BOOL)markFirstFrameReached;

/// 接线点 C：启动器/插件页加载时调一次，把「上一次启动的结论」结算到注册表。
/// @return 本次**因达到阈值而被自动停用**的条目（供 UI 提示）；没有则为空数组。
///         注册表读失败、marker 缺失、marker 损坏、marker 已被结算过 ⇒ 都返回空数组。
- (NSArray<A2PluginRegistryEntry *> *)evaluatePreviousLaunch;

/// 以下三个是接线点的便利入口，转发到 sharedGuard。
+ (BOOL)markLaunchStarted;
+ (BOOL)markFirstFrameReached;
+ (NSArray<A2PluginRegistryEntry *> *)evaluatePreviousLaunch;

@end

NS_ASSUME_NONNULL_END
