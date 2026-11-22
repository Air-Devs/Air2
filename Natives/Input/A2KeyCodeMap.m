//
//  A2KeyCodeMap.m
//  Air2
//
//  映射表由参考实现的公开常量逐条对齐生成（见头文件说明）。
//  表是常量、无状态，不构成全局可变单例。
//

#import "A2KeyCodeMap.h"

typedef struct {
    int from;
    int to;
} A2KeyMapEntry;

/// FCL（Linux evdev）→ GLFW。100 条。
static const A2KeyMapEntry kA2EvdevToGlfw[] = {
    {   1, 256 }, // KEY_ESC
    {   2,  49 }, // KEY_1
    {   3,  50 }, // KEY_2
    {   4,  51 }, // KEY_3
    {   5,  52 }, // KEY_4
    {   6,  53 }, // KEY_5
    {   7,  54 }, // KEY_6
    {   8,  55 }, // KEY_7
    {   9,  56 }, // KEY_8
    {  10,  57 }, // KEY_9
    {  11,  48 }, // KEY_0
    {  12,  45 }, // KEY_MINUS
    {  13,  61 }, // KEY_EQUAL
    {  14, 259 }, // KEY_BACKSPACE
    {  15, 258 }, // KEY_TAB
    {  16,  81 }, // KEY_Q
    {  17,  87 }, // KEY_W
    {  18,  69 }, // KEY_E
    {  19,  82 }, // KEY_R
    {  20,  84 }, // KEY_T
    {  21,  89 }, // KEY_Y
    {  22,  85 }, // KEY_U
    {  23,  73 }, // KEY_I
    {  24,  79 }, // KEY_O
    {  25,  80 }, // KEY_P
    {  26,  91 }, // KEY_LEFTBRACE
    {  27,  93 }, // KEY_RIGHTBRACE
    {  28, 257 }, // KEY_ENTER
    {  29, 341 }, // KEY_LEFTCTRL
    {  30,  65 }, // KEY_A
    {  31,  83 }, // KEY_S
    {  32,  68 }, // KEY_D
    {  33,  70 }, // KEY_F
    {  34,  71 }, // KEY_G
    {  35,  72 }, // KEY_H
    {  36,  74 }, // KEY_J
    {  37,  75 }, // KEY_K
    {  38,  76 }, // KEY_L
    {  39,  59 }, // KEY_SEMICOLON
    {  40,  39 }, // KEY_APOSTROPHE
    {  41,  96 }, // KEY_GRAVE
    {  42, 340 }, // KEY_LEFTSHIFT
    {  43,  92 }, // KEY_BACKSLASH
    {  44,  90 }, // KEY_Z
    {  45,  88 }, // KEY_X
    {  46,  67 }, // KEY_C
    {  47,  86 }, // KEY_V
    {  48,  66 }, // KEY_B
    {  49,  78 }, // KEY_N
    {  50,  77 }, // KEY_M
    {  51,  44 }, // KEY_COMMA
    {  52,  46 }, // KEY_DOT
    {  53,  47 }, // KEY_SLASH
    {  54, 344 }, // KEY_RIGHTSHIFT
    {  55, 332 }, // KEY_KPASTERISK
    {  56, 342 }, // KEY_LEFTALT
    {  57,  32 }, // KEY_SPACE
    {  58, 280 }, // KEY_CAPSLOCK
    {  59, 290 }, // KEY_F1
    {  60, 291 }, // KEY_F2
    {  61, 292 }, // KEY_F3
    {  62, 293 }, // KEY_F4
    {  63, 294 }, // KEY_F5
    {  64, 295 }, // KEY_F6
    {  65, 296 }, // KEY_F7
    {  66, 297 }, // KEY_F8
    {  67, 298 }, // KEY_F9
    {  68, 299 }, // KEY_F10
    {  69, 282 }, // KEY_NUMLOCK
    {  71, 327 }, // KEY_KP7
    {  72, 328 }, // KEY_KP8
    {  73, 329 }, // KEY_KP9
    {  74, 333 }, // KEY_KPMINUS
    {  75, 324 }, // KEY_KP4
    {  76, 325 }, // KEY_KP5
    {  77, 326 }, // KEY_KP6
    {  78, 334 }, // KEY_KPPLUS
    {  79, 321 }, // KEY_KP1
    {  80, 322 }, // KEY_KP2
    {  81, 323 }, // KEY_KP3
    {  82, 320 }, // KEY_KP0
    {  83, 330 }, // KEY_KPDOT
    {  87, 300 }, // KEY_F11
    {  88, 301 }, // KEY_F12
    {  96, 335 }, // KEY_KPENTER
    {  97, 345 }, // KEY_RIGHTCTRL
    {  98, 331 }, // KEY_KPSLASH
    { 100, 346 }, // KEY_RIGHTALT
    { 102, 268 }, // KEY_HOME
    { 103, 265 }, // KEY_UP
    { 104, 266 }, // KEY_PAGEUP
    { 105, 263 }, // KEY_LEFT
    { 106, 262 }, // KEY_RIGHT
    { 107, 269 }, // KEY_END
    { 108, 264 }, // KEY_DOWN
    { 109, 267 }, // KEY_PAGEDOWN
    { 110, 260 }, // KEY_INSERT
    { 111, 261 }, // KEY_DELETE
    { 117, 336 }, // KEY_KPEQUAL
    { 119, 284 }, // KEY_PAUSE
};

