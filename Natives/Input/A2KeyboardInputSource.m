// ============================================================================
//  Natives/Input/A2KeyboardInputSource.m
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 键盘源实现
// ----------------------------------------------------------------------------
//  HID→GLFW 表的依据是**公开标准数据**：USB HID Usage Tables（Keyboard/Keypad
//  usage ID）与 GLFW 官方 glfw3.h 的键码数值。净室实现，未参考 Pojav /
//  Boardwalk / Amethyst / LWJGL 的源码。
//
//  ★覆盖范围★：字母/数字/标点/编辑键/方向键/F1–F24/小键盘/修饰键 —— 也就是
//  GLFW 键盘空间里「外接键盘真的可能发出来」的全部。多媒体键（音量/播放）不映射：
//  GLFW 没有对应键码，硬编一个数字只会造出 MC 永远收不到的假绑定。
// ============================================================================
#import "A2KeyboardInputSource.h"

#import "a2_log.h"

static int A2GLFWKeyFromHIDUsage(long hid) {
    // 字母 a..z：HID 0x04..0x1D ⇒ GLFW_KEY_A(65)..GLFW_KEY_Z(90)
    if (hid >= 0x04 && hid <= 0x1D) {
        return 65 + (int) (hid - 0x04);
    }
    // 数字 1..9：HID 0x1E..0x26 ⇒ GLFW_KEY_1(49)..GLFW_KEY_9(57)
    if (hid >= 0x1E && hid <= 0x26) {
        return 49 + (int) (hid - 0x1E);
    }
    // F1..F12：HID 0x3A..0x45 ⇒ GLFW_KEY_F1(290)..F12(301)
    if (hid >= 0x3A && hid <= 0x45) {
        return 290 + (int) (hid - 0x3A);
    }
    // F13..F24：HID 0x68..0x73 ⇒ GLFW_KEY_F13(302)..F24(313)
    if (hid >= 0x68 && hid <= 0x73) {
        return 302 + (int) (hid - 0x68);
    }
    // 小键盘 1..9：HID 0x59..0x61 ⇒ GLFW_KEY_KP_1(321)..KP_9(329)
    if (hid >= 0x59 && hid <= 0x61) {
        return 321 + (int) (hid - 0x59);
    }

    switch (hid) {
        case 0x27: return 48;    // 0            -> GLFW_KEY_0
        case 0x28: return 257;   // Return       -> GLFW_KEY_ENTER
        case 0x29: return 256;   // Escape       -> GLFW_KEY_ESCAPE
        case 0x2A: return 259;   // Backspace    -> GLFW_KEY_BACKSPACE
        case 0x2B: return 258;   // Tab          -> GLFW_KEY_TAB
        case 0x2C: return 32;    // Space        -> GLFW_KEY_SPACE
        case 0x2D: return 45;    // -            -> GLFW_KEY_MINUS
        case 0x2E: return 61;    // =            -> GLFW_KEY_EQUAL
        case 0x2F: return 91;    // [            -> GLFW_KEY_LEFT_BRACKET
        case 0x30: return 93;    // ]            -> GLFW_KEY_RIGHT_BRACKET
        case 0x31: return 92;    // \            -> GLFW_KEY_BACKSLASH
        case 0x32: return 162;   // 非 US 的 #~   -> GLFW_KEY_WORLD_2
        case 0x33: return 59;    // ;            -> GLFW_KEY_SEMICOLON
        case 0x34: return 39;    // '            -> GLFW_KEY_APOSTROPHE
        case 0x35: return 96;    // `            -> GLFW_KEY_GRAVE_ACCENT
        case 0x36: return 44;    // ,            -> GLFW_KEY_COMMA
        case 0x37: return 46;    // .            -> GLFW_KEY_PERIOD
        case 0x38: return 47;    // /            -> GLFW_KEY_SLASH
        case 0x39: return 280;   // CapsLock     -> GLFW_KEY_CAPS_LOCK
        case 0x46: return 283;   // PrintScreen  -> GLFW_KEY_PRINT_SCREEN
        case 0x47: return 281;   // ScrollLock   -> GLFW_KEY_SCROLL_LOCK
        case 0x48: return 284;   // Pause        -> GLFW_KEY_PAUSE
        case 0x49: return 260;   // Insert       -> GLFW_KEY_INSERT
        case 0x4A: return 268;   // Home         -> GLFW_KEY_HOME
        case 0x4B: return 266;   // PageUp       -> GLFW_KEY_PAGE_UP
        case 0x4C: return 261;   // Delete(前向) -> GLFW_KEY_DELETE
        case 0x4D: return 269;   // End          -> GLFW_KEY_END
        case 0x4E: return 267;   // PageDown     -> GLFW_KEY_PAGE_DOWN
        case 0x4F: return 262;   // Right        -> GLFW_KEY_RIGHT
        case 0x50: return 263;   // Left         -> GLFW_KEY_LEFT
        case 0x51: return 264;   // Down         -> GLFW_KEY_DOWN
        case 0x52: return 265;   // Up           -> GLFW_KEY_UP
        case 0x53: return 282;   // NumLock      -> GLFW_KEY_NUM_LOCK
        case 0x54: return 331;   // KP /         -> GLFW_KEY_KP_DIVIDE
        case 0x55: return 332;   // KP *         -> GLFW_KEY_KP_MULTIPLY
        case 0x56: return 333;   // KP -         -> GLFW_KEY_KP_SUBTRACT
        case 0x57: return 334;   // KP +         -> GLFW_KEY_KP_ADD
        case 0x58: return 335;   // KP Enter     -> GLFW_KEY_KP_ENTER
        case 0x62: return 320;   // KP 0         -> GLFW_KEY_KP_0
        case 0x63: return 330;   // KP .         -> GLFW_KEY_KP_DECIMAL
        case 0x64: return 161;   // 非 US 的 \|   -> GLFW_KEY_WORLD_1
        case 0x65: return 348;   // Application  -> GLFW_KEY_MENU
        case 0x67: return 336;   // KP =         -> GLFW_KEY_KP_EQUAL
        case 0xE0: return 341;   // LCtrl        -> GLFW_KEY_LEFT_CONTROL
        case 0xE1: return 340;   // LShift       -> GLFW_KEY_LEFT_SHIFT
        case 0xE2: return 342;   // LAlt         -> GLFW_KEY_LEFT_ALT
        case 0xE3: return 343;   // LGUI         -> GLFW_KEY_LEFT_SUPER
        case 0xE4: return 345;   // RCtrl        -> GLFW_KEY_RIGHT_CONTROL
        case 0xE5: return 344;   // RShift       -> GLFW_KEY_RIGHT_SHIFT
        case 0xE6: return 346;   // RAlt         -> GLFW_KEY_RIGHT_ALT
        case 0xE7: return 347;   // RGUI         -> GLFW_KEY_RIGHT_SUPER
        default: break;
    }
    return -1;   // GLFW_KEY_UNKNOWN（官方值 -1）
}

