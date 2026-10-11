//
//  A2LaunchChain.m
//  Air2
//
//  顺序编排实现。★只做顺序与短路，不含任何业务/平台细节★。
//

#import "A2LaunchChain.h"

static NSString *const A2LaunchChainErrorDomain = @"A2LaunchChainError";

@interface A2LaunchChain ()
@property (nonatomic, copy) A2LaunchChainDeliverScriptBlock deliverBlock;
@property (nonatomic, copy) A2LaunchChainVerifyBlock verifyBlock;
@property (nonatomic, copy) A2LaunchChainCreateVMBlock createVMBlock;
@property (nonatomic, readwrite) A2LaunchChainStage stage;
@property (nonatomic, readwrite, copy) NSString *failureReason;
@end

@implementation A2LaunchChain

+ (instancetype)chainWithDeliverScript:(A2LaunchChainDeliverScriptBlock)deliver
                                verify:(A2LaunchChainVerifyBlock)verify
                             createJVM:(A2LaunchChainCreateVMBlock)createJVM {
    NSParameterAssert(deliver);
    NSParameterAssert(verify);
    NSParameterAssert(createJVM);
    A2LaunchChain *c = [A2LaunchChain new];
    c.deliverBlock = deliver;
    c.verifyBlock = verify;
    c.createVMBlock = createJVM;
    c.stage = A2LaunchChainStageIdle;
    c.failureReason = @"";
    return c;
}

- (BOOL)runWithError:(NSError **)error {
    NSError *stepErr = nil;

    // ① 先发脚本：失败【不拦路】（下发是尽力而为；探测会再兜底）。
    //    —— 对齐 [JIT-ORDER]：Extension/自包含脚本必须在任何 brk #0x69 探测之前下发，
    //       否则 base 脚本对传统 0x69 只回哨兵 0xE0000069 ⇒ 探测永远失败（死锁）。
    self.stage = A2LaunchChainStageScript;
    if (!self.deliverBlock(&stepErr)) {
        NSLog(@"[A2LAUNCH] ① 下发 JIT 脚本未成功（不拦路，继续）: %@",
              stepErr.localizedDescription ?: @"(无详情)");
    }

    // ② 探测 JIT：不通过 ⇒ 优雅失败，绝不进 ③（否则首帧 JIT 取指 SIGBUS）。
    self.stage = A2LaunchChainStageVerify;
    NSString *reason = nil;
    if (!self.verifyBlock(&reason)) {
        self.failureReason = reason.length ? reason : @"JIT 不可用";
        if (error) {
            *error = [NSError errorWithDomain:A2LaunchChainErrorDomain
                                         code:A2LaunchChainStageVerify
                                     userInfo:@{ NSLocalizedDescriptionKey: self.failureReason }];
        }
        NSLog(@"[A2LAUNCH] ② JIT 不可用，已阻止创建 VM: %@", self.failureReason);
        return NO;
    }

    // ③ 建 VM。
    self.stage = A2LaunchChainStageCreateVM;
    stepErr = nil;
    if (!self.createVMBlock(&stepErr)) {
        self.failureReason = stepErr.localizedDescription ?: @"创建 JVM 失败";
        if (error) {
            *error = stepErr ?: [NSError errorWithDomain:A2LaunchChainErrorDomain
                                                    code:A2LaunchChainStageCreateVM
                                                userInfo:@{ NSLocalizedDescriptionKey: self.failureReason }];
        }
        NSLog(@"[A2LAUNCH] ③ 创建 JVM 失败: %@", self.failureReason);
        return NO;
    }

    self.stage = A2LaunchChainStageDone;
    NSLog(@"[A2LAUNCH] 全链成功（① 脚本 → ② JIT 已验证 → ③ VM 已创建）");
    return YES;
}

@end
