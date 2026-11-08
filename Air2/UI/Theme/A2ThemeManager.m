//
//  A2ThemeManager.m
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

#import "A2ThemeManager.h"
#import "A2Log.h"

NSNotificationName const A2ThemeDidChangeNotification = @"A2ThemeDidChangeNotification";
NSNotificationName const A2BackgroundDidChangeNotification = @"A2BackgroundDidChangeNotification";

static NSString *const kKeyThemeKind   = @"A2ThemeKind";
static NSString *const kKeyAppearance  = @"A2AppearanceMode";
static NSString *const kKeyBgBlur      = @"A2BackgroundBlur";
static NSString *const kKeyBgOverlay   = @"A2BackgroundDarkOverlay";
static NSString *const kKeyBgFade      = @"A2BackgroundFadeRatio";
static NSString *const kKeyPaletteStyle = @"A2PaletteStyle";
static NSString *const kKeyCustomSeed  = @"A2CustomSeedColor";
static NSString *const kBackgroundFileName = @"air2_background.jpg";

/// 自动种子色的持久化键（只在 A2ThemeManager 内读写，不进 A2Settings 的配置表）
static NSString *const kA2ThemeAutoSeedKey = @"A2ThemeAutoSeed";

/// 插件主题的持久化键：三者同时存在才算「当前是插件主题」。
/// 存 token 而不是只存插件 id —— 重启时不必依赖插件系统是否已经装配完成，
/// 也不会出现「插件被禁用后启动直接掉回预设、用户以为设置丢了」的观感差异。
static NSString *const kKeyPluginThemeId     = @"A2PluginThemePluginId";
static NSString *const kKeyPluginThemeName   = @"A2PluginThemeName";
static NSString *const kKeyPluginThemeTokens = @"A2PluginThemeTokens";

@implementation A2ThemeManager {
    A2ColorTheme *_theme;
    UIImage *_backgroundImage;
    // 按模式解析后的色板缓存
    A2ColorScheme *_resolvedScheme;
    BOOL _resolvedIsDark;
    // 插件贡献的颜色主题（见 applyPluginThemeFromPlugin:name:tokens:）
    NSDictionary<NSString *, NSString *> *_pluginThemeTokens;
    NSString *_pluginThemePluginId;
    NSString *_pluginThemeName;
}

+ (instancetype)shared {
    static A2ThemeManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2ThemeManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;

    _backgroundBlur = [d objectForKey:kKeyBgBlur] ? [d integerForKey:kKeyBgBlur] : 24;
    _backgroundDarkOverlay = [d objectForKey:kKeyBgOverlay] ? [d doubleForKey:kKeyBgOverlay] : 0.28;
    _backgroundFadeRatio = [d objectForKey:kKeyBgFade] ? [d doubleForKey:kKeyBgFade] : 0.35;
    _appearanceMode = (A2AppearanceMode)[d integerForKey:kKeyAppearance];

    // 新用户默认冰川蓝（清爽取向；已存选择不受影响，只改缺省）。
    NSInteger kind = [d objectForKey:kKeyThemeKind] ? [d integerForKey:kKeyThemeKind] : A2ThemeKindGlacier;
    if (kind < 0 || kind >= A2ThemeKindCount) kind = A2ThemeKindGlacier;
    _selectedKind = (A2ThemeKind)kind;

    _paletteStyle = [d objectForKey:kKeyPaletteStyle] ? [d integerForKey:kKeyPaletteStyle] : 0;
    NSInteger seedRGB = [d objectForKey:kKeyCustomSeed] ? [d integerForKey:kKeyCustomSeed] : -1;
    if (seedRGB >= 0) {
        _customSeedColor = A2Hex((uint32_t)seedRGB);
    }

    _backgroundImage = [self loadPersistedBackground];
    // ★自动种子色：读回上次的开关；但没有背景图时一律视为关闭（需求②）★
    _autoSeedEnabled = _backgroundImage != nil
        && [NSUserDefaults.standardUserDefaults boolForKey:kA2ThemeAutoSeedKey];

    // 插件主题：只有 token 非空才算有效状态（id / 名字只用于展示，缺了不影响生效）
    NSDictionary *pluginTokens = [d dictionaryForKey:kKeyPluginThemeTokens];
    if ([pluginTokens isKindOfClass:NSDictionary.class] && pluginTokens.count > 0) {
        _pluginThemeTokens = [pluginTokens copy];
        _pluginThemePluginId = [d stringForKey:kKeyPluginThemeId];
        _pluginThemeName = [d stringForKey:kKeyPluginThemeName];
    }

    [self rebuildTheme];

    return self;
}

