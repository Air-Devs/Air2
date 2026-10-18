//
//  SOCKS5Proxy.m
//  Angel Aura Amethyst
//
//  本地 SOCKS5 代理服务器实现
//
//  ============================================================================
//  实现说明
//  ============================================================================
//
//  本文件实现 SOCKS5Proxy.h 中定义的本地 SOCKS5 代理服务器。
//
//  关键实现点：
//    1. 监听 socket 使用系统 POSIX socket（socket/bind/listen/accept）
//    2. 客户端连接后，在新线程中处理 SOCKS5 握手和数据转发
//    3. SOCKS5 协议实现遵循 RFC 1928，支持无认证方式和 CONNECT 命令
//    4. 目标地址支持 IPv4、IPv6 和域名三种类型
//    5. 远程连接通过 ZeroTierBridge 的 libzt socket API 建立
//    6. 双向转发使用 GCD 并发队列，两个方向同时转发
//    7. 所有在 block 内赋值的局部变量使用 __block 修饰符
//
//  线程模型：
//    - 主线程：startWithPort:error: / stop
//    - Accept 线程：NSThread，循环 accept 新连接
//    - 客户端处理线程：NSThread，每个客户端一个
//    - 转发任务：GCD 并发队列，每个连接两个任务（client→remote、remote→client）
//
//  SOCKS5 协议常量（RFC 1928）：
//    VER = 0x05（SOCKS 版本 5）
//    METHOD_NO_AUTH = 0x00（无认证）
//    METHOD_NO_ACCEPTABLE = 0xFF（无可接受的认证方法）
//    CMD_CONNECT = 0x01（CONNECT 命令）
//    ATYP_IPV4 = 0x01（IPv4 地址）
//    ATYP_DOMAIN = 0x03（域名）
//    ATYP_IPV6 = 0x04（IPv6 地址）
//
//  ============================================================================

#import "SOCKS5Proxy.h"
#import "ZeroTierBridge.h"
#import "utils.h"

// POSIX socket 头文件
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>  // TCP_NODELAY
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/select.h>
#include <sys/time.h>
#include <stdatomic.h>  // C11 原子操作
#include <netdb.h>      // getaddrinfo（域名解析，用于 P0-2）

#pragma mark - 常量定义

/// SOCKS5 代理默认监听端口
const uint16_t SOCKS5ProxyDefaultPort = 1080;

/// 客户端连接通知名
NSNotificationName const SOCKS5ProxyClientConnectedNotification = @"SOCKS5ProxyClientConnectedNotification";

/// 客户端断开通知名
NSNotificationName const SOCKS5ProxyClientDisconnectedNotification = @"SOCKS5ProxyClientDisconnectedNotification";

/// 错误域名
static NSString * const kSOCKS5ProxyErrorDomain = @"SOCKS5ProxyErrorDomain";

/// 错误码
typedef NS_ENUM(NSInteger, SOCKS5ProxyErrorCode) {
    SOCKS5ProxyErrorCodeAlreadyRunning        = 1, // 代理已在运行
    SOCKS5ProxyErrorCodeSocketCreateFailed    = 2, // 创建 socket 失败
    SOCKS5ProxyErrorCodeBindFailed            = 3, // 绑定端口失败
    SOCKS5ProxyErrorCodeListenFailed          = 4, // 监听失败
    SOCKS5ProxyErrorCodeFrameworkUnavailable  = 5, // ZeroTier framework 不可用
};

/// SOCKS5 协议常量（RFC 1928）
#define SOCKS5_VERSION                 0x05
#define SOCKS5_METHOD_NO_AUTH          0x00
#define SOCKS5_METHOD_USER_PASS        0x02
#define SOCKS5_METHOD_NO_ACCEPTABLE    0xFF
#define SOCKS5_CMD_CONNECT             0x01
#define SOCKS5_CMD_BIND                0x02
#define SOCKS5_CMD_UDP_ASSOCIATE       0x03
#define SOCKS5_ATYP_IPV4               0x01
#define SOCKS5_ATYP_DOMAIN             0x03
#define SOCKS5_ATYP_IPV6               0x04

/// SOCKS5 回复码（RFC 1928 第 6 节）
#define SOCKS5_REP_SUCCESS                    0x00
#define SOCKS5_REP_GENERAL_FAILURE            0x01
#define SOCKS5_REP_NOT_ALLOWED                0x02
#define SOCKS5_REP_NETWORK_UNREACHABLE        0x03
#define SOCKS5_REP_HOST_UNREACHABLE           0x04
#define SOCKS5_REP_CONNECTION_REFUSED         0x05
#define SOCKS5_REP_TTL_EXPIRED                0x06
#define SOCKS5_REP_COMMAND_NOT_SUPPORTED      0x07
#define SOCKS5_REP_ADDRESS_TYPE_NOT_SUPPORTED 0x08

/// 数据转发缓冲区大小（64KB）
#define SOCKS5_BUFFER_SIZE 65536

/// 连接远程主机的超时时间（秒）
#define SOCKS5_CONNECT_TIMEOUT 30.0

/// 客户端 socket 读写超时（秒）
/// 防止恶意客户端只发送部分数据后保持连接不发送，导致服务器线程永久阻塞
#define SOCKS5_CLIENT_IO_TIMEOUT 30

/// 客户端握手阶段的读写超时（秒）
#define SOCKS5_HANDSHAKE_TIMEOUT 15

#pragma mark - 辅助函数

/// 完整读取指定长度的数据（带超时）
///
/// read() 系统调用可能不会一次性返回所有请求的字节，需要循环读取。
/// 本函数会阻塞直到读取到指定长度或连接关闭。
///
/// 关键修复（H9）：使用 select 实现超时，防止恶意客户端只发送部分数据后
/// 保持连接但不发送更多数据，导致服务器线程永久阻塞。
///
/// @param fd socket 文件描述符
/// @param buf 接收缓冲区
/// @param len 需要读取的长度
/// @param timeoutSec 超时秒数（≤0 表示阻塞模式，无超时）
/// @return 实际读取的字节数（< len 表示连接已关闭或出错，-1 表示错误或超时）
static ssize_t readAllWithTimeout(int fd, void *buf, size_t len, int timeoutSec) {
    size_t totalRead = 0;
    uint8_t *p = (uint8_t *)buf;

    while (totalRead < len) {
        // 使用 select 检查 socket 可读，带超时
        if (timeoutSec > 0) {
            fd_set readFds;
            FD_ZERO(&readFds);
            FD_SET(fd, &readFds);

            struct timeval tv;
            tv.tv_sec = timeoutSec;
            tv.tv_usec = 0;

            int selectResult = select(fd + 1, &readFds, NULL, NULL, &tv);
            if (selectResult < 0) {
                if (errno == EINTR) {
                    continue;
                }
                NSLog(@"[SOCKS5Proxy] readAll select error: errno = %d, fd = %d", errno, fd);
                return -1;
            }
            if (selectResult == 0) {
                // 超时
                NSLog(@"[SOCKS5Proxy] readAll timeout (%d sec), fd = %d, read %zu/%zu bytes",
                      timeoutSec, fd, totalRead, len);
                return totalRead > 0 ? (ssize_t)totalRead : -1;
            }
        }

        ssize_t n = read(fd, p + totalRead, len - totalRead);
        if (n < 0) {
            // 被信号中断，重试
            if (errno == EINTR) {
                continue;
            }
            // 其他错误
            NSLog(@"[SOCKS5Proxy] readAll error: errno = %d, fd = %d", errno, fd);
            return -1;
        }
        if (n == 0) {
            // 连接已关闭
            return (ssize_t)totalRead;
        }
        totalRead += (size_t)n;
    }

    return (ssize_t)totalRead;
}

/// 兼容旧调用：无超时的 readAll（用于已经设置 SO_RCVTIMEO 的 socket）
static ssize_t readAll(int fd, void *buf, size_t len) {
    return readAllWithTimeout(fd, buf, len, 0);
}

