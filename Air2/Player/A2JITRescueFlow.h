#ifndef A2_JIT_RESCUE_FLOW_H
#define A2_JIT_RESCUE_FLOW_H

#import <Foundation/Foundation.h>

/// 启动前 JIT 补齐流程：没 JIT 就带脚本跳 StikDebug，回来复查后继续启动。
@interface A2JITRescueFlow : NSObject

/// 当前 JIT 是否可用（内核级 entitlement / CS_DEBUGGED / 区域已验证）
+ (BOOL)jitReadyNow;

/// 拉起外部工具（带我们的脚本路径），等回到前台后复查，回调结果。
+ (void)beginRescueWithScript:(NSString *)scriptPath
                   completion:(void (^)(BOOL ok))completion;

@end

#endif
