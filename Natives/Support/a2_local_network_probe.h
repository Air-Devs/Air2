//
//  a2_local_network_probe.h
//  Air2 —— [PAIRWIRE-NETPROBE] 「本地网络」权限自检探针
//
//  为什么需要它：iOS 没有公开 API 能查询「本地网络」权限是否已授予；
//  而设备发起配对（pairable-host 广告）一旦没权限，只会在 listener 上以 PublishFailed 失败，
//  用户看到的是笼统报错。本探针用「自建 Bonjour 服务 + 自己浏览自己」的通行做法间接判断：
//    · 起一个 NWListener，服务类型 _a2lnprobe._tcp（本地网络内的临时探针，不外泄任何信息）
//    · 同类型起一个 NWBrowser；浏览到任何结果 ⇒ 说明本地网络权限已给
//    · listener 失败 / 超时内没结果 ⇒ 未授权（或环境异常），如实分类返回
//
//  ★调用点（唯一）★：Air2/Bridge/A2JITAutoPairingEngineBridge.m 的
//  -startDeviceInitiatedPairingWithHostName:… 里（开始广告之前）。
//
//  iOS 14+；只用 Network.framework，不需要 multicast entitlement。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 跑一次自检。返回 YES = 已授权（浏览到探针服务）。
/// 失败时 *reason 给出可读分类：「未授权（listener 失败）」「超时未浏览到探针服务」「无法创建探针」…
BOOL A2LocalNetworkProbeRun(NSTimeInterval timeout, NSString *_Nullable *_Nullable reason);

/// 判据行（默认可见、可 grep）：[A2-PAIRPIN] netprobe=ok|denied|timeout reason=…
NSString *A2LocalNetworkProbeCriterionLine(NSString *verdict, NSString *_Nullable reason);

NS_ASSUME_NONNULL_END
