//
//  A2GameControlsView.m
//  Air2
//

#import "A2GameControlsView.h"
#include <sys/sysctl.h>
#include <string.h>
#import "a2_log.h"
#import "A2ControlLayoutIO.h"

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
// ★移动键布局版本★ 1 = 旧（W/A/S/D/潜 默认坐标写在左上角）
//                      2 = 整簇容器锚定左下角（已被撤掉：簇容器让五键无法单独编辑）
//                      3 = 五键各自独立控件，默认坐标分别落在左下角安全区
static NSString *const kA2CtrlLayoutVerKey = @"A2ControlLayoutVersion";
static const NSInteger kA2CtrlLayoutVer = 3;

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
        // ★摇杆不独占触摸★ 否则拖动摇杆时其它按钮收不到触摸（真机：摇杆移动中点不了别的键）
        self.multipleTouchEnabled = YES;
        self.exclusiveTouch = NO;
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
    // ★疾跑阈值★ iPad 上摇杆半径大、手指位移也大，80% 容易误判成疾跑
    //   ⇒ iPad 抬到 92%；另外允许用 A2StickSprintThreshold(0~1) 覆盖。
    double th = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) ? 0.92 : 0.80;
    id ov = [NSUserDefaults.standardUserDefaults objectForKey:@"A2StickSprintThreshold"];
    if (ov != nil) {
        double v = [NSUserDefaults.standardUserDefaults doubleForKey:@"A2StickSprintThreshold"];
        if (v > 0.3 && v <= 1.0) th = v;
    }
    BOOL sprint = (len > _radius * th);
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
- (void)a2_buildMoveKeys;
- (NSArray<UIView *> *)a2_moveKeyViews;
- (void)a2_layoutDefaultMoveKeys;
- (void)a2_placeMoveKey:(UIView *)v center:(CGPoint)c size:(CGFloat)s;
- (void)a2_logControlLayout;
@end

@implementation A2GameControlsView {
    long _window;
    A2MoveMode _moveMode;

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
    UIButton *_escButton;
    NSMutableArray<UIButton *> *_hotbar;
    NSMutableDictionary<NSString *, UIView *> *_movable;   // 可自定义的控件（编辑模式用）
    UITextField *_kbField;
    BOOL _kbVisible;
    BOOL _editing;
    NSTimer *_useWatchdog;
    NSTimer *_attackWatchdog;
    UIView *_selectionHandle;      // 选中框右下角的缩放把手
    __weak UIView *_selectedControl;
    NSMutableDictionary<NSString *, NSString *> *_customTitles;  // 自定义键 id → 显示名
    NSMutableSet<NSString *> *_removedIds;                        // 被删除的内置键 id
    NSString *_pendingCid;                                        // 正在等待选键的控件 id
    NSMutableArray<NSNumber *> *_comboBuffer;                     // 组合键选择缓冲
    NSString *_latchedCid;                                        // 已锁存(按住)修饰键的控件
    int _latchedModifier;                                         // 锁存中的 F 键码
    __weak UIView *_keypadMask;                                   // 键盘面板遮罩（供关闭用）
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
        _customTitles = [NSMutableDictionary dictionary];
        _removedIds = [NSMutableSet set];
        [NSNotificationCenter.defaultCenter addObserver:self
                                              selector:@selector(a2_layoutChanged:)
                                                  name:@"A2ControlLayoutChanged"
                                                object:nil];
        _bindings = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kA2BindingsKey] mutableCopy]
                    ?: [NSMutableDictionary dictionary];
        _restFrames = [NSMutableDictionary dictionary];

        [self a2_buildMoveKeys];
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
    return b;
}

/// ★五键各自独立★ W/A/S/D/潜 直接挂在控件层上（不是容器里的子键）：
///   与跳/攻/用/ESC 同级别 ⇒ 通用 60×60 循环给它们配同样的 pan/pinch/tap/长按手势，
///   编辑器里可以逐个选中、拖动、缩放、改键、删除、单独存进布局。
- (void)a2_buildMoveKeys {
    _dirButtons = [NSMutableDictionary dictionary];
    NSArray *ids    = @[ @"w", @"a", @"s", @"d" ];
    NSArray *titles = @[ @"W", @"A", @"S", @"D" ];
    int keys[4] = { kKeyW, kKeyA, kKeyS, kKeyD };
    for (int i = 0; i < 4; i++) {
        UIButton *b = [self a2_makeButton:titles[i]];
        b.tag = keys[i];
        b.translatesAutoresizingMaskIntoConstraints = YES;
        b.bounds = CGRectMake(0, 0, 60, 60);
        [b addTarget:self action:@selector(a2_dirTouchDown:) forControlEvents:UIControlEventTouchDown];
        [b addTarget:self action:@selector(a2_dirTouchUp:) forControlEvents:UIControlEventTouchUpInside |
                                                               UIControlEventTouchUpOutside |
                                                               UIControlEventTouchCancel];
        [self addSubview:b];
        _dirButtons[@(keys[i])] = b;
        _movable[ids[i]] = b;
    }

    _sneakButton = [self a2_makeButton:@"潜"];
    _sneakButton.tag = kKeyLeftShift;
    _sneakButton.translatesAutoresizingMaskIntoConstraints = YES;
    _sneakButton.bounds = CGRectMake(0, 0, 60, 60);
    [_sneakButton addTarget:self action:@selector(a2_toggleSneak) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_sneakButton];
    _movable[@"sneak"] = _sneakButton;
}

