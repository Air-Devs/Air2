//
//  A2JITExternalToolProvider.m
//  Air2
//
//  ★占位实现★：只回答「本机是否装了可拉起的外部使能器」；拉起 + 有界等待属第二阶段。
//

#import "A2JITExternalToolProvider.h"
#import "A2JITFacts.h"

@interface A2JITExternalToolProvider ()
@property (nonatomic, strong) A2JITFacts *facts;
@end

@implementation A2JITExternalToolProvider

- (instancetype)initWithFacts:(A2JITFacts *)facts {
    NSParameterAssert(facts);
    self = [super init];
    if (self) {
        _facts = facts;
    }
    return self;
}

- (A2JITProviderKind)kind {
    return A2JITProviderKindExternalTool;
}

- (NSString *)displayName {
    return @"外部工具";
}

- (BOOL)isAvailable {
    // 外部工具本身要求 iOS 17.4+（StikDebug 系的最低系统）。
    return [self.facts supportsRemoteDebugJIT];
}

- (BOOL)isPairingReady {
    // 装了外部使能器即视为「可完成配对 + 开启」——它自带隧道与配对能力。
    return self.facts.hasExternalEnablerInstalled;
}

- (BOOL)preparePairingWithError:(NSError *_Nullable *_Nullable)error {
    if (self.isPairingReady) {
        return YES;
    }
    if (error) {
        *error = A2JITProviderNotImplementedError(
            @"未检测到可拉起的外部工具：请安装 StikDebug / SideStore 等并保持其 scheme 可打开");
    }
    return NO;
}

- (BOOL)activateJITWithError:(NSError *_Nullable *_Nullable)error {
    if (error) {
        *error = A2JITProviderNotImplementedError(
            @"外部工具开启 JIT 尚未接入（第二阶段：canOpenURL + scheme 拉起 + 有界等待 + 真实能力复验）");
    }
    return NO;
}

- (NSString *)userActionHint {
    return @"安装并使用外部工具（StikDebug / SideStore…）开启 JIT";
}

@end