/// 完整写入指定长度的数据（带超时）
///
/// write() 系统调用可能不会一次性写入所有字节，需要循环写入。
///
/// 关键修复（M9）：write 返回 0 视为错误（对端可能已关闭）。
///
/// @param fd socket 文件描述符
/// @param buf 写入缓冲区
/// @param len 需要写入的长度
/// @param timeoutSec 超时秒数（≤0 表示阻塞模式，无超时）
/// @return 实际写入的字节数（< len 表示出错，-1 表示错误或超时）
static ssize_t writeAllWithTimeout(int fd, const void *buf, size_t len, int timeoutSec) {
    size_t totalWritten = 0;
    const uint8_t *p = (const uint8_t *)buf;

    while (totalWritten < len) {
        // 使用 select 检查 socket 可写，带超时
        if (timeoutSec > 0) {
            fd_set writeFds;
            FD_ZERO(&writeFds);
            FD_SET(fd, &writeFds);

            struct timeval tv;
            tv.tv_sec = timeoutSec;
            tv.tv_usec = 0;

            int selectResult = select(fd + 1, NULL, &writeFds, NULL, &tv);
            if (selectResult < 0) {
                if (errno == EINTR) {
                    continue;
                }
                NSLog(@"[SOCKS5Proxy] writeAll select error: errno = %d, fd = %d", errno, fd);
                return -1;
            }
            if (selectResult == 0) {
                // 超时
                NSLog(@"[SOCKS5Proxy] writeAll timeout (%d sec), fd = %d, wrote %zu/%zu bytes",
                      timeoutSec, fd, totalWritten, len);
                return totalWritten > 0 ? (ssize_t)totalWritten : -1;
            }
        }

        ssize_t n = write(fd, p + totalWritten, len - totalWritten);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            NSLog(@"[SOCKS5Proxy] writeAll error: errno = %d, fd = %d", errno, fd);
            return -1;
        }
        if (n == 0) {
            // 关键修复（M9）：write 返回 0 通常表示错误（对端已关闭或缓冲区满）
            NSLog(@"[SOCKS5Proxy] writeAll returned 0, peer may have closed: fd = %d", fd);
            return -1;
        }
        totalWritten += (size_t)n;
    }

    return (ssize_t)totalWritten;
}

/// 兼容旧调用：无超时的 writeAll
static ssize_t writeAll(int fd, const void *buf, size_t len) {
    return writeAllWithTimeout(fd, buf, len, 0);
}

#pragma mark - SOCKS5Proxy 类扩展

@interface SOCKS5Proxy () {
    /// 监听 socket 文件描述符（受 _lock 保护）
    int _listenFD;

    /// 实际监听端口（受 _lock 保护）
    uint16_t _listeningPort;

    /// 是否正在运行（受 _lock 保护）
    BOOL _running;

    /// Accept 线程（接受新客户端连接）
    NSThread *_acceptThread;

    /// 线程锁，保护所有内部状态变量
    NSLock *_lock;

    /// 活跃的客户端处理线程列表（受 _lock 保护）
    NSMutableArray<NSThread *> *_clientThreads;

    /// 关键修复（C1）：活跃的客户端 socket fd 列表（受 _lock 保护）
    /// 用于在 stop 时主动 shutdown 所有客户端连接，强制 read/write 返回，
    /// 避免客户端处理线程因阻塞 IO 无法退出导致线程泄漏。
    NSMutableArray<NSNumber *> *_clientFDs;

    /// 关键修复（M12）：活跃的远程（libzt）socket fd 列表（受 _lock 保护）
    /// 用于在 stop 时主动 shutdown 所有远程连接，强制 recv/send 返回，
    /// 避免客户端线程在 forwardDataBetweenClientFD: 中阻塞在 recvData:remoteFD: 上
    /// 最长 30 秒（SOCKS5_CONNECT_TIMEOUT 设置的 SO_RCVTIMEO）。
    ///
    /// 之前 stop 仅 shutdown 客户端 fd，不处理远程 fd：
    ///   1. client→remote 任务因 read(clientFD) 返回 0 而退出
    ///   2. remote→client 任务仍阻塞在 recvData:remoteFD: 中
    ///      （shutdown(clientFD, SHUT_WR) 只关闭客户端 fd 的写端，不影响远程 fd 的读端）
    ///   3. dispatch_group_wait(group, DISPATCH_TIME_FOREVER) 等待两个方向都完成
    ///   4. 客户端线程在 stop 返回后继续存活最长 30 秒，造成线程和 fd 临时泄漏
    ///
    /// 修复方案：跟踪所有远程 fd，在 stop 时对每个远程 fd 执行 shutdown(SHUT_RDWR)，
    /// 强制 recvData: 立即返回，让客户端线程快速退出。
    NSMutableArray<NSNumber *> *_remoteFDs;
}
@end

#pragma mark - SOCKS5Proxy 实现

@implementation SOCKS5Proxy

#pragma mark - 单例模式

/// 获取共享的 SOCKS5Proxy 单例实例
/// 使用 dispatch_once 保证线程安全的单次初始化
+ (instancetype)sharedProxy {
    static SOCKS5Proxy *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

/// 重写 allocWithZone: 防止通过 alloc/init 创建第二个实例
+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static SOCKS5Proxy *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [super allocWithZone:zone];
    });
    return shared;
}

/// 私有初始化方法
- (instancetype)init {
    self = [super init];
    if (self) {
        _listenFD = -1;
        _listeningPort = 0;
        _running = NO;
        _acceptThread = nil;
        _lock = [[NSLock alloc] init];
        _clientThreads = [[NSMutableArray alloc] init];
        _clientFDs = [[NSMutableArray alloc] init];
        _remoteFDs = [[NSMutableArray alloc] init];

        NSLog(@"[SOCKS5Proxy] Singleton initialized");
    }
    return self;
}

#pragma mark - 启动与停止