/// 移动五键（顺序固定：W/A/S/D/潜）
- (NSArray<UIView *> *)a2_moveKeyViews {
    NSMutableArray *a = [NSMutableArray array];
    int keys[4] = { kKeyW, kKeyA, kKeyS, kKeyD };
    for (int i = 0; i < 4; i++) {
        UIButton *b = _dirButtons[@(keys[i])];
        if (b != nil) [a addObject:b];
    }
    if (_sneakButton != nil) [a addObject:_sneakButton];
    return a;
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
    _jumpButton.translatesAutoresizingMaskIntoConstraints = YES;
    _jumpButton.bounds = CGRectMake(0, 0, 76, 76);
    [_jumpButton addTarget:self action:@selector(a2_jumpDown) forControlEvents:UIControlEventTouchDown];
    [_jumpButton addTarget:self action:@selector(a2_jumpUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self addSubview:_jumpButton];
    _movable[@"jump"] = _jumpButton;
    {
        UIPanGestureRecognizer *jp = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(a2_dragItem:)];
        jp.cancelsTouchesInView = YES;
        [_jumpButton addGestureRecognizer:jp];
    }
    [_jumpButton addGestureRecognizer:[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(a2_pinchItem:)]];
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
    // ★五键各自独立★ 摇杆模式下逐个隐藏（没有容器了）
    for (UIView *v in [self a2_moveKeyViews]) v.hidden = stick;
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
static int a2_touchSeen = 0;

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit != nil && hit != self && a2_touchSeen < 3) {
        a2_touchSeen++;
        NSLog(@"[A2-CONTROLS] 触摸命中控件层 #%d (hit=%@)", a2_touchSeen, NSStringFromClass(hit.class));
    }
    return (hit == self) ? nil : hit;
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
    if (newWindow == nil) {
        [self a2_releaseLatchedIfAny];
        [_useWatchdog invalidate]; _useWatchdog = nil;
        [_attackWatchdog invalidate]; _attackWatchdog = nil;
        a2_glfw_input_post_mouse_button(_window, kMouseLeft, 0);
        a2_glfw_input_post_mouse_button(_window, kMouseRight, 0);
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

    _escButton = [self a2_makeButton:@"ESC"];
    [_escButton addTarget:self action:@selector(a2_tapEsc) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_escButton];
    _movable[@"esc"] = _escButton;

    // ★方向键/潜行专用的 pan 白名单★ 这五键按住时不能被 pan 抢走触摸（见下面循环里的注释）。
    static NSSet<NSString *> *a2PanNoCancelIds = nil;
    static dispatch_once_t a2PanNoCancelOnce;
    dispatch_once(&a2PanNoCancelOnce, ^{
        a2PanNoCancelIds = [NSSet setWithObjects:@"w", @"a", @"s", @"d", @"sneak", nil];
    });
    NSMutableArray<NSString *> *a2PanNoCancelHit = [NSMutableArray array];

    for (NSString *cid in _movable) {
        UIView *v = _movable[cid];
        // ★五键与其它键同级别★ W/A/S/D/潜 也是普通控件：统一 60×60 起手，
        //   位置/大小由 a2_layoutDefaultButtons 里的 a2_layoutDefaultMoveKeys 单独给。
        v.translatesAutoresizingMaskIntoConstraints = YES;
        v.bounds = CGRectMake(0, 0, 60, 60);
        // ★手势绝不能吞掉按钮自身的触摸★
        //   默认 cancelsTouchesInView=YES ⇒ 轻点一旦被手势识别，UIButton 的
        //   touch-up 就被取消 ⇒ 只有高亮、动作永不执行（真机现象："右上四键有高亮没作用"）。
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(a2_dragItem:)];
        // ★方向键/潜行例外★ 按住 W/A/S/D/潜 时手指常会滑出按钮范围：cancelsTouchesInView=YES
        //   会让 pan 一识别就取消 UIButton 的触摸 ⇒ 键在半路松开（走着走着停一下）。
        //   这五键改成 NO：触摸继续送到按钮，松手才 touch-up；拖动布局照旧由 pan 处理。
        BOOL a2IsMoveKey = [a2PanNoCancelIds containsObject:cid];
        pan.cancelsTouchesInView = a2IsMoveKey ? NO : YES;   // ★滑动=取消按钮点击(区分滑动与轻点)
        if (a2IsMoveKey) [a2PanNoCancelHit addObject:cid];
        [v addGestureRecognizer:pan];

        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(a2_pinchItem:)];
        pinch.cancelsTouchesInView = NO;
        [v addGestureRecognizer:pinch];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(a2_tapControl:)];
        tap.cancelsTouchesInView = NO;
        [v addGestureRecognizer:tap];

        UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(a2_longPressControl:)];
        hold.minimumPressDuration = 0.6;
        hold.cancelsTouchesInView = NO;
        [v addGestureRecognizer:hold];
    }

    // ★一次性自证日志★ 明确列出哪些键的 pan 不吞触摸，其余键仍是 YES
    static BOOL a2PanLogOnce = NO;
    if (!a2PanLogOnce) {
        a2PanLogOnce = YES;
        NSArray *sorted = [a2PanNoCancelHit sortedArrayUsingSelector:@selector(compare:)];
        a2_log_f(@"[A2-CTRL-PAN] pan.cancelsTouchesInView=NO 的键：%@（其余键保持 YES）",
                 [sorted componentsJoinedByString:@","]);
    }
    _attackButton.bounds    = CGRectMake(0, 0, 76, 76);
    _useButton.bounds       = CGRectMake(0, 0, 76, 76);
    _inventoryButton.bounds = CGRectMake(0, 0, 56, 56);
    _f3Button.bounds        = CGRectMake(0, 0, 56, 56);
    _keyboardButton.bounds  = CGRectMake(0, 0, 56, 56);
    _escButton.bounds       = CGRectMake(0, 0, 56, 56);
    [self a2_layoutDefaultButtons];
}

- (void)a2_layoutDefaultButtons {
    CGFloat W = CGRectGetWidth(self.bounds)  > 0 ? CGRectGetWidth(self.bounds)  : 874;
    CGFloat H = CGRectGetHeight(self.bounds) > 0 ? CGRectGetHeight(self.bounds) : 402;

    // ★五键★ W/A/S/D/潜 各自独立，默认坐标分别算到左下角安全区
    [self a2_layoutDefaultMoveKeys];

    // 右下：跳 / 攻 / 用 三个分开摆（原来三者叠在一起）
    _jumpButton.center      = CGPointMake(W - 74,  H - 150);
    _attackButton.center    = CGPointMake(W - 74,  H - 62);
    _useButton.center       = CGPointMake(W - 158, H - 62);

    // 右上：下移到 y=96，避开刘海/状态条那一条"点不动"的区域；新增 ESC
    _inventoryButton.center = CGPointMake(W - 46,  96);
    _f3Button.center        = CGPointMake(W - 110, 96);
    _keyboardButton.center  = CGPointMake(W - 174, 96);
    _escButton.center       = CGPointMake(W - 302, 96);
}

#pragma mark - 默认布局：W/A/S/D/潜 五个独立键

/// ★只改默认坐标，不做容器★ 把五个键**分别**摆到左下角安全区内：
///   · 先用与原十字簇同一套几何（边长 side = 短边 × 0.42，键 b = side × 0.30，潜 = 0.9b）
///     算出五键的中心点 ⇒ 它们之间的相对排布/间距与旧版一模一样，只是不再有容器视图。
///   · 留白 = 安全区 + 与屏幕成比例的基础留白（≥12pt）⇒ 横屏刘海（左）/Home 条（下）都不遮键。
///   · 与底部 1..9 热键条水平相交时把整块抬到热键条上方 ⇒ 不压热键条。
- (void)a2_layoutDefaultMoveKeys {
    CGFloat W = CGRectGetWidth(self.bounds)  > 0 ? CGRectGetWidth(self.bounds)  : 874;
    CGFloat H = CGRectGetHeight(self.bounds) > 0 ? CGRectGetHeight(self.bounds) : 402;
    UIEdgeInsets sa = self.safeAreaInsets;

    CGFloat shortSide = MIN(W, H);
    if (shortSide <= 1) shortSide = 402;
    CGFloat side = shortSide * 0.42;                 // 五键占用的方块边长：iPhone 402 ⇒ ≈169；iPad 603 ⇒ ≈253
    side = MIN(MAX(side, 132.0), 320.0);             // 上下限：小屏仍可点，大屏别虚胖
    CGFloat pad = MAX(12.0, shortSide * 0.030);      // 与屏宽成比例的基础留白（iPhone ≈12）
    CGFloat left   = MAX(sa.left, 0.0)   + pad;      // 横屏刘海在左
    CGFloat bottom = MAX(sa.bottom, 0.0) + pad;      // Home 条在下
    // ★底部热键条★ 1..9 中心在 H-30、高 36 ⇒ 顶边 H-48。五键的水平范围真的压到它时把整块抬起来，
    //   否则竖屏 iPhone 上 S 会与「2/3」两键重叠（横屏 iPad/iPhone 横向不相交，保持贴底）。
    CGFloat hotbarW  = 9 * 36 + 8 * 6;               // 372 = a2_layoutHotbar 的实际总宽
    CGFloat hotbarX0 = (W - hotbarW) * 0.5;
    if (left + side > hotbarX0) bottom = MAX(bottom, 36.0 + pad + 4.0);
    // 兜底：屏太矮 / 安全区太大时，至少留 8pt 在可见区内（后面的 clamp 还会再保一道）
    left   = MIN(left,   MAX(8.0, W - side - 8.0));
    bottom = MIN(bottom, MAX(8.0, H - side - 8.0));

    // 五键中心（与旧簇内相对坐标完全一致：W 上 / A 左 / S 下 / D 右 / 潜 居中）
    CGFloat b  = side * 0.30;
    CGFloat cx = left + side * 0.5;
    CGFloat cy = H - bottom - side * 0.5;
    [self a2_placeMoveKey:_dirButtons[@(kKeyW)] center:CGPointMake(cx, cy - side * 0.5 + b * 0.5) size:b];
    [self a2_placeMoveKey:_dirButtons[@(kKeyA)] center:CGPointMake(left + b * 0.5, cy)             size:b];
    [self a2_placeMoveKey:_dirButtons[@(kKeyS)] center:CGPointMake(cx, H - bottom - b * 0.5)       size:b];
    [self a2_placeMoveKey:_dirButtons[@(kKeyD)] center:CGPointMake(left + side - b * 0.5, cy)      size:b];
    [self a2_placeMoveKey:_sneakButton         center:CGPointMake(cx, cy)                          size:b * 0.9];
}

