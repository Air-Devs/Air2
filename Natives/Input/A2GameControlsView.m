//
//  A2GameControlsView.m
//  Air2
//

#import "A2GameControlsView.h"

// GLFW 键码（与 Java 侧 GLFW.java 常量一致）
static const int kKeyW = 87, kKeyA = 65, kKeyS = 83, kKeyD = 68;
static const int kKeySpace = 32;
static const int kKeyLeftShift = 340;
static const int kKeyLeftControl = 341;

static NSString *const kA2MoveModeKey = @"A2MoveMode";

/// 输入层：把一次按键合成进 GLFW 事件总线（实现见 Natives/Input/a2_glfw_input.m）
extern void a2_glfw_input_post_key(long window, int key, int action);

#pragma mark - 摇杆

@protocol A2StickDelegate <NSObject>
- (void)a2Stick:(UIView *)stick didChangeDirection:(CGPoint)dir sprint:(BOOL)sprint;
- (void)a2StickDidTapCenter:(UIView *)stick;
@end

/// 圆形摇杆：拖动 → 方向向量；超阈值 → 疾跑；轻点中心 → 潜行开关（由外部处理）
@interface A2StickView : UIView
@property (nonatomic, weak) id<A2StickDelegate> delegate;
@end

@implementation A2StickView {
    CGPoint _center;
    CGFloat _radius;
    CGPoint _knob;
    BOOL _dragging;
    CGPoint _touchDownPoint;
    CFTimeInterval _touchDownTime;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.multipleTouchEnabled = NO;
        self.exclusiveTouch = YES;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    _radius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5;
    if (CGPointEqualToPoint(_knob, CGPointZero)) {
        _knob = _center;
    }
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor colorWithWhite:1.0 alpha:0.10] setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(_center.x - _radius, _center.y - _radius,
                                               _radius * 2, _radius * 2));
    [[UIColor colorWithWhite:1.0 alpha:0.25] setStroke];
    CGContextSetLineWidth(ctx, 2.0);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(_center.x - _radius, _center.y - _radius,
                                                 _radius * 2, _radius * 2));

    CGFloat knobR = _radius * 0.34;
    [[UIColor colorWithWhite:1.0 alpha:0.35] setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(_knob.x - knobR, _knob.y - knobR,
                                               knobR * 2, knobR * 2));
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    CGPoint p = [t locationInView:self];
    _dragging = YES;
    _touchDownPoint = p;
    _touchDownTime = CACurrentMediaTime();
    _knob = p;
    [self setNeedsDisplay];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_dragging) return;
    UITouch *t = [touches anyObject];
    CGPoint p = [t locationInView:self];
    _knob = p;

    CGFloat dx = p.x - _center.x;
    CGFloat dy = p.y - _center.y;
    CGFloat len = sqrt(dx * dx + dy * dy);
    CGFloat dead = _radius * 0.18;
    if (len < dead) {
        [self.delegate a2Stick:self didChangeDirection:CGPointZero sprint:NO];
        [self setNeedsDisplay];
        return;
    }
    CGFloat nx = dx / len, ny = dy / len;
    // 疾跑 = 拖出半径的 80%
    BOOL sprint = (len > _radius * 0.80);
    [self.delegate a2Stick:self didChangeDirection:CGPointMake(nx, ny) sprint:sprint];
    [self setNeedsDisplay];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    CGPoint p = [t locationInView:self];
    CFTimeInterval dt = CACurrentMediaTime() - _touchDownTime;
    CGFloat moved = hypot(p.x - _touchDownPoint.x, p.y - _touchDownPoint.y);

    _dragging = NO;
    _knob = _center;
    [self.delegate a2Stick:self didChangeDirection:CGPointZero sprint:NO];

    // 轻点中心（位移很小 + 时间很短）= 潜行开关
    if (dt < 0.35 && moved < _radius * 0.20) {
        CGFloat d2center = hypot(p.x - _center.x, p.y - _center.y);
        if (d2center < _radius * 0.45) {
            [self.delegate a2StickDidTapCenter:self];
        }
    }
    [self setNeedsDisplay];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _dragging = NO;
    _knob = _center;
    [self.delegate a2Stick:self didChangeDirection:CGPointZero sprint:NO];
    [self setNeedsDisplay];
}

