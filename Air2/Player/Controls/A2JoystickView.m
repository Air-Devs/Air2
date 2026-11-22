//
//  A2JoystickView.m
//  Air2
//
//  实现见 .h。几何/方向判定的数学部分逐条对照 ZL2：
//    ui/control/gamepad/Joystick.kt
//      · calculateAcceleration()  = magnitude^2（上限 1）
//      · calculateDirection()     = ((angleDeg + 22.5) / 45) % 8
//      · onTick()                 = 按 deltaMs/16ms 归一化，上限 4 倍
//    ui/control/joystick/_Movement.kt
//      · 斜向方向 = 两个基础方向键同时按下
//

#import "A2JoystickView.h"
#import "A2ThemeManager.h"
#import "A2Logger.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

/// 采样基准周期（ms）—— ZL2 的 BASE_TICK_MS
static const double kBaseTickMs = 16.0;
/// 单次偏移量最大时间倍率 —— ZL2 的 MAX_TIME_SCALE
static const double kMaxTimeScale = 4.0;
/// 方向滞回角（度）。扇区宽 45°，留 12° 余量避免边界抖键。
static const double kDirectionHysteresisDeg = 12.0;

#pragma mark - 方向工具

/// 方向 → ZL2 directionEvents 的键名
static NSString *A2DirectionKey(A2JoystickDirection d) {
    switch (d) {
        case A2JoystickDirectionEast:      return @"east";
        case A2JoystickDirectionNorthEast: return @"north_east";
        case A2JoystickDirectionNorth:     return @"north";
        case A2JoystickDirectionNorthWest: return @"north_west";
        case A2JoystickDirectionWest:      return @"west";
        case A2JoystickDirectionSouthWest: return @"south_west";
        case A2JoystickDirectionSouth:     return @"south";
        case A2JoystickDirectionSouthEast: return @"south_east";
        default:                           return @"";
    }
}

/// 方向的扇区中心角（度，数学坐标系：east=0，逆时针为正）
static double A2DirectionCenterDeg(A2JoystickDirection d) {
    switch (d) {
        case A2JoystickDirectionEast:      return 0;
        case A2JoystickDirectionNorthEast: return 45;
        case A2JoystickDirectionNorth:     return 90;
        case A2JoystickDirectionNorthWest: return 135;
        case A2JoystickDirectionWest:      return 180;
        case A2JoystickDirectionSouthWest: return 225;
        case A2JoystickDirectionSouth:     return 270;
        case A2JoystickDirectionSouthEast: return 315;
        default:                           return NAN;
    }
}

@interface A2JoystickView ()

@property (nonatomic, strong) UIView *outerRing;
@property (nonatomic, strong) UIView *knob;
@property (nonatomic, assign) CGPoint knobOffset;

/// 当前按住的事件键集合（集合差分 → press/release）
@property (nonatomic, strong) NSMutableSet<NSString *> *pressedKeys;

@property (nonatomic, assign) A2JoystickDirection direction;
@property (nonatomic, assign) CGFloat magnitude;

/// ROCKER 模式的持续输出
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval lastTickTimestamp;
@property (nonatomic, assign) CGPoint rockerUnit;   ///< 单位方向（屏幕坐标）
@end

@implementation A2JoystickView

- (instancetype)initWithWidget:(A2ControlWidget *)widget {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    _widget = widget;
    _deadZone = (widget.deadZone > 0 && widget.deadZone < 0.9) ? widget.deadZone : 0.15;
    _triggerMode = widget.triggerMode;
    _mouseSensitivity = 900;
    _pressedKeys = [NSMutableSet set];
    _direction = A2JoystickDirectionNone;
    _magnitude = 0;

    // 四个方向键默认 WASD（与三家默认布局一致）
    _upKey = @"87";
    _downKey = @"83";
    _leftKey = @"65";
    _rightKey = @"68";

    self.backgroundColor = UIColor.clearColor;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"摇杆";

    _outerRing = [[UIView alloc] initWithFrame:CGRectZero];
    _outerRing.userInteractionEnabled = NO;
    _outerRing.layer.borderWidth = 2;
    [self addSubview:_outerRing];

    _knob = [[UIView alloc] initWithFrame:CGRectZero];
    _knob.userInteractionEnabled = NO;
    [self addSubview:_knob];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.maximumNumberOfTouches = 1;
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

    CGFloat knobSize = side * 0.45;
    _knob.bounds = CGRectMake(0, 0, knobSize, knobSize);
    _knob.layer.cornerRadius = knobSize / 2;
    _knob.center = CGPointMake(CGRectGetMidX(_outerRing.frame) + _knobOffset.x,
                               CGRectGetMidY(_outerRing.frame) + _knobOffset.y);
}

#pragma mark - 输入

- (A2ControlInputDispatcher *)input {
    if (!_input) {
        _input = [A2ControlInputDispatcher dispatcherWithDelegate:self.inputDelegate];
    }
    return _input;
}

