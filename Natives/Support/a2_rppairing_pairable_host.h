//
//  a2_rppairing_pairable_host.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— [A2-RXPC] iOS 27 的【设备发起配对】：本机当「可配对宿主（pairable host）」。
//
//  角色（★与 §2c 相反★，公开实现口径）：
//    · 本机广告 mDNS 服务 `_remotepairing-pairable-host._tcp`（常量复用 a2_rppairing_rsd.h 的
//      A2RPRSDServicePairableHost，不另造一个）；
//    · iOS 设备浏览到它 ⇒ 用户在【设置 › 隐私与安全性 › 开发者模式 › 与 XXX 配对】里连入，
//      并输入【本 App 显示的 6 位码】；
//    · 会话里【设备】扮演 rppairing 的 host（发 originatedBy: "host"，发起握手与 SRP pair-setup），
//      ★本机扮演 rppairing 的 device/accessory★（SRP 服务端）。
//    · 本机就是设备本身（回环）⇒ 连上的对端是本机，不存在外部电脑。
//    · 该路径通告的线上协议版本是 26（★不是 §2c/§2b 的 19★）。
//
//  协议出处（★只读行为/接口/公开规格常量，未搬运任何项目源码★）：
//    · 服务类型 `_remotepairing-pairable-host._tcp` 与 TXT 记录键
//      （name / identifier / authTag / model / flags / ver / minVer）；
//    · authTag = base64( 6 字节 )：SipHash-2-4( key = 16 字节 altIRK, msg = identifier ) 的
//      8 字节【小端】输出，取前 6 字节【逆序】；
//    · 服务实例名 = identifier，且 mDNS 实例名上限 30 字符；
//    · 该路径只需【本地网络】权限，★不需要 multicast entitlement★；
//    · 「每次配对都生成新的主机密钥（旧配对记录作废）」「超时中止（默认 5 分钟）」
//      「后台保活窗口约 30 秒」为公开文档口径（实现见 .m 注释）。
//
//  ★做到 / 做不到（如实，绝不假成功）★：
//    · 做到：TXT/authTag 的【真算法 + 公开测试向量自证】；NWListener 真广告（mDNSResponder）
//      与真接受连入；四类失败分类（无本地网络权限 / 被挂起 / 超时 / 密钥轮换）；判据行 [RXPC]。
//    · 后台保活（.pairing.session 继续处理任务）：★属 App 层的接线★（需 Info.plist 的
//      BGTaskSchedulerPermittedIdentifiers 与 UIApplication 的 background task）。本层不假装自己
//      做到了，只在 reason 里点名它没被持有。
//    · 与 iOS 27 真设备互操作未验证（本会话无真机）。
//

#import <Foundation/Foundation.h>
#import "a2_remotexpc_session.h"

NS_ASSUME_NONNULL_BEGIN

/// 通告的线上协议版本（★该路径 = 26；§2c/§2b 用 19★）。
#define A2RPPairableHostWireProtocolVersion 26
/// mDNS 服务实例名上限（公开实现显式放宽到 30）。
#define A2RPPairableHostServiceNameMaxLength 30
/// altIRK 的字节数（16）。
#define A2RPPairableHostAltIRKBytes 16
/// 默认配对超时（公开文档口径：5 分钟未完成即中止）。
#define A2RPPairableHostDefaultBudgetSeconds 300.0

#pragma mark - 纯逻辑：authTag / TXT / 服务名

/// SipHash-2-4：key 为 16 字节（按两个【小端】u64 取用）。
uint64_t A2RPSipHash24WithKey16(const uint8_t key[A2RPPairableHostAltIRKBytes],
                                const void *bytes, size_t length);

/// authTag（6 字节，未 base64）：SipHash-2-4(altIRK, identifier) 的 8 字节小端输出取前 6 字节逆序。
/// altIRK != 16 字节 ⇒ nil。
NSData *_Nullable A2RPPairableHostAuthTag(NSData *altIRK, NSString *serviceIdentifier);

/// 新的 altIRK（16 字节 CSPRNG）。★每次配对都应新生成（旧配对记录作废）★。
NSData *_Nullable A2RPPairableHostFreshAltIRK(void);

