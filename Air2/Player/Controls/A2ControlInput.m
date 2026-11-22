//
//  A2ControlInput.m
//  Air2
//
//  实现见 A2ControlInput.h 的说明。
//  对照 ZL2：
//    ui/control/event/Events.kt
//    ui/control/event/KeyEventHandler.kt
//    ui/control/input/InputListener.kt
//

#import "A2ControlInput.h"
#import "A2ControlRenderer.h"
#import "A2Logger.h"
#import <math.h>
#import <dlfcn.h>

// ---------------------------------------------------------------------------
// 桥接兜底（有意的分层例外）
//
// 控件层的契约是 A2ControlInputDelegate（+可选的 A2ControlAdvancedInput）。
// 但宿主 SurfaceViewController 目前只实现了老协议的 5 个方法，没有鼠标键 /
// 滚轮通道。攻击、使用、滚轮这些默认控件就会"按了没反应"。
//
// input_bridge_v3.m 已经导出了这两个 C 函数（utils.h 里有声明，但那是
// Player/Context 的巨型头文件，Controls 不应该 import 它）：
//     void CallbackBridge_nativeSendMouseButton(int button, int action, int mods);
//     void CallbackBridge_nativeSendScroll(CGFloat xoffset, CGFloat yoffset);
// 所以这里用 dlsym 在运行时取符号：
//   · 编译期零依赖，Controls 仍可单独编译/预览
//   · 宿主以后实现了 A2ControlAdvancedInput，会优先走协议，不经过这里
//   · 符号不存在（预览/单测）时退回通知
// ---------------------------------------------------------------------------
typedef void (*A2BridgeMouseButtonFn)(int button, int action, int mods);
typedef void (*A2BridgeScrollFn)(CGFloat xoffset, CGFloat yoffset);

static A2BridgeMouseButtonFn A2BridgeMouseButton(void) {
    static A2BridgeMouseButtonFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (A2BridgeMouseButtonFn)(void *)dlsym(RTLD_DEFAULT,
                                                 "CallbackBridge_nativeSendMouseButton");
    });
    return fn;
}

static A2BridgeScrollFn A2BridgeScroll(void) {
    static A2BridgeScrollFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (A2BridgeScrollFn)(void *)dlsym(RTLD_DEFAULT,
                                             "CallbackBridge_nativeSendScroll");
    });
    return fn;
}

NSNotificationName const A2ControlMouseButtonNotification = @"A2ControlMouseButtonNotification";
NSNotificationName const A2ControlScrollNotification = @"A2ControlScrollNotification";
NSNotificationName const A2ControlLauncherEventNotification = @"A2ControlLauncherEventNotification";

#pragma mark - GLFW 键名表

// GLFW 3.x 的键码是固定的（glfw3.h）。这里只收录控件布局实际会用到的部分，
// 但覆盖了 26 字母 / 10 数字 / F1~F12 / 修饰键 / 导航键 / 小键盘 / 标点。
typedef struct {
    const char *name;
    NSInteger code;
} A2GLFWNameEntry;

