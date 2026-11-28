// ============================================================================
//  Natives/Input/A2GamepadInputSource.m
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 手柄源（接口 + 未实现）
// ----------------------------------------------------------------------------
//  同虚拟按钮源：接口与错误路径是真的，只有「接 GameController」这一步留给
//  [INPUT-MAP-3]。这样手柄的出厂映射表今天就能被单测断言，
//  等真接上时不需要再改映射层与绑定表。
// ============================================================================
#import "A2GamepadInputSource.h"

#import "a2_log.h"

@implementation A2GamepadInputSource {
    BOOL _loggedNotWired;
}

@synthesize enabled = _enabled;
@synthesize delegate = _delegate;

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _enabled = YES;
    }
    return self;
}

#pragma mark - A2InputSource

- (A2InputSourceKind)sourceKind {
    return A2InputSourceKindGamepad;
}

- (NSString *)sourceIdentifier {
    return @"gamepad";
}

- (BOOL)isWired {
    return NO;
}

- (BOOL)startWithError:(NSError *_Nullable *_Nullable)error {
    if (error != NULL) {
        *error = [NSError errorWithDomain:A2InputErrorDomain
                                     code:A2InputErrorCodeNotImplemented
                                 userInfo:@{
            NSLocalizedDescriptionKey:
                @"手柄源尚未接线（[INPUT-MAP-3]）：GameController 回调未接入"
        }];
    }
    return NO;
}

- (void)stop {
    self.enabled = NO;
}

#pragma mark - 触发

- (void)button:(A2GamepadButton)button action:(A2InputAction)action {
    if (button < 0 || button >= A2GamepadButtonCount) {
        return;
    }
    if (!self.isEnabled) {
        if (!_loggedNotWired) {
            _loggedNotWired = YES;
            a2_log_f(@"[INPUT-MAP] 手柄源未接线，丢弃按键 %s 的事件",
                     A2GamepadButtonName(button).UTF8String ?: "?");
        }
        return;
    }
    A2InputTrigger trigger = A2InputTriggerMake(A2InputSourceKindGamepad, (int) button, nil, action, 0);
    [self.delegate inputSource:self didProduceTrigger:trigger];
}

@end
