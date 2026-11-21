//
//  A2ControlStyle.m
//  Air2
//

#import "A2ControlStyle.h"
#import "A2ThemeManager.h"

#pragma mark - 颜色解析

/// 解析 ZL2 的颜色格式。
/// ZL2 用 Compose 的 Color，序列化成 0xAARRGGBB 的整数。
/// FCL / Air1 可能用 "#RRGGBB" 或 "#AARRGGBB" 字符串。
static UIColor *A2ColorFromJSON(id value, UIColor *fallback) {
    if (!value || value == NSNull.null) return fallback;

    uint64_t argb = 0;
    BOOL hasColor = NO;

    if ([value isKindOfClass:NSNumber.class]) {
        argb = [value unsignedLongLongValue];
        hasColor = YES;
    } else if ([value isKindOfClass:NSString.class]) {
        NSString *s = [(NSString *)value stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        s = [s stringByReplacingOccurrencesOfString:@"#" withString:@""];
        s = [s stringByReplacingOccurrencesOfString:@"0x" withString:@""];
        s = [s stringByReplacingOccurrencesOfString:@"0X" withString:@""];
        unsigned long long v = 0;
        NSScanner *scanner = [NSScanner scannerWithString:s];
        if ([scanner scanHexLongLong:&v]) {
            argb = v;
            hasColor = YES;
            // "#RRGGBB"（6 位）补成不透明
            if (s.length == 6) argb |= 0xFF000000ULL;
        }
    }

    if (!hasColor) return fallback;

    CGFloat a = ((argb >> 24) & 0xFF) / 255.0;
    CGFloat r = ((argb >> 16) & 0xFF) / 255.0;
    CGFloat g = ((argb >> 8) & 0xFF) / 255.0;
    CGFloat b = (argb & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

static uint64_t A2ColorToARGB(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [c getRed:&r green:&g blue:&b alpha:&a];
    return ((uint64_t)lrint(a * 255) << 24) |
           ((uint64_t)lrint(r * 255) << 16) |
           ((uint64_t)lrint(g * 255) << 8)  |
            (uint64_t)lrint(b * 255);
}

static double A2Num(id j, NSString *k, double fb) {
    if (![j isKindOfClass:NSDictionary.class]) return fb;
    id v = j[k];
    if ([v isKindOfClass:NSNumber.class]) return [v doubleValue];
    return fb;
}

#pragma mark - StyleConfig

@implementation A2ControlStyleConfig

+ (instancetype)defaultLight {
    A2ControlStyleConfig *c = [A2ControlStyleConfig new];
    c.alpha = 0.72;
    c.pressedAlpha = 0.92;
    c.backgroundColor = [UIColor colorWithWhite:1.0 alpha:1.0];
    c.pressedBackgroundColor = [UIColor colorWithWhite:1.0 alpha:1.0];
    c.borderColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    c.pressedBorderColor = [UIColor colorWithWhite:0.0 alpha:0.8];
    c.borderWidth = 1;
    c.pressedBorderWidth = 1.5;
    c.borderRadius = 20;
    c.pressedBorderRadius = 20;
    c.contentColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    c.pressedContentColor = [UIColor colorWithWhite:0.0 alpha:1.0];
    c.fontSize = 14;
    c.pressedFontSize = 14;
    return c;
}

+ (instancetype)defaultDark {
    A2ControlStyleConfig *c = [A2ControlStyleConfig defaultLight];
    c.backgroundColor = [UIColor colorWithWhite:0.0 alpha:1.0];
    c.pressedBackgroundColor = [UIColor colorWithWhite:0.0 alpha:1.0];
    c.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    c.pressedBorderColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    c.contentColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    c.pressedContentColor = [UIColor colorWithWhite:1.0 alpha:1.0];
    return c;
}

+ (instancetype)configFromJSON:(NSDictionary *)j {
    if (![j isKindOfClass:NSDictionary.class]) return [self defaultLight];

    A2ControlStyleConfig *c = [A2ControlStyleConfig new];
    c.alpha = A2Num(j, @"alpha", 0.72);
    c.pressedAlpha = A2Num(j, @"pressedAlpha", 0.92);
    c.backgroundColor = A2ColorFromJSON(j[@"backgroundColor"], [UIColor whiteColor]);
    c.pressedBackgroundColor = A2ColorFromJSON(j[@"pressedBackgroundColor"], c.backgroundColor);
    c.borderColor = A2ColorFromJSON(j[@"borderColor"], [UIColor grayColor]);
    c.pressedBorderColor = A2ColorFromJSON(j[@"pressedBorderColor"], c.borderColor);
    c.borderWidth = A2Num(j, @"borderWidth", 1);
    c.pressedBorderWidth = A2Num(j, @"pressedBorderWidth", c.borderWidth);
    c.borderRadius = A2Num(j, @"borderRadius", 20);
    c.pressedBorderRadius = A2Num(j, @"pressedBorderRadius", c.borderRadius);
    c.contentColor = A2ColorFromJSON(j[@"contentColor"], [UIColor blackColor]);
    c.pressedContentColor = A2ColorFromJSON(j[@"pressedContentColor"], c.contentColor);
    c.fontSize = A2Num(j, @"fontSize", 14);
    c.pressedFontSize = A2Num(j, @"pressedFontSize", c.fontSize);
    return c;
}

- (NSDictionary *)toJSON {
    return @{
        @"alpha": @(self.alpha),
        @"pressedAlpha": @(self.pressedAlpha),
        @"backgroundColor": @(A2ColorToARGB(self.backgroundColor)),
        @"pressedBackgroundColor": @(A2ColorToARGB(self.pressedBackgroundColor)),
        @"borderColor": @(A2ColorToARGB(self.borderColor)),
        @"pressedBorderColor": @(A2ColorToARGB(self.pressedBorderColor)),
        @"borderWidth": @(self.borderWidth),
        @"pressedBorderWidth": @(self.pressedBorderWidth),
        @"borderRadius": @(self.borderRadius),
        @"pressedBorderRadius": @(self.pressedBorderRadius),
        @"contentColor": @(A2ColorToARGB(self.contentColor)),
        @"pressedContentColor": @(A2ColorToARGB(self.pressedContentColor)),
        @"fontSize": @(self.fontSize),
        @"pressedFontSize": @(self.pressedFontSize),
    };
}

@end

#pragma mark - ButtonStyle

@implementation A2ControlStyle

+ (instancetype)styleFromJSON:(NSDictionary *)j {
    if (![j isKindOfClass:NSDictionary.class]) return nil;

    A2ControlStyle *s = [A2ControlStyle new];
    s.rawJSON = j;
    s.name = j[@"name"] ?: @"";
    s.identifier = j[@"uuid"] ?: j[@"id"] ?: s.name;
    s.animateSwap = [j[@"animateSwap"] boolValue];
    s.commonStyle = j[@"commonStyle"] ? [j[@"commonStyle"] boolValue] : YES;

    NSDictionary *light = j[@"lightStyle"];
    NSDictionary *dark = j[@"darkStyle"];

    s.lightStyle = light ? [A2ControlStyleConfig configFromJSON:light]
                         : [A2ControlStyleConfig defaultLight];
    s.darkStyle  = dark  ? [A2ControlStyleConfig configFromJSON:dark]
                         : (s.commonStyle ? s.lightStyle : [A2ControlStyleConfig defaultDark]);
    return s;
}

- (NSDictionary *)toJSON {
    NSMutableDictionary *d = self.rawJSON
        ? [self.rawJSON mutableCopy] : [NSMutableDictionary dictionary];
    d[@"name"] = self.name;
    d[@"uuid"] = self.identifier;
    d[@"animateSwap"] = @(self.animateSwap);
    d[@"commonStyle"] = @(self.commonStyle);
    d[@"lightStyle"] = [self.lightStyle toJSON];
    d[@"darkStyle"] = [self.darkStyle toJSON];
    return d;
}

- (A2ControlStyleConfig *)configForDarkMode:(BOOL)dark {
    return dark ? self.darkStyle : self.lightStyle;
}

- (UIColor *)contentColorForDarkMode:(BOOL)dark pressed:(BOOL)pressed {
    A2ControlStyleConfig *c = [self configForDarkMode:dark];
    return pressed ? c.pressedContentColor : c.contentColor;
}

- (UIColor *)backgroundColorForDarkMode:(BOOL)dark pressed:(BOOL)pressed {
    A2ControlStyleConfig *c = [self configForDarkMode:dark];
    return pressed ? c.pressedBackgroundColor : c.backgroundColor;
}

- (UIColor *)borderColorForDarkMode:(BOOL)dark pressed:(BOOL)pressed {
    A2ControlStyleConfig *c = [self configForDarkMode:dark];
    return pressed ? c.pressedBorderColor : c.borderColor;
}

- (CGFloat)alphaForDarkMode:(BOOL)dark pressed:(BOOL)pressed {
    A2ControlStyleConfig *c = [self configForDarkMode:dark];
    return pressed ? c.pressedAlpha : c.alpha;
}

- (CGFloat)borderWidthForDarkMode:(BOOL)dark pressed:(BOOL)pressed {
    A2ControlStyleConfig *c = [self configForDarkMode:dark];
    return pressed ? c.pressedBorderWidth : c.borderWidth;
}

- (CGFloat)fontSizeForDarkMode:(BOOL)dark pressed:(BOOL)pressed {
    A2ControlStyleConfig *c = [self configForDarkMode:dark];
    return pressed ? c.pressedFontSize : c.fontSize;
}

- (void)applyToView:(UIView *)view darkMode:(BOOL)dark pressed:(BOOL)pressed {
    if (!view) return;

    view.backgroundColor = [self backgroundColorForDarkMode:dark pressed:pressed];
    view.alpha = [self alphaForDarkMode:dark pressed:pressed];

    view.layer.borderColor = [self borderColorForDarkMode:dark pressed:pressed].CGColor;
    view.layer.borderWidth = [self borderWidthForDarkMode:dark pressed:pressed];

    A2ControlStyleConfig *c = [self configForDarkMode:dark];
    CGFloat r = pressed ? c.pressedBorderRadius : c.borderRadius;
    view.layer.cornerRadius = r;
    view.layer.cornerCurve = kCACornerCurveContinuous;
}

@end
