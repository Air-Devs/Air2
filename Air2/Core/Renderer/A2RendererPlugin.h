//
//  A2RendererPlugin.h
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
//  A2RendererPlugin.h
//  Air2
//
//  渲染器插件 —— 从 zip 导入、解析、校验。
//
//  设计目标：导入一个 .air2plugin（zip）后，渲染器自动出现在
//  「设置 → 渲染 → 渲染器插件」里，不需要重启、不需要改代码。
//
//  与 FCL 的关系：
//    FCL 的插件是独立 APK，Android 可以扫描已安装应用来发现。
//    iOS 没有这个概念（沙箱 + 代码签名），所以改成「导入 zip」。
//    但 manifest 的 env 部分【完全兼容 FCL 的 v2 格式】——
//    渲染器作者的配置可以基本复用，只需把 .so 重编成 .dylib。
//
//  ⚠️ iOS 的签名限制：
//    导入的 dylib 只有在 TrollStore / 越狱环境下才能直接 dlopen。
//    正常签名环境下会返回 "code signature invalid" ——
//    我们仍然允许导入并列出，但标记为不可用并给出准确原因，
//    而不是让用户面对一个静默失败的选项。
//
//  ★职责边界（三处不交叉，避免第二套真相源）★：
//    · 本类 = manifest → 值对象 + **静态**校验（不碰 zip、不装文件）；
//    · `A2RendererImporter` = 解压 → 校验 → **原子安装** / 卸载；
//    · `A2RendererCatalog`（既有，本单不改它）= 「可选哪些后端」的候选表。
//      本类**不往候选表里塞导入项**：启动链只从 `<App>/Frameworks/` 加载
//      （见 `Natives/Renderer/a2_renderer.h`），装到 Documents 的库在签名
//      环境里根本加载不了 —— 列进选择器就是「选了必定失败」的假选项。
//

#import <Foundation/Foundation.h>
#import "A2RendererLibraryLayout.h"

NS_ASSUME_NONNULL_BEGIN

/// 渲染器可用状态
typedef NS_ENUM(NSInteger, A2RendererAvailability) {
    A2RendererAvailabilityUnknown = 0,
    A2RendererAvailabilityAvailable,      ///< 文件与导出符号齐备（能否 dlopen 要到启动时才知道）
    A2RendererAvailabilityMissingLib,     ///< 文件不存在 / 不是普通文件
    A2RendererAvailabilitySignatureInvalid,///< 代码签名无效（正常签名环境）
    A2RendererAvailabilityArchitectureMismatch, ///< 架构不匹配（x86 / Android .so 等）
    A2RendererAvailabilityMissingDependency,    ///< 缺依赖库 / 缺导出符号
};

#pragma mark - 环境变量配置项

/// 环境变量的类型（对应 FCL v2 的四种 EnvV2）
typedef NS_ENUM(NSInteger, A2RendererEnvType) {
    A2RendererEnvTypeNormal = 0,      ///< 固定值，用户不可改
    A2RendererEnvTypeToggleable,      ///< 开关
    A2RendererEnvTypeSelectable,      ///< 单选
    A2RendererEnvTypeCustomizable,    ///< 自由输入
};

@interface A2RendererEnvSpec : NSObject
@property (nonatomic, assign) A2RendererEnvType type;
@property (nonatomic, copy) NSString *key;
/// NormalEnv 的固定值 / ToggleableEnv 打开时的值
@property (nonatomic, copy, nullable) NSString *value;
/// 显示标题（Toggleable / Selectable / Customizable 用）
@property (nonatomic, copy, nullable) NSString *title;
/// Toggleable：默认是否开启
@property (nonatomic, assign) BOOL defaultOn;
/// Selectable：默认选中项
@property (nonatomic, copy, nullable) NSString *defaultValue;
/// Selectable：可选值列表 [{value, label}]
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *selectableValues;
/// Customizable：默认值
@property (nonatomic, copy, nullable) NSString *customDefault;

/// 从 manifest 的 env 条目构造（类型不认识 ⇒ 按 NormalEnv，与 FCL 语义一致）。
/// `key` 为空返回 nil —— 没有 key 的环境变量没有意义。
///
/// ★本单只解析、不应用★：启动链（`A2LaunchSession` / `a2_renderer`）不消费渲染器的
/// 环境变量，「按用户设置算出要 setenv 什么」这一步等真正有加载器时再做 ——
/// 现在写一个没有调用点的解析函数就是死代码。
+ (nullable instancetype)specWithJSON:(NSDictionary *)json;
@end

#pragma mark - 渲染器插件

@interface A2RendererPlugin : NSObject

// ---- manifest 字段 ----
@property (nonatomic, assign) NSInteger formatVersion;
@property (nonatomic, copy) NSString *rendererID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *pluginDescription;
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic, copy, nullable) NSString *author;
/// 作者自述的主页。★只解析、不展示★：列表已经三行，再塞一条链接更乱；
/// 字段按 spec 收下（将来插件详情页要用），本版不校验格式、不联网。
@property (nonatomic, copy, nullable) NSString *homepage;

/// 库的布局形态。manifest 里用 "libraryLayout" 字段声明：
///   "combined"  —— GL 与 EGL 在同一个 dylib（MobileGlues / NG-GL4ES）
///   "separate"  —— 两个独立 dylib（Zink / VirGL）
///   "glOnly"    —— 只有 GL
/// 缺省时自动推断：eglPath 为空或等于 glPath → combined，否则 separate。
@property (nonatomic, assign) A2RendererLibraryLayout libraryLayout;

