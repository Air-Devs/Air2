// ============================================================================
//  Natives/Support/a2_tlspsk_selftest.m
//  Air2 —— [A2-PAIR-ONDEVICE] TLS-PSK 隧道回环自检实现
// ----------------------------------------------------------------------------
//  分工（刻意）：
//    · 服务端：**同一份 mbedTLS**、TLS1.2、静态 PSK（`psk_cb` 不校验 identity）、
//      套件白名单同样是 0x00AF/0x008C —— 与设备侧的要求一致（规格 §12）；
//    · 客户端：**生产路径** `A2TLSPskTunnel`（门面）→ `a2_tlspsk_mbedtls.m`（后端），
//      不绕过任何一层 ⇒ 通过即代表真实调用链可用。
//    · 帧格式同样是隧道约定（4B 大端长度 + 载荷），顺带证明收发分帧正确。
//
//  ★为什么 identity 用非空★：mbedTLS 3.6 在 `psk_identity_len == 0` 时**根本不提供
//    PSK 套件**（实测：对 OpenSSL `s_server` 直接 `no shared cipher`），所以「空
//    identity」这条路 mbedTLS 表达不出来。设备是否忽略 identity 必须真机验
//    （详见 docs/ONDEVICE-PAIR.md §3）。
//
//  SPDX-License-Identifier: GPL-3.0-or-later
// ============================================================================
#import "a2_tlspsk_selftest.h"
#import "a2_tlspsk_tunnel.h"
#import "a2_log.h"

#import <Security/Security.h>

#if __has_include(<mbedtls/ssl.h>) && __has_include(<mbedtls/entropy.h>) && \
    __has_include(<mbedtls/ctr_drbg.h>) && __has_include(<mbedtls/net_sockets.h>)
#  define A2_TLSPK_SELFTEST_HAVE_MBEDTLS 1
#  import <mbedtls/ssl.h>
#  import <mbedtls/ssl_ciphersuites.h>
#  import <mbedtls/entropy.h>
#  import <mbedtls/ctr_drbg.h>
#  import <mbedtls/net_sockets.h>
#  import <mbedtls/error.h>
#  import <mbedtls/build_info.h>
#  include <arpa/inet.h>
#  include <netinet/in.h>
#  include <sys/select.h>
#  include <sys/socket.h>
#  include <unistd.h>
#else
#  define A2_TLSPK_SELFTEST_HAVE_MBEDTLS 0
#endif

NSTimeInterval const A2TLSPskSelfTestDefaultTimeout = 8.0;

@implementation A2TLSPskSelfTestResult

- (instancetype)init {
    self = [super init];
    if (self) {
        _cipherSuite = @"-";
        _tlsVersion = @"-";
        _detail = @"";
    }
    return self;
}

- (NSString *)criterionLine {
    return [NSString stringWithFormat:
            @"[A2-TLSPK-SELFTEST] passed=%@ suite=%@ version=%@ echo=%luB %.2fs detail=%@",
            _passed ? @"yes" : @"no", _cipherSuite, _tlsVersion,
            (unsigned long) _echoBytes, _elapsed, _detail];
}

@end

#if A2_TLSPK_SELFTEST_HAVE_MBEDTLS

// ---------------------------------------------------------------------------
// 回环服务端（与生产同一份 mbedTLS；只做「收一帧、原样回一帧」）
// ---------------------------------------------------------------------------

static const int kA2TLSPskSuites[] = { 0x00AF, 0x008C, 0 };

typedef struct {
    int              listen_fd;
    int              port;
    const unsigned char *psk;
    size_t           psk_len;
    int              rc;            ///< 0 = 成功；负 = 卡住的 mbedtls 返回值
    int              stage;         ///< 卡在哪一步（1 bind 2 listen 3 accept 4 conf 5 handshake 6 io）
    int              suite_id;
    char             version[16];
    size_t           echo_bytes;
    char             err[160];
} A2PskLoopServer;

