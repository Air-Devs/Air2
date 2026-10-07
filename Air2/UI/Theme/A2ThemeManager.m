//
//  A2ThemeManager.m
//  Air2
//

#import "A2ThemeManager.h"

NSNotificationName const A2ThemeDidChangeNotification = @"A2ThemeDidChangeNotification";

static NSString *const kKeyThemeKind   = @"A2ThemeKind";
static NSString *const kKeyAppearance  = @"A2AppearanceMode";
static NSString *const kKeyGlass       = @"A2GlassIntensity";

@implementation A2ThemeManager {
    A2ColorTheme *_currentTheme;
    UIImage *_wallpaper;
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
    _glassIntensity = [d objectForKey:kKeyGlass] ? [d integerForKey:kKeyGlass] : 60;
    _appearanceMode = (A2AppearanceMode)[d integerForKey:kKeyAppearance];

    NSInteger kind = [d objectForKey:kKeyThemeKind] ? [d integerForKey:kKeyThemeKind] : A2ThemeKindEmbermire;
    if (kind < 0 || kind >= A2ThemeKindCount) kind = A2ThemeKindEmbermire;
    _selectedKind = (A2ThemeKind)kind;
    _currentTheme = [A2ColorTheme themeForKind:_selectedKind];

    return self;
}

#pragma mark - 主题切换

- (void)setSelectedKind:(A2ThemeKind)selectedKind {
    if (selectedKind < 0 || selectedKind >= A2ThemeKindCount) return;
    if (_selectedKind == selectedKind) return;

    _selectedKind = selectedKind;
    [self rebuildTheme];
    [self persist];
    [self notifyChanged];
}

- (void)setWallpaper:(UIImage *)wallpaper {
    _wallpaper = wallpaper;
    if (_selectedKind == A2ThemeKindDynamic) {
        [self rebuildTheme];
        [self notifyChanged];
    }
}

- (UIImage *)wallpaper {
    return _wallpaper;
}

/// 依据当前 selectedKind 重建主题对象
- (void)rebuildTheme {
    if (_selectedKind == A2ThemeKindDynamic) {
        _currentTheme = _wallpaper ? [A2ColorTheme themeFromImage:_wallpaper] : [A2ColorTheme themeForKind:A2ThemeKindEmbermire];
    } else {
        _currentTheme = [A2ColorTheme themeForKind:_selectedKind];
    }
}

- (A2ColorTheme *)currentTheme {
    return _currentTheme;
}

#pragma mark - 外观

- (BOOL)isDark {
    switch (_appearanceMode) {
        case A2AppearanceModeLight: return NO;
        case A2AppearanceModeDark:  return YES;
        case A2AppearanceModeSystem:
        default:
            if (@available(iOS 13.0, *)) {
                return UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
            }
            return NO;
    }
}

- (void)setAppearanceMode:(A2AppearanceMode)appearanceMode {
    if (_appearanceMode == appearanceMode) return;
    _appearanceMode = appearanceMode;
    [self persist];
    [self notifyChanged];
}

- (void)setGlassIntensity:(NSInteger)glassIntensity {
    NSInteger clamped = MAX(0, MIN(100, glassIntensity));
    if (_glassIntensity == clamped) return;
    _glassIntensity = clamped;
    [self persist];
    [self notifyChanged];
}

- (void)applyAppearanceToWindow:(UIWindow *)window {
    if (!window) return;
    switch (_appearanceMode) {
        case A2AppearanceModeLight: window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight; break;
        case A2AppearanceModeDark:  window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;  break;
        case A2AppearanceModeSystem:window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified; break;
    }
    window.tintColor = _currentTheme.primary;
}

#pragma mark - 语义取色

- (UIColor *)backgroundColor {
    return self.isDark ? _currentTheme.backgroundDark : _currentTheme.background;
}

- (UIColor *)surfaceColor {
    return self.isDark ? [_currentTheme.surface colorWithAlphaComponent:0.16] : _currentTheme.surface;
}

- (UIColor *)surfaceElevatedColor {
    return self.isDark ? [_currentTheme.surfaceElevated colorWithAlphaComponent:0.22] : _currentTheme.surfaceElevated;
}

- (UIColor *)cardFillColor {
    // 暗色下用低透明度白，让背景的彩色透出来；亮色下用实色保证可读性
    if (self.isDark) {
        return [UIColor colorWithWhite:1.0 alpha:0.10];
    }
    return [_currentTheme.surface colorWithAlphaComponent:0.72];
}

#pragma mark - 持久化与广播

- (void)persist {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:_selectedKind forKey:kKeyThemeKind];
    [d setInteger:_appearanceMode forKey:kKeyAppearance];
    [d setInteger:_glassIntensity forKey:kKeyGlass];
}

- (void)notifyChanged {
    [NSNotificationCenter.defaultCenter postNotificationName:A2ThemeDidChangeNotification
                                                      object:self
                                                    userInfo:@{ @"theme": _currentTheme }];
}

@end