/// GLFW 常量名 → 数值。121 条。
static const struct { const char *name; int code; } kA2GlfwNames[] = {
    { "UNKNOWN", 0 },
    { "SPACE", 32 },
    { "APOSTROPHE", 39 },
    { "COMMA", 44 },
    { "MINUS", 45 },
    { "PERIOD", 46 },
    { "SLASH", 47 },
    { "0", 48 },
    { "1", 49 },
    { "2", 50 },
    { "3", 51 },
    { "4", 52 },
    { "5", 53 },
    { "6", 54 },
    { "7", 55 },
    { "8", 56 },
    { "9", 57 },
    { "SEMICOLON", 59 },
    { "EQUAL", 61 },
    { "A", 65 },
    { "B", 66 },
    { "C", 67 },
    { "D", 68 },
    { "E", 69 },
    { "F", 70 },
    { "G", 71 },
    { "H", 72 },
    { "I", 73 },
    { "J", 74 },
    { "K", 75 },
    { "L", 76 },
    { "M", 77 },
    { "N", 78 },
    { "O", 79 },
    { "P", 80 },
    { "Q", 81 },
    { "R", 82 },
    { "S", 83 },
    { "T", 84 },
    { "U", 85 },
    { "V", 86 },
    { "W", 87 },
    { "X", 88 },
    { "Y", 89 },
    { "Z", 90 },
    { "LEFT_BRACKET", 91 },
    { "BACKSLASH", 92 },
    { "RIGHT_BRACKET", 93 },
    { "GRAVE_ACCENT", 96 },
    { "WORLD_1", 161 },
    { "WORLD_2", 162 },
    { "ESCAPE", 256 },
    { "ENTER", 257 },
    { "TAB", 258 },
    { "BACKSPACE", 259 },
    { "INSERT", 260 },
    { "DELETE", 261 },
    { "RIGHT", 262 },
    { "LEFT", 263 },
    { "DOWN", 264 },
    { "UP", 265 },
    { "PAGE_UP", 266 },
    { "PAGE_DOWN", 267 },
    { "HOME", 268 },
    { "END", 269 },
    { "CAPS_LOCK", 280 },
    { "SCROLL_LOCK", 281 },
    { "NUM_LOCK", 282 },
    { "PRINT_SCREEN", 283 },
    { "PAUSE", 284 },
    { "F1", 290 },
    { "F2", 291 },
    { "F3", 292 },
    { "F4", 293 },
    { "F5", 294 },
    { "F6", 295 },
    { "F7", 296 },
    { "F8", 297 },
    { "F9", 298 },
    { "F10", 299 },
    { "F11", 300 },
    { "F12", 301 },
    { "F13", 302 },
    { "F14", 303 },
    { "F15", 304 },
    { "F16", 305 },
    { "F17", 306 },
    { "F18", 307 },
    { "F19", 308 },
    { "F20", 309 },
    { "F21", 310 },
    { "F22", 311 },
    { "F23", 312 },
    { "F24", 313 },
    { "F25", 314 },
    { "KP_0", 320 },
    { "KP_1", 321 },
    { "KP_2", 322 },
    { "KP_3", 323 },
    { "KP_4", 324 },
    { "KP_5", 325 },
    { "KP_6", 326 },
    { "KP_7", 327 },
    { "KP_8", 328 },
    { "KP_9", 329 },
    { "KP_DECIMAL", 330 },
    { "KP_DIVIDE", 331 },
    { "KP_MULTIPLY", 332 },
    { "KP_SUBTRACT", 333 },
    { "KP_ADD", 334 },
    { "KP_ENTER", 335 },
    { "KP_EQUAL", 336 },
    { "LEFT_SHIFT", 340 },
    { "LEFT_CONTROL", 341 },
    { "LEFT_ALT", 342 },
    { "LEFT_SUPER", 343 },
    { "RIGHT_SHIFT", 344 },
    { "RIGHT_CONTROL", 345 },
    { "RIGHT_ALT", 346 },
    { "RIGHT_SUPER", 347 },
    { "MENU", 348 },
};