/// 启动代理服务器
///
/// 流程：
///   1. 检查是否已运行
///   2. 检查 ZeroTier framework 可用性
///   3. 创建 POSIX socket
///   4. 设置 SO_REUSEADDR
///   5. 绑定到 127.0.0.1:port
///   6. 获取实际绑定端口
///   7. 开始监听
///   8. 启动 Accept 线程
- (BOOL)startWithPort:(uint16_t)port
                error:(NSError **)error {
    // 关键修复（H8）：整个启动流程用锁保护，避免并发调用导致状态混乱
    [_lock lock];

    // 关键修复（C1/H8）：bind 失败 (errno=48 EADDRINUSE) 的根因是上次断开时 socket 未被正确关闭，
    // 或 app 进程崩溃（SIGSEGV）后 _running 标记与实际 socket 状态不一致。
    // 修复方案：启动前先强制停止一次，确保旧的监听 socket 已被关闭，端口被释放。
    if (_running) {
        NSLog(@"[SOCKS5Proxy] Detected proxy still running before startup, stopping old proxy to release port");
        // 临时释放锁以调用 stop（stop 内部会加锁）
        [_lock unlock];
        [self stop];
        // 给系统一点时间释放端口（TIME_WAIT 状态）
        [NSThread sleepForTimeInterval:0.1];
        [_lock lock];
    } else if (_listenFD >= 0) {
        // _running 为 NO 但 _listenFD 仍有效（异常状态），强制关闭
        NSLog(@"[SOCKS5Proxy] Detected zombie listen socket (fd=%d), forcefully closing", _listenFD);
        close(_listenFD);
        _listenFD = -1;
        [NSThread sleepForTimeInterval:0.1];
    }

    // 检查是否已运行（停止后再次检查）
    if (_running) {
        [_lock unlock];
        NSLog(@"[SOCKS5Proxy] Proxy already running, port = %u", _listeningPort);
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeAlreadyRunning
                                      userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_952", nil)}];
        }
        return NO;
    }
    [_lock unlock];

    // 检查 ZeroTier framework 是否可用
    // 如果 framework 不可用，代理无法连接到 ZeroTier 网络，启动没有意义
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[SOCKS5Proxy] Startup failed: ZeroTier framework unavailable");
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeFrameworkUnavailable
                                      userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_953", nil)}];
        }
        return NO;
    }

    NSLog(@"[SOCKS5Proxy] Starting proxy server, requested port = %u", port);

    // 步骤 1：创建监听 socket（系统 POSIX socket，不是 libzt socket）
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"[SOCKS5Proxy] Failed to create socket: errno = %d", errno);
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeSocketCreateFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_954", nil), errno]}];
        }
        return NO;
    }

    // 步骤 2：设置 SO_REUSEADDR，允许端口重用
    // 避免"Address already in use"错误（前一次运行的 socket 处于 TIME_WAIT 状态）
    int opt = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        NSLog(@"[SOCKS5Proxy] Failed to set SO_REUSEADDR: errno = %d (ignoring, continuing)", errno);
    }

    // 步骤 3：绑定到 127.0.0.1:port
    // 只监听本地回环地址，避免暴露到外部网络
    //
    // 关键修复（端口冲突处理）：bind 失败时自动尝试下一个端口。
    //
    // errno=48 (EADDRINUSE) 表示端口被占用，可能原因：
    //   1. 上一次启动器进程的 socket 处于 TIME_WAIT 状态（SO_REUSEADDR 在 iOS 上
    //      某些情况下对 127.0.0.1 bind 行为不一致，仍可能拒绝 bind）
    //   2. iOS jailbreak 设备上端口被其他进程占用（如越狱环境下的 VPN 工具、
    //      SSH 动态转发等常使用 1080 端口）
    //   3. 同一进程内上一次 SOCKS5 代理未正确关闭（虽然 startWithPort: 入口
    //      已有 stop 检查，但极端情况下仍可能残留）
    //
    // 修复方案：
    //   - 先尝试用户指定的端口（通常是 1080）
    //   - 如果 bind 失败，依次尝试 port+1, port+2, ..., port+9（共 10 个端口）
    //   - 如果 10 个端口都失败，最后使用 port=0 让系统自动分配可用端口
    //   - 实际使用的端口通过 listeningPort 属性和 currentSOCKS5Port 暴露给
    //     JavaLauncher，确保 JVM 参数 -DsocksProxyPort 使用正确端口
    //
    // 这样既能尽量使用固定端口（方便用户调试和防火墙配置），又能避免端口
    // 冲突导致联机功能完全不可用。

    uint16_t actualPort = 0;
    BOOL bindSuccess = NO;
    int lastBindErrno = 0;

    for (int attempt = 0; attempt < 11; attempt++) {
        // 前 10 次尝试 port+0 到 port+9，第 11 次使用 port=0（系统自动分配）
        uint16_t tryPort = (attempt < 10) ? (port + attempt) : 0;

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(tryPort);
        addr.sin_addr.s_addr = inet_addr("127.0.0.1");

        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            // bind 成功
            bindSuccess = YES;

            if (tryPort == 0) {
                // 系统自动分配的端口，需要通过 getsockname 查询实际端口
                socklen_t addrLen = sizeof(addr);
                if (getsockname(fd, (struct sockaddr *)&addr, &addrLen) < 0) {
                    NSLog(@"[SOCKS5Proxy] getsockname failed: errno = %d", errno);
                    close(fd);
                    if (error) {
                        *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                                      code:SOCKS5ProxyErrorCodeSocketCreateFailed
                                                  userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_955", nil)}];
                    }
                    return NO;
                }
                actualPort = ntohs(addr.sin_port);
            } else {
                actualPort = tryPort;
            }

            if (tryPort != port) {
                NSLog(@"[SOCKS5Proxy] Requested port %u is in use, using port %u instead", port, actualPort);
            }
            break;
        }

        // bind 失败
        lastBindErrno = errno;
        NSLog(@"[SOCKS5Proxy] bind port %u failed: errno = %d (trying next port)", tryPort, errno);

        // bind 失败后，需要关闭旧 socket 并创建新 socket
        // （bind 失败后 socket 状态不可预测，不能直接复用）
        close(fd);
        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            NSLog(@"[SOCKS5Proxy] Failed to recreate socket: errno = %d", errno);
            if (error) {
                *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                              code:SOCKS5ProxyErrorCodeSocketCreateFailed
                                          userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_954", nil), errno]}];
            }
            return NO;
        }

        // 重新设置 SO_REUSEADDR（新 socket 需要重新设置）
        int reuseOpt = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseOpt, sizeof(reuseOpt));
    }

    if (!bindSuccess) {
        NSLog(@"[SOCKS5Proxy] All port attempts failed (last errno = %d)", lastBindErrno);
        close(fd);
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeBindFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_956", nil), port, lastBindErrno]}];
        }
        return NO;
    }

    // 步骤 5：开始监听
    // backlog = 16，允许最多 16 个等待接受的连接
    if (listen(fd, 16) < 0) {
        NSLog(@"[SOCKS5Proxy] listen failed: errno = %d", errno);
        close(fd);
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeListenFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_957", nil), errno]}];
        }
        return NO;
    }

    // 更新内部状态
    [_lock lock];
    _listenFD = fd;
    _listeningPort = actualPort;
    _running = YES;
    [_clientFDs removeAllObjects];
    [_clientThreads removeAllObjects];
    // 关键修复（P1-9）：start 时未清理 _remoteFDs，重启后残留的旧 remoteFD
    // 会在下一次 stop() 时被 shutdownSocket:，可能误关闭已被系统复用的新 fd。
    // 与 _clientFDs / _clientThreads 同步清理，保证 fd 列表一致。
    [_remoteFDs removeAllObjects];
    [_lock unlock];

    NSLog(@"[SOCKS5Proxy] Proxy server started, listening on 127.0.0.1:%u", actualPort);

    // 步骤 6：启动 Accept 线程
    __weak typeof(self) weakSelf = self;
    _acceptThread = [[NSThread alloc] initWithBlock:^{
        [weakSelf acceptLoop];
    }];
    [_acceptThread setName:@"SOCKS5Proxy-Accept"];
    [_acceptThread start];

    return YES;
}