static const A2GLFWNameEntry kGLFWNames[] = {
    {"GLFW_KEY_UNKNOWN", -1},
    {"GLFW_KEY_SPACE", 32},
    {"GLFW_KEY_APOSTROPHE", 39},
    {"GLFW_KEY_COMMA", 44},
    {"GLFW_KEY_MINUS", 45},
    {"GLFW_KEY_PERIOD", 46},
    {"GLFW_KEY_SLASH", 47},
    {"GLFW_KEY_0", 48},
    {"GLFW_KEY_1", 49},
    {"GLFW_KEY_2", 50},
    {"GLFW_KEY_3", 51},
    {"GLFW_KEY_4", 52},
    {"GLFW_KEY_5", 53},
    {"GLFW_KEY_6", 54},
    {"GLFW_KEY_7", 55},
    {"GLFW_KEY_8", 56},
    {"GLFW_KEY_9", 57},
    {"GLFW_KEY_SEMICOLON", 59},
    {"GLFW_KEY_EQUAL", 61},
    {"GLFW_KEY_A", 65},
    {"GLFW_KEY_B", 66},
    {"GLFW_KEY_C", 67},
    {"GLFW_KEY_D", 68},
    {"GLFW_KEY_E", 69},
    {"GLFW_KEY_F", 70},
    {"GLFW_KEY_G", 71},
    {"GLFW_KEY_H", 72},
    {"GLFW_KEY_I", 73},
    {"GLFW_KEY_J", 74},
    {"GLFW_KEY_K", 75},
    {"GLFW_KEY_L", 76},
    {"GLFW_KEY_M", 77},
    {"GLFW_KEY_N", 78},
    {"GLFW_KEY_O", 79},
    {"GLFW_KEY_P", 80},
    {"GLFW_KEY_Q", 81},
    {"GLFW_KEY_R", 82},
    {"GLFW_KEY_S", 83},
    {"GLFW_KEY_T", 84},
    {"GLFW_KEY_U", 85},
    {"GLFW_KEY_V", 86},
    {"GLFW_KEY_W", 87},
    {"GLFW_KEY_X", 88},
    {"GLFW_KEY_Y", 89},
    {"GLFW_KEY_Z", 90},
    {"GLFW_KEY_LEFT_BRACKET", 91},
    {"GLFW_KEY_BACKSLASH", 92},
    {"GLFW_KEY_RIGHT_BRACKET", 93},
    {"GLFW_KEY_GRAVE_ACCENT", 96},
    {"GLFW_KEY_WORLD_1", 161},
    {"GLFW_KEY_WORLD_2", 162},
    {"GLFW_KEY_ESCAPE", 256},
    {"GLFW_KEY_ENTER", 257},
    {"GLFW_KEY_TAB", 258},
    {"GLFW_KEY_BACKSPACE", 259},
    {"GLFW_KEY_INSERT", 260},
    {"GLFW_KEY_DELETE", 261},
    {"GLFW_KEY_RIGHT", 262},
    {"GLFW_KEY_LEFT", 263},
    {"GLFW_KEY_DOWN", 264},
    {"GLFW_KEY_UP", 265},
    {"GLFW_KEY_PAGE_UP", 266},
    {"GLFW_KEY_PAGE_DOWN", 267},
    {"GLFW_KEY_HOME", 268},
    {"GLFW_KEY_END", 269},
    {"GLFW_KEY_CAPS_LOCK", 280},
    {"GLFW_KEY_SCROLL_LOCK", 281},
    {"GLFW_KEY_NUM_LOCK", 282},
    {"GLFW_KEY_PRINT_SCREEN", 283},
    {"GLFW_KEY_PAUSE", 284},
    {"GLFW_KEY_F1", 290},
    {"GLFW_KEY_F2", 291},
    {"GLFW_KEY_F3", 292},
    {"GLFW_KEY_F4", 293},
    {"GLFW_KEY_F5", 294},
    {"GLFW_KEY_F6", 295},
    {"GLFW_KEY_F7", 296},
    {"GLFW_KEY_F8", 297},
    {"GLFW_KEY_F9", 298},
    {"GLFW_KEY_F10", 299},
    {"GLFW_KEY_F11", 300},
    {"GLFW_KEY_F12", 301},
    {"GLFW_KEY_F13", 302},
    {"GLFW_KEY_F14", 303},
    {"GLFW_KEY_F15", 304},
    {"GLFW_KEY_F16", 305},
    {"GLFW_KEY_F17", 306},
    {"GLFW_KEY_F18", 307},
    {"GLFW_KEY_F19", 308},
    {"GLFW_KEY_F20", 309},
    {"GLFW_KEY_F21", 310},
    {"GLFW_KEY_F22", 311},
    {"GLFW_KEY_F23", 312},
    {"GLFW_KEY_F24", 313},
    {"GLFW_KEY_F25", 314},
    {"GLFW_KEY_KP_0", 320},
    {"GLFW_KEY_KP_1", 321},
    {"GLFW_KEY_KP_2", 322},
    {"GLFW_KEY_KP_3", 323},
    {"GLFW_KEY_KP_4", 324},
    {"GLFW_KEY_KP_5", 325},
    {"GLFW_KEY_KP_6", 326},
    {"GLFW_KEY_KP_7", 327},
    {"GLFW_KEY_KP_8", 328},
    {"GLFW_KEY_KP_9", 329},
    {"GLFW_KEY_KP_DECIMAL", 330},
    {"GLFW_KEY_KP_DIVIDE", 331},
    {"GLFW_KEY_KP_MULTIPLY", 332},
    {"GLFW_KEY_KP_SUBTRACT", 333},
    {"GLFW_KEY_KP_ADD", 334},
    {"GLFW_KEY_KP_ENTER", 335},
    {"GLFW_KEY_KP_EQUAL", 336},
    {"GLFW_KEY_LEFT_SHIFT", 340},
    {"GLFW_KEY_LEFT_CONTROL", 341},
    {"GLFW_KEY_LEFT_ALT", 342},
    {"GLFW_KEY_LEFT_SUPER", 343},
    {"GLFW_KEY_RIGHT_SHIFT", 344},
    {"GLFW_KEY_RIGHT_CONTROL", 345},
    {"GLFW_KEY_RIGHT_ALT", 346},
    {"GLFW_KEY_RIGHT_SUPER", 347},
    {"GLFW_KEY_MENU", 348},
};

