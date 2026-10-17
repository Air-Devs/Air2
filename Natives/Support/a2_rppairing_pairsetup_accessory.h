//
//  a2_rppairing_pairsetup_accessory.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— [A2-PAIRWIRE] iOS 27「设备发起配对」的★最后一跳★：
//  把 pairable-host 广告（A2RPPairableHostAdvertiser）与 pair-setup 的
//  ★accessory/device 侧★会话（A2RPPairSetupSession）接到一起，
//  跑完 PS-Msg01..06 并交出★配对文件字节★（落盘由调用方的 store 负责，本层不碰存储）。
//
//  ── 角色与方向（★公开规格口径，不是本仓能改的设计选择★）──
//    · 本机广告 `_remotepairing-pairable-host._tcp` ⇒ 本机是 pairable-host ⇒ ★accessory 侧★；
//    · 连入的对端（iOS 设备的系统配对栈）是 rppairing 的 host/controller；
//    · ★会话由对端发起★：对端先发 PS-Msg01，本机（responder）收完回 PS-Msg02……
//      ⇒ 本层是【先收后发】的显式驱动循环（与 Host 侧 runHostOverTransport: 的【先发后收】相反）。
//
//  ── 传输缝（A2RPPairSetupMessageTransport）★不改其既有语义★ ──
//    · Host 侧驱动继续只用它既有的 `exchangePairingData:kind:startNew:reason:`（发一条、收下一条）；
//    · Accessory 侧驱动改用它的★两个可选原语★（见 a2_rppairing_pairsetup.h）：
//        `receivePairingDataWithKind:timeout:reason:`（只收）
//        `sendPairingData:kind:startNew:reason:`     （只发）
//      ★缝未实现这两个原语 ⇒ 本层如实失败（不假装能收/能发）★，
//      绝不靠偷改既有 `exchangePairingData:` 的语义来适配 responder。
//
//  ── 做到 / 做不到（如实，绝不假成功）──
//    · 做到：生成新主机身份/altIRK → 起广告 → 等系统连入 → 建传输 → accessory 侧 PS-Msg01..06
//      → 交出配对文件字节；六类失败分类；广告/连入/每步/成败★逐条判据行★；
//      注入假广告器 + 假传输即可在 macOS 上把整条链真跑（tests/JIT/pairwire_tests.m）。
//    · 做不到（★本会话无真机★）：与 iOS 27 真设备互操作 —— 「设置里是否真的出现配对入口」
//      「对端是否接受我们的帧」★未验证★，不得声称验证过。
//    · 进程被挂起时的后台保活（BGTaskScheduler / `.pairing.session`）★属 App 层接线★，
//      本层不假装拥有它：被连入前的等待一旦落到 Suspended 就如实分类。
//    · 取消是【协作式】的：置标志 + `stop` 拆监听；正在阻塞的那一次等待会在其预算内返回后才停
//      （★不声称能瞬间中断系统调用★；不做跨线程 cancel 正在等待的 listexer，那会踩 use-after-stop）。
//

#import <Foundation/Foundation.h>
#import "a2_remotexpc_session.h"                 // A2RPByteStream
#import "a2_rppairing_pairsetup.h"               // A2RPPairSetupStep / A2RPPairSetupMessageTransport
#import "a2_rppairing_pairsetup_transport.h"     // A2RPPairSetupRemoteXPCTransport（生产传输）
#import "a2_rppairing_pairable_host.h"           // A2RPPairableHostAdvertiser / A2RPPairableHostFailure

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 判据行（[A2-PAIRPIN]，★与 Player 侧同一标记★）

/// 判据行前缀。★同一标记在 Player 侧（A2JITPairingCodeSession）也出现★ ——
/// 两处各自书写字面量，是为了不引入 Natives → Player 的反向依赖（ADR-002）。
/// 真机判据：`grep '\[A2-PAIRPIN\]' latestlog.txt`（控制台归档）或 `lastlog.txt`（会话日志，
/// 「运行日志」页读的那一份）—— 两者都命中，因为本行的出口是统一的判据行出口。
FOUNDATION_EXPORT NSString *const A2RPPairWireCriterionMarker;

/// 打一行判据行（前缀 + 内容；★默认可见★，独立于任何 verbose 开关）。
void A2RPPairWireCriterionLog(NSString *line);

#pragma mark - 失败分类

