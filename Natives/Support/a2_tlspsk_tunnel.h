// ============================================================================
//  Natives/Support/a2_tlspsk_tunnel.h
//  Air2 —— [A2-INTEGRATION] TLS-PSK 隧道 ●可替换接口●（RPPairing 规格 §12）
// ----------------------------------------------------------------------------
//  本接口只做一件事：把「TLS-PSK 隧道」这一件事封在一个后端可替换的门面后：
//     建连(connect) / 发帧(sendFrame) / 收帧(receiveFrame) / 关(close)。
//  ★设计目标（用户拍板）★
//    · 走【第三方 mbedTLS（Apache-2.0）】实现，不手写 TLS —— 见同目录 a2_tlspsk_mbedtls.m；
//    · 封在接口后 ⇒ ★日后可换自写实现而不动任何调用方★（换后端只改 registerBackend:）；
//    · ★默认关★：isEnabled 默认 NO，未打开时 connect 一律如实拒绝（reason 点名「开关未开」）；
//    · ★不谎报★：没有可用后端 / 地址策略拒绝 / 握手失败，都【如实】返回 NO + 具体原因，
//      绝不静默成功、绝不假报已连；
//    · ★不上云★：默认主机策略只允许「本机 / 私有网段 / 链路本地 / .local(Bonjour)」
//      （见 A2TLSPskDefaultHostPolicy）—— 任何公网地址一律拒绝并如实记录，杜绝云中继。
//
//  ★调用点（谁调它·哪一行）★
//    · 生产：`Air2/Bridge/A2JITAutoPairingEngineBridge.m` 的 TLS-PSK 口径块
//      （`A2TLSPskMbedTLSEnsureRegistered()` → `[A2TLSPskTunnel statusLine]`）——真机诊断日志逐行可核；
//    · 自证：`tests/JIT/jit_logic_tests.m` 的 [A2-INTEGRATION] 例（默认关 + 不谎报 + 不上云）。
//  本文件之前 **无同职责实现**（旧的 `A2RPRSDPublicTLSPSKPathSufficient` 只对「公开 TLS 栈
//  给不出 §12 套件」这一事实做点名，不提供隧道本体）⇒ 不是重复造轮子。
//
//  许可：本文件归 Air2 项目本人；所依赖的 mbedTLS 为第三方（Apache-2.0，见
//        Libraries/ThirdParty/mbedtls/LICENSE 与 docs/DEPENDENCIES.md）。
// ============================================================================
#ifndef A2_TLSPK_TUNNEL_H
#define A2_TLSPK_TUNNEL_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 隧道状态（如实反映，不用它做「已连」的假象）。
typedef NS_ENUM(NSInteger, A2TLSPskTunnelState) {
    A2TLSPskTunnelStateIdle      = 0,  // 未建连（含「开关未开」/「无后端」）
    A2TLSPskTunnelStateReady     = 1,  // 已完成 PSK 握手，可以收发帧
    A2TLSPskTunnelStateClosed    = 2,  // 已关闭（调用方或对端）
    A2TLSPskTunnelStateFailed    = 3,  // 建连/收发失败（reason 点名）
};

/// ★可替换后端协议★ —— 只有「建连 / 发帧 / 收帧 / 关」四件事。
/// 换实现（例如日后自写 TLS 1.2 PSK）只需实现本协议并 registerBackend:，调用方零改动。
@protocol A2TLSPskTunnelBackend <NSObject>
@required
/// 后端名（日志用；如 «mbedTLS 3.6.2»）。★不得虚标版本/能力★。
- (NSString *)backendName;
/// 后端此刻是否可用。★不谎报★：不可用时 reason 必须具体（缺库/未编译/初始化失败…）。
- (BOOL)isAvailableWithReason:(NSString *_Nullable *_Nullable)reason;
/// 建连并完成 PSK 握手。identity 为空串表示「无 identity」（规格 §12 设备侧约定）。
- (BOOL)connectToHost:(NSString *)host
                 port:(uint16_t)port
                  psk:(NSData *)psk
             identity:(NSString *)identity
              timeout:(NSTimeInterval)timeout
               reason:(NSString *_Nullable *_Nullable)reason;