@implementation A2KeyboardInputSource {
    /// 未覆盖的 HID usage 只报一次（真机上一个陌生的多媒体键不该刷满日志）
    BOOL _loggedUnmappedUsage;
}

// 协议里的属性必须显式合成：只声明在 @protocol 上的 @property 不会自动生 ivar。
@synthesize enabled = _enabled;
@synthesize delegate = _delegate;

#pragma mark - A2InputSource

- (A2InputSourceKind)sourceKind {
    return A2InputSourceKindKeyboard;
}

- (NSString *)sourceIdentifier {
    return @"keyboard";
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _enabled = YES;
    }
    return self;
}

- (BOOL)startWithError:(NSError *_Nullable *_Nullable)error {
    // 键盘没有「注册监听」这一步：UIKit 把 presses* 事件推给宿主视图，视图再转进来。
    // 所以 start 只是把开关打开 —— 但仍然如实走一遍协议，装配点不必为每个源写分支。
    (void) error;
    self.enabled = YES;
    return YES;
}

- (void)stop {
    self.enabled = NO;
}

#pragma mark - 触发

+ (int)glfwKeyForHIDUsage:(long)hidUsage {
    return A2GLFWKeyFromHIDUsage(hidUsage);
}

- (BOOL)handleHIDUsage:(long)hidUsage action:(A2InputAction)action mods:(int)mods {
    if (!self.isEnabled) {
        return NO;
    }
    int glfwKey = A2GLFWKeyFromHIDUsage(hidUsage);
    if (glfwKey < 0) {
        if (!_loggedUnmappedUsage) {
            _loggedUnmappedUsage = YES;
            a2_log_f(@"[INPUT-MAP] 键盘 HID usage 未覆盖：0x%02lx（该键不产生按键事件；"
                     @"若是常用键，补 A2KeyboardInputSource 的表）",
                     (unsigned long) hidUsage);
        }
        return NO;
    }
    A2InputTrigger trigger = A2InputTriggerMake(A2InputSourceKindKeyboard, glfwKey, nil, action, mods);
    trigger.scancode = (int) hidUsage;   // 保留 HID usage，供按 scancode 认键的 Mod 使用
    [self.delegate inputSource:self didProduceTrigger:trigger];
    return YES;
}

@end
