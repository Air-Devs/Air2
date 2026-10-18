//
//  A2GameControlsView.m
//  Air2
//

#import "A2GameControlsView.h"
#import "a2_log.h"

// GLFW 键码（与 Java 侧 GLFW.java 常量一致）
static const int kKeyW = 87, kKeyA = 65, kKeyS = 83, kKeyD = 68;
static const int kKeySpace = 32;
static const int kKeyLeftShift = 340;
static const int kKeyLeftControl = 341;

static const int kKeyE    = 69;
static const int kKeyF3   = 292;
static const int kMouseLeft = 0, kMouseRight = 1;

static NSString *const kA2MoveModeKey  = @"A2MoveMode";
static NSString *const kA2LayoutsKey   = @"A2ControlLayouts";     // {方案名: {id: {x,y,w,h,a}}}
static NSString *const kA2LayoutCurKey = @"A2ControlLayoutCurrent";
static NSString *const kA2BindingsKey  = @"A2ControlBindings";   // {控件id: GLFW键码}

/// 输入层：把一次输入合成进 GLFW 事件总线（实现见 Natives/Input/a2_glfw_input.m）
extern void a2_glfw_input_post_key(long window, int key, int action);
extern void a2_glfw_input_post_mouse_button(long window, int button, int action);
extern void a2_glfw_input_post_char(long window, int codepoint, int mods);

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
// 前置声明：这些在 @implementation 里定义得较晚，self.xxx 的点语法需要先见到声明
- (UIViewController *)a2_topViewController;
- (NSArray<UIView *> *)a2_movableViews;
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
    UIButton *_attackButton;
    UIButton *_useButton;
    UIButton *_inventoryButton;
    UIButton *_f3Button;
    UIButton *_keyboardButton;
    UIButton *_editButton;
    NSMutableArray<UIButton *> *_hotbar;
    NSMutableDictionary<NSString *, UIView *> *_movable;   // 可自定义的控件（编辑模式用）
    UITextField *_kbField;
    BOOL _kbVisible;
    BOOL _editing;
    NSMutableDictionary<NSString *, NSNumber *> *_bindings;   // 控件id -> GLFW 键码
    NSMutableDictionary<NSString *, NSValue *> *_restFrames;  // 编辑前位置（取消用）


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
        _hotbar = [NSMutableArray array];
        _movable = [NSMutableDictionary dictionary];
        _bindings = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kA2BindingsKey] mutableCopy]
                    ?: [NSMutableDictionary dictionary];
        _restFrames = [NSMutableDictionary dictionary];

        [self a2_buildDPad];
        [self a2_buildStick];
        [self a2_buildJump];
        [self a2_buildActionButtons];
        [self a2_buildHotbar];
        [self a2_buildKeyboardField];
        [self a2_applyMode];
        [self a2_applySavedLayout];
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

#pragma mark - 阶段2：右侧按钮

- (void)a2_buildActionButtons {
    _attackButton = [self a2_makeButton:@"攻"];
    [_attackButton addTarget:self action:@selector(a2_attackDown) forControlEvents:UIControlEventTouchDown];
    [_attackButton addTarget:self action:@selector(a2_attackUp) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    [self addSubview:_attackButton];
    _movable[@"attack"] = _attackButton;

    _useButton = [self a2_makeButton:@"用"];
    [_useButton addTarget:self action:@selector(a2_useDown) forControlEvents:UIControlEventTouchDown];
    [_useButton addTarget:self action:@selector(a2_useUp) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    [self addSubview:_useButton];
    _movable[@"use"] = _useButton;

    _inventoryButton = [self a2_makeButton:@"包"];
    [_inventoryButton addTarget:self action:@selector(a2_tapE) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_inventoryButton];
    _movable[@"inventory"] = _inventoryButton;

    _f3Button = [self a2_makeButton:@"F3"];
    [_f3Button addTarget:self action:@selector(a2_tapF3) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_f3Button];
    _movable[@"f3"] = _f3Button;

    _keyboardButton = [self a2_makeButton:@"⌨"];
    [_keyboardButton addTarget:self action:@selector(a2_toggleKeyboard) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_keyboardButton];
    _movable[@"keyboard"] = _keyboardButton;

    _editButton = [self a2_makeButton:@"⚙"];
    [_editButton addTarget:self action:@selector(a2_toggleEdit) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_editButton];
    _movable[@"edit"] = _editButton;

    for (NSString *cid in _movable) {
        UIView *v = _movable[cid];
        v.translatesAutoresizingMaskIntoConstraints = YES;
        v.bounds = CGRectMake(0, 0, 60, 60);
        [v addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(a2_dragItem:)]];
        [v addGestureRecognizer:[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(a2_pinchItem:)]];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(a2_tapControl:)];
        [v addGestureRecognizer:tap];
    }
    _attackButton.bounds    = CGRectMake(0, 0, 76, 76);
    _useButton.bounds       = CGRectMake(0, 0, 76, 76);
    _inventoryButton.bounds = CGRectMake(0, 0, 56, 56);
    _f3Button.bounds        = CGRectMake(0, 0, 56, 56);
    _keyboardButton.bounds  = CGRectMake(0, 0, 56, 56);
    _editButton.bounds      = CGRectMake(0, 0, 44, 44);
    [self a2_layoutDefaultButtons];
}

