//
//  A2JITDDIProbe.h
//  Air2
//
//  Player —— DDI 前置条件的【判定合成】（纯逻辑：本地镜像 + 设备侧查询 ⇒ 三态）。
//
//  为什么单独一件：
//    · A2JITAutoPairing 的 DDI 那一项原来一律是 Unknown（探测未接线）；
//      本类把它变成【真三态】：已就位 / 缺失 / 无法确认。
//    · 判定规则只有一处实现（本类），设置页与单测都读它，避免「两处漂移」。
//
//  ★分层★：本类只依赖 A2JITDDIStore（本地文件系统）与 A2JITDDIDeviceQuery（注入缝）。
//  真正碰设备/网络的机制（个性化请求、image_mounter 挂载）由 Bridge 实现注入，
//  Player 侧只做「状态合成」。
//
//  许可：零第三方；★未搬运任何第三方代码★。
//

#import <Foundation/Foundation.h>
#import "A2JITDDI.h"

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// 注入缝（供设置页 / 编排层消费）
// ---------------------------------------------------------------------------

/// DDI 判定缝：给出一份 DDI 判定（含取证）。
@protocol A2JITDDIProbe <NSObject>

@required

/// 当前 DDI 判定。★无法确认就回 Unknown；绝不把「没探测到」报成 Present★。
- (A2JITDDIStatus *)ddiStatus;

@end

// ---------------------------------------------------------------------------
// 真实现（本地镜像 + 设备侧查询合成）
// ---------------------------------------------------------------------------

@class A2JITDDIStore;

/// 本地优先的 DDI 判定实现。
///
/// 规则（唯一实现，见 .m）：
///   ① 本地有【版本匹配且新鲜】的镜像 ⇒ Present（就位）；
///   ② 本地没有/不匹配/过期，但设备侧已确认有可用 DDI ⇒ Present；
///   ③ 本地明确不可用（缺失 / 版本不符 / 过期）且设备侧不可查 ⇒ 如实报该不可用态（缺失类）；
///   ④ 两边都无法确认（目录不可读 / 镜像未声明版本 / 设备侧未接线）⇒ Unknown。
@interface A2JITLocalDDIProbe : NSObject <A2JITDDIProbe>

/// 注入本地镜像存储、系统要求与（可空的）设备侧查询。
- (instancetype)initWithStore:(A2JITDDIStore *)store
                  requirement:(A2JITDDIRequirement *)requirement
                  deviceQuery:(nullable id<A2JITDDIDeviceQuery>)deviceQuery;

/// 本地镜像存储。
@property (nonatomic, readonly, strong) A2JITDDIStore *store;
/// 系统要求（版本 / 构建号 / 芯片 ID）。
@property (nonatomic, readonly, strong) A2JITDDIRequirement *requirement;
/// 设备侧查询（未接线 ⇒ nil；此时只报本地判定，并注明设备侧不可查）。
@property (nonatomic, readonly, strong, nullable) id<A2JITDDIDeviceQuery> deviceQuery;
/// 新鲜度窗口（秒；默认 A2JITDDI.defaultMaxAge）。
@property (nonatomic, readonly) NSTimeInterval maxAge;

/// 只跑【本地】那一半判定（供诊断 / 单测；不清楚设备侧）。
- (A2JITDDIVerdict)localVerdictWithEvidence:(NSString *_Nullable *_Nullable)evidenceOut;

/// ★联网取 DDI★ 的调用点（未接线 / 缺能力 ⇒ NO + 确切缺什么）。
- (BOOL)fetchPersonalizedImageWithReason:(NSString *_Nullable *_Nullable)reasonOut;
/// 挂载当前本地镜像的调用点（缺特权 / 未接线 ⇒ NO + 确切缺什么）。
- (BOOL)mountCurrentImageWithReason:(NSString *_Nullable *_Nullable)reasonOut;

@end

NS_ASSUME_NONNULL_END