/// 一轮配对的阶段（★UI 的「等待设备连入 / 等设备输码 / 已配对 / 失败」都从它上来★）。
typedef NS_ENUM(NSInteger, A2RPPairSetupAccessoryPhase) {
    A2RPPairSetupAccessoryPhaseStarting    = 0,  ///< 生成本轮主机身份 / altIRK
    A2RPPairSetupAccessoryPhaseAdvertising = 1,  ///< 已起广告，★等设备连入★（用户此刻去系统设置）
    A2RPPairSetupAccessoryPhaseConnected   = 2,  ///< ★已被连入★
    A2RPPairSetupAccessoryPhaseVerifying   = 3,  ///< 正在跑 PS-Msg01..06（等设备输码/验码）
    A2RPPairSetupAccessoryPhaseSucceeded   = 4,  ///< 配对成功
    A2RPPairSetupAccessoryPhaseFailed      = 5,  ///< 失败（分类见 detail）
    A2RPPairSetupAccessoryPhaseCancelled   = 6,  ///< 被取消
};
NSString *A2RPPairSetupAccessoryPhaseName(A2RPPairSetupAccessoryPhase phase);

/// 阶段/步进观察者：phase=当前阶段；step=会话步（非会话阶段为 Idle）；line=判据行内容（已含前缀）。
typedef void (^A2RPPairSetupAccessoryObserver)(A2RPPairSetupAccessoryPhase phase,
                                               A2RPPairSetupStep step,
                                               NSString *line);

/// accessory 侧一轮配对的失败分类（★失败必须能归到一类，供 UI/判据分流★）。
typedef NS_ENUM(NSInteger, A2RPPairSetupAccessoryFailure) {
    A2RPPairSetupAccessoryFailureNone = 0,
    A2RPPairSetupAccessoryFailureIdentityFailed,            ///< 生成主机身份/altIRK 失败
    A2RPPairSetupAccessoryFailureAltIRKUnavailable,         ///< CSPRNG 取不到 16 字节 altIRK
    A2RPPairSetupAccessoryFailureNoLocalNetworkPermission,  ///< 本地网络权限被拒（发布必失败）
    A2RPPairSetupAccessoryFailureSuspended,                 ///< 进程被挂起（通告后未等到连入）
    A2RPPairSetupAccessoryFailureWaitTimedOut,              ///< 预算内没有设备连入
    A2RPPairSetupAccessoryFailurePublishFailed,             ///< 其它发布失败
    A2RPPairSetupAccessoryFailureAcceptFailed,              ///< 连入了但取不出字节通道
    A2RPPairSetupAccessoryFailureTransportFailed,           ///< 建 remoteXPC 传输失败
    A2RPPairSetupAccessoryFailurePinMissing,                ///< 本机没有可用的 6 位码
    A2RPPairSetupAccessoryFailureWrongPin,                  ///< 对端证明校验不过（码不对 / 被篡改）
    A2RPPairSetupAccessoryFailureProtocolError,             ///< 非 TLV8 / 缺字段 / 乱序 / 签名不过
    A2RPPairSetupAccessoryFailureSessionTimedOut,           ///< 会话中途对端不再回（超时）
    A2RPPairSetupAccessoryFailureNotEstablished,            ///< 走完消息流仍不在已建立态
    A2RPPairSetupAccessoryFailurePairingFileUnavailable,    ///< 成功但产不出配对文件字节
    A2RPPairSetupAccessoryFailureCancelled,                 ///< 被取消（协作式）
};

/// 失败分类的稳定诊断名（判据行用，与 [A2-PAIRPIN] 同前缀行内出现）。
NSString *A2RPPairSetupAccessoryFailureName(A2RPPairSetupAccessoryFailure failure);

#pragma mark - 广告器抽象（真实现 = A2RPPairableHostAdvertiser；单测用假广告器）

/// ★广告器抽象缝★：本层只认这些成员。既有 A2RPPairableHostAdvertiser 已全部具备 ⇒
/// 下方以分类（category）声明遵守，★不改既有类★。
@protocol A2RPPairSetupAccessoryListener <NSObject>
@property (nonatomic, readonly, copy) NSString *serviceName;
@property (nonatomic, readonly, copy) NSString *hostName;
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly) A2RPPairableHostFailure failure;
@property (nonatomic, readonly, copy, nullable) NSString *failureReason;
@property (nonatomic, readonly) BOOL systemSawService;
- (nullable id<A2RPByteStream>)advertiseAndWaitForDeviceWithBudget:(NSTimeInterval)budget
                                                            reason:(NSString *_Nullable *_Nullable)reason;
- (void)stop;
@end

/// 既有通告器遵守本缝（★只加声明，不改实现★）。
@interface A2RPPairableHostAdvertiser (A2RPPairSetupAccessory) <A2RPPairSetupAccessoryListener>
@end

