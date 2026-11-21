//
//  A2JoystickView.m
//  Air2
//

#import "A2JoystickView.h"
#import "A2ThemeManager.h"

@interface A2JoystickView ()
@property (nonatomic, strong) UIView *outerRing;
@property (nonatomic, strong) UIView *knob;
@property (nonatomic, assign) CGPoint knobOffset;
/// 当前已按下的方向（避免重复发送按键）
@property (nonatomic, assign) BOOL upPressed;
@property (nonatomic, assign) BOOL downPressed;
@property (nonatomic, assign) BOOL leftPressed;
@property (nonatomic, assign) BOOL rightPressed;
@end

@implementation A2JoystickView

- (instancetype)initWithWidget:(A2ControlWidget *)widget {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _widget = widget;
    _deadZone = 0.15;

    // 默认方向键（WASD）—— 与三家默认布局一致
    _upKey = @"87";     // W
    _downKey = @"83";   // S
    _leftKey = @"65";   // A
    _rightKey = @"68";  // D

    self.backgroundColor = UIColor.clearColor;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"摇杆";

    // 外圈
    _outerRing = [[UIView alloc] initWithFrame:CGRectZero];
    _outerRing.userInteractionEnabled = NO;
    _outerRing.layer.borderWidth = 2;
    [self addSubview:_outerRing];

    // 摇杆头
    _knob = [[UIView alloc] initWithFrame:CGRectZero];
    _knob.userInteractionEnabled = NO;
    [self addSubview:_knob];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];

    [self applyTheme];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
    _outerRing.frame = CGRectMake((self.bounds.size.width - side) / 2,
                                  (self.bounds.size.height - side) / 2,
                                  side, side);
    _outerRing.layer.cornerRadius = side / 2;

    // 摇杆头 = 外圈的 45%
    CGFloat knobSize = side * 0.45;
    _knob.bounds = CGRectMake(0, 0, knobSize, knobSize);
    _knob.layer.cornerRadius = knobSize / 2;
    _knob.center = CGPointMake(CGRectGetMidX(_outerRing.frame) + _knobOffset.x,
                               CGRectGetMidY(_outerRing.frame) + _knobOffset.y);
}

#pragma mark - 交互

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint center = CGPointMake(CGRectGetMidX(_outerRing.frame),
                                 CGRectGetMidY(_outerRing.frame));
    CGPoint loc = [g locationInView:self];

    CGPoint delta = CGPointMake(loc.x - center.x, loc.y - center.y);
    CGFloat radius = CGRectGetWidth(_outerRing.bounds) / 2;
    CGFloat dist = hypot(delta.x, delta.y);

    // 限制摇杆头在半径内
    CGFloat maxDist = radius - CGRectGetWidth(_knob.bounds) / 2;
    if (dist > maxDist && dist > 0) {
        delta.x = delta.x / dist * maxDist;
        delta.y = delta.y / dist * maxDist;
    }

    _knobOffset = delta;
    [self setNeedsLayout];

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        // 回中 → 全部释放
        _knobOffset = CGPointZero;
        [self setNeedsLayout];
        [self releaseAllDirections];
        return;
    }

    // 按位移判定方向。死区内的位移不触发。
    CGFloat normX = dist > 0 ? delta.x / radius : 0;
    CGFloat normY = dist > 0 ? delta.y / radius : 0;
    BOOL outOfDeadZone = (dist / radius) > self.deadZone;

    [self setDirection:@"up"    pressed:outOfDeadZone && normY < -self.deadZone key:self.upKey];
    [self setDirection:@"down"  pressed:outOfDeadZone && normY >  self.deadZone key:self.downKey];
    [self setDirection:@"left"  pressed:outOfDeadZone && normX < -self.deadZone key:self.leftKey];
    [self setDirection:@"right" pressed:outOfDeadZone && normX >  self.deadZone key:self.rightKey];
}

/// 设置某个方向的按下状态。
/// 只在状态【变化】时发按键 —— 否则每帧都发 press 会把游戏输入打爆。
- (void)setDirection:(NSString *)dir pressed:(BOOL)pressed key:(NSString *)key {
    if (key.length == 0) return;

    BOOL *flag = NULL;
    if ([dir isEqualToString:@"up"]) flag = &_upPressed;
    else if ([dir isEqualToString:@"down"]) flag = &_downPressed;
    else if ([dir isEqualToString:@"left"]) flag = &_leftPressed;
    else if ([dir isEqualToString:@"right"]) flag = &_rightPressed;
    if (!flag) return;

    if (*flag == pressed) return;   // 没变化
    *flag = pressed;

    if (pressed) {
        [self.inputDelegate controlPressKey:key];
    } else {
        [self.inputDelegate controlReleaseKey:key];
    }
}

- (void)releaseAllDirections {
    [self setDirection:@"up"    pressed:NO key:self.upKey];
    [self setDirection:@"down"  pressed:NO key:self.downKey];
    [self setDirection:@"left"  pressed:NO key:self.leftKey];
    [self setDirection:@"right" pressed:NO key:self.rightKey];
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
    // 离开屏幕时确保按键已释放 —— 否则会"粘键"
    if (!newWindow) [self releaseAllDirections];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _outerRing.layer.borderColor = [t.cOnSurface colorWithAlphaComponent:0.4].CGColor;
    _outerRing.backgroundColor = [t.cOnSurface colorWithAlphaComponent:0.08];
    _knob.backgroundColor = [t.cOnSurface colorWithAlphaComponent:0.55];
}

@end
