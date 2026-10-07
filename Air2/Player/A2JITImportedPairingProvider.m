//
//  A2JITImportedPairingProvider.m
//  Air2
//
//  ★占位实现★：配对文件的【存在性】可由事实回答；【导入动作】（文档选择器）与
//  【开启动作】（iOS 26 内置 helper）属第二阶段。
//

#import "A2JITImportedPairingProvider.h"
#import "A2JITFacts.h"

@interface A2JITImportedPairingProvider ()
@property (nonatomic, strong) A2JITFacts *facts;
@end

@implementation A2JITImportedPairingProvider

- (instancetype)initWithFacts:(A2JITFacts *)facts {
    NSParameterAssert(facts);
    self = [super init];
    if (self) {
        _facts = facts;
    }
    return self;
}

- (A2JITProviderKind)kind {
    return A2JITProviderKindImportedPairing;
}

- (NSString *)displayName {
    return @"导入配对文件";
}

- (BOOL)isAvailable {
    return [self.facts supportsRemoteDebugJIT];
}

- (BOOL)isPairingReady {
    return self.facts.hasImportedPairingFile;
}

- (BOOL)preparePairingWithError:(NSError *_Nullable *_Nullable)error {
    if (self.isPairingReady) {
        return YES;
    }
    if (error) {
        *error = A2JITProviderNotImplementedError(
            @"尚未导入配对文件：请在设置中导入 .plist / .mobiledevicepairing");
    }
    return NO;
}

- (BOOL)activateJITWithError:(NSError *_Nullable *_Nullable)error {
    if (![self.facts supportsBuiltInHelper]) {
        if (error) {
            *error = A2JITProviderNotImplementedError(
                @"iOS 17.4–25 没有内置开启能力：请改用外部工具（StikDebug / SideStore…）启用 JIT");
        }
        return NO;
    }
    if (error) {
        *error = A2JITProviderNotImplementedError(
            @"iOS 26 内置手动开启尚未接入（第二阶段：独立 helper 进程 + ExtensionKit XPC）");
    }
    return NO;
}

- (NSString *)userActionHint {
    return @"在设置 → JIT 中导入由外部工具生成的配对文件";
}

@end
