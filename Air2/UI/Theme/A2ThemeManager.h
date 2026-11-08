//
//  A2ThemeManager.h
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
//  主题与外观的全局管理。
//
//  职责边界：
//    · 持有当前主题与外观模式
//    · 广播变更（视图订阅后重新取色）
//    · 管理自定义背景（图片/模糊/遮罩强度）
//  不负责：具体视图怎么画 —— 那是视图自己的事。
//

#import <UIKit/UIKit.h>
// A2ThemeManager 是主题层的聚合点：
// 所有取色的调用方只要能拿到 A2ThemeManager，就能拿到
// A2ColorScheme 与 A2ColorTheme 的类型定义。
// 因此下面这两个 import 是【故意】的 —— 视图层只需
// #import "A2ThemeManager.h" 即可使用全部主题类型。
#import "A2ColorTheme.h"
#import "A2ColorScheme.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2AppearanceMode) {
    A2AppearanceModeSystem = 0,  ///< 跟随系统
    A2AppearanceModeLight,       ///< 强制亮色
    A2AppearanceModeDark,        ///< 强制暗色
};

/// 主题变更通知。userInfo: @"theme" → A2ColorTheme
extern NSNotificationName const A2ThemeDidChangeNotification;
/// 背景变更通知（图片/模糊/遮罩）
extern NSNotificationName const A2BackgroundDidChangeNotification;

@interface A2ThemeManager : NSObject

+ (instancetype)shared;

#pragma mark - 主题

/// 当前主题（永不为 nil）
@property (nonatomic, strong, readonly) A2ColorTheme *theme;

/// 当前生效的语义色板 —— 【已按当前亮暗模式解析】。
///
/// 这里返回的是具体色值，不是动态颜色。视图在 applyTheme 里
/// 直接取用即可，不需要关心 trait 环境。
/// 每次 isDark 变化或主题切换后都会重新解析，并广播通知。
@property (nonatomic, strong, readonly) A2ColorScheme *scheme;

@property (nonatomic, assign) A2ThemeKind selectedKind;

/// 配色风格（对应 MD3 的 PaletteStyle）。
/// 影响从种子色推导色板的方式，不改变主题本身。
@property (nonatomic, assign) NSInteger paletteStyle;

/// 用户自定义的种子色。非 nil 时 selectedKind 视为「自定义」。
@property (nonatomic, strong, nullable) UIColor *customSeedColor;

#pragma mark - 自动种子色

/// 是否启用「自动获取种子色」。
/// 启用后：优先用自定义背景图取色；没有背景图就不允许开启（阿帅 2026-11-06 需求 ②）。
/// ★插件兼容★：插件应用自己的主题时，必须先调用 setAutoSeedEnabled:NO，
///   否则本开关会把插件主题覆盖掉（rebuildTheme 里 autoSeed 优先于 selectedKind）。
@property (nonatomic, assign, readonly, getter=isAutoSeedEnabled) BOOL autoSeedEnabled;

/// 开关自动种子色。@return NO = 当前没有可用种子图（无自定义背景），无法开启，保持原状。
/// ★不叫 setAutoSeedEnabled:★ setter 形式必须返回 void，否则编译器报 type of setter must be void。
- (BOOL)enableAutoSeed:(BOOL)enabled;

#pragma mark - 插件贡献的颜色主题

/// 当前生效的插件主题 token（token → `#RRGGBB`）。nil = 当前用的不是插件主题。
@property (nonatomic, copy, readonly, nullable) NSDictionary<NSString *, NSString *> *pluginThemeTokens;

/// 当前插件主题所属的插件 id；不是插件主题时为 nil。持久化，重启后仍是它。
@property (nonatomic, copy, readonly, nullable) NSString *pluginThemePluginId;

/// 应用「插件贡献的颜色主题」。
///
/// ★这是唯一入口★ 不要绕过去直接改 `selectedKind` / `customSeedColor`：
/// 本方法做三件事，缺任何一件插件主题都会被别的分支盖掉——
///   ① `enableAutoSeed:NO` —— 自动种子色在 rebuildTheme 里优先于一切；
///   ② 清掉手动种子色 —— `_customSeedColor` 分支同样优先，不清就永远显示旧种子色；
///   ③ 记下 token 并重建 + 持久化（重启后由 init 读回）。
///
/// @param pluginId 提供该主题的插件 id（展示与持久化用；空 ⇒ 直接忽略）
/// @param name     主题展示名（一般是插件 manifest 的 `name`）
/// @param tokens   该插件的 `themeTokens`（非空；空 ⇒ 直接忽略）
- (void)applyPluginThemeFromPlugin:(NSString *)pluginId
                              name:(nullable NSString *)name
                            tokens:(NSDictionary<NSString *, NSString *> *)tokens;

#pragma mark - 外观

@property (nonatomic, assign) A2AppearanceMode appearanceMode;

/// 当前是否为暗色（综合系统与用户设置）
@property (nonatomic, assign, readonly, getter=isDark) BOOL dark;

/// 应用到窗口
- (void)applyAppearanceToWindow:(UIWindow *)window;

#pragma mark - 自定义背景

/// 用户设置的背景图。nil 表示使用主题渐变。
@property (nonatomic, strong, nullable) UIImage *backgroundImage;

/// 背景模糊强度 0~100
@property (nonatomic, assign) NSInteger backgroundBlur;

/// 背景图在暗色模式下的遮罩强度 0.0~1.0，默认 0.28
@property (nonatomic, assign) CGFloat backgroundDarkOverlay;

/// 操作栏一侧的渐隐遮罩宽度比例 0.0~1.0，默认 0.35
/// 作用：用户可能选一张花哨的图，右侧卡片需要稳定的对比度才看得清
@property (nonatomic, assign) CGFloat backgroundFadeRatio;

/// 持久化背景图（存到沙盒，返回是否成功）
- (BOOL)persistBackgroundImage:(UIImage *)image;
/// 从沙盒读取已保存的背景图
- (nullable UIImage *)loadPersistedBackground;
/// 清除自定义背景
- (void)clearBackgroundImage;

#pragma mark - 广播

- (void)notifyThemeChanged;
- (void)notifyBackgroundChanged;

@end

NS_ASSUME_NONNULL_END
