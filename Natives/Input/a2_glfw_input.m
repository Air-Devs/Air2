// ============================================================================
//  Natives/Input/a2_glfw_input.m
//  Air2 —— 自研 GLFW 输入层（阶段 A）· 实现
// ----------------------------------------------------------------------------
//  职责：把 iOS 的触摸事件翻译成 GLFW 语义事件并投进事件总线。
//    · 触摸 → 光标位置 + 鼠标左键（GLFW 语义：一根主触摸 = 指针）
//    · 外接键盘按下/抬起 → 转发给映射层的键盘源（[INPUT-MAP-1] 起不在本文件翻译）
//    · 外接键盘字符 → CHAR 事件（文本输入不是「按了哪个键」，不参与改绑）
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

// [INPUT-MAP-1] 统一输入映射层：键盘不再在本文件里翻译，改由「源 → 映射 → 内核汇」。
#import "A2GamepadInputSource.h"
#import "A2InputBinding.h"
#import "A2InputRouter.h"
#import "A2KernelInputSink.h"
#import "A2KeyboardInputSource.h"
#import "A2VirtualButtonInputSource.h"

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
//  HID → GLFW 键码表已搬到 A2KeyboardInputSource（[INPUT-MAP-1]）
// ============================================================================
//  搬走的原因：表是「键盘这个源怎么翻译自己」的知识，属于源。留在本文件会出现
//  两份口径（一份给视图、一份给映射层），同一个物理键可能在两条路径上给出两个
//  键码 —— 那样用户改绑的键和实际按下的键就永远对不上。
//  本文件只保留「修饰位」的翻译：CHAR（文本输入）事件仍然带 mods。

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
/// [INPUT-MAP-1] 本窗口的输入路由器（装配在 a2_glfw_input_router()）。
/// ★强引用★：视图是路由器的生命周期锚点；路由器只弱登记在窗口表里。
@property (nonatomic, strong) A2InputRouter *a2InputRouter;
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
// [INPUT-MAP-1] 键盘源（装配保证存在；窗口句柄为 0 时可能为 nil）。
- (A2KeyboardInputSource *)a2KeyboardSource;
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
    if (getenv("AMETHYST_METAL") != NULL) {
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
        // [INPUT-MAP-1] 窗口一有视图就把映射层装好：键盘源已启动、内核汇已接上。
        // 虚拟按钮源/手柄源也在这里注册（只有接口，start 会如实失败并留日志）。
        _a2InputRouter = a2_glfw_input_router(window);
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
                                  : ((UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) ? 1.25 : 1.0);
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
    int mods = a2_glfw_mods_from_flags(event.modifierFlags);
    A2KeyboardInputSource *keyboard = [self a2KeyboardSource];
    for (UIPress *pr in presses) {
        UIKey *key = pr.key;
        if (key == nil) {
            continue;
        }
        // ① 按键：交给映射层（改绑 / 键盘直通 / 多源同落点的引用计数都在那里）。
        //    未覆盖的 HID usage 由键盘源自己记日志（只报一次），这里不做判断。
        [keyboard handleHIDUsage:(long) key.keyCode action:A2InputActionPress mods:mods];

        // ② 文本：仍是 CHAR 通道。★字符流不是「按了哪个键」★：
        //    MC 的聊天/告示牌输入读 glfwSetCharCallback，改绑不该影响打出来的字。
        [self postChar:key mods:mods];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    int mods = a2_glfw_mods_from_flags(event.modifierFlags);
    A2KeyboardInputSource *keyboard = [self a2KeyboardSource];
    for (UIPress *pr in presses) {
        UIKey *key = pr.key;
        if (key == nil) {
            continue;
        }
        // 抬起必须和按下走同一条路：否则映射层记的「按下集合」永远清不掉
        // （MC 里就是「松手了还在走」）。
        [keyboard handleHIDUsage:(long) key.keyCode action:A2InputActionRelease mods:mods];
    }
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self pressesEnded:presses withEvent:event];
}

