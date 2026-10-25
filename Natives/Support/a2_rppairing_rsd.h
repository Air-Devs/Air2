//
//  a2_rppairing_rsd.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— [JIT-AUTOPAIR-2] RPPairing 的「发现 / 连接 / 线上消息 / TLS-PSK」层。
//
//  依据（公开协议描述 §2/§3/§8/§11/§12，来源见 a2_rppairing.h 顶部）：
//    · §2 三条连接路径：2a USB/CoreDeviceProxy（走 RemoteXPC）、2b `_remoted._tcp`（RemoteXPC，
//      需 ncm）、2c `_remotepairing._tcp`（裸 RPPairing socket，端口通常 49152，**只支持 pair-verify**）。
//    · §3 裸 socket 的帧 = magic("RPPairing" 9B) + 2B 大端长度 + JSON；信封 = message.plain._0 /
//      message.streamEncrypted._0 + originatedBy + sequenceNumber；该路径的二进制一律 **base64** 字符串。
//    · §8 hostOptions(wireProtocolVersion=19, attemptPairVerify=true) → pairingData 事件（kind=verifyManualPairing）。
//    · §11 createListener（加密请求）⇒ 回 port，用来连 TLS-PSK 隧道。
//    · §12 隧道 = TLS 1.2 PSK，套件 0x00AF/0x008C，PSK = pair-verify 的 shared secret。
//
//  ★本单实现到哪一步（如实，有实测证据）★：
//    · 发现（NWBrowser）/连接（NWConnection）/帧读写/JSON 信封/pair-verify 消息流：**真实现**。
//    · TLS-PSK 隧道：★已打通「隧道本体」★——改走随仓 mbedTLS（Apache-2.0）后端，
//      见同目录 a2_tlspsk_mbedtls.m / a2_tlspsk_tunnel.{h,m} / a2_tlspsk_selftest.{h,m}：
//      真握手 + 协商断言（0x00AF/0x008C + TLSv1.2）+ 回环自检
//      （tests/Natives/run_tlspsk_tunnel_tests.py）。仍**未**验证的是设备侧互操作：
//      ① 设备是否接受非空 PSK identity（mbedTLS 表达不出空 identity，见
//      docs/ONDEVICE-PAIR.md §3）；② PSK 真值（pair-verify 的 shared secret）→ 隧道的接线
//      仍无调用方（属主线业务逻辑）。
//
//  ★与「不碰别的工作」的边界★：本文件只做「发现 + 连接 + 握手 + 产出配对文件」，
//    不含 DDI 取得/挂载，也不含 JIT↔建 VM 串联，更不实现 RSD service 的调用。
//

#import <Foundation/Foundation.h>
#import "a2_rppairing.h"

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// 服务类型与传输路径（公开规格 §2）
// ---------------------------------------------------------------------------

/// `_remotepairing._tcp`（裸 RPPairing socket；★只支持 pair-verify★）。
FOUNDATION_EXPORT NSString *const A2RPRSDServiceRemotePairing;
/// `_remoted._tcp`（RemoteXPC；需设备侧 ncm）。
FOUNDATION_EXPORT NSString *const A2RPRSDServiceRemoted;
/// `_remotepairing-pairable-host._tcp`（设备作为可配对宿主 —— App 侧做宿主时用）。
FOUNDATION_EXPORT NSString *const A2RPRSDServicePairableHost;

typedef NS_ENUM(NSInteger, A2RPRSDTransport) {
    A2RPRSDTransportUnknown     = 0,
    A2RPRSDTransportRawSocket   = 1,   ///< §2c：裸 socket + JSON 帧
    A2RPRSDTransportRemoteXPC   = 2,   ///< §2a/2b：RemoteXPC（HTTP/2 + XPC）
};

/// 服务类型 → 传输路径。★未知服务类型回 Unknown（不猜）★。
A2RPRSDTransport A2RPRSDTransportForServiceType(NSString *serviceType);
/// 传输路径的诊断名（日志用；稳定字符串）。
NSString *A2RPRSDTransportName(A2RPRSDTransport transport);

/// 本仓支持的发现服务类型（顺序 = 尝试顺序）：先 2c（pair-verify 直连），再 2b。
NSArray<NSString *> *A2RPRSDDefaultServiceTypes(void);

// ---------------------------------------------------------------------------
// 流式帧读取（裸 socket：magic + 2B BE 长度 + JSON）
// ---------------------------------------------------------------------------

/// 把分片到达的字节喂进来，按帧切出载荷。★不足一帧时不报错（等更多数据）★，格式错才报错。
@interface A2RPRSDFrameReader : NSObject
/// 追加收到的字节。
- (void)appendData:(NSData *)data;
/// 缓冲里还剩多少字节。
@property (nonatomic, readonly) NSUInteger bufferedBytes;
/// 尝试切出一帧的载荷（JSON 字节）。
/// @return nil = 数据不够或出错；error 非空 ⇒ 确实是错（magic 不符等）；error 为 nil ⇒ 只是不够。
- (NSData *_Nullable)popFramePayloadWithError:(NSString *_Nullable *_Nullable)error;
@end

// ---------------------------------------------------------------------------
// JSON 消息（规格 §8 / §11 / §3 的信封）
// ---------------------------------------------------------------------------

