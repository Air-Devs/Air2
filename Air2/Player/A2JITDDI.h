//
//  A2JITDDI.h
//  Air2
//
//  Player —— 【Developer Disk Image（DDI）】的类型 + 纯逻辑 + 设备侧查询注入缝。
//
//  口径来源：docs/JIT-PROVISIONING.md §1.2 前置条件条目「④（首次）联网取 DDI」。
//  ★本文件只定义「类型 + 纯逻辑（版本对齐 / 新鲜度 / 三态判定）」★：
//    · 本地镜像的发现与校验在 A2JITDDIStore（Player，Foundation-only）；
//    · 判定合成在 A2JITDDIProbe（Player，纯逻辑）；
//    · ★真正碰设备/网络的机制（个性化请求、image_mounter 挂载）不在这里★ ——
//      由设备侧查询协议 A2JITDDIDeviceQuery 注入，真机实现经 Bridge → Natives
//      （层级：App → UI → Player → Core → Bridge → Natives）。Player 只消费状态。
//
//  ★「不谎报」的两条硬规矩★：
//    1. 版本对齐只能是【三态】（Matched / Mismatched / Unknown）——
//       镜像没声明版本/构建号、或系统构建号取不到时一律 Unknown，★不许猜成匹配★；
//    2. 判定 Unknown（无法确认）与 Missing（明确缺失）必须分清，
//       前者不许当成「缺失」、更不许当成「已就位」。
//
//  许可：零第三方；★只参考公开文档与公开实现的行为描述，未搬运任何第三方代码★
//  （见 docs/DEPENDENCIES.md「DDI 取得」节）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// 镜像来源 / 形态
// ---------------------------------------------------------------------------

/// 本地镜像的来源（供 UI 说明「这份镜像哪来的」；探测面宽、取值窄）。
typedef NS_ENUM(NSInteger, A2JITDDISource) {
    A2JITDDISourceUnknown    = 0,  ///< 来源不明
    A2JITDDISourceContainer  = 1,  ///< 本 App 容器约定目录（Library/Application Support/DDI）
    A2JITDDISourceUserImport = 2,  ///< 用户经系统文档选择器导入（同配对文件的导入机制）
    A2JITDDISourceDevice     = 3,  ///< 设备侧（image_mounter 已挂载 / 系统目录；沙盒内通常不可读）
    A2JITDDISourceBundled    = 4,  ///< 随包镜像
};

/// 镜像形态。
typedef NS_ENUM(NSInteger, A2JITDDIKind) {
    A2JITDDIKindUnknown      = 0,  ///< 未识别
    A2JITDDIKindLegacy       = 1,  ///< 传统 DDI（DeveloperDiskImage.dmg + .signature）
    A2JITDDIKindPersonalized = 2,  ///< iOS 17+ 个性化镜像（dmg + trustcache，按设备个性化）
};

// ---------------------------------------------------------------------------
// 判定（★三态语义★）
// ---------------------------------------------------------------------------

/// 版本对齐结果（★三态：Unknown 与 Mismatched 必须分清★）。
typedef NS_ENUM(NSInteger, A2JITDDIMatch) {
    A2JITDDIMatchUnknown    = 0,  ///< 无法对齐（镜像未声明版本/构建号，或系统构建号取不到）
    A2JITDDIMatchMatched    = 1,  ///< 与系统版本/构建号一致
    A2JITDDIMatchMismatched = 2,  ///< 与系统版本/构建号不一致
};

/// DDI 判定（★Unknown = 无法确认；Missing = 明确缺失；两者不许混★）。
typedef NS_ENUM(NSInteger, A2JITDDIVerdict) {
    A2JITDDIVerdictUnknown         = 0,  ///< 无法确认（探测未接线 / 元数据不足 / 读不到）⇒ 前置条件 Unknown
    A2JITDDIVerdictPresent         = 1,  ///< 已就位（本地有版本匹配且新鲜的镜像）⇒ 前置条件 Satisfied
    A2JITDDIVerdictMissing         = 2,  ///< 明确缺失（本地没有可用镜像）⇒ 前置条件 Unsatisfied
    A2JITDDIVerdictVersionMismatch = 3,  ///< 有镜像但与系统版本/构建号不匹配 ⇒ 前置条件 Unsatisfied
    A2JITDDIVerdictStale           = 4,  ///< 有匹配镜像但超过新鲜度窗口 ⇒ 前置条件 Unsatisfied
};