/// 停止代理服务器
///
/// 关键修复（C1）：关闭监听 socket 后，主动 shutdown 所有活跃客户端连接，
/// 强制阻塞在 read/recv 上的客户端线程返回，避免线程泄漏。
///
/// 关键修复（M4）：stop 后短暂等待，让客户端线程有机会清理资源，
/// 然后再由调用方离开 ZeroTier 网络。
- (void)stop {
    // 关键修复（N1）：stop 在主线程被调用时会阻塞 UI 最长 2 秒。
    //
    // 触发链路：用户点击「断开连接」按钮 → MultiplayerManager.disconnectCurrentRoom
    // （主线程）→ SOCKS5Proxy.stop（主线程）→ 等待客户端线程退出（2 秒）→ UI 卡死。
    //
    // 修复方案：
    //   1. 所有立即性的清理工作（关闭监听 socket、shutdown 客户端/远程 fd、清空列表、
    //      设置 _running=NO）都在当前线程同步执行，确保 stop 返回后代理不再接受
    //      新连接、不再转发数据，状态对调用方立即可见
    //   2. 「等待客户端线程退出」这一耗时操作改为：主线程异步派发到后台队列执行，
    //      不阻塞 UI；后台线程则同步等待（disconnectCurrentRoom 通常在主线程，
    //      但若在后台线程调用则同步等待无影响）
    //
    // 这样 stop 在主线程调用时几乎立即返回（仅耗时 shutdown 系统调用），UI 不卡顿；
    // 客户端线程在后台线程被等待退出，资源仍会被正确清理。
    BOOL isMainThread = [NSThread isMainThread];

    [_lock lock];
    if (!_running) {
        [_lock unlock];
        NSLog(@"[SOCKS5Proxy] Proxy is not running, no need to stop");
        return;
    }

    NSLog(@"[SOCKS5Proxy] Stopping proxy server (isMainThread=%d)...", isMainThread);
    _running = NO;

    // 关闭监听 socket，这会导致 accept() 返回错误，accept 线程退出
    if (_listenFD >= 0) {
        close(_listenFD);
        _listenFD = -1;
    }

    // 保存当前端口用于日志，然后清除
    uint16_t savedPort = _listeningPort;
    _listeningPort = 0;

    // 复制客户端线程列表和 fd 列表（不阻塞太久）
    NSArray<NSThread *> *threads = [_clientThreads copy];
    NSArray<NSNumber *> *clientFDs = [_clientFDs copy];
    NSArray<NSNumber *> *remoteFDs = [_remoteFDs copy];
    [_clientThreads removeAllObjects];
    [_clientFDs removeAllObjects];
    [_remoteFDs removeAllObjects];
    [_lock unlock];

    NSLog(@"[SOCKS5Proxy] Listen socket closed (port %u), shutting down %lu client connections and %lu remote connections...",
          savedPort, (unsigned long)clientFDs.count, (unsigned long)remoteFDs.count);

    // 关键修复（C1）：主动 shutdown 所有活跃客户端 fd
    // shutdown(SHUT_RDWR) 会强制 read/recv 返回 0 或错误，唤醒阻塞的客户端线程
    // 这是解决线程泄漏的核心：只有唤醒阻塞的 read，客户端线程才能退出
    for (NSNumber *fdNum in clientFDs) {
        int clientFD = [fdNum intValue];
        if (clientFD >= 0) {
            // shutdown 而不是 close：close 只是减少引用计数，不会立即唤醒阻塞的 read
            // shutdown(SHUT_RDWR) 会立即让所有阻塞在该 fd 上的 read/write 返回
            int rc = shutdown(clientFD, SHUT_RDWR);
            NSLog(@"[SOCKS5Proxy] shutdown client fd=%d, result=%d (errno=%d)", clientFD, rc, errno);
        }
    }

    // 关键修复（M12）：主动 shutdown 所有活跃远程 fd（libzt socket）
    // 之前不 shutdown 远程 fd，导致客户端线程在 forwardDataBetweenClientFD: 中
    // 阻塞在 recvData:remoteFD: 上最长 30 秒（SO_RCVTIMEO 超时）。
    // shutdown 远程 fd 的 SHUT_RDWR 会立即让 recv 返回，让客户端线程快速退出。
    for (NSNumber *fdNum in remoteFDs) {
        int remoteFD = [fdNum intValue];
        if (remoteFD >= 0) {
            int rc = [[ZeroTierBridge sharedInstance] shutdownSocket:remoteFD how:2 /* SHUT_RDWR */];
            NSLog(@"[SOCKS5Proxy] shutdown remote fd=%d, result=%d", remoteFD, rc);
        }
    }

    NSLog(@"[SOCKS5Proxy] Shut down all client connections, waiting for %lu client threads to exit...",
          (unsigned long)threads.count);

    // 关键修复（N1）：等待客户端线程退出（带超时，避免无限等待）
    // - 后台线程：同步等待，调用方已不在主线程，阻塞无 UI 影响
    // - 主线程：异步派发到后台队列执行等待，避免 UI 卡死
    //   客户端线程被 shutdown 唤醒后会很快退出，等待逻辑即使异步执行也不会延迟
    //   下一次 startWithPort:（startWithPort: 内部已检测 _running 标志和 _listenFD，
    //   且强制停止旧代理时也只等待 0.1 秒，不会与异步等待冲突）
    if (threads.count == 0) {
        NSLog(@"[SOCKS5Proxy] Proxy stopped (no active client threads)");
        return;
    }

    if (isMainThread) {
        // 主线程：异步派发到后台队列等待，不阻塞 UI
        NSArray<NSThread *> *threadsToWait = [threads copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSTimeInterval waitDeadline = [NSDate timeIntervalSinceReferenceDate] + 2.0;
            for (NSThread *thread in threadsToWait) {
                while (![thread isFinished] && [NSDate timeIntervalSinceReferenceDate] < waitDeadline) {
                    [NSThread sleepForTimeInterval:0.05];
                }
                if (![thread isFinished]) {
                    NSLog(@"[SOCKS5Proxy] Warning: client thread %@ did not exit within 2 seconds", thread.name);
                }
            }
            NSLog(@"[SOCKS5Proxy] Proxy stopped, all client connections cleaned up (background wait completed)");
        });
        NSLog(@"[SOCKS5Proxy] stop called on main thread, dispatched waiting for %lu client threads to background queue",
              (unsigned long)threads.count);
    } else {
        // 后台线程：同步等待
        NSTimeInterval waitDeadline = [NSDate timeIntervalSinceReferenceDate] + 2.0;
        for (NSThread *thread in threads) {
            while (![thread isFinished] && [NSDate timeIntervalSinceReferenceDate] < waitDeadline) {
                [NSThread sleepForTimeInterval:0.05];
            }
            if (![thread isFinished]) {
                NSLog(@"[SOCKS5Proxy] Warning: client thread %@ did not exit within 2 seconds", thread.name);
            }
        }
        NSLog(@"[SOCKS5Proxy] Proxy stopped, all client connections cleaned up");
    }
}

/// 代理服务器是否正在运行
/// @return YES 如果正在运行
- (BOOL)isRunning {
    [_lock lock];
    BOOL running = _running;
    [_lock unlock];
    return running;
}

/// 当前监听端口
/// @return 监听端口（未运行时返回 0）
- (uint16_t)listeningPort {
    [_lock lock];
    uint16_t port = _listeningPort;
    [_lock unlock];
    return port;
}

#pragma mark - Accept 循环

