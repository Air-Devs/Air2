// ============================================================================
//  Natives/Input/A2InputTypes.m
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 词汇表实现
// ----------------------------------------------------------------------------
//  本文件只有两件事：① 枚举 → 名字（日志/测试用）；② GLFW 键盘空间的完整目录。
//
//  ★为什么键位目录要手写而不是遍历 0..348★
//    GLFW 的键码是稀疏的（33..96 是 ASCII，161/162 是世界键，256 起是功能键，
//    中间大量空号）。遍历会造出一堆「不存在的键」，映射编辑器里就会出现
//    用户能选、MC 却永远收不到的空洞选项 —— 那比少列几个键更难查。
// ============================================================================
#import "A2InputTypes.h"

NSString *const A2InputErrorDomain = @"dev.airdevs.air2.input";

NSString *A2InputSourceKindName(A2InputSourceKind kind) {
    switch (kind) {
        case A2InputSourceKindVirtualButton: return @"virtual-button";
        case A2InputSourceKindKeyboard:      return @"keyboard";
        case A2InputSourceKindGamepad:       return @"gamepad";
    }
    return @"unknown";
}

NSString *A2InputTargetKindName(A2InputTargetKind kind) {
    switch (kind) {
        case A2InputTargetKindKey:           return @"key";
        case A2InputTargetKindGamepadButton: return @"gamepad-button";
    }
    return @"unknown";
}

NSString *A2InputActionName(A2InputAction action) {
    return (action == A2InputActionPress) ? @"press" : @"release";
}

NSString *A2GamepadButtonName(A2GamepadButton button) {
    switch (button) {
        case A2GamepadButtonA:           return @"A";
        case A2GamepadButtonB:           return @"B";
        case A2GamepadButtonX:           return @"X";
        case A2GamepadButtonY:           return @"Y";
        case A2GamepadButtonLeftBumper:  return @"LB";
        case A2GamepadButtonRightBumper: return @"RB";
        case A2GamepadButtonBack:        return @"BACK";
        case A2GamepadButtonStart:       return @"START";
        case A2GamepadButtonGuide:       return @"GUIDE";
        case A2GamepadButtonLeftThumb:   return @"LS";
        case A2GamepadButtonRightThumb:  return @"RS";
        case A2GamepadButtonDPadUp:      return @"DPAD_UP";
        case A2GamepadButtonDPadRight:   return @"DPAD_RIGHT";
        case A2GamepadButtonDPadDown:    return @"DPAD_DOWN";
        case A2GamepadButtonDPadLeft:    return @"DPAD_LEFT";
    }
    return [NSString stringWithFormat:@"GAMEPAD_%ld", (long) button];
}

#pragma mark - 稳定键

NSString *A2InputTriggerKey(A2InputTrigger trigger) {
    if (trigger.identifier.length > 0) {
        return [NSString stringWithFormat:@"%ld|id:%@",
                (long) trigger.sourceKind, trigger.identifier];
    }
    return [NSString stringWithFormat:@"%ld|code:%d", (long) trigger.sourceKind, trigger.code];
}

NSString *A2InputEventTargetKey(A2InputEvent event) {
    return [NSString stringWithFormat:@"%ld|code:%d", (long) event.targetKind, event.code];
}

#pragma mark - 键盘空间目录