- (void)a2_layoutDefaultButtons {
    CGFloat W = CGRectGetWidth(self.bounds)  > 0 ? CGRectGetWidth(self.bounds)  : 874;
    CGFloat H = CGRectGetHeight(self.bounds) > 0 ? CGRectGetHeight(self.bounds) : 402;
    _attackButton.center    = CGPointMake(W - 70,  H - 62);
    _useButton.center       = CGPointMake(W - 152, H - 62);
    _inventoryButton.center = CGPointMake(W - 44,  52);
    _f3Button.center        = CGPointMake(W - 108, 52);
    _keyboardButton.center  = CGPointMake(W - 172, 52);
    _editButton.center      = CGPointMake(W - 224, 52);
}

#pragma mark - 阶段3：热键条 + 系统键盘

- (void)a2_buildHotbar {
    for (int i = 1; i <= 9; i++) {
        UIButton *b = [self a2_makeButton:[NSString stringWithFormat:@"%d", i]];
        b.tag = i;
        b.translatesAutoresizingMaskIntoConstraints = YES;
        b.bounds = CGRectMake(0, 0, 36, 36);
        [b addTarget:self action:@selector(a2_hot:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:b];
        [_hotbar addObject:b];
        _movable[[NSString stringWithFormat:@"hot%d", i]] = b;
        [b addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(a2_dragItem:)]];
    }
    [self a2_layoutHotbar];
}

- (void)a2_layoutHotbar {
    CGFloat W = CGRectGetWidth(self.bounds)  > 0 ? CGRectGetWidth(self.bounds)  : 874;
    CGFloat H = CGRectGetHeight(self.bounds) > 0 ? CGRectGetHeight(self.bounds) : 402;
    CGFloat total = 9 * 36 + 8 * 6;
    CGFloat x = (W - total) * 0.5 + 18;
    for (UIButton *b in _hotbar) {
        b.center = CGPointMake(x, H - 42);
        x += 42;
    }
}

- (void)a2_hot:(UIButton *)sender {
    int key = 48 + (int) sender.tag;
    a2_glfw_input_post_key(_window, key, 1);
    a2_glfw_input_post_key(_window, key, 0);
}

- (void)a2_buildKeyboardField {
    _kbField = [[UITextField alloc] initWithFrame:CGRectMake(-1000, -1000, 1, 1)];
    _kbField.delegate = (id<UITextFieldDelegate>) self;
    _kbField.autocorrectionType = UITextAutocorrectionTypeNo;
    _kbField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [self addSubview:_kbField];
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    if (string.length == 0) {
        a2_glfw_input_post_key(_window, 259, 1);
        a2_glfw_input_post_key(_window, 259, 0);
        return NO;
    }
    for (NSUInteger i = 0; i < string.length; i++) {
        a2_glfw_input_post_char(_window, (int)[string characterAtIndex:i], 0);
    }
    return NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    a2_glfw_input_post_key(_window, 257, 1);
    a2_glfw_input_post_key(_window, 257, 0);
    return NO;
}

- (void)a2_toggleKeyboard {
    _kbVisible = !_kbVisible;
    if (_kbVisible) {
        _kbField.text = @" ";
        [_kbField becomeFirstResponder];
        _keyboardButton.backgroundColor = [UIColor colorWithRed:0.42 green:0.65 blue:1.0 alpha:0.45];
        a2_log_f(@"[A2-CONTROLS] 系统键盘 唤出");
    } else {
        [_kbField resignFirstResponder];
        _kbField.text = @"";
        _keyboardButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        a2_log_f(@"[A2-CONTROLS] 系统键盘 收回");
    }
}

#pragma mark - 动作

