// ============================================================================
//  Natives/Input/a2_glfw_input.m
//  Air2 —— 自研 GLFW 输入层（阶段 A）· 实现
// ----------------------------------------------------------------------------
//  职责：把 iOS 的触摸与**外接**键盘事件，翻译成 GLFW 语义事件并投进事件总线。
//    · 触摸 → 光标位置 + 鼠标左键（GLFW 语义：一根主触摸 = 指针）
//    · 外接键盘按下/抬起 → GLFW_KEY_*（HID usage → GLFW 键码，紧凑标准表）
//  软键盘文本输入（字符/文本/IME）是阶段 B，本文件不做。
//
//  ★为什么用「一根主触摸 = 指针」★
//    GLFW 的输入模型是「一个鼠标 + 一个光标」。iOS 没有鼠标，最贴近的映射是
//    把主触摸当作指针：位置 → CURSOR_POS，按下/抬起 → MOUSE_BUTTON(左键)。
//    MC 的 MouseHandler / InputConstants 正是按这套语义工作的。
//
//  净室：独立编写，未参考 Pojav / Boardwalk / Amethyst / LWJGL 源码。
//    HID→GLFW 键码表依据的是 **USB HID Usage Tables**（公开标准）与
//    GLFW 官方 glfw3.h 的键码数值（公开事实数据）。
// ============================================================================
#import "a2_glfw_input.h"
#import "a2_sdl_input.h"
#import "a2_glfw_window.h"
#import "a2_log.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <string.h>

// 鼠标左键（官方 glfw3.h：GLFW_MOUSE_BUTTON_LEFT = GLFW_MOUSE_BUTTON_1 = 0）
#define A2_GLFW_MOUSE_BUTTON_LEFT 0

// 滚动分辨率：间接输入每累计这么多「点」折算 1 个 GLFW 滚动刻度。
// 依据：离散滚轮一格在 UIKit 间接输入里约 10 点（触控板为连续量）⇒ 一格 ≈ ±1.0，
// 与桌面 GLFW「滚轮一格 = yoffset ±1」的手感对齐。属可调常数（阶段 B 可按真机微调）。
#define A2_GLFW_SCROLL_POINTS_PER_NOTCH 10.0

