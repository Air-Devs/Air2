// ============================================================================
//  Natives/Input/A2VirtualButtonInputSource.m
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 虚拟按钮源（接口 + 未实现）
// ----------------------------------------------------------------------------
//  ★本文件刻意「没有实现」★：接口与错误路径都是真的，只有「接上控件层」这一步
//  留给 [INPUT-MAP-2]。这样映射层今天就能把它注册进来、单测能断言「未接线时
//  start 如实失败」，而不是等实现完了才发现接口形状不对。
// ============================================================================
#import "A2VirtualButtonInputSource.h"

#import "a2_log.h"

@implementation A2VirtualButtonInputSource {
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
    return A2InputSourceKindVirtualButton;
}

- (NSString *)sourceIdentifier {
    return @"virtual-button";
}

- (BOOL)isWired {
    // 接线 = start 成功。start 恒失败 ⇒ 恒 NO（见下）。
    return NO;
}

- (BOOL)startWithError:(NSError *_Nullable *_Nullable)error {
    if (error != NULL) {
        *error = [NSError errorWithDomain:A2InputErrorDomain
                                     code:A2InputErrorCodeNotImplemented
                                 userInfo:@{
            NSLocalizedDescriptionKey:
                @"虚拟按钮源尚未接线（[INPUT-MAP-2]）：控件层当前仍直接投 GLFW 键事件"
        }];
    }
    return NO;
}

- (void)stop {
    self.enabled = NO;
}

#pragma mark - 触发

- (void)buttonWithIdentifier:(NSString *)identifier action:(A2InputAction)action {
    if (identifier.length == 0) {
        return;
    }
    if (!self.isEnabled) {
        // 没接线时被调用（说明有人在 [INPUT-MAP-2] 之前就改了控件层）：
        // 记一次，避免「改了代码但没生效」被当成玄学。
        if (!_loggedNotWired) {
            _loggedNotWired = YES;
            a2_log_f(@"[INPUT-MAP] 虚拟按钮源未接线，丢弃控件 %s 的事件",
                     identifier.UTF8String ?: "?");
        }
        return;
    }
    A2InputTrigger trigger = A2InputTriggerMake(A2InputSourceKindVirtualButton, 0, identifier, action, 0);
    [self.delegate inputSource:self didProduceTrigger:trigger];
}

@end