/// Accept 循环（在 _acceptThread 线程中运行）
///
/// 循环接受新客户端连接，为每个客户端启动一个处理线程。
- (void)acceptLoop {
    NSLog(@"[SOCKS5Proxy] Accept thread started");

    // 关键修复（M10）：连续 accept 错误计数器，防止无限循环消耗 CPU
    int consecutiveErrors = 0;
    static const int kMaxConsecutiveErrors = 20;

    while (YES) {
        // 检查运行状态
        [_lock lock];
        BOOL running = _running;
        int listenFD = _listenFD;
        [_lock unlock];

        if (!running || listenFD < 0) {
            NSLog(@"[SOCKS5Proxy] Accept thread exiting (proxy has stopped)");
            break;
        }

        // 接受新连接
        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);
        int clientFD = accept(listenFD, (struct sockaddr *)&clientAddr, &clientLen);

        if (clientFD < 0) {
            // 检查是否是因为代理已停止
            [_lock lock];
            BOOL stillRunning = _running;
            [_lock unlock];

            if (!stillRunning) {
                NSLog(@"[SOCKS5Proxy] accept returned -1, proxy has stopped, exiting loop");
                break;
            }

            // 关键修复（M10）：EBADF 表示 listenFD 无效，直接退出
            // EMFILE/ENFILE 表示文件描述符耗尽，退避后继续
            if (errno == EBADF) {
                NSLog(@"[SOCKS5Proxy] accept returned EBADF (listenFD invalid), exiting loop");
                // 关键修复（M11）：异常退出时必须清理 _running 状态，
                // 否则 isRunning 仍返回 YES，上层认为代理正常但实际已停止接受连接。
                [_lock lock];
                _running = NO;
                if (_listenFD >= 0) {
                    close(_listenFD);
                    _listenFD = -1;
                }
                _listeningPort = 0;
                [_lock unlock];
                break;
            }

            consecutiveErrors++;
            NSLog(@"[SOCKS5Proxy] accept failed: errno = %d (consecutive %d times)", errno, consecutiveErrors);

            // 关键修复（M10）：连续错误次数过多，退出避免无限循环
            if (consecutiveErrors >= kMaxConsecutiveErrors) {
                NSLog(@"[SOCKS5Proxy] %d consecutive accept errors, exiting loop", consecutiveErrors);
                // 关键修复（M11）：异常退出时清理 _running 状态和 _listenFD，
                // 让 isRunning 返回 NO，上层（MultiplayerManager）能检测到代理已停止。
                // 之前不清理导致：
                //   - isRunning 仍返回 YES
                //   - MultiplayerManager.isSOCKS5ProxyRunning 报告代理在运行
                //   - 但实际不再接受新连接，Minecraft 的 SOCKS5 连接请求被静默丢弃
                //   - 系统进入不一致状态
                [_lock lock];
                _running = NO;
                if (_listenFD >= 0) {
                    close(_listenFD);
                    _listenFD = -1;
                }
                _listeningPort = 0;
                [_lock unlock];
                break;
            }

            // 退避，避免 CPU 空转
            [NSThread sleepForTimeInterval:0.1];
            continue;
        }

        // 重置错误计数器
        consecutiveErrors = 0;

        // 获取客户端 IP 和端口
        char clientIP[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &clientAddr.sin_addr, clientIP, sizeof(clientIP));
        uint16_t clientPort = ntohs(clientAddr.sin_port);
        NSLog(@"[SOCKS5Proxy] New client connection: %s:%u (fd=%d)", clientIP, clientPort, clientFD);

        // 关键修复（H9/C1）：为客户端 socket 设置 SO_RCVTIMEO
        // 防止恶意客户端只发送部分数据后保持连接不发送，导致服务器线程永久阻塞。
        // 超时后 read 返回 -1 且 errno=EAGAIN/EWOULDBLOCK，客户端线程可以退出。
        struct timeval rcvTimeout;
        rcvTimeout.tv_sec = SOCKS5_CLIENT_IO_TIMEOUT;
        rcvTimeout.tv_usec = 0;
        if (setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, sizeof(rcvTimeout)) < 0) {
            NSLog(@"[SOCKS5Proxy] Failed to set SO_RCVTIMEO: errno = %d (ignoring, continuing)", errno);
        }

        // 关键修复（M14）：设置 SO_KEEPALIVE
        // 如果对端异常断开（如网络中断、进程崩溃），本端能及时检测到，
        // 避免长时间阻塞在 read 上不知道连接已断开。
        int keepalive = 1;
        if (setsockopt(clientFD, SOL_SOCKET, SO_KEEPALIVE, &keepalive, sizeof(keepalive)) < 0) {
            NSLog(@"[SOCKS5Proxy] Failed to set SO_KEEPALIVE: errno = %d (ignoring, continuing)", errno);
        }

        // 关键修复（P1-5）：客户端 socket 设置 SO_SNDTIMEO / SO_NOSIGPIPE
        //
        // 问题：与 PortForwarder 同源问题——writeAll 调用 writeAllWithTimeout(fd, buf, len, 0)
        // 时 timeoutSec=0 表示无超时。MC 接收缓冲区满时 write 永久阻塞，转发线程泄漏。
        //
        // 修复：设置 30 秒发送超时，超时后 write 返回 -1 且 errno=EAGAIN，转发循环退出。
        // SO_NOSIGPIPE 防止 write 对已关闭连接触发 SIGPIPE 崩溃。
        struct timeval sndTimeout;
        sndTimeout.tv_sec = SOCKS5_CLIENT_IO_TIMEOUT;
        sndTimeout.tv_usec = 0;
        if (setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &sndTimeout, sizeof(sndTimeout)) < 0) {
            NSLog(@"[SOCKS5Proxy] Failed to set SO_SNDTIMEO: errno = %d (ignoring, continuing)", errno);
        }
        int nosigpipe = 1;
        if (setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe)) < 0) {
            NSLog(@"[SOCKS5Proxy] Failed to set SO_NOSIGPIPE: errno = %d (ignoring, continuing)", errno);
        }

        // 关键修复（P2-11）：iOS 默认 keepalive 间隔 ~2 小时，无法及时检测半死连接。
        // 改为更激进：空闲 30s 探测，每 10s 一次，3 次失败判定死亡。
        int keepIdle = 30;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, sizeof(keepIdle));
        int keepIntvl = 10;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPINTVL, &keepIntvl, sizeof(keepIntvl));
        int keepCnt = 3;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPCNT, &keepCnt, sizeof(keepCnt));

        // 发送客户端连接通知
        [[NSNotificationCenter defaultCenter] postNotificationName:SOCKS5ProxyClientConnectedNotification
                                                            object:self
                                                          userInfo:@{
                                                              @"clientIP": [NSString stringWithUTF8String:clientIP],
                                                              @"clientPort": @(clientPort)
                                                          }];

        // 启动客户端处理线程
        __weak typeof(self) weakSelf = self;
        NSThread *clientThread = [[NSThread alloc] initWithBlock:^{
            [weakSelf handleClient:clientFD];
        }];
        [clientThread setName:[NSString stringWithFormat:@"SOCKS5Proxy-Client-%d", clientFD]];

        [_lock lock];
        if (_running) {
            [_clientThreads addObject:clientThread];
            // 关键修复（C1）：将客户端 fd 加入数组，stop 时可以主动 shutdown
            [_clientFDs addObject:@(clientFD)];
            [clientThread start];
        } else {
            // 代理已停止，直接关闭客户端连接
            NSLog(@"[SOCKS5Proxy] Proxy has stopped, rejecting new connection fd=%d", clientFD);
            close(clientFD);
        }
        [_lock unlock];
    }

    NSLog(@"[SOCKS5Proxy] Accept thread exited");
}

#pragma mark - 客户端处理

/// 处理单个客户端连接（在客户端处理线程中运行）
///
/// 流程：
///   1. SOCKS5 握手（认证协商 + 请求解析）
///   2. 通过 ZeroTierBridge 连接目标主机
///   3. 双向转发数据
///   4. 清理资源
///
/// 关键修复（H10）：使用 @try @finally 确保 fd 在所有路径下都被正确关闭，
/// 即使握手或转发过程中抛出异常也不会泄漏 fd。
///
/// @param clientFD 客户端 socket 文件描述符
- (void)handleClient:(int)clientFD {
    @autoreleasepool {
        NSLog(@"[SOCKS5Proxy] Starting to handle client fd=%d", clientFD);

        // 用于保存握手结果
        NSString *targetHost = nil;
        uint16_t targetPort = 0;
        int remoteFD = -1;

        @try {
            // 步骤 1：SOCKS5 握手
            BOOL handshakeOK = [self socks5Handshake:clientFD
                                          targetHost:&targetHost
                                          targetPort:&targetPort
                                            remoteFD:&remoteFD];

            if (!handshakeOK) {
                NSLog(@"[SOCKS5Proxy] SOCKS5 handshake failed, closing client fd=%d", clientFD);

                // 发送客户端断开通知
                [[NSNotificationCenter defaultCenter] postNotificationName:SOCKS5ProxyClientDisconnectedNotification
                                                                    object:self
                                                                  userInfo:@{@"reason": @"handshake_failed"}];
                return;
            }

            NSLog(@"[SOCKS5Proxy] SOCKS5 handshake succeeded, target %@:%u, starting forwarding (clientFD=%d, remoteFD=%d)",
                  targetHost, targetPort, clientFD, remoteFD);

            // 关键修复（M12）：将远程 fd 加入 _remoteFDs 列表，以便 stop 时能 shutdown 它。
            // 否则 stop 时只 shutdown 客户端 fd，远程 fd 仍阻塞 recv，客户端线程无法退出。
            [_lock lock];
            [_remoteFDs addObject:@(remoteFD)];
            [_lock unlock];

            // 关键修复：对客户端 socket 设置 TCP_NODELAY（禁用 Nagle 算法）
            // Minecraft 是实时交互游戏，延迟比带宽更重要
            int clientNoDelay = 1;
            setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &clientNoDelay, sizeof(clientNoDelay));

            // 关键修复：对 libzt socket 设置 TCP_NODELAY（降低 ZeroTier 虚拟网络延迟）
            int ztNoDelay = 1;
            zts_bsd_setsockopt(remoteFD, ZTS_IPPROTO_TCP, ZTS_TCP_NODELAY, &ztNoDelay, sizeof(ztNoDelay));

            // 步骤 2：双向转发数据
            [self forwardDataBetweenClientFD:clientFD remoteFD:remoteFD];

            // 发送客户端断开通知
            [[NSNotificationCenter defaultCenter] postNotificationName:SOCKS5ProxyClientDisconnectedNotification
                                                                object:self
                                                              userInfo:@{@"reason": @"closed"}];

            NSLog(@"[SOCKS5Proxy] Client handling completed fd=%d", clientFD);
        } @finally {
            // 关键修复（H10）：无论是否异常，都要关闭 fd，避免资源泄漏
            //
            // 关键修复（M10）：先从 _clientFDs 移除 fd，再 close(fd)。
            // 之前先 close(clientFD) 再 removeCurrentThreadAndFD:，存在 fd 复用竞争：
            //   1. close(clientFD) 后 fd 编号可被新 accept 调用复用
            //   2. 若在 close 和 removeCurrentThreadAndFD: 之间发生了新的 start 周期且
            //      accept 返回了相同的 fd 编号
            //   3. removeCurrentThreadAndFD: 中的 indexOfObject:@(clientFD) 会匹配到
            //      新连接的条目并将其错误移除
            //   4. 后续 stop 调用时不会 shutdown 这个新连接的 fd，导致线程泄漏
            // 修复方案：先在 _lock 内从 _clientFDs 移除 fd，然后在锁外 close(fd)。
            // 这样 fd 编号在被复用前已从列表中移除，不会误删新连接的条目。
            //
            // 关键修复（M12）：同时从 _remoteFDs 移除 remoteFD，避免 stop 时
            // shutdown 已关闭的 remoteFD。
            [self removeCurrentThreadAndClientFD:clientFD remoteFD:remoteFD];

            // 关闭客户端 socket（系统 POSIX socket）
            if (clientFD >= 0) {
                close(clientFD);
            }
            // 关闭远程 socket（libzt socket，通过 ZeroTierBridge 关闭）
            if (remoteFD >= 0) {
                [[ZeroTierBridge sharedInstance] closeSocket:remoteFD];
            }
        }
    }
}

