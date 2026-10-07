//
//  A2JITAutomaticPairingProvider.m
//  Air2
//
//  ★占位实现★：只回答「本机是否支持这条路径」，机制一律返回未接入。
//

#import "A2JITAutomaticPairingProvider.h"
#import "A2JITFacts.h"

@interface A2JITAutomaticPairingProvider ()
@property (nonatomic, strong) A2JITFacts *facts;
@end

@implementation A2JITAutomaticPairingProvider

- (instancetype)initWithFacts:(A2JITFacts *)facts {
    NSParameterAssert(facts);
    self = [super init];
    if (self) {
        _facts = facts;
    }
    return self;
}

- (A2JITProviderKind)kind {
    return A2JITProviderKindAutomaticPairing;
}

- (NSString *)displayName {
    return @"设备内自动配对";
}

- (BOOL)isAvailable {
    // 仅 iOS 27+ 有用户可见的设备内自动配对（iOS 18–26.7 仍需配对文件 + PC）。
    return [self.facts supportsAutomaticPairing];
}

- (BOOL)isPairingReady {
    // 占位：自动生成尚未接入，恒判未就绪，编排层会自动降级到 ② 导入。
    return NO;
}

- (BOOL)preparePairingWithError:(NSError *_Nullable *_Nullable)error {
    if (error) {
        *error = A2JITProviderNotImplementedError(
            @"设备内自动配对尚未接入（第二阶段：自研 RPPairing + vendor idevice(MIT)）");
    }
    return NO;
}

- (BOOL)activateJITWithError:(NSError *_Nullable *_Nullable)error {
    if (error) {
        *error = A2JITProviderNotImplementedError(@"自动配对路径的 JIT 开启尚未接入（第二阶段）");
    }
    return NO;
}

- (NSString *)userActionHint {
    return @"当前版本尚未接入设备内自动配对，请改用导入配对文件或外部工具";
}

@end
