//
//  A2JITAutoPairing.h
//  Air2
//
//  Player —— 取得路径 ①：【设备内自动配对】（iOS 27+，自研 RPPairing）的类型与注入缝。
//
//  口径来源：docs/JIT-PROVISIONING.md §1.2（iOS 27+ —— 自动）。
//    前置条件 = ① Developer Mode 开启 ② 本地网络权限（Bonjour 广告）
//               ③ 签名带 get-task-allow ④（首次）联网取 DDI；
//    取得路径 = 设备内自动配对（自研 RPPairing：RSD host + pair-verify + TLS-PSK 隧道）
//               → App 内开启 JIT。
//
//  ★本文件只定义「类型 + 协议 + 纯逻辑映射」★：
//    · 真正发 Bonjour / 连 RSD / pair-verify / 建 TLS-PSK 的实现【不在这里】——
//      真机实现经 Bridge 落到 Natives（层级：App → UI → Player → Core → Bridge → Natives）；
//      Player 侧只认协议与值对象（可脱离真机单测）。
//    · ★不引入任何第三方库★；★不参考/不搬运 SideInstaller 代码★
//      （其许可为自定义：非商业 + 禁止再分发，只可参考协议思路，见 docs/DEPENDENCIES.md）。
//
//  与 A2JITReadinessProbe 的分工：
//    · A2JITAutoPairingEngine 负责【把配对文件拿到手】（本文件）；
//    · A2JITReadinessProbe 负责【复验本进程现在能不能用 JIT】（brk #0x69 区域取证）。
//    两者都由 Provider 在对应阶段调用，互不替代。
//

#import <Foundation/Foundation.h>
#import "A2JITStateMachine.h"   // A2JITFailureReason（把分类映射回现有失败原因体系）

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// 前置条件（docs/JIT-PROVISIONING.md §1.2 的 ①–④）
// ---------------------------------------------------------------------------

/// 自动配对的前置条件（四项；顺序即文档 ①–④）。
typedef NS_ENUM(NSInteger, A2JITAutoPairingPrecondition) {
    A2JITAutoPairingPreconditionDeveloperMode = 0,  ///< ① Developer Mode 开启
    A2JITAutoPairingPreconditionLocalNetwork  = 1,  ///< ② 本地网络权限（Bonjour 广告）
    A2JITAutoPairingPreconditionGetTaskAllow  = 2,  ///< ③ 签名带 get-task-allow
    A2JITAutoPairingPreconditionDDI           = 3,  ///< ④（首次）联网取 DDI（Developer Disk Image）
};

/// 前置条件数量（遍历用；勿改语义）。
FOUNDATION_EXPORT const NSInteger A2JITAutoPairingPreconditionCount;

/// 单条前置条件的判定态。
/// ★三态：Unknown（无法确认）与 Unsatisfied（明确未满足）必须分清★——
/// 系统不提供查询、或探测实现尚未接入时，一律如实报 Unknown，绝不当作已满足（不谎报）。
typedef NS_ENUM(NSInteger, A2JITAutoPairingPreconditionState) {
    A2JITAutoPairingPreconditionStateUnknown     = 0,  ///< 无法确认（探测未接入 / 系统不提供查询）
    A2JITAutoPairingPreconditionStateSatisfied   = 1,  ///< 已满足
    A2JITAutoPairingPreconditionStateUnsatisfied = 2,  ///< 明确未满足
};

// ---------------------------------------------------------------------------
// 自研 RPPairing 的可观测步骤（失败分类按步骤落点）
// ---------------------------------------------------------------------------

/// 自动配对的执行步骤（一条链：发现 → RSD → pair-verify → TLS-PSK → 写文件）。
typedef NS_ENUM(NSInteger, A2JITAutoPairingStep) {
    A2JITAutoPairingStepIdle       = 0,  ///< 未开始
    A2JITAutoPairingStepDiscovery  = 1,  ///< ① Bonjour 广告发现本机 RSD 广播
    A2JITAutoPairingStepRSDConnect = 2,  ///< ② 连接 RSD（RemoteServiceDiscovery）端口
    A2JITAutoPairingStepPairVerify = 3,  ///< ③ pair-verify（曲线验签，建立信任）
    A2JITAutoPairingStepTunnel     = 4,  ///< ④ 建立 TLS-PSK 隧道
    A2JITAutoPairingStepWriteFile  = 5,  ///< ⑤ 把配对材料写入容器约定位置
    A2JITAutoPairingStepDone       = 6,  ///< ⑥ 完成（可交给判据内核复验并开启 JIT）
};

// ---------------------------------------------------------------------------
// 失败 / 阻塞分类（★映射到现有 A2JITFailureReason 体系★）
// ---------------------------------------------------------------------------