#pragma mark - SOCKS5 协议实现

/// SOCKS5 握手
///
/// 完成认证协商和请求解析，并通过 ZeroTierBridge 连接目标主机。
///
/// @param clientFD 客户端 socket 文件描述符
/// @param targetHost 输出：目标主机地址
/// @param targetPort 输出：目标端口
/// @param remoteFD 输出：远程 socket 文件描述符（libzt socket）
/// @return YES 如果握手成功
- (BOOL)socks5Handshake:(int)clientFD
             targetHost:(NSString **)targetHost
             targetPort:(uint16_t *)targetPort
               remoteFD:(int *)remoteFD {
    // ============================================================
    // 步骤 1：认证方法协商
    // ============================================================

    // 读取客户端 greeting 头：VER(1) NMETHODS(1)
    uint8_t greeting[2] = {0};
    ssize_t n = readAll(clientFD, greeting, 2);
    if (n != 2) {
        NSLog(@"[SOCKS5Proxy] Failed to read greeting header: n=%zd", n);
        return NO;
    }

    // 验证 SOCKS 版本
    if (greeting[0] != SOCKS5_VERSION) {
        NSLog(@"[SOCKS5Proxy] Unsupported SOCKS version: %d", greeting[0]);
        return NO;
    }

    uint8_t nMethods = greeting[1];
    if (nMethods == 0) {
        NSLog(@"[SOCKS5Proxy] Client did not provide any authentication methods");
        return NO;
    }

    // 读取方法列表：METHODS(NMETHODS)
    uint8_t methods[256] = {0};
    n = readAll(clientFD, methods, nMethods);
    if (n != nMethods) {
        NSLog(@"[SOCKS5Proxy] Failed to read methods list: n=%zd, expected=%d", n, nMethods);
        return NO;
    }

    // 检查是否支持无认证方式（METHOD_NO_AUTH = 0x00）
    // 本代理不支持用户名/密码认证
    BOOL noAuthSupported = NO;
    for (int i = 0; i < nMethods; i++) {
        if (methods[i] == SOCKS5_METHOD_NO_AUTH) {
            noAuthSupported = YES;
            break;
        }
    }

    if (!noAuthSupported) {
        NSLog(@"[SOCKS5Proxy] Client does not support no-auth method, rejecting connection");
        // 回复无可接受的方法
        uint8_t reply[2] = {SOCKS5_VERSION, SOCKS5_METHOD_NO_ACCEPTABLE};
        writeAll(clientFD, reply, 2);
        return NO;
    }

    // 回复选择无认证方式：VER(1) METHOD(1)
    uint8_t methodReply[2] = {SOCKS5_VERSION, SOCKS5_METHOD_NO_AUTH};
    n = writeAll(clientFD, methodReply, 2);
    if (n != 2) {
        NSLog(@"[SOCKS5Proxy] Failed to send method reply: n=%zd", n);
        return NO;
    }

    NSLog(@"[SOCKS5Proxy] SOCKS5 authentication method negotiation completed (no-auth)");

    // ============================================================
    // 步骤 2：读取客户端请求
    // ============================================================

    // 读取请求头：VER(1) CMD(1) RSV(1) ATYP(1)
    uint8_t requestHeader[4] = {0};
    n = readAll(clientFD, requestHeader, 4);
    if (n != 4) {
        NSLog(@"[SOCKS5Proxy] Failed to read request header: n=%zd", n);
        return NO;
    }

    // 验证 SOCKS 版本
    if (requestHeader[0] != SOCKS5_VERSION) {
        NSLog(@"[SOCKS5Proxy] SOCKS version error in request: %d", requestHeader[0]);
        return NO;
    }

    // 检查命令类型（只支持 CONNECT）
    uint8_t cmd = requestHeader[1];
    if (cmd != SOCKS5_CMD_CONNECT) {
        NSLog(@"[SOCKS5Proxy] Unsupported CMD: %d (only CONNECT=1 supported)", cmd);
        [self sendSocks5Reply:clientFD
                          rep:SOCKS5_REP_COMMAND_NOT_SUPPORTED
                     bindAddr:@"0.0.0.0"
                     bindPort:0
                         atyp:SOCKS5_ATYP_IPV4];
        return NO;
    }

    // 解析目标地址
    uint8_t atyp = requestHeader[3];
    NSString *destHost = nil;

    switch (atyp) {
        case SOCKS5_ATYP_IPV4: {
            // IPv4 地址：4 字节
            uint8_t ipv4[4] = {0};
            n = readAll(clientFD, ipv4, 4);
            if (n != 4) {
                NSLog(@"[SOCKS5Proxy] Failed to read IPv4 address: n=%zd", n);
                return NO;
            }
            destHost = [NSString stringWithFormat:@"%d.%d.%d.%d",
                        ipv4[0], ipv4[1], ipv4[2], ipv4[3]];
            break;
        }

        case SOCKS5_ATYP_DOMAIN: {
            // 域名：1 字节长度 + 域名字符串
            uint8_t domainLen = 0;
            n = readAll(clientFD, &domainLen, 1);
            if (n != 1) {
                NSLog(@"[SOCKS5Proxy] Failed to read domain name length: n=%zd", n);
                return NO;
            }
            char domain[256] = {0};
            n = readAll(clientFD, domain, domainLen);
            if (n != domainLen) {
                NSLog(@"[SOCKS5Proxy] Failed to read domain name: n=%zd, expected=%d", n, domainLen);
                return NO;
            }
            NSString *domainStr = [NSString stringWithUTF8String:domain];

            // 关键修复（P0-2）：libzt 的 zts_bsd_connect 不支持域名解析
            // （zts_inet_pton 遇到非数字 IP 直接返回 0），需要先用系统
            // getaddrinfo 把域名解析为 IP，再传给 ZeroTierBridge.connectSocket。
            // 否则用户在 MC 中填入域名时联机会直接失败。
            // 解析失败时回退使用原始域名，保持与旧行为兼容（由上层报错）。
            struct addrinfo hints, *res = NULL;
            memset(&hints, 0, sizeof(hints));
            hints.ai_family = AF_UNSPEC;       // 同时接受 IPv4 / IPv6
            hints.ai_socktype = SOCK_STREAM;
            int gaiResult = getaddrinfo(domain, NULL, &hints, &res);
            if (gaiResult == 0 && res != NULL) {
                char resolvedIP[INET6_ADDRSTRLEN] = {0};
                if (res->ai_family == AF_INET) {
                    struct sockaddr_in *sin = (struct sockaddr_in *)res->ai_addr;
                    inet_ntop(AF_INET, &sin->sin_addr, resolvedIP, sizeof(resolvedIP));
                } else if (res->ai_family == AF_INET6) {
                    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)res->ai_addr;
                    inet_ntop(AF_INET6, &sin6->sin6_addr, resolvedIP, sizeof(resolvedIP));
                }
                if (resolvedIP[0] != '\0') {
                    destHost = [NSString stringWithUTF8String:resolvedIP];
                    NSLog(@"[SOCKS5Proxy] Domain %@ resolved to %@", domainStr, destHost);
                } else {
                    destHost = domainStr;
                    NSLog(@"[SOCKS5Proxy] Domain %@ resolved to empty result, falling back to original domain", domainStr);
                }
                freeaddrinfo(res);
            } else {
                destHost = domainStr;
                NSLog(@"[SOCKS5Proxy] Domain %@ resolution failed (gaiResult=%d: %s), using original domain",
                      domainStr, gaiResult, gai_strerror(gaiResult));
            }
            break;
        }

        case SOCKS5_ATYP_IPV6: {
            // IPv6 地址：16 字节
            uint8_t ipv6[16] = {0};
            n = readAll(clientFD, ipv6, 16);
            if (n != 16) {
                NSLog(@"[SOCKS5Proxy] Failed to read IPv6 address: n=%zd", n);
                return NO;
            }
            char ipv6Str[INET6_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET6, ipv6, ipv6Str, sizeof(ipv6Str));
            destHost = [NSString stringWithUTF8String:ipv6Str];
            break;
        }

        default:
            NSLog(@"[SOCKS5Proxy] Unsupported ATYP: %d", atyp);
            [self sendSocks5Reply:clientFD
                              rep:SOCKS5_REP_ADDRESS_TYPE_NOT_SUPPORTED
                         bindAddr:@"0.0.0.0"
                         bindPort:0
                             atyp:SOCKS5_ATYP_IPV4];
            return NO;
    }

    // 读取目标端口：2 字节，网络字节序（大端）
    uint8_t portBytes[2] = {0};
    n = readAll(clientFD, portBytes, 2);
    if (n != 2) {
        NSLog(@"[SOCKS5Proxy] Failed to read port: n=%zd", n);
        return NO;
    }
    uint16_t destPort = (uint16_t)((portBytes[0] << 8) | portBytes[1]);

    NSLog(@"[SOCKS5Proxy] Client requested connection to %@:%u", destHost, destPort);

    // ============================================================
    // 步骤 3：通过 ZeroTier 虚拟网络连接目标
    // ============================================================

    // 检测目标地址类型：IPv6 地址包含 ':'，IPv4 地址包含 '.'
    BOOL isIPv6Target = ([destHost rangeOfString:@":"].location != NSNotFound);
    int socketFamily = isIPv6Target ? ZTS_AF_INET6 : ZTS_AF_INET;

    // 创建 libzt socket（根据目标地址类型选择 IPv4 或 IPv6）
    // Ad-hoc 网络只有 IPv6，必须使用 ZTS_AF_INET6 创建 socket
    int ztFD = [[ZeroTierBridge sharedInstance] createTCPSocketForFamily:socketFamily];
    if (ztFD < 0) {
        NSLog(@"[SOCKS5Proxy] Failed to create ZeroTier socket(family=%d): ztFD=%d", socketFamily, ztFD);
        [self sendSocks5Reply:clientFD
                          rep:SOCKS5_REP_GENERAL_FAILURE
                     bindAddr:@"0.0.0.0"
                     bindPort:0
                         atyp:SOCKS5_ATYP_IPV4];
        return NO;
    }

    // 连接目标主机
    int connectResult = [[ZeroTierBridge sharedInstance] connectSocket:ztFD
                                                                toHost:destHost
                                                                  port:destPort
                                                               timeout:SOCKS5_CONNECT_TIMEOUT];
    if (connectResult != 0) {
        NSLog(@"[SOCKS5Proxy] Failed to connect to target via ZeroTier: result=%d, target=%@:%u",
              connectResult, destHost, destPort);
        [[ZeroTierBridge sharedInstance] closeSocket:ztFD];

        // 根据错误类型选择合适的回复码
        // 由于 libzt 的错误码与 SOCKS5 回复码不直接对应，这里统一使用 CONNECTION_REFUSED
        [self sendSocks5Reply:clientFD
                          rep:SOCKS5_REP_CONNECTION_REFUSED
                     bindAddr:@"0.0.0.0"
                     bindPort:0
                         atyp:SOCKS5_ATYP_IPV4];
        return NO;
    }

    NSLog(@"[SOCKS5Proxy] Connected to target via ZeroTier successfully: target=%@:%u, ztFD=%d",
          destHost, destPort, ztFD);

    // ============================================================
    // 步骤 4：发送成功回复
    // ============================================================

    [self sendSocks5Reply:clientFD
                      rep:SOCKS5_REP_SUCCESS
                 bindAddr:@"0.0.0.0"
                 bindPort:0
                     atyp:SOCKS5_ATYP_IPV4];

    // 输出握手结果
    if (targetHost) {
        *targetHost = destHost;
    }
    if (targetPort) {
        *targetPort = destPort;
    }
    if (remoteFD) {
        *remoteFD = ztFD;
    }

    return YES;
}

