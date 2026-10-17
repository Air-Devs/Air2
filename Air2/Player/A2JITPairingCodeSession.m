//
//  A2JITPairingCodeSession.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Player —— 设备发起档的配对码会话实现（口径与「未做 + 唯一改点」见头文件）。
//

#import "A2JITPairingCodeSession.h"
#import "A2Log.h"     // [A2Log criterion:]：判据行的统一出口（控制台 + 会话日志文件）

// ★持久化键（Player 内部；带 A2 前缀避免与老线键撞）★——用户切到系统设置期间，码要能读回来。
static NSString *const kA2CodeKey    = @"A2PairingCodeCode";
static NSString *const kA2HostKey    = @"A2PairingCodeHost";
static NSString *const kA2StateKey   = @"A2PairingCodeState";
static NSString *const kA2DetailKey  = @"A2PairingCodeDetail";

@implementation A2JITPairingCodeSession

+ (NSString *)pairableHostServiceType {
    // ★与 Info.plist 的 NSBonjourServices 同一字面量★（Natives 侧叫 A2RPRSDServicePairableHost；
    //   Player 不得 import Natives ⇒ 此处以同一字面量出现，tests/JIT 有「与 plist 一致」的门禁）。
    return @"_remotepairing-pairable-host._tcp";
}

+ (NSString *)stateName:(A2JITPairingCodeState)state {
    switch (state) {
        case A2JITPairingCodeStateIdle:        return @"idle";
        case A2JITPairingCodeStateAdvertising: return @"advertising";
        case A2JITPairingCodeStateConnected:   return @"connected";
        case A2JITPairingCodeStateVerifying:   return @"verifying";
        case A2JITPairingCodeStateSucceeded:   return @"succeeded";
        case A2JITPairingCodeStateFailed:      return @"failed";
    }
    return @"unknown";
}

+ (NSString *)criterionLineForState:(A2JITPairingCodeState)state
                               host:(NSString *)host
                               code:(NSString *)code
                             detail:(nullable NSString *)detail {
    return [NSString stringWithFormat:@"[A2-PAIRPIN] state=%@ host=%@ code=%@%@",
            [self stateName:state],
            host.length ? host : @"(none)",
            code.length ? code : @"(none)",
            detail.length ? [NSString stringWithFormat:@" detail=%@", detail] : @""];
}

+ (instancetype)sharedSession {
    static A2JITPairingCodeSession *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [A2JITPairingCodeSession new]; });
    return s;
}

+ (nullable instancetype)restoredFromDefaults {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *code = [d stringForKey:kA2CodeKey];
    NSString *host = [d stringForKey:kA2HostKey];
    // ★没有「正在显示的码」就不算一个可恢复的会话★（endPairing 会清掉码 ⇒ 恢复返回 nil，
    //   屏幕上不会留一个已经作废的码）。
    if (code.length == 0) {
        return nil;
    }
    A2JITPairingCodeSession *s = [A2JITPairingCodeSession new];
    s->_code = [code copy] ?: @"";
    s->_hostName = [host copy] ?: @"";
    s->_state = (A2JITPairingCodeState)[d integerForKey:kA2StateKey];
    s->_lastDetail = [[d stringForKey:kA2DetailKey] copy];
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _code = @"";
        _hostName = @"";
        _state = A2JITPairingCodeStateIdle;
    }
    return self;
}

- (BOOL)beginDeviceInitiatedWithHostName:(NSString *)hostName error:(NSError *_Nullable *_Nullable)error {
    if (hostName.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2JITPairingCode" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"主机名为空 ⇒ 不生成配对码（用户在设置列表里认不出我们）"
            }];
        }
        return NO;
    }
    // 6 位码（含前导零）：用 arc4random（Darwin 上由内核 CSPRNG 驱动）。
    uint32_t v = arc4random_uniform(1000000u);
    _code = [NSString stringWithFormat:@"%06u", (unsigned)v];
    _hostName = [hostName copy];
    _state = A2JITPairingCodeStateAdvertising;
    _lastDetail = @"已生成配对码并显示（等设备在 设置 › 通用 › VPN 与设备管理 里输入）";

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:_code forKey:kA2CodeKey];
    [d setObject:_hostName forKey:kA2HostKey];
    [d setInteger:_state forKey:kA2StateKey];
    [d setObject:_lastDetail forKey:kA2DetailKey];

    [A2Log criterion:@"%@", [A2JITPairingCodeSession criterionLineForState:_state host:_hostName code:_code
                                                        detail:@"listener=由 A2JITAutoPairingEngineBridge→A2RPPairSetupAccessory 起 NWListener(_remotepairing-pairable-host._tcp) 并在同一条流上跑 pair-setup（本类只负责生成/显示码）"]];
    return YES;
}

- (void)advanceToState:(A2JITPairingCodeState)state detail:(nullable NSString *)detail {
    _state = state;
    _lastDetail = [detail copy];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:state forKey:kA2StateKey];
    [d setObject:(detail ?: @"") forKey:kA2DetailKey];
    [A2Log criterion:@"%@", [A2JITPairingCodeSession criterionLineForState:state host:_hostName code:_code detail:detail]];
}

- (void)endPairing {
    // ★作废即清：屏幕上不能留一个已经不能用的码★（否则用户会拿它去输，然后困惑）。
    _code = @"";
    _lastDetail = nil;
    _state = A2JITPairingCodeStateIdle;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d removeObjectForKey:kA2CodeKey];
    [d removeObjectForKey:kA2DetailKey];
    [d setInteger:A2JITPairingCodeStateIdle forKey:kA2StateKey];
    [A2Log criterion:@"%@", [A2JITPairingCodeSession criterionLineForState:_state host:_hostName code:_code
                                                        detail:@"配对结束，已作废并清除显示的码"]];
}

@end
