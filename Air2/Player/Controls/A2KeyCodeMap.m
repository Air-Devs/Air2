//
//  A2KeyCodeMap.m
//  Air2
//
//  对照源码：
//    fcl/FCL/src/main/java/com/mio/controlconverter/CcConstants.kt
//      GLFW_TO_FCL / FCL_MOUSE / FCL_SCROLL_REVERSE
//    Linux input-event-codes.h（FCL 用的那套）
//

#import "A2KeyCodeMap.h"
#import "A2ControlInput.h"

const NSInteger A2FCLMouseLeft = 1000;
const NSInteger A2FCLMouseMiddle = 1001;
const NSInteger A2FCLMouseRight = 1002;
const NSInteger A2FCLScrollUp = 1003;
const NSInteger A2FCLScrollDown = 1004;

/// (GLFW 键码, FCL Linux 键码)
typedef struct {
    NSInteger glfw;
    NSInteger fcl;
} A2CodePair;

static const A2CodePair kPairs[] = {
    // ---- 字母 ----
    {65, 30},  // A
    {66, 48},  // B
    {67, 46},  // C
    {68, 32},  // D
    {69, 18},  // E
    {70, 33},  // F
    {71, 34},  // G
    {72, 35},  // H
    {73, 23},  // I
    {74, 36},  // J
    {75, 37},  // K
    {76, 38},  // L
    {77, 50},  // M
    {78, 49},  // N
    {79, 24},  // O
    {80, 25},  // P
    {81, 16},  // Q
    {82, 19},  // R
    {83, 31},  // S
    {84, 20},  // T
    {85, 22},  // U
    {86, 47},  // V
    {87, 17},  // W
    {88, 45},  // X
    {89, 21},  // Y
    {90, 44},  // Z

    // ---- 数字 ----
    {48, 11},  // 0
    {49, 2},   // 1
    {50, 3},   // 2
    {51, 4},   // 3
    {52, 5},   // 4
    {53, 6},   // 5
    {54, 7},   // 6
    {55, 8},   // 7
    {56, 9},   // 8
    {57, 10},  // 9

    // ---- 标点 ----
    {32, 57},  // space
    {39, 40},  // apostrophe
    {44, 51},  // comma
    {45, 12},  // minus
    {46, 52},  // period
    {47, 53},  // slash
    {59, 39},  // semicolon
    {61, 13},  // equal
    {91, 26},  // [
    {92, 43},  // backslash
    {93, 27},  // ]
    {96, 41},  // grave

    // ---- 控制/导航 ----
    {256, 1},   // escape
    {257, 28},  // enter
    {258, 15},  // tab
    {259, 14},  // backspace
    {260, 110}, // insert
    {261, 111}, // delete
    {262, 106}, // right
    {263, 105}, // left
    {264, 108}, // down
    {265, 103}, // up
    {266, 104}, // page up
    {267, 109}, // page down
    {268, 102}, // home
    {269, 107}, // end
    {280, 58},  // caps lock
    {281, 70},  // scroll lock
    {282, 69},  // num lock
    {283, 99},  // print screen
    {284, 119}, // pause

    // ---- 功能键 ----
    {290, 59},  {291, 60},  {292, 61},  {293, 62},
    {294, 63},  {295, 64},  {296, 65},  {297, 66},
    {298, 67},  {299, 68},  {300, 87},  {301, 88},
    {302, 183}, {303, 184}, {304, 185}, {305, 186},
    {306, 187}, {307, 188}, {308, 189}, {309, 190},
    {310, 191}, {311, 192}, {312, 193}, {313, 194},

    // ---- 小键盘 ----
    {320, 82},  // kp_0
    {321, 79},  // kp_1
    {322, 80},  // kp_2
    {323, 81},  // kp_3
    {324, 75},  // kp_4
    {325, 76},  // kp_5
    {326, 77},  // kp_6
    {327, 71},  // kp_7
    {328, 72},  // kp_8
    {329, 73},  // kp_9
    {330, 83},  // kp_decimal
    {331, 98},  // kp_divide
    {332, 55},  // kp_multiply
    {333, 74},  // kp_subtract
    {334, 78},  // kp_add
    {335, 96},  // kp_enter
    {336, 117}, // kp_equal

    // ---- 修饰键 ----
    {340, 42},  // left shift
    {341, 29},  // left control
    {342, 56},  // left alt
    {343, 125}, // left super
    {344, 54},  // right shift
    {345, 97},  // right control
    {346, 100}, // right alt
    {347, 126}, // right super
};

static const size_t kPairCount = sizeof(kPairs) / sizeof(kPairs[0]);

@implementation A2KeyCodeMap

+ (NSInteger)fclCodeForGLFWCode:(NSInteger)glfwCode {
    // 鼠标（GLFW 0~7 → FCL 1000/1002/1001/…）
    if (glfwCode >= 0 && glfwCode <= 7) {
        switch (glfwCode) {
            case 0: return A2FCLMouseLeft;
            case 1: return A2FCLMouseRight;
            case 2: return A2FCLMouseMiddle;
            default: return -1;   // FCL 没有 4~8 号鼠标键的等价物
        }
    }
    for (size_t i = 0; i < kPairCount; i++) {
        if (kPairs[i].glfw == glfwCode) return kPairs[i].fcl;
    }
    return -1;
}