#pragma mark - 主题

- (A2ColorTheme *)theme {
    return _theme;
}

- (A2ColorScheme *)scheme {
    // 缓存：同一模式下反复取色不应重复创建对象。
    // isDark / theme 变化时清掉缓存。
    if (!_resolvedScheme || _resolvedIsDark != self.isDark) {
        _resolvedScheme = [_theme.scheme resolvedForDark:self.isDark];
        _resolvedIsDark = self.isDark;
    }
    return _resolvedScheme;
}

- (void)setSelectedKind:(A2ThemeKind)selectedKind {
    if (selectedKind < 0 || selectedKind >= A2ThemeKindCount) return;
    if (_selectedKind == selectedKind) return;

    _selectedKind = selectedKind;
    // 用户自己换主题 ⇒ 插件主题让位（否则界面上写着「冰川蓝」，实际还是插件色板）
    [self a2_dropPluginTheme];
    [self rebuildTheme];
    _resolvedScheme = nil;      // 主题变了，解析缓存失效
    [self persist];
    [self notifyThemeChanged];
}

/// 依据当前种类重建主题对象
- (void)rebuildTheme {
    // ★插件主题优先★ 它是一整套显式色板（作者给了哪个角色就用哪个），
    // 不该再被种子色 / 自动取色重新推导一遍。没有插件主题时下面的路径与以前完全一致。
    if (_pluginThemeTokens.count > 0) {
        NSString *displayName = _pluginThemeName.length > 0 ? _pluginThemeName : @"插件主题";
        NSString *desc = _pluginThemePluginId.length > 0
            ? [NSString stringWithFormat:@"由插件 %@ 提供", _pluginThemePluginId]
            : @"由插件提供";
        _theme = [A2ColorTheme themeWithPluginTokens:_pluginThemeTokens
                                                name:displayName
                                                desc:desc
                                                base:[self a2_userTheme]];
        return;
    }
    _theme = [self a2_userTheme];
}

/// 用户自己那套主题：手动种子色 → 自动种子色 → 预设种类（原 rebuildTheme 的全部逻辑，
/// 一字未改）。插件主题只用它当「插件没声明的字段」的回落基线，不参与别的判定。
- (A2ColorTheme *)a2_userTheme {
    // 自定义种子色优先：用户在大色盘里选的颜色会覆盖主题预设
    if (_customSeedColor) {
        return [A2ColorTheme themeWithSeedColor:_customSeedColor
                                   paletteStyle:_paletteStyle
                                           name:@"自定义"
                                           desc:@"从色盘选取的种子色"];
    }

    // ★自动种子色★ 有背景图就直接从图取色（优先于"用户手动选了 Dynamic"）
    if (_autoSeedEnabled && _backgroundImage) {
        return [A2ColorTheme themeFromImage:_backgroundImage];
    }

    if (_selectedKind == A2ThemeKindDynamic && _backgroundImage) {
        return [A2ColorTheme themeFromImage:_backgroundImage];
    }
    if (_selectedKind == A2ThemeKindDynamic) {
        // 选了动态取色但还没设背景图，回退到默认主题，避免界面出现随机配色
        return [A2ColorTheme themeForKind:A2ThemeKindGlacier];
    }
    return [A2ColorTheme themeForKind:_selectedKind];
}

#pragma mark - 插件贡献的颜色主题

/// 只清状态，不重建 / 不持久化 / 不广播 —— 调用方（各个 setter）紧接着会自己做这三件事。
- (void)a2_dropPluginTheme {
    if (_pluginThemeTokens.count == 0) return;
    _pluginThemeTokens = nil;
    _pluginThemePluginId = nil;
    _pluginThemeName = nil;
    [A2Log criterion:@"[A2-PLUGIN-UI] 颜色主题 已退出插件主题（用户改用种子色 / 自动取色 / 预设）"];
}

- (void)applyPluginThemeFromPlugin:(NSString *)pluginId
                              name:(nullable NSString *)name
                            tokens:(NSDictionary<NSString *, NSString *> *)tokens {
    if (pluginId.length == 0 || tokens.count == 0) return;

    // ① 自动种子色在 rebuildTheme 里优先于一切：不关掉，插件色板一重建就被背景图取色顶掉。
    (void)[self enableAutoSeed:NO];
    // ② 手动种子色同样优先（走的是 ivar 而不是 setter：setter 会连带广播/持久化一次，
    //    而下面本来就要统一 persist + notify，避免一个动作广播两遍）。
    _customSeedColor = nil;
    // ③ 记下这套 token，之后 rebuildTheme 走插件分支
    _pluginThemePluginId = [pluginId copy];
    _pluginThemeName = [name copy];
    _pluginThemeTokens = [tokens copy];

    [self rebuildTheme];
    _resolvedScheme = nil;
    [self persist];
    [self notifyThemeChanged];

    [A2Log criterion:@"[A2-PLUGIN-UI] 颜色主题 已切换为插件主题：%@（%lu 色）",
     pluginId, (unsigned long)tokens.count];
}

