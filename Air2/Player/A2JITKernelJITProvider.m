//
//  A2JITKernelJITProvider.m
//  Air2
//
//  ★占位实现★：只回答「本机是否具备内核级 JIT 环境」；真实启用 + 复验属第二阶段。
//

#import "A2JITKernelJITProvider.h"
#import "A2JITFacts.h"

@interface A2JITKernelJITProvider ()
@property (nonatomic, strong) A2JITFacts *facts;
@end

@implementation A2JITKernelJITProvider

- (instancetype)initWithFacts:(A2JITFacts *)facts {
    NSParameterAssert(facts);
    self = [super init];
    if (self) {
        _facts = facts;
    }
    return self;
}

- (A2JITProviderKind)kind {
    return A2JITProviderKindKernel;
}

- (NSString *)displayName {
    return @"内核级 JIT";
}

- (BOOL)isAvailable {
    return [self.facts hasKernelJITEnvironment];
}

- (BOOL)isPairingReady {
    // 内核级路径不需要配对文件 / 隧道：环境具备即视为「配对就绪」。
    return self.isAvailable;
}

- (BOOL)preparePairingWithError:(NSError *_Nullable *_Nullable)error {
    if (self.isAvailable) {
        return YES;
    }
    if (error) {
        *error = A2JITProviderNotImplementedError(
            @"本机不具备内核级 JIT 环境（需越狱 / TrollStore / dynamic-codesigning）");
    }
    return NO;
}

- (BOOL)activateJITWithError:(NSError *_Nullable *_Nullable)error {
    if (error) {
        *error = A2JITProviderNotImplementedError(
            @"内核级 JIT 直启尚未接入（第二阶段：复用 A2JITEnvironment 的真实能力复验）");
    }
    return NO;
}

- (NSString *)userActionHint {
    return @"越狱环境需在越狱设置里为本 App 打开 JIT（Allow JIT）";
}

@end
