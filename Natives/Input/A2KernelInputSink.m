// ============================================================================
//  Natives/Input/A2KernelInputSink.m
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 内核汇实现
// ----------------------------------------------------------------------------
//  只做一件事：把映射层解算好的事件，按目标空间投给当前内核能收的通道。
//  ★这里不许出现任何版本判断★（26.2/26.3 的差异已经封在
//  a2_glfw_input_post_key_event 内部；在这里再判一次就会出现两处真相）。
// ============================================================================
#import "A2KernelInputSink.h"

#import "a2_glfw_input.h"
#import "a2_log.h"

@implementation A2KernelInputSink {
    /// 只报一次「本内核没有手柄通道」，避免连按时刷屏
    BOOL _loggedGamepadUnsupported;
}

- (instancetype)initWithWindowHandle:(long)window {
    self = [super init];
    if (self != nil) {
        _windowHandle = window;
    }
    return self;
}

- (NSString *)sinkIdentifier {
    return @"kernel-glfw";
}

- (BOOL)isAvailable {
    return _windowHandle != 0;
}

- (BOOL)emitEvent:(A2InputEvent)event {
    if (!self.isAvailable) {
        return NO;
    }
    switch (event.targetKind) {
        case A2InputTargetKindKey:
            // 键盘落点：GLFW 总线 + （26.3 时）SDL 镜像，都在这个函数里完成。
            a2_glfw_input_post_key_event(_windowHandle, event.code, event.scancode,
                                         (event.action == A2InputActionPress) ? 1 : 0,
                                         event.mods);
            return YES;

        case A2InputTargetKindGamepadButton:
            if (!_loggedGamepadUnsupported) {
                _loggedGamepadUnsupported = YES;
                a2_log_criterion(@"[INPUT-MAP] 当前内核没有手柄通道：落点 %@ 无法直接投递，"
                                 @"请把该按键绑到键盘键位（默认表已如此）",
                                 A2GamepadButtonName((A2GamepadButton) event.code));
            }
            return NO;
    }
    return NO;
}

@end
