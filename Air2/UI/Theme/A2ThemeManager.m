//
//  A2ThemeManager.m
//  Air2
//

#import "A2ThemeManager.h"

NSNotificationName const A2ThemeDidChangeNotification = @"A2ThemeDidChangeNotification";
NSNotificationName const A2BackgroundDidChangeNotification = @"A2BackgroundDidChangeNotification";

static NSString *const kKeyThemeKind   = @"A2ThemeKind";
static NSString *const kKeyAppearance  = @"A2AppearanceMode";
static NSString *const kKeyBgBlur      = @"A2BackgroundBlur";
static NSString *const kKeyBgOverlay   = @"A2BackgroundDarkOverlay";
static NSString *const kKeyBgFade      = @"A2BackgroundFadeRatio";
static NSString *const kBackgroundFileName = @"air2_background.jpg";

@implementation A2ThemeManager {
    A2ColorTheme *_theme;
    UIImage *_backgroundImage;
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

    NSInteger kind = [d objectForKey:kKeyThemeKind] ? [d integerForKey:kKeyThemeKind] : A2ThemeKindEmbermire;
    if (kind < 0 || kind >= A2ThemeKindCount) kind = A2ThemeKindEmbermire;
    _selectedKind = (A2ThemeKind)kind;

    _backgroundImage = [self loadPersistedBackground];
    [self rebuildTheme];

    return self;
}

#pragma mark - 主题

- (A2ColorTheme *)theme {
    return _theme;
}

- (A2ColorScheme *)scheme {
    return _theme.scheme;
}

- (void)setSelectedKind:(A2ThemeKind)selectedKind {
    if (selectedKind < 0 || selectedKind >= A2ThemeKindCount) return;
    if (_selectedKind == selectedKind) return;

    _selectedKind = selectedKind;
    [self rebuildTheme];
    [self persist];
    [self notifyThemeChanged];
}

/// 依据当前种类重建主题对象
- (void)rebuildTheme {
    if (_selectedKind == A2ThemeKindDynamic && _backgroundImage) {
        _theme = [A2ColorTheme themeFromImage:_backgroundImage];
    } else if (_selectedKind == A2ThemeKindDynamic) {
        // 选了动态取色但还没设背景图，回退到默认主题，避免界面出现随机配色
        _theme = [A2ColorTheme themeForKind:A2ThemeKindEmbermire];
    } else {
        _theme = [A2ColorTheme themeForKind:_selectedKind];
    }
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

- (void)setBackgroundImage:(UIImage *)image {
    _backgroundImage = image;
    // 动态取色主题依赖背景图，换了图要重算
    if (_selectedKind == A2ThemeKindDynamic) {
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