static const size_t kGLFWNameCount = sizeof(kGLFWNames) / sizeof(kGLFWNames[0]);

/// 鼠标键名（GLFW 语义：0 左 / 1 右 / 2 中 / 3~7 扩展）
static NSInteger A2MouseButtonFromName(NSString *name) {
    if ([name isEqualToString:@"GLFW_MOUSE_BUTTON_LEFT"] ||
        [name isEqualToString:@"GLFW_MOUSE_BUTTON_1"] ||
        [name isEqualToString:@"key.mouse.left"]) return 0;
    if ([name isEqualToString:@"GLFW_MOUSE_BUTTON_RIGHT"] ||
        [name isEqualToString:@"GLFW_MOUSE_BUTTON_2"] ||
        [name isEqualToString:@"key.mouse.right"]) return 1;
    if ([name isEqualToString:@"GLFW_MOUSE_BUTTON_MIDDLE"] ||
        [name isEqualToString:@"GLFW_MOUSE_BUTTON_3"] ||
        [name isEqualToString:@"key.mouse.middle"]) return 2;

    static NSString *const kPrefix = @"GLFW_MOUSE_BUTTON_";
    if ([name hasPrefix:kPrefix]) {
        NSString *tail = [name substringFromIndex:kPrefix.length];
        NSInteger n = tail.integerValue;
        if (n >= 4 && n <= 8) return n - 1;   // GLFW_MOUSE_BUTTON_4 → 3
    }
    return -1;
}

#pragma mark - A2ControlEventKey

@implementation A2ControlEventKey

+ (NSString *)glfwNameForKeyCode:(NSInteger)code {
    for (size_t i = 0; i < kGLFWNameCount; i++) {
        if (kGLFWNames[i].code == code) return @(kGLFWNames[i].name);
    }
    return nil;
}

+ (NSString *)keyCodeForGLFWName:(NSString *)name {
    if (![name isKindOfClass:NSString.class] || name.length == 0) return nil;
    for (size_t i = 0; i < kGLFWNameCount; i++) {
        if (strcmp(kGLFWNames[i].name, name.UTF8String) == 0) {
            return [NSString stringWithFormat:@"%ld", (long)kGLFWNames[i].code];
        }
    }
    return nil;
}

