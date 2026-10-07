//
//  A2JITCoordinator.m
//  Air2
//
//  JIT 供给编排实现。★只做状态推进与优先级判定，不含平台/网络细节★。
//  所有真正的动作（生成 / 导入 / 探测 / 附加调试器）都委托给注入的 A2JITProvisioning。
//

#import "A2JITCoordinator.h"

static NSString *const A2JITCoordinatorErrorDomain = @"A2JITCoordinatorError";

@interface A2JITCoordinator ()
@property (nonatomic, strong) id<A2JITProvisioning> provisioning;
@property (nonatomic, readwrite) A2JITState state;
@property (nonatomic, readwrite, copy) NSString *statusDetail;
- (void)settle:(A2JITState)state detail:(NSString *)detail;
- (void)fail:(NSError *_Nullable *_Nullable)error
        code:(NSInteger)code
     message:(NSString *)message;
@end

@implementation A2JITCoordinator

- (instancetype)initWithProvisioning:(id<A2JITProvisioning>)provisioning {
    NSParameterAssert(provisioning);
    self = [super init];
    if (self) {
        _provisioning = provisioning;
        _state = A2JITStateUnavailable;
        _statusDetail = @"尚未评估 JIT 环境";
    }
    return self;
}

- (BOOL)readyToRunGame {
    return self.state == A2JITStateEnabled;
}

#pragma mark - 状态推进

- (void)settle:(A2JITState)state detail:(NSString *)detail {
    self.state = state;
    self.statusDetail = detail;
    NSLog(@"[A2JIT] %ld %@", (long)state, detail);
}

- (void)refreshState {
    // 已启用是终态：不因一次探测抖动把状态复位（JIT 一旦拿到不会撤销）。
    if (self.state == A2JITStateEnabled) {
        return;
    }

    if (![self.provisioning isSystemSupported]) {
        [self settle:A2JITStateUnavailable
              detail:@"系统版本不支持内置 JIT（需 iOS 17.4+）"];
        return;
    }

    if (![self.provisioning hasPairingFile]) {
        [self settle:A2JITStateWaitingPairing detail:@"等待配对文件"];
        return;
    }

    if (![self.provisioning isTunnelReachable]) {
        [self settle:A2JITStatePaired detail:@"已配对，等待隧道就绪（如 LocalDevVPN）"];
        return;
    }

    [self settle:A2JITStateWaitingActivation detail:@"已配对且环境就绪，等待开启 JIT"];
}

#pragma mark - 取得配对（① 自动 → ② 导入 → ③ 外部）

- (BOOL)acquirePairingWithImportedURL:(NSURL *)importedURL
                                error:(NSError *_Nullable *_Nullable)error {
    if (![self.provisioning isSystemSupported]) {
        [self fail:error code:A2JITStateUnavailable message:@"系统版本不支持内置 JIT（需 iOS 17.4+）"];
        return NO;
    }

    // ① 自动生成（可选能力；未实现或失败都不拦路，降级到 ②）。
    if ([self.provisioning respondsToSelector:@selector(generatePairingFileWithError:)]) {
        NSError *genErr = nil;
        if ([self.provisioning generatePairingFileWithError:&genErr]) {
            [self refreshState];
            return YES;
        }
        NSLog(@"[A2JIT] 自动生成配对文件未成功，降级到导入: %@",
              genErr.localizedDescription ?: @"(无详情)");
    }

    // ② 导入用户提供的文件（需要 UI 提供 URL）。
    if (importedURL &&
        [self.provisioning respondsToSelector:@selector(importPairingFileAtURL:error:)]) {
        if ([self.provisioning importPairingFileAtURL:importedURL error:error]) {
            [self refreshState];
            return YES;
        }
        return NO;
    }

    // ③ 外部工具：本层不接管，只给出指引（详见 docs/DECISIONS.md ADR-007）。
    [self fail:error code:A2JITPairingSourceExternal
        message:@"尚无配对文件：请通过外部工具（如 StikDebug / SideStore）生成后导入"];
    return NO;
}

#pragma mark - 开启 JIT

- (BOOL)enableJITWithError:(NSError *_Nullable *_Nullable)error {
    if (self.state == A2JITStateEnabled) {
        return YES;
    }
    if (![self.provisioning isSystemSupported]) {
        [self fail:error code:A2JITStateUnavailable message:@"系统版本不支持内置 JIT（需 iOS 17.4+）"];
        return NO;
    }
    if (![self.provisioning hasPairingFile]) {
        [self fail:error code:A2JITStateWaitingPairing message:@"请先取得本机配对文件"];
        return NO;
    }

    [self settle:A2JITStateWaitingActivation detail:@"正在开启 JIT…"];
    NSError *enableErr = nil;
    if (![self.provisioning enableJITForCurrentProcessWithError:&enableErr]) {
        // 开启失败不回退到「未配对」——配对文件仍在，只是本次没成。
        [self settle:A2JITStateWaitingActivation
              detail:enableErr.localizedDescription ?: @"开启 JIT 失败"];
        if (error) { *error = enableErr; }
        return NO;
    }

    [self settle:A2JITStateEnabled detail:@"JIT 已启用"];
    return YES;
}

#pragma mark - 错误

- (void)fail:(NSError *_Nullable *_Nullable)error
        code:(NSInteger)code
     message:(NSString *)message {
    [self settle:self.state detail:message];
    if (error) {
        *error = [NSError errorWithDomain:A2JITCoordinatorErrorDomain
                                     code:code
                                 userInfo:@{ NSLocalizedDescriptionKey: message }];
    }
}

@end