// ---------------------------------------------------------------------------
// 系统要求（与系统版本 / 构建号对齐的「被匹配方」）
// ---------------------------------------------------------------------------

/// 本机对 DDI 的要求（由事实来源 + 设备侧查询构造；★纯值对象★）。
@interface A2JITDDIRequirement : NSObject

/// 主/次版本号（如 27.2）。
@property (nonatomic, readonly) NSInteger osMajorVersion;
@property (nonatomic, readonly) NSInteger osMinorVersion;

/// 系统构建号（如 24B5084k）。★取不到就是 nil ⇒ 无法按构建号对齐（不猜）★。
@property (nonatomic, readonly, copy, nullable) NSString *build;

/// 显式构造。
+ (instancetype)requirementWithOSMajorVersion:(NSInteger)majorVersion
                                 minorVersion:(NSInteger)minorVersion
                                        build:(nullable NSString *)build;

/// 版本串（如 "27.2"）。
- (NSString *)versionString;
/// 展示串：有构建号 ⇒ "27.2 (24B5084k)"；无 ⇒ "27.2"。
- (NSString *)displayVersion;

@end

// ---------------------------------------------------------------------------
// 本地镜像（已发现的物理文件）
// ---------------------------------------------------------------------------

/// 一份本地 DDI 镜像（★纯值对象★；字段缺就是 nil，不做默认值填充）。
@interface A2JITDDIImage : NSObject

/// 镜像文件绝对路径（.dmg）。
@property (nonatomic, readonly, copy) NSString *filePath;
/// 配套 trustcache 路径（个性化镜像才有；无则 nil）。
@property (nonatomic, readonly, copy, nullable) NSString *trustcachePath;
/// 镜像形态。
@property (nonatomic, readonly) A2JITDDIKind kind;
/// 来源。
@property (nonatomic, readonly) A2JITDDISource source;
/// 字节数（0 = 读不到 / 空）。
@property (nonatomic, readonly) unsigned long long byteSize;
/// SHA-256（十六进制小写；未计算时 nil）。
@property (nonatomic, readonly, copy, nullable) NSString *sha256;
/// 导入时间（无元数据 ⇒ nil ⇒ 无法判新鲜度）。
@property (nonatomic, readonly, copy, nullable) NSDate *importedAt;
/// 镜像【声明】的构建号（来自元数据 / 文件名；无 ⇒ nil）。
@property (nonatomic, readonly, copy, nullable) NSString *declaredBuild;
/// 镜像【声明】的系统版本串（如 "27.2"；无 ⇒ nil）。
@property (nonatomic, readonly, copy, nullable) NSString *declaredOSVersion;

/// 显式构造。
+ (instancetype)imageWithFilePath:(NSString *)filePath
                   trustcachePath:(nullable NSString *)trustcachePath
                             kind:(A2JITDDIKind)kind
                           source:(A2JITDDISource)source
                         byteSize:(unsigned long long)byteSize
                           sha256:(nullable NSString *)sha256
                       importedAt:(nullable NSDate *)importedAt
                    declaredBuild:(nullable NSString *)declaredBuild
                declaredOSVersion:(nullable NSString *)declaredOSVersion;

@end

// ---------------------------------------------------------------------------
// 设备侧查询注入缝（★机制不在这里★：真机 = Bridge → Natives）
// ---------------------------------------------------------------------------

/// DDI 判定的【设备侧】查询（可查询门缝）。
///
/// ★本协议只被 Bridge 实现★（Player 侧只声明并且只依赖它）；未接线的实现
/// **必须如实回 Unknown / NO + 确切缺什么**，绝不假成功。
@protocol A2JITDDIDeviceQuery <NSObject>

@required

/// 设备侧是否已有可用 DDI（如 Xcode 已挂载）。
/// ★查不到就回 A2JITDDIVerdictUnknown 并在 evidenceOut 写明为什么，不许猜★。
- (A2JITDDIVerdict)deviceDDIVerdictWithEvidence:(NSString *_Nullable *_Nullable)evidenceOut;

