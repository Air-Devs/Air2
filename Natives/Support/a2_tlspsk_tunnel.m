// ============================================================================
//  Natives/Support/a2_tlspsk_tunnel.m
//  Air2 —— [A2-INTEGRATION] TLS-PSK 隧道门面实现（默认关 / 可替换 / 不谎报 / 不上云）
// ----------------------------------------------------------------------------
//  本文件只做「门面 + 策略」；真正的 TLS 在 a2_tlspsk_mbedtls.m（后端）。
//  ★无第三方 TLS 逻辑、无握手逻辑★ —— 这样「换后端」不碰本文件。
// ============================================================================
#import "a2_tlspsk_tunnel.h"
#import "a2_log.h"

#pragma mark - 默认主机准入策略（★不上云★）

/// 只放行「本机 / 私有网段 / 链路本地 / .local(Bonjour)」。
/// 这是「不上云」的机器判据：任何公网地址 ⇒ NO（调用方如实拒绝并记录）。
BOOL A2TLSPskDefaultHostPolicy(NSString *host) {
    if (host.length == 0) {
        return NO;
    }
    NSString *h = [host lowercaseString];

    // ① 名字：loopback / Bonjour 本地
    if ([h isEqualToString:@"localhost"] || [h isEqualToString:@"::1"] ||
        [h isEqualToString:@"ip6-localhost"] || [h hasSuffix:@".local"]) {
        return YES;
    }

    // ② IPv4 字面量：回环 / 私有 / 链路本地
    if ([h isEqualToString:@"127.0.0.1"] || [h hasPrefix:@"127."]) {
        return YES;
    }
    if ([h hasPrefix:@"10."] || [h hasPrefix:@"192.168."] || [h hasPrefix:@"169.254."]) {
        return YES;
    }
    if ([h hasPrefix:@"172."]) {
        // 172.16.0.0/12
        NSArray<NSString *> *p = [h componentsSeparatedByString:@"."];
        if (p.count == 4) {
            NSInteger second = [p[1] integerValue];
            if (second >= 16 && second <= 31) {
                return YES;
            }
        }
        return NO;
    }

    // ③ IPv6 链路本地 / 唯一本地地址（ULA，fc00::/7）
    if ([h hasPrefix:@"fe80:"] || [h hasPrefix:@"fc"] || [h hasPrefix:@"fd"]) {
        return YES;
    }

    // ④ 其余（含任何公网域名/IP）⇒ 拒绝
    return NO;
}

#pragma mark - 门面

/// 已注册后端；nil ⇒ «未注册»（如实）。
static id<A2TLSPskTunnelBackend> gA2TLSPskBackend = nil;
static A2TLSPskHostPolicy gA2TLSPskHostPolicy = nil;

@interface A2TLSPskTunnel ()
@property (nonatomic, readwrite) A2TLSPskTunnelState state;
@end

@implementation A2TLSPskTunnel

+ (instancetype)sharedTunnel {
    static A2TLSPskTunnel *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[A2TLSPskTunnel alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _enabled = NO;                          // ★默认关★
        _state = A2TLSPskTunnelStateIdle;
    }
    return self;
}

+ (void)registerBackend:(id<A2TLSPskTunnelBackend>)backend {
    gA2TLSPskBackend = backend;
    a2_log_f(@"[A2-TLSPK] 后端已注册：%s", backend ? [[backend backendName] UTF8String] : "«nil»");
}

+ (NSString *)backendName {
    return gA2TLSPskBackend ? [gA2TLSPskBackend backendName] : @"未注册";
}

+ (BOOL)isAvailableWithReason:(NSString *_Nullable *_Nullable)reason {
    if (gA2TLSPskBackend == nil) {
        if (reason) {
            *reason = @"未注册任何 TLS-PSK 后端（缺 mbedTLS 静态库 / 后端未编入包）";
        }
        return NO;
    }
    return [gA2TLSPskBackend isAvailableWithReason:reason];
}