// ============================================================================
//  HID usage → GLFW 键码（紧凑标准表）
// ============================================================================
// UIKeyboardHIDUsage 就是 USB HID Keyboard/Keypad usage ID（公开标准）。
// 覆盖主界面所需：字母/数字/标点/编辑键/方向键/F 键/修饰键。
// ★完整表（含各国布局与多媒体键）属阶段 B 补全★ —— 本表已足够「进主界面 + 基本操作」。
static int a2_glfw_key_from_hid(long hid) {
    // USB HID 0x04..0x1D = 字母 a..z ⇒ GLFW_KEY_A(65)..GLFW_KEY_Z(90)（连续）
    if (hid >= 0x04 && hid <= 0x1D) {
        return 65 + (int) (hid - 0x04);
    }
    // USB HID 0x1E..0x26 = 数字 1..9 ⇒ GLFW_KEY_1(49)..GLFW_KEY_9(57)
    if (hid >= 0x1E && hid <= 0x26) {
        return 49 + (int) (hid - 0x1E);
    }
    switch (hid) {
        case 0x27: return 48;   // 0      -> GLFW_KEY_0
        case 0x28: return 257;  // Return -> GLFW_KEY_ENTER
        case 0x29: return 256;  // Escape -> GLFW_KEY_ESCAPE
        case 0x2A: return 259;  // Delete/Backspace -> GLFW_KEY_BACKSPACE
        case 0x2B: return 258;  // Tab    -> GLFW_KEY_TAB
        case 0x2C: return 32;   // Space  -> GLFW_KEY_SPACE
        case 0x2D: return 45;   // -      -> GLFW_KEY_MINUS
        case 0x2E: return 61;   // =      -> GLFW_KEY_EQUAL
        case 0x2F: return 91;   // [      -> GLFW_KEY_LEFT_BRACKET
        case 0x30: return 93;   // ]      -> GLFW_KEY_RIGHT_BRACKET
        case 0x31: return 92;   // \      -> GLFW_KEY_BACKSLASH
        case 0x33: return 59;   // ;      -> GLFW_KEY_SEMICOLON
        case 0x34: return 39;   // '      -> GLFW_KEY_APOSTROPHE
        case 0x35: return 96;   // `      -> GLFW_KEY_GRAVE_ACCENT
        case 0x36: return 44;   // ,      -> GLFW_KEY_COMMA
        case 0x37: return 46;   // .      -> GLFW_KEY_PERIOD
        case 0x38: return 47;   // /      -> GLFW_KEY_SLASH
        case 0x39: return 280;  // CapsLock -> GLFW_KEY_CAPS_LOCK
        case 0x46: return 283;  // PrintScreen -> GLFW_KEY_PRINT_SCREEN
        case 0x47: return 281;  // ScrollLock  -> GLFW_KEY_SCROLL_LOCK
        case 0x48: return 284;  // Pause       -> GLFW_KEY_PAUSE
        case 0x49: return 260;  // Insert      -> GLFW_KEY_INSERT
        case 0x4A: return 268;  // Home        -> GLFW_KEY_HOME
        case 0x4B: return 266;  // PageUp      -> GLFW_KEY_PAGE_UP
        case 0x4C: return 261;  // DeleteFwd   -> GLFW_KEY_DELETE
        case 0x4D: return 269;  // End         -> GLFW_KEY_END
        case 0x4E: return 267;  // PageDown    -> GLFW_KEY_PAGE_DOWN
        case 0x4F: return 262;  // Right       -> GLFW_KEY_RIGHT
        case 0x50: return 263;  // Left        -> GLFW_KEY_LEFT
        case 0x51: return 264;  // Down        -> GLFW_KEY_DOWN
        case 0x52: return 265;  // Up          -> GLFW_KEY_UP
        case 0x53: return 282;  // NumLock     -> GLFW_KEY_NUM_LOCK
        case 0xE0: return 341;  // LCtrl  -> GLFW_KEY_LEFT_CONTROL
        case 0xE1: return 340;  // LShift -> GLFW_KEY_LEFT_SHIFT
        case 0xE2: return 342;  // LAlt   -> GLFW_KEY_LEFT_ALT
        case 0xE3: return 343;  // LGUI   -> GLFW_KEY_LEFT_SUPER
        case 0xE4: return 345;  // RCtrl  -> GLFW_KEY_RIGHT_CONTROL
        case 0xE5: return 344;  // RShift -> GLFW_KEY_RIGHT_SHIFT
        case 0xE6: return 346;  // RAlt   -> GLFW_KEY_RIGHT_ALT
        case 0xE7: return 347;  // RGUI   -> GLFW_KEY_RIGHT_SUPER
        default: break;
    }
    // F1..F12：HID 0x3A..0x45 ⇒ GLFW_KEY_F1(290)..F12(301)（连续）
    if (hid >= 0x3A && hid <= 0x45) {
        return 290 + (int) (hid - 0x3A);
    }
    return -1;   // GLFW_KEY_UNKNOWN（官方值为 -1）
}

// UIKeyModifierFlags → GLFW mods 位（官方 glfw3.h：SHIFT=1, CONTROL=2, ALT=4, SUPER=8）
static int a2_glfw_mods_from_flags(UIKeyModifierFlags flags) {
    int mods = 0;
    if (flags & UIKeyModifierShift)     mods |= 0x0001;
    if (flags & UIKeyModifierControl)   mods |= 0x0002;
    if (flags & UIKeyModifierAlternate) mods |= 0x0004;
    if (flags & UIKeyModifierCommand)   mods |= 0x0008;
    if (flags & UIKeyModifierAlphaShift) mods |= 0x0010;  // CapsLock
    return mods;
}

