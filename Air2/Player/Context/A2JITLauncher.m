//
//  A2JITLauncher.m
//  Air2
//

#import "A2JITLauncher.h"
#import "utils.h"
#import "A2Logger.h"
#import "A2Dialog.h"
#import "A2Settings.h"

@implementation A2JITLauncher

+ (A2JITState)currentState {
    // 1. 已经能用
    if (isJITEnabled(NO)) {
        // 但要做到「真能力自检」——CS_DEBUGGED 可能是粘滞的
        if (DeviceNeedsDebugJITMapping() && !AMEJITVerifyWritableJITRegion()) {
            [A2Logger warning:@"JIT" message:@"isJITEnabled=1 但真能力自检失败（CS_DEBUGGED 粘滞）"];
            return A2JITStateUnavailable;
        }
        return A2JITStateReady;
    }

    // 2. 越狱原生 JIT
    if (AMEJailbreakNativeJITPathApplies()) {
        if (AMEJailbreakNativeJITReady()) {
            [A2Logger info:@"JIT" message:@"越狱原生 JIT 已验证可用"];
            return A2JITStateReady;
        }
        [A2Logger info:@"JIT" message:@"越狱环境但原生 JIT 未就绪，回落外部使能器"];
    }

    // 3. 外部使能器已配置
    if (AMEJITConfiguredExternalEnablerIsActive()) {
        return A2JITStateWaiting;
    }

    return A2JITStateUnavailable;
}

+ (NSString *)statusDescription {
    switch ([self currentState]) {
        case A2JITStateReady:
            return @"JIT 可用";
        case A2JITStateWaiting:
            return [NSString stringWithFormat:@"等待 %@ 启用 JIT",
                    AMEJITConfiguredEnablerDisplayName() ?: @"外部工具"];
        default:
            return @"无 JIT（游戏将无法运行）";
    }
}

+ (void)gatedByJITInViewController:(UIViewController *)host
                            onReady:(void (^)(void))handler {
    BOOL jit = isJITEnabled(NO);
    BOOL native = AMEJailbreakNativeJITPathApplies() && AMEJailbreakNativeJITReady();
    BOOL jbPath = AMEJailbreakNativeJITPathApplies();
    BOOL hasEnabler = AMEJITConfiguredExternalEnablerIsActive();

    [A2Logger info:@"JIT"
           message:[NSString stringWithFormat:
                    @"门禁检查：isJIT=%d 越狱路径=%d 原生就绪=%d 外部使能器=%@",
                    jit, jbPath, native,
                    hasEnabler ? (AMEJITConfiguredEnablerDisplayName() ?: @"已配置") : @"无"]];

    // ---- 放行条件 ----
    if (jit || native) {
        // CS_DEBUGGED 可能粘滞（调试器早已脱离），做一次真自检
        if (DeviceNeedsDebugJITMapping() && !AMEJITVerifyWritableJITRegion()) {
            [A2Logger warning:@"JIT" message:@"声明可用但自检失败，尝试重挂调试器"];
            [self presentUnavailableIn:host
                                 title:@"JIT 未真正就绪"
                               message:@"系统标记显示已启用 JIT，但实测无法分配可执行内存。\n\n"
                                        @"通常是调试器已脱离（工具被系统回收）。请重新用 JIT 工具附加一次后重试。"];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (handler) handler();
        });
        return;
    }

    // ---- 有外部使能器：唤起并等待 ----
    if (hasEnabler) {
        NSString *name = AMEJITConfiguredEnablerDisplayName() ?: @"JIT 工具";
        [A2Logger info:@"JIT" message:[NSString stringWithFormat:@"唤起外部使能器：%@", name]];

        AMEJITEnablerActionResult r = AMEJITOpenConfiguredExternalEnabler();
        if (r == AMEJITEnablerActionResultMissingTool) {
            [self presentUnavailableIn:host
                                 title:@"找不到 JIT 工具"
                               message:[NSString stringWithFormat:
                                        @"已配置「%@」，但系统里找不到它（可能未安装或 URL Scheme 被禁用）。\n\n"
                                        @"请在「设置 → 启动器 → JIT 获取方式」里改选一个已安装的工具。", name]];
            return;
        }

        // 轮询等待（最多 60 秒）
        __weak typeof(host) weakHost = host;
        [self waitForJITWithDeadline:60
                             attempt:0
                                host:weakHost
                             onReady:handler];
        return;
    }

    // ---- 什么都没有 ----
    [self presentUnavailableIn:host
                         title:@"无法启用 JIT"
                       message:@"当前设备没有可用的 JIT（即时编译），游戏会在启动后卡死。\n\n"
                                @"解决方式（任选其一）：\n"
                                @"· 用 StikDebug / SideStore 等方式为 Air2 启用 JIT\n"
                                @"· TrollStore 用户可在设置里选择对应工具\n"
                                @"· 越狱设备可直接使用原生 JIT\n\n"
                                @"启用后回到这里再次启动游戏。"];
}

#pragma mark - 等待

+ (void)waitForJITWithDeadline:(NSTimeInterval)seconds
                       attempt:(NSInteger)attempt
                          host:(UIViewController *)host
                       onReady:(void (^)(void))handler {
    if (AMEJITWaitReadyVerified()) {
        [A2Logger info:@"JIT"
               message:[NSString stringWithFormat:@"第 %ld 次检查：JIT 就绪，开始启动",
                        (long)(attempt + 1)]];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (handler) handler();
        });
        return;
    }

    if (attempt * 1.0 >= seconds) {
        [A2Logger error:@"JIT" message:@"等待 JIT 超时"];
        [self presentUnavailableIn:host
                             title:@"等待 JIT 超时"
                           message:@"外部工具没有在规定时间内启用 JIT。\n\n"
                                    @"请确认工具已经在后台运行，然后重试。"];
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self waitForJITWithDeadline:seconds
                             attempt:attempt + 1
                                host:host
                             onReady:handler];
    });
}

#pragma mark - 提示

+ (void)presentUnavailableIn:(UIViewController *)host
                       title:(NSString *)title
                     message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!host || !host.view) {
            [A2Logger error:@"JIT" message:message];
            return;
        }
        [A2Dialog showInView:host.view
                       title:title
                     message:message
                     actions:@[
            [A2DialogAction actionWithTitle:@"知道了"
                                       style:A2DialogActionStyleFilled
                                     handler:nil],
        ]];
    });
}

@end