@end

#pragma mark - 控件主视图

@interface A2GameControlsView () <A2StickDelegate>
@end

@implementation A2GameControlsView {
    long _window;
    A2MoveMode _moveMode;

    UIView *_dpadContainer;
    NSMutableDictionary<NSNumber *, UIButton *> *_dirButtons;   // key -> button
    UIButton *_sneakButton;

    A2StickView *_stick;

    UIButton *_jumpButton;

    // 方向状态（0/1）
    BOOL _pressed[4];           // W A S D
    BOOL _sneaking;
    BOOL _sprintHeld;
    NSTimeInterval _lastTapTime[4];
}

- (instancetype)initWithWindowHandle:(long)window {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _window = window;
        NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:kA2MoveModeKey];
        _moveMode = (saved == A2MoveModeStick) ? A2MoveModeStick : A2MoveModeDPad;
        self.backgroundColor = [UIColor clearColor];
        self.multipleTouchEnabled = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        for (int i = 0; i < 4; i++) {
            _lastTapTime[i] = 0;
            _pressed[i] = NO;
        }
        [self a2_buildDPad];
        [self a2_buildStick];
        [self a2_buildJump];
        [self a2_applyMode];
    }
    return self;
}

#pragma mark - 构建

- (UIButton *)a2_makeButton:(NSString *)title {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    b.layer.cornerRadius = 14.0;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.9] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    b.exclusiveTouch = YES;
    return b;
}

