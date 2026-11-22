//
//  A2LaunchSplashView.h
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
//  A2LaunchSplashView.h
//  Air2
//
//  启动遮罩 —— 从「点开始游戏」到「游戏画面出现」之间的过渡层。
//
//  ## 为什么需要
//
//  启动 Minecraft 的流程是：
//      选版本 → 完整性检查 → 补下载 → 拉起 JVM → 加载类
//      → 初始化 OpenGL → 显示主菜单
//
//  中间这十几秒如果只是黑屏，用户会以为卡死了。
//
//  ## 显示什么
//
//  参考 ZL2 与 Air1 的做法：
//    · 版本名与图标
//    · 当前阶段（检查文件 / 补下载 / 启动 JVM / 初始化渲染）
//    · 已用时间
//    · 一段实时日志（调试时有价值，失败时自动展开）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2LaunchStage) {
    A2LaunchStagePreparing = 0,    ///< 准备 / 检查文件
    A2LaunchStageRepairing,        ///< 补下载
    A2LaunchStageStartingJVM,      ///< 启动 JVM
    A2LaunchStageLoadingClasses,   ///< 加载类
    A2LaunchStageInitializingGL,   ///< 初始化渲染
    A2LaunchStageWaitingWindow,    ///< 等待游戏窗口
    A2LaunchStageFinished,         ///< 完成
    A2LaunchStageFailed,           ///< 失败
};

// ------------------------------------------------------------------
//  启动任务清单（对照 ZL2 GameLaunchFlow.buildLaunchPhases）
//
//  ZL2 的启动界面**不是百分比进度条**，而是一份任务清单：
//    zl2 .../game/launch/GameLaunchFlow.kt:167 buildLaunchPhases
//    四个 addTask，每个带 icon + title：
//      1. 账号登录校验      ic_login
//      2. 检查游戏环境      ic_extension_outlined
//         （扫模组 → 检查渲染器兼容 → 解析 manifest → 补下依赖库）
//      3. 校验并修复文件    ic_assignment_filled（可被 skipGameIntegrityCheck 跳过）
//      4. 启动游戏          ic_rocket_launch_filled
//    UI 展示的是每一项的状态（等待 / 进行中 / 完成 / 失败），
//    进度感来自「还剩几项没做完」，而不是一个编出来的百分比。
//
//  之前这里做了一条按权重推进的进度条，权重是凭空拍的，与真实阶段耗时无关，
//  已废弃。改为任务清单。
// ------------------------------------------------------------------

typedef NS_ENUM(NSInteger, A2LaunchTaskState) {
    A2LaunchTaskStatePending = 0,   ///< 等待
    A2LaunchTaskStateRunning,       ///< 进行中
    A2LaunchTaskStateDone,          ///< 完成
    A2LaunchTaskStateFailed,        ///< 失败
    A2LaunchTaskStateSkipped,       ///< 跳过（例如不需要校验账号）
};

@interface A2LaunchTaskItem : NSObject
/// SF Symbols 名（如 "checkmark.shield"）
@property (nonatomic, copy, readonly) NSString *symbolName;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, assign) A2LaunchTaskState state;
/// 进行中/失败时的补充说明（一行），可为空
@property (nonatomic, copy, nullable) NSString *detail;

+ (instancetype)itemWithSymbol:(NSString *)symbol
                         title:(NSString *)title;
@end

/// 用一份任务清单重建列表。传 nil 或空数组则隐藏清单。
@interface A2LaunchSplashView : UIView

@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, strong, nullable) UIImage *versionIcon;

@property (nonatomic, assign, readonly) A2LaunchStage stage;

- (void)setTasks:(nullable NSArray<A2LaunchTaskItem *> *)tasks;

/// 更新某一项状态。索引越界会被忽略（不崩）。
- (void)setTaskState:(A2LaunchTaskState)state
             atIndex:(NSInteger)index
              detail:(nullable NSString *)detail;


/// 兼容旧调用：把语言级阶段映射到清单里「进行中」的那一项。
- (void)setStage:(A2LaunchStage)stage message:(nullable NSString *)message;

@property (nonatomic, assign) BOOL showsLog;
- (void)appendLog:(NSString *)line;

- (void)showFailure:(NSString *)message
            onRetry:(nullable void (^)(void))onRetry
             onQuit:(nullable void (^)(void))onQuit;

- (void)finishAndDismissWithCompletion:(nullable void (^)(void))completion;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
