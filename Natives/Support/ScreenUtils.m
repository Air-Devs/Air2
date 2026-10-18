#import "ScreenUtils.h"

@implementation ScreenUtils

// 极速缓存：nativeBounds/nativeScale 是固定值，用 dispatch_once 一次性获取
// UIScreen.main.bounds/nativeBounds 是 O(1) 操作，但 dispatch_once 仍能避免重复调用开销
// 注意：CGSizeZero 在 iOS SDK 中展开为 compound literal (CGSize){0,0}，不是编译期常量，
// 不能用于全局变量初始化。改用 plain struct initializer {0,0}。
static CGSize _cachedNativeBounds = {0, 0};
static CGFloat _cachedNativeScale = 0;
static CGFloat _cachedScale = 0;
static dispatch_once_t _nativeOnceToken;

+ (void)initializeNativeBounds {
    dispatch_once(&_nativeOnceToken, ^{
        UIScreen *screen = [UIScreen mainScreen];
        _cachedNativeBounds = screen.nativeBounds.size;
        _cachedNativeScale = screen.nativeScale;
        _cachedScale = screen.scale;
    });
}

+ (CGSize)screenSize {
    // UIScreen.main.bounds 在 iOS 13+ 会随方向变化，实时获取
    return [UIScreen mainScreen].bounds.size;
}

+ (CGSize)screenSizePortrait {
    [self initializeNativeBounds];
    // nativeBounds 是固定值，竖屏时 width < height
    CGSize native = _cachedNativeBounds;
    if (native.width <= native.height) {
        // 原生就是竖屏方向
        return CGSizeMake(native.width / _cachedNativeScale, native.height / _cachedNativeScale);
    }
    // 原生是横屏方向，交换
    return CGSizeMake(native.height / _cachedNativeScale, native.width / _cachedNativeScale);
}

+ (CGSize)screenSizeLandscape {
    [self initializeNativeBounds];
    CGSize native = _cachedNativeBounds;
    if (native.width >= native.height) {
        // 原生就是横屏方向
        return CGSizeMake(native.width / _cachedNativeScale, native.height / _cachedNativeScale);
    }
    // 原生是竖屏方向，交换
    return CGSizeMake(native.height / _cachedNativeScale, native.width / _cachedNativeScale);
}

+ (CGSize)nativeScreenSize {
    [self initializeNativeBounds];
    return _cachedNativeBounds;
}

+ (CGFloat)screenScale {
    [self initializeNativeBounds];
    return _cachedScale;
}

+ (CGFloat)nativeScale {
    [self initializeNativeBounds];
    return _cachedNativeScale;
}

+ (BOOL)isPad {
    // 优先用 traitCollection.userInterfaceIdiom（受 UIKit+hook 的 _setUserInterfaceIdiom 影响）
    // 但如果用户没有强制 Phone 模式，用真实 idiom
    // 注意：UIKit+hook.m 强制 idiom 为 Phone（除非 debug.debug_ipad_ui），
    // 所以这里用 [UIDevice currentDevice].userInterfaceIdiom 会受 hook 影响。
    // 为了真实检测 iPad，用 mainScreen.traitCollection.userInterfaceIdiom。
    UIUserInterfaceIdiom idiom = [UIScreen mainScreen].traitCollection.userInterfaceIdiom;
    if (idiom == UIUserInterfaceIdiomPad) return YES;
    // fallback：用 model 名称检测（不受 hook 影响）
    NSString *model = [[UIDevice currentDevice].model lowercaseString];
    return [model containsString:@"ipad"];
}

+ (BOOL)isPhone {
    return ![self isPad];
}

+ (BOOL)isLandscape {
    // 用 statusBarOrientation 比 UIDevice.orientation 更可靠（早期启动时 UIDevice.orientation 可能未知）
    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
    return UIInterfaceOrientationIsLandscape(orientation);
}

+ (BOOL)isPortrait {
    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
    return UIInterfaceOrientationIsPortrait(orientation);
}

+ (UIEdgeInsets)safeAreaInsets {
    UIWindow *window = [self keyWindow];
    if (@available(iOS 11.0, *)) {
        return window.safeAreaInsets;
    }
    return UIEdgeInsetsZero;
}

+ (CGFloat)statusBarHeight {
    UIWindow *window = [self keyWindow];
    if (@available(iOS 13.0, *)) {
        if (window.windowScene && window.windowScene.statusBarManager) {
            return window.windowScene.statusBarManager.statusBarFrame.size.height;
        }
    }
    return [UIApplication sharedApplication].statusBarFrame.size.height;
}

+ (CGFloat)navigationBarHeight {
    // 标准 44，横屏 iPhone 可能不同
    return 44.0;
}

+ (CGFloat)tabBarHeight {
    return 49.0 + [self safeAreaBottom];
}

+ (CGFloat)safeAreaBottom {
    return [self safeAreaInsets].bottom;
}

+ (CGFloat)safeAreaTop {
    return [self safeAreaInsets].top;
}

+ (BOOL)hasNotch {
    return [self safeAreaTop] > 20.0;
}

+ (CGFloat)cornerRadius {
    // 近似值：iPhone X+ 约 39pt，iPad 约 18pt
    return [self isPad] ? 18.0 : 39.0;
}

+ (CGFloat)sp:(CGFloat)sp {
    // 参照 FCL 的 sp() 函数：基于屏幕宽度缩放
    // FCL 用 baseWidth = 360 (Android reference phone width)
    // 但 iOS 用 pt 而非 px，所以这里用 baseWidth = 375 (iPhone X width)
    CGFloat baseWidth = 375.0;
    CGFloat screenWidth = [self screenSize].width;
    CGFloat scale = screenWidth / baseWidth;
    // 限制缩放范围，避免极端尺寸
    // 修复：原 max=2.0 导致 iPad 上字体放大到 2 倍（16pt->32pt），
    // 菜单/版本管理界面字体严重过大。iPad 宽度 1024+ 时 scale=2.73 被 clamp 到 2.0，
    // 远超合理范围。将上限降低至 1.15，iPad 上字体仅略大于 iPhone 基准，
    // 与系统动态字体风格保持一致。
    if (scale < 0.85) scale = 0.85;
    if (scale > 1.15) scale = 1.15;
    return sp * scale;
}

+ (CGFloat)dp:(CGFloat)dp {
    // 同 sp，基于屏幕宽度缩放
    CGFloat baseWidth = 375.0;
    CGFloat screenWidth = [self screenSize].width;
    CGFloat scale = screenWidth / baseWidth;
    // dp 用于尺寸（icon 大小、间距等），允许比 sp 稍大的缩放范围，
    // 但仍需限制避免 iPad 上元素过大
    if (scale < 0.85) scale = 0.85;
    if (scale > 1.3) scale = 1.3;
    return dp * scale;
}

+ (UIWindow *)keyWindow {
    // 兼容 iOS 13+ 和旧版
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in scene.windows) {
                    if (window.isKeyWindow) {
                        return window;
                    }
                }
                // 没有 keyWindow 时返回第一个 window
                if (scene.windows.count > 0) {
                    return scene.windows.firstObject;
                }
            }
        }
    }
    return [UIApplication sharedApplication].keyWindow;
}

@end
