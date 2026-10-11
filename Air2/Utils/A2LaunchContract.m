//
//  A2LaunchContract.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  契约常量的唯一定义点（声明见 A2LaunchContract.h）。
//

#import "A2LaunchContract.h"

NSString *const A2LaunchEntryMainClass        = @"dev.airdevs.air2.launch.A2Entry";
NSString *const A2LaunchPlanFlag              = @"--plan";
NSString *const A2LaunchGameClassLoaderName   = @"dev.airdevs.air2.launch.A2GameClassLoader";
NSString *const A2LaunchJavaEntryJarName      = @"air2-launch.jar";
NSString *const A2LaunchJavaPatchJarName      = @"air2-lwjgl-patch.jar";

const NSInteger A2LaunchPlanSchema = 1;

// ★系统属性名★（读取方 = 复用线覆盖层 GLFW 的静态块；见 A2LaunchContract.h 的注解）
NSString *const A2LaunchSysPropGLFWWindowSize         = @"glfw.windowSize";
NSString *const A2LaunchSysPropMaximumFramesPerSecond = @"UIScreen.maximumFramesPerSecond";

// ★用户选择项★（NSUserDefaults；Air2 自己的偏好存储 —— 与 Natives/Context/a2_launch.m
// 读 debug.* 开关同一来源，不是老线 POJAV_HOME 下的 plist）。
NSString *const A2SelectedRendererPrefKey    = @"A2SelectedRenderer";
NSString *const A2SelectedJavaRuntimePrefKey = @"A2SelectedJavaRuntime";
// [JIT-AUTOPAIR-3] 配对码来源（写入点=设置页；读取点=Player 的 A2JITPairingPinResolver）。
NSString *const A2SelectedPairingPinSourcePrefKey = @"A2SelectedPairingPinSource";
