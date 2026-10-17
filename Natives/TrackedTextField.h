#import <UIKit/UIKit.h>

#include "jni.h"

@interface TrackedTextField : UITextField

@property(nonatomic, copy) void(^sendChar)(jchar codepoint);
@property(nonatomic, copy) void(^sendCharMods)(jchar codepoint, int mods);
@property(nonatomic, copy) void(^sendKey)(int key, int scancode, int action, int mods);
// SDL/IME 侧临时 resign 要求导致标准键盘意外关闭的防护（Amethyst-JP 同款思路）。
// 置位时忽略非显式的 resign；SurfaceViewController 在显式键盘开关处临时清零。

@property(nonatomic, assign) BOOL preventUnexpectedResign;
@end