// ============================================================================
//  宿主视图：触摸 + 外接键盘
// ============================================================================
@interface A2GlfwView : UIView
// ★不能叫 window★：UIView 自带 readonly 的 `window`(UIWindow *)，同名 long 会把它覆盖掉，
//   UIKit 把本视图加进层级时问 [view window] 会拿到句柄数字 ⇒ objc_msgSend 崩。
@property (nonatomic, assign) long  glfwWindow;
@property (nonatomic, assign) NSInteger activeTouches;
/// 主触点（第一根手指）：多点触控时锁定它，避免光标在两根手指之间跳。
@property (nonatomic, weak)   UITouch *a2PrimaryTouch;
/// 抓取模式用的虚拟光标与上次触摸采样点（增量口径）。
@property (nonatomic, assign) CGPoint a2VirtualCursor;
@property (nonatomic, assign) CGPoint a2LastTouch;
@property (nonatomic, assign) BOOL  touchLogged;
@property (nonatomic, assign) BOOL  scrollLogged;
@property (nonatomic) BOOL  a2ScrollGestureInstalled;
// 滚动（间接输入）：声明在类内，避免 GCC_WARN_UNDECLARED_SELECTOR 警告。
- (void)a2_scroll:(UIPanGestureRecognizer *)pan;
@end

@implementation A2GlfwView
{
    NSTimer *_a2HoldTimer;
    BOOL     _a2LeftPressed;
    CGPoint  _a2DownPoint;
    NSTimeInterval _a2DownTime;
    BOOL     _a2Moved;
}

/// ★2026-10-18 真机证据★ metallum 的 iOS 路径直接假设
///   `cocoaView.layer` 就是 CAMetalLayer（它注释里写明 GameSurfaceView 用
///   `+layerClass` 覆写成 CAMetalLayer）。我们是普通 UIView ⇒ 快照时系统
///   对它发 Metal 相关消息 ⇒ `-[MTLVertexAttributeInternal bounds]
///   unrecognized selector` + 黑屏。
///   只在 Metal 渲染器（AMETHYST_METAL=1）时启用，gl4es/EGL 路径保持 CALayer。
+ (Class)layerClass {
    // ★2026-11-01★ MG/ANGLE 路径同样需要 backing layer = CAMetalLayer：
    //   老 Air 的 GameSurfaceView 就是 +layerClass 覆写成 CAMetalLayer，
    //   ANGLE(iOS) 直接呈现到它；我们此前外挂子层 ⇒ 画得出、上不了屏。
    if (getenv("AMETHYST_METAL") != NULL || getenv("A2_GL_METAL_HOST") != NULL) {
        return [CAMetalLayer class];
    }
    return [super layerClass];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // ★iPhone Duo★ 折叠展开 / Split View 改变尺寸时不会走旋转通知，只能靠这里。
    static CGSize a2LastSize = {0, 0};
    CGSize s = self.bounds.size;
    if (fabs(s.width - a2LastSize.width) > 0.5 || fabs(s.height - a2LastSize.height) > 0.5) {
        a2LastSize = s;
        extern void a2_glfw_window_handle_host_resize(long handle);
        if (self.glfwWindow != 0) {
            a2_glfw_window_handle_host_resize(self.glfwWindow);
        }
    }
}

- (instancetype)initWithWindowHandle:(long)window {
    self = [super initWithFrame:CGRectZero];
    if (self != nil) {
        _glfwWindow = window;
        self.multipleTouchEnabled = YES;
        self.backgroundColor = [UIColor blackColor];
        self.opaque = YES;

        // ★滚动源：间接输入（外接鼠标滚轮 / 触控板两指滚动）★
        //   allowedScrollTypesMask 让 pan 手势也认滚轮/触控板（Apple 文档）；
        //   maximumNumberOfTouches = 0 ⇒ 只认间接输入，不吃直接触摸
        //   （直接触摸仍走 touchesBegan/Moved/Ended，指针语义不变）。
        // ★滚轮手势延迟到 didMoveToWindow 安装★（真因：iOS 27 下在"视图还没进窗口层级"
        //   时调用 addGestureRecognizer，会在 _UIGestureRecognizerRegisterInContainer 里崩，信号 6）。
        _a2ScrollGestureInstalled = NO;
    }
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window == nil /* ← UIView 真 window */ || _a2ScrollGestureInstalled) return;
    // ★再延后一个 runloop★：didMoveToWindow 发生时 UIKit 还在做布局/上屏，
    //   此时 addGestureRecognizer 仍可能踩到未稳定的容器（真机崩溃点 objc_retain）。
    //   下一个主队列轮次再装，那时视图层级已经稳定。
    if (!NSThread.isMainThread) {
        __weak typeof(self) ws = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [ws didMoveToWindow]; });
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        A2GlfwView *v = weakSelf;
        if (v == nil || v.window == nil || v->_a2ScrollGestureInstalled) return;
        [v a2_installScrollGestureIfNeeded];
    });
}

