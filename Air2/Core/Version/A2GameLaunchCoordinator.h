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
//  启动编排器 —— 严格对照 ZL2 的 GameLaunchFlow.kt buildLaunchPhases（第 167~274 行）。
//
//  ## ZL2 的结构（任务清单，不是一条直线）
//
//    GameLaunchFlow.launch() 第 126~157 行
//      └─ TaskFlowExecutor.executePhasesAsync()
//           └─ buildPhase { ... } 第 184~273 行
//                ├─ Task 1  账号校验        （第 187~209 行，条件执行）
//                ├─ Task 2  检查游戏环境    （第 213~242 行，必做）
//                │            ├─ checkMods()            第 328~339 行
//                │            ├─ checkRendererSupport() 第 344~365 行
//                │            ├─ VersionInfoParser 解析 manifest 第 225~231 行
//                │            └─ 打了补丁就重新检索依赖库并下载 第 234~241 行
//                ├─ Task 3  校验并修复文件  （第 244~255 行，可跳过）
//                └─ Task 4  启动游戏        （第 258~272 行）
//
//  ## Air2 的映射
//
//    ZL2 的一个「检查游戏环境」任务在 Air2 拆成三步，便于 UI 逐项显示
//    等待 / 进行中 / 完成 / 失败：
//
//      1. 校验账号          A2AccountManager.refreshCurrentAccountIfNeeded:
//      2. 扫描模组          A2LaunchPrecheck scanModsForVersion:report:
//      3. 检查渲染器        A2LaunchPrecheck checkRendererForMCVersion:report:error:
//      4. 解析版本清单      A2LaunchPrecheck parseManifestForVersion:report:error:
//      5. 校验并修复文件    A2IntegrityChecker + A2IntegrityRepairer
//      6. 启动游戏          JRE 检查 + 交给 UI 拉起 JVM
//
//    执行器用 A2TaskFlowExecutor：阶段 → 任务串行、协作式取消、UI 快照。
//    每个任务失败时都会带上「哪个文件 / 哪个 URL / 什么原因 / 能否重试」
//    （A2LaunchDiagnostics.h），不会只剩一句「启动失败」。
//
//  ## 观察接口
//
//    · A2LaunchProgressDidChangeNotification 每次状态变化都会在主线程发出；
//      userInfo[@"progress"] 是旧的进度对象（兼容旧 UI），
//      userInfo[@"steps"] 是当前完整的任务清单（含失败原因）。
//    · -steps 可随时从任意线程取一份只读快照。
//    · A2LaunchStepState 的数值与 Player/GameUI/A2LaunchSplashView.h 的
//      A2LaunchTaskState 一一对应，UI 可直接映射。
//
//  ## 与旧版协调器的差异
//
//    · 旧版是嵌套 completion 链，没有统一取消；现在失败后后续任务不再执行，
//      取消会传到修复器 / 批量下载。
//    · 旧版在「文件不完整」时直接调 A2GameInstaller 重装原版；现在先走
//      A2IntegrityRepairer 只补缺文件，只有版本 JSON 本身坏了才回退重装。
//    · 旧版账号只判断 401/403；现在保留了同类分类，但补上了可重试标记。
//

#import <Foundation/Foundation.h>

#import "A2VersionManager.h"
#import "A2LaunchDiagnostics.h"

NS_ASSUME_NONNULL_BEGIN

/// 启动任务的粗分类。保留旧值顺序，UI 的 switch 不需要改。
typedef NS_ENUM(NSInteger, A2LaunchTask) {
    A2LaunchTaskCheckAccount = 0,   ///< 账号校验（离线/跳过时仍占一项，状态为 Skipped）
    A2LaunchTaskScanMods,           ///< 扫描模组
    A2LaunchTaskVerifyFiles,        ///< 完整性校验与修复
    A2LaunchTaskStartGame,          ///< 启动
};

/// 清单里单项的状态。数值必须与 A2LaunchTaskState（UI 层）一致。
typedef NS_ENUM(NSInteger, A2LaunchStepState) {
    A2LaunchStepStatePending = 0,   ///< 等待
    A2LaunchStepStateRunning = 1,   ///< 进行中
    A2LaunchStepStateDone = 2,      ///< 完成
    A2LaunchStepStateFailed = 3,    ///< 失败
    A2LaunchStepStateSkipped = 4,   ///< 跳过（离线账号 / 用户设置跳过校验）
};

/// 任务清单里的一项，供 UI 直接渲染。
@interface A2LaunchStep : NSObject

/// 显示名（"校验账号" / "扫描模组" / ...）
@property (nonatomic, copy, readonly) NSString *title;
/// 当前状态
@property (nonatomic, assign, readonly) A2LaunchStepState state;
/// 一行细节（当前文件名 / 错误原因），可为 nil
@property (nonatomic, copy, readonly, nullable) NSString *detail;
/// 失败时的完整诊断（含 file/url/reason/retryable），成功/等待时为 nil
@property (nonatomic, strong, readonly, nullable) NSError *error;
/// 原样重试是否可能成功
@property (nonatomic, assign, readonly, getter=isRetryable) BOOL retryable;

@end

/// 启动进度（兼容旧 UI 的字段 + 新增诊断字段）
@interface A2LaunchProgress : NSObject
@property (nonatomic, assign) A2LaunchTask task;
@property (nonatomic, assign) double fraction;      ///< 0~1（整个流程）
@property (nonatomic, assign) double taskFraction;  ///< 0~1（当前 Task）
@property (nonatomic, copy) NSString *title;        ///< Task 名（"扫描模组"）
@property (nonatomic, copy) NSString *message;      ///< 细节

/// 新增：当前步骤在清单中的位置（-1 表示还没有任务在跑）
@property (nonatomic, assign) NSInteger stepIndex;
@property (nonatomic, assign) NSInteger stepCount;
/// 新增：当前步骤状态（等待/进行中/完成/失败/跳过）
@property (nonatomic, assign) A2LaunchStepState stepState;
/// 新增：失败原因（不含文件/地址的短句）；成功时为 nil
@property (nonatomic, copy, nullable) NSString *failureReason;
/// 新增：原样重试是否可能成功
@property (nonatomic, assign, getter=isRetryable) BOOL retryable;
@end

extern NSNotificationName const A2LaunchProgressDidChangeNotification;

@interface A2GameLaunchCoordinator : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, getter=isLaunching) BOOL launching;
@property (nonatomic, readonly) A2LaunchTask currentTask;

/// 完整任务清单（只读快照，任意线程可读）。空闲时为空数组。
@property (nonatomic, copy, readonly) NSArray<A2LaunchStep *> *steps;

/// 最近一次启动失败的错误（含 kind/file/url/reason/retryable）；成功后清空。
@property (nonatomic, strong, readonly, nullable) NSError *lastError;

/// 启动
///
/// @param versionName 目标版本
/// @param skipAccountRefresh 跳过账号校验（用户自己确保凭据有效）
/// @param skipIntegrityCheck 跳过文件校验（对照 ZL2 的 version.skipGameIntegrityCheck）
/// @param completion 结果。失败时 error.userInfo 带 @"kind"（A2LaunchErrorKind）
///                   以及 A2LaunchDiagnostics 的文件/地址/原因/可重试字段。
///                   完成块在主线程回调。
- (void)launchVersion:(NSString *)versionName
   skipAccountRefresh:(BOOL)skipAccountRefresh
  skipIntegrityCheck:(BOOL)skipIntegrityCheck
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// 取消当前流程。修复器/批量下载会收到取消；正在跑的校验会尽快返回。
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