+ (A2ControlInputKind)kindForRawKey:(NSString *)raw outCode:(NSInteger *)outCode {
    if (![raw isKindOfClass:NSString.class]) return A2ControlInputKindUnknown;

    NSString *s = [raw stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return A2ControlInputKindUnknown;

    if (outCode) *outCode = -1;

    // ---- 滚轮（ZL2 有四种写法）----
    if ([s isEqualToString:@"launcher.event.scroll_up.single"] ||
        [s isEqualToString:@"launcher.event.scroll_down.single"] ||
        [s isEqualToString:@"MOUSE_SCROLL_UP"] ||
        [s isEqualToString:@"MOUSE_SCROLL_DOWN"] ||
        [s hasPrefix:@"scroll:"]) {
        return A2ControlInputKindScroll;
    }

    // ---- 启动器事件 ----
    if ([s hasPrefix:@"launcher.event."]) return A2ControlInputKindLauncher;

    // ---- 鼠标键（名字写法 / key.mouse.*）----
    NSInteger mb = A2MouseButtonFromName(s);
    if (mb >= 0) {
        if (outCode) *outCode = mb;
        return A2ControlInputKindMouseButton;
    }

    // ---- GLFW 名称 ----
    if ([s hasPrefix:@"GLFW_KEY_"]) {
        NSString *code = [self keyCodeForGLFWName:s];
        if (code) {
            if (outCode) *outCode = code.integerValue;
            return A2ControlInputKindKey;
        }
        return A2ControlInputKindUnknown;
    }

    // ---- 数字：0~7 视作鼠标键（GLFW 键盘从 32 起），其余是键盘 ----
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    if ([[s stringByTrimmingCharactersInSet:digits] length] == 0) {
        NSInteger code = s.integerValue;
        if (code >= 0 && code <= 7) {
            if (outCode) *outCode = code;
            return A2ControlInputKindMouseButton;
        }
        if (outCode) *outCode = code;
        return A2ControlInputKindKey;
    }

    // ---- "87.0" 这种带小数点的历史数据 ----
    if ([s rangeOfString:@"."].location != NSNotFound) {
        NSInteger code = (NSInteger)llround(s.doubleValue);
        if (code >= 0 && code <= 7) {
            if (outCode) *outCode = code;
            return A2ControlInputKindMouseButton;
        }
        if (outCode) *outCode = code;
        return code > 0 ? A2ControlInputKindKey : A2ControlInputKindUnknown;
    }

    return A2ControlInputKindUnknown;
}

+ (NSString *)normalizedKey:(NSString *)raw {
    NSInteger code = -1;
    switch ([self kindForRawKey:raw outCode:&code]) {
        case A2ControlInputKindKey:
        case A2ControlInputKindMouseButton:
            return code >= 0 ? [NSString stringWithFormat:@"%ld", (long)code] : nil;
        case A2ControlInputKindScroll: {
            NSInteger dir = [self scrollDirectionForRawKey:raw];
            return dir != 0 ? [NSString stringWithFormat:@"scroll:%ld", (long)dir] : nil;
        }
        case A2ControlInputKindLauncher:
        case A2ControlInputKindUnknown:
        default:
            return nil;
    }
}

+ (NSString *)keyForMouseButton:(NSInteger)button {
    if (button < 0) return nil;
    return [NSString stringWithFormat:@"%ld", (long)button];
}

+ (BOOL)isSingleScrollKey:(NSString *)raw {
    if (![raw isKindOfClass:NSString.class]) return NO;
    return [raw hasSuffix:@".single"];
}

+ (NSInteger)scrollDirectionForRawKey:(NSString *)raw {
    if (![raw isKindOfClass:NSString.class]) return 0;
    if ([raw hasPrefix:@"scroll:"]) {
        return raw.integerValue == 0 ? 0 : (raw.integerValue > 0 ? 1 : -1);
    }
    if ([raw isEqualToString:@"MOUSE_SCROLL_UP"]) return 1;
    if ([raw isEqualToString:@"MOUSE_SCROLL_DOWN"]) return -1;
    if ([raw hasPrefix:@"launcher.event.scroll_up"]) return 1;
    if ([raw hasPrefix:@"launcher.event.scroll_down"]) return -1;
    return 0;
}

@end

#pragma mark - A2KeyStateKeeper

@interface A2KeyStateKeeper ()
/// key → 按住它的控件数
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *counts;
@end

@implementation A2KeyStateKeeper

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _counts = [NSMutableDictionary dictionary];
    return self;
}

- (BOOL)hasPressedKeys {
    return self.counts.count > 0;
}

