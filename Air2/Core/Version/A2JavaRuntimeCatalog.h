//
//  A2JavaRuntimeCatalog.h
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
//  Core/Version —— ★「有哪些 Java 运行时可被选中」的唯一真相源★（候选表 + 可用性判定）。
//
//  目录约定（与 `Natives/Context/a2_vmloader.m` 的解析口径一致）：
//      `<App>/java_runtimes/<目录名>/lib/server/libjvm.dylib`
//  候选目录名与老线同一血统（本机 Amethyst 构建产物 b12 artifacts 的 `java_runtimes/`）：
//      java-8-openjdk / java-17-openjdk / java-21-openjdk / java-25-openjdk
//
//  ★调用点★：
//    · `Air2/UI/Screens/Settings/A2RuntimeSettings.m`（Java 运行时行的候选表 + 「未内置」标记）
//    · `Air2/Player/A2LaunchSession.m`（解析用户选择 ⇒ 产出 `javaHome`，交给启动计划）
//
//  ★显示名的语言归属★：展示文案在 Player 的四语表 `A2RuntimeStrings`（Core 在 Player 之下，
//  不能反向依赖）⇒ 本类只给**稳定的文案 key**。缺 key 时 UI 回退到目录名（技术名）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2JavaRuntimeCatalog : NSObject

/// 随包的运行时根目录名（`<App>/java_runtimes`）。
+ (NSString *)javaRuntimesDirectoryName;

/// 全部候选目录名（★稳定顺序：新 → 旧★：25 / 21 / 17 / 8）。
+ (NSArray<NSString *> *)allDirectoryNames;

/// 主推目录名（默认项）。★默认项要合理★：取候选表首（最新的那一档）。
+ (NSString *)defaultDirectoryName;

/// 目录名 → major（`java-25-openjdk` → 25）；不是本表认识的形态返回 0（不猜）。
+ (NSInteger)majorVersionForDirectoryName:(NSString *)directoryName;

/// 目录名 → 展示名四语文案 key（`java-25-openjdk` → `runtime.jre.25`）。
+ (NSString *)nameLocalizationKeyForDirectoryName:(NSString *)directoryName;

/// major → 「适合哪些 MC 版本」的四语文案 key（未知 major 返回 `runtime.jre.mc.unknown`）。
+ (NSString *)mcRangeLocalizationKeyForMajorVersion:(NSInteger)majorVersion;

/// 该目录是否是**可用的**运行时根：`<javaHome>/lib/server/libjvm.dylib` 存在
/// （= `a2_vmloader` 的首选布局，也是 `scripts/stage_runtime.sh` 的自证条件）。
/// javaHome 为空 ⇒ NO（未内置/不完整，不猜）。
+ (BOOL)isUsableJavaHome:(nullable NSString *)javaHome;

@end

NS_ASSUME_NONNULL_END
