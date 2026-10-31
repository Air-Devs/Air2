//
//  A2RendererCatalog.h
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
//  Core/Renderer —— ★「有哪些渲染后端可被选中」的唯一真相源★（候选表 + 包内可用性）。
//
//  职责边界（与既有两件不重叠）：
//    · 本类 = **静态候选表 + 包内存在性判定**（纯数据 + 一次 fileExistsAtPath，无 UIKit、无 dlopen）；
//    · `A2Renderers`（同目录，既有）= **注册表 + 标识解析**（去重 / 版本级覆盖 > 全局 > 首个）；
//      本类把候选登记进去，而不是另造一套解析（★不重复造轮子★）；
//    · `Natives/Renderer/a2_renderer.*` = **真正 dlopen 的地方**（那一步只能在 Natives）。
//
//  标识 = **dylib 文件名**（与老线 `runtime_native/Natives/utils.h` 的 `RENDERER_NAME_*`
//  逐字同表；取值即 `A2SelectedRendererPrefKey` 存进 NSUserDefaults 的值）。
//
//  ★调用点★：
//    · `Air2/UI/Screens/Settings/A2RuntimeSettings.m`（渲染器行的候选表 + 「未内置」标记）
//    · `Air2/Player/A2LaunchSession.m`（解析用户选择 ⇒ 交给 Bridge 的 dylib 名 / 阻断判据）
//
//  ★显示名的语言归属★：候选的**展示文案**放 Player 的四语表 `A2RuntimeStrings`
//  （Core 在 Player 之下，不能反向依赖）⇒ 本类只给**稳定的文案 key**，
//  由 UI 侧 `A2RuntimeStrings stringForKey:` 取词。缺 key 时 UI 回退到 `identifier`（技术名）。
//

#import <Foundation/Foundation.h>

#import "A2Renderer.h"

NS_ASSUME_NONNULL_BEGIN

/// 候选档位（用于 UI 分组与排序，也用于报告里区分「主推 / 兼容底 / 实验」）。
typedef NS_ENUM(NSInteger, A2RendererTier) {
    A2RendererTierRecommended = 0,  ///< ★主推★（自研 Metal）
    A2RendererTierCompat      = 1,  ///< ★兼容底★（老版本 MC 的转译层）
    A2RendererTierExperimental= 2,  ///< 实验 / 尚未内置（保留入口，选中会如实阻断）
};

/// ★渲染后端的 GL 能力等级★（静态元数据，判据用；不代表包内是否内置 —— 那是 `+isBundled:`）。
///
/// 为什么要有它：`isBundled` 只能回答「文件在不在」，答不了「这个后端能不能当 GL 用」。
/// 两条静态失败组合正是照着这个缺口生成的：
///   · MoltenVK 是 **Vulkan ICD**（无 EGL / 无 `gl*` 导出）⇒ 被当成 GL 库下发必崩；
///   · gl4es 家族的上限是 **GL 2.x 固定管线** ⇒ 接不了 1.13+（要求 GL 3.2 core）。
typedef NS_ENUM(NSInteger, A2RendererGLClass) {
    A2RendererGLClassNotGL     = -1,  ///< 不是 GL 后端（Vulkan 直通：MoltenVK）⇒ 启动链不得下发 `opengl.libname`
    A2RendererGLClassFixedOnly = 0,   ///< GL 1.x/2.x 固定管线翻译层（gl4es 家族）⇒ 只接 1.12.2 及更早
    A2RendererGLClassModern    = 1,   ///< GL 3.2+ / Metal 直通（metallum / mobileglues）⇒ 1.13+ 及 26.x
};

@interface A2RendererCatalog : NSObject

/// ★固定管线首选后端（NG-GL4ES / KW）的标识★ = dylib 文件名。
///
/// 它是 `-DDEFAULT_ES=3 -DNOEGL -DNO_INIT_CONSTRUCTOR` 编出来的 gl4es 变体（Krypton Wrapper），
/// 与老线 `libgl4es_114.dylib` 是**两支二进制**，不能互相替代：
///   · 老线那只在 dlopen 时自带 constructor 初始化（`initialize_gl4es()` 由它自己调）；
///   · 这一只的 constructor 被 `NO_INIT_CONSTRUCTOR` 关掉 ⇒ ★宿主必须在游戏 context
///     成为 current 之后显式调 `initialize_gl4es()`★，漏掉不崩但黑屏（见 `Natives/Renderer/a2_gl_bridge.m` ⑥a）。
/// 为什么常量放 Core：≤1.12 的「默认项」与「不可用时的回退判据」都在 Player 的启动会话里，
/// 而清单登记在本类 ⇒ 三处必须同一份字面量（否则改一处忘一处就是石山）。
extern NSString *const A2RendererNGGL4ESKWDylibName;