- (A2KeyboardInputSource *)a2KeyboardSource {
    id<A2InputSource> source = [self.a2InputRouter sourceForKind:A2InputSourceKindKeyboard];
    // 装配（a2_glfw_input_router）保证键盘源存在；这里不兜底造一个：
    // 造出来也没有汇，按键会静默消失 —— 那比 nil 更难查。
    return (A2KeyboardInputSource *) source;
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
/// 调用方：A2GameControlsView（屏幕上的方向/跳跃/潜行等按钮）、A2KernelInputSink。
/// 为什么走同一条事件总线：MC 只认 GLFW 回调，绕开它自己造一条会与真实输入打架。
void a2_glfw_input_post_key(long window, int key, int action) {
    a2_glfw_input_post_key_event(window, key, 0, action, 0);
}

/// ★映射层投递键盘事件走这条★：硬件键盘的 scancode 与 Ctrl/Shift 组合键都在这里带下去。
/// ★26.3 内核★：GLFW 总线 + SDL 镜像一次做完，调用方不需要判断版本。
void a2_glfw_input_post_key_event(long window, int key, int scancode, int action, int mods) {
    A2GlfwEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.window = window;
    ev.type = A2_GLFW_EVENT_KEY;
    ev.i0 = key;
    ev.i1 = scancode;   // 0 = 合成输入；硬件键盘 = HID usage
    ev.i2 = action;     // GLFW_PRESS=1 / GLFW_RELEASE=0
    ev.i3 = mods;
    a2_glfw_event_post(&ev);    // ★26.3★ 键事件镜像到 SDL（26.2 自动 no-op）
    a2_sdl_input_key(key, action ? 1 : 0);
}

UIView *a2_glfw_input_make_view(long window) {
    A2GlfwView *view = [[A2GlfwView alloc] initWithWindowHandle:window];
    return view;
}

// ============================================================================
//  [INPUT-MAP-1] 映射层装配（每个窗口一份）
// ============================================================================
//  ★登记表是「强键 → 弱值」★：窗口句柄做键，路由器做弱值。
//  路由器的强引用归视图（A2GlfwView.a2InputRouter）——视图没了，条目自动消失，
//  不需要在窗口销毁路径上加钩子（那条路径上有 JVM 退出与线程收尾，越少动越好）。
static NSMapTable<NSNumber *, A2InputRouter *> *A2InputRouterTable(void) {
    static NSMapTable<NSNumber *, A2InputRouter *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSMapTable strongToWeakObjectsMapTable];
    });
    return table;
}

A2InputRouter *a2_glfw_input_router(long window) {
    if (window == 0) {
        return nil;
    }
    NSNumber *key = @(window);
    A2InputRouter *existing = [A2InputRouterTable() objectForKey:key];
    if (existing != nil) {
        return existing;
    }

    A2InputRouter *router = [[A2InputRouter alloc] initWithBindings:[A2InputBindingTable defaultTable]];

    // ① 内核汇：一份覆盖所有内核（GLFW 总线 + 26.3 的 SDL 镜像都在投递函数里）。
    [router addSink:[[A2KernelInputSink alloc] initWithWindowHandle:window]];

    // ② 键盘源：本迭代真正实现的那一种。
    [router addSource:[[A2KeyboardInputSource alloc] init]];

    // ③ 虚拟按钮源 / 手柄源：只有接口。[INPUT-MAP-2] / [INPUT-MAP-3] 补实现。
    //    ★在这里注册而不是不注册★：让「未接线」这件事在启动日志里就可见，
    //    而不是等用户插上手柄发现没反应才去猜。
    [router addSource:[[A2VirtualButtonInputSource alloc] init]];
    [router addSource:[[A2GamepadInputSource alloc] init]];

    [A2InputRouterTable() setObject:router forKey:key];
    a2_log_criterion(@"[INPUT-MAP] 输入映射层已装配 window=%ld（键盘已实现；虚拟按钮/手柄仅接口）",
                     window);
    return router;
}
