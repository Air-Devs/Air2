#import "KeyboardInput.h"
#import "../utils.h"

#include "../glfw_keycodes.h"

@implementation KeyboardInput

int keycodeTable[UIKeyboardHIDUsageKeyboardRightGUI+1];

+ (void)initKeycodeTable {
    for (int i = UIKeyboardHIDUsageKeyboardA; i <= UIKeyboardHIDUsageKeyboardZ; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeyboardA + GLFW_KEY_A;
    }

    // 0-9 keys
    keycodeTable[UIKeyboardHIDUsageKeyboard0] = GLFW_KEY_0;
    for (int i = UIKeyboardHIDUsageKeyboard1; i <= UIKeyboardHIDUsageKeyboard9; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeyboard1 + GLFW_KEY_1;
    }

    // Arrow keys
    keycodeTable[UIKeyboardHIDUsageKeyboardUpArrow] = GLFW_KEY_DPAD_UP;
    keycodeTable[UIKeyboardHIDUsageKeyboardDownArrow] = GLFW_KEY_DPAD_DOWN;
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftArrow] = GLFW_KEY_DPAD_LEFT;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightArrow] = GLFW_KEY_DPAD_RIGHT;

    keycodeTable[UIKeyboardHIDUsageKeyboardComma] = GLFW_KEY_COMMA;
    keycodeTable[UIKeyboardHIDUsageKeyboardPeriod] = GLFW_KEY_PERIOD;

    // Alt keys
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftAlt] = GLFW_KEY_LEFT_ALT;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightAlt] = GLFW_KEY_RIGHT_ALT;

    // Control keys
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftControl] = GLFW_KEY_LEFT_CONTROL;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightControl] = GLFW_KEY_RIGHT_CONTROL;

    // Shift keys
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftShift] = GLFW_KEY_LEFT_SHIFT;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightShift] = GLFW_KEY_RIGHT_SHIFT;

    // Bracket keys
    keycodeTable[UIKeyboardHIDUsageKeyboardOpenBracket] = GLFW_KEY_LEFT_BRACKET;
    keycodeTable[UIKeyboardHIDUsageKeyboardCloseBracket] = GLFW_KEY_RIGHT_BRACKET;

    // Slash keys
    keycodeTable[UIKeyboardHIDUsageKeyboardSlash] = GLFW_KEY_SLASH;
    keycodeTable[UIKeyboardHIDUsageKeyboardBackslash] = GLFW_KEY_BACKSLASH;

    // Page keys
    keycodeTable[UIKeyboardHIDUsageKeyboardPageUp] = GLFW_KEY_PAGE_UP;
    keycodeTable[UIKeyboardHIDUsageKeyboardPageDown] = GLFW_KEY_PAGE_DOWN;

    // Some other keys
    keycodeTable[UIKeyboardHIDUsageKeyboardHome] = GLFW_KEY_HOME;
    keycodeTable[UIKeyboardHIDUsageKeyboardEscape] = GLFW_KEY_ESCAPE;
    keycodeTable[UIKeyboardHIDUsageKeyboardTab] = GLFW_KEY_TAB;
    keycodeTable[UIKeyboardHIDUsageKeyboardReturnOrEnter] = GLFW_KEY_ENTER;
    keycodeTable[UIKeyboardHIDUsageKeyboardSpacebar] = GLFW_KEY_SPACE;
    keycodeTable[UIKeyboardHIDUsageKeyboardDeleteOrBackspace] = GLFW_KEY_BACKSPACE;
    keycodeTable[UIKeyboardHIDUsageKeyboardDeleteForward] = GLFW_KEY_DELETE;
    keycodeTable[UIKeyboardHIDUsageKeyboardGraveAccentAndTilde] = GLFW_KEY_GRAVE_ACCENT;

    keycodeTable[UIKeyboardHIDUsageKeyboardHyphen] = GLFW_KEY_MINUS;
    keycodeTable[UIKeyboardHIDUsageKeyboardEqualSign] = GLFW_KEY_EQUAL;
    keycodeTable[UIKeyboardHIDUsageKeyboardSemicolon] = GLFW_KEY_SEMICOLON;

    // Lock keys
    keycodeTable[UIKeyboardHIDUsageKeyboardCapsLock] = GLFW_KEY_CAPS_LOCK;
    keycodeTable[UIKeyboardHIDUsageKeypadNumLock] = GLFW_KEY_NUM_LOCK;
    keycodeTable[UIKeyboardHIDUsageKeyboardScrollLock] = GLFW_KEY_SCROLL_LOCK;

    // Numpad keys
    keycodeTable[UIKeyboardHIDUsageKeypadSlash] = GLFW_KEY_NUMPAD_DIVIDE;
    keycodeTable[UIKeyboardHIDUsageKeypadAsterisk] = GLFW_KEY_NUMPAD_MULTIPLY;
    keycodeTable[UIKeyboardHIDUsageKeypadHyphen] = GLFW_KEY_NUMPAD_SUBTRACT;
    keycodeTable[UIKeyboardHIDUsageKeypadPlus] = GLFW_KEY_NUMPAD_ADD;
    keycodeTable[UIKeyboardHIDUsageKeypadEnter] = GLFW_KEY_NUMPAD_ENTER;
    keycodeTable[UIKeyboardHIDUsageKeypadEqualSign] = GLFW_KEY_NUMPAD_EQUAL;
    keycodeTable[UIKeyboardHIDUsageKeypad0] = GLFW_KEY_NUMPAD_0;
    for (int i = UIKeyboardHIDUsageKeypad1; i <= UIKeyboardHIDUsageKeypad9; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeypad1 + GLFW_KEY_NUMPAD_1;
    }

    // Function keys
    for (int i = UIKeyboardHIDUsageKeyboardF1; i <= UIKeyboardHIDUsageKeyboardF12; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeyboardF1 + GLFW_KEY_F1;
    }
}