@implementation A2KeyCodeMap

+ (NSInteger)keyCodeFromName:(NSString *)name {
    NSString *raw = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (raw.length == 0) return 0;

    NSString *key = raw.uppercaseString;
    if ([key hasPrefix:@"GLFW_"]) key = [key substringFromIndex:5];

    // 鼠标键：Air2 内部用负数表示（-1 左 / -2 右 / -3 中），其余键 Air2 暂不支持。
    if ([key hasPrefix:@"MOUSE_BUTTON_"]) {
        NSString *button = [key substringFromIndex:@"MOUSE_BUTTON_".length];
        if ([button isEqualToString:@"LEFT"] || [button isEqualToString:@"1"]) return -1;
        if ([button isEqualToString:@"RIGHT"] || [button isEqualToString:@"2"]) return -2;
        if ([button isEqualToString:@"MIDDLE"] || [button isEqualToString:@"3"]) return -3;
        return 0;
    }
    // ZL2 的常量名是 GLFW_KEY_W，去掉 GLFW_ 后还剩 KEY_；
    // 表里的名字不带前缀（"W"），也要接受裸名与数字。
    if ([key hasPrefix:@"KEY_"]) key = [key substringFromIndex:4];

    // 纯数字（部分老布局把键码直接写成字符串）
    BOOL digits = YES;
    for (NSUInteger i = 0; i < key.length; i++) {
        unichar c = [key characterAtIndex:i];
        if (c < '0' || c > '9') { digits = NO; break; }
    }
    if (digits) {
        // "0" 既可能是「未绑定」的占位，也可能是 GLFW_KEY_0；表里键名用 "0" 指数字 0，
        // 这里按显示名处理，避免 ZL2 导出的 "0" 变成未绑定。
        if (key.length == 1 && [key isEqualToString:@"0"]) return 48;
        return key.integerValue;
    }

    const char *utf8 = key.UTF8String;
    for (size_t i = 0; i < sizeof(kA2GlfwNames) / sizeof(kA2GlfwNames[0]); i++) {
        if (strcmp(kA2GlfwNames[i].name, utf8) == 0) return kA2GlfwNames[i].code;
    }
    return 0;
}

+ (NSInteger)keyCodeFromFCLKeycode:(NSInteger)evdevCode {
    for (size_t i = 0; i < sizeof(kA2EvdevToGlfw) / sizeof(kA2EvdevToGlfw[0]); i++) {
        if (kA2EvdevToGlfw[i].from == (int)evdevCode) return kA2EvdevToGlfw[i].to;
    }
    return 0;
}

+ (NSInteger)fclKeycodeFromKeyCode:(NSInteger)keyCode {
    for (size_t i = 0; i < sizeof(kA2EvdevToGlfw) / sizeof(kA2EvdevToGlfw[0]); i++) {
        if (kA2EvdevToGlfw[i].to == (int)keyCode) return kA2EvdevToGlfw[i].from;
    }
    return 0;
}

@end