/// ★联网取 DDI★（默认关；开启后走 Apple 官方端点做个性化请求）。
/// ★这属于「访问 Apple 官方服务」，不是「上云」★：请求发往 Apple 的 personalization/TSS 端点，
/// 不经过任何第三方服务器。未接入 ⇒ 回 NO + 确切缺什么（不假成功）。
- (BOOL)fetchPersonalizedImageForRequirement:(A2JITDDIRequirement *)requirement
                                      reason:(NSString *_Nullable *_Nullable)reasonOut;

/// 挂载 / 卸载镜像。★需要特权或未接线时回 NO + 确切缺什么★（不假成功）。
- (BOOL)mountImageAtPath:(NSString *)imagePath
           trustcachePath:(nullable NSString *)trustcachePath
                  reason:(NSString *_Nullable *_Nullable)reasonOut;

@end

// ---------------------------------------------------------------------------
// 判定结果（不可变值对象）
// ---------------------------------------------------------------------------

/// 一次 DDI 判定的结果（★不可变、可单测★）。
@interface A2JITDDIStatus : NSObject

/// 判定（五态；Unknown = 无法确认）。
@property (nonatomic, readonly) A2JITDDIVerdict verdict;
/// 取证 / 原因摘要（始终非空，供日志与设置页副标题直接展示）。
@property (nonatomic, readonly, copy) NSString *evidence;
/// 命中的镜像路径（无则 nil）。
@property (nonatomic, readonly, copy, nullable) NSString *imagePath;
/// 命中的镜像来源（无镜像时为 Unknown）。
@property (nonatomic, readonly) A2JITDDISource source;

/// 显式构造。
+ (instancetype)statusWithVerdict:(A2JITDDIVerdict)verdict
                        imagePath:(nullable NSString *)imagePath
                           source:(A2JITDDISource)source
                         evidence:(NSString *)evidence;

@end

// ---------------------------------------------------------------------------
// 纯逻辑（★无平台调用、可单测★）
// ---------------------------------------------------------------------------

/// DDI 的纯逻辑判定（唯一实现）。
@interface A2JITDDI : NSObject

/// 默认新鲜度窗口（秒）：与配对文件同口径（免费签名 7 天重签会让缓存失效，见 §5 风险 3）。
+ (NSTimeInterval)defaultMaxAge;

/// 镜像与要求的【版本对齐】（★三态；取不到 ⇒ Unknown，不猜★）。
+ (A2JITDDIMatch)matchOfImage:(A2JITDDIImage *)image
              withRequirement:(A2JITDDIRequirement *)requirement
                          why:(NSString *_Nullable *_Nullable)whyOut;

/// 综合判定：版本对齐 + 新鲜度 ⇒ 五态判定。
/// @param image      本地镜像（nil ⇒ Missing）。
/// @param maxAge     新鲜度窗口（秒）。
/// @param now        参考时间（可注入，便于单测）。
+ (A2JITDDIVerdict)verdictForImage:(nullable A2JITDDIImage *)image
                   withRequirement:(A2JITDDIRequirement *)requirement
                            maxAge:(NSTimeInterval)maxAge
                               now:(NSDate *)now
                               why:(NSString *_Nullable *_Nullable)whyOut;

/// 判定 → 前置条件三态（★Unknown 只由 Unknown 判定产生★）。
+ (NSInteger)preconditionStateValueForVerdict:(A2JITDDIVerdict)verdict;

/// 从 `NSProcessInfo.operatingSystemVersionString`（形如 "Version 27.2 (Build 24B5084k)"）
/// 里取出构建号；取不到 ⇒ nil（★不猜★）。
+ (nullable NSString *)buildFromOperatingSystemVersionString:(NSString *)versionString;

/// 稳定英文名（日志 / 诊断用，非本地化）。
+ (NSString *)displayNameForVerdict:(A2JITDDIVerdict)verdict;
/// 稳定英文名（来源；日志用，非本地化）。
+ (NSString *)displayNameForSource:(A2JITDDISource)source;

@end

NS_ASSUME_NONNULL_END
