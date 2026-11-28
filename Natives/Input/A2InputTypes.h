// ============================================================================
//  Natives/Input/A2InputTypes.h
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 词汇表（唯一一份）
// ----------------------------------------------------------------------------
//  要解决的问题（用户 2026-11-28 口述）：
//    「给目前所有的 MC 内核加一套输入方式：虚拟按钮 / 键盘 / 手柄，
//      都能映射到键盘所有按键或手柄任何按键」。
//
//  为什么先有词汇表：三种源（虚拟按钮 / 键盘 / 手柄）与两个目标空间
//  （键盘按键 / 手柄按键）如果各自定义一套编号，映射层就变成 N×M 个翻译函数，
//  这正是「石山」的起点。所以本文件只做一件事：把「谁产生什么」和
//  「能映射到什么」定义成两组类型，其余文件一律复用，不许再造同义词。
//
//  ★两个空间必须分开★
//    · 键盘空间 = GLFW 键码（GLFW_KEY_*，MC 的按键回调认这套编号）
//    · 手柄空间 = A2GamepadButton（编号刻意沿用 GLFW_GAMEPAD_BUTTON_*）
//    两者数值会撞（都有 0/1/2），若共用一个 int 就会「手柄 A 变成键盘 A」，
//    而且这种串号在真机上只表现为「按了没反应/按错键」，极难查。
//    ⇒ 所以触发与事件里都带 targetKind / sourceKind，任何一层都不许省。
//
//  ★为什么触发里带 identifier★
//    虚拟按钮的触发是「哪个控件」（布局里的 id，如 "attack"、自定义控件 id），
//    不是键码：一个控件可以被用户改绑到任意键，用键码当触发就把「改绑」变成
//    「换一个控件」。键盘/手柄没有这个问题（它们的触发天然是编号）⇒ identifier 可为 nil。
// ============================================================================
#ifndef A2_INPUT_TYPES_H
#define A2_INPUT_TYPES_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 错误域

/// [INPUT-MAP-1] 输入层错误域。未实现的源（虚拟按钮 / 手柄）用 CodeNotImplemented
/// 如实报错，★不允许「start 返回 YES 但什么都不做」★ —— 那会让上层以为手柄能用了。
extern NSString *const A2InputErrorDomain;

typedef NS_ENUM(NSInteger, A2InputErrorCode) {
    /// 该源在本迭代只有接口、没有实现（[INPUT-MAP-2] 补）。
    A2InputErrorCodeNotImplemented = 1,
    /// 宿主环境不满足（例如手柄源在没有 GameController 框架回调的情况下被启动）。
    A2InputErrorCodeUnavailable = 2,
};

#pragma mark - 三种输入源

/// 输入源种类。三种源共用一套接口（A2InputSource），这里只是分类标签。
typedef NS_ENUM(NSInteger, A2InputSourceKind) {
    /// 屏幕上的虚拟按钮（A2GameControlsView 的控件；布局 id 即触发标识）。
    A2InputSourceKindVirtualButton = 0,
    /// 外接/软键盘（触发 = GLFW 键码）。
    A2InputSourceKindKeyboard = 1,
    /// 手柄（触发 = A2GamepadButton）。
    A2InputSourceKindGamepad = 2,
};

/// 日志/诊断用名字。★只用于日志与测试断言，不参与任何逻辑分支★。
NSString *A2InputSourceKindName(A2InputSourceKind kind);

#pragma mark - 两个目标空间

/// 目标空间：映射的落点在哪套编号里。
typedef NS_ENUM(NSInteger, A2InputTargetKind) {
    /// 键盘按键：code = GLFW 键码（GLFW_KEY_*）。
    A2InputTargetKindKey = 0,
    /// 手柄按键：code = A2GamepadButton。
    A2InputTargetKindGamepadButton = 1,
};

NSString *A2InputTargetKindName(A2InputTargetKind kind);

/// 按下/抬起。数值刻意与 GLFW 一致（1 = PRESS，0 = RELEASE），
/// 这样汇到 GLFW 总线时不需要再翻译一次。
typedef NS_ENUM(NSInteger, A2InputAction) {
    A2InputActionRelease = 0,
    A2InputActionPress   = 1,
};

NSString *A2InputActionName(A2InputAction action);

/// 手柄按键。★编号与 GLFW_GAMEPAD_BUTTON_* 逐值相同★：
/// 将来若 MC 内核直接吃手柄，汇出时不用查表；现在的映射层也只把它当编号用。
typedef NS_ENUM(NSInteger, A2GamepadButton) {
    A2GamepadButtonA          = 0,
    A2GamepadButtonB          = 1,
    A2GamepadButtonX          = 2,
    A2GamepadButtonY          = 3,
    A2GamepadButtonLeftBumper = 4,
    A2GamepadButtonRightBumper = 5,
    A2GamepadButtonBack       = 6,
    A2GamepadButtonStart      = 7,
    A2GamepadButtonGuide      = 8,
    A2GamepadButtonLeftThumb  = 9,
    A2GamepadButtonRightThumb = 10,
    A2GamepadButtonDPadUp     = 11,
    A2GamepadButtonDPadRight  = 12,
    A2GamepadButtonDPadDown   = 13,
    A2GamepadButtonDPadLeft   = 14,
};