- (NSArray<NSString *> *)pressedKeys {
    return self.counts.allKeys;
}

- (BOOL)isPressed:(NSString *)key {
    if (key.length == 0) return NO;
    return self.counts[key] != nil;
}

- (void)pressKey:(NSString *)key {
    if (key.length == 0) return;

    NSInteger old = self.counts[key].integerValue;
    self.counts[key] = @(old + 1);
    // 只有 0 → 1 才真正下发（对照 KeyEventHandler.pressKey）
    if (old == 0) {
        [self.delegate controlPressKey:key];
    }
}

- (void)releaseKey:(NSString *)key {
    if (key.length == 0) return;

    NSInteger old = self.counts[key].integerValue;
    if (old <= 0) {
        // 没按住却要抬 —— 忽略，不要打扰宿主
        return;
    }
    if (old == 1) {
        [self.counts removeObjectForKey:key];
        [self.delegate controlReleaseKey:key];
    } else {
        self.counts[key] = @(old - 1);
    }
}

- (void)releaseAll {
    // 先快照再清空 —— 否则 delegate 回调里再改字典会崩
    NSArray<NSString *> *keys = self.counts.allKeys;
    [self.counts removeAllObjects];
    for (NSString *k in keys) {
        [self.delegate controlReleaseKey:k];
    }
}

- (void)dealloc {
    // 视图销毁时不能留下粘键
    [self releaseAll];
}

@end

#pragma mark - A2ControlInputDispatcher

@interface A2ControlInputDispatcher ()
@property (nonatomic, strong) A2KeyStateKeeper *keyState;
/// 兜底告警只打一次，避免高频触摸刷爆日志
@property (nonatomic, assign) BOOL didWarnMouseFallback;
@property (nonatomic, assign) BOOL didWarnScrollFallback;
@end

@implementation A2ControlInputDispatcher

+ (instancetype)dispatcherWithDelegate:(id<A2ControlInputDelegate>)delegate {
    A2ControlInputDispatcher *d = [A2ControlInputDispatcher new];
    d.delegate = delegate;
    return d;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _keyState = [A2KeyStateKeeper new];
    return self;
}

- (void)setDelegate:(id<A2ControlInputDelegate>)delegate {
    _delegate = delegate;
    self.keyState.delegate = delegate;
}

#pragma mark 事件键

- (void)pressEventKey:(NSString *)raw {
    NSInteger code = -1;
    switch ([A2ControlEventKey kindForRawKey:raw outCode:&code]) {
        case A2ControlInputKindKey:
            [self.keyState pressKey:[NSString stringWithFormat:@"%ld", (long)code]];
            break;

        case A2ControlInputKindMouseButton:
            [self pressMouseButton:code];
            break;

        case A2ControlInputKindScroll:
            [self scrollByX:0 y:[A2ControlEventKey scrollDirectionForRawKey:raw]];
            break;

        case A2ControlInputKindLauncher:
            [self launcherEvent:raw];
            break;

        default:
            break;
    }
}

- (void)releaseEventKey:(NSString *)raw {
    NSInteger code = -1;
    switch ([A2ControlEventKey kindForRawKey:raw outCode:&code]) {
        case A2ControlInputKindKey:
            [self.keyState releaseKey:[NSString stringWithFormat:@"%ld", (long)code]];
            break;

        case A2ControlInputKindMouseButton:
            [self releaseMouseButton:code];
            break;

        default:
            // 滚轮与启动器事件没有「按住」概念
            break;
    }
}

#pragma mark 鼠标