static int a2_psk_srv_cb(void *ctx, mbedtls_ssl_context *ssl,
                         const unsigned char *identity, size_t identity_len) {
    A2PskLoopServer *srv = (A2PskLoopServer *) ctx;
    (void) identity; (void) identity_len;   // ★不校验 identity★（与设备侧「只认 PSK」一致）
    return mbedtls_ssl_set_hs_psk(ssl, srv->psk, srv->psk_len);
}

/// 一次完整的服务端会话（在后台线程跑）。
static void a2_psk_loop_server_run(A2PskLoopServer *srv, NSTimeInterval timeout) {
    srv->stage = 1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { srv->rc = -1; return; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_len = sizeof(addr);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   // ★只听 127.0.0.1★
    addr.sin_port = 0;                                // ★端口交给系统选★
    if (bind(fd, (struct sockaddr *) &addr, sizeof(addr)) != 0) {
        srv->rc = -2; close(fd); return;
    }
    socklen_t alen = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *) &addr, &alen) != 0) {
        srv->rc = -3; close(fd); return;
    }
    srv->port = ntohs(addr.sin_port);
    srv->stage = 2;
    if (listen(fd, 1) != 0) { srv->rc = -4; close(fd); return; }
    srv->listen_fd = fd;

    srv->stage = 3;
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(fd, &rfds);
    struct timeval tv;
    tv.tv_sec = (time_t) timeout;
    tv.tv_usec = 0;
    int sel = select(fd + 1, &rfds, NULL, NULL, &tv);
    if (sel <= 0) { srv->rc = -5; close(fd); srv->listen_fd = -1; return; }
    int cfd = accept(fd, NULL, NULL);
    close(fd);
    srv->listen_fd = -1;
    if (cfd < 0) { srv->rc = -6; return; }
    struct timeval iotv;
    iotv.tv_sec = (time_t) timeout;
    iotv.tv_usec = 0;
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &iotv, sizeof(iotv));
    setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &iotv, sizeof(iotv));

    srv->stage = 4;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&drbg);

    const char *pers = "a2-tlspsk-selftest-srv";
    int ret = mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy,
                                    (const unsigned char *) pers, strlen(pers));
    if (ret != 0) { srv->rc = ret; snprintf(srv->err, sizeof(srv->err), "drbg_seed"); goto done; }

    ret = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_SERVER,
                                      MBEDTLS_SSL_TRANSPORT_STREAM,
                                      MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) { srv->rc = ret; snprintf(srv->err, sizeof(srv->err), "config_defaults"); goto done; }
    mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &drbg);
    mbedtls_ssl_conf_min_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_max_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_ciphersuites(&conf, kA2TLSPskSuites);
    mbedtls_ssl_conf_psk_cb(&conf, a2_psk_srv_cb, srv);
    mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);

    ret = mbedtls_ssl_setup(&ssl, &conf);
    if (ret != 0) { srv->rc = ret; snprintf(srv->err, sizeof(srv->err), "ssl_setup"); goto done; }

    mbedtls_net_context net;
    mbedtls_net_init(&net);
    net.fd = cfd;   // 复用已 accept 的 fd（mbedtls_net_context 只有一个 fd 字段）
    mbedtls_ssl_set_bio(&ssl, &net, mbedtls_net_send, mbedtls_net_recv, NULL);

    srv->stage = 5;
    while ((ret = mbedtls_ssl_handshake(&ssl)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) break;
    }
    if (ret != 0) {
        srv->rc = ret;
        mbedtls_strerror(ret, srv->err, sizeof(srv->err));
        goto done;
    }
    srv->suite_id = mbedtls_ssl_get_ciphersuite_id_from_ssl(&ssl);
    snprintf(srv->version, sizeof(srv->version), "%s", mbedtls_ssl_get_version(&ssl));

    srv->stage = 6;
    {
        // 隧道帧：4B 大端长度 + 载荷（与 a2_tlspsk_mbedtls.m 的线格式一致）
        unsigned char hdr[4];
        size_t got = 0;
        while (got < sizeof(hdr)) {
            ret = mbedtls_ssl_read(&ssl, hdr + got, sizeof(hdr) - got);
            if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (ret <= 0) { srv->rc = ret ? ret : -7; snprintf(srv->err, sizeof(srv->err), "read_hdr"); goto done; }
            got += (size_t) ret;
        }
        uint32_t n = ((uint32_t) hdr[0] << 24) | ((uint32_t) hdr[1] << 16) |
                     ((uint32_t) hdr[2] << 8) | (uint32_t) hdr[3];
        if (n == 0 || n > 4096) { srv->rc = -8; snprintf(srv->err, sizeof(srv->err), "bad_len=%u", n); goto done; }
        unsigned char *body = (unsigned char *) malloc(n);
        size_t have = 0;
        while (have < n) {
            ret = mbedtls_ssl_read(&ssl, body + have, n - have);
            if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (ret <= 0) { free(body); srv->rc = ret ? ret : -9; snprintf(srv->err, sizeof(srv->err), "read_body"); goto done; }
            have += (size_t) ret;
        }
        // 原样回显（长度前缀 + 同一份载荷）
        if (mbedtls_ssl_write(&ssl, hdr, sizeof(hdr)) != (int) sizeof(hdr)) {
            free(body); srv->rc = -10; snprintf(srv->err, sizeof(srv->err), "write_hdr"); goto done;
        }
        size_t sent = 0;
        while (sent < n) {
            ret = mbedtls_ssl_write(&ssl, body + sent, n - sent);
            if (ret <= 0) { free(body); srv->rc = -11; snprintf(srv->err, sizeof(srv->err), "write_body"); goto done; }
            sent += (size_t) ret;
        }
        srv->echo_bytes = n;
        free(body);
        mbedtls_ssl_close_notify(&ssl);
    }