- (void)setInputDelegate:(id<A2ControlInputDelegate>)inputDelegate {
    _inputDelegate = inputDelegate;
    _input.delegate = inputDelegate;
}

- (void)setTriggerMode:(A2JoystickTriggerMode)triggerMode {
    _triggerMode = triggerMode;
    if (triggerMode == A2JoystickTriggerModeDirection) {
        [self stopRockerTimer];
    }
}

#pragma mark - 手势

- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled ||
        g.state == UIGestureRecognizerStateFailed) {
        [self resetToCenter];
        return;
    }

    CGPoint center = CGPointMake(CGRectGetMidX(_outerRing.frame),
                                 CGRectGetMidY(_outerRing.frame));
    CGPoint loc = [g locationInView:self];
    CGPoint delta = CGPointMake(loc.x - center.x, loc.y - center.y);

    CGFloat radius = CGRectGetWidth(_outerRing.bounds) / 2;
    if (radius <= 1) return;
    CGFloat dist = hypot(delta.x, delta.y);

    // ---- 摇杆头视觉：限制在半径内 ----
    CGFloat maxDist = radius - CGRectGetWidth(_knob.bounds) / 2;
    if (maxDist < 1) maxDist = radius;
    CGPoint visual = delta;
    if (dist > maxDist && dist > 0) {
        visual.x = delta.x / dist * maxDist;
        visual.y = delta.y / dist * maxDist;
    }
    _knobOffset = visual;
    [self setNeedsLayout];

    // ---- 死区重标定 ----
    // 旧实现用 dist/radius 判方向，死区附近会反复触发；
    // 这里先把死区扣掉再归一化，输出始终是平滑的 0~1。
    CGFloat rawMagnitude = MIN(1.0, dist / radius);
    CGFloat normalized = 0;
    if (rawMagnitude > self.deadZone) {
        normalized = (rawMagnitude - self.deadZone) / MAX(0.01, 1.0 - self.deadZone);
    }
    normalized = MAX(0.0, MIN(1.0, normalized));
    _magnitude = normalized;

    // ---- 方向判定（带滞回）----
    A2JoystickDirection newDirection = A2JoystickDirectionNone;
    if (normalized > 0) {
        double angleDeg = atan2(-delta.y, delta.x) * 180.0 / M_PI;   // 屏幕 y 向下 → 取负
        if (angleDeg < 0) angleDeg += 360.0;

        double prevCenter = A2DirectionCenterDeg(_direction);
        BOOL keepPrevious = !isnan(prevCenter) &&
            fabs(remainder(angleDeg - prevCenter, 360.0)) <= (22.5 + kDirectionHysteresisDeg);

        if (keepPrevious) {
            newDirection = _direction;
        } else {
            NSInteger index = ((NSInteger)floor((angleDeg + 22.5) / 45.0)) % 8;
            if (index < 0) index += 8;
            newDirection = (A2JoystickDirection)index;
        }
    }
    _direction = newDirection;

    if (self.triggerMode == A2JoystickTriggerModeDirection) {
        [self applyDirectionKeys];
    } else {
        [self updateRockerUnitWithDelta:delta];
        [self startRockerTimerIfNeeded];
    }
}

/// 当前方向对应的事件键集合。
/// 优先用 widget.directionEvents（ZL2/FCL 导入的真实配置），
/// 没有就退回 up/down/left/right 四个属性（旧 API）。
- (NSSet<NSString *> *)keysForDirection:(A2JoystickDirection)d {
    if (d == A2JoystickDirectionNone) return [NSSet set];

    NSDictionary<NSString *, NSArray<A2ControlEvent *> *> *events = self.widget.directionEvents;
    NSArray<A2ControlEvent *> *list = events[A2DirectionKey(d)];

    NSMutableSet<NSString *> *out = [NSMutableSet set];
    if (list.count) {
        for (A2ControlEvent *e in list) {
            NSString *key = [A2ControlEventKey normalizedKey:e.key];
            if (key.length) [out addObject:key];
        }
        return out;
    }

    // 退化路径：四方向属性
    switch (d) {
        case A2JoystickDirectionNorth:
            if (self.upKey.length) [out addObject:self.upKey];
            break;
        case A2JoystickDirectionSouth:
            if (self.downKey.length) [out addObject:self.downKey];
            break;
        case A2JoystickDirectionWest:
            if (self.leftKey.length) [out addObject:self.leftKey];
            break;
        case A2JoystickDirectionEast:
            if (self.rightKey.length) [out addObject:self.rightKey];
            break;
        case A2JoystickDirectionNorthEast:
            if (self.upKey.length) [out addObject:self.upKey];
            if (self.rightKey.length) [out addObject:self.rightKey];
            break;
        case A2JoystickDirectionNorthWest:
            if (self.upKey.length) [out addObject:self.upKey];
            if (self.leftKey.length) [out addObject:self.leftKey];
            break;
        case A2JoystickDirectionSouthEast:
            if (self.downKey.length) [out addObject:self.downKey];
            if (self.rightKey.length) [out addObject:self.rightKey];
            break;
        case A2JoystickDirectionSouthWest:
            if (self.downKey.length) [out addObject:self.downKey];
            if (self.leftKey.length) [out addObject:self.leftKey];
            break;
        default:
            break;
    }
    return out;
}

