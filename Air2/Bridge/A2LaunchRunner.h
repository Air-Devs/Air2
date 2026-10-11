//
//  A2LaunchRunner.h
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Bridge —— ★自研启动链的唯一跨层入口★。
//
//  为什么在 Bridge（而不是 Player）：
//    分层规范 App → UI → Player → Core → Bridge → Natives（docs/ARCHITECTURE.md §依赖方向）；
//    ★Bridge 是唯一与 Natives 相邻的层★ ⇒ 「调用 Natives/Context 的 a2_launch_jvm_with_argv」
//    这件事只能发生在这里。Player 与 UI 只见本类的纯 ObjC 签名，不 import 任何 Natives 头。
//
//  本类做三件事（都不含业务）：
//    ① 转发开关：`a2_launch_runtime_enabled()`（默认关 ⇒ 旧行为不变）；
//    ② 用 Natives R4 的**唯一拼装点**产出 classpath（`a2_paths_build_classpath`），
//       并把同一份输入同时用于 argv 与 `A2LaunchInput` —— 否则 a2_launch 的 classpath
//       对齐校验会判「漂移」并【阻断启动】（返回 -9）；
//    ③ 组成完整 java 命令行后调 `a2_launch_jvm_with_argv`。
//
//  ★classpath 顺序★：front 项 = `<App>/Java/air2-launch.jar` + `<App>/Java/air2-lwjgl-patch.jar`，
//    因为 `org.lwjgl.*` 补丁类必须**先于** `libs/lwjgl-<ver>/*` 被解析（同名类覆盖）。
//

#import <Foundation/Foundation.h>

#import "A2LaunchRuntimeFacts.h"   // Utils —— ★运行时事实值对象★（屏幕像素尺寸 / 系统最大帧率）

NS_ASSUME_NONNULL_BEGIN

@interface A2LaunchRunner : NSObject

/// 自研启动链是否启用（薄转发 Natives 的 `a2_launch_runtime_enabled`；默认关）。
/// 真值来源见 a2_launch.h：env RT_P1_RUNTIME / 标志文件 / 设置项 debug.rt_p1_runtime。
+ (BOOL)runtimeChainEnabled;

/// ★采集「启动时的屏幕运行时事实」★（宿主窗口像素尺寸 + 系统最大帧率）。
///
/// 为什么在 Bridge：这两个值来自 UIKit，而 `Core` 明文不得 import UIKit
/// （docs/ARCHITECTURE.md §Core：「可单测，不依赖 UIKit」）、`Player` 也不感知 UIKit
/// （同层 A2JITLocalFactsSource 把 UIKit 探测留给更上层）；Bridge 是启动链唯一
/// 与 Natives 相邻的跨层入口，链上只有它读 UIKit 不越界。
///
/// ★调用点只有一处★：`Air2/Player/A2LaunchSession.m` 的
/// `+startCurrentVersionWithCompletion:`（在产出启动计划**之前**，同一线程；
/// 该路径由 UI 主线程进入 ⇒ UIKit 查询落在主线程）。采集结果经
/// `A2LaunchPlan` 的 `runtimeFacts` 字段落成 VM 级 `-D`。
///
/// ★不猜★：任一项取不到 ⇒ 对应字段为 0，底层据此**不下发**该 `-D`
/// （宁可让 Java 侧如实抛错，也不填一个默认值把问题盖住）。
+ (A2LaunchRuntimeFacts *)currentRuntimeFacts;

/// 以已解析好的取值组成 java 命令行并调用自研链（**同步阻塞**：会建 VM 并派发主类 main，
/// 调用方须放到后台队列）。
///
/// @param planPath    启动计划 JSON 路径（交给 Java 侧 A2Entry 的 `--plan`）
/// @param entryJarPath 自研启动核心 jar（`<App>/Java/air2-launch.jar`）
/// @param patchJarPath LWJGL 补丁 jar（`<App>/Java/air2-lwjgl-patch.jar`；可空）
/// @param jvmOptions  VM 级选项（`-Xmx…` / `-D…`；不含 classpath）
/// @param javaHome    选中的 JRE home
/// @param gameDir     实例游戏目录
/// @param userHome    POJAV_HOME 等价目录
/// @param tmpDir      可写临时目录
/// @param librariesPath `<...>/libraries`
/// @param lwjglDir    `<...>/lwjgl-<ver>`
/// @param frameworksPath `<App>/Frameworks`（可空 ⇒ 由 bundle 推）
/// @param rendererDylib ★用户选中的渲染后端 dylib 名★（`A2SelectedRendererPrefKey` 的值；
///        可空 ⇒ 主推 `libmetallum.dylib`）。★由 Player 解析好传入，Bridge 不读偏好★ ——
///        本层只负责「把它交给 Natives/Renderer/a2_renderer 加载」。
/// @return `a2_launch_jvm_with_argv` 的返回码（0 成功；负值见 a2_launch.h 契约）；
///         ★-10 = 所选渲染后端未内置/加载失败 ⇒ 未进 VM，如实阻断（不静默回退）★。
+ (int)launchWithPlanPath:(NSString *)planPath
             entryJarPath:(NSString *)entryJarPath
           patchJarPath:(nullable NSString *)patchJarPath
               jvmOptions:(NSArray<NSString *> *)jvmOptions
                 javaHome:(NSString *)javaHome
                  gameDir:(NSString *)gameDir
                 userHome:(NSString *)userHome
                   tmpDir:(NSString *)tmpDir
            librariesPath:(NSString *)librariesPath
                 lwjglDir:(NSString *)lwjglDir
           frameworksPath:(nullable NSString *)frameworksPath
            rendererDylib:(nullable NSString *)rendererDylib;

@end

NS_ASSUME_NONNULL_END
