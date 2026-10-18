#import <UIKit/UIKit.h>

/// 屏幕尺寸检测工具类（参照 FCL 的 ScreenUtils 设计）
/// 极速获取：nativeBounds/nativeScale 使用 dispatch_once 缓存（固定值，O(1)）；
/// screenSize/safeAreaInsets 实时获取（随方向/安全区域变化）。
/// 支持 iPhone 和 iPad，自动适配方向。
@interface ScreenUtils : NSObject

/// 当前屏幕尺寸（点值，考虑当前方向）
+ (CGSize)screenSize;

/// 竖屏屏幕尺寸（点值，固定值）
+ (CGSize)screenSizePortrait;

/// 横屏屏幕尺寸（点值，固定值）
+ (CGSize)screenSizeLandscape;

/// 原生屏幕尺寸（像素值，固定值，不随方向变化）
+ (CGSize)nativeScreenSize;

/// 屏幕缩放因子（如 2.0 / 3.0）
+ (CGFloat)screenScale;

/// 原生缩放因子（如 2.0 / 3.0）
+ (CGFloat)nativeScale;

/// 是否 iPad
+ (BOOL)isPad;

/// 是否 iPhone
+ (BOOL)isPhone;

/// 是否横屏（基于 statusBarOrientation，比 UIDevice.orientation 更可靠）
+ (BOOL)isLandscape;

/// 是否竖屏
+ (BOOL)isPortrait;

/// 安全区域 insets（基于当前 keyWindow）
+ (UIEdgeInsets)safeAreaInsets;

/// 状态栏高度（iOS 13+ 用 statusBarManager，旧版用 statusBarFrame）
+ (CGFloat)statusBarHeight;

/// 导航栏高度（44，横屏 iPhone 可能不同）
+ (CGFloat)navigationBarHeight;

/// 标签栏高度（49 + safeAreaBottom）
+ (CGFloat)tabBarHeight;

/// 底部安全区域高度（iPhone X+ 为 34，其他为 0）
+ (CGFloat)safeAreaBottom;

/// 顶部安全区域高度（iPhone X+ 为 47/44，其他为 20）
+ (CGFloat)safeAreaTop;

/// 是否有刘海屏/灵动岛（safeAreaTop > 20）
+ (BOOL)hasNotch;

/// 屏幕圆角半径（近似值，用于 UI 设计参考）
+ (CGFloat)cornerRadius;

/// 适配后的字体大小（基于屏幕宽度缩放，参照 FCL 的 sp() 函数）
+ (CGFloat)sp:(CGFloat)sp;

/// 适配后的尺寸大小（基于屏幕宽度缩放，参照 FCL 的 dp() 函数）
+ (CGFloat)dp:(CGFloat)dp;

/// 当前 keyWindow（兼容 iOS 13+ 和旧版）
+ (UIWindow *)keyWindow;

@end