- (void)a2_attackDown { a2_glfw_input_post_mouse_button(_window, kMouseLeft, 1);  _attackButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.30]; }
- (void)a2_attackUp   { a2_glfw_input_post_mouse_button(_window, kMouseLeft, 0);  _attackButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14]; }
- (void)a2_useDown    { a2_glfw_input_post_mouse_button(_window, kMouseRight, 1); _useButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.30]; }
- (void)a2_useUp      { a2_glfw_input_post_mouse_button(_window, kMouseRight, 0); _useButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14]; }
- (void)a2_tapE       { [self a2_pressBound:@"inventory" fallback:kKeyE]; }
- (void)a2_tapF3      { [self a2_pressBound:@"f3" fallback:kKeyF3]; }

#pragma mark - 阶段4/5：自定义 + 多方案

- (void)a2_toggleEdit {
    _editing = !_editing;
    _editButton.backgroundColor = _editing
        ? [UIColor colorWithRed:0.42 green:0.65 blue:1.0 alpha:0.45]
        : [UIColor colorWithWhite:1.0 alpha:0.14];
    if (!_editing) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"控件编辑"
                                                                  message:@"拖动=移动；双指捏=大小；可存多套方案"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"保存到当前方案" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf a2_saveLayout];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"新建方案…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf a2_askNewLayoutName];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"切换方案" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf a2_presentLayoutPicker];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"恢复默认布局" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [weakSelf a2_layoutDefaultButtons];
        [weakSelf a2_layoutHotbar];
        for (UIView *v in weakSelf.a2_movableViews) v.alpha = 1.0;
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"完成" style:UIAlertActionStyleCancel handler:nil]];

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = self;
        sheet.popoverPresentationController.sourceRect = _editButton.frame;
    }
    [self.a2_topViewController presentViewController:sheet animated:YES completion:nil];
}

- (NSArray<UIView *> *)a2_movableViews {
    NSMutableArray *all = [NSMutableArray array];
    for (UIView *v in _movable.allValues) [all addObject:v];
    [all addObjectsFromArray:_hotbar];
    return all;
}

- (void)a2_dragItem:(UIPanGestureRecognizer *)pan {
    if (!_editing) return;
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:self];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [pan setTranslation:CGPointZero inView:self];
}

- (void)a2_pinchItem:(UIPinchGestureRecognizer *)pinch {
    if (!_editing) return;
    UIView *v = pinch.view;
    CGFloat s = pinch.scale;
    v.bounds = CGRectMake(0, 0, MAX(28, v.bounds.size.width * s), MAX(28, v.bounds.size.height * s));
    pinch.scale = 1.0;
}

- (void)a2_askNewLayoutName {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建方案"
                                                                  message:@"给它起个名字"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"方案名"; }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0) name = @"自定义";
        [NSUserDefaults.standardUserDefaults setObject:name forKey:kA2LayoutCurKey];
        [weakSelf a2_saveLayout];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self.a2_topViewController presentViewController:alert animated:YES completion:nil];
}

- (void)a2_presentLayoutPicker {
    NSDictionary *store = [NSUserDefaults.standardUserDefaults dictionaryForKey:kA2LayoutsKey] ?: @{};
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择方案"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSString *name in store.allKeys) {
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [NSUserDefaults.standardUserDefaults setObject:name forKey:kA2LayoutCurKey];
            [weakSelf a2_applySavedLayout];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self.a2_topViewController presentViewController:sheet animated:YES completion:nil];
}

- (void)a2_saveLayout {
    NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:kA2LayoutCurKey] ?: @"默认";
    NSMutableDictionary *store = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kA2LayoutsKey] mutableCopy]
                                 ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    for (NSString *cid in _movable) {
        UIView *v = _movable[cid];
        entry[cid] = @{ @"x": @(v.center.x), @"y": @(v.center.y),
                        @"w": @(v.bounds.size.width), @"h": @(v.bounds.size.height),
                        @"a": @(v.alpha) };
    }
    for (NSUInteger i = 0; i < _hotbar.count; i++) {
        UIView *v = _hotbar[i];
        NSString *cid = [NSString stringWithFormat:@"hot%lu", (unsigned long)(i + 1)];
        entry[cid] = @{ @"x": @(v.center.x), @"y": @(v.center.y),
                        @"w": @(v.bounds.size.width), @"h": @(v.bounds.size.height),
                        @"a": @(v.alpha) };
    }
    store[name] = entry;
    [NSUserDefaults.standardUserDefaults setObject:store forKey:kA2LayoutsKey];
    a2_log_f(@"[A2-CONTROLS] 方案已保存：%@（%lu 项）", name, (unsigned long) entry.count);
}

