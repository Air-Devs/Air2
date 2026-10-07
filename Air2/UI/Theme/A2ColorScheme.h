//
//  A2ColorScheme.h
//  Air2
//
//  MD3 语义色板的读写接口。
//  内部实现分两步：先用「亮」「暗」两组具体色值填充，
//  再合并为一个全是动态颜色的对外色板。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 工具函数（供同模块其他文件使用）

UIColor *A2Hex(uint32_t rgb);
UIColor *A2DynamicColor(uint32_t lightRGB, uint32_t darkRGB);
uint32_t A2RGBValue(UIColor *c);
void A2GetHSB(UIColor *c, CGFloat *h, CGFloat *s, CGFloat *b);
/// 以指定饱和度/亮度重建同色相颜色
UIColor *A2Tone(UIColor *seed, CGFloat sat, CGFloat bright);
/// 色相偏移
UIColor *A2ShiftHue(UIColor *seed, CGFloat delta);

#pragma mark - 色板

@interface A2ColorScheme : NSObject

#pragma mark 主色
@property (nonatomic, strong) UIColor *primary;
@property (nonatomic, strong) UIColor *onPrimary;
@property (nonatomic, strong) UIColor *primaryContainer;
@property (nonatomic, strong) UIColor *onPrimaryContainer;

#pragma mark 次要色
@property (nonatomic, strong) UIColor *secondary;
@property (nonatomic, strong) UIColor *onSecondary;
@property (nonatomic, strong) UIColor *secondaryContainer;
@property (nonatomic, strong) UIColor *onSecondaryContainer;

#pragma mark 第三色
@property (nonatomic, strong) UIColor *tertiary;
@property (nonatomic, strong) UIColor *tertiaryContainer;

#pragma mark 表面
@property (nonatomic, strong) UIColor *surface;
@property (nonatomic, strong) UIColor *onSurface;
@property (nonatomic, strong) UIColor *surfaceContainerLowest;
@property (nonatomic, strong) UIColor *surfaceContainerLow;
@property (nonatomic, strong) UIColor *surfaceContainer;
@property (nonatomic, strong) UIColor *surfaceContainerHigh;
@property (nonatomic, strong) UIColor *surfaceContainerHighest;
@property (nonatomic, strong) UIColor *surfaceVariant;
@property (nonatomic, strong) UIColor *onSurfaceVariant;

#pragma mark 描边
@property (nonatomic, strong) UIColor *outline;
@property (nonatomic, strong) UIColor *outlineVariant;

#pragma mark 语义
@property (nonatomic, strong) UIColor *error;
@property (nonatomic, strong) UIColor *onError;
@property (nonatomic, strong) UIColor *errorContainer;
@property (nonatomic, strong) UIColor *onErrorContainer;
@property (nonatomic, strong) UIColor *success;
@property (nonatomic, strong) UIColor *warning;

#pragma mark 反色
@property (nonatomic, strong) UIColor *inverseSurface;
@property (nonatomic, strong) UIColor *inverseOnSurface;
@property (nonatomic, strong) UIColor *inversePrimary;

/// 由亮/暗两套具体色值生成对外使用的动态色板
- (void)makeDynamicFromLight:(A2ColorScheme *)light dark:(A2ColorScheme *)dark;

@end

NS_ASSUME_NONNULL_END
