//
//  A2LaunchContract.h
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  启动链「跨层契约常量」—— 放在 Utils（叶子层：全层可依赖，它不反向依赖任何业务层）。
//
//  为什么单独成文件、且放在 Utils：
//    · 这几个串是【三层共同约定的名字】：Core 产出启动计划时要写它、Player 编排要用它、
//      Bridge 组 java 命令行（margv）时要用它、Java 侧入口按它取名。
//    · 分层规范 App → UI → Player → Core → Bridge → Natives 里，Core 与 Bridge 之间
//      只允许「Core → Bridge」单向；若把常量放 Core，Bridge 就不得不 import Core（违规范），
//      放 Bridge 则 Core 反向依赖（虽然允许，但会让 Core 的「业务」与「跨界通道」纠缠）。
//    · Utils 是唯一「所有层都能 import、且不含业务」的家 ⇒ 契约常量落这里最干净。
//
//  ★这些名字是 ABI 级契约★：改它们必须同时改
//    JavaApp/src/launcher/dev/airdevs/air2/launch/*.java 与
//    scripts/gen_xcodeproj.py 的 Java 脚本阶段（jar 名 / 拷贝目标）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// ★Java 侧自研入口主类★ —— native `a2_run_main` 的派发目标。
/// 见 JavaApp/src/launcher/dev/airdevs/air2/launch/A2Entry.java。
FOUNDATION_EXPORT NSString *const A2LaunchEntryMainClass;

/// Java 侧入口读取启动计划的参数名（`A2Entry` 只认这一个）。
FOUNDATION_EXPORT NSString *const A2LaunchPlanFlag;

/// 追加类路径用的系统类加载器（Java 9+ 唯一可行方式；Java 8 走反射兜底）。
FOUNDATION_EXPORT NSString *const A2LaunchGameClassLoaderName;

/// 自研启动核心 jar 名（随包 `<App>/Java/`；由 JavaApp/Makefile + 脚本阶段产出）。
FOUNDATION_EXPORT NSString *const A2LaunchJavaEntryJarName;

/// LWJGL 补丁类 jar 名（★决策：org.lwjgl.* 补丁放 Java 侧、独立 jar★，
/// 必须排在 `libs/lwjgl-<ver>/*` 之前 ⇒ 作为 classpath 最前的 front 项）。
FOUNDATION_EXPORT NSString *const A2LaunchJavaPatchJarName;

/// 自研 org.lwjgl.glfw.* 最小集 jar 名（[A2-OWNGLFW-1]，随包 `<App>/Java/`）。
/// 它覆盖官方 `org.lwjgl.glfw.GLFW`/`Callbacks`/`GLFWNativeCocoa`，同样必须在
/// `libs/lwjgl-<ver>/*` 之前（与补丁 jar 同列 front 项）。缺该 jar 时自动跳过（回退官方实现）。
FOUNDATION_EXPORT NSString *const A2LaunchJavaOwnGlfwJarName;

/// 启动计划 JSON 的 schema（与 Java 侧 `A2LaunchPlan.SCHEMA_VERSION` 必须一致，否则 Java 侧直接失败）。
FOUNDATION_EXPORT const NSInteger A2LaunchPlanSchema;

NS_ASSUME_NONNULL_END