/// 阻塞 / 失败分类。前 6 项是前置条件类（可先于任何网络动作判定），
/// 其余按步骤落点细分 —— 供 UI「按原因分流」文案，不写成一句万能文案。
typedef NS_ENUM(NSInteger, A2JITAutoPairingBlocker) {
    A2JITAutoPairingBlockerNone                    = 0,   ///< 无阻塞
    A2JITAutoPairingBlockerSystemTooOld            = 1,   ///< 非 iOS 27+（本路径不适用）→ SystemTooOld
    A2JITAutoPairingBlockerDeveloperModeOff        = 2,   ///< Developer Mode 未开 → PairingMissing
    A2JITAutoPairingBlockerLocalNetworkDenied      = 3,   ///< 本地网络权限未授予 → PairingMissing
    A2JITAutoPairingBlockerGetTaskAllowMissing     = 4,   ///< 签名缺 get-task-allow → PairingMissing
    A2JITAutoPairingBlockerDDIMissing              = 5,   ///< 缺 DDI（首次需联网）→ PairingMissing
    A2JITAutoPairingBlockerPreconditionUnconfirmed = 6,   ///< 前置条件无法确认（探测未接入）→ PairingMissing
    A2JITAutoPairingBlockerEngineUnavailable       = 7,   ///< RPPairing 引擎未接入 → AutoPairingNotBuilt
    A2JITAutoPairingBlockerDiscoveryFailed         = 8,   ///< 未发现 RSD 广播 → PairingMissing
    A2JITAutoPairingBlockerRSDConnectFailed        = 9,   ///< RSD 端口连不上 → PairingMissing
    A2JITAutoPairingBlockerPairVerifyFailed        = 10,  ///< pair-verify 失败 → PairingMissing
    A2JITAutoPairingBlockerTunnelFailed            = 11,  ///< TLS-PSK 隧道建立失败 → TunnelUnreachable
    A2JITAutoPairingBlockerWriteFailed             = 12,  ///< 配对材料写出失败 → PairingMissing
    A2JITAutoPairingBlockerStalePairingFile        = 13,  ///< 已有配对文件但已过期 → PairingMissing
};

// ---------------------------------------------------------------------------
// 前置条件判定结果（不可变值对象）
// ---------------------------------------------------------------------------

/// 前置条件四项的判定结果（★不可变、可单测★）。
@interface A2JITAutoPairingPreconditions : NSObject

/// 显式构造四项判定态。
+ (instancetype)preconditionsWithDeveloperMode:(A2JITAutoPairingPreconditionState)developerMode
                                  localNetwork:(A2JITAutoPairingPreconditionState)localNetwork
                                  getTaskAllow:(A2JITAutoPairingPreconditionState)getTaskAllow
                                           ddi:(A2JITAutoPairingPreconditionState)ddi;

/// 四项全 Unknown（★探测未接入时的如实取值——不是「已满足」★）。
+ (instancetype)unknownPreconditions;

/// 四项全 Satisfied（单测 / 假装配用）。
+ (instancetype)allSatisfiedPreconditions;

/// 取某条前置条件的判定态。
- (A2JITAutoPairingPreconditionState)stateForPrecondition:(A2JITAutoPairingPrecondition)precondition;

/// 第一条【明确未满足】的前置条件（无则 nil）。
- (nullable NSNumber *)firstUnsatisfiedPrecondition;
/// 第一条【无法确认】的前置条件（无则 nil；仅在无未满足项时有意义）。
- (nullable NSNumber *)firstUnconfirmedPrecondition;
/// 四项是否【全部明确满足】。
- (BOOL)allSatisfied;

@end

// ---------------------------------------------------------------------------
// 【注入点】设备内自动配对引擎（RPPairing）
// ---------------------------------------------------------------------------

/// 自动配对引擎。真机实现经 Bridge 落到 Natives（本单为定义调用点的骨架；
/// ★骨架必须如实报「未接入」，绝不假成功★）。
@protocol A2JITAutoPairingEngine <NSObject>

@required

/// 引擎是否已编译 / 接线（RPPairing 真实现是否可用）。
- (BOOL)isEngineAvailable;

/// 读取当前前置条件（Developer Mode / 本地网络 / get-task-allow / DDI）。
/// ★取不到的项一律回 Unknown★（绝不把「没探测到」报成「已满足」）。
- (A2JITAutoPairingPreconditions *)readPreconditions;

/// ★有界★生成配对文件并把配对材料写入注入的存储（容器约定位置）。
/// 成功返回 YES；失败返回 NO 并回填可读原因与分类。
/// ★调用方保证不在主线程；预算由调用方给出（超时即失败，绝不无限等）★。
/// @param budget     最长允许耗时（秒）。
/// @param whyOut     可读原因 / 取证（可为 NULL 指针）。
/// @param blockerOut 失败分类（可为 NULL 指针）。
- (BOOL)generatePairingFileWithinBudget:(NSTimeInterval)budget
                                 reason:(NSString *_Nullable *_Nullable)whyOut
                                blocker:(A2JITAutoPairingBlocker *_Nullable)blockerOut;

@end

NS_ASSUME_NONNULL_END
