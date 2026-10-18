// ============================================================================
//  Natives/Support/a2_tlspsk_mbedtls.m
//  Air2 —— [A2-INTEGRATION] TLS-PSK 隧道 ●mbedTLS 后端●（第三方，Apache-2.0）
// ----------------------------------------------------------------------------
//  只在「TLS-PSK 隧道」这一件事上使用 mbedTLS：
//      · TLS 1.2，客户端，静态 PSK（`mbedtls_ssl_conf_psk`），只开 §12 的两个套件
//        0x00AF / 0x008C（★用 `mbedtls_ssl_conf_ciphersuites` 白名单锁死★，不给协商甜头）；
//      · 无证书校验（PSK 模式；`MBEDTLS_SSL_VERIFY_NONE`）；
//      · 帧 = 4 字节大端长度 + 载荷（由本文件实现，属于「隧道线格式」，非 TLS 语义）。
//  熵：库以 `-DMBEDTLS_ENTROPY_HARDWARE_ALT` 编成 ⇒ 由本文件的 `mbedtls_hardware_poll`
//      用 iOS 公开的 `SecRandomCopyBytes` 提供（★不读 /dev/urandom，不改库配置★）。
//
//  ★不上云★：真正的地址准入在门面 `a2_tlspsk_tunnel.m`（本文件只做传输，不决定能不能连）。
//
//  许可：本文件归 Air2 项目本人；链接的 mbedTLS 为 Apache-2.0（见
//        Libraries/ThirdParty/mbedtls/LICENSE 与 docs/DEPENDENCIES.md）。
// ============================================================================
#import "a2_tlspsk_mbedtls.h"
#import "a2_tlspsk_tunnel.h"
#import "a2_log.h"

#import <Security/Security.h>
#import <string.h>
#import <sys/socket.h>

#if __has_include(<mbedtls/ssl.h>) && __has_include(<mbedtls/entropy.h>) && \
    __has_include(<mbedtls/ctr_drbg.h>) && __has_include(<mbedtls/net_sockets.h>)
#  define A2_TLSPK_HAVE_MBEDTLS 1
#  import <mbedtls/ssl.h>
#  import <mbedtls/ssl_ciphersuites.h>
#  import <mbedtls/entropy.h>
#  import <mbedtls/ctr_drbg.h>
#  import <mbedtls/net_sockets.h>
#  import <mbedtls/error.h>
#  import <mbedtls/build_info.h>
#  import <mbedtls/version.h>
#else
#  define A2_TLSPK_HAVE_MBEDTLS 0
#endif

// ---------------------------------------------------------------------------
// 编译期事实（不猜）
// ---------------------------------------------------------------------------

NSString *A2TLSPskMbedTLSVersionString(void) {
#if A2_TLSPK_HAVE_MBEDTLS
    return @MBEDTLS_VERSION_STRING_FULL;
#else
    return @"未编入";
#endif
}

#if A2_TLSPK_HAVE_MBEDTLS

// ---------------------------------------------------------------------------
// 熵源：mbedTLS ALT 钩子 → iOS 公开 API（SecRandomCopyBytes）
// ---------------------------------------------------------------------------
int mbedtls_hardware_poll(void *data, unsigned char *output, size_t len, size_t *olen) {
    (void) data;
    if (output == NULL || olen == NULL) {
        return -1;
    }
    if (SecRandomCopyBytes(kSecRandomDefault, len, output) != errSecSuccess) {
        *olen = 0;
        return -1;
    }
    *olen = len;
    return 0;
}

#pragma mark - 后端

@interface A2TLSPskMbedTLSBackend : NSObject <A2TLSPskTunnelBackend>
@end