/// §8 Step 1：hostOptions 请求（wireProtocolVersion = 19）。
NSDictionary<NSString *, id> *A2RPRSDHostOptionsRequest(BOOL attemptPairVerify);

/// §8 Step 2/7：pairingData 事件（kind = verifyManualPairing）。
NSDictionary<NSString *, id> *A2RPRSDPairingDataEvent(NSData *tlv,
                                                      NSString *kind,
                                                      BOOL startNewSession);

/// 从收到的 JSON 里取出 pairingData 的 TLV 字节。
/// 该路径下二进制是 base64 字符串（规格 §3），所以这里**先按 base64 解**，解不出再当原始字节。
/// 取不到 ⇒ nil 并回填原因。
NSData *_Nullable A2RPRSDTLVFromPairingDataEvent(NSDictionary<NSString *, id> *event,
                                                 NSString *_Nullable *_Nullable reason);

/// §11：createListener 请求（key = base64(encryption_key)，transportProtocolType = tcp）。
NSDictionary<NSString *, id> *A2RPRSDCreateListenerRequest(NSData *encryptionKey);

/// §11：从 createListener 响应里取端口（字符串或整数都接受）。取不到 ⇒ nil + 原因。
NSNumber *_Nullable A2RPRSDListenerPortFromResponse(NSDictionary<NSString *, id> *response,
                                                    NSString *_Nullable *_Nullable reason);

// ---------------------------------------------------------------------------
// TLS-PSK（§12）—— ★如实点名「公开 API 走不通」★
// ---------------------------------------------------------------------------

/// 设备要求的两个套件（规格 §12）。
#define A2RPRSDCipherSuitePSKAES256CBCSHA384 0x00AF
#define A2RPRSDCipherSuitePSKAES128CBCSHA    0x008C

/// 公开 TLS 栈能否满足 §12 的套件要求？★本仓实测结论 = NO★，理由写进 reason。
BOOL A2RPRSDPublicTLSPSKPathSufficient(NSString *_Nullable *_Nullable reason);

/// 按 §12 构造 Network.framework 的 PSK 参数（真调 `sec_protocol_options_add_pre_shared_key`：
/// PSK = pair-verify 的 shared secret，identity = 空）。★返回 nil ⇒ 构造失败（含原因）★。
/// 注意：即使构造成功，也**不代表**能与设备协商出 0x00AF/0x008C（见上面的能力探针）。
id _Nullable A2RPRSDTLSPSKParameters(NSData *psk, NSString *_Nullable *_Nullable reason);

// ---------------------------------------------------------------------------
// 发现 + 连接 + pair-verify（真实现；★只在有真端点的环境下才会成功★）
// ---------------------------------------------------------------------------

/// Bonjour 发现（NWBrowser）。所有方法都要在后台队列/有 runloop 的环境下调用。
@interface A2RPRSDDiscovery : NSObject

- (instancetype)initWithServiceTypes:(NSArray<NSString *> *)serviceTypes;

/// 在 budget 秒内等第一个可用端点（同步阻塞；调用方保证不在主线程上长时间占用）。
/// @return 非 nil ⇒ 已发现的端点（`nw_endpoint_t`，类型在头文件里不暴露，避免把 Network 依赖外泄）；
///         nil ⇒ 原因写进 reason（「未发现任何服务」/「发现但端点无地址」等，★不猜★）。
- (nullable id)waitForEndpointWithTimeout:(NSTimeInterval)budget
                                   reason:(NSString *_Nullable *_Nullable)reason;

/// 端点的可读描述（`ip:port` 或 Bonjour 名字；日志用）。
+ (NSString *)describeEndpoint:(id)endpoint;

/// 已发现端点的可读列表（日志用）。
@property (nonatomic, readonly, copy) NSArray<NSString *> *foundDescriptions;

- (void)stop;

@end

/// 一次「连上设备 → hostOptions → pair-verify(M1..M4) → 产出配对文件」的完整尝试。
@interface A2RPRSDPairVerifyClient : NSObject

/// 同步执行（内部用信号量卡住 timeout）。
/// @param endpoint        A2RPRSDDiscovery 给出的端点对象。
/// @param devicePublicKey 设备侧 Ed25519 公钥（来自既有配对记录/certificate）。
///        ★公开规格 §8 Step 6 明确写着设备那份证明「可不解」★，所以传 nil 也允许 ——
///        此时不做身份签名校验（会被如实记录在 reason 里），仍会做完密钥交换。
/// @return 成功 ⇒ 一个**新生成**的 Ed25519 身份（规格 §7：配对记录里的签名密钥在成功握手后为新值）；
///         失败 ⇒ nil 且 reason 点名卡在哪一步（连接/握手/对端拒绝）。
+ (nullable A2RPPairingIdentity *)pairVerifyWithEndpoint:(id)endpoint
                                           localIdentity:(A2RPPairingIdentity *)localIdentity
                                         devicePublicKey:(NSData *_Nullable)devicePublicKey
                                                 timeout:(NSTimeInterval)timeout
                                                  reason:(NSString *_Nullable *_Nullable)reason;

@end

NS_ASSUME_NONNULL_END