/// 发一帧。★帧格式由本层约定★：4 字节大端长度前缀 + 载荷。
- (BOOL)sendFrame:(NSData *)frame
          timeout:(NSTimeInterval)timeout
           reason:(NSString *_Nullable *_Nullable)reason;
/// 收一帧（返回去掉长度前缀的载荷）。超时/断开 ⇒ nil 且 reason 点名。
- (nullable NSData *)receiveFrameWithTimeout:(NSTimeInterval)timeout
                                      reason:(NSString *_Nullable *_Nullable)reason;
/// 主动关闭（幂等）。
- (void)close;

@optional
/// 协商到的套件（如 «0x00AF»）；未握手 ⇒ «-»。★是握手结果，不是配置值★。
- (NSString *)negotiatedCipherSuite;
/// 协商到的版本（如 «TLSv1.2»）；未握手 ⇒ «-»。
- (NSString *)negotiatedTLSVersion;
@end

/// 主机准入策略：返回 YES 才允许连。★默认 = 本机/私有网段/链路本地/.local（不上云）★。
typedef BOOL (^A2TLSPskHostPolicy)(NSString *host);

/// ★门面★：唯一对外的 TLS-PSK 隧道入口。
@interface A2TLSPskTunnel : NSObject

+ (instancetype)sharedTunnel;

/// ★总开关，默认 NO★（用户拍板「默认关」）。未打开时 connect 一律拒绝并点名。
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;

/// 当前状态（如实）。
@property (nonatomic, readonly) A2TLSPskTunnelState state;

/// ★握手结果★ 协商到的套件（如 «0x00AF»）；未握手 ⇒ «-»。由后端在握手成功后提供。
@property (nonatomic, readonly, copy) NSString *lastNegotiatedCipherSuite;
/// ★握手结果★ 协商到的版本（如 «TLSv1.2»）；未握手 ⇒ «-»。
@property (nonatomic, readonly, copy) NSString *lastNegotiatedTLSVersion;

/// 「版本 / 套件」一句话（如 «TLSv1.2 / 0x00AF»）；未握手 ⇒ «未握手»。★不谎报★。
- (NSString *)negotiatedSummary;

/// 注册/替换后端（幂等；后注册的覆盖先前的）。★可替换性的唯一入口★。
+ (void)registerBackend:(id<A2TLSPskTunnelBackend>)backend;

/// 当前后端名；无后端 ⇒ «未注册»（不谎报）。
+ (NSString *)backendName;

/// 当前是否可用（类方法，便于诊断处直接查）；不可用时 reason 具体。
+ (BOOL)isAvailableWithReason:(NSString *_Nullable *_Nullable)reason;

/// 便利函数（供诊断日志一行调用）：返回「后端名 + 可用性 + 开关」的一句话。
+ (NSString *)statusLine;

/// 主机准入策略（恒为默认策略，见 A2TLSPskDefaultHostPolicy）。
+ (A2TLSPskHostPolicy)hostPolicy;

/// 默认主机准入策略：本机/私有网段/链路本地/.local ⇒ YES；其余（公网）⇒ NO（★不上云★）。
BOOL A2TLSPskDefaultHostPolicy(NSString *host);

// ---- 实例操作（转发给已注册后端；未开/无后端 ⇒ 如实失败） ----
- (BOOL)connectToHost:(NSString *)host
                 port:(uint16_t)port
                  psk:(NSData *)psk
             identity:(nullable NSString *)identity
              timeout:(NSTimeInterval)timeout
               reason:(NSString *_Nullable *_Nullable)reason;
- (BOOL)sendFrame:(NSData *)frame
          timeout:(NSTimeInterval)timeout
           reason:(NSString *_Nullable *_Nullable)reason;
- (nullable NSData *)receiveFrameWithTimeout:(NSTimeInterval)timeout
                                      reason:(NSString *_Nullable *_Nullable)reason;
- (void)close;

@end

NS_ASSUME_NONNULL_END
#endif /* A2_TLSPK_TUNNEL_H */
