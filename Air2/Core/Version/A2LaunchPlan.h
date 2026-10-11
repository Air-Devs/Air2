//
//  A2LaunchPlan.h
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Core/Version —— 启动计划（launch plan）的★产出方★。
//
//  ★归属决策（见 docs/ARCHITECTURE.md [LAUNCH-PLAN] 与 D:\CTF\_AIR2_LAUNCH_PATH.md §①）：
//    启动计划由 **Core** 产出，不由 native 自研链产出。理由三条：
//      ① 计划的内容 = 版本 JSON 语义（mainClass / arguments / libraries / assetIndex /
//         inheritsFrom 合并 / rules 求值）+ 账号取值 ⇒ 是**业务**；
//      ② 分层规范写明 Natives「只接收已解析好的参数，不感知版本/账号」
//         （docs/ARCHITECTURE.md §Natives 约束），a2_launch.h / A2JVMContext.h 也把
//         「javaHome 与启动选项由上层（Player → Core）解析后传入」写成契约；
//      ③ Core/Version 的职责本就包含「启动参数拼装」（docs/ARCHITECTURE.md §Core）。
//    ⇒ native 自研链保持「纯消费者」：只吃已拼好的 margv + A2LaunchInput。
//
//  ★与 A2LaunchInput / A2JVMContext 的对齐★：
//    · 本类产出的是 **Java 侧**要吃的计划（mainClass/arguments/properties/classpath/nativeLibrary）；
//    · `jvmOptionsWithMemoryMB:` 产出的是 **VM 级** 选项（-X/-D），它们是 margv 里主类**之前**的 token，
//      由 Bridge 与 classpath 一起组成 argv，再交给 `a2_launch_jvm_with_argv(argc, argv, input)`；
//    · ★classpath 不在本类★：按 §3.4「路径只由一处拼装」，classpath 的唯一拼装点是
//      `Natives/Context/a2_resourcepaths.h` 的 `a2_paths_build_classpath`（Core 不能 import Natives）
//      ⇒ 由 Bridge 在组 argv 时调用它，并把它作为 `A2LaunchInput.librariesPath/lwjglDir/frontJar`
//      的同一份输入传下去（否则 a2_launch 的 classpath 对齐校验会判漂移并【阻断启动】）。
//

#import <Foundation/Foundation.h>

#import "A2LaunchRuntimeFacts.h"   // Utils —— ★运行时事实★（屏幕像素尺寸 / 系统最大帧率）

NS_ASSUME_NONNULL_BEGIN

/// 启动计划（schema=1）。字段与 JavaApp/src/launcher/dev/airdevs/air2/launch/A2LaunchPlan.java 一一对应。
@interface A2LaunchPlan : NSObject

/// 版本名（如 1.21.5 或 1.21.5-forge-52.0.1）。
@property (nonatomic, copy, readonly) NSString *versionID;
/// MC 主类（如 net.minecraft.client.main.Main）。
@property (nonatomic, copy, readonly) NSString *mainClass;
/// 已完全替换占位符的程序参数。
@property (nonatomic, copy, readonly) NSArray<NSString *> *arguments;
/// 需在 MC/LWJGL 类初始化【之前】落下的系统属性。
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *properties;
/// 显式 jar 列表（★无通配★ —— 展开的唯一实现是 native R4）。
@property (nonatomic, copy, readonly) NSArray<NSString *> *classpath;
/// JNI 符号宿主（主可执行文件绝对路径；空则 Java 侧跳过 System.load）。
@property (nonatomic, copy, readonly, nullable) NSString *nativeLibrary;
/// ★启动时的运行时事实★（屏幕像素尺寸 / 系统最大帧率）；nil = 调用方没提供。
///
/// 它是计划里唯一「非版本 JSON 语义」的一类取值 —— 来源是 UI 层事实
/// （见 `A2LaunchRunner.currentRuntimeFacts`；Core 不 import UIKit，故由调用方如实传入）。
/// 消费点：`jvmOptionsWithMemoryMB:` 把其中【已取到】的项落成 VM 级 `-D`
/// （复用线覆盖层 `GLFW.java:538/557` 的静态块会在装载 GLFW 类时直接读，
/// 所以必须走 `-D`，不能等 A2Entry 落属性）。
/// ★不进计划 JSON★：schema 保持 1，Java 侧的 `A2LaunchPlan.java` 不认识它
/// （读这两个值的是 JVM 本身，不是 Java 代码）。
@property (nonatomic, copy, readonly, nullable) A2LaunchRuntimeFacts *runtimeFacts;

/// 由【已合并 inheritsFrom】的版本 JSON 产出计划。
/// @param json         合并后的版本 JSON
/// @param versionID    版本名
/// @param account      账号取值：username / accessToken / uuid / userType（缺失键按空串）
/// @param gameDir      实例游戏目录（--gameDir / -Duser.dir）
/// @param assetsDir    assets 目录（--assetsDir）
/// @param librariesDir libraries 目录（classpath 里各 jar 的根）
/// @param versionJarPath 版本客户端 jar（`{versionPath}/{name}.jar`，可空）
/// @param runtimeFacts ★启动时运行时事实★（可空 ⇒ 两项 `-D` 都不下发；见属性注解）
+ (nullable instancetype)planFromVersionJSON:(NSDictionary *)json
                                   versionID:(NSString *)versionID
                                 accountDict:(NSDictionary<NSString *, NSString *> *)account
                                     gameDir:(NSString *)gameDir
                                   assetsDir:(NSString *)assetsDir
                                librariesDir:(NSString *)librariesDir
                              versionJarPath:(nullable NSString *)versionJarPath
                                runtimeFacts:(nullable A2LaunchRuntimeFacts *)runtimeFacts
                                       error:(NSError *_Nullable *_Nullable)error;

/// 便捷：从 `<versionDir>/<versionID>.json` 起，沿 inheritsFrom 合并后产出计划。
+ (nullable instancetype)planForVersionDirectory:(NSString *)versionDir
                                       versionID:(NSString *)versionID
                                     accountDict:(NSDictionary<NSString *, NSString *> *)account
                                         gameDir:(NSString *)gameDir
                                       assetsDir:(NSString *)assetsDir
                                    librariesDir:(NSString *)librariesDir
                                  versionJarPath:(nullable NSString *)versionJarPath
                                    runtimeFacts:(nullable A2LaunchRuntimeFacts *)runtimeFacts
                                           error:(NSError *_Nullable *_Nullable)error;

/// 沿 inheritsFrom 链合并版本 JSON（父在前、子覆盖；libraries 追加、arguments 追加）。
/// 最多 8 层（防环 + 防爆栈）。找不到根 json 或解析失败时返回 nil。
+ (nullable NSDictionary *)mergedVersionJSONFromDirectory:(NSString *)versionDir
                                                versionID:(NSString *)versionID
                                                    error:(NSError *_Nullable *_Nullable)error;

/// 计划的 JSON 表示（schema=1）。
- (NSDictionary *)JSONObject;
/// 原子写盘。
- (BOOL)writeToFile:(NSString *)path error:(NSError *_Nullable *_Nullable)error;

/// VM 级 JVM 选项（`-Xmx…` / `-D…`）—— ★不含 classpath★。
- (NSArray<NSString *> *)jvmOptionsWithMemoryMB:(NSInteger)memoryMB;
/// 程序参数（`--plan <path>`）。
- (NSArray<NSString *> *)programArgumentsWithPlanPath:(NSString *)planPath;

@end

NS_ASSUME_NONNULL_END
