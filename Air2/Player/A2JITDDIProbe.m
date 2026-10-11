//
//  A2JITDDIProbe.m
//  Air2
//
//  [JIT-DDI-1] 判定合成实现（★纯逻辑★：本地文件系统 + 注入的设备侧查询；无网络、无设备调用）。
//

#import "A2JITDDIProbe.h"
#import "A2JITDDIStore.h"
#import "A2JITDDIGuidance.h"   // 统一日志行（唯一实现）

@interface A2JITLocalDDIProbe ()
// 头文件 readonly，内部可写（单测可调小窗口）。
@property (nonatomic, readwrite) NSTimeInterval maxAge;
/// 组装结果 + 打统一日志行。
- (A2JITDDIStatus *)finishWithVerdict:(A2JITDDIVerdict)verdict
                           imagePath:(nullable NSString *)imagePath
                              source:(A2JITDDISource)source
                            evidence:(nullable NSString *)evidence;
@end

@implementation A2JITLocalDDIProbe

- (instancetype)initWithStore:(A2JITDDIStore *)store
                  requirement:(A2JITDDIRequirement *)requirement
                  deviceQuery:(nullable id<A2JITDDIDeviceQuery>)deviceQuery {
    NSParameterAssert(store);
    NSParameterAssert(requirement);
    self = [super init];
    if (self) {
        _store = store;
        _requirement = requirement;
        _deviceQuery = deviceQuery;
        _maxAge = [A2JITDDI defaultMaxAge];
    }
    return self;
}

#pragma mark - 本地那一半

- (A2JITDDIVerdict)localVerdictWithEvidence:(NSString *_Nullable *_Nullable)evidenceOut {
    // ★目录不可读 ⇒ 一律「无法确认」，不许报「缺失」或「就位」★。
    if (![self.store isStoreReadable]) {
        if (evidenceOut) {
            *evidenceOut = [NSString stringWithFormat:@"DDI 目录不可读：%@", self.store.directory];
        }
        return A2JITDDIVerdictUnknown;
    }
    A2JITDDIImage *img = [self.store currentImage];
    NSString *why = nil;
    A2JITDDIVerdict v = [A2JITDDI verdictForImage:img
                                 withRequirement:self.requirement
                                          maxAge:self.maxAge
                                             now:[NSDate date]
                                             why:&why];
    NSString *who = img ? [NSString stringWithFormat:@"本地镜像 %@", img.filePath.lastPathComponent] : @"本地";
    if (evidenceOut) {
        *evidenceOut = [NSString stringWithFormat:@"%@：%@", who, why ?: @"(无详情)"];
    }
    return v;
}

#pragma mark - 判定合成

- (A2JITDDIStatus *)ddiStatus {
    NSString *localWhy = nil;
    A2JITDDIVerdict local = [self localVerdictWithEvidence:&localWhy];

    NSString *devWhy = nil;
    A2JITDDIVerdict device = A2JITDDIVerdictUnknown;
    if (self.deviceQuery != nil) {
        device = [self.deviceQuery deviceDDIVerdictWithEvidence:&devWhy];
    } else {
        devWhy = @"设备侧查询未接线（Bridge → Natives 尚未落地）⇒ 设备侧不可查";
    }

    // ---- ① 本地已就位 ⇒ 就位（最强证据，无需设备侧） ----
    if (local == A2JITDDIVerdictPresent) {
        A2JITDDIImage *img = [self.store currentImage];
        return [self finishWithVerdict:A2JITDDIVerdictPresent
                             imagePath:img.filePath
                                source:img.source
                              evidence:localWhy];
    }

    // ---- ② 设备侧确认为「有」 ⇒ 就位（来源标 Device） ----
    if (device == A2JITDDIVerdictPresent) {
        return [self finishWithVerdict:A2JITDDIVerdictPresent
                             imagePath:nil
                                source:A2JITDDISourceDevice
                              evidence:devWhy ?: @"设备侧报告已有可用 DDI"];
    }

    // ---- ③ 本地明确不可用（缺失 / 版本不符 / 过期）⇒ 如实报该态 ----
    if (local != A2JITDDIVerdictUnknown) {
        NSString *why = localWhy ?: @"本地不可用";
        if (device == A2JITDDIVerdictUnknown && devWhy.length) {
            why = [NSString stringWithFormat:@"%@；设备侧无法确认（%@）", why, devWhy];
        }
        return [self finishWithVerdict:local
                             imagePath:nil
                                source:A2JITDDISourceUnknown
                              evidence:why];
    }

    // ---- ④ 设备侧能给出明确结论 ⇒ 用它 ----
    if (device != A2JITDDIVerdictUnknown) {
        return [self finishWithVerdict:device
                             imagePath:nil
                                source:A2JITDDISourceDevice
                              evidence:devWhy ?: @"设备侧判定"];
    }

    // ---- ⑤ 两边都无法确认 ⇒ Unknown（★绝不猜成 Present★） ----
    NSString *why = [NSString stringWithFormat:@"本地无法确认（%@）；设备侧无法确认（%@）",
                     localWhy ?: @"无详情", devWhy ?: @"无详情"];
    return [self finishWithVerdict:A2JITDDIVerdictUnknown
                         imagePath:nil
                            source:A2JITDDISourceUnknown
                          evidence:why];
}

- (A2JITDDIStatus *)finishWithVerdict:(A2JITDDIVerdict)verdict
                           imagePath:(nullable NSString *)imagePath
                              source:(A2JITDDISource)source
                            evidence:(nullable NSString *)evidence {
    NSString *ev = evidence.length ? evidence : @"(无取证记录)";
    // 一行定成败：判定 / 来源 / 系统要求 / 取证（默认可见，便于真机照单核对）。
    NSString *detail = [NSString stringWithFormat:@"source=%@ require=%@ %@",
                        [A2JITDDI displayNameForSource:source],
                        [self.requirement displayVersion], ev];
    NSLog(@"%@", [A2JITDDIGuidance logLineWithProvider:@"本地 DDI 探测"
                                              verdict:verdict
                                             evidence:detail]);
    return [A2JITDDIStatus statusWithVerdict:verdict imagePath:imagePath source:source evidence:ev];
}

#pragma mark - 机制调用点（全部如实转发；未接线 ⇒ NO + 确切缺什么）

- (BOOL)fetchPersonalizedImageWithReason:(NSString *_Nullable *_Nullable)reasonOut {
    if (self.deviceQuery == nil) {
        if (reasonOut) {
            *reasonOut = @"未接线：个性化 DDI 的官方端点请求与校验经 Bridge → Natives 落地（docs/JIT-PROVISIONING.md §4.2）";
        }
        return NO;
    }
    return [self.deviceQuery fetchPersonalizedImageForRequirement:self.requirement reason:reasonOut];
}

- (BOOL)mountCurrentImageWithReason:(NSString *_Nullable *_Nullable)reasonOut {
    A2JITDDIImage *img = [self.store currentImage];
    if (img == nil) {
        if (reasonOut) {
            *reasonOut = @"本地没有可挂载的 DDI 镜像（先导入）";
        }
        return NO;
    }
    if (self.deviceQuery == nil) {
        if (reasonOut) {
            *reasonOut = @"未接线：挂载经 image_mounter 服务（Bridge → Natives 落地），需要相应特权";
        }
        return NO;
    }
    return [self.deviceQuery mountImageAtPath:img.filePath
                                trustcachePath:img.trustcachePath
                                       reason:reasonOut];
}

@end
