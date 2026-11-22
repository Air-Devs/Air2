//
//  A2GamepadView.m
//  Air2
//
//  对照 ZL2：ui/control/gamepad/GamepadMap.kt（默认键位表）
//            ui/control/gamepad/DpadDirection.kt（四方向）
//
//  绘制用 drawRect:（不建子视图）：手柄是整块图形，
//  十几个子视图反而更慢，且 hitTest 还是要自己算区域。
//

#import "A2GamepadView.h"
#import "A2ControlLayout.h"
#import "A2ThemeManager.h"
#import "A2KeyCodeMap.h"

/// 区域 → 映射字典里的键名（与 ZL2 GamepadMap identifier 对应）
static NSString *A2GamepadRegionKey(A2GamepadRegion r) {
    switch (r) {
        case A2GamepadRegionA:         return @"a";
        case A2GamepadRegionB:         return @"b";
        case A2GamepadRegionX:         return @"x";
        case A2GamepadRegionY:         return @"y";
        case A2GamepadRegionStart:     return @"start";
        case A2GamepadRegionSelect:    return @"select";
        case A2GamepadRegionDpadUp:    return @"dpad_up";
        case A2GamepadRegionDpadDown:  return @"dpad_down";
        case A2GamepadRegionDpadLeft:  return @"dpad_left";
        case A2GamepadRegionDpadRight: return @"dpad_right";
        default:                       return @"";
    }
}

/// ZL2 GamepadMap 的游戏内默认键位
static NSString *A2GamepadDefaultKey(A2GamepadRegion r) {
    switch (r) {
        case A2GamepadRegionA:         return @"32";       // SPACE
        case A2GamepadRegionB:         return @"340";      // LEFT_SHIFT
        case A2GamepadRegionX:         return @"290";      // F1
        case A2GamepadRegionY:         return @"69";       // E
        case A2GamepadRegionStart:     return @"256";      // ESCAPE
        case A2GamepadRegionSelect:    return @"2";        // 鼠标中键
        case A2GamepadRegionDpadUp:    return @"294";      // F5
        case A2GamepadRegionDpadDown:  return @"81";       // Q
        case A2GamepadRegionDpadLeft:  return @"70";       // F
        case A2GamepadRegionDpadRight: return @"84";       // T
        default:                       return nil;
    }
}

@interface A2GamepadView ()
@property (nonatomic, assign, readwrite) A2GamepadRegion activeRegion;
@end

@implementation A2GamepadView

- (instancetype)initWithWidget:(A2ControlWidget *)widget {
    self = [super initWithWidget:widget];
    if (!self) return nil;

    _activeRegion = A2GamepadRegionNone;
    self.titleLabel.hidden = YES;
    self.backgroundColor = UIColor.clearColor;
    self.layer.borderWidth = 0;
    self.accessibilityLabel = @"屏幕手柄";
    self.multipleTouchEnabled = YES;
    return self;
}

#pragma mark - 映射

- (NSString *)keyForRegion:(A2GamepadRegion)region {
    if (region == A2GamepadRegionNone) return nil;

    NSString *name = A2GamepadRegionKey(region);
    NSString *mapped = self.widget.gamepadMapping[name];
    if (mapped.length) return mapped;
    return A2GamepadDefaultKey(region);
}

#pragma mark - 几何

- (CGRect)dpadRect {
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat side = MIN(w * 0.46, h * 0.92);
    return CGRectMake(w * 0.02, (h - side) / 2, side, side);
}

- (CGFloat)abxyRadius {
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    return MIN(w, h) * 0.115;
}

- (CGPoint)abxyCenter {
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat side = MIN(w * 0.46, h * 0.92);
    CGFloat cx = w - side * 0.62 - w * 0.02;
    return CGPointMake(cx, h * 0.44);
}

- (CGPoint)centerForRegion:(A2GamepadRegion)region {
    CGPoint c = [self abxyCenter];
    CGFloat r = [self abxyRadius] * 1.15;
    switch (region) {
        case A2GamepadRegionY: return CGPointMake(c.x, c.y - r);
        case A2GamepadRegionA: return CGPointMake(c.x, c.y + r);
        case A2GamepadRegionX: return CGPointMake(c.x - r, c.y);
        case A2GamepadRegionB: return CGPointMake(c.x + r, c.y);
        default: return c;
    }
}

- (CGRect)pillRectForRegion:(A2GamepadRegion)region {
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat side = MIN(w * 0.46, h * 0.92);
    CGFloat pw = side * 0.32;
    CGFloat ph = side * 0.16;
    CGFloat cy = h - ph * 0.75;
    CGFloat cx = region == A2GamepadRegionStart ? w * 0.62 : w * 0.82;
    return CGRectMake(cx - pw / 2, cy - ph / 2, pw, ph);
}

