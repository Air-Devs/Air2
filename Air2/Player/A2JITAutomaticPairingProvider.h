//
//  A2JITAutomaticPairingProvider.h
//  Air2
//
//  Player —— 取得路径 ①：【设备内自动配对】（iOS 27+）。
//
//  语义（用户拍板 / ADR-009；docs/JIT-PROVISIONING.md §1.2）：
//    iOS 27 起可【在本机自研 RPPairing】生成配对文件，不再需要 PC / 外部工具。
//    前置条件 = ① Developer Mode ② 本地网络权限（Bonjour）③ get-task-allow ④（首次）DDI。
//
//  [JIT-AUTOPAIR-1] 本单把「占位」换成【真能力探测 + 前置条件检查 + 配对文件存在性与新鲜度】：
//    · isAvailable   —— 能力检测（iOS ≥ 27；与事实一致，不看是否已配对）；
//    · isPairingReady—— ★真探测★：容器约定位置里有一份【新鲜】的可用配对文件才算就绪；
//    · preparePairingWithError: —— ★先查前置条件，再（有界）尝试生成★；
//      缺什么就报什么（Developer Mode / 本地网络 / get-task-allow / DDI / 探测未接入 …），
//      ★绝不假成功★（引擎未接入 / 前置未确认时如实失败并给出确切分类）；
//    · activateJITWithError:    —— 与 ②导入 同口径：真调判据内核复验（有界预算）。
//
//  ★边界★：本类不 import 任何 Natives 头（分层纪律）；RPPairing 的真实现经
//  Bridge → Natives 注入（本单为 A2JITAutoPairingEngine 协议 + Bridge 骨架）。
//  ★合规★：零新增第三方；★不参考 / 不搬运 SideInstaller 代码★（自定义许可，只可参考协议思路）。
//

#import <Foundation/Foundation.h>
#import "A2JITProvider.h"
#import "A2JITReadinessProbe.h"
#import "A2JITAutoPairing.h"
#import "A2JITDDIProbe.h"   // [JIT-DDI-1] DDI 前置条件的真探测（注入缝 + 判定合成）

@class A2JITFacts;
@class A2JITPairingFileStore;

NS_ASSUME_NONNULL_BEGIN

/// ① 设备内自动配对（iOS 27+）。
@interface A2JITAutomaticPairingProvider : NSObject <A2JITProvider>

/// 兼容旧装配：只注入事实（前置条件未知、无引擎 ⇒ 如实报「未接入」，不假装成功）。
- (instancetype)initWithFacts:(A2JITFacts *)facts;

/// ★装配用★：注入前置条件、RPPairing 引擎、配对文件存储与判据内核。
/// @param preconditions 前置条件四项的判定态（nil ⇒ 四项全 Unknown）。
/// @param engine        RPPairing 引擎（nil ⇒ 未接入，如实失败）。
/// @param store         配对文件存储（nil ⇒ 用容器默认位置）。
/// @param probe         判据内核（Bridge → Natives/A2JITEnvironment；nil ⇒ 开启时如实失败）。
- (instancetype)initWithFacts:(A2JITFacts *)facts
                preconditions:(nullable A2JITAutoPairingPreconditions *)preconditions
                       engine:(nullable id<A2JITAutoPairingEngine>)engine
                        store:(nullable A2JITPairingFileStore *)store
                        probe:(nullable id<A2JITReadinessProbe>)probe;

/// ★[JIT-DDI-1] 装配用（推荐）★：在上一版基础上再注入 DDI 真探测。
/// ★注入 ddiProbe 后，前置条件里的【DDI 那一项】以探测结果为准★
/// （可区分「已就位 / 缺失 / 无法确认」）；★探测回 Unknown 时仍报 Unknown，绝不猜成已满足★。
/// @param ddiProbe DDI 判定（nil ⇒ DDI 一项沿用注入的 preconditions 原值，如实保持 Unknown）。
- (instancetype)initWithFacts:(A2JITFacts *)facts
                preconditions:(nullable A2JITAutoPairingPreconditions *)preconditions
                       engine:(nullable id<A2JITAutoPairingEngine>)engine
                     ddiProbe:(nullable id<A2JITDDIProbe>)ddiProbe
                        store:(nullable A2JITPairingFileStore *)store
                        probe:(nullable id<A2JITReadinessProbe>)probe;

/// DDI 判定探测（未注入 ⇒ nil）。
@property (nonatomic, readonly, strong, nullable) id<A2JITDDIProbe> ddiProbe;

/// ★生效的前置条件★：注入值 +（有 ddiProbe 时）以探测结果覆盖 DDI 那一项。
- (A2JITAutoPairingPreconditions *)effectivePreconditions;

/// 最近一次 DDI 判定（未注入 ddiProbe 时为 nil）。
- (nullable A2JITDDIStatus *)ddiStatus;

/// 生成配对文件的有界预算（秒）。
@property (nonatomic, readonly) NSTimeInterval generationBudget;
/// 配对文件的新鲜度窗口（秒）。
@property (nonatomic, readonly) NSTimeInterval pairingFileMaxAge;
/// 最近一次执行到的步骤。
@property (nonatomic, readonly) A2JITAutoPairingStep lastStep;
/// 最近一次的阻塞 / 失败分类（无阻塞为 None）。
@property (nonatomic, readonly) A2JITAutoPairingBlocker lastBlocker;
/// 最近一次判据 verdict（无 probe 时为 Unknown）。
@property (nonatomic, readonly) A2JITReadinessVerdict lastVerdict;
/// 最近一次取证 / 原因摘要（无则 nil）。
@property (nonatomic, readonly, copy, nullable) NSString *lastEvidence;
/// 当前配对文件路径（无则 nil）。
@property (nonatomic, readonly, copy, nullable) NSString *pairingFilePath;

/// 是否能【尝试】生成（前置条件全满足 && 引擎接入）。★与 isPairingReady 不同★：
/// isPairingReady = 材料已到手；本属性 = 有本事去拿。
- (BOOL)canGeneratePairingFile;
/// 是否已有一份【新鲜】的可用配对文件（无文件 / 过期 ⇒ NO）。
- (BOOL)hasFreshUsablePairingFile;
/// 需要用户先处理的前置条件（未满足优先，其次未确认；无则 nil）。
- (nullable NSNumber *)firstBlockingPrecondition;

/// 需要用户处理的前置条件的【本地化 reason key】：
/// 有【明确未满足】项 → `jit.row.autopair.precondMissing`；
/// 只有【未确认】项 → `jit.row.autopair.precondUnknown`（★不把 Unknown 说成「未满足」★）；
/// 无阻塞 → nil。文案本体在 A2JITStrings（四语）。
- (nullable NSString *)blockingPreconditionReasonKey;

@end

NS_ASSUME_NONNULL_END
