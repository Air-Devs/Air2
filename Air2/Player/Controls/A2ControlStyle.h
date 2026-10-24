//
//  A2ControlStyle.h
//  Air2
//
//  控件样式 —— 对照 ZL2 的 ButtonStyle / StyleConfig。
//
//  ## ZL2 的样式规格（实证自 ButtonStyle.kt）
//
//    StyleConfig（一套）:
//      alpha / pressedAlpha              不透明度（常态/按下）
//      backgroundColor / pressedBackgroundColor
//      borderColor / pressedBorderColor
//      borderWidth / pressedBorderWidth
//      borderRadius / pressedBorderRadius
//      contentColor / pressedContentColor  （文字与图标）
//      fontSize / pressedFontSize
//
//    ButtonStyle（一组）:
//      name / uuid
//      animateSwap         按下时是否有过渡动画
//      commonStyle         亮暗共用一套
//      lightStyle         亮色模式
//      darkStyle          暗色模式
//
//  ## 为什么要亮暗两套
//
//  控件叠在游戏画面上，而游戏画面本身可能是亮的（白天下雪）
//  或暗的（洞穴）。同一套颜色在两种背景下都可能看不清，
//  所以 ZL2 允许分别定义。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 一套样式配置（对应 ZL2 的 StyleConfig）
@interface A2ControlStyleConfig : NSObject
@property (nonatomic, assign) CGFloat alpha;
@property (nonatomic, assign) CGFloat pressedAlpha;
@property (nonatomic, strong) UIColor *backgroundColor;
@property (nonatomic, strong) UIColor *pressedBackgroundColor;
@property (nonatomic, strong) UIColor *borderColor;
@property (nonatomic, strong) UIColor *pressedBorderColor;
@property (nonatomic, assign) CGFloat borderWidth;
@property (nonatomic, assign) CGFloat pressedBorderWidth;
@property (nonatomic, assign) CGFloat borderRadius;
@property (nonatomic, assign) CGFloat pressedBorderRadius;
@property (nonatomic, strong) UIColor *contentColor;
@property (nonatomic, strong) UIColor *pressedContentColor;
@property (nonatomic, assign) CGFloat fontSize;
@property (nonatomic, assign) CGFloat pressedFontSize;

+ (instancetype)configFromJSON:(NSDictionary *)json;
- (NSDictionary *)toJSON;
/// 默认样式（半透明白底 + 深色文字）
+ (instancetype)defaultLight;
+ (instancetype)defaultDark;
@end

/// 一组样式（对应 ZL2 的 ButtonStyle）
@interface A2ControlStyle : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, assign) BOOL animateSwap;
@property (nonatomic, assign) BOOL commonStyle;
@property (nonatomic, strong) A2ControlStyleConfig *lightStyle;
@property (nonatomic, strong) A2ControlStyleConfig *darkStyle;
@property (nonatomic, copy) NSDictionary *rawJSON;

+ (instancetype)styleFromJSON:(NSDictionary *)json;
- (NSDictionary *)toJSON;

/// 按当前亮暗模式取一套
- (A2ControlStyleConfig *)configForDarkMode:(BOOL)dark;
/// 按按下态取参数
- (UIColor *)contentColorForDarkMode:(BOOL)dark pressed:(BOOL)pressed;
- (UIColor *)backgroundColorForDarkMode:(BOOL)dark pressed:(BOOL)pressed;
- (UIColor *)borderColorForDarkMode:(BOOL)dark pressed:(BOOL)pressed;
- (CGFloat)alphaForDarkMode:(BOOL)dark pressed:(BOOL)pressed;
- (CGFloat)borderWidthForDarkMode:(BOOL)dark pressed:(BOOL)pressed;
- (CGFloat)fontSizeForDarkMode:(BOOL)dark pressed:(BOOL)pressed;

/// 应用到某个 UIView（圆角、边框、背景）
- (void)applyToView:(UIView *)view darkMode:(BOOL)dark pressed:(BOOL)pressed;

@end

NS_ASSUME_NONNULL_END