/// 发送 SOCKS5 回复
///
/// 回复格式：VER(1) REP(1) RSV(1) ATYP(1) BND.ADDR(?) BND.PORT(2)
///
/// @param clientFD 客户端 socket 文件描述符
/// @param rep 回复码（SOCKS5_REP_*）
/// @param bindAddr 绑定地址（BND.ADDR）
/// @param bindPort 绑定端口（BND.PORT）
/// @param atyp 地址类型（SOCKS5_ATYP_*）
- (void)sendSocks5Reply:(int)clientFD
                    rep:(uint8_t)rep
              bindAddr:(NSString *)bindAddr
              bindPort:(uint16_t)bindPort
                  atyp:(uint8_t)atyp {
    // 构建回复数据
    NSMutableData *reply = [NSMutableData data];

    // VER(1) REP(1) RSV(1) ATYP(1)
    uint8_t header[4] = {SOCKS5_VERSION, rep, 0x00, atyp};
    [reply appendBytes:header length:4];

    // BND.ADDR（根据 ATYP 不同长度不同）
    if (atyp == SOCKS5_ATYP_IPV4) {
        uint8_t ipv4[4] = {0, 0, 0, 0};
        if (bindAddr && bindAddr.length > 0) {
            inet_pton(AF_INET, [bindAddr UTF8String], ipv4);
        }
        [reply appendBytes:ipv4 length:4];
    } else if (atyp == SOCKS5_ATYP_IPV6) {
        uint8_t ipv6[16] = {0};
        if (bindAddr && bindAddr.length > 0) {
            inet_pton(AF_INET6, [bindAddr UTF8String], ipv6);
        }
        [reply appendBytes:ipv6 length:16];
    }

    // BND.PORT（2 字节，网络字节序）
    uint8_t portBytes[2] = {
        (uint8_t)((bindPort >> 8) & 0xFF),
        (uint8_t)(bindPort & 0xFF)
    };
    [reply appendBytes:portBytes length:2];

    // 发送回复
    // 关键修复（L2）：检查 writeAll 返回值，失败时记录日志
    ssize_t writeResult = writeAll(clientFD, reply.bytes, reply.length);
    if (writeResult < 0 || (size_t)writeResult != reply.length) {
        NSLog(@"[SOCKS5Proxy] Failed to send SOCKS5 reply: writeResult=%zd, expected=%lu",
              writeResult, (unsigned long)reply.length);
    }

    NSLog(@"[SOCKS5Proxy] Sent SOCKS5 reply: rep=%d, addr=%@:%u, atyp=%d",
          rep, bindAddr, bindPort, atyp);
}