- (void)a2_applySavedLayout {
    if (CGRectGetWidth(self.bounds) <= 0) return;
    NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:kA2LayoutCurKey] ?: @"默认";
    NSDictionary *store = [NSUserDefaults.standardUserDefaults dictionaryForKey:kA2LayoutsKey];
    NSDictionary *entry = store[name];
    if (![entry isKindOfClass:NSDictionary.class]) return;

    for (NSString *cid in entry) {
        UIView *v = _movable[cid];
        if (v == nil && [cid hasPrefix:@"hot"]) {
            NSInteger idx = [[cid substringFromIndex:3] integerValue];
            if (idx >= 1 && idx <= (NSInteger) _hotbar.count) v = _hotbar[(NSUInteger)(idx - 1)];
        }
        if (v == nil) continue;
        NSDictionary *e = entry[cid];
        v.bounds = CGRectMake(0, 0, [e[@"w"] doubleValue], [e[@"h"] doubleValue]);
        v.center = CGPointMake([e[@"x"] doubleValue], [e[@"y"] doubleValue]);
        v.alpha = [e[@"a"] doubleValue] > 0 ? [e[@"a"] doubleValue] : 1.0;
    }
}


#pragma mark - 任意键绑定

/// 取某控件当前绑定的键码（没绑过就用默认）。
- (int)a2_keyForControl:(NSString *)cid fallback:(int)def {
    NSNumber *n = _bindings[cid];
    return n != nil ? n.intValue : def;
}

- (void)a2_setKey:(int)key forControl:(NSString *)cid {
    _bindings[cid] = @(key);
    [NSUserDefaults.standardUserDefaults setObject:_bindings forKey:kA2BindingsKey];
    a2_log_f(@"[A2-CONTROLS] 控件 %@ 绑定键码 %d", cid, key);
}

/// 编辑模式下点控件 = 改键位（拖动/捏合仍用于位置与大小）。
- (void)a2_tapControl:(UITapGestureRecognizer *)tap {
    if (!_editing) return;
    NSString *cid = nil;
    for (NSString *k in _movable) { if (_movable[k] == tap.view) { cid = k; break; } }
    if (cid == nil) return;
    [self a2_presentKeyPickerFor:cid];
}

- (void)a2_presentKeyPickerFor:(NSString *)cid {
    NSArray<NSArray *> *groups = @[
        @[ @"W", @87 ], @[ @"A", @65 ], @[ @"S", @83 ], @[ @"D", @68 ],
        @[ @"空格", @32 ], @[ @"Shift", @340 ], @[ @"Ctrl", @341 ],
        @[ @"E 背包", @69 ], @[ @"Q 丢弃", @81 ], @[ @"T 聊天", @84 ],
        @[ @"Esc", @256 ], @[ @"Enter", @257 ], @[ @"F1", @290 ], @[ @"F3", @292 ], @[ @"F5", @294 ],
        @[ @"鼠标左键", @(-1) ], @[ @"鼠标右键", @(-2) ],
    ];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"绑定按键"
                                                                  message:[NSString stringWithFormat:@"控件：%@", cid]
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSArray *g in groups) {
        [sheet addAction:[UIAlertAction actionWithTitle:g[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            int code = [g[1] intValue];
            if (code == -1)      { [weakSelf a2_setKey:-1 forControl:cid]; }
            else if (code == -2) { [weakSelf a2_setKey:-2 forControl:cid]; }
            else                 { [weakSelf a2_setKey:code forControl:cid]; }
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = self;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.bounds),
                                                                   CGRectGetMidY(self.bounds), 1, 1);
    }
    [self.a2_topViewController presentViewController:sheet animated:YES completion:nil];
}

/// 按绑定发一次「按下+抬起」（-1/-2 走鼠标左右键）。
- (void)a2_pressBound:(NSString *)cid fallback:(int)def {
    int code = [self a2_keyForControl:cid fallback:def];
    if (code == -1) { a2_glfw_input_post_mouse_button(_window, 0, 1); a2_glfw_input_post_mouse_button(_window, 0, 0); return; }
    if (code == -2) { a2_glfw_input_post_mouse_button(_window, 1, 1); a2_glfw_input_post_mouse_button(_window, 1, 0); return; }
    a2_glfw_input_post_key(_window, code, 1);
    a2_glfw_input_post_key(_window, code, 0);
}


@end
