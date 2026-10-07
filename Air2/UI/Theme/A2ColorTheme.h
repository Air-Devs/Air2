//
//  A2ColorTheme.h
//  Air2
//
//  配色系统 —— 5 套手调色板 + 动态取色
//  参考 ZL2 的 ColorTheme 思路，收敛为 iOS 上辨识度更高的 5 套
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 主题标识
typedef NS_ENUM(NSInteger, A2ThemeKind) {
    A2ThemeKindEmbermire = 0,   ///< 烈焰红棕（默认）
    A2ThemeKindGlacier,         ///< 冰川蓝
    A2ThemeKindVerdantDawn,     ///< 青野绿
    A2ThemeKindVelvetRose,      ///< 绛紫玫瑰
    A2ThemeKindUrbanAsh,        ///< 都市灰
    A2ThemeKindDynamic,         ///< 从壁纸动态提取
    A2ThemeKindCount
};

/// 一套完整的调色板。字段语义对齐 Material3 的 ColorScheme 命名，
/// 但收敛到实际会用到的那几档，避免出现"定义了没人用"的颜色。
@interface A2ColorTheme : NSObject

@property (nonatomic, assign, readonly) A2ThemeKind kind;
@property (nonatomic, copy, readonly) NSString *displayName;

// ---- 品牌色 ----
@property (nonatomic, strong, readonly) UIColor *primary;        ///< 主色，按钮/强调
@property (nonatomic, strong, readonly) UIColor *onPrimary;      ///< 主色上的文字
@property (nonatomic, strong, readonly) UIColor *primaryContainer;  ///< 主色容器（浅填充）

// ---- 强调色 ----
@property (nonatomic, strong, readonly) UIColor *accent;         ///< 高亮、进度条、选中态

// ---- 背景层 ----
@property (nonatomic, strong, readonly) UIColor *background;     ///< 页面背景（亮模式）
@property (nonatomic, strong, readonly) UIColor *backgroundDark; ///< 页面背景（暗模式）
@property (nonatomic, strong, readonly) UIColor *surface;        ///< 卡片表面基准色
@property (nonatomic, strong, readonly) UIColor *surfaceElevated;///< 悬浮层表面

// ---- 文字 ----
@property (nonatomic, strong, readonly) UIColor *textPrimary;
@property (nonatomic, strong, readonly) UIColor *textSecondary;
@property (nonatomic, strong, readonly) UIColor *textTertiary;

// ---- 语义 ----
@property (nonatomic, strong, readonly) UIColor *danger;
@property (nonatomic, strong, readonly) UIColor *success;

/// 壁纸渐变用的三个色（用于主页背景）
@property (nonatomic, strong, readonly) NSArray<UIColor *> *wallpaperGradient;

/// 取出指定主题
+ (instancetype)themeForKind:(A2ThemeKind)kind;

/// 从图片提取主色并生成一套动态主题
/// @param image 用户壁纸
/// @return 提取失败时返回 Embermire
+ (instancetype)themeFromImage:(UIImage *)image;

/// 全部可选主题（不含 Dynamic）
+ (NSArray<A2ColorTheme *> *)allThemes;

@end

NS_ASSUME_NONNULL_END
