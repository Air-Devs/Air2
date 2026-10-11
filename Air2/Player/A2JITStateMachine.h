//
//  A2JITStateMachine.h
//  Air2
//
//  Player —— JIT 供给的【纯状态机】（状态 + 原因 + 说明；★不碰 UIKit、不碰 Provider★）。
//
//  [JIT-IMPL] 为什么单独拆出来：
//    · 原来的状态迁移逻辑内嵌在 A2JITCoordinator.m（那里还牵着 Provider 与启动链），
//      无法脱离真机单测。这里把它抽成纯值迁移：给定“从哪来 / 去哪”，只回答
//      【是否合法】并落状态，返回 YES/NO；★不做任何平台/网络动作★。
//    · 状态与原因枚举也一并落在此处（它们本来就是状态机的词汇），
//      A2JITCoordinator.h 转引它，保持既有引用路径不变。
//
//  状态图（见 docs/JIT-PROVISIONING.md §2.1）：
//
//      Unavailable ──▶ WaitingPairing ──(取配对)──▶ Paired
//           ▲                                          │ enableJIT
//           │                                          ▼
//           └────────────── WaitingActivation ──成功──▶ Enabled（终态）
//
//  合法迁移（★Enabled 是终态，只能停在 Enabled★）：
//    · Unavailable       → WaitingPairing | Paired            （环境变好，重评估）
//    · WaitingPairing     → Paired | Unavailable              （取配对成功 / 路径消失）
//    · Paired             → WaitingActivation | WaitingPairing | Unavailable
//    · WaitingActivation  → Enabled | Paired | WaitingPairing | Unavailable
//    · Enabled            → （仅自迁移；不得离开）
//  自迁移（X→X）恒合法：只更新原因/说明（refreshState 的抖动不入死循环）。
//  ★非法示例（应被拒）★：WaitingPairing→Enabled / Paired→Enabled / Unavailable→WaitingActivation /
//    Enabled→任何其它（终态不可逆）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// JIT 供给状态机。
///
/// 串起「配对 → 开启」，把「配对」从「就绪」里单独拆出，以承载四类取得路径。
typedef NS_ENUM(NSInteger, A2JITState) {
    A2JITStateUnavailable       = 0,  ///< 不可用：无可用取得路径（含原因，见 A2JITFailureReason）
    A2JITStateWaitingPairing    = 1,  ///< 等待配对：尚无本机配对材料
    A2JITStatePaired            = 2,  ///< 已配对：配对材料就绪（导入 / 自动 / 外部 / 内核）
    A2JITStateWaitingActivation = 3,  ///< 等待开启：已配对，正在附加调试器 / 分配 JIT
    A2JITStateEnabled           = 4,  ///< 已启用：本进程已获得 JIT（终态）
};

/// 不可用 / 失败的原因（★带原因枚举★，供失败提示条分流，不可混成一句万能文案）。
typedef NS_ENUM(NSInteger, A2JITFailureReason) {
    A2JITFailureReasonNone                 = 0,  ///< 无失败
    A2JITFailureReasonSystemTooOld         = 1,  ///< 系统过低（纯签名 < 17.4）
    A2JITFailureReasonNoProvider           = 2,  ///< 本机没有可用的取得路径
    A2JITFailureReasonPairingMissing       = 3,  ///< 缺配对文件 / 尚未导入
    A2JITFailureReasonAutoPairingNotBuilt  = 4,  ///< 设备内自动配对未实现（本版本）
    A2JITFailureReasonExternalToolMissing  = 5,  ///< 未检测到可拉起的外部工具
    A2JITFailureReasonTunnelUnreachable    = 6,  ///< 隧道（LocalDevVPN）不可达
    A2JITFailureReasonActivationFailed     = 7,  ///< 开启 JIT 失败
    A2JITFailureReasonKernelJITUnavailable = 8,  ///< 内核级 JIT 环境不具备
};

/// ★[JIT-IMPL] 纯状态机★：只做合法迁移判定 + 落状态，可脱离真机单测。
@interface A2JITStateMachine : NSObject

/// 当前状态（默认 Unavailable）。
@property (nonatomic, readonly) A2JITState state;
/// 当前/最近失败原因（正常态为 A2JITFailureReasonNone）。
@property (nonatomic, readonly) A2JITFailureReason failureReason;
/// 状态的可读说明（UI/诊断用；可为空串）。
@property (nonatomic, readonly, copy) NSString *statusDetail;

/// 以默认状态（Unavailable）构造。
- (instancetype)init;
/// 以指定初始状态构造。
- (instancetype)initWithState:(A2JITState)state;

/// 纯判定：从 from 迁到 to 是否合法（自迁移恒合法）。
+ (BOOL)canTransitionFrom:(A2JITState)from to:(A2JITState)to;

/// 尝试迁移：合法则落状态（并更新原因/说明）返回 YES；非法则【状态不变】返回 NO。
- (BOOL)transitionTo:(A2JITState)to
              reason:(A2JITFailureReason)reason
              detail:(nullable NSString *)detail;

/// 状态 / 原因的展示名（诊断、日志、UI 文案用）。
+ (NSString *)displayNameForState:(A2JITState)state;
+ (NSString *)displayNameForFailureReason:(A2JITFailureReason)reason;

@end

NS_ASSUME_NONNULL_END