/// 集合差分：新集合 - 旧集合 = 要按下的；旧 - 新 = 要抬起的。
/// 这样斜向切单向时只换一个键，不会把整组键抬起来重按（ZL2 也是这个思路）。
- (void)applyDirectionKeys {
    NSSet<NSString *> *target = [self keysForDirection:self.direction];
    if ([target isEqualToSet:self.pressedKeys]) return;

    NSMutableSet *toRelease = [self.pressedKeys mutableCopy];
    [toRelease minusSet:target];
    NSMutableSet *toPress = [target mutableCopy];
    [toPress minusSet:self.pressedKeys];

    for (NSString *key in toRelease) {
        [self.input releaseEventKey:key];
    }
    for (NSString *key in toPress) {
        [self.input pressEventKey:key];
    }

    self.pressedKeys = [target mutableCopy];
}

#pragma mark - ROCKER 模式

- (void)updateRockerUnitWithDelta:(CGPoint)delta {
    CGFloat len = hypot(delta.x, delta.y);
    if (len < 1) {
        _rockerUnit = CGPointZero;
        return;
    }
    _rockerUnit = CGPointMake(delta.x / len, delta.y / len);
}

- (void)startRockerTimerIfNeeded {
    if (self.displayLink) return;
    // CADisplayLink 在 iOS 上就是 60/120Hz 的 VSync 回调，
    // 与 ZL2 用协程 tick 的节奏等价；dt 由 timestamp 差分给出。
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self
                                                      selector:@selector(onRockerTick:)];
    link.preferredFramesPerSecond = 60;
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.displayLink = link;
    self.lastTickTimestamp = 0;
}

- (void)stopRockerTimer {
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.lastTickTimestamp = 0;
}

- (void)onRockerTick:(CADisplayLink *)link {
    if (self.triggerMode != A2JoystickTriggerModeRocker || _magnitude <= 0) {
        [self stopRockerTimer];
        return;
    }

    double deltaMs = kBaseTickMs;
    if (self.lastTickTimestamp > 0) {
        deltaMs = (link.timestamp - self.lastTickTimestamp) * 1000.0;
    }
    self.lastTickTimestamp = link.timestamp;
    if (!isfinite(deltaMs) || deltaMs <= 0) deltaMs = kBaseTickMs;

    double timeScale = MAX(0.0, MIN(kMaxTimeScale, deltaMs / kBaseTickMs));

    // ZL2 的加速度：magnitude^2（MOUSE_MAX_ACCELERATION = 2.0）
    double accel = pow(_magnitude, 2.0);
    if (accel > 1.0) accel = 1.0;

    // 像素/秒 → 本帧位移
    double perSecond = self.mouseSensitivity * accel;
    double dx = _rockerUnit.x * perSecond * (deltaMs / 1000.0);
    double dy = _rockerUnit.y * perSecond * (deltaMs / 1000.0);

    // timeScale 只影响上限保护，避免掉帧后一帧跳很远
    dx = MAX(-self.mouseSensitivity, MIN(self.mouseSensitivity, dx * MIN(1.0, timeScale)));
    dy = MAX(-self.mouseSensitivity, MIN(self.mouseSensitivity, dy * MIN(1.0, timeScale)));

    if (fabs(dx) >= 0.01 || fabs(dy) >= 0.01) {
        [self.input moveMouseBy:CGPointMake(dx, dy)];
    }

    // 方向变化也要通知（游戏内可能用于疾跑等）
    [self applyDirectionKeys];
}

#pragma mark - 复位

- (void)resetToCenter {
    [self stopRockerTimer];

    for (NSString *key in self.pressedKeys) {
        [self.input releaseEventKey:key];
    }
    [self.pressedKeys removeAllObjects];

    _direction = A2JoystickDirectionNone;
    _magnitude = 0;
    _knobOffset = CGPointZero;
    _rockerUnit = CGPointZero;
    [self setNeedsLayout];
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
    // 离开屏幕必须释放 —— 否则会"粘键"（老实现也是这个理由）
    if (!newWindow) [self resetToCenter];
}

- (void)dealloc {
    [_displayLink invalidate];
    _displayLink = nil;
    // dealloc 里直接调自己会经 _input（weak delegate 可能已释放，安全）
    for (NSString *key in _pressedKeys) {
        [_input releaseEventKey:key];
    }
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _outerRing.layer.borderColor = [t.cOnSurface colorWithAlphaComponent:0.4].CGColor;
    _outerRing.backgroundColor = [t.cOnSurface colorWithAlphaComponent:0.08];
    _knob.backgroundColor = [t.cOnSurface colorWithAlphaComponent:0.55];
}

@end
