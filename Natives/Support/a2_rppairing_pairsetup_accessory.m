//
//  a2_rppairing_pairsetup_accessory.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [A2-PAIRWIRE] 设备发起配对的驱动实现（口径/做到哪一步/阻塞点见头文件）。
//

#import "a2_rppairing_pairsetup_accessory.h"
#import "a2_rppairing.h"          // A2RPPairingIdentity
#import "a2_rppairing_rsd.h"      // ★复用★服务类型常量 A2RPRSDServicePairableHost（不另造）
#import "a2_remotexpc_session.h"  // A2RemoteXPCErrorKind
#import "a2_log.h"                // a2_log_criterion：判据行的统一出口（控制台 + 会话日志文件）

#pragma mark - 判据行

NSString *const A2RPPairWireCriterionMarker = @"[A2-PAIRPIN]";

void A2RPPairWireCriterionLog(NSString *line) {
    // ★单行、默认可见★：走统一出口 ⇒ ①控制台（设备日志 / macOS 测试的 stderr 都能
    //   `grep '\[A2-PAIRPIN\]'`）②App 会话日志文件（lastlog.txt，「运行日志」页可看）。
    //   ★用 %@ 包一层★：line 里可能带 % 字符（端口/尺寸），避免格式串注入。
    a2_log_criterion(@"%@ %@", A2RPPairWireCriterionMarker, line ?: @"");
}

#pragma mark - 阶段名 / 失败分类名

NSString *A2RPPairSetupAccessoryPhaseName(A2RPPairSetupAccessoryPhase phase) {
    switch (phase) {
        case A2RPPairSetupAccessoryPhaseStarting:    return @"starting";
        case A2RPPairSetupAccessoryPhaseAdvertising: return @"advertising";
        case A2RPPairSetupAccessoryPhaseConnected:   return @"connected";
        case A2RPPairSetupAccessoryPhaseVerifying:   return @"verifying";
        case A2RPPairSetupAccessoryPhaseSucceeded:   return @"succeeded";
        case A2RPPairSetupAccessoryPhaseFailed:      return @"failed";
        case A2RPPairSetupAccessoryPhaseCancelled:   return @"cancelled";
    }
    return @"unknown";
}

NSString *A2RPPairSetupAccessoryFailureName(A2RPPairSetupAccessoryFailure failure) {
    switch (failure) {
        case A2RPPairSetupAccessoryFailureNone:                   return @"None";
        case A2RPPairSetupAccessoryFailureIdentityFailed:         return @"IdentityFailed";
        case A2RPPairSetupAccessoryFailureAltIRKUnavailable:      return @"AltIRKUnavailable";
        case A2RPPairSetupAccessoryFailureNoLocalNetworkPermission:return @"NoLocalNetworkPermission";
        case A2RPPairSetupAccessoryFailureSuspended:              return @"Suspended";
        case A2RPPairSetupAccessoryFailureWaitTimedOut:           return @"WaitTimedOut";
        case A2RPPairSetupAccessoryFailurePublishFailed:          return @"PublishFailed";
        case A2RPPairSetupAccessoryFailureAcceptFailed:           return @"AcceptFailed";
        case A2RPPairSetupAccessoryFailureTransportFailed:        return @"TransportFailed";
        case A2RPPairSetupAccessoryFailurePinMissing:             return @"PinMissing";
        case A2RPPairSetupAccessoryFailureWrongPin:               return @"WrongPin";
        case A2RPPairSetupAccessoryFailureProtocolError:          return @"ProtocolError";
        case A2RPPairSetupAccessoryFailureSessionTimedOut:        return @"SessionTimedOut";
        case A2RPPairSetupAccessoryFailureNotEstablished:         return @"NotEstablished";
        case A2RPPairSetupAccessoryFailurePairingFileUnavailable: return @"PairingFileUnavailable";
        case A2RPPairSetupAccessoryFailureCancelled:              return @"Cancelled";
    }
    return [NSString stringWithFormat:@"Unknown(%ld)", (long)failure];
}