/// 单个默认摆放：设置正方形边长 + 中心（五键各管自己，互不牵连）
- (void)a2_placeMoveKey:(UIView *)v center:(CGPoint)c size:(CGFloat)s {
    if (v == nil || s <= 1) return;
    v.bounds = CGRectMake(0, 0, s, s);
    v.center = c;
}

/// ★布局版本迁移★ 旧版把移动键的默认坐标写在左上角（v1），v2 把它们装进一个整簇容器（已撤掉）；
/// 且「本机首次进入」会把当时那份布局播种进 NSUserDefaults ⇒ 只改常量对老设备不生效。
/// 版本号 < 3 时按新默认（五键各自 / 左下角）重锚这五个键并落盘；其它控件坐标一个都不动，且只做一次。
- (void)a2_migrateLayoutVersionIfNeeded {
    NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:kA2CtrlLayoutVerKey];
    if (v >= kA2CtrlLayoutVer) return;
    [NSUserDefaults.standardUserDefaults setInteger:kA2CtrlLayoutVer forKey:kA2CtrlLayoutVerKey];
    [self a2_layoutDefaultMoveKeys];
    a2_log_f(@"[A2-CTRL-LAYOUT] 迁移 v%ld→v%ld：W/A/S/D/潜 五键各自重锚左下角安全区（已无簇容器）",
             (long) v, (long) kA2CtrlLayoutVer);
    if (!_editing) [self a2_saveLayout];   // 落盘，否则下次启动又被旧存档的左上角覆盖
}

#pragma mark - 真机核对判据：[A2-CTRL-LAYOUT]

/// 控件在控件层坐标系里的 frame（五个移动键现在也是控件层的直接子视图，等价于 frame）
- (CGRect)a2_frameInSelf:(UIView *)v {
    if (v == nil) return CGRectZero;
    return v.superview ? [v.superview convertRect:v.frame toView:self] : v.frame;
}

- (void)a2_logFrameFor:(NSString *)name view:(UIView *)v {
    if (v == nil) return;
    CGRect f = [self a2_frameInSelf:v];
    a2_log_f(@"[A2-CTRL-LAYOUT] %s frame=(%.1f,%.1f,%.1f,%.1f) hidden=%d",
             name.UTF8String, f.origin.x, f.origin.y, f.size.width, f.size.height, v.hidden ? 1 : 0);
}

/// ★真机核对用★ 屏幕尺寸 + 每个键的最终 frame（x,y,w,h）逐个打印（已无簇信息）
- (void)a2_logControlLayout {
    CGSize s = self.bounds.size;
    if (s.width <= 1 || s.height <= 1) return;
    UIEdgeInsets sa = self.safeAreaInsets;
    a2_log_f(@"[A2-CTRL-LAYOUT] 屏幕=%.0fx%.0f safe=(t%.0f,l%.0f,b%.0f,r%.0f) 模式=%s",
             s.width, s.height, sa.top, sa.left, sa.bottom, sa.right,
             (_moveMode == A2MoveModeStick ? "stick" : "dpad"));

    [self a2_logFrameFor:@"W"   view:_dirButtons[@(kKeyW)]];
    [self a2_logFrameFor:@"A"   view:_dirButtons[@(kKeyA)]];
    [self a2_logFrameFor:@"S"   view:_dirButtons[@(kKeyS)]];
    [self a2_logFrameFor:@"D"   view:_dirButtons[@(kKeyD)]];
    [self a2_logFrameFor:@"潜"  view:_sneakButton];
    [self a2_logFrameFor:@"跳"  view:_jumpButton];
    [self a2_logFrameFor:@"攻"  view:_attackButton];
    [self a2_logFrameFor:@"用"  view:_useButton];
    [self a2_logFrameFor:@"包"  view:_inventoryButton];
    [self a2_logFrameFor:@"F3"  view:_f3Button];
    [self a2_logFrameFor:@"⌨"   view:_keyboardButton];
    [self a2_logFrameFor:@"ESC" view:_escButton];
    for (NSUInteger i = 0; i < _hotbar.count; i++) {
        [self a2_logFrameFor:[NSString stringWithFormat:@"热键%lu", (unsigned long) (i + 1)] view:_hotbar[i]];
    }

    // 判据①：五个移动键各自是否都在可见区内
    // 判据②：五个移动键是否有任何一个与底部 1..9 热键条相交（不压热键条）
    NSArray<UIView *> *moveKeys = [self a2_moveKeyViews];
    int inside = 0, overlap = 0;
    CGRect hotbarUnion = CGRectNull;
    for (UIView *b in _hotbar) hotbarUnion = CGRectUnion(hotbarUnion, [self a2_frameInSelf:b]);
    for (UIView *v in moveKeys) {
        CGRect f = [self a2_frameInSelf:v];
        if (f.size.width > 0.5 &&
            CGRectGetMinX(f) >= -0.5 && CGRectGetMinY(f) >= -0.5 &&
            CGRectGetMaxX(f) <= s.width + 0.5 && CGRectGetMaxY(f) <= s.height + 0.5) inside++;
        if (!CGRectIsNull(hotbarUnion) && CGRectIntersectsRect(f, hotbarUnion)) overlap++;
    }
    a2_log_f(@"[A2-CTRL-LAYOUT] 判定：移动五键 %lu 个全部在可见区=%d（%d/%lu） 与热键条相交=%d",
             (unsigned long) moveKeys.count, (inside == (int) moveKeys.count) ? 1 : 0,
             inside, (unsigned long) moveKeys.count, overlap);
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
        {
            UIPanGestureRecognizer *hp = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(a2_dragItem:)];
            hp.cancelsTouchesInView = YES;
            [b addGestureRecognizer:hp];
        }
    }
    [self a2_layoutHotbar];
}

- (void)a2_layoutHotbar {
    CGFloat W = CGRectGetWidth(self.bounds)  > 0 ? CGRectGetWidth(self.bounds)  : 874;
    CGFloat H = CGRectGetHeight(self.bounds) > 0 ? CGRectGetHeight(self.bounds) : 402;
    CGFloat total = 9 * 36 + 8 * 6;
    CGFloat x = (W - total) * 0.5 + 18;
    for (UIButton *b in _hotbar) {
        b.center = CGPointMake(x, H - 30);   // ★贴底★ 原来 H-42 视觉上偏高
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
    if (_editing) return;   // 编辑模式下不呼出系统键盘（点 ⌨ 只用于选中/拖动）
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

- (void)a2_attackDown {
    a2_glfw_input_post_mouse_button(_window, kMouseLeft, 1);
    _attackButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.30];
    [_attackWatchdog invalidate];
    // 捕获值而不是在 block 里解引用 weakSelf（clang: dereferencing a __weak pointer is not allowed）
    const long win = _window;
    _attackWatchdog = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
        a2_glfw_input_post_mouse_button(win, kMouseLeft, 0);
    }];
}
- (void)a2_attackUp {
    [_attackWatchdog invalidate]; _attackWatchdog = nil;
    a2_glfw_input_post_mouse_button(_window, kMouseLeft, 0);
    _attackButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
}
- (void)a2_useDown {
    a2_glfw_input_post_mouse_button(_window, kMouseRight, 1);
    _useButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.30];
    // ★看门狗★ 若 touch-up 丢了（手势/系统取消），2 秒后强制松开右键，
    //   否则“点一下就一直放方块、再点一下才停”（用户实测）。
    [_useWatchdog invalidate];
    __weak typeof(self) weakSelf = self;
    _useWatchdog = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
        [weakSelf a2_forceReleaseUse];
    }];
}
- (void)a2_useUp {
    [_useWatchdog invalidate]; _useWatchdog = nil;
    a2_glfw_input_post_mouse_button(_window, kMouseRight, 0);
    _useButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
}
- (void)a2_forceReleaseUse {
    _useWatchdog = nil;
    a2_glfw_input_post_mouse_button(_window, kMouseRight, 0);
    _useButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    a2_log_f(@"[A2-CONTROLS] 「用」键看门狗：强制松开右键");
}
- (void)a2_tapE       { [self a2_pressBound:@"inventory" fallback:kKeyE]; }
- (void)a2_tapF3      { [self a2_pressBound:@"f3" fallback:kKeyF3]; }
- (void)a2_tapEsc     { [self a2_pressBound:@"esc" fallback:256]; }