+ (NSString *)statusLine {
    NSString *r = nil;
    BOOL ok = [self isAvailableWithReason:&r];
    return [NSString stringWithFormat:@"后端=%@ 可用=%@ 开关=%@（默认关）%@",
                                      [self backendName], ok ? @"是" : @"否",
                                      [self sharedTunnel].isEnabled ? @"开" : @"关",
                                      (ok ? @"" : [NSString stringWithFormat:@"｜缺：%@", r ?: @"未知"])];
}

+ (void)setHostPolicy:(nullable A2TLSPskHostPolicy)policy {
    gA2TLSPskHostPolicy = policy;
}

+ (A2TLSPskHostPolicy)hostPolicy {
    return gA2TLSPskHostPolicy ?: ^BOOL(NSString *host) {
        return A2TLSPskDefaultHostPolicy(host);
    };
}

#pragma mark - 实例操作

- (BOOL)connectToHost:(NSString *)host
                 port:(uint16_t)port
                  psk:(NSData *)psk
             identity:(nullable NSString *)identity
              timeout:(NSTimeInterval)timeout
               reason:(NSString *_Nullable *_Nullable)reason {
    if (!self.enabled) {
        self.state = A2TLSPskTunnelStateIdle;
        if (reason) { *reason = @"TLS-PSK 隧道开关未开启（★默认关★，需显式置 enabled=YES）"; }
        return NO;
    }
    if (gA2TLSPskBackend == nil) {
        self.state = A2TLSPskTunnelStateIdle;
        if (reason) { *reason = @"未注册任何 TLS-PSK 后端（缺 mbedTLS 静态库 / 后端未编入包）"; }
        return NO;
    }
    // ★不上云★：主机准入策略（默认只放行本机/私有网段/链路本地/.local）。
    A2TLSPskHostPolicy policy = [A2TLSPskTunnel hostPolicy];
    if (policy && !policy(host)) {
        self.state = A2TLSPskTunnelStateFailed;
        if (reason) {
            *reason = [NSString stringWithFormat:
                       @"拒绝连接非本地地址「%@」：默认策略只连本机/私有网段/链路本地/.local（★不上云★）", host];
        }
        return NO;
    }
    if (psk.length == 0) {
        self.state = A2TLSPskTunnelStateFailed;
        if (reason) { *reason = @"PSK 为空（pair-verify 的 shared secret 未就绪）"; }
        return NO;
    }

    NSString *sub = nil;
    BOOL ok = [gA2TLSPskBackend connectToHost:host
                                        port:port
                                         psk:psk
                                    identity:(identity ?: @"")
                                     timeout:timeout
                                      reason:&sub];
    self.state = ok ? A2TLSPskTunnelStateReady : A2TLSPskTunnelStateFailed;
    if (!ok && reason) { *reason = sub ?: @"后端建连失败（未给出原因——★视为不谎报的失败★）"; }
    return ok;
}

- (BOOL)sendFrame:(NSData *)frame
          timeout:(NSTimeInterval)timeout
           reason:(NSString *_Nullable *_Nullable)reason {
    if (self.state != A2TLSPskTunnelStateReady || gA2TLSPskBackend == nil) {
        if (reason) { *reason = @"隧道未就绪（未建连或已关闭）"; }
        return NO;
    }
    return [gA2TLSPskBackend sendFrame:frame timeout:timeout reason:reason];
}

- (nullable NSData *)receiveFrameWithTimeout:(NSTimeInterval)timeout
                                      reason:(NSString *_Nullable *_Nullable)reason {
    if (self.state != A2TLSPskTunnelStateReady || gA2TLSPskBackend == nil) {
        if (reason) { *reason = @"隧道未就绪（未建连或已关闭）"; }
        return nil;
    }
    return [gA2TLSPskBackend receiveFrameWithTimeout:timeout reason:reason];
}

- (void)close {
    if (gA2TLSPskBackend != nil) {
        [gA2TLSPskBackend close];
    }
    self.state = A2TLSPskTunnelStateClosed;
}

@end