@implementation A2TLSPskMbedTLSBackend {
    mbedtls_ssl_context        _ssl;
    mbedtls_ssl_config         _conf;
    mbedtls_entropy_context    _entropy;
    mbedtls_ctr_drbg_context   _ctrDrbg;
    mbedtls_net_context        _net;
    BOOL                       _inited;      // 上述结构是否已 init（保证 free 幂等）
    BOOL                       _handshaked;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _inited = NO;
        _handshaked = NO;
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (NSString *)backendName {
    return [NSString stringWithFormat:@"mbedTLS %@", @MBEDTLS_VERSION_STRING];
}

- (BOOL)isAvailableWithReason:(NSString *_Nullable *_Nullable)reason {
    // 编进来了 ⇒ 可用（真握手仍要真对端；可用性只陈述「后端就绪」）。
    if (reason) { *reason = @""; }
    return YES;
}

- (BOOL)setupIfNeededWithReason:(NSString *_Nullable *_Nullable)reason {
    if (_inited) {
        return YES;
    }
    mbedtls_ssl_init(&_ssl);
    mbedtls_ssl_config_init(&_conf);
    mbedtls_entropy_init(&_entropy);
    mbedtls_ctr_drbg_init(&_ctrDrbg);
    mbedtls_net_init(&_net);
    _inited = YES;
    (void) reason;
    return YES;
}

- (void)close {
    if (!_inited) {
        return;
    }
    if (_handshaked) {
        (void) mbedtls_ssl_close_notify(&_ssl);
        _handshaked = NO;
    }
    mbedtls_net_free(&_net);
    mbedtls_ssl_free(&_ssl);
    mbedtls_ssl_config_free(&_conf);
    mbedtls_ctr_drbg_free(&_ctrDrbg);
    mbedtls_entropy_free(&_entropy);
    _inited = NO;
}

- (BOOL)connectToHost:(NSString *)host
                 port:(uint16_t)port
                  psk:(NSData *)psk
             identity:(NSString *)identity
              timeout:(NSTimeInterval)timeout
               reason:(NSString *_Nullable *_Nullable)reason {
    [self close];
    if (![self setupIfNeededWithReason:reason]) { return NO; }

    const char *pers = "a2-tlspsk";
    int ret = mbedtls_ctr_drbg_seed(&_ctrDrbg, mbedtls_entropy_func, &_entropy,
                                    (const unsigned char *) pers, strlen(pers));
    if (ret != 0) {
        if (reason) { *reason = [NSString stringWithFormat:@"CTR_DRBG 播种失败（mbedtls rc=%d）", ret]; }
        [self close];
        return NO;
    }

    ret = mbedtls_ssl_config_defaults(&_conf,
                                      MBEDTLS_SSL_IS_CLIENT,
                                      MBEDTLS_SSL_TRANSPORT_STREAM,
                                      MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) {
        if (reason) { *reason = [NSString stringWithFormat:@"ssl_config_defaults 失败（mbedtls rc=%d）", ret]; }
        [self close];
        return NO;
    }

    mbedtls_ssl_conf_rng(&_conf, mbedtls_ctr_drbg_random, &_ctrDrbg);
    mbedtls_ssl_conf_authmode(&_conf, MBEDTLS_SSL_VERIFY_NONE);           // PSK ⇒ 无证书链
    mbedtls_ssl_conf_min_tls_version(&_conf, MBEDTLS_SSL_VERSION_TLS1_2); // §12 = TLS 1.2
    mbedtls_ssl_conf_max_tls_version(&_conf, MBEDTLS_SSL_VERSION_TLS1_2);

    // ★只开设备要的两个套件★（规格 §12：0x00AF / 0x008C），其余一律不给。
    static const int kSuites[] = { 0x00AF, 0x008C, 0 };
    mbedtls_ssl_conf_ciphersuites(&_conf, kSuites);

    // 静态 PSK（identity 为空串表示无 identity，符合 §12 的对称约定）。
    NSData *idData = [(identity ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    ret = mbedtls_ssl_conf_psk(&_conf,
                               (const unsigned char *) psk.bytes, psk.length,
                               (const unsigned char *) (idData.length ? idData.bytes : (const void *) ""),
                               idData.length);
    if (ret != 0) {
        if (reason) { *reason = [NSString stringWithFormat:@"conf_psk 失败（mbedtls rc=%d；PSK 长度=%lu）",
                                 ret, (unsigned long) psk.length]; }
        [self close];
        return NO;
    }

    ret = mbedtls_ssl_setup(&_ssl, &_conf);
    if (ret != 0) {
        if (reason) { *reason = [NSString stringWithFormat:@"ssl_setup 失败（mbedtls rc=%d）", ret]; }
        [self close];
        return NO;
    }

    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%u", (unsigned) port);
    ret = mbedtls_net_connect(&_net, host.UTF8String, portStr, MBEDTLS_NET_PROTO_TCP);
    if (ret != 0) {
        if (reason) { *reason = [NSString stringWithFormat:@"TCP 连接 %@:%u 失败（mbedtls rc=%d）",
                                 host, (unsigned) port, ret]; }
        [self close];
        return NO;
    }

    // 收发超时（尽力而为；BSD socket 层面）。
    if (timeout > 0 && _net.fd >= 0) {
        struct timeval tv;
        tv.tv_sec = (time_t) timeout;
        tv.tv_usec = (suseconds_t) ((timeout - (NSTimeInterval) tv.tv_sec) * 1000000.0);
        (void) setsockopt(_net.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        (void) setsockopt(_net.fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    }

    mbedtls_ssl_set_bio(&_ssl, &_net, mbedtls_net_send, mbedtls_net_recv, NULL);

    while ((ret = mbedtls_ssl_handshake(&_ssl)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
            char ebuf[128] = {0};
            mbedtls_strerror(ret, ebuf, sizeof(ebuf));
            if (reason) {
                *reason = [NSString stringWithFormat:@"PSK 握手失败（mbedtls rc=%d：%s）",
                           ret, ebuf];
            }
            [self close];
            return NO;
        }
    }
    _handshaked = YES;
    return YES;
}

- (BOOL)sendFrame:(NSData *)frame
          timeout:(NSTimeInterval)timeout
           reason:(NSString *_Nullable *_Nullable)reason {
    (void) timeout;
    if (!_handshaked) {
        if (reason) { *reason = @"隧道未完成握手"; }
        return NO;
    }
    uint32_t n = (uint32_t) frame.length;
    unsigned char hdr[4];
    hdr[0] = (unsigned char) ((n >> 24) & 0xFF);
    hdr[1] = (unsigned char) ((n >> 16) & 0xFF);
    hdr[2] = (unsigned char) ((n >> 8) & 0xFF);
    hdr[3] = (unsigned char) (n & 0xFF);
    int ret = mbedtls_ssl_write(&_ssl, hdr, sizeof(hdr));
    if (ret != (int) sizeof(hdr)) {
        if (reason) { *reason = [NSString stringWithFormat:@"发送长度前缀失败（mbedtls rc=%d）", ret]; }
        return NO;
    }
    const unsigned char *p = (const unsigned char *) frame.bytes;
    size_t left = frame.length;
    while (left > 0) {
        ret = mbedtls_ssl_write(&_ssl, p, left);
        if (ret <= 0) {
            if (reason) { *reason = [NSString stringWithFormat:@"发送载荷失败（mbedtls rc=%d）", ret]; }
            return NO;
        }
        p += ret;
        left -= (size_t) ret;
    }
    return YES;
}

- (nullable NSData *)receiveFrameWithTimeout:(NSTimeInterval)timeout
                                      reason:(NSString *_Nullable *_Nullable)reason {
    (void) timeout;
    if (!_handshaked) {
        if (reason) { *reason = @"隧道未完成握手"; }
        return nil;
    }
    unsigned char hdr[4];
    size_t got = 0;
    while (got < sizeof(hdr)) {
        int ret = mbedtls_ssl_read(&_ssl, hdr + got, sizeof(hdr) - got);
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) { continue; }
        if (ret <= 0) {
            if (reason) { *reason = [NSString stringWithFormat:@"读取长度前缀失败（mbedtls rc=%d）", ret]; }
            return nil;
        }
        got += (size_t) ret;
    }
    uint32_t n = ((uint32_t) hdr[0] << 24) | ((uint32_t) hdr[1] << 16) |
                 ((uint32_t) hdr[2] << 8) | (uint32_t) hdr[3];
    if (n > (16u * 1024u * 1024u)) {
        if (reason) { *reason = [NSString stringWithFormat:@"帧长度异常（%u > 16MB）", n]; }
        return nil;
    }
    NSMutableData *out = [NSMutableData dataWithLength:n];
    unsigned char *dst = (unsigned char *) out.mutableBytes;
    size_t have = 0;
    while (have < n) {
        int ret = mbedtls_ssl_read(&_ssl, dst + have, n - have);
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) { continue; }
        if (ret <= 0) {
            if (reason) { *reason = [NSString stringWithFormat:@"读取载荷失败（mbedtls rc=%d）", ret]; }
            return nil;
        }
        have += (size_t) ret;
    }
    return out;
}

@end

#endif /* A2_TLSPK_HAVE_MBEDTLS */

#pragma mark - 注册入口

static int gA2TLSPskRegistered = 0;

void A2TLSPskMbedTLSEnsureRegistered(void) {
#if A2_TLSPK_HAVE_MBEDTLS
    if (gA2TLSPskRegistered) {
        return;
    }
    gA2TLSPskRegistered = 1;
    A2TLSPskMbedTLSBackend *b = [[A2TLSPskMbedTLSBackend alloc] init];
    [A2TLSPskTunnel registerBackend:b];
    a2_log_f(@"[A2-TLSPK] 已注册 mbedTLS 后端：%s（TLS 1.2 / 静态 PSK / 套件 0x00AF,0x008C / ★默认关★）",
             [A2TLSPskMbedTLSVersionString() UTF8String]);
#else
    // ★不谎报★：编译期就没有 mbedTLS 头 ⇒ 不注册任何后端，只留一条实证日志。
    a2_log_f(@"[A2-TLSPK] 未编入 mbedTLS（编译期 __has_include(<mbedtls/ssl.h>) 失败）"
             @"⇒ 不注册后端；门面将如实报「未注册任何 TLS-PSK 后端」");
#endif
}