/// GLFW 键码 → 显示名。只建一次：目录是常量数据，运行时反复建字典纯属浪费。
static NSDictionary<NSNumber *, NSString *> *A2KeyNameTable(void) {
    static NSDictionary<NSNumber *, NSString *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary<NSNumber *, NSString *> *m = [NSMutableDictionary dictionaryWithCapacity:140];

        // ① 可打印 ASCII：GLFW_KEY_SPACE(32) … GLFW_KEY_GRAVE_ACCENT(96)。
        //    这一段与 USB HID 的 0x04..0x38 一一对应，字母/数字/标点全在这里。
        for (int c = 32; c <= 96; c++) {
            if (c == 32) {
                m[@(c)] = @"SPACE";
            } else {
                m[@(c)] = [NSString stringWithFormat:@"%c", (char) c];
            }
        }

        // ② 世界键（非 US 布局的额外键）
        m[@(161)] = @"WORLD_1";
        m[@(162)] = @"WORLD_2";

        // ③ 编辑/导航键
        m[@(256)] = @"ESCAPE";
        m[@(257)] = @"ENTER";
        m[@(258)] = @"TAB";
        m[@(259)] = @"BACKSPACE";
        m[@(260)] = @"INSERT";
        m[@(261)] = @"DELETE";
        m[@(262)] = @"RIGHT";
        m[@(263)] = @"LEFT";
        m[@(264)] = @"DOWN";
        m[@(265)] = @"UP";
        m[@(266)] = @"PAGE_UP";
        m[@(267)] = @"PAGE_DOWN";
        m[@(268)] = @"HOME";
        m[@(269)] = @"END";

        // ④ 锁/打印/暂停
        m[@(280)] = @"CAPS_LOCK";
        m[@(281)] = @"SCROLL_LOCK";
        m[@(282)] = @"NUM_LOCK";
        m[@(283)] = @"PRINT_SCREEN";
        m[@(284)] = @"PAUSE";

        // ⑤ F1..F25（GLFW 官方定义到 F25；外接键盘的 F13+ 在 iOS 上少见但要能映射）
        for (int i = 0; i < 25; i++) {
            m[@(290 + i)] = [NSString stringWithFormat:@"F%d", i + 1];
        }

        // ⑥ 小键盘（GLFW 320..336 连续）
        for (int i = 0; i <= 9; i++) {
            m[@(320 + i)] = [NSString stringWithFormat:@"KP_%d", i];
        }
        m[@(330)] = @"KP_DECIMAL";
        m[@(331)] = @"KP_DIVIDE";
        m[@(332)] = @"KP_MULTIPLY";
        m[@(333)] = @"KP_SUBTRACT";
        m[@(334)] = @"KP_ADD";
        m[@(335)] = @"KP_ENTER";
        m[@(336)] = @"KP_EQUAL";

        // ⑦ 修饰键与菜单键（可映射：例如把虚拟按钮绑到 SHIFT 做「潜行」）
        m[@(340)] = @"LEFT_SHIFT";
        m[@(341)] = @"LEFT_CONTROL";
        m[@(342)] = @"LEFT_ALT";
        m[@(343)] = @"LEFT_SUPER";
        m[@(344)] = @"RIGHT_SHIFT";
        m[@(345)] = @"RIGHT_CONTROL";
        m[@(346)] = @"RIGHT_ALT";
        m[@(347)] = @"RIGHT_SUPER";
        m[@(348)] = @"MENU";

        table = [m copy];
    });
    return table;
}

NSArray<NSNumber *> *A2InputAllKeyCodes(void) {
    static NSArray<NSNumber *> *codes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        codes = [[A2KeyNameTable() allKeys] sortedArrayUsingSelector:@selector(compare:)];
    });
    return codes;
}

NSString *A2InputKeyDisplayName(int glfwKey) {
    NSString *name = A2KeyNameTable()[@(glfwKey)];
    if (name != nil) {
        return name;
    }
    return [NSString stringWithFormat:@"KEY_%d", glfwKey];
}

int A2InputKeyCodeForDisplayName(NSString *name) {
    if (name.length == 0) {
        return -1;
    }
    static NSDictionary<NSString *, NSNumber *> *reverse = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary<NSString *, NSNumber *> *m = [NSMutableDictionary dictionary];
        [A2KeyNameTable() enumerateKeysAndObjectsUsingBlock:^(NSNumber *code, NSString *label, BOOL *stop) {
            (void) stop;
            // 名字大小写不敏感：映射表可能被外部工具写成小写（FCL/ZL2 导入就是这样）。
            m[label.lowercaseString] = code;
        }];
        reverse = [m copy];
    });
    // ★不用 `?: -1`★：键码 0 在 GLFW 里不是合法落点，但「靠 0 是假值」来判缺失
    // 是一颗定时炸弹 —— 哪天表里真出现 0，查名字就会静默返回 -1。
    NSNumber *code = reverse[name.lowercaseString];
    return (code != nil) ? code.intValue : -1;
}