@property (nonatomic, copy) NSString *rendererGLPath;   ///< 相对包根
/// EGL 库。libraryLayout 为 combined 时可留空（表示与 GL 同一个文件）。
@property (nonatomic, copy) NSString *rendererEGLPath;
@property (nonatomic, copy) NSArray<NSString *> *dlopenLibPaths;
@property (nonatomic, copy, nullable) NSString *minMCVer;
@property (nonatomic, copy, nullable) NSString *maxMCVer;
@property (nonatomic, copy) NSArray<A2RendererEnvSpec *> *envSpecs;

// ---- iOS 扩展 ----
@property (nonatomic, copy, nullable) NSString *minSystemVersion;
@property (nonatomic, assign) BOOL requiresJIT;
@property (nonatomic, copy, nullable) NSString *iosNotes;

// ---- 运行时状态 ----
/// 插件解压后的目录
@property (nonatomic, copy, readonly) NSString *installPath;
/// 是否可用
@property (nonatomic, assign, readonly) A2RendererAvailability availability;
/// 不可用原因（给用户看的人话）
@property (nonatomic, copy, nullable, readonly) NSString *unavailableReason;
/// 图标路径（可选）
@property (nonatomic, copy, nullable, readonly) NSString *iconPath;
/// 是否为用户导入（NO = 内置；内置不可卸载）
@property (nonatomic, assign, readonly, getter=isImported) BOOL imported;
/// 来源文件名（安装记录里的事实：「这个插件是从哪个文件装的」）
@property (nonatomic, copy, nullable, readonly) NSString *sourceFileName;

/// GL / EGL 库的绝对路径（该布局不需要时为 nil / 空串）
@property (nonatomic, copy, readonly) NSString *absoluteGLPath;
@property (nonatomic, copy, nullable, readonly) NSString *absoluteEGLPath;

/// 从 manifest JSON 构造并做**静态校验**（不读磁盘文件）。
///
/// 严格程度按 `docs/RENDERER_PLUGIN_SPEC.md` 3.1：
///   · 必填：formatVersion == 1 / rendererId / displayName / rendererGLPath；
///   · `libraryLayout` 为 separate 时 rendererEGLPath 必填；
///   · 所有库路径必须是**包内相对路径**（拒绝绝对路径、`..`、反斜杠、控制字符）；
///   · rendererId 必须是安全目录名（`[A-Za-z0-9._-]`，不以 `.` 开头，≤64 字符）。
///
/// @param error 失败时填**给人看的具体原因**（不是「格式不正确」这种空话）
+ (nullable instancetype)pluginWithManifest:(NSDictionary *)json
                                installPath:(NSString *)installPath
                                      error:(NSString * _Nullable * _Nullable)error;

/// 同上，不要原因（只想快速判断「这个目录里是不是一个能用的插件」时用）。
+ (nullable instancetype)pluginWithManifest:(NSDictionary *)json
                                installPath:(NSString *)installPath;

/// 用已落盘的安装记录（`install.json` 的 `sourceFileName`）补齐来源名。
/// 只在导入器扫描安装目录时调用；没有记录时是 no-op。
- (void)attachSourceFileName:(nullable NSString *)sourceFileName;

/// 校验磁盘上的文件并更新 availability / unavailableReason（顺带填 iconPath）。
/// ★不 dlopen★（理由见实现里的注释）。
- (void)validate;

#pragma mark - 静态校验工具（导入器与 validate 共用同一份实现）

/// 是否是「包内相对路径」，且没有目录穿越。
///
/// 拒绝：空串、绝对路径（`/` 开头）、反斜杠（zip 里两种分隔符都可能出现）、
/// 任何 `..` 段、`.` 段、空段（`a//b`）、控制字符、结尾的点或空格。
/// ★这是唯一的路径判据★：zip 条目校验与 manifest 库路径校验都调它，
/// 不许各处各写一份（写两份必然有一天只改一处）。
+ (BOOL)isSafePackageRelativePath:(NSString *)path;

/// 是否是安全目录名。rendererId 会直接当目录名用，必须先过这一关 ——
/// 否则 `rendererId: "../../Library"` 就能把文件写出插件目录。
+ (BOOL)isSafeRendererID:(NSString *)rendererID;

/// 是否为 iOS 能加载的 dylib：Mach-O（thin 或含 arm64 切片的 fat）、
/// CPU 类型 arm64、`filetype = MH_DYLIB`。
///
/// 提前查的理由：x86 库或 Android 的 .so 在 dlopen 时只会给一句含糊的
/// "not a mach-o file"，用户不知道是「拿错了平台的文件」。
+ (BOOL)isIOSArm64DylibAtPath:(NSString *)path error:(NSString * _Nullable * _Nullable)error;

/// 检查 Mach-O 是否**导出**指定符号 —— 纯静态，不执行任何库代码。
///
/// ⚠️ 不要用 dlopen 做"能否加载"的探测：
///   dlopen 会执行库的 constructor，而 GL 库的 constructor
///   通常假设 EGL 上下文已就绪 —— 探测阶段没有那个环境，
///   会直接 SIGSEGV。（实测：导入 MobileGlues 崩在 init_target_egl）
+ (BOOL)machO:(NSString *)path
    exportsSymbol:(const char *)symbolName
          missing:(NSString * _Nullable * _Nullable)missing;

@end

NS_ASSUME_NONNULL_END