/// 真正的安装动作（延后一个 runloop 后调用）。
- (void)a2_installScrollGestureIfNeeded {
    if (_a2ScrollGestureInstalled || self.window == nil) return;
    id a2sg = [NSUserDefaults.standardUserDefaults objectForKey:@"A2EnableScrollGesture"];
    BOOL enable = (a2sg == nil) ? YES : [NSUserDefaults.standardUserDefaults boolForKey:@"A2EnableScrollGesture"];
    if (!enable) return;

    // 滚轮/触控板（间接输入）滚动：allowedScrollTypesMask 让 pan 也认滚轮；
    // maximumNumberOfTouches=0 ⇒ 只认间接输入、不吃手指（手指仍走 touchesBegan/Moved）。
    UIPanGestureRecognizer *scroll = [[UIPanGestureRecognizer alloc]
                                      initWithTarget:self action:@selector(a2_scroll:)];
    scroll.allowedScrollTypesMask = UIScrollTypeMaskAll;
    scroll.maximumNumberOfTouches = 0;
    [self addGestureRecognizer:scroll];
    _a2ScrollGestureInstalled = YES;
    a2_log_criterion(@"[A2-INPUT] 滚轮手势已安装（视图已进窗口层级）");
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

// ---- 投递助手 ----
- (void)postCursor:(CGPoint)p {
    // ★2026-10-18★ 坐标单位 = ★点(point)★，不要乘屏幕缩放：
    //   实测单点触控坐标本来就是准的（用户验证），乘 scale 会变成 3 倍偏移。
    //   （老 Air 的 touchHotbar 那处乘 scale 是热点条的另一条通道，与光标位置不同源。）
    A2GlfwEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.window = self.glfwWindow;
    ev.type = A2_GLFW_EVENT_CURSOR_POS;
    ev.d0 = (double) p.x;
    ev.d1 = (double) p.y;
    // ★26.3★ 指针位置同步进 SDL（SdlInputBridge 用 lastX/lastY 给按键事件定位）
    a2_sdl_input_cursor(p.x, p.y);
    a2_glfw_event_post(&ev);
}

- (void)postButton:(int)button action:(int)action mods:(int)mods {
    A2GlfwEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.window = self.glfwWindow;
    ev.type = A2_GLFW_EVENT_MOUSE_BUTTON;
    ev.i0 = button;
    ev.i1 = action;
    ev.i2 = mods;
    a2_glfw_event_post(&ev);
}

- (void)postEnter:(int)entered {
    A2GlfwEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.window = self.glfwWindow;
    ev.type = A2_GLFW_EVENT_CURSOR_ENTER;
    ev.i0 = entered;
    a2_glfw_event_post(&ev);
}

// 文本输入：外接键盘按键产生的字符（UIKey.characters）→ CHAR 事件。
// ★只在外接键盘的 -pressesBegan: 里调★（软键盘文本输入属阶段 B，本文件不做）。
- (void)postChar:(UIKey *)key mods:(int)mods {
    NSString *chars = key.characters;
    if (chars.length == 0) {
        return;
    }
    // 取首个 Unicode 码点（UTF-32 解码，代理对也正确）；控制字符不算文本输入，跳过。
    NSData *utf32 = [chars dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    if (utf32.length < 4) {
        return;
    }
    uint32_t cp = 0;
    memcpy(&cp, utf32.bytes, 4);
    if (cp == 0 || cp < 0x20) {
        return;
    }
    A2GlfwEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.window = self.glfwWindow;
    ev.type = A2_GLFW_EVENT_CHAR;
    ev.i0 = (int) cp;
    ev.i1 = mods;
    a2_glfw_event_post(&ev);
}

// 滚动：间接输入（外接鼠标滚轮 / 触控板两指滚动）→ SCROLL 事件。
// GLFW 语义：yoffset 正 = 向上/远离用户。UIKit 的 pan translation.y 向下为正 ⇒ 取负。
- (void)a2_scroll:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:self];
    [pan setTranslation:CGPointZero inView:self];
    if (t.x == 0.0 && t.y == 0.0) {
        return;
    }
    if (!self.scrollLogged) {
        self.scrollLogged = YES;
        a2_log_f(@"[A2-GLFW] 首次滚动已到达输入层 window=%ld（间接输入→SCROLL 通道通则）",
                 self.glfwWindow);
    }
    A2GlfwEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.window = self.glfwWindow;
    ev.type = A2_GLFW_EVENT_SCROLL;
    ev.d0 = (double) (t.x / A2_GLFW_SCROLL_POINTS_PER_NOTCH);
    ev.d1 = (double) (-t.y / A2_GLFW_SCROLL_POINTS_PER_NOTCH);
    a2_glfw_event_post(&ev);
}