#pragma mark - 阶段4/5：自定义 + 多方案

- (void)a2_toggleEdit {
    _editing = !_editing;
    // 游戏内已无 ⚙（编辑移到设置里），这里只维护状态位
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
    [sheet addAction:[UIAlertAction actionWithTitle:(_moveMode == A2MoveModeStick ? @"切换为：分键移动" : @"切换为：摇杆移动")
                                                style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf setMoveMode:(weakSelf.moveMode == A2MoveModeStick ? A2MoveModeDPad : A2MoveModeStick)];
        [weakSelf a2_saveLayout];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"导入布局(剪贴板)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf a2_importLayoutFromClipboard];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"导出布局(复制到剪贴板)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf a2_exportLayoutToClipboard];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"恢复默认布局" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [weakSelf a2_layoutDefaultButtons];
        [weakSelf a2_layoutHotbar];
        for (UIView *v in weakSelf.a2_movableViews) v.alpha = 1.0;
        [weakSelf a2_clampControlsIntoBounds];
        [weakSelf a2_logControlLayout];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"完成" style:UIAlertActionStyleCancel handler:nil]];

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = self;
        sheet.popoverPresentationController.sourceRect = self.bounds;
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
    [self a2_layoutHandleForSelected];
}

- (void)a2_pinchItem:(UIPinchGestureRecognizer *)pinch {
    if (!_editing) return;
    UIView *v = pinch.view;
    CGFloat s = pinch.scale;
    v.bounds = CGRectMake(0, 0, MAX(28, v.bounds.size.width * s), MAX(28, v.bounds.size.height * s));
    pinch.scale = 1.0;
    [self a2_layoutHandleForSelected];
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
    NSString *prefix = [[self a2_deviceKey] stringByAppendingString:@"|"];
    // ★先数一遍本机型已保存的方案★：一个都没有时不能弹 —— 那样的 ActionSheet 只有
    //   一个「取消」按钮、正文空白，用户看到的就是一个空壳弹窗（与本单修的安装页空壳同源）。
    NSUInteger savedCount = 0;
    for (NSString *full in store.allKeys) {
        if ([full hasPrefix:prefix]) savedCount++;
    }
    if (savedCount == 0) {
        a2_log_f(@"[A2-CTRL-LAYOUT] 本机型还没有已保存的方案（store=%lu 条）⇒ 不弹选择框，避免只有一个「取消」的空壳",
                 (unsigned long)store.count);
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择方案"
                                                                  message:@"选一个已保存的控件方案，立即应用"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSString *full in store.allKeys) {
        // 只列本机型的方案；展示去掉「设备键|」前缀
        if (![full hasPrefix:prefix]) continue;
        NSString *name = [full substringFromIndex:prefix.length];
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [NSUserDefaults.standardUserDefaults setObject:name forKey:kA2LayoutCurKey];
            [weakSelf a2_applySavedLayout];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self.a2_topViewController presentViewController:sheet animated:YES completion:nil];
}

- (void)a2_saveLayout {
    NSString *name = [self a2_layoutStoreKey];   // ★设备键|方案名★
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
    for (NSString *cid in _customTitles) {
        NSMutableDictionary *e = [entry[cid] mutableCopy];
        if (e == nil) continue;
        e[@"t"] = _customTitles[cid];
        entry[cid] = e;
    }
    entry[@"_removed"] = _removedIds.allObjects ?: @[];
    entry[@"_w"] = @(CGRectGetWidth(self.bounds));
    entry[@"_h"] = @(CGRectGetHeight(self.bounds));
    store[name] = entry;
    [NSUserDefaults.standardUserDefaults setObject:store forKey:kA2LayoutsKey];
    // ★立即生效★ 写盘 + 广播：已存在的控件层收到后立刻重载，不必重启 App
    [NSUserDefaults.standardUserDefaults synchronize];
    [NSNotificationCenter.defaultCenter postNotificationName:@"A2ControlLayoutChanged" object:nil];
    a2_log_f(@"[A2-CONTROLS] 方案已保存：%@（%lu 项）并广播立即生效", name, (unsigned long) entry.count);
}

- (void)a2_applySavedLayout {
    if (CGRectGetWidth(self.bounds) <= 0) return;
    NSString *name = [self a2_layoutStoreKey];   // ★设备键|方案名★
    NSDictionary *store = [NSUserDefaults.standardUserDefaults dictionaryForKey:kA2LayoutsKey];
    NSDictionary *entry = store[name];
    if (entry == nil) {
        // 这台机型还没有自己的方案 ⇒ 把当前默认布局存成它的初始方案
        [self a2_saveLayout];
        store = [NSUserDefaults.standardUserDefaults dictionaryForKey:kA2LayoutsKey];
        entry = store[name];
    }
    if (![entry isKindOfClass:NSDictionary.class]) return;

    // 先重建上次保存过的自定义键（布局里带 t 的）
    for (NSString *cid in entry) {
        if (![cid hasPrefix:@"custom"]) continue;
        if (_movable[cid] != nil) continue;
        NSString *title = entry[cid][@"t"];
        if (![title isKindOfClass:NSString.class]) continue;
        [self a2_addCustomControlWithTitle:title];
        _movable[cid].hidden = NO;
    }
    // 再恢复/隐藏
    for (NSString *removed in entry[@"_removed"] ?: @[]) {
        UIView *v = _movable[removed];
        if (v != nil) { v.hidden = YES; v.userInteractionEnabled = NO; }
    }

    // ★跨尺寸还原★ 保存时画布尺寸和现在不同 ⇒ 按比例缩放（否则换设备/换方向后跑到屏幕外）
    CGFloat savedW = [entry[@"_w"] doubleValue];
    CGFloat savedH = [entry[@"_h"] doubleValue];
    CGFloat curW = CGRectGetWidth(self.bounds), curH = CGRectGetHeight(self.bounds);
    BOOL scale = (savedW > 1 && savedH > 1 && curW > 1 && curH > 1);
    CGFloat kx = scale ? curW / savedW : 1.0;
    CGFloat ky = scale ? curH / savedH : 1.0;

    for (NSString *cid in entry) {
        if ([cid isEqualToString:@"_removed"] || [cid hasPrefix:@"_"]) continue;
        UIView *v = _movable[cid];
        if (v == nil && [cid hasPrefix:@"hot"]) {
            NSInteger idx = [[cid substringFromIndex:3] integerValue];
            if (idx >= 1 && idx <= (NSInteger) _hotbar.count) v = _hotbar[(NSUInteger)(idx - 1)];
        }
        if (v == nil) continue;
        NSDictionary *e = entry[cid];
        v.bounds = CGRectMake(0, 0, [e[@"w"] doubleValue] * kx, [e[@"h"] doubleValue] * ky);
        // 夹回可见区域（留 1/4 边长余量，保证仍然抓得到）
        CGFloat halfW = CGRectGetWidth(v.bounds) * 0.5, halfH = CGRectGetHeight(v.bounds) * 0.5;
        CGFloat x = [e[@"x"] doubleValue] * kx;
        CGFloat y = [e[@"y"] doubleValue] * ky;
        v.center = CGPointMake(MIN(MAX(x, halfW), curW - halfW),
                               MIN(MAX(y, halfH), curH - halfH));
        v.alpha = [e[@"a"] doubleValue] > 0 ? [e[@"a"] doubleValue] : 1.0;
    }
}


