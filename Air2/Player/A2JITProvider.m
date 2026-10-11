//
//  A2JITProvider.m
//  Air2
//
//  Provider 层共用：错误 domain 与「未接入」/「真实失败」两类错误的统一构造。
//  ★本文件不含任何平台实现★（四路实现的机制在各自的 .m 里）。
//

#import "A2JITProvider.h"

NSString *const A2JITProviderErrorDomain = @"A2JITProviderError";

NSError *A2JITProviderNotImplementedError(NSString *reason) {
    NSString *message = reason.length ? reason : @"第二阶段未接入";
    return [NSError errorWithDomain:A2JITProviderErrorDomain
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

// [JIT-IMPL-2] code=2：机制在，但这一次真的没成（判据未通过 / 超时 / 缺文件）。
NSError *A2JITProviderFailureError(NSString *reason) {
    NSString *message = reason.length ? reason : @"本次执行未成功";
    return [NSError errorWithDomain:A2JITProviderErrorDomain
                               code:2
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}