- (void)pressMouseButton:(NSInteger)button {
    id<A2ControlInputDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(controlPressMouseButton:)]) {
        [(id<A2ControlAdvancedInput>)d controlPressMouseButton:button];
        return;
    }
    // 宿主还没实现扩展协议。
    // 老实现会把鼠标键塞进 keyState 走 controlPressKey: —— 那是错的：
    //   · 左键 0 被 SurfaceViewController 的 `code <= 0` 直接丢掉
    //   · 右键/中键 1/2 会被当成 GLFW 键盘码 1/2 发进游戏（游戏里不存在这两个键）
    // 这里先试运行时的 input_bridge 符号（见文件头说明），再退通知。
    A2BridgeMouseButtonFn fn = A2BridgeMouseButton();
    if (fn) {
        fn((int)button, 1, 0);
        return;
    }
    if (!self.didWarnMouseFallback) {
        self.didWarnMouseFallback = YES;
        [A2Logger warning:@"A2ControlInput"
                  message:@"宿主未实现 A2ControlAdvancedInput，且找不到 "
                          @"CallbackBridge_nativeSendMouseButton；鼠标键改走通知（不再伪造键盘码）"];
    }
    [NSNotificationCenter.defaultCenter
        postNotificationName:A2ControlMouseButtonNotification
                      object:self
                    userInfo:@{@"button": @(button), @"pressed": @YES}];
}

- (void)releaseMouseButton:(NSInteger)button {
    id<A2ControlInputDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(controlReleaseMouseButton:)]) {
        [(id<A2ControlAdvancedInput>)d controlReleaseMouseButton:button];
        return;
    }
    A2BridgeMouseButtonFn fn = A2BridgeMouseButton();
    if (fn) {
        fn((int)button, 0, 0);
        return;
    }
    [NSNotificationCenter.defaultCenter
        postNotificationName:A2ControlMouseButtonNotification
                      object:self
                    userInfo:@{@"button": @(button), @"pressed": @NO}];
}

- (void)moveMouseBy:(CGPoint)delta {
    if (CGPointEqualToPoint(delta, CGPointZero)) return;
    [self.delegate controlMoveMouse:delta];
}

- (BOOL)moveMouseTo:(CGPoint)position {
    id<A2ControlInputDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(controlMoveMouseTo:)]) {
        [(id<A2ControlAdvancedInput>)d controlMoveMouseTo:position];
        return YES;
    }
    return NO;
}

- (void)scrollByX:(CGFloat)dx y:(CGFloat)dy {
    if (dx == 0 && dy == 0) return;

    id<A2ControlInputDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(controlScrollByX:y:)]) {
        [(id<A2ControlAdvancedInput>)d controlScrollByX:dx y:dy];
        return;
    }
    // 没有滚轮通道：先试 input_bridge 的导出函数（见文件头说明），再发通知。
    A2BridgeScrollFn fn = A2BridgeScroll();
    if (fn) {
        fn(dx, dy);
        return;
    }
    if (!self.didWarnScrollFallback) {
        self.didWarnScrollFallback = YES;
        [A2Logger warning:@"A2ControlInput"
                  message:@"宿主未实现 A2ControlAdvancedInput，且找不到 "
                          @"CallbackBridge_nativeSendScroll；滚轮改走通知"];
    }
    [NSNotificationCenter.defaultCenter
        postNotificationName:A2ControlScrollNotification
                      object:self
                    userInfo:@{@"dx": @(dx), @"dy": @(dy)}];
}

#pragma mark 启动器事件

- (void)launcherEvent:(NSString *)name {
    if (name.length == 0) return;

    if ([name hasPrefix:@"launcher.event.scroll_"]) {
        NSInteger dir = [A2ControlEventKey scrollDirectionForRawKey:name];
        [self scrollByX:0 y:dir];
        return;
    }
    if ([name isEqualToString:@"launcher.event.switch_ime"]) {
        [self.delegate controlToggleKeyboard];
        return;
    }
    if ([name isEqualToString:@"launcher.event.switch_menu"] ||
        [name isEqualToString:@"toggle_gui"] || [name isEqualToString:@"ToggleGui"]) {
        [self.delegate controlToggleGui];
        return;
    }

    // 其它启动器事件（切换鼠标模式、切层等）交给上层订阅
    [NSNotificationCenter.defaultCenter
        postNotificationName:A2ControlLauncherEventNotification
                      object:self
                    userInfo:@{@"event": name}];
}

- (void)releaseAll {
    [self.keyState releaseAll];
}

- (void)dealloc {
    [self.keyState releaseAll];
}

@end
