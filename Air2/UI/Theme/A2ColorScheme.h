//
//  A2ColorScheme.h
//  Air2
//
//  MD3 语义色板。
//
//  ⚠️ 设计决策：这里【不用】UIColor 的动态颜色（colorWithDynamicProvider）。
//
//  原因：动态颜色在被赋值给视图属性时，由【视图自身的 trait 环境】解析。
//  而我们的取色发生在 applyTheme 里，此时视图往往还没加入 window 层级，
//  解析用的是默认 trait（亮色）—— 结果是「iPhone 开暗黑模式，
//  卡片却渲染成亮色」这种问题，且极难排查（代码看起来完全正确）。
//
//  正确的做法：
//    1. 色板同时持有亮色与暗色的具体色值
//    2. 提供 current: 方法，按传入的 isDark 返回对应的具体 UIColor
//    3. 视图在 applyTheme 里显式传入 A2ThemeManager.shared.isDark
//
//  代价是每次切换外观要重建视图颜色（已经在做），
//  换来的是完全可预测的取色结果。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 工具函数

UIColor *A2Hex(uint32_t rgb);
/// 以指定饱和度/亮度重建同色相颜色
UIColor *A2Tone(UIColor *seed, CGFloat sat, CGFloat bright);
/// 色相偏移
UIColor *A2ShiftHue(UIColor *seed, CGFloat delta);
/// 读取 HSL 分量
void A2GetHSB(UIColor *c, CGFloat *h, CGFloat *s, CGFloat *b);
/// 取 0xRRGGBB
uint32_t A2RGBValue(UIColor *c);

#pragma mark - 单个色槽

/// 一个语义色槽：同时持有亮色与暗色的具体值
@interface A2ColorSlot : NSObject

@property (nonatomic, strong) UIColor *light;
@property (nonatomic, strong) UIColor *dark;

+ (instancetype)light:(UIColor *)light dark:(UIColor *)dark;
/// 按模式取具体色值
- (UIColor *)colorForDark:(BOOL)isDark;

@end

#pragma mark - 色板

@interface A2ColorScheme : NSObject

#pragma mark 主色
@property (nonatomic, strong) A2ColorSlot *primary;
@property (nonatomic, strong) A2ColorSlot *onPrimary;
@property (nonatomic, strong) A2ColorSlot *primaryContainer;
@property (nonatomic, strong) A2ColorSlot *onPrimaryContainer;

#pragma mark 次要色
@property (nonatomic, strong) A2ColorSlot *secondary;
@property (nonatomic, strong) A2ColorSlot *onSecondary;
@property (nonatomic, strong) A2ColorSlot *secondaryContainer;
@property (nonatomic, strong) A2ColorSlot *onSecondaryContainer;

#pragma mark 第三色
@property (nonatomic, strong) A2ColorSlot *tertiary;
@property (nonatomic, strong) A2ColorSlot *tertiaryContainer;

#pragma mark 表面
@property (nonatomic, strong) A2ColorSlot *surface;
@property (nonatomic, strong) A2ColorSlot *onSurface;
@property (nonatomic, strong) A2ColorSlot *surfaceContainerLowest;
@property (nonatomic, strong) A2ColorSlot *surfaceContainerLow;
@property (nonatomic, strong) A2ColorSlot *surfaceContainer;
@property (nonatomic, strong) A2ColorSlot *surfaceContainerHigh;
@property (nonatomic, strong) A2ColorSlot *surfaceContainerHighest;
@property (nonatomic, strong) A2ColorSlot *surfaceVariant;
@property (nonatomic, strong) A2ColorSlot *onSurfaceVariant;

#pragma mark 描边
@property (nonatomic, strong) A2ColorSlot *outline;
@property (nonatomic, strong) A2ColorSlot *outlineVariant;

#pragma mark 语义
@property (nonatomic, strong) A2ColorSlot *error;
@property (nonatomic, strong) A2ColorSlot *onError;
@property (nonatomic, strong) A2ColorSlot *errorContainer;
@property (nonatomic, strong) A2ColorSlot *onErrorContainer;
@property (nonatomic, strong) A2ColorSlot *success;
@property (nonatomic, strong) A2ColorSlot *warning;

#pragma mark 反色
@property (nonatomic, strong) A2ColorSlot *inverseSurface;
@property (nonatomic, strong) A2ColorSlot *inverseOnSurface;
@property (nonatomic, strong) A2ColorSlot *inversePrimary;

#pragma mark 便捷取色

/// 生成一个「已按模式解析」的快照 —— 视图 applyTheme 时调用一次，
/// 之后全部从这个快照取具体色值，不再有 trait 解析的不确定性。
- (instancetype)resolvedForDark:(BOOL)isDark;

// 以下方法只在 resolved 快照上有意义（直接返回具体 UIColor）
@property (nonatomic, strong, readonly) UIColor *cPrimary;
@property (nonatomic, strong, readonly) UIColor *cOnPrimary;
@property (nonatomic, strong, readonly) UIColor *cPrimaryContainer;
@property (nonatomic, strong, readonly) UIColor *cOnPrimaryContainer;
@property (nonatomic, strong, readonly) UIColor *cSecondary;
@property (nonatomic, strong, readonly) UIColor *cSecondaryContainer;
@property (nonatomic, strong, readonly) UIColor *cTertiary;
@property (nonatomic, strong, readonly) UIColor *cTertiaryContainer;
@property (nonatomic, strong, readonly) UIColor *cSurface;
@property (nonatomic, strong, readonly) UIColor *cOnSurface;
@property (nonatomic, strong, readonly) UIColor *cSurfaceContainerLowest;
@property (nonatomic, strong, readonly) UIColor *cSurfaceContainerLow;
@property (nonatomic, strong, readonly) UIColor *cSurfaceContainer;
@property (nonatomic, strong, readonly) UIColor *cSurfaceContainerHigh;
@property (nonatomic, strong, readonly) UIColor *cSurfaceContainerHighest;
@property (nonatomic, strong, readonly) UIColor *cSurfaceVariant;
@property (nonatomic, strong, readonly) UIColor *cOnSurfaceVariant;
@property (nonatomic, strong, readonly) UIColor *cOutline;
@property (nonatomic, strong, readonly) UIColor *cOutlineVariant;
@property (nonatomic, strong, readonly) UIColor *cError;
@property (nonatomic, strong, readonly) UIColor *cOnError;
@property (nonatomic, strong, readonly) UIColor *cErrorContainer;
@property (nonatomic, strong, readonly) UIColor *cSuccess;
@property (nonatomic, strong, readonly) UIColor *cWarning;
@property (nonatomic, strong, readonly) UIColor *cInverseSurface;
@property (nonatomic, strong, readonly) UIColor *cInverseOnSurface;
@property (nonatomic, strong, readonly) UIColor *cInversePrimary;

/// 当前解析出的模式
@property (nonatomic, assign, readonly) BOOL resolvedIsDark;

@end

NS_ASSUME_NONNULL_END