/// mDNS TXT 记录（键值均为字符串；与公开实现口径一致）。
/// @param name   设备上显示的名字（让用户认得出，如 "Air2"）。
/// @param model  型号标识（iOS 把本机当电脑 ⇒ 建议用 Mac 标识，如 "Mac17,7"）。
/// @param identifier 服务标识（= 配对文件的 identifier）。
NSDictionary<NSString *, NSString *> *A2RPPairableHostTXTRecords(NSString *name,
                                                                 NSString *model,
                                                                 NSString *identifier,
                                                                 NSData *altIRK);

/// 服务实例名：取 identifier，超长则截到 30 字符。
NSString *A2RPPairableHostServiceName(NSString *identifier);

#pragma mark - 失败分类

typedef NS_ENUM(NSInteger, A2RPPairableHostFailure) {
    A2RPPairableHostFailureNone = 0,
    A2RPPairableHostFailureNoLocalNetworkPermission, ///< 本地网络权限被拒（发布必失败）
    A2RPPairableHostFailureSuspended,                ///< 进程被挂起（通告后未等到连入）
    A2RPPairableHostFailureTimedOut,                 ///< 超过预算（默认 300s）
    A2RPPairableHostFailureKeyRotated,               ///< ★非错误★：本次用新主机密钥（旧配对记录作废）
    A2RPPairableHostFailurePublishFailed,            ///< 其它发布失败
    A2RPPairableHostFailureAcceptFailed,             ///< 接受到了连接但取不出字节通道
};

/// 失败分类的稳定诊断名（判据行用）。
NSString *A2RPPairableHostFailureName(A2RPPairableHostFailure failure);

#pragma mark - 通告器

/// 真广告 + 真接受连入（NWListener / mDNSResponder）。
@interface A2RPPairableHostAdvertiser : NSObject

- (instancetype)initWithName:(NSString *)name
                       model:(NSString *)model
                  identifier:(NSString *)identifier
                      altIRK:(NSData *)altIRK;

/// 是否已成功广告（listener 达到 ready）。
@property (nonatomic, readonly) BOOL advertising;
/// 通告端口（advertising 为 YES 时有效；0 表示未知）。
@property (nonatomic, readonly) uint16_t port;
/// 服务实例名（= identifier 截断到 30；判据行用）。
@property (nonatomic, readonly, copy) NSString *serviceName;
/// 主机名（判据行用；`.local.` 形式）。
@property (nonatomic, readonly, copy) NSString *hostName;
/// 系统是否「看见」了该服务（= 有连接被接受）。
@property (nonatomic, readonly) BOOL systemSawService;
/// 失败分类。
@property (nonatomic, readonly) A2RPPairableHostFailure failure;
/// 失败/备注原因（可读）。
@property (nonatomic, readonly, copy, nullable) NSString *failureReason;
/// 观察到的 listener 等待态（用于区分「被挂起」与「纯超时」）。
@property (nonatomic, readonly) BOOL observedWaitingState;

/// 广告并在 budget 秒内等系统连入（★同步阻塞★；调用方保证不在主线程长时间占用）。
/// @return 非 nil ⇒ 已被接受的字节通道（交给 pair-setup 的 device 侧会话驱动）；
///         nil ⇒ 原因写进 reason、分类写进 failure。
- (nullable id<A2RPByteStream>)advertiseAndWaitForDeviceWithBudget:(NSTimeInterval)budget
                                                            reason:(NSString *_Nullable *_Nullable)reason;

- (void)stop;

@end

#pragma mark - 判据行（[A2-RXPC] 整层的生产调用点）

/// ★生产调用点★：把 [A2-RXPC] 整层的就绪度与契约写进判据行（[RXPC]），并做一次【有界】的
/// 编解码自证（帧 / HPACK / XPC 往返）与 pairable-host 通告契约自证（authTag/txt/服务名）。
/// 谁调它：Air2/Bridge/A2JITAutoPairingEngineBridge.m 的生成路径（只加一行，见报告）。
/// ★无网络动作、无副作用、不做 5 分钟等待★。
void A2RXPCReportLayerReadiness(void);

NS_ASSUME_NONNULL_END
