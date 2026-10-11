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

/// 启动计划 JSON 的 schema（与 Java 侧 `A2LaunchPlan.SCHEMA_VERSION` 必须一致，否则 Java 侧直接失败）。
FOUNDATION_EXPORT const NSInteger A2LaunchPlanSchema;

/// ★JVM 系统属性名（ABI 级契约）★ —— 复用线覆盖层 `GLFW.java` 的**静态块**直接读它们：
///   · `GLFW.java:538`  `System.getProperty("glfw.windowSize").split("x")`   ⇒ 取值必须是 `"<宽>x<高>"`；
///   · `GLFW.java:557`  `Integer.parseInt(System.getProperty("UIScreen.maximumFramesPerSecond"))`
///                      ⇒ 取值必须是十进制整数（单位 = 帧/秒）。
/// 因为读它们的是**类装载时**的静态块，所以只能由 VM 级 `-D` 落下（早于任何类初始化）——
/// 落点在 `A2LaunchPlan.jvmOptionsWithMemoryMB:`，取值来源见 `A2LaunchRuntimeFacts`。
/// ★改这里的字面量必须同步改 `JavaApp/src/lwjgl/org/lwjgl/glfw/GLFW.java` 的那两行★
/// （机器校验：`scripts/verify_launch_planprops.py`）。
FOUNDATION_EXPORT NSString *const A2LaunchSysPropGLFWWindowSize;
FOUNDATION_EXPORT NSString *const A2LaunchSysPropMaximumFramesPerSecond;

/// ★用户选择的渲染后端偏好键（跨层契约：UI 写、Player 读、Bridge 只接收已解析的 dylib 名）★。
///
/// 存储：**Air2 自己的 `NSUserDefaults`**（★不是老线 `$POJAV_HOME` 下的 plist★）。
/// 取值：渲染后端 dylib 的**文件名**（与老线 `runtime_native/Natives/utils.h` 的
///      `RENDERER_NAME_*` 同一词汇表，如 `libmetallum.dylib`）；键缺失 = 未选择 ⇒ 用主推。
/// 写入点唯一：`Air2/UI/Screens/Settings/A2RuntimeSettings.m` 的渲染器行 onTap；
/// 读取点唯一：`Air2/Player/A2LaunchSession.m` 的 `+startCurrentVersionWithCompletion:`。
FOUNDATION_EXPORT NSString *const A2SelectedRendererPrefKey;

/// ★用户选择的 Java 运行时偏好键★（同上：NSUserDefaults，UI 写、Player 读）。
/// 取值：`<App>/java_runtimes/` 下的**目录名**（如 `java-25-openjdk`）；键缺失 = 未选择 ⇒ 用主推。
/// 选中值最终成为启动计划的 `javaHome`（`A2LaunchRunner.javaHome:` 参数）。
FOUNDATION_EXPORT NSString *const A2SelectedJavaRuntimePrefKey;

/// ★用户选择的「配对码来源」偏好键★（[JIT-AUTOPAIR-3]；同上：NSUserDefaults，UI 写、Player 读）。
///
/// 取值 = 候选标识（见 `A2JITPairingPinSourceCatalog`）：
///   · `trustDialog`     —— 信任弹窗档（iOS 常规）：PIN 固定 `000000`，自动；
///   · `deviceInitiated` —— 设备发起档（iOS 27，★主推★）：本机显示 6 位码，用户在系统设置里输入；
///   · `existingRecord`  —— 已有配对记录档：走 pair-verify 快路径（跳过 pair-setup）；
///   · `onScreenCode`    —— 设备屏显码档（Apple TV / Vision Pro）：★照列、未实现★。
/// ★键缺失 = 未选择 ⇒ 一律如实拒绝（不静默回退到别的档）★。
/// 写入点唯一：`Air2/UI/Screens/Settings/A2JITSettings.m` 的「配对码来源」行；
/// 读取点唯一：`Air2/Player/A2JITPairingPinSource.m` 的 `A2JITPairingPinResolver`。
FOUNDATION_EXPORT NSString *const A2SelectedPairingPinSourcePrefKey;

NS_ASSUME_NONNULL_END