+ (BOOL)sendKeyEvent:(UIKey *)key down:(BOOL)isDown {
    char modifiers = 0;

    // convert UIKey's modifiers to GLFW
    if (key.modifierFlags & UIKeyModifierAlphaShift) {
        modifiers |= GLFW_MOD_CAPS_LOCK;
    }
    if (key.modifierFlags & UIKeyModifierShift) {
        modifiers |= GLFW_MOD_SHIFT;
    }
    if (key.modifierFlags & UIKeyModifierAlternate) {
        modifiers |= GLFW_MOD_ALT;
    }
    if (key.modifierFlags & UIKeyModifierControl) {
        modifiers |= GLFW_MOD_CONTROL;
    }
    if (key.modifierFlags & UIKeyModifierCommand) {
        modifiers |= GLFW_MOD_SUPER;
    }

    // send the keycode
    NSUInteger hidUsage = (NSUInteger)key.keyCode;
    int keycode = hidUsage <= UIKeyboardHIDUsageKeyboardRightGUI
        ? keycodeTable[hidUsage]
        : 0;
    if (keycode != 0) {
        // issue #27 修复（参照 FCL commit 08c0716）：
        // MC 1.21.9+ 不再仅依赖 key 回调中的 mods 参数，而是通过
        // InputConstants.isKeyDown() 查询 modifier 状态，该状态由 MC 自己
        // 维护在独立缓存中，必须显式 setModifiers 才能更新。
        //
        // 关键修复 1：release 事件中 iOS 的 modifierFlags 仍包含被释放的键，
        // 导致 mods 与 action 自相矛盾。这里对 modifier 键本身做修正：
        // 释放时从 mods 中移除该键对应的位，让事件语义自洽。
        if (!isDown) {
            switch (keycode) {
                case GLFW_KEY_LEFT_SHIFT:
                case GLFW_KEY_RIGHT_SHIFT:
                    modifiers &= ~GLFW_MOD_SHIFT;
                    break;
                case GLFW_KEY_LEFT_CONTROL:
                case GLFW_KEY_RIGHT_CONTROL:
                    modifiers &= ~GLFW_MOD_CONTROL;
                    break;
                case GLFW_KEY_LEFT_ALT:
                case GLFW_KEY_RIGHT_ALT:
                    modifiers &= ~GLFW_MOD_ALT;
                    break;
                case GLFW_KEY_LEFT_SUPER:
                case GLFW_KEY_RIGHT_SUPER:
                    modifiers &= ~GLFW_MOD_SUPER;
                    break;
                case GLFW_KEY_CAPS_LOCK:
                    modifiers &= ~GLFW_MOD_CAPS_LOCK;
                    break;
                default:
                    break;
            }
        }

        CallbackBridge_nativeSendKey(keycode, 0 /* scancode */, isDown, modifiers);

        // 关键修复 2：显式同步 MC 1.21.9+ 内部的 modifier 缓存。
        // 即便某些版本 MC 不使用 setModifiers，调用也是安全的（旧版本无此方法
        // 会直接 no-op）。这能确保物理键盘的 Shift/Ctrl/Alt 在游戏内生效。
        CallbackBridge_queueModifierSync(modifiers);
    } else {
        NSLog(@"KeyboardInput: Unhandled key %lu", (unsigned long)key.keyCode);
    }

    // key.characters.length < 11: skip sending characters if the string starts with UIKeyInput
    if (isDown && key.characters.length < 11) {
        for (int i = 0; i < key.characters.length; i++) {
            int keychar = [key.characters characterAtIndex:i];
            CallbackBridge_nativeSendCharMods(keychar, modifiers);
            CallbackBridge_nativeSendChar(keychar);
        }
    }

    return keycode != 0 || isDown;
}

@end