done:
    srv->listen_fd = -1;
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    mbedtls_ctr_drbg_free(&drbg);
    mbedtls_entropy_free(&entropy);
    if (cfd >= 0) close(cfd);
}

static void a2_selftest_server_entry(A2PskLoopServer *srv) {
    a2_psk_loop_server_run(srv, 6.0);
}

#endif /* A2_TLSPK_SELFTEST_HAVE_MBEDTLS */

A2TLSPskSelfTestResult *A2TLSPskSelfTestRun(NSTimeInterval timeout) {
    if (timeout <= 0) {
        timeout = A2TLSPskSelfTestDefaultTimeout;
    }
    NSDate *start = [NSDate date];
    A2TLSPskSelfTestResult *r = [[A2TLSPskSelfTestResult alloc] init];

#if !A2_TLSPK_SELFTEST_HAVE_MBEDTLS
    r.passed = NO;
    r.detail = @"未编入 mbedTLS（编译期 __has_include(<mbedtls/ssl.h>) 失败）⇒ 无法自检";
    r.elapsed = -[start timeIntervalSinceNow];
    a2_log_f(@"[A2-TLSPK-SELFTEST] passed=no detail=%s", r.detail.UTF8String);
    return r;
#else
    // ---- 1) 生成一次性 PSK（32B，CSPRNG）----
    unsigned char psk[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(psk), psk) != errSecSuccess) {
        r.passed = NO;
        r.detail = @"取随机 PSK 失败（SecRandomCopyBytes）⇒ 自检不做假";
        r.elapsed = -[start timeIntervalSinceNow];
        a2_log_f(@"[A2-TLSPK-SELFTEST] passed=no detail=%s", r.detail.UTF8String);
        return r;
    }

    // ---- 2) 后台起回环服务端，等它报出端口 ----
    // ★必须是 __block★：普通局部结构被 block 捕获时是**按值复制**，
    //   线程里写进去的 port/rc/stage 全落在副本上 ⇒ 主线程永远读到 port==0
    //   （本轮实测踩过：自检恒报「回环服务端未能就位 stage=0 rc=-999」）。
    __block A2PskLoopServer srv;
    memset(&srv, 0, sizeof(srv));
    srv.listen_fd = -1;
    srv.psk = psk;
    srv.psk_len = sizeof(psk);
    srv.rc = -999;

    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        a2_selftest_server_entry(&srv);
    }];
    thread.name = @"A2TLSPskSelfTestServer";
    [thread start];

    NSTimeInterval deadline = [NSDate date].timeIntervalSince1970 + timeout;
    while (srv.port == 0 && srv.rc == -999 && [NSDate date].timeIntervalSince1970 < deadline) {
        [NSThread sleepForTimeInterval:0.005];
    }
    if (srv.port == 0) {
        r.passed = NO;
        r.detail = [NSString stringWithFormat:@"回环服务端未能就位（stage=%d rc=%d）", srv.stage, srv.rc];
        r.elapsed = -[start timeIntervalSinceNow];
        a2_log_f(@"[A2-TLSPK-SELFTEST] passed=no detail=%s", r.detail.UTF8String);
        return r;
    }

    // ---- 3) 走**生产路径**建连（门面 + mbedTLS 后端）----
    A2TLSPskTunnel *tunnel = [A2TLSPskTunnel sharedTunnel];
    BOOL wasEnabled = tunnel.isEnabled;
    tunnel.enabled = YES;                 // ★只在本自检期间打开★
    NSString *why = nil;
    BOOL ok = [tunnel connectToHost:@"127.0.0.1"
                               port:(uint16_t) srv.port
                                psk:[NSData dataWithBytes:psk length:sizeof(psk)]
                           identity:@"a2-selftest"
                            timeout:timeout
                             reason:&why];

    NSUInteger echoed = 0;
    if (ok) {
        NSData *payload = [@"a2-tlspsk-selftest" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *sendWhy = nil;
        if (![tunnel sendFrame:payload timeout:timeout reason:&sendWhy]) {
            ok = NO;
            why = [NSString stringWithFormat:@"发帧失败：%@", sendWhy ?: @"-"];
        } else {
            NSString *recvWhy = nil;
            NSData *echo = [tunnel receiveFrameWithTimeout:timeout reason:&recvWhy];
            if (echo == nil) {
                ok = NO;
                why = [NSString stringWithFormat:@"收帧失败：%@", recvWhy ?: @"-"];
            } else if (![echo isEqualToData:payload]) {
                ok = NO;
                why = [NSString stringWithFormat:@"回显不一致（收到 %lu B）", (unsigned long) echo.length];
            } else {
                echoed = echo.length;
            }
        }
    }
    // ★在 close 之前读协商摘要★（close 会把状态置 Closed，之后 negotiatedSummary 如实回「未握手」）。
    NSString *summary = [tunnel negotiatedSummary];
    [tunnel close];
    tunnel.enabled = wasEnabled;          // ★恢复原开关★（默认关不许被自检悄悄打开）

    // 等服务端收尾（最多 timeout），保证日志顺序与 echo 计数一致。
    while (!thread.isFinished && [NSDate date].timeIntervalSince1970 < deadline + 2.0) {
        [NSThread sleepForTimeInterval:0.01];
    }

    r.cipherSuite = [tunnel.lastNegotiatedCipherSuite length] ? tunnel.lastNegotiatedCipherSuite : @"-";
    r.tlsVersion = [tunnel.lastNegotiatedTLSVersion length] ? tunnel.lastNegotiatedTLSVersion : @"-";
    r.echoBytes = echoed;
    r.passed = ok && echoed > 0;
    if (r.passed) {
        r.detail = [NSString stringWithFormat:@"回环握手完成（%@ / %@），帧回显 %lu B%@",
                    r.tlsVersion, r.cipherSuite, (unsigned long) echoed,
                    summary.length ? [NSString stringWithFormat:@"，%@", summary] : @""];
    } else {
        r.detail = why.length ? why : [NSString stringWithFormat:
                                       @"握手后回显失败（服务端 stage=%d rc=%d err=%s）",
                                       srv.stage, srv.rc, srv.err];
        if (!ok && srv.rc != 0 && srv.stage >= 5 && srv.err[0]) {
            r.detail = [NSString stringWithFormat:@"%@（服务端：%s）", r.detail, srv.err];
        }
    }
    r.elapsed = -[start timeIntervalSinceNow];
    a2_log_f(@"%s", r.criterionLine.UTF8String);
    return r;
#endif
}