#pragma mark - 双向数据转发

/// 在客户端和远程主机之间双向转发数据
///
/// 使用 GCD 并发队列，启动两个任务分别处理两个方向的数据转发：
///   - client → remote：从客户端读取数据，通过 ZeroTier 发送到远程
///   - remote → client：从 ZeroTier 接收数据，发送给客户端
///
/// 当任一方向结束时，通过 shutdown() 通知另一端，使其 read/recv 返回 0 并退出。
///
/// @param clientFD 客户端 socket 文件描述符（系统 POSIX socket）
/// @param remoteFD 远程 socket 文件描述符（libzt socket）
- (void)forwardDataBetweenClientFD:(int)clientFD
                          remoteFD:(int)remoteFD {
    // 关键修复（N2）：使用 atomic_bool 替代 __block BOOL，确保跨线程内存可见性。
    //
    // 问题：__block 修饰符只是让变量可以在 block 内被修改，但不提供内存屏障。
    // 在 ARM64（iPhone）等弱内存模型架构上，一个线程对 __block 变量的写入
    // 可能不会被另一个线程立即看到，导致：
    //   - 一个方向已关闭，但另一个方向的循环没有及时看到标志变化
    //   - 继续阻塞在 read/recvData 上，直到对端 FIN 到达或 IO 超时才退出
    //   - 转发任务延迟退出（最坏情况下需要等待对端关闭或 IO 超时）
    //
    // 修复方案：使用 C11 atomic_bool，原子操作自带合适的内存屏障
    // （memory_order_seq_cst），保证一个线程的写入对另一个线程立即可见。
    //
    // 关键修复（N2 验证发现）：必须同时使用 __block 和 atomic。
    // - __block：让变量被 block 按引用捕获（两个 block 共享同一变量），而不是按值捕获
    //   （按值捕获会导致每个 block 有独立副本，原子操作在各自副本上执行，完全失效）
    // - atomic_bool：提供内存屏障，保证跨线程可见性
    // 两者缺一不可：只有 __block 无内存屏障，只有 atomic 会被按值捕获。
    // 关键修复：使用 atomic_bool 替代 _Atomic(BOOL)，确保跨平台兼容性
    // _Atomic(BOOL) 在 Objective-C 中可能不被支持（BOOL 是 signed char 的 typedef）
    __block atomic_bool clientClosed = ATOMIC_VAR_INIT(false);
    __block atomic_bool remoteClosed = ATOMIC_VAR_INIT(false);

    // 创建并发队列用于双向转发
    dispatch_queue_t forwardQueue = dispatch_queue_create("com.angelaura.socks5.forward", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t group = dispatch_group_create();

    // ============================================================
    // 方向 1：client → remote
    // 从客户端（POSIX socket）读取数据，通过 ZeroTier（libzt socket）发送
    // ============================================================
    dispatch_group_async(group, forwardQueue, ^{
        uint8_t buffer[SOCKS5_BUFFER_SIZE];

        while (YES) {
            @autoreleasepool {
                // 检查远程是否已关闭（原子读，自带内存屏障）
                if (atomic_load(&remoteClosed)) {
                    NSLog(@"[SOCKS5Proxy] client→remote: remote already closed, exiting forwarding");
                    break;
                }

                // 从客户端读取数据（系统 read）
                ssize_t n = read(clientFD, buffer, sizeof(buffer));
                if (n <= 0) {
                    // n == 0：客户端关闭连接
                    // n < 0：读取错误
                    NSLog(@"[SOCKS5Proxy] client→remote ended: n=%zd, errno=%d", n, errno);

                    // 标记客户端已关闭（原子写，自带内存屏障）
                    atomic_store(&clientClosed, true);

                    // 关闭远程的写端，通知 remote→client 方向退出
                    // shutdown 会导致另一端的 recv 返回 0
                    // 关键修复：remoteFD 是 libzt socket，必须使用 zts_bsd_shutdown
                    [[ZeroTierBridge sharedInstance] shutdownSocket:remoteFD how:SHUT_WR];
                    break;
                }

                // 通过 ZeroTier 发送数据（libzt send）
                ssize_t sent = [[ZeroTierBridge sharedInstance] sendData:remoteFD
                                                                  buffer:buffer
                                                                  length:(size_t)n];
                if (sent <= 0) {
                    NSLog(@"[SOCKS5Proxy] Failed to send to remote: sent=%zd", sent);

                    // 标记远程已关闭（原子写）
                    atomic_store(&remoteClosed, true);

                    // 关闭客户端的写端
                    shutdown(clientFD, SHUT_WR);
                    break;
                }
            }
        }
    });

    // ============================================================
    // 方向 2：remote → client
    // 从 ZeroTier（libzt socket）接收数据，发送给客户端（POSIX socket）
    // ============================================================
    dispatch_group_async(group, forwardQueue, ^{
        uint8_t buffer[SOCKS5_BUFFER_SIZE];

        while (YES) {
            @autoreleasepool {
                // 检查客户端是否已关闭（原子读，自带内存屏障）
                if (atomic_load(&clientClosed)) {
                    NSLog(@"[SOCKS5Proxy] remote→client: client already closed, exiting forwarding");
                    break;
                }

                // 通过 ZeroTier 接收数据（libzt recv）
                ssize_t n = [[ZeroTierBridge sharedInstance] recvData:remoteFD
                                                                buffer:buffer
                                                                length:sizeof(buffer)];
                if (n <= 0) {
                    // n == 0：远程关闭连接
                    // n < 0：接收错误
                    NSLog(@"[SOCKS5Proxy] remote→client ended: n=%zd", n);

                    // 标记远程已关闭（原子写）
                    atomic_store(&remoteClosed, true);

                    // 关闭客户端的写端，通知 client→remote 方向退出
                    shutdown(clientFD, SHUT_WR);
                    break;
                }

                // 发送数据给客户端（系统 write）
                ssize_t sent = writeAll(clientFD, buffer, (size_t)n);
                if (sent <= 0) {
                    NSLog(@"[SOCKS5Proxy] Failed to send to client: sent=%zd", sent);

                    // 标记客户端已关闭（原子写）
                    atomic_store(&clientClosed, true);

                    // 关闭远程的写端
                    // 关键修复：remoteFD 是 libzt socket，必须使用 zts_bsd_shutdown
                    [[ZeroTierBridge sharedInstance] shutdownSocket:remoteFD how:SHUT_WR];
                    break;
                }
            }
        }
    });

    // 等待两个方向的转发都完成
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    NSLog(@"[SOCKS5Proxy] Bidirectional forwarding ended (clientFD=%d, remoteFD=%d)", clientFD, remoteFD);
}

#pragma mark - 辅助方法

/// 从客户端线程列表、客户端 fd 列表和远程 fd 列表中移除当前线程和对应的 fd
///
/// 关键修复（C1）：同时移除客户端 fd，避免 stop 时 shutdown 已关闭的 fd
/// 关键修复（M12）：同时移除远程 fd，避免 stop 时 shutdown 已关闭的 remoteFD
- (void)removeCurrentThreadAndClientFD:(int)clientFD remoteFD:(int)remoteFD {
    NSThread *current = [NSThread currentThread];
    [_lock lock];
    [_clientThreads removeObject:current];

    // 移除客户端 fd（使用 indexOfObject: 找到对应的 NSNumber）
    if (clientFD >= 0) {
        NSNumber *clientFDNum = @(clientFD);
        NSUInteger clientIndex = [_clientFDs indexOfObject:clientFDNum];
        if (clientIndex != NSNotFound) {
            [_clientFDs removeObjectAtIndex:clientIndex];
        }
    }

    // 关键修复（M12）：移除远程 fd
    if (remoteFD >= 0) {
        NSNumber *remoteFDNum = @(remoteFD);
        NSUInteger remoteIndex = [_remoteFDs indexOfObject:remoteFDNum];
        if (remoteIndex != NSNotFound) {
            [_remoteFDs removeObjectAtIndex:remoteIndex];
        }
    }

    [_lock unlock];
}

@end