+ (NSInteger)glfwCodeForFCLCode:(NSInteger)fclCode {
    if (fclCode == A2FCLMouseLeft) return 0;
    if (fclCode == A2FCLMouseRight) return 1;
    if (fclCode == A2FCLMouseMiddle) return 2;
    for (size_t i = 0; i < kPairCount; i++) {
        if (kPairs[i].fcl == fclCode) return kPairs[i].glfw;
    }
    return -1;
}

+ (BOOL)isFCLPointerCode:(NSInteger)fclCode {
    return fclCode >= 1000;
}

+ (NSInteger)scrollDirectionForFCLCode:(NSInteger)fclCode {
    if (fclCode == A2FCLScrollUp) return 1;
    if (fclCode == A2FCLScrollDown) return -1;
    return 0;
}

+ (NSInteger)glfwCodeForName:(NSString *)name {
    if (![name isKindOfClass:NSString.class] || name.length == 0) return -1;

    // 鼠标名
    if ([name hasPrefix:@"GLFW_MOUSE_BUTTON_"]) {
        if ([name isEqualToString:@"GLFW_MOUSE_BUTTON_LEFT"] ||
            [name isEqualToString:@"GLFW_MOUSE_BUTTON_1"]) return 0;
        if ([name isEqualToString:@"GLFW_MOUSE_BUTTON_RIGHT"] ||
            [name isEqualToString:@"GLFW_MOUSE_BUTTON_2"]) return 1;
        if ([name isEqualToString:@"GLFW_MOUSE_BUTTON_MIDDLE"] ||
            [name isEqualToString:@"GLFW_MOUSE_BUTTON_3"]) return 2;
        NSInteger n = [name substringFromIndex:@"GLFW_MOUSE_BUTTON_".length].integerValue;
        if (n >= 4 && n <= 8) return n - 1;
        return -1;
    }

    NSString *code = [A2ControlEventKey keyCodeForGLFWName:name];
    return code ? code.integerValue : -1;
}

+ (NSString *)nameForGLFWCode:(NSInteger)code {
    switch (code) {
        case 0: return @"GLFW_MOUSE_BUTTON_LEFT";
        case 1: return @"GLFW_MOUSE_BUTTON_RIGHT";
        case 2: return @"GLFW_MOUSE_BUTTON_MIDDLE";
        case 3: return @"GLFW_MOUSE_BUTTON_4";
        case 4: return @"GLFW_MOUSE_BUTTON_5";
        case 5: return @"GLFW_MOUSE_BUTTON_6";
        case 6: return @"GLFW_MOUSE_BUTTON_7";
        case 7: return @"GLFW_MOUSE_BUTTON_8";
        default: return [A2ControlEventKey glfwNameForKeyCode:code];
    }
}

+ (NSInteger)fclCodeForEventKey:(NSString *)eventKey {
    NSInteger code = -1;
    A2ControlInputKind kind = [A2ControlEventKey kindForRawKey:eventKey outCode:&code];

    switch (kind) {
        case A2ControlInputKindKey:
            return [self fclCodeForGLFWCode:code];

        case A2ControlInputKindMouseButton:
            return [self fclCodeForGLFWCode:code];

        case A2ControlInputKindScroll: {
            NSInteger dir = [A2ControlEventKey scrollDirectionForRawKey:eventKey];
            return dir > 0 ? A2FCLScrollUp : (dir < 0 ? A2FCLScrollDown : -1);
        }

        default:
            return -1;
    }
}

+ (NSDictionary<NSString *, NSString *> *)zlEventForFCLCode:(NSInteger)fclCode {
    if (fclCode == A2FCLScrollUp) {
        return @{@"type": @"launcher_event", @"key": @"launcher.event.scroll_up.single"};
    }
    if (fclCode == A2FCLScrollDown) {
        return @{@"type": @"launcher_event", @"key": @"launcher.event.scroll_down.single"};
    }

    NSInteger glfw = [self glfwCodeForFCLCode:fclCode];
    if (glfw < 0) return nil;

    NSString *name = [self nameForGLFWCode:glfw];
    if (name.length == 0) return nil;

    return @{@"type": @"key", @"key": name};
}

+ (NSInteger)fclCodeForZLEventType:(NSString *)type key:(NSString *)key {
    if (![key isKindOfClass:NSString.class] || key.length == 0) return -1;

    if ([type isEqualToString:@"launcher_event"]) {
        if ([A2ControlEventKey isSingleScrollKey:key] ||
            [key hasPrefix:@"launcher.event.scroll_"]) {
            return [self fclCodeForEventKey:key];
        }
        // 其它启动器事件在 FCL 里没有一一对应的「键码」，由调用方按事件语义处理
        return -1;
    }

    return [self fclCodeForEventKey:key];
}

@end