#pragma mark - 广告器抽象 + 既有类遵守它（★只加声明，不改既有实现★）

@implementation A2RPPairableHostAdvertiser (A2RPPairSetupAccessory)
@end

#pragma mark - 结果值对象

@interface A2RPPairSetupAccessoryRun ()
@property (nonatomic, readwrite) A2RPPairSetupAccessoryFailure failure;
@property (nonatomic, readwrite, copy) NSString *detail;
@property (nonatomic, readwrite, copy, nullable) NSData *pairingFileData;
@property (nonatomic, readwrite, copy, nullable) NSString *identifier;
@property (nonatomic, readwrite, copy, nullable) NSString *advertisedName;
@property (nonatomic, readwrite, copy, nullable) NSString *hostName;
@property (nonatomic, readwrite, copy, nullable) NSString *serviceName;
@property (nonatomic, readwrite) uint16_t port;
@property (nonatomic, readwrite, copy, nullable) NSString *authTagBase64;
@property (nonatomic, readwrite) BOOL advertised;
@property (nonatomic, readwrite) BOOL connected;
@property (nonatomic, readwrite) A2RPPairSetupStep lastStep;
@end

@implementation A2RPPairSetupAccessoryRun
- (BOOL)succeeded { return self.failure == A2RPPairSetupAccessoryFailureNone && self.pairingFileData.length > 0; }
- (instancetype)init {
    self = [super init];
    if (self) {
        _detail = @"";
        _lastStep = A2RPPairSetupStepIdle;
    }
    return self;
}
@end

#pragma mark - 驱动

/// 生产装配：真通告器（既有 A2RPPairableHostAdvertiser）。
static A2RPPairSetupAccessoryListenerFactory const A2RPPWProductionListenerFactory =
    ^id<A2RPPairSetupAccessoryListener>(NSString *name, NSString *model,
                                        NSString *identifier, NSData *altIRK) {
    return [[A2RPPairableHostAdvertiser alloc] initWithName:name
                                                      model:model
                                                 identifier:identifier
                                                     altIRK:altIRK];
};

/// 生产装配：真传输（RemoteXPC；★本侧是 accessory ⇒ originatedBy=device★）。
/// ★真机互操作未验证★：`originatedBy` 的取值是公开实现的通行口径，仍以真机对拍为准（见报告）。
static A2RPPairSetupAccessoryTransportFactory const A2RPPWProductionTransportFactory =
    ^id<A2RPPairSetupMessageTransport>(id<A2RPByteStream> stream, NSString *hostName,
                                       NSString **_Nullable reason) {
    A2RemoteXPCErrorKind err = A2RemoteXPCErrorNone;
    return [A2RPPairSetupRemoteXPCTransport transportOverByteStream:stream
                                                       originatedBy:@"device"
                                                           hostName:hostName
                                                        wireVersion:A2RPPairableHostWireProtocolVersion
                                                            timeout:30.0
                                                             reason:reason
                                                              error:&err];
};

@implementation A2RPPairSetupAccessory

+ (NSString *)defaultAdvertisedNameForHostName:(NSString *)hostName {
    NSString *h = hostName.length > 0 ? hostName : @"iPhone";
    return [NSString stringWithFormat:@"Air2 (%@)", h];
}

+ (A2RPPairSetupAccessoryRun *)runWithHostName:(NSString *)hostName
                                           pin:(NSString *)pin
                                        budget:(NSTimeInterval)budget
                                      observer:(A2RPPairSetupAccessoryObserver)observer
                                   isCancelled:(BOOL (^)(void))isCancelled {
    return [self runWithHostName:hostName
                             pin:pin
                          budget:budget
                 listenerFactory:A2RPPWProductionListenerFactory
                transportFactory:A2RPPWProductionTransportFactory
                        observer:observer
                     isCancelled:isCancelled];
}