#pragma mark - 任意键绑定

/// 取某控件当前绑定的键码（没绑过就用默认）。组合键时返回第一个键。
- (int)a2_keyForControl:(NSString *)cid fallback:(int)def {
    id v = _bindings[cid];
    if ([v isKindOfClass:NSArray.class]) {
        NSArray *a = v;
        return a.count ? [a.firstObject intValue] : def;
    }
    return [v isKindOfClass:NSNumber.class] ? [v intValue] : def;
}

/// 把绑定翻译成人话（键位面板标题用）
- (NSString *)a2_describeBindingFor:(NSString *)cid {
    NSArray *codes = [self a2_codesForControl:cid fallback:0];
    NSMutableArray *names = [NSMutableArray array];
    for (NSNumber *n in codes) {
        int c = n.intValue;
        if (c == 0) { [names addObject:@"未绑定"]; continue; }
        if (c == -1) { [names addObject:@"鼠标左"]; continue; }
        if (c == -2) { [names addObject:@"鼠标右"]; continue; }
        if (c >= 290 && c <= 301) { [names addObject:[NSString stringWithFormat:@"F%d", c - 289]]; continue; }
        if (c == 32) { [names addObject:@"空格"]; continue; }
        if (c == 256) { [names addObject:@"Esc"]; continue; }
        if (c == 257) { [names addObject:@"Enter"]; continue; }
        if (c == 258) { [names addObject:@"Tab"]; continue; }
        if (c == 259) { [names addObject:@"⌫"]; continue; }
        if (c == 340) { [names addObject:@"Shift"]; continue; }
        if (c == 341) { [names addObject:@"Ctrl"]; continue; }
        if (c == 342) { [names addObject:@"Alt"]; continue; }
        if (c >= 262 && c <= 265) {
            NSArray *ar = @[@"→", @"←", @"↓", @"↑"];
            [names addObject:ar[c - 262]];
            continue;
        }
        [names addObject:[NSString stringWithFormat:@"%c", (char)c]];
    }
    return [names componentsJoinedByString:@" + "];
}

/// 取某控件要派的全部键码（组合键 = 多个；普通键 = 一个）
- (NSArray<NSNumber *> *)a2_codesForControl:(NSString *)cid fallback:(int)def {
    id v = _bindings[cid];
    if ([v isKindOfClass:NSArray.class]) {
        return [(NSArray *)v count] ? v : @[ @(def) ];
    }
    if ([v isKindOfClass:NSNumber.class]) return @[ v ];
    return @[ @(def) ];
}

- (void)a2_setKey:(int)key forControl:(NSString *)cid {
    _bindings[cid] = @(key);
    [NSUserDefaults.standardUserDefaults setObject:_bindings forKey:kA2BindingsKey];
    a2_log_f(@"[A2-CONTROLS] 控件 %@ 绑定键码 %d", cid, key);
}

/// 编辑模式下点控件 = 改键位（拖动/捏合仍用于位置与大小）。
- (void)a2_longPressControl:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIView *v = g.view;
    for (NSString *cid in _movable) {
        if (_movable[cid] == v) { [self a2_releaseLatchedIfAny]; break; }
    }
}

- (void)a2_tapControl:(UITapGestureRecognizer *)tap {
    if (!_editing) return;
    UIView *v = tap.view;
    if (v == nil) return;

    // ★第一次点=选中（高亮 + 右下角缩放把手）★ 再点同一个才弹键位选择
    if (_selectedControl == v) {
        NSString *cid = nil;
        for (NSString *k in _movable) { if (_movable[k] == v) { cid = k; break; } }
        if (cid != nil) [self a2_presentKeyPickerFor:cid];
        return;
    }
    [self a2_selectControl:v];
}

/// 选中某控件：去掉上一个的高亮、给这个加边框和把手。
- (void)a2_selectControl:(UIView *)v {
    if (_selectedControl != nil) {
        _selectedControl.layer.borderWidth = 1.0;
        _selectedControl.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    }
    _selectedControl = v;
    v.layer.borderWidth = 2.0;
    v.layer.borderColor = [UIColor colorWithRed:0.42 green:0.65 blue:1.0 alpha:1.0].CGColor;

    if (_selectionHandle == nil) {
        _selectionHandle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
        _selectionHandle.backgroundColor = [UIColor colorWithRed:0.42 green:0.65 blue:1.0 alpha:0.95];
        _selectionHandle.layer.cornerRadius = 13;
        _selectionHandle.layer.borderWidth = 2;
        _selectionHandle.layer.borderColor = [UIColor whiteColor].CGColor;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(a2_dragHandle:)];
        [_selectionHandle addGestureRecognizer:pan];
        [self addSubview:_selectionHandle];
    }
    _selectionHandle.hidden = NO;
    [self bringSubviewToFront:_selectionHandle];
    [self a2_layoutHandleForSelected];
}

- (void)a2_layoutHandleForSelected {
    UIView *v = _selectedControl;
    if (v == nil || _selectionHandle == nil) return;
    CGPoint c = [v.superview convertPoint:CGPointMake(CGRectGetMaxX(v.frame), CGRectGetMaxY(v.frame)) toView:self];
    _selectionHandle.center = c;
}

/// 拖把手=等比放大/缩小（最小 28pt）
- (void)a2_dragHandle:(UIPanGestureRecognizer *)pan {
    UIView *v = _selectedControl;
    if (v == nil) return;
    CGPoint t = [pan translationInView:self];
    CGSize s = v.bounds.size;
    CGFloat side = MAX(28.0, s.width + t.x);
    v.bounds = CGRectMake(0, 0, side, MAX(28.0, s.height + t.y));
    [pan setTranslation:CGPointZero inView:self];
    [self a2_layoutHandleForSelected];
}

/// ★自定义按键★ 新建一个按钮并绑定（具体绑什么键，由用户再点一次从键位表里选）
- (void)a2_addCustomControlWithTitle:(NSString *)title {
    if (!_editing) return;
    NSString *name = title.length ? title : @"键";

    // id 递增，且跳过历史已用的
    NSInteger n = 1;
    NSString *cid = nil;
    do {
        cid = [NSString stringWithFormat:@"custom%ld", (long)n++];
    } while (_movable[cid] != nil || _customTitles[cid] != nil);

    UIButton *b = [self a2_makeButton:name];
    b.translatesAutoresizingMaskIntoConstraints = YES;
    b.bounds = CGRectMake(0, 0, 64, 64);
    b.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    [self addSubview:b];

    _movable[cid] = b;
    _customTitles[cid] = name;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(a2_dragItem:)];
    pan.cancelsTouchesInView = YES;
    [b addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(a2_tapControl:)];
    tap.cancelsTouchesInView = NO;
    [b addGestureRecognizer:tap];

    [self a2_selectControl:b];
    [self a2_saveLayout];
    a2_log_f(@"[A2-CONTROLS] 新增自定义键：%@ (%@)", name, cid);
}

/// ★删除选中★ 内置键与自定义键都可删；删内置的记进 _removedIds，重进不复活
- (void)a2_removeSelectedControl {
    UIView *v = _selectedControl;
    if (v == nil) return;
    NSString *cid = nil;
    for (NSString *k in _movable) { if (_movable[k] == v) { cid = k; break; } }
    if (cid == nil) return;

    [v removeFromSuperview];
    [_movable removeObjectForKey:cid];
    [_customTitles removeObjectForKey:cid];
    [_removedIds addObject:cid];
    _selectedControl = nil;
    _selectionHandle.hidden = YES;
    [self a2_saveLayout];
    a2_log_f(@"[A2-CONTROLS] 删除控件：%@", cid);
}