#pragma mark - 外观

/// 当前是否暗色。
///
/// 注意不能用 UITraitCollection.currentTraitCollection ——
/// 它返回的是「当前线程的 trait 环境」，在布局、后台回调等上下文里
/// 会退化成默认值（表现为亮色主题下卡片却取了暗色 surface）。
/// 正确做法是从窗口的 traitCollection 取，它反映真实的界面外观。
- (BOOL)isDark {
    switch (_appearanceMode) {
        case A2AppearanceModeLight: return NO;
        case A2AppearanceModeDark:  return YES;
        case A2AppearanceModeSystem:
        default:
            return [self resolveSystemDark];
    }
}

- (BOOL)resolveSystemDark {
    // 优先用窗口（最可靠）
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) {
                return w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
            }
        }
    }
    // 退化：取任意窗口
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindow *w = ((UIWindowScene *)scene).windows.firstObject;
        if (w) return w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

- (void)setPaletteStyle:(NSInteger)paletteStyle {
    if (_paletteStyle == paletteStyle) return;
    _paletteStyle = paletteStyle;
    if (_customSeedColor) [self rebuildTheme];
    _resolvedScheme = nil;
    [self persist];
    [self notifyThemeChanged];
}

- (void)setCustomSeedColor:(UIColor *)customSeedColor {
    _customSeedColor = customSeedColor;
    // 用户从色盘选了种子色 ⇒ 插件主题让位（种子色是更明确的意图）
    if (customSeedColor) [self a2_dropPluginTheme];
    [self rebuildTheme];
    _resolvedScheme = nil;
    [self persist];
    [self notifyThemeChanged];
}

- (void)setAppearanceMode:(A2AppearanceMode)appearanceMode {
    if (_appearanceMode == appearanceMode) return;
    _appearanceMode = appearanceMode;
    [self persist];
    [self notifyThemeChanged];
}

- (void)applyAppearanceToWindow:(UIWindow *)window {
    if (!window) return;
    switch (_appearanceMode) {
        case A2AppearanceModeLight:
            window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
            break;
        case A2AppearanceModeDark:
            window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            break;
        case A2AppearanceModeSystem:
            window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
            break;
    }
    window.tintColor = _theme.lightPrimary;
}

#pragma mark - 自定义背景

- (BOOL)enableAutoSeed:(BOOL)enabled {
    if (enabled && _backgroundImage == nil) return NO;   // 需求②：没有种子图就不许开
    if (enabled) {
        // 需求②：有图也要真能取到种子色 —— themeFromImage 失败时会回落 Glacier，
        // 用它当判据（kind != Dynamic ⇒ 取色失败 ⇒ 不允许开启，保持主题色）。
        A2ColorTheme *candidate = [A2ColorTheme themeFromImage:_backgroundImage];
        if (candidate.kind != A2ThemeKindDynamic) return NO;
    }
    _autoSeedEnabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kA2ThemeAutoSeedKey];
    if (enabled) {
        // 自动取色接管：手动种子色让位，否则 rebuildTheme 会一直用自定义色
        _customSeedColor = nil;
        _selectedKind = A2ThemeKindDynamic;
        // 同理，插件主题也让位：自动取色是用户此刻的显式选择
        [self a2_dropPluginTheme];
    }
    [self rebuildTheme];
    [self notifyThemeChanged];
    return YES;
}

- (void)setBackgroundImage:(UIImage *)image {
    _backgroundImage = image;
    // 背景图没了且开着自动取色 ⇒ 自动关掉（需求②：取不到就回主题色，不留半生效状态）
    if (image == nil && _autoSeedEnabled) {
        _autoSeedEnabled = NO;
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:kA2ThemeAutoSeedKey];
        _selectedKind = A2ThemeKindGlacier;
        [self rebuildTheme];
        [self notifyThemeChanged];
        [self notifyBackgroundChanged];
        return;
    }
    // 动态/自动取色都依赖背景图，换了图要重算
    if (_selectedKind == A2ThemeKindDynamic || _autoSeedEnabled) {
        [self rebuildTheme];
        [self notifyThemeChanged];
    }
    [self notifyBackgroundChanged];
}