+ (A2RPPairSetupAccessoryRun *)runWithHostName:(NSString *)hostName
                                           pin:(NSString *)pin
                                        budget:(NSTimeInterval)budget
                               listenerFactory:(A2RPPairSetupAccessoryListenerFactory)listenerFactory
                              transportFactory:(A2RPPairSetupAccessoryTransportFactory)transportFactory
                                      observer:(A2RPPairSetupAccessoryObserver)observer
                                   isCancelled:(BOOL (^)(void))isCancelled {
    A2RPPairSetupAccessoryRun *run = [A2RPPairSetupAccessoryRun new];
    run.hostName = hostName;
    run.advertisedName = [self defaultAdvertisedNameForHostName:hostName];

    /// 阶段上报（★唯一的观察出口★：阶段 + 会话步 + 判据行）。
    void (^emit)(A2RPPairSetupAccessoryPhase, A2RPPairSetupStep, NSString *) =
        ^(A2RPPairSetupAccessoryPhase phase, A2RPPairSetupStep step, NSString *line) {
        A2RPPairWireCriterionLog([NSString stringWithFormat:@"phase=%@ %@",
                                  A2RPPairSetupAccessoryPhaseName(phase), line ?: @""]);
        if (observer) { observer(phase, step, line); }
    };

    // 失败出口（★所有失败都走这里：回填分类 + 打判据行 + 上报阶段★）。
    //   ★detail 里带上稳定类名★：UI 的「失败原因」与真机判据都要能直接看到 class=…
    #define A2RPPW_FAIL(KIND, MSG)                                             \
        do {                                                                   \
            run.failure = (KIND);                                              \
            run.detail = [NSString stringWithFormat:@"[%@] %@",                \
                          A2RPPairSetupAccessoryFailureName(run.failure), (MSG)];\
            emit(A2RPPairSetupAccessoryPhaseFailed, run.lastStep,               \
                 [NSString stringWithFormat:                                   \
                  @"配对失败 class=%@ identifier=%@ 主机名=%@ 已连入=%@ 原因=%@",  \
                  A2RPPairSetupAccessoryFailureName(run.failure),              \
                  run.identifier ?: @"(none)", run.hostName ?: @"(none)",      \
                  run.connected ? @"是" : @"否", run.detail]);                  \
            return run;                                                        \
        } while (0)
    #define A2RPPW_CANCELLED_IF_NEEDED()                                       \
        do {                                                                   \
            if (isCancelled != nil && isCancelled()) {                          \
                A2RPPW_FAIL(A2RPPairSetupAccessoryFailureCancelled,            \
                            @"被取消（协作式：在阶段边界停下）");                 \
            }                                                                  \
        } while (0)

    if (listenerFactory == nil || transportFactory == nil) {
        A2RPPW_FAIL(A2RPPairSetupAccessoryFailurePublishFailed, @"未注入广告器/传输工厂 ⇒ 拒绝");
    }
    if (hostName.length == 0) {
        A2RPPW_FAIL(A2RPPairSetupAccessoryFailurePublishFailed,
                    @"主机名为空 ⇒ 用户在系统设置列表里认不出本机，拒绝起广告");
    }
    A2RPPW_CANCELLED_IF_NEEDED();

    // ---- ① 本次配对的主机身份（★每次配对都新生成 ⇒ 旧配对记录作废★）----
    NSError *idErr = nil;
    A2RPPairingIdentity *identity = [A2RPPairingIdentity identityWithHostName:hostName error:&idErr];
    if (identity == nil) {
        A2RPPW_FAIL(A2RPPairSetupAccessoryFailureIdentityFailed,
                    ([NSString stringWithFormat:@"主机身份生成失败：%@", idErr.localizedDescription ?: @"未知"]));
    }
    run.identifier = identity.identifier;

    // ---- ② 新的 altIRK（16 字节 CSPRNG；authTag 由它 + identifier 算出）----
    NSData *altIRK = A2RPPairableHostFreshAltIRK();
    if (altIRK.length != A2RPPairableHostAltIRKBytes) {
        A2RPPW_FAIL(A2RPPairSetupAccessoryFailureAltIRKUnavailable, @"CSPRNG 取不到 16 字节 altIRK");
    }
    NSData *tag = A2RPPairableHostAuthTag(altIRK, identity.identifier);
    run.authTagBase64 = tag != nil ? [tag base64EncodedStringWithOptions:0] : @"";
    run.serviceName = A2RPPairableHostServiceName(identity.identifier);
    emit(A2RPPairSetupAccessoryPhaseStarting, A2RPPairSetupStepIdle,
         [NSString stringWithFormat:@"主机身份 identifier=%@（★本轮新生成 ⇒ 旧配对记录作废★）",
          identity.identifier]);

    // ---- ③ 起广告 ----
    id<A2RPPairSetupAccessoryListener> listener = listenerFactory(run.advertisedName, @"Mac17,7",
                                                                  identity.identifier, altIRK);
    if (listener == nil) {
        A2RPPW_FAIL(A2RPPairSetupAccessoryFailurePublishFailed, @"广告器构造失败（工厂回 nil）");
    }
    emit(A2RPPairSetupAccessoryPhaseAdvertising, A2RPPairSetupStepIdle,
         [NSString stringWithFormat:
          @"advertise 启动 服务=%@ 实例名=%@ 显示名=%@ identifier=%@ authTag=%@ 协议版本=%d（★等设备连入★）",
          A2RPRSDServicePairableHost, run.serviceName, run.advertisedName, identity.identifier,
          run.authTagBase64, A2RPPairableHostWireProtocolVersion]);
    A2RPPairWireCriterionLog(@"等待设备连入（请到 设置 › 通用 › VPN 与设备管理 找「与 Air2 … 配对」；"
                             @"部分机型在 设置 › 隐私与安全性 › 开发者模式）");

    NSTimeInterval advBudget = MAX(1.0, budget * 0.9);
    NSString *advWhy = nil;
    id<A2RPByteStream> stream = [listener advertiseAndWaitForDeviceWithBudget:advBudget reason:&advWhy];
    run.port = listener.port;
    run.advertised = listener.port != 0;

    if (stream == nil) {
        // ★按既有通告器的失败分类如实分流★（权限/挂起/超时/发布/接受）—— 不写万能文案。
        A2RPPairableHostFailure hf = listener.failure;
        A2RPPairSetupAccessoryFailure mapped;
        switch (hf) {
            case A2RPPairableHostFailureNoLocalNetworkPermission:
                mapped = A2RPPairSetupAccessoryFailureNoLocalNetworkPermission; break;
            case A2RPPairableHostFailureSuspended:
                mapped = A2RPPairSetupAccessoryFailureSuspended; break;
            case A2RPPairableHostFailureTimedOut:
                mapped = A2RPPairSetupAccessoryFailureWaitTimedOut; break;
            case A2RPPairableHostFailureAcceptFailed:
                mapped = A2RPPairSetupAccessoryFailureAcceptFailed; break;
            case A2RPPairableHostFailurePublishFailed:
            case A2RPPairableHostFailureKeyRotated:
            case A2RPPairableHostFailureNone:
            default:
                mapped = A2RPPairSetupAccessoryFailurePublishFailed; break;
        }
        A2RPPW_FAIL(mapped, ([NSString stringWithFormat:@"广告/等待连入未成（通告分类=%@）：%@",
                              A2RPPairableHostFailureName(hf), advWhy ?: listener.failureReason ?: @"原因未记录"]));
    }

    run.connected = YES;
    emit(A2RPPairSetupAccessoryPhaseConnected, A2RPPairSetupStepIdle,
         [NSString stringWithFormat:
          @"★被连入★ 服务=%@ 实例名=%@ 主机名=%@ 端口=%u（设置里的配对入口已被使用）",
          A2RPRSDServicePairableHost, listener.serviceName, listener.hostName, (unsigned)listener.port]);
    A2RPPW_CANCELLED_IF_NEEDED();

    // ---- ④ 建传输 ----
    NSString *tWhy = nil;
    id<A2RPPairSetupMessageTransport> transport = nil;
    if (stream != nil) {
        transport = transportFactory(stream, hostName, &tWhy);
    }
    if (transport == nil) {
        A2RPPW_FAIL(A2RPPairSetupAccessoryFailureTransportFailed,
                    ([NSString stringWithFormat:@"建 pair-setup 传输失败：%@", tWhy ?: @"原因未记录"]));
    }
    A2RPPW_CANCELLED_IF_NEEDED();
    emit(A2RPPairSetupAccessoryPhaseVerifying, A2RPPairSetupStepIdle,
         @"传输就绪 角色=device/accessory（会话由对端 host/controller 发起，本机先收后回）");

    // ---- ⑤ 驱动 accessory 侧 PS-Msg01..06（★先收后发★）----
    NSData *sessionKey = nil;
    NSString *driveWhy = nil;
    A2RPPairSetupDriveFailure driveFail = A2RPPairSetupDriveFailureNone;
    BOOL ok = [A2RPPairSetupSession runAccessoryOverTransport:transport
                                                     identity:identity
                                                          pin:pin
                                                 stepObserver:^(A2RPPairSetupStep step, NSString *line) {
        run.lastStep = step;
        emit(A2RPPairSetupAccessoryPhaseVerifying, step, line);
    }
                                                       reason:&driveWhy
                                                 failureKind:&driveFail
                                                   sessionKey:&sessionKey];
    if (!ok) {
        A2RPPairSetupAccessoryFailure mapped;
        switch (driveFail) {
            case A2RPPairSetupDriveFailurePinMissing:
                mapped = A2RPPairSetupAccessoryFailurePinMissing; break;
            case A2RPPairSetupDriveFailurePeerRejected:
                mapped = A2RPPairSetupAccessoryFailureWrongPin; break;
            case A2RPPairSetupDriveFailureProtocol:
                mapped = A2RPPairSetupAccessoryFailureProtocolError; break;
            case A2RPPairSetupDriveFailureTransportTimeout:
                mapped = A2RPPairSetupAccessoryFailureSessionTimedOut; break;
            case A2RPPairSetupDriveFailureNotEstablished:
                mapped = A2RPPairSetupAccessoryFailureNotEstablished; break;
            case A2RPPairSetupDriveFailureTransport:
            case A2RPPairSetupDriveFailureNone:
            default:
                mapped = A2RPPairSetupAccessoryFailureTransportFailed; break;
        }
        A2RPPW_FAIL(mapped, ([NSString stringWithFormat:@"pair-setup 未完成（驱动分类=%ld）：%@",
                              (long)driveFail, driveWhy ?: @"原因未记录"]));
    }

    // ---- ⑥ 交出配对文件字节（★落盘由调用方的 store 负责，本层不碰存储★）----
    NSData *file = [identity pairingFileData];
    if (file.length == 0) {
        A2RPPW_FAIL(A2RPPairSetupAccessoryFailurePairingFileUnavailable, @"配对成功但产不出配对文件字节");
    }
    run.pairingFileData = file;
    run.failure = A2RPPairSetupAccessoryFailureNone;
    run.lastStep = A2RPPairSetupStepEstablished;
    run.detail = [NSString stringWithFormat:@"配对成功（PS-Msg01..06 走完）；配对文件 %lu 字节，会话密钥 %lu 字节",
                  (unsigned long)file.length, (unsigned long)sessionKey.length];
    emit(A2RPPairSetupAccessoryPhaseSucceeded, A2RPPairSetupStepEstablished,
         [NSString stringWithFormat:
          @"★配对成功★ identifier=%@ 主机名=%@ 会话密钥=%lu 字节 配对文件=%lu 字节（落盘由调用方的 store 负责）",
          identity.identifier, hostName, (unsigned long)sessionKey.length, (unsigned long)file.length]);
    #undef A2RPPW_CANCELLED_IF_NEEDED
    #undef A2RPPW_FAIL
    return run;
}

@end