/// ★宿主 EGL 后端（系统 GLES 3.0 / EAGL）的标识★ = `libeagl.dylib`。
///
/// 它**不是**一个包内的 dylib：整层 EGL（`Natives/Renderer/a2_eagl_egl.m` 的假 EGL 1.4 子集）
/// 就编在主二进制里，`eglCreateWindowSurface` 落到 CAEAGLLayer + `presentRenderbuffer:`。
/// 标识的后半段（`mobileglues` = GL 层）说明它怎么接：
///   · EGL 层 = 本二进制（宿主提供）⇒ 不需要 `Frameworks/libeagl.dylib` 这个文件；
///   · GL 层 = MobileGlues（`-Dorg.lwjgl.opengl.libname=mobileglues`），由它把 MC 的 GL 3.2+
///     调用翻译到宿主的 GLES 3.0 上。
/// ⇒ `+isBundled:` 对它判的是「GL 层在不在」（见实现里的说明），不判这个不存在的文件。
/// ★为什么常量放 Core★：默认值（Player 的 `A2DefaultRendererForVersion`）、候选表、
/// 阻断判据三处必须同一份字面量（同 `A2RendererNGGL4ESKWDylibName` 的理由）。
extern NSString *const A2RendererHostEGLDylibName;

/// 全部候选（★稳定顺序★：主推 → 兼容底 → 实验）。
/// 每一项的 `identifier` = dylib 文件名，`displayName` = 技术名（回退用），`dylibName` = 同名。
+ (NSArray<A2Renderer *> *)allCandidates;

/// 主推候选（默认项）。
+ (A2Renderer *)defaultCandidate;

/// 按标识取候选；未登记返回 nil。
+ (nullable A2Renderer *)candidateForIdentifier:(NSString *)identifier;

/// 档位（未登记的标识按「实验」处理，不猜成主推）。
+ (A2RendererTier)tierForIdentifier:(NSString *)identifier;

/// 档位 / 展示名的四语文案 key（交给 Player 的 A2RuntimeStrings 取词；本类不取词）。
+ (NSString *)tierLocalizationKeyForTier:(A2RendererTier)tier;
+ (NSString *)nameLocalizationKeyForIdentifier:(NSString *)identifier;

/// 该后端的 GL 能力等级（静态元数据；未登记的标识按「not GL」处理，不猜成可用）。
+ (A2RendererGLClass)glClassForIdentifier:(NSString *)identifier;

/// 该后端在某版本上**要求的 JRE 下限**（major）。返回 0 = 本判据不覆盖该组合（不猜）。
/// 判据来自 `metallum_agent.jar` 的类集主版本（实测）：
///   · `classes261/262/263` = 69（Java 25）⇒ 26.x 需要 java-25；
///   · `classes12111_1_21_11` = 65（Java 21）+ agent 本体 65 ⇒ 1.21.11 至少 java-21。
/// 其它版本没有对应类集 ⇒ 由「metallum 类集覆盖」告警处理，这里返回 0 不重复判。
+ (NSInteger)requiredJavaMajorForIdentifier:(NSString *)identifier
                                  versionID:(NSString *)versionID
                                    mcMajor:(NSInteger)mcMajor
                                    mcMinor:(NSInteger)mcMinor;

/// ★内置判定诊断★：nil = 已内置（文件在 **且** 能 dlopen）；否则为可读原因
/// （「缺文件」/「dlopen 失败：<dlerror>」）。给阻断文案用，避免只说「未内置」。
+ (nullable NSString *)bundleDiagnosisForCandidate:(A2Renderer *)candidate
                                    frameworksPath:(nullable NSString *)frameworksPath;

/// 包内是否已内置该渲染后端 —— ★文件存在 **且** 能 dlopen 成功★才算内置。
/// 只用 `fileExistsAtPath` 会把「文件在但依赖缺失/架构不符」判成内置（实测 GL4ES 依赖
/// `@rpath/libEGL.framework`，只拷它一个就会 dlopen 失败）⇒ 闸门形同虚设。
/// frameworksPath 为空 ⇒ NO（未内置，不猜）。
+ (BOOL)isBundled:(A2Renderer *)candidate frameworksPath:(nullable NSString *)frameworksPath;

/// 把全部候选登记进既有注册表（幂等：已登记的返回 NO 不影响结果）。
+ (void)registerAllCandidatesIntoRegistry:(A2Renderers *)registry;

@end

NS_ASSUME_NONNULL_END