/// 点 → 区域（纯几何，不依赖子视图）
- (A2GamepadRegion)regionAtPoint:(CGPoint)p {
    CGRect dpad = [self dpadRect];
    if (CGRectContainsPoint(dpad, p)) {
        CGFloat cx = CGRectGetMidX(dpad);
        CGFloat cy = CGRectGetMidY(dpad);
        CGFloat dx = p.x - cx;
        CGFloat dy = p.y - cy;
        CGFloat dead = dpad.size.width * 0.10;
        if (hypot(dx, dy) < dead) return A2GamepadRegionNone;
        if (fabs(dx) > fabs(dy)) {
            return dx > 0 ? A2GamepadRegionDpadRight : A2GamepadRegionDpadLeft;
        }
        return dy > 0 ? A2GamepadRegionDpadDown : A2GamepadRegionDpadUp;
    }

    CGFloat r = [self abxyRadius];
    A2GamepadRegion faces[] = {A2GamepadRegionY, A2GamepadRegionA,
                               A2GamepadRegionX, A2GamepadRegionB};
    for (size_t i = 0; i < sizeof(faces) / sizeof(faces[0]); i++) {
        CGPoint c = [self centerForRegion:faces[i]];
        if (hypot(p.x - c.x, p.y - c.y) <= r) return faces[i];
    }

    if (CGRectContainsPoint([self pillRectForRegion:A2GamepadRegionStart], p)) {
        return A2GamepadRegionStart;
    }
    if (CGRectContainsPoint([self pillRectForRegion:A2GamepadRegionSelect], p)) {
        return A2GamepadRegionSelect;
    }
    return A2GamepadRegionNone;
}

#pragma mark - 触摸

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) {
        [super touchesBegan:touches withEvent:event];
        return;
    }
    UITouch *t = touches.anyObject;
    if (!t) return;
    [self switchToRegion:[self regionAtPoint:[t locationInView:self]]];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) return;
    UITouch *t = touches.anyObject;
    if (!t) return;

    A2GamepadRegion region = [self regionAtPoint:[t locationInView:self]];
    if (region != self.activeRegion) [self switchToRegion:region];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) {
        [super touchesEnded:touches withEvent:event];
        return;
    }
    [self switchToRegion:A2GamepadRegionNone];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) {
        [super touchesCancelled:touches withEvent:event];
        return;
    }
    [self switchToRegion:A2GamepadRegionNone];
}

/// 区域切换 = 旧区域抬起 + 新区域按下。
/// 单触点场景下不需要引用计数，但走 dispatcher 才能正确区分鼠标键/滚轮。
- (void)switchToRegion:(A2GamepadRegion)region {
    if (region == self.activeRegion) return;

    A2GamepadRegion old = self.activeRegion;
    self.activeRegion = region;

    if (old != A2GamepadRegionNone) {
        NSString *key = [self keyForRegion:old];
        if (key.length) [self.input releaseEventKey:key];
    }
    if (region != A2GamepadRegionNone) {
        NSString *key = [self keyForRegion:region];
        if (key.length) [self.input pressEventKey:key];
    }

    [self setNeedsDisplay];
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
    if (!newWindow) [self switchToRegion:A2GamepadRegionNone];
}

#pragma mark - 绘制

- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];

    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    UIColor *line = [t.cOnSurface colorWithAlphaComponent:0.45];
    UIColor *fill = [t.cOnSurface colorWithAlphaComponent:0.10];
    UIColor *active = [t.cPrimary colorWithAlphaComponent:0.55];

    // ---- D-pad：十字由两条圆角矩形叠出来 ----
    CGRect dpad = [self dpadRect];
    CGFloat arm = dpad.size.width * 0.32;
    CGFloat thick = dpad.size.width * 0.28;

    UIBezierPath *vertical = [UIBezierPath bezierPathWithRoundedRect:
        CGRectMake(CGRectGetMidX(dpad) - thick / 2, CGRectGetMinY(dpad),
                   thick, dpad.size.height)
        cornerRadius:thick * 0.28];
    UIBezierPath *horizontal = [UIBezierPath bezierPathWithRoundedRect:
        CGRectMake(CGRectGetMinX(dpad), CGRectGetMidY(dpad) - thick / 2,
                   dpad.size.width, thick)
        cornerRadius:thick * 0.28];

    BOOL dpadActive = self.activeRegion == A2GamepadRegionDpadUp ||
                      self.activeRegion == A2GamepadRegionDpadDown ||
                      self.activeRegion == A2GamepadRegionDpadLeft ||
                      self.activeRegion == A2GamepadRegionDpadRight;
    [dpadActive ? active : fill setFill];
    [vertical fill];
    [horizontal fill];

    [line setStroke];
    vertical.lineWidth = 1.2;
    horizontal.lineWidth = 1.2;
    [vertical stroke];
    [horizontal stroke];

    // 方向小三角
    [[UIColor colorWithWhite:1.0 alpha:0.65] setFill];
    for (int i = 0; i < 4; i++) {
        CGPoint c = CGPointZero;
        CGFloat s = arm * 0.5;
        switch (i) {
            case 0: c = CGPointMake(CGRectGetMidX(dpad), CGRectGetMinY(dpad) + arm * 0.55); break;
            case 1: c = CGPointMake(CGRectGetMidX(dpad), CGRectGetMaxY(dpad) - arm * 0.55); break;
            case 2: c = CGPointMake(CGRectGetMinX(dpad) + arm * 0.55, CGRectGetMidY(dpad)); break;
            default: c = CGPointMake(CGRectGetMaxX(dpad) - arm * 0.55, CGRectGetMidY(dpad)); break;
        }
        CGPoint p[3];
        if (i == 0) { p[0] = CGPointMake(c.x, c.y - s); p[1] = CGPointMake(c.x - s, c.y + s); p[2] = CGPointMake(c.x + s, c.y + s); }
        else if (i == 1) { p[0] = CGPointMake(c.x, c.y + s); p[1] = CGPointMake(c.x - s, c.y - s); p[2] = CGPointMake(c.x + s, c.y - s); }
        else if (i == 2) { p[0] = CGPointMake(c.x - s, c.y); p[1] = CGPointMake(c.x + s, c.y - s); p[2] = CGPointMake(c.x + s, c.y + s); }
        else { p[0] = CGPointMake(c.x + s, c.y); p[1] = CGPointMake(c.x - s, c.y - s); p[2] = CGPointMake(c.x - s, c.y + s); }
        UIBezierPath *tri = [UIBezierPath bezierPath];
        [tri moveToPoint:p[0]];
        [tri addLineToPoint:p[1]];
        [tri addLineToPoint:p[2]];
        [tri closePath];
        [tri fill];
    }

    // ---- ABXY ----
    CGFloat r = [self abxyRadius];
    struct { A2GamepadRegion region; const char *label; } faces[] = {
        {A2GamepadRegionY, "Y"},
        {A2GamepadRegionA, "A"},
        {A2GamepadRegionX, "X"},
        {A2GamepadRegionB, "B"},
    };
    UIFont *font = [UIFont systemFontOfSize:MAX(9, r * 0.9) weight:UIFontWeightSemibold];
    for (size_t i = 0; i < sizeof(faces) / sizeof(faces[0]); i++) {
        CGPoint c = [self centerForRegion:faces[i]];
        BOOL isActive = (self.activeRegion == faces[i].region);

        CGRect box = CGRectMake(c.x - r, c.y - r, r * 2, r * 2);
        UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:box];
        [isActive ? active : fill setFill];
        [circle fill];
        [line setStroke];
        circle.lineWidth = 1.2;
        [circle stroke];

        NSString *label = @(faces[i].label);
        CGSize size = [label sizeWithAttributes:@{NSFontAttributeName: font}];
        [label drawAtPoint:CGPointMake(c.x - size.width / 2, c.y - size.height / 2)
            withAttributes:@{
                NSFontAttributeName: font,
                NSForegroundColorAttributeName: t.cOnSurface,
            }];
    }

    // ---- START / SELECT ----
    for (int i = 0; i < 2; i++) {
        A2GamepadRegion region = (i == 0) ? A2GamepadRegionStart : A2GamepadRegionSelect;
        CGRect box = [self pillRectForRegion:region];
        UIBezierPath *pill = [UIBezierPath bezierPathWithRoundedRect:box
                                                       cornerRadius:box.size.height / 2];
        [self.activeRegion == region ? active : fill setFill];
        [pill fill];
        [line setStroke];
        pill.lineWidth = 1.0;
        [pill stroke];

        NSString *label = (i == 0) ? @"▶" : @"■";
        UIFont *pf = [UIFont systemFontOfSize:MAX(7, box.size.height * 0.55)
                                        weight:UIFontWeightMedium];
        CGSize size = [label sizeWithAttributes:@{NSFontAttributeName: pf}];
        [label drawAtPoint:CGPointMake(CGRectGetMidX(box) - size.width / 2,
                                       CGRectGetMidY(box) - size.height / 2)
            withAttributes:@{
                NSFontAttributeName: pf,
                NSForegroundColorAttributeName: [t.cOnSurface colorWithAlphaComponent:0.8],
            }];
    }
}

#pragma mark - 主题

- (void)applyTheme {
    self.backgroundColor = UIColor.clearColor;
    [self setNeedsDisplay];
}

- (void)setActiveRegion:(A2GamepadRegion)activeRegion {
    _activeRegion = activeRegion;
    [self setNeedsDisplay];
}

@end