- (void)a2_layoutChanged:(NSNotification *)n {
    if (!_editing) [self a2_reloadSavedLayout];   // 编辑器里别抢用户的编辑态
}

- (void)a2_reloadSavedLayout {
    [self a2_applySavedLayout];
    [self a2_clampControlsIntoBounds];
    [self a2_logControlLayout];
}

- (void)a2_deselect {
    if (_selectedControl != nil) {
        _selectedControl.layer.borderWidth = 1.0;
        _selectedControl.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    }
    _selectedControl = nil;
    _selectionHandle.hidden = YES;
}

- (void)a2_presentKeyPickerFor:(NSString *)cid {
    UIViewController *top = self.a2_topViewController;
    if (top == nil || cid == nil) return;
    _pendingCid = cid;
    _comboBuffer = [NSMutableArray array];

    // 遮罩
    UIView *mask = [[UIView alloc] initWithFrame:top.view.bounds];
    mask.tag = 0xA2C0;
    _keypadMask = mask;
    mask.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
    [top.view addSubview:mask];

    UITapGestureRecognizer *outside = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(a2_closeKeyPad)];
    [mask addGestureRecognizer:outside];

    // 面板
    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    panel.layer.cornerRadius = 20;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    [mask addSubview:panel];
    // 面板内部的点击不要被"点遮罩关闭"吃掉（只点面板外的空白才关闭）
    UITapGestureRecognizer *inner = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(a2_keyPadInnerTap:)];
    inner.cancelsTouchesInView = NO;
    [panel addGestureRecognizer:inner];
    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:mask.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:mask.centerYAnchor],
        [panel.widthAnchor constraintEqualToAnchor:mask.widthAnchor multiplier:0.92],
        [panel.heightAnchor constraintLessThanOrEqualToAnchor:mask.heightAnchor multiplier:0.86],
    ]];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectZero];
    tip.translatesAutoresizingMaskIntoConstraints = NO;
    tip.text = [NSString stringWithFormat:@"选择要绑定的按键   当前：%@", [self a2_describeBindingFor:cid]];
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.92];
    tip.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    tip.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:tip];

    UISwitch *comboSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    comboSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    comboSwitch.tag = 0xA2C1;
    comboSwitch.onTintColor = [UIColor colorWithRed:0.42 green:0.65 blue:1 alpha:1];
    [panel addSubview:comboSwitch];

    UILabel *comboLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    comboLabel.translatesAutoresizingMaskIntoConstraints = NO;
    comboLabel.tag = 0xA2C3;
    comboLabel.text = @"组合键";
    comboLabel.textColor = [UIColor colorWithWhite:1 alpha:0.82];
    comboLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [panel addSubview:comboLabel];

    UIButton *confirm = [UIButton buttonWithType:UIButtonTypeSystem];
    confirm.translatesAutoresizingMaskIntoConstraints = NO;
    confirm.tag = 0xA2C2;
    [confirm setTitle:@"确定" forState:UIControlStateNormal];
    [confirm setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    confirm.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    confirm.backgroundColor = [UIColor colorWithRed:0.42 green:0.65 blue:1 alpha:1];
    confirm.layer.cornerRadius = 10;
    confirm.hidden = YES;
    [confirm addTarget:self action:@selector(a2_comboConfirm) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:confirm];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"完成" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithRed:0.42 green:0.65 blue:1 alpha:1] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [close addTarget:self action:@selector(a2_closeKeyPad) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    [panel addSubview:scroll];

    UIStackView *col = [[UIStackView alloc] initWithFrame:CGRectZero];
    col.translatesAutoresizingMaskIntoConstraints = NO;
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 8;
    [scroll addSubview:col];

    [NSLayoutConstraint activateConstraints:@[
        [tip.topAnchor constraintEqualToAnchor:panel.topAnchor constant:16],
        [tip.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [close.centerYAnchor constraintEqualToAnchor:tip.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],
        [comboSwitch.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [comboSwitch.centerYAnchor constraintEqualToAnchor:tip.bottomAnchor constant:22],
        [comboLabel.leadingAnchor constraintEqualToAnchor:comboSwitch.trailingAnchor constant:8],
        [comboLabel.centerYAnchor constraintEqualToAnchor:comboSwitch.centerYAnchor],
        [confirm.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],
        [confirm.centerYAnchor constraintEqualToAnchor:comboSwitch.centerYAnchor],
        [confirm.widthAnchor constraintEqualToConstant:76],
        [confirm.heightAnchor constraintEqualToConstant:34],
        [scroll.topAnchor constraintEqualToAnchor:comboSwitch.bottomAnchor constant:12],
        [scroll.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:14],
        [scroll.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14],
        [scroll.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-14],
        // ★UIScrollView 正确用法★ 内容钉 contentLayoutGuide，宽度跟 frameLayoutGuide，
        //   并且给 scroll 一个明确高度 —— 否则高度算成 0，键盘整块不显示（只剩开关一行）。
        [scroll.heightAnchor constraintEqualToConstant:250],
        [col.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [col.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [col.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [col.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [col.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
    ]];

    // ★全键位表★ 每行 (显示名, GLFW 键码)
    NSArray<NSArray *> *rows = @[
        @[ @[@"1",@49], @[@"2",@50], @[@"3",@51], @[@"4",@52], @[@"5",@53],
           @[@"6",@54], @[@"7",@55], @[@"8",@56], @[@"9",@57], @[@"0",@48] ],
        @[ @[@"Q",@81], @[@"W",@87], @[@"E",@69], @[@"R",@82], @[@"T",@84],
           @[@"Y",@89], @[@"U",@85], @[@"I",@73], @[@"O",@79], @[@"P",@80] ],
        @[ @[@"A",@65], @[@"S",@83], @[@"D",@68], @[@"F",@70], @[@"G",@71],
           @[@"H",@72], @[@"J",@74], @[@"K",@75], @[@"L",@76] ],
        @[ @[@"Z",@90], @[@"X",@88], @[@"C",@67], @[@"V",@86], @[@"B",@66],
           @[@"N",@78], @[@"M",@77], @[@"⌫",@259] ],
        @[ @[@"空格",@32], @[@"Esc",@256], @[@"Enter",@257], @[@"Tab",@258],
           @[@"Shift",@340], @[@"Ctrl",@341], @[@"Alt",@342] ],
        @[ @[@"↑",@265], @[@"↓",@264], @[@"←",@263], @[@"→",@262],
           @[@"鼠标左",@(-1)], @[@"鼠标右",@(-2)] ],
        @[ @[@"F1",@290], @[@"F2",@291], @[@"F3",@292], @[@"F4",@293],
           @[@"F5",@294], @[@"F6",@295] ],
        @[ @[@"F7",@296], @[@"F8",@297], @[@"F9",@298], @[@"F10",@299],
           @[@"F11",@300], @[@"F12",@301] ],
        // ★符号键★（GLFW 用 ASCII 码，和 SDL 一致）
        @[ @[@"-",@45], @[@"=",@61], @[@"[",@91], @[@"]",@93], @[@"\\",@92],
           @[@";",@59], @[@"'",@39], @[@",",@44], @[@".",@47], @[@"/",@47] ],
        // ★小键盘★（GLFW KP_0..KP_9 = 320..329）
        @[ @[@"KP0",@320], @[@"KP1",@321], @[@"KP2",@322], @[@"KP3",@323],
           @[@"KP4",@324], @[@"KP5",@325], @[@"KP6",@326] ],
        @[ @[@"KP7",@327], @[@"KP8",@328], @[@"KP9",@329], @[@"KP.",@330],
           @[@"KP/",@331], @[@"KP*",@332], @[@"KP-",@333], @[@"KP+",@334], @[@"KP⏎",@335] ],
    ];

    for (NSArray *row in rows) {
        UIStackView *line = [[UIStackView alloc] initWithFrame:CGRectZero];
        line.axis = UILayoutConstraintAxisHorizontal;
        line.spacing = 6;
        line.distribution = UIStackViewDistributionFillEqually;
        for (NSArray *kv in row) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
            [b setTitle:kv[0] forState:UIControlStateNormal];
            [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.95] forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
            b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
            b.layer.cornerRadius = 9;
            b.layer.cornerCurve = kCACornerCurveContinuous;
            b.tag = [kv[1] integerValue];
            [b addTarget:self action:@selector(a2_keyPadTapped:) forControlEvents:UIControlEventTouchUpInside];
            [b.heightAnchor constraintEqualToConstant:42].active = YES;
            [line addArrangedSubview:b];
        }
        [col addArrangedSubview:line];
    }

    a2_log_f(@"[A2-CONTROLS] 打开键盘面板：%@", cid);
}

- (void)a2_keyPadInnerTap:(UITapGestureRecognizer *)g { /* 吞掉，避免关面板 */ }

- (void)a2_keyPadTapped:(UIButton *)b {
    if (_pendingCid.length == 0) return;

    UIView *mask = [self.a2_topViewController.view viewWithTag:0xA2C0];
    UISwitch *sw = (UISwitch *)[mask viewWithTag:0xA2C1];

    if (sw.isOn) {
        int code = (int)b.tag;
        // ★任意键都能组合，最多 3 个★（不再限制必须以 F 键打头）
        if (_comboBuffer.count >= 3) return;
        [_comboBuffer addObject:@(code)];

        UILabel *lb = (UILabel *)[mask viewWithTag:0xA2C3];
        NSMutableArray *names = [NSMutableArray array];
        for (NSNumber *n in _comboBuffer) {
            int c = n.intValue;
            [names addObject:(c >= 290 && c <= 301) ? [NSString stringWithFormat:@"F%d", c - 289]
                                                    : [NSString stringWithFormat:@"%c", c]];
        }
        lb.text = [names componentsJoinedByString:@" + "];

        UIButton *ok = (UIButton *)[mask viewWithTag:0xA2C2];
        ok.hidden = NO;
        return;
    }

    [self a2_setKey:(int)b.tag forControl:_pendingCid];
    [self a2_closeKeyPad];
}

/// 组合键确定：写入绑定并自动关闭
- (void)a2_comboConfirm {
    if (_pendingCid.length == 0 || _comboBuffer.count == 0) return;
    _bindings[_pendingCid] = [_comboBuffer copy];
    [NSUserDefaults.standardUserDefaults setObject:_bindings forKey:kA2BindingsKey];
    a2_log_f(@"[A2-CONTROLS] 控件 %@ 绑定组合键 %@", _pendingCid, _comboBuffer);
    [self a2_closeKeyPad];
}

- (void)a2_closeKeyPad {
    UIView *mask = _keypadMask;
    if (mask == nil) mask = [self.a2_topViewController.view viewWithTag:0xA2C0];
    [mask removeFromSuperview];
    _keypadMask = nil;
    _pendingCid = nil;
}

/// 松开锁存的修饰键（长按组合键控件、退出游戏、切布局时都会调）
- (BOOL)a2_releaseLatchedIfAny {
    if (_latchedCid.length == 0) return NO;
    a2_glfw_input_post_key(_window, _latchedModifier, 0);
    a2_log_f(@"[A2-CONTROLS] 组合键释放：key=%d", _latchedModifier);
    [self a2_markLatched:NO forCid:_latchedCid];
    _latchedCid = nil;
    _latchedModifier = 0;
    return YES;
}

/// 锁存时给控件加个高亮，让用户知道 F3 还按着
- (void)a2_markLatched:(BOOL)on forCid:(NSString *)cid {
    UIView *v = _movable[cid];
    v.layer.borderWidth = on ? 2.0 : 1.0;
    v.layer.borderColor = (on ? [UIColor colorWithRed:1.0 green:0.72 blue:0.25 alpha:1.0]
                              : [UIColor colorWithWhite:1 alpha:0.22]).CGColor;
}

/// 按绑定发一次「按下+抬起」（-1/-2 走鼠标左右键）。
- (void)a2_pressBound:(NSString *)cid fallback:(int)def {
    NSArray<NSNumber *> *codes = [self a2_codesForControl:cid fallback:def];
    int first = codes.firstObject.intValue;
    if (first == -1) { a2_glfw_input_post_mouse_button(_window, 0, 1); a2_glfw_input_post_mouse_button(_window, 0, 0); return; }
    if (first == -2) { a2_glfw_input_post_mouse_button(_window, 1, 1); a2_glfw_input_post_mouse_button(_window, 1, 0); return; }

    a2_log_f(@"[A2-CONTROLS] 按键合成 cid=%@ keys=%@ window=%ld", cid, codes, _window);
    // ★组合键 = 锁存式★ 对应 Minecraft「按住 F3 + 单点 F4」的用法：
    //   第 1 次点 → F3 按下并保持；之后每点一次 → 只点一下 F4；长按 → 松开 F3。
    NSNumber *modifier = codes.firstObject;

    if (codes.count == 1) {
        a2_glfw_input_post_key(_window, modifier.intValue, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            a2_glfw_input_post_key(self->_window, modifier.intValue, 0);
        });
        return;
    }

    NSNumber *target = codes[1];

    if (_latchedCid.length == 0) {
        // 开始按住修饰键
        if ([self a2_releaseLatchedIfAny]) return;
        _latchedCid = cid;
        _latchedModifier = modifier.intValue;
        a2_glfw_input_post_key(_window, modifier.intValue, 1);
        [self a2_markLatched:YES forCid:cid];
        a2_log_f(@"[A2-CONTROLS] 组合键锁存：按住 key=%d（%@）", _latchedModifier, cid);
        return;
    }

    if ([_latchedCid isEqualToString:cid]) {
        // 已按住 → 单点目标键
        a2_glfw_input_post_key(_window, target.intValue, 1);
        a2_glfw_input_post_key(_window, target.intValue, 0);
        a2_log_f(@"[A2-CONTROLS] 组合键单点：key=%d（修饰键保持 %d）", target.intValue, _latchedModifier);
        return;
    }

    // 点的是另一个组合键 ⇒ 先松开旧的，再锁存新的
    [self a2_releaseLatchedIfAny];
    _latchedCid = cid;
    _latchedModifier = modifier.intValue;
    a2_glfw_input_post_key(_window, modifier.intValue, 1);
    [self a2_markLatched:YES forCid:cid];
}


#pragma mark - 多格式导入导出（A2 / FCL / ZL2）

- (NSArray<NSDictionary *> *)a2_currentControlsNormalized {
    NSMutableArray *out = [NSMutableArray array];
    CGFloat W = MAX(1.0, CGRectGetWidth(self.bounds));
    CGFloat H = MAX(1.0, CGRectGetHeight(self.bounds));
    for (NSString *cid in _movable) {
        UIView *v = _movable[cid];
        [out addObject:@{
            @"id": cid,
            @"x": @(v.center.x / W), @"y": @(v.center.y / H),
            @"w": @(v.bounds.size.width / W), @"h": @(v.bounds.size.height / H),
            @"a": @(v.alpha),
            @"key": _bindings[cid] ?: @0,
            @"label": [v isKindOfClass:UIButton.class] ? ([((UIButton *)v) titleForState:UIControlStateNormal] ?: @"") : @"",
        }];
    }
    return out;
}

- (void)a2_applyControlsNormalized:(NSArray<NSDictionary *> *)controls {
    CGFloat W = CGRectGetWidth(self.bounds), H = CGRectGetHeight(self.bounds);
    NSInteger applied = 0;
    for (NSDictionary *c in controls) {
        NSString *cid = c[@"id"];
        UIView *v = _movable[cid];
        if (v == nil) continue;   // 外部布局里我们不认识的控件：跳过并计数
        v.bounds = CGRectMake(0, 0, [c[@"w"] doubleValue] * W, [c[@"h"] doubleValue] * H);
        v.center = CGPointMake([c[@"x"] doubleValue] * W, [c[@"y"] doubleValue] * H);
        if (c[@"a"] != nil) v.alpha = MAX(0.15, [c[@"a"] doubleValue]);
        if (c[@"key"] != nil) [self a2_setKey:[c[@"key"] intValue] forControl:cid];
        applied++;
    }
    a2_log_f(@"[A2-CONTROLS] 已导入 %ld/%lu 项（其余为外部格式中我们不认识的控件）",
             (long) applied, (unsigned long) controls.count);
}

- (void)a2_importLayoutFromClipboard {
    NSString *text = UIPasteboard.generalPasteboard.string;
    if (text.length == 0) {
        a2_log_f(@"[A2-CONTROLS] 剪贴板为空，无法导入");
        return;
    }
    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:&err];
    if (json == nil) {
        a2_log_f(@"[A2-CONTROLS] 导入失败：不是合法 JSON（%@）", err.localizedDescription ?: @"");
        return;
    }
    A2ControlLayoutFormat fmt = [A2ControlLayoutIO detectFormat:json];
    NSArray<NSDictionary *> *controls = [A2ControlLayoutIO parseJSON:json format:fmt];
    if (controls.count == 0) {
        a2_log_f(@"[A2-CONTROLS] 导入失败：没有解析出控件（格式=%ld）", (long) fmt);
        return;
    }
    [self a2_applyControlsNormalized:controls];
    a2_log_f(@"[A2-CONTROLS] 导入完成：格式=%ld 共 %lu 项", (long) fmt, (unsigned long) controls.count);
}

- (void)a2_exportLayoutToClipboard {
    NSArray<NSDictionary *> *controls = [self a2_currentControlsNormalized];
    id json = [A2ControlLayoutIO exportControls:controls format:A2ControlLayoutFormatA2 name:@"默认"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:NULL];
    if (data == nil) return;
    UIPasteboard.generalPasteboard.string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    a2_log_f(@"[A2-CONTROLS] 已导出 A2 布局到剪贴板（%lu 项）", (unsigned long) controls.count);
}


- (UIViewController *)a2_topViewController {
    UIResponder *r = self;
    while (r != nil && ![r isKindOfClass:UIViewController.class]) r = r.nextResponder;
    UIViewController *vc = (UIViewController *) r;
    // ★兜底★ 控件挂在"游戏视图"（普通 UIView）上，响应链常到 UIWindow 就断，
    //   那样 present 会静默失败 —— 表现为「点了有高亮但没反应」。
    if (vc == nil) vc = UIApplication.sharedApplication.keyWindow.rootViewController;
    if (vc == nil) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *) scene).windows) {
                if (w.isKeyWindow) { vc = w.rootViewController; break; }
            }
            if (vc != nil) break;
        }
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

/// ★边界判断★ 默认布局是按手机比例写的，iPad/分屏下会跑到屏幕外。
///   这里逐项把控件夹回可见区（留半个边长余量），并打一行判据。
- (void)a2_clampControlsIntoBounds {
    CGSize s = self.bounds.size;
    if (s.width <= 1 || s.height <= 1) return;
    int moved = 0;
    for (NSString *cid in _movable) {
        UIView *v = _movable[cid];
        if (v == nil || v.hidden) continue;
        CGFloat hw = CGRectGetWidth(v.bounds) * 0.5;
        CGFloat hh = CGRectGetHeight(v.bounds) * 0.5;
        CGFloat x = MIN(MAX(v.center.x, hw), s.width - hw);
        CGFloat y = MIN(MAX(v.center.y, hh), s.height - hh);
        if (fabs(x - v.center.x) > 0.5 || fabs(y - v.center.y) > 0.5) {
            v.center = CGPointMake(x, y);
            moved++;
        }
    }
    if (moved > 0) {
        a2_log_f(@"[A2-CONTROLS] 边界修正：%d 个控件被夹回可见区（bounds=%.0fx%.0f）",
                 moved, s.width, s.height);
    }
}

/// ★按机型定制★ 设备键 = 硬件型号 + 屏幕点数（长边x短边）
- (NSString *)a2_deviceKey {
    // hw.machine 才是具体机型（iPhone15,2 / iPad13,4 …）；UIDevice.model 只有 "iPhone"
    static char machine[64] = {0};
    size_t len = sizeof(machine);
    if (machine[0] == 0 && sysctlbyname("hw.machine", machine, &len, NULL, 0) != 0) {
        strlcpy(machine, "iOS", sizeof(machine));
    }
    CGSize s = UIScreen.mainScreen.bounds.size;
    CGFloat l = MAX(s.width, s.height), sh = MIN(s.width, s.height);
    return [NSString stringWithFormat:@"%s-%.0fx%.0f", machine, l, sh];
}

/// 本机当前的存储键 = 「设备键|方案名」⇒ 同一方案在不同机型各存一份，互不覆盖
- (NSString *)a2_layoutStoreKey {
    NSString *base = [NSUserDefaults.standardUserDefaults stringForKey:kA2LayoutCurKey] ?: @"默认";
    return [NSString stringWithFormat:@"%@|%@", [self a2_deviceKey], base];
}

/// ★iPhone Duo★ 折叠/展开、Split View 都会改 bounds ⇒ 不能只在构建时排一次。
/// 尺寸变化 >1pt 就按新宽度重排（自定义布局按比例缩放）。
- (void)layoutSubviews {
    [super layoutSubviews];
    static CGSize a2Last = {0, 0};
    CGSize s = self.bounds.size;
    if (s.width <= 0 || s.height <= 0) return;
    BOOL changed = (a2Last.width <= 0 ||
                    fabs(s.width - a2Last.width) > 1.0 ||
                    fabs(s.height - a2Last.height) > 1.0);
    if (!changed) return;

    CGFloat kx = (a2Last.width  > 1.0) ? s.width  / a2Last.width  : 1.0;
    CGFloat ky = (a2Last.height > 1.0) ? s.height / a2Last.height : 1.0;
    if (a2Last.width > 1.0) {
        for (UIView *v in [self a2_movableViews]) {
            v.center = CGPointMake(v.center.x * kx, v.center.y * ky);
        }
    }
    a2Last = s;
    [self a2_layoutDefaultButtons];
    [self a2_layoutHotbar];
    [self a2_applySavedLayout];
    [self a2_migrateLayoutVersionIfNeeded];   // ★一次性★ 旧存档里簇在左上角 ⇒ 整簇重锚左下角
    [self a2_clampControlsIntoBounds];   // ★边界判断★ 防止默认布局在 iPad 上跑出屏幕
    [self a2_logControlLayout];          // ★真机核对★ 每个键的最终 frame + 屏幕尺寸
}

#pragma mark - 编辑器 API（设置里的控件布局编辑器调用）

- (void)a2_setEditing:(BOOL)editing {
    _editing = editing;
    if (!editing) [self a2_deselect];
    // 编辑时允许拖动/捏合；非编辑态手势仍挂着但不吞触摸（cancelsTouchesInView=NO）
}

- (void)a2_saveLayoutNow {
    [self a2_saveLayout];
}

- (NSArray<NSDictionary *> *)a2_exportControls {
    return [self a2_currentControlsNormalized];
}

- (void)a2_importControls:(NSArray<NSDictionary *> *)controls {
    if (controls.count) [self a2_applyControlsNormalized:controls];
}

- (void)a2_applyMoveMode:(NSInteger)mode {
    [self setMoveMode:(mode == A2MoveModeStick ? A2MoveModeStick : A2MoveModeDPad)];
}


@end