// ★滑动 / 左键 判定★
//   手指落下时【不】立刻发左键（否则滑动视角 = 一直按着左键：挖矿/线框/无音效）。
//   规则：落下后 0.25s 内移动超过 8pt ⇒ 判为「滑动视角」→ 永不发左键；
//        原地不动满 0.25s ⇒ 判为「长按」→ 发左键按下（开始挖/交互），抬起时释放。
static const CGFloat kA2TapSlop = 8.0;
static const NSTimeInterval kA2HoldDelay = 0.25;

- (void)noteFirstTouch:(CGPoint)p {
    if (!self.touchLogged) {
        self.touchLogged = YES;
        a2_log_f(@"[A2-GLFW] 首次触摸已到达输入层 window=%ld at=(%.0f,%.0f)（触摸→光标/左键通道通则）",
                 self.glfwWindow, (double) p.x, (double) p.y);
    }
}

// ---- 触摸 ----
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void) event;
    // ★多点触控（2026-10-18 第二轮）★
    //   已有主触点时，第二根手指按下必须【整段忽略】：
    //   否则下面会把 a2VirtualCursor 重置成这根手指的位置 ⇒ 抓取模式下视角跳一下。
    //   （用户实测：单手跟手正常，多指就跳 —— 就是这一处。）
    if (self.a2PrimaryTouch != nil && [touches containsObject:self.a2PrimaryTouch]) {
        self.activeTouches += (NSInteger) touches.count;
        return;
    }
    UITouch *t = self.a2PrimaryTouch;
    if (t == nil) {
        // 主触点已抬起（或还没建立）⇒ 用本批里的第一根当新的主触点
        t = [touches anyObject];
        self.a2PrimaryTouch = t;
    }
    if (t == nil) {
        return;
    }
    CGPoint p = [t locationInView:self];
    BOOL wasIdle = (self.activeTouches == 0);
    self.activeTouches += (NSInteger) touches.count;
    [self noteFirstTouch:p];
    // 记下起点：抓取模式靠增量，不靠绝对位置
    self.a2LastTouch = p;
    self.a2VirtualCursor = p;
    extern int a2_glfw_input_is_grabbing(void);
    if (!a2_glfw_input_is_grabbing()) {
        // ★2026-10-18 你的现象①「手指落下瞬间视角仍跳一下」★
        //   抓取模式下这里不能再发绝对位置（那会变成一次「瞬间移动」→ 视角跳）。
        //   只记录起点，位移从下一次 touchesMoved 开始算。
        [self postCursor:p];
    }
    if (wasIdle) {
        [self postEnter:1];
        // ★不立刻发左键★ 先起 0.25s 计时：原地不动才算"长按(=挖/交互)"，
        //   一动就取消 ⇒ 滑动屏幕只移动视角，不会按着左键。
        _a2DownPoint = p;
        _a2DownTime = CACurrentMediaTime();
        _a2Moved = NO;
        _a2LeftPressed = NO;
        [_a2HoldTimer invalidate];
        __weak typeof(self) weakSelf = self;
        _a2HoldTimer = [NSTimer scheduledTimerWithTimeInterval:kA2HoldDelay repeats:NO block:^(NSTimer *tm) {
            __strong typeof(weakSelf) self2 = weakSelf;
            if (self2 == nil || self2.a2PrimaryTouch == nil) return;
            self2->_a2LeftPressed = YES;
            [self2 postButton:A2_GLFW_MOUSE_BUTTON_LEFT action:A2_GLFW_PRESS mods:0];
            a2_log_f(@"[A2-GLFW] 长按 0.25s ⇒ 左键按下");
        }];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void) event;
    UITouch *t = self.a2PrimaryTouch;
    if (t == nil || ![touches containsObject:t]) {
        return;   // 移动的是第二根手指 ⇒ 不影响光标
    }
    CGPoint p = [t locationInView:self];
    if (!_a2LeftPressed && _a2HoldTimer != nil) {
        CGFloat dx0 = p.x - _a2DownPoint.x, dy0 = p.y - _a2DownPoint.y;
        if (sqrt(dx0 * dx0 + dy0 * dy0) > kA2TapSlop) {
            [_a2HoldTimer invalidate];
            _a2HoldTimer = nil;      // ★判为滑动视角★ 本次触摸不再发左键
            _a2Moved = YES;
            a2_log_f(@"[A2-GLFW] 位移超过阈值 ⇒ 判为滑动，取消左键");
        }
    }
    extern int a2_glfw_input_is_grabbing(void);
    if (a2_glfw_input_is_grabbing()) {
        // ★抓取模式(游戏内)★ 只送【两次采样之差】，绝对坐标只用于判定"点了什么"。
        // 否则手指一落下光标瞬移到触点 ⇒ MC 收到巨大位移 ⇒ 视角锁死/乱飞。
        // ★视角灵敏度★ 设置键 A2ViewSensitivity(0.3~3.0，默认 1.0；iPad 默认再放大 25%)
        //   只作用于"抓取模式"的位移增量，不改动其它输入。
        static double sSens = -1;
        if (sSens < 0) {
            id v = [NSUserDefaults.standardUserDefaults objectForKey:@"A2ViewSensitivity"];
            double d = (v != nil) ? [NSUserDefaults.standardUserDefaults doubleForKey:@"A2ViewSensitivity"]
                                  : ((UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) ? 1.25 : 1.0);
            sSens = (d >= 0.3 && d <= 3.0) ? d : 1.0;
        }
        CGFloat dx = (p.x - self.a2LastTouch.x) * sSens;
        CGFloat dy = (p.y - self.a2LastTouch.y) * sSens;
        self.a2VirtualCursor = CGPointMake(self.a2VirtualCursor.x + dx,
                                           self.a2VirtualCursor.y + dy);
        self.a2LastTouch = p;
        [self postCursor:self.a2VirtualCursor];
    } else {
        self.a2LastTouch = p;
        [self postCursor:p];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void) event;
    UITouch *t = self.a2PrimaryTouch;
    if (t != nil && [touches containsObject:t]) {
        // ★松手不再发绝对坐标★ 抓取模式下绝对坐标会把视角瞬移回去（真机：松手回弹）
        extern int a2_glfw_input_is_grabbing(void);
        if (!a2_glfw_input_is_grabbing()) {
            [self postCursor:[t locationInView:self]];
        }
        self.a2PrimaryTouch = nil;
    }
    self.activeTouches -= (NSInteger) touches.count;
    if (self.activeTouches <= 0) {
        self.activeTouches = 0;
        [_a2HoldTimer invalidate];
        _a2HoldTimer = nil;

        // ★轻点 = 一次左键点击★（游戏菜单/按钮靠它）
        //   没有这一段：快速点按既不是长按、也不发点击 ⇒ 界面里点不动（真机已复现）。
        if (!_a2Moved && !_a2LeftPressed &&
            (CACurrentMediaTime() - _a2DownTime) < kA2HoldDelay) {
            CGPoint up = [t locationInView:self];
            extern int a2_glfw_input_is_grabbing(void);
            if (!a2_glfw_input_is_grabbing()) [self postCursor:up];
            [self postButton:A2_GLFW_MOUSE_BUTTON_LEFT action:A2_GLFW_PRESS mods:0];
            [self postButton:A2_GLFW_MOUSE_BUTTON_LEFT action:A2_GLFW_RELEASE mods:0];
            a2_log_f(@"[A2-GLFW] 轻点 ⇒ 合成一次左键点击 (%.0f,%.0f)", up.x, up.y);
        }

        if (_a2LeftPressed) {
            [self postButton:A2_GLFW_MOUSE_BUTTON_LEFT action:A2_GLFW_RELEASE mods:0];
            _a2LeftPressed = NO;
        }
        [self postEnter:0];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

// ---- 外接键盘（按下/抬起）----
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *pr in presses) {
        UIKey *key = pr.key;
        if (key == nil) {
            continue;
        }
        int gkey = a2_glfw_key_from_hid((long) key.keyCode);
        if (gkey < 0) {
            continue;   // 未覆盖的键：跳过（阶段 B 补全表）
        }
        A2GlfwEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.window = self.glfwWindow;
        ev.type = A2_GLFW_EVENT_KEY;
        ev.i0 = gkey;
        ev.i1 = (int) key.keyCode;                      // scancode = HID usage
        ev.i2 = A2_GLFW_PRESS;
        ev.i3 = a2_glfw_mods_from_flags(event.modifierFlags);
        a2_glfw_event_post(&ev);

        // ★同一次按下也是文本输入源★：外接键盘的字符 → CHAR 事件
        //   （MC 的文本/聊天输入读的是 glfwSetCharCallback，不是 key 回调）。
        [self postChar:key mods:a2_glfw_mods_from_flags(event.modifierFlags)];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *pr in presses) {
        UIKey *key = pr.key;
        if (key == nil) {
            continue;
        }
        int gkey = a2_glfw_key_from_hid((long) key.keyCode);
        if (gkey < 0) {
            continue;
        }
        A2GlfwEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.window = self.glfwWindow;
        ev.type = A2_GLFW_EVENT_KEY;
        ev.i0 = gkey;
        ev.i1 = (int) key.keyCode;
        ev.i2 = A2_GLFW_RELEASE;
        ev.i3 = a2_glfw_mods_from_flags(event.modifierFlags);
        a2_glfw_event_post(&ev);
    }
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self pressesEnded:presses withEvent:event];
}