- (UIImage *)backgroundImage {
    return _backgroundImage;
}

- (void)setBackgroundBlur:(NSInteger)backgroundBlur {
    NSInteger clamped = MAX(0, MIN(100, backgroundBlur));
    if (_backgroundBlur == clamped) return;
    _backgroundBlur = clamped;
    [self persist];
    [self notifyBackgroundChanged];
}

- (void)setBackgroundDarkOverlay:(CGFloat)v {
    CGFloat clamped = MAX(0.0, MIN(1.0, v));
    if (fabs(_backgroundDarkOverlay - clamped) < 0.001) return;
    _backgroundDarkOverlay = clamped;
    [self persist];
    [self notifyBackgroundChanged];
}

- (void)setBackgroundFadeRatio:(CGFloat)v {
    CGFloat clamped = MAX(0.0, MIN(1.0, v));
    if (fabs(_backgroundFadeRatio - clamped) < 0.001) return;
    _backgroundFadeRatio = clamped;
    [self persist];
    [self notifyBackgroundChanged];
}

#pragma mark 背景图持久化

/// 背景图存沙盒而非 UserDefaults —— UserDefaults 存大图会拖慢启动
- (NSString *)backgroundFilePath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) return nil;
    return [docs stringByAppendingPathComponent:kBackgroundFileName];
}

- (BOOL)persistBackgroundImage:(UIImage *)image {
    if (!image) return NO;
    NSString *path = [self backgroundFilePath];
    if (!path) return NO;

    // 缩到合理尺寸再存：原图可能好几 MB，界面用不到那么大
    CGFloat maxSide = 2400;
    CGSize size = image.size;
    if (MAX(size.width, size.height) > maxSide) {
        CGFloat scale = maxSide / MAX(size.width, size.height);
        size = CGSizeMake(size.width * scale, size.height * scale);
    }

    UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    NSData *data = UIImageJPEGRepresentation(scaled, 0.88);
    if (!data) return NO;

    NSError *error = nil;
    BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&error];
    return ok;
}

- (UIImage *)loadPersistedBackground {
    NSString *path = [self backgroundFilePath];
    if (!path) return nil;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    return [UIImage imageWithContentsOfFile:path];
}

- (void)clearBackgroundImage {
    NSString *path = [self backgroundFilePath];
    if (path) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
    _backgroundImage = nil;
    [self rebuildTheme];
    [self notifyThemeChanged];
    [self notifyBackgroundChanged];
}

#pragma mark - 持久化与广播

- (void)persist {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:_selectedKind forKey:kKeyThemeKind];
    [d setInteger:_appearanceMode forKey:kKeyAppearance];
    [d setInteger:_backgroundBlur forKey:kKeyBgBlur];
    [d setDouble:_backgroundDarkOverlay forKey:kKeyBgOverlay];
    [d setDouble:_backgroundFadeRatio forKey:kKeyBgFade];
    [d setInteger:_paletteStyle forKey:kKeyPaletteStyle];
    if (_customSeedColor) {
        [d setInteger:(NSInteger)A2RGBValue(_customSeedColor) forKey:kKeyCustomSeed];
    } else {
        [d removeObjectForKey:kKeyCustomSeed];
    }

    // 插件主题：三把键同进同出，避免读回时出现「有 id 没 token」的半状态
    if (_pluginThemeTokens.count > 0) {
        [d setObject:_pluginThemeTokens forKey:kKeyPluginThemeTokens];
        if (_pluginThemePluginId.length > 0) {
            [d setObject:_pluginThemePluginId forKey:kKeyPluginThemeId];
        } else {
            [d removeObjectForKey:kKeyPluginThemeId];
        }
        if (_pluginThemeName.length > 0) {
            [d setObject:_pluginThemeName forKey:kKeyPluginThemeName];
        } else {
            [d removeObjectForKey:kKeyPluginThemeName];
        }
    } else {
        [d removeObjectForKey:kKeyPluginThemeTokens];
        [d removeObjectForKey:kKeyPluginThemeId];
        [d removeObjectForKey:kKeyPluginThemeName];
    }
}

- (void)notifyThemeChanged {
    [NSNotificationCenter.defaultCenter postNotificationName:A2ThemeDidChangeNotification
                                                      object:self
                                                    userInfo:@{ @"theme": _theme }];
}

- (void)notifyBackgroundChanged {
    [NSNotificationCenter.defaultCenter postNotificationName:A2BackgroundDidChangeNotification
                                                      object:self
                                                    userInfo:nil];
}

@end
