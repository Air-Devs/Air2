//
//  A2JITHelperBridge.h
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Bridge —— ★主 App 侧「拉起内建 JIT helper appex」的唯一实现★
// ----------------------------------------------------------------------------
//  ★为什么要独立进程★：一个进程不能同步地调试自己（自 attach 会永久卡死），
//  所以 StikJIT.framework 绝不能在主 App 里 attach 本进程。可行形态只有一个：
//  把 debugger 那一半放进随包的 appex（PlugIns/Air2JITHelper.appex）里，由主 App
//  用私有 NSExtension API 拉起，再让它反向 attach 主 App。
//
//  ★本文件的三个纯函数 + 一个判据★（对应 Henge ios/Henge/JIT/JITBuiltIn.swift:66-105
//  的 `HengeBuiltInJIT.send` 与 JITBuiltIn.swift:128-161 的 `HelperRequest.begin`）：
//    ① requestDataWithOperation:…  —— 写请求（纯 JSON 编码，不碰系统）
//       调用点：Air2/Player/A2StikJITProvider.m `+enableBuiltInJITWithBudget:reason:`
//               替换掉现在的 `a2_stikjit_enable_jit(getpid(), …)`（第 260 行）。
//    ② startWithRequestData:completion: —— 触发扩展（真正的进程拉起 + 保活）
//       调用点：同上，紧接 ① 之后；`enable` 会一直挂着，直到 helper 反向 attach 完
//               并 detach，所以★回调可能在几十秒后★才来。
//    ③ responseFromPayload:error:  —— 读应答（纯 JSON 解码）
//       调用点：② 的 completion 里（本类内部已调用一次），调用方要用到
//               txmPresent 等字段时可直接复用。
//    ④ unavailableReason —— 用前判据（iOS 版本 / LiveContainer / 扩展 API 是否在）。
//       调用点：② 内部第一句；UI 侧 `+[A2StikJITProvider unavailableReason]` 可直接复用。
//
//  ★谁调它·哪一行★
//    Air2/Player/A2StikJITProvider.m:260（现有自 attach）→ 换成 ①②
//    Air2/Player/A2StikJITProvider.m:216（现有 unavailableReason）→ 可并到 ④
//
//  ★前置（调用方负责，本层不猜）★
//    · iOS 26+（扩展点 com.apple.ar.viewer + XPCService 形态更低版本没有）
//    · 不在 LiveContainer 里（getenv("LC_HOME_PATH") ⇒ 扩展起不来）
//    · 配对文件（RPPairing plist）已由用户导入；JIT 脚本已读到 base64
//    · 本机 LocalDevVPN 已连（StikJIT 通过它把 RSD 暴露到回环）
//    · StikJIT.framework 随包在 <App>/Frameworks/（appex 用 @rpath 找它）
//
//  ★线程★：② 可在任意线程调用（内部把「拉起」那一步切到主线程），回调在主线程。
//          ①②③ 都不阻塞；真正的阻塞在 helper 进程里。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 请求类型（raw value 与 JSON 里的 "operation" 逐字对应，见 A2JITHelperMessages.swift）。
typedef NS_ENUM(NSInteger, A2JITHelperOperation) {
    /// 探 LocalDevVPN 可达性 + 下载/挂载/校验 DDI（真正开 JIT 之前的一步）。
    A2JITHelperOperationPrepare = 0,
    /// attach 目标进程并跑 JIT 脚本，直到脚本 detach（请求会一直挂着）。
    A2JITHelperOperationEnable = 1,
    /// 清掉 appex 容器里的 DDI 缓存。
    A2JITHelperOperationResetDDI = 2,
};

/// 错误域。code 见 .m 里 `A2JITHelperError()` 的调用点（1 不可用 / 2 扩展找不到 /
/// 3 没有 NSExtension API / 4 请求编不出来 / 5 被取消 / 6 被中断 / 7 没起来 / 8 没应答）。
FOUNDATION_EXPORT NSString *const A2JITHelperErrorDomain;

/// 随包 appex 的目录名（PlugIns/ 下）。
FOUNDATION_EXPORT NSString *const A2JITHelperBundleName;

/// IPC 的两个 key（= A2JITHelperMessages.swift 里的 itemKey；两侧必须逐字一致）。
FOUNDATION_EXPORT NSString *const A2JITHelperRequestItemKey;
FOUNDATION_EXPORT NSString *const A2JITHelperResponseItemKey;

/// 应答 JSON 的字段名（helper 侧 Codable 的 property 名）。
FOUNDATION_EXPORT NSString *const A2JITHelperResponseSuccessKey;
FOUNDATION_EXPORT NSString *const A2JITHelperResponseMessageKey;
/// appex 回的整数码（Response.code）。文本由桥按码映射，不再让 appex 回任意字符串。
FOUNDATION_EXPORT NSString *const A2JITHelperResponseCodeKey;
FOUNDATION_EXPORT NSString *const A2JITHelperResponseTXMPresentKey;

@interface A2JITHelperBridge : NSObject

/// ④ 判据：nil = 现在可以用；非 nil = 不能用的可读原因。
+ (nullable NSString *)unavailableReason;

/// ① 写请求：把参数编成 helper appex 期待的 JSON（Data）。
/// `enable` 要求 targetPID>0、pairingData 非空、scriptBase64 非空；`prepare` 要求
/// pairingData 非空；`resetDDI` 不需要别的。参数不合法 ⇒ 返回 nil 并填 error（code 4）。
+ (nullable NSData *)requestDataWithOperation:(A2JITHelperOperation)operation
                                   targetPID:(int32_t)targetPID
                                 pairingData:(nullable NSData *)pairingData
                                scriptBase64:(nullable NSString *)scriptBase64
                                     rsdPort:(nullable NSNumber *)rsdPort
                                deviceAddress:(nullable NSString *)deviceAddress
                                       error:(NSError *_Nullable *_Nullable)error;

/// ② 触发扩展：用私有 NSExtension API 拉起 appex 并把请求作为 NSExtensionItem 送进去。
/// 返回值 = 「已受理」（进程能否起来、JIT 成没成一律走 completion）。
/// completion 恰好一次：response = ③ 解出的字典（success/message/txmPresent），
/// 或者 error 非空（进程没起来 / 被取消 / 被中断 / 没应答）。
+ (BOOL)startWithRequestData:(NSData *)requestData
                  completion:(void (^)(NSDictionary<NSString *, id> *_Nullable response,
                                       NSError *_Nullable error))completion;

/// ③ 读应答：把 helper 回传的 JSON 解成字典；`success`/`message` 类型不对或载荷为空
/// ⇒ 返回 nil 并填 error（code 8）。
+ (nullable NSDictionary<NSString *, id> *)responseFromPayload:(nullable NSData *)payload
                                                         error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