@end

// ============================================================================
//  工厂
// ============================================================================
/// ★控件用★ 合成鼠标按键（button: 0=左 1=右；action: 1=按下 0=抬起）。
/// 调用方：A2GameControlsView 的攻击(左)/使用(右)。
void a2_glfw_input_post_mouse_button(long window, int button, int action) {
    A2GlfwEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.window = window;
    ev.type = A2_GLFW_EVENT_MOUSE_BUTTON;
    ev.i0 = button;
    ev.i1 = action;
    ev.i2 = 0;   // mods
    a2_glfw_event_post(&ev);    // ★26.3★ MC 只监听 SDL 事件 ⇒ 同一份输入镜像一份给 SDL 队列
    //   （26.2 及更早没有 SdlInputBridge，这里自动 no-op）
    a2_sdl_input_button(button, action ? 1 : 0);

}

/// ★控件用★ 合成字符输入（系统键盘 → GLFW CHAR 事件）。
void a2_glfw_input_post_char(long window, int codepoint, int mods) {
    A2GlfwEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.window = window;
    ev.type = A2_GLFW_EVENT_CHAR;
    ev.i0 = codepoint;
    ev.i1 = mods;
    a2_glfw_event_post(&ev);
}

/// ★游戏内控件用★ 合成一次按键事件（key 用 GLFW 键码；action: 1=按下 0=抬起）。
/// 调用方：Air2/Player/Controls/A2GameControlsView（屏幕上的方向/跳跃/潜行等按钮）。
/// 为什么走同一条事件总线：MC 只认 GLFW 回调，绕开它自己造一条会与真实输入打架。
void a2_glfw_input_post_key(long window, int key, int action) {
    A2GlfwEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.window = window;
    ev.type = A2_GLFW_EVENT_KEY;
    ev.i0 = key;
    ev.i1 = 0;       // scancode：控件合成用不到
    ev.i2 = action;  // GLFW_PRESS=1 / GLFW_RELEASE=0
    ev.i3 = 0;       // mods
    a2_glfw_event_post(&ev);    // ★26.3★ 键事件镜像到 SDL（26.2 自动 no-op）
    a2_sdl_input_key(key, action ? 1 : 0);

}

UIView *a2_glfw_input_make_view(long window) {
    A2GlfwView *view = [[A2GlfwView alloc] initWithWindowHandle:window];
    return view;
}