/// 手柄按键总数（枚举里不写 COUNT：它会进 for 循环边界，写死一个哨兵更清楚）。
#define A2GamepadButtonCount 15

NSString *A2GamepadButtonName(A2GamepadButton button);

#pragma mark - 触发（源 → 映射层）

/// 一次「源侧动作」：谁、按了什么、带了什么修饰键。
/// ★值类型 + 栈上传递★：键事件是高频路径（真机连按时每秒几十次），
/// 不该为每次按下分配一个对象；identifier 的生命周期由源保证（调用期间有效）。
typedef struct {
    A2InputSourceKind sourceKind;
    /// 键盘：GLFW 键码；手柄：A2GamepadButton；虚拟按钮：0（用 identifier）。
    int code;
    /// 虚拟按钮的控件 id；键盘/手柄为 nil。
    __unsafe_unretained NSString *_Nullable identifier;
    /// 键盘修饰位（GLFW mods：SHIFT=1 / CONTROL=2 / ALT=4 / SUPER=8 / CAPS=16）。
    int mods;
    /// 按下还是抬起。★源必须如实给出★：映射层靠它维护「哪些落点还按着」，
    /// 少了它就无法在退后台/断连时把卡住的键抬起来。
    A2InputAction action;
    /// 键盘扫描码（USB HID usage）。只有键盘源会填，其余为 0。
    /// ★为什么留着它★：GLFW 的按键回调同时给 key 与 scancode，部分 Mod 按 scancode
    /// 认键（国际布局）。丢了它，映射层虽然还能用，但 Mod 的按键识别会退化 ——
    /// 这种退化不会报错，只会在装了某个 Mod 之后才被发现。
    int scancode;
} A2InputTrigger;

/// 构造触发。★不给「部分初始化」的机会★：字段一起给，避免漏填 sourceKind
/// 导致「手柄事件被当成键盘事件」这种只有真机才能发现的串号。
static inline A2InputTrigger A2InputTriggerMake(A2InputSourceKind sourceKind,
                                               int code,
                                               NSString *_Nullable identifier,
                                               A2InputAction action,
                                               int mods) {
    A2InputTrigger trigger;
    trigger.sourceKind = sourceKind;
    trigger.code = code;
    trigger.identifier = identifier;
    trigger.mods = mods;
    trigger.action = action;
    trigger.scancode = 0;
    return trigger;
}

#pragma mark - 事件（映射层 → 内核汇）

/// 一次「目标侧事件」：映射解算完的落点。
typedef struct {
    A2InputTargetKind targetKind;
    /// 键盘：GLFW 键码；手柄：A2GamepadButton。
    int code;
    A2InputAction action;
    int mods;
    /// 轴值（[INPUT-MAP-3] 手柄摇杆用；按键事件恒为 0，不用 1 表示按下 ——
    /// 按下与否看 action，混用会让「value != 0 即按下」的写法在松开时出错）。
    float value;
    /// 键盘扫描码（透传触发里的 scancode；非键盘事件为 0）。
    int scancode;
} A2InputEvent;

static inline A2InputEvent A2InputEventMake(A2InputTargetKind targetKind,
                                           int code,
                                           A2InputAction action,
                                           int mods) {
    A2InputEvent event;
    event.targetKind = targetKind;
    event.code = code;
    event.action = action;
    event.mods = mods;
    event.value = 0.0f;
    event.scancode = 0;
    return event;
}

/// 触发的稳定字符串键（绑定表查表、映射层「按下集合」跟踪都用它）。
/// ★唯一实现★：两边各拼一套串是「改绑后查不到旧绑定」这类灵异问题的温床。
/// 形如 `keyboard|code:65` / `virtual-button|id:attack` / `gamepad|code:0`。
NSString *A2InputTriggerKey(A2InputTrigger trigger);

/// 目标事件的稳定字符串键（映射层按它做「多源同落点」的引用计数）。
/// 形如 `key|code:32` / `gamepad-button|code:0`。
NSString *A2InputEventTargetKey(A2InputEvent event);

#pragma mark - 键盘空间（GLFW 键码）目录

/// 键盘空间的**全部**可映射键（GLFW 键码），按数值升序。
/// 用途：① 映射编辑器列出「键盘所有按键」；② 单测断言目标空间没有漏键；
///      ③ 日志里把键码翻成人能读的名字。
/// ★只含 GLFW 定义的键码★：GLFW_KEY_UNKNOWN(-1) 不在表内（它不是可映射的落点）。
NSArray<NSNumber *> *A2InputAllKeyCodes(void);

/// 键码 → 显示名（"A" / "F13" / "KP_ENTER" …）。未知键码返回 "KEY_<code>"，
/// ★不返回 nil★：日志与 UI 都不该因为一个越界键码而丢整行。
NSString *A2InputKeyDisplayName(int glfwKey);

/// 显示名 → 键码（大小写不敏感）。未知名字返回 -1（GLFW_KEY_UNKNOWN）。
/// 与 A2InputKeyDisplayName 互为逆运算，单测按往返断言。
int A2InputKeyCodeForDisplayName(NSString *name);

NS_ASSUME_NONNULL_END

#endif /* A2_INPUT_TYPES_H */
