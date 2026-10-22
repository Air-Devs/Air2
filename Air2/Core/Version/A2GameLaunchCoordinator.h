//
//  A2GameLaunchCoordinator.h
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
//
//
//  A2GameLaunchCoordinator.h
//  Air2
//
//  启动编排器 —— **严格对照 ZL2 的 GameLaunchFlow.kt（286 行）**。
//
//  ## ZL2 的结构（不是一条直线，是 Phase + Task 模型）
//
//    GameLaunchFlow.launch()
//      └─ TaskFlowExecutor.executePhasesAsync()
//           └─ buildPhase {
//                ├─ Task 1  账号校验        （条件执行）
//                ├─ Task 2  扫描模组        （必做，可能打补丁）
//                ├─ Task 3  完整性校验       （可跳过）
//                └─ Task 4  启动游戏
//              }
//
//  ## 每个 Task 的细节
//
//  **Task 1 · 账号校验**
//    条件：有网络 && !skipAccountRefresh && AccountsManager.isLaunchCheckNeeded(account)
//    微软账号：
//      · 距过期 < 5 分钟 → 直接刷新
//      · 否则 validateAccessToken，失败再刷新
//    外置账号：
//      · validateOrRefresh → 失败则 passwordLogin
//    失败分两类（这个区分很重要）：
//      · ReloginRequired → 引导用户重新登录
//      · CheckFailed     → 网络/服务器问题，可重试
//
//  **Task 2 · 扫描模组**
//    读 mods 目录，然后：
//      · 发现 touchcontroller → 开启触摸代理
//      · lwjgl3ify 需要补丁 → patchLwjgl3ify
//      · **打了补丁就要重新检索依赖库并下载** ← 这条容易漏
//
//  **Task 3 · 完整性校验**
//    用的是 MinecraftDownloader(mode = VERIFY_AND_REPAIR)：
//    只读【本地已存在的】版本 json，按它的 sha1/size 校验，
//    缺的补下、错的删除重下。
//    —— 注意：这与「DOWNLOAD 模式」是【同一个类的两个模式】，
//       不是两套代码。这一点我之前理解错了。
//
//  **Task 4 · 启动**
//    runGame() → exitActivity()
//
//  ## 我们的实现
//
//  Kotlin 协程 → ObjC 完成回调链；TaskFlowExecutor → 顺序执行 + 阶段通知。
//  语义保持：Task 顺序、失败分类、可选跳过都要一致。
//

#import <Foundation/Foundation.h>
#import "A2VersionManager.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2LaunchTask) {
    A2LaunchTaskCheckAccount = 0,   ///< 账号校验（条件执行）
    A2LaunchTaskScanMods,           ///< 扫描模组（必做）
    A2LaunchTaskVerifyFiles,        ///< 完整性校验（可跳过）
    A2LaunchTaskStartGame,          ///< 启动
};

/// 失败类型 —— 区分「要重新登录」和「网络问题」，处理方式完全不同
typedef NS_ENUM(NSInteger, A2LaunchErrorKind) {
    A2LaunchErrorKindReloginRequired = 0,   ///< 凭据被服务端拒绝
    A2LaunchErrorKindCheckFailed,           ///< 网络/服务器问题
    A2LaunchErrorKindFileIntegrity,         ///< 文件损坏且无法修复
    A2LaunchErrorKindNoJRE,                 ///< 没有可用的 Java
    A2LaunchErrorKindUnknown,
};

/// 启动进度
@interface A2LaunchProgress : NSObject
@property (nonatomic, assign) A2LaunchTask task;
@property (nonatomic, assign) double fraction;      ///< 0~1（整个流程）
@property (nonatomic, assign) double taskFraction;  ///< 0~1（当前 Task）
@property (nonatomic, copy) NSString *title;        ///< Task 名（"扫描模组"）
@property (nonatomic, copy) NSString *message;      ///< 细节
@end

extern NSNotificationName const A2LaunchProgressDidChangeNotification;

@interface A2GameLaunchCoordinator : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, getter=isLaunching) BOOL launching;
@property (nonatomic, readonly) A2LaunchTask currentTask;

/// 启动
///
/// @param versionName 目标版本
/// @param skipAccountRefresh 跳过账号校验（用户自己确保凭据有效）
/// @param skipIntegrityCheck 跳过文件校验（对照 ZL2 的 version.skipGameIntegrityCheck）
/// @param completion 结果。失败时 error.userInfo[@"kind"] 带 A2LaunchErrorKind
- (void)launchVersion:(NSString *)versionName
   skipAccountRefresh:(BOOL)skipAccountRefresh
  skipIntegrityCheck:(BOOL)skipIntegrityCheck
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

- (void)cancel;

@end

NS_ASSUME_NONNULL_END