/// 造一个广告器（生产 = A2RPPairableHostAdvertiser；单测 = 假广告器）。
typedef id<A2RPPairSetupAccessoryListener> _Nullable (^A2RPPairSetupAccessoryListenerFactory)(
    NSString *name, NSString *model, NSString *identifier, NSData *altIRK);

/// 用被接受的字节通道造一个 pair-setup 消息传输（生产 = RemoteXPC(§2a/§2b)）。
typedef id<A2RPPairSetupMessageTransport> _Nullable (^A2RPPairSetupAccessoryTransportFactory)(
    id<A2RPByteStream> stream, NSString *hostName, NSString *_Nullable *_Nullable reason);

#pragma mark - 一轮的结果（值对象；★不可变★）

@interface A2RPPairSetupAccessoryRun : NSObject
@property (nonatomic, readonly) A2RPPairSetupAccessoryFailure failure;
@property (nonatomic, readonly, copy) NSString *detail;                 ///< 可读原因/取证
@property (nonatomic, readonly, copy, nullable) NSData *pairingFileData;///< 成功才有（交给调用方的 store 落盘）
@property (nonatomic, readonly, copy, nullable) NSString *identifier;   ///< 本次新主机身份 identifier
@property (nonatomic, readonly, copy, nullable) NSString *advertisedName;  ///< 通告用的显示名
@property (nonatomic, readonly, copy, nullable) NSString *hostName;     ///< 通告的主机名（判据行用）
@property (nonatomic, readonly, copy, nullable) NSString *serviceName;  ///< mDNS 实例名（= identifier 截断）
@property (nonatomic, readonly) uint16_t port;                          ///< 通告端口（未就绪为 0）
@property (nonatomic, readonly, copy, nullable) NSString *authTagBase64;///< TXT 里那个 authTag
@property (nonatomic, readonly) BOOL advertised;                        ///< 是否真的进入 advertising
@property (nonatomic, readonly) BOOL connected;                         ///< 是否被系统连入
@property (nonatomic, readonly) A2RPPairSetupStep lastStep;             ///< 会话走到哪一步
@property (nonatomic, readonly) BOOL succeeded;
@end

#pragma mark - 驱动

@interface A2RPPairSetupAccessory : NSObject

/// ★唯一的驱动函数★（可注入缝，供单测把整条链真跑）。
/// @param hostName        展示/身份用的主机名（用户在设置列表里靠它认出我们）。
/// @param pin             本机正在显示的 6 位码（★空 ⇒ 如实失败 PinMissing★，不猜不默认）。
/// @param budget          整轮最长耗时（秒）；广告等待从它切分（会话另有各自的原语超时）。
/// @param listenerFactory 造广告器。
/// @param transportFactory 用被接受的字节通道造消息传输。
/// @param observer        阶段/步进观察者（可为 nil）：每进入一个阶段、每有一条消息进/出都回调一次。
///                        可在任意线程被调用；实现方自行回主线程。
/// @param isCancelled     轮询点（可为 nil）：返回 YES ⇒ 尽快停下来并如实回 Cancelled（协作式，见头文件）。
+ (A2RPPairSetupAccessoryRun *)runWithHostName:(NSString *)hostName
                                           pin:(NSString *)pin
                                        budget:(NSTimeInterval)budget
                               listenerFactory:(A2RPPairSetupAccessoryListenerFactory)listenerFactory
                              transportFactory:(A2RPPairSetupAccessoryTransportFactory)transportFactory
                                      observer:(nullable A2RPPairSetupAccessoryObserver)observer
                                   isCancelled:(nullable BOOL (^)(void))isCancelled;

/// 生产装配：真广告器（A2RPPairableHostAdvertiser）+ 真传输（RemoteXPC，originatedBy=device）。
/// ★谁调它★：Air2/Bridge/A2JITAutoPairingEngineBridge.m 的设备发起档入口（唯一调用点）。
+ (A2RPPairSetupAccessoryRun *)runWithHostName:(NSString *)hostName
                                           pin:(NSString *)pin
                                        budget:(NSTimeInterval)budget
                                      observer:(nullable A2RPPairSetupAccessoryObserver)observer
                                   isCancelled:(nullable BOOL (^)(void))isCancelled;

/// 本路径通告的显示名默认值（`Air2 (<hostname>)`；用户在系统设置列表里认这个）。
+ (NSString *)defaultAdvertisedNameForHostName:(NSString *)hostName;

@end

NS_ASSUME_NONNULL_END
