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

@interface A2LaunchSplashView : UIView

@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, strong, nullable) UIImage *versionIcon;

@property (nonatomic, assign, readonly) A2LaunchStage stage;

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