- (void)a2_buildDPad {
    _dpadContainer = [[UIView alloc] initWithFrame:CGRectZero];
    _dpadContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _dpadContainer.backgroundColor = [UIColor clearColor];
    _dpadContainer.multipleTouchEnabled = YES;
    [self addSubview:_dpadContainer];

    _dirButtons = [NSMutableDictionary dictionary];
    NSArray *titles = @[ @"W", @"A", @"S", @"D" ];
    int keys[4] = { kKeyW, kKeyA, kKeyS, kKeyD };
    for (int i = 0; i < 4; i++) {
        UIButton *b = [self a2_makeButton:titles[i]];
        b.tag = keys[i];
        [b addTarget:self action:@selector(a2_dirTouchDown:) forControlEvents:UIControlEventTouchDown];
        [b addTarget:self action:@selector(a2_dirTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [_dpadContainer addSubview:b];
        _dirButtons[@(keys[i])] = b;
    }

    _sneakButton = [self a2_makeButton:@"潜"];
    _sneakButton.tag = kKeyLeftShift;
    [_sneakButton addTarget:self action:@selector(a2_toggleSneak) forControlEvents:UIControlEventTouchUpInside];
    [_dpadContainer addSubview:_sneakButton];

    // 十字布局（相对容器）
    UIView *w = _dirButtons[@(kKeyW)], *a = _dirButtons[@(kKeyA)], *s = _dirButtons[@(kKeyS)], *d = _dirButtons[@(kKeyD)];
    [NSLayoutConstraint activateConstraints:@[
        [_dpadContainer.leadingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor constant:24],
        [_dpadContainer.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-24],
        [_dpadContainer.widthAnchor constraintEqualToConstant:190],
        [_dpadContainer.heightAnchor constraintEqualToConstant:190],

        [w.topAnchor constraintEqualToAnchor:_dpadContainer.topAnchor],
        [w.centerXAnchor constraintEqualToAnchor:_dpadContainer.centerXAnchor],
        [w.widthAnchor constraintEqualToConstant:56], [w.heightAnchor constraintEqualToConstant:56],

        [a.leadingAnchor constraintEqualToAnchor:_dpadContainer.leadingAnchor],
        [a.centerYAnchor constraintEqualToAnchor:_dpadContainer.centerYAnchor],
        [a.widthAnchor constraintEqualToConstant:56], [a.heightAnchor constraintEqualToConstant:56],

        [d.trailingAnchor constraintEqualToAnchor:_dpadContainer.trailingAnchor],
        [d.centerYAnchor constraintEqualToAnchor:_dpadContainer.centerYAnchor],
        [d.widthAnchor constraintEqualToConstant:56], [d.heightAnchor constraintEqualToConstant:56],

        [s.bottomAnchor constraintEqualToAnchor:_dpadContainer.bottomAnchor],
        [s.centerXAnchor constraintEqualToAnchor:_dpadContainer.centerXAnchor],
        [s.widthAnchor constraintEqualToConstant:56], [s.heightAnchor constraintEqualToConstant:56],

        [_sneakButton.centerXAnchor constraintEqualToAnchor:_dpadContainer.centerXAnchor],
        [_sneakButton.centerYAnchor constraintEqualToAnchor:_dpadContainer.centerYAnchor],
        [_sneakButton.widthAnchor constraintEqualToConstant:52], [_sneakButton.heightAnchor constraintEqualToConstant:52],
    ]];
}

- (void)a2_buildStick {
    _stick = [[A2StickView alloc] initWithFrame:CGRectZero];
    _stick.translatesAutoresizingMaskIntoConstraints = NO;
    _stick.delegate = self;
    [self addSubview:_stick];

    [NSLayoutConstraint activateConstraints:@[
        [_stick.leadingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor constant:24],
        [_stick.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-24],
        [_stick.widthAnchor constraintEqualToConstant:190],
        [_stick.heightAnchor constraintEqualToConstant:190],
    ]];
}

- (void)a2_buildJump {
    _jumpButton = [self a2_makeButton:@"跳"];
    _jumpButton.tag = kKeySpace;
    [_jumpButton addTarget:self action:@selector(a2_jumpDown) forControlEvents:UIControlEventTouchDown];
    [_jumpButton addTarget:self action:@selector(a2_jumpUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self addSubview:_jumpButton];

    [NSLayoutConstraint activateConstraints:@[
        [_jumpButton.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor constant:-28],
        [_jumpButton.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-32],
        [_jumpButton.widthAnchor constraintEqualToConstant:72],
        [_jumpButton.heightAnchor constraintEqualToConstant:72],
    ]];
}

#pragma mark - 模式

- (A2MoveMode)moveMode { return _moveMode; }

- (void)setMoveMode:(A2MoveMode)mode {
    if (mode == _moveMode) return;
    [self a2_releaseAll];
    _moveMode = mode;
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:kA2MoveModeKey];
    [self a2_applyMode];
}

- (void)a2_applyMode {
    BOOL stick = (_moveMode == A2MoveModeStick);
    _dpadContainer.hidden = stick;
    _stick.hidden = !stick;
}

#pragma mark - 分键

- (void)a2_dirTouchDown:(UIButton *)sender {
    int key = (int) sender.tag;
    int idx = [self a2_indexForKey:key];
    if (idx < 0) return;

    // 快速点两下同一个方向 = 疾跑
    NSTimeInterval now = CACurrentMediaTime();
    BOOL doubleTap = (now - _lastTapTime[idx]) < 0.30;
    _lastTapTime[idx] = now;

    if (!_pressed[idx]) {
        _pressed[idx] = YES;
        a2_glfw_input_post_key(_window, key, 1);
    }
    if (doubleTap && !_sprintHeld) {
        _sprintHeld = YES;
        a2_glfw_input_post_key(_window, kKeyLeftControl, 1);
    }
    sender.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
}

- (void)a2_dirTouchUp:(UIButton *)sender {
    int key = (int) sender.tag;
    int idx = [self a2_indexForKey:key];
    if (idx < 0) return;
    if (_pressed[idx]) {
        _pressed[idx] = NO;
        a2_glfw_input_post_key(_window, key, 0);
    }
    // 松开方向 → 放掉疾跑
    if (_sprintHeld) {
        _sprintHeld = NO;
        a2_glfw_input_post_key(_window, kKeyLeftControl, 0);
    }
    sender.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
}

- (int)a2_indexForKey:(int)key {
    switch (key) {
        case kKeyW: return 0;
        case kKeyA: return 1;
        case kKeyS: return 2;
        case kKeyD: return 3;
        default: return -1;
    }
}

#pragma mark - 潜行 / 跳跃

- (void)a2_toggleSneak {
    _sneaking = !_sneaking;
    a2_glfw_input_post_key(_window, kKeyLeftShift, _sneaking ? 1 : 0);
    _sneakButton.backgroundColor = _sneaking
        ? [UIColor colorWithRed:0.42 green:0.65 blue:1.0 alpha:0.45]
        : [UIColor colorWithWhite:1.0 alpha:0.14];
}

- (void)a2_jumpDown {
    a2_glfw_input_post_key(_window, kKeySpace, 1);
    _jumpButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
}

- (void)a2_jumpUp {
    a2_glfw_input_post_key(_window, kKeySpace, 0);
    _jumpButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
}

#pragma mark - 摇杆回调

- (void)a2Stick:(UIView *)stick didChangeDirection:(CGPoint)dir sprint:(BOOL)sprint {
    BOOL wantW = NO, wantA = NO, wantS = NO, wantD = NO;
    if (dir.x != 0 || dir.y != 0) {
        // 8 向：按象限取两轴
        CGFloat ax = fabs(dir.x), ay = fabs(dir.y);
        if (ay > 0.38) { if (dir.y < 0) wantW = YES; else wantS = YES; }
        if (ax > 0.38) { if (dir.x < 0) wantA = YES; else wantD = YES; }
    }
    [self a2_setKey:kKeyW on:wantW];
    [self a2_setKey:kKeyA on:wantA];
    [self a2_setKey:kKeyS on:wantS];
    [self a2_setKey:kKeyD on:wantD];

    if (sprint != _sprintHeld) {
        _sprintHeld = sprint;
        a2_glfw_input_post_key(_window, kKeyLeftControl, sprint ? 1 : 0);
    }
}

- (void)a2StickDidTapCenter:(UIView *)stick {
    [self a2_toggleSneak];
}

- (void)a2_setKey:(int)key on:(BOOL)on {
    int idx = [self a2_indexForKey:key];
    if (idx < 0) return;
    if (_pressed[idx] == on) return;
    _pressed[idx] = on;
    a2_glfw_input_post_key(_window, key, on ? 1 : 0);
}

#pragma mark - 收尾

/// 移除/切换模式前把按住的键全部放开，避免"卡住一直走"
- (void)a2_releaseAll {
    for (int i = 0; i < 4; i++) {
        if (_pressed[i]) {
            int keys[4] = { kKeyW, kKeyA, kKeyS, kKeyD };
            a2_glfw_input_post_key(_window, keys[i], 0);
            _pressed[i] = NO;
        }
    }
    if (_sprintHeld) {
        _sprintHeld = NO;
        a2_glfw_input_post_key(_window, kKeyLeftControl, 0);
    }
}

/// ★关键★ 空白区域不能吃触摸：否则游戏/视角触摸全被这层挡住。
/// 只在命中子控件（按钮/摇杆）时返回它，点空白返回 nil ⇒ 事件落到下面的游戏视图。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
    if (newWindow == nil) {
        [self a2_releaseAll];
        if (_sneaking) {
            _sneaking = NO;
            a2_glfw_input_post_key(_window, kKeyLeftShift, 0);
        }
    }
}

@end
