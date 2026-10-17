//
//  PortForwarder.m
//  Angel Aura Amethyst
//
//  TCP 端口转发器实现（支持房主模式和房客模式）
//
//  ============================================================================
//  实现说明
//  ============================================================================
//
//  本文件实现 PortForwarder.h 中定义的 TCP 端口转发器，支持两种模式：
//
//  房客模式（Guest Mode）：
//    1. 监听 socket 使用系统 POSIX socket（socket/bind/listen/accept）
//    2. 客户端连接后，通过 ZeroTierBridge 创建 libzt socket 连接到远程主机
//    3. 双向转发使用 GCD 并发队列，两个方向同时转发
//    4. 使用 atomic_bool 标志确保跨线程内存可见性
//    5. 端口冲突处理：尝试 localPort 到 localPort+9，最后回退 port=0
//
//  房主模式（Host Mode，反向转发）：
//    1. 监听 socket 使用 libzt socket（通过 ZeroTierBridge 的 createListenSocket/bind/listen）
//    2. 使用 zts_bsd_select 检测新连接（与房客模式的 POSIX select 类似）
//    3. 客户端连接后（acceptOnSocket:），创建本地 BSD socket 连接到 127.0.0.1:localHostPort
//    4. 双向转发数据（libzt socket ↔ 本地 BSD socket）
//    5. 代际计数器防止快速 stop→start 时旧线程重复 accept
//
//  线程模型：
//    - 主线程：startGuestMode / startHostMode / stop
//    - Accept 线程：NSThread，循环 accept 新连接（房客模式用 POSIX select，房主模式用 zts_bsd_select）
//    - 客户端处理线程：NSThread，每个客户端一个
//    - 转发任务：GCD 并发队列，每个连接两个任务（posix→zt、zt→posix）
//
//  稳定性机制（两种模式共享）：
//    - 代际计数器：防止快速 stop→start 时旧 accept 线程重复 accept
//    - TCP_NODELAY：禁用 Nagle 算法，降低实时游戏延迟
//    - SO_KEEPALIVE + 激进 keepalive 参数：及时检测半死连接
//    - SO_SNDTIMEO / SO_RCVTIMEO：防止转发线程无限阻塞
//    - SO_NOSIGPIPE：防止 SIGPIPE 崩溃
//    - atomic_bool：跨线程内存可见性
//    - 活跃 fd 列表：stop 时 shutdown 唤醒阻塞的 read/recv
//
//  =============================================================================

#import "PortForwarder.h"
#import "ZeroTierBridge.h"
#import "utils.h"

// POSIX socket 头文件
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>  // TCP_NODELAY（禁用 Nagle 算法，降低延迟）
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/select.h>
#include <sys/time.h>
#include <fcntl.h>      // fcntl（非阻塞 connect 用到 F_GETFL/F_SETFL/O_NONBLOCK）
#include <stdatomic.h>  // C11 原子操作，用于双向转发的标志变量

#pragma mark - 常量定义

/// 端口转发器默认本地监听端口（Minecraft 默认服务器端口）
const uint16_t PortForwarderDefaultLocalPort = 25565;

/// 错误域名
static NSString * const kPortForwarderErrorDomain = @"PortForwarderErrorDomain";

/// 数据转发缓冲区大小（64KB）
#define PORT_FORWARDER_BUFFER_SIZE 65536

/// 远程连接超时时间（10 秒）
#define PORT_FORWARDER_CONNECT_TIMEOUT 10.0

/// 监听队列最大长度
#define PORT_FORWARDER_BACKLOG 16

/// 端口冲突最大重试次数
#define PORT_FORWARDER_MAX_PORT_RETRIES 10

#pragma mark - 辅助函数

/// 将所有数据写入 fd（循环 write 直到所有数据写完或出错）
/// @param fd 文件描述符
/// @param buffer 数据缓冲区
/// @param length 数据长度
/// @return 实际写入的字节数，-1 表示错误
static ssize_t writeAll(int fd, const uint8_t *buffer, size_t length) {
    size_t totalWritten = 0;
    while (totalWritten < length) {
        ssize_t n = write(fd, buffer + totalWritten, length - totalWritten);
        if (n < 0) {
            if (errno == EINTR) {
                // 被信号中断，重试
                continue;
            }
            // 关键修复（P1-4）：处理 SO_SNDTIMEO 超时
            // EAGAIN/EWOULDBLOCK 表示发送缓冲区暂时不可用（达到 SO_SNDTIMEO 超时）。
            // 之前直接返回 -1 视为错误，导致转发线程退出，连接断开。
            // 实际上对于实时游戏流量，超时通常意味着对端处理不过来，应该断开连接让 MC 自动重连，
            // 而不是无限阻塞。这里直接返回 -1 让上层关闭连接。
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                NSLog(@"[PortForwarder] writeAll timeout (fd=%d), closing connection", fd);
            }
            // 真正的错误
            return -1;
        }
        if (n == 0) {
            // 不应该发生
            break;
        }
        totalWritten += (size_t)n;
    }
    return (ssize_t)totalWritten;
}

#pragma mark - PortForwarder 类扩展

@interface PortForwarder () {
    /// 监听 socket 文件描述符（-1 表示未创建）
    /// 房客模式：POSIX socket fd
    /// 房主模式：libzt socket fd
    int _listenFD;

    /// Accept 线程
    NSThread *_acceptThread;

    /// 线程锁，保护内部状态
    NSLock *_lock;

    /// 是否正在停止（用于通知 accept 线程退出）
    BOOL _stopping;

    /// 关键修复（P1-8）：accept 线程代际计数器
    /// 每次 start 自增，acceptLoop 启动时捕获当前代际值，
    /// 循环中检查代际是否仍匹配。若不匹配（说明期间发生过 stop→start），
    /// 旧线程立即退出，避免与新一轮 start 启动的 accept 线程重复 accept 同一 listenFD。
    int _acceptGeneration;

    /// 活跃 POSIX socket fd 集合（用于 stop 时 shutdown 唤醒阻塞的 read）
    /// 房客模式：accept 返回的客户端 fd
    /// 房主模式：连接到本地 MC LAN 的 fd
    NSMutableArray<NSNumber *> *_activePosixFDs;

    /// 活跃 libzt socket fd 集合（用于 stop 时 shutdown 唤醒阻塞的 recvData）
    /// 房客模式：连接到远程主机的 libzt fd
    /// 房主模式：acceptOnSocket: 返回的 libzt 客户端 fd
    NSMutableArray<NSNumber *> *_activeZtFDs;
}

/// 实际监听端口
@property (nonatomic, assign, readwrite) uint16_t listeningPort;

/// 是否正在运行
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;

/// 当前运行模式
@property (nonatomic, assign, readwrite) PortForwarderMode mode;

/// 房客模式：远程主机地址（房主的 ZeroTier IP）
@property (nonatomic, copy, readwrite, nullable) NSString *hostIP;

/// 房客模式：远程端口（房主的 MC LAN 端口）
@property (nonatomic, assign, readwrite) uint16_t hostPort;

/// 房主模式：本地 MC LAN 端口
@property (nonatomic, assign, readwrite) uint16_t localHostPort;

#pragma mark - 房客模式私有方法

/// 房客模式 accept 线程主循环
/// @param myGen 启动时捕获的代际值
- (void)guestAcceptLoopWithGeneration:(int)myGen;

/// 房客模式：处理客户端连接
/// @param clientFD 客户端 socket 文件描述符（POSIX socket）
- (void)handleGuestClient:(int)clientFD;

#pragma mark - 房主模式私有方法

/// 房主模式 accept 线程主循环
/// @param myGen 启动时捕获的代际值
- (void)hostAcceptLoopWithGeneration:(int)myGen;

/// 房主模式：处理通过 ZeroTier 接受的连接
/// @param ztClientFD libzt 客户端 socket 文件描述符
- (void)handleHostConnection:(int)ztClientFD;

#pragma mark - 共享私有方法

/// 双向转发数据
/// @param posixFD POSIX socket（房客模式为客户端，房主模式为本地连接）
/// @param ztFD libzt socket（房客模式为远程，房主模式为客户端）
- (void)forwardDataBetweenPosixFD:(int)posixFD
                             ztFD:(int)ztFD;

@end

#pragma mark - PortForwarder 实现

@implementation PortForwarder

#pragma mark - 单例模式

/// 获取共享的 PortForwarder 单例实例
/// 使用 dispatch_once 保证线程安全的单次初始化
+ (instancetype)sharedForwarder {
    static PortForwarder *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

/// 重写 allocWithZone: 防止通过 alloc/init 创建第二个实例
+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static PortForwarder *shared = nil;
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
        _acceptThread = nil;
        _stopping = NO;
        _running = NO;
        _mode = PortForwarderModeNone;
        _listeningPort = 0;
        _hostIP = nil;
        _hostPort = 0;
        _localHostPort = 0;
        _lock = [[NSLock alloc] init];
        _activePosixFDs = [[NSMutableArray alloc] init];
        _activeZtFDs = [[NSMutableArray alloc] init];
        _acceptGeneration = 0;
        NSLog(@"[PortForwarder] Singleton initialized");
    }
    return self;
}

#pragma mark - 启动房客模式

/// 启动房客模式
///
/// 完整流程：
///   1. 参数校验
///   2. 检查是否已在运行
///   3. 检查 ZeroTier framework 是否可用
///   4. 创建监听 socket（尝试端口 localPort 到 localPort+9）
///   5. bind + listen
///   6. 启动 accept 线程
- (BOOL)startGuestModeWithLocalPort:(uint16_t)localPort
                              hostIP:(NSString *)hostIP
                            hostPort:(uint16_t)hostPort {
    // ============================================================
    // 步骤 1：参数校验
    // ============================================================
    if (!hostIP || hostIP.length == 0) {
        NSLog(@"[PortForwarder] Guest mode start failed: hostIP is empty");
        return NO;
    }

    if (hostPort == 0) {
        NSLog(@"[PortForwarder] Guest mode start failed: hostPort is 0");
        return NO;
    }

    // ============================================================
    // 步骤 2：检查是否已在运行
    // ============================================================
    [_lock lock];
    if (_running) {
        [_lock unlock];
        NSLog(@"[PortForwarder] Guest mode start failed: forwarder already running (mode=%ld, port %u)",
              (long)_mode, _listeningPort);
        return NO;
    }
    [_lock unlock];

    // ============================================================
    // 步骤 3：检查 ZeroTier framework 是否可用
    // ============================================================
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[PortForwarder] Guest mode start failed: ZeroTier framework unavailable");
        return NO;
    }

    // ============================================================
    // 步骤 4：创建监听 socket（尝试端口 localPort 到 localPort+9）
    // ============================================================
    NSLog(@"[PortForwarder] Starting guest mode: local %u (or +1~+9) → %@:%u",
          localPort, hostIP, hostPort);

    int listenFD = -1;
    uint16_t actualPort = 0;

    for (int retry = 0; retry < PORT_FORWARDER_MAX_PORT_RETRIES; retry++) {
        uint16_t tryPort = localPort + retry;

        // 创建 TCP socket
        listenFD = socket(AF_INET, SOCK_STREAM, 0);
        if (listenFD < 0) {
            NSLog(@"[PortForwarder] socket() failed: errno=%d (%s)", errno, strerror(errno));
            continue;
        }

        // 设置 SO_REUSEADDR，避免端口处于 TIME_WAIT 状态时 bind 失败
        int reuseAddr = 1;
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, sizeof(reuseAddr));

        // 绑定到 127.0.0.1:tryPort（仅本地回环，不对外暴露）
        struct sockaddr_in bindAddr;
        memset(&bindAddr, 0, sizeof(bindAddr));
        bindAddr.sin_family = AF_INET;
        bindAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // 127.0.0.1
        bindAddr.sin_port = htons(tryPort);

        int bindResult = bind(listenFD, (struct sockaddr *)&bindAddr, sizeof(bindAddr));
        if (bindResult < 0) {
            NSLog(@"[PortForwarder] bind(%u) failed: errno=%d (%s), trying next port",
                  tryPort, errno, strerror(errno));
            close(listenFD);
            listenFD = -1;
            continue;
        }

        // bind 成功
        actualPort = tryPort;
        NSLog(@"[PortForwarder] bind succeeded: port %u", actualPort);
        break;
    }

    // 如果所有端口都绑定失败，最后尝试 port=0（系统自动分配）
    if (listenFD < 0) {
        NSLog(@"[PortForwarder] All specified ports failed to bind, trying system auto-assigned port...");
        listenFD = socket(AF_INET, SOCK_STREAM, 0);
        if (listenFD < 0) {
            NSLog(@"[PortForwarder] socket() failed: errno=%d (%s)", errno, strerror(errno));
            return NO;
        }

        int reuseAddr = 1;
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, sizeof(reuseAddr));

        struct sockaddr_in bindAddr;
        memset(&bindAddr, 0, sizeof(bindAddr));
        bindAddr.sin_family = AF_INET;
        bindAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        bindAddr.sin_port = htons(0);  // 系统自动分配端口

        int bindResult = bind(listenFD, (struct sockaddr *)&bindAddr, sizeof(bindAddr));
        if (bindResult < 0) {
            NSLog(@"[PortForwarder] bind(0) failed: errno=%d (%s)", errno, strerror(errno));
            close(listenFD);
            return NO;
        }

        // 获取系统分配的实际端口
        struct sockaddr_in actualAddr;
        socklen_t addrLen = sizeof(actualAddr);
        if (getsockname(listenFD, (struct sockaddr *)&actualAddr, &addrLen) == 0) {
            actualPort = ntohs(actualAddr.sin_port);
        }
        NSLog(@"[PortForwarder] System auto-assigned port: %u", actualPort);
    }

    // ============================================================
    // 步骤 5：listen
    // ============================================================
    int listenResult = listen(listenFD, PORT_FORWARDER_BACKLOG);
    if (listenResult < 0) {
        NSLog(@"[PortForwarder] listen() failed: errno=%d (%s)", errno, strerror(errno));
        close(listenFD);
        return NO;
    }

    // ============================================================
    // 步骤 6：更新状态并启动 accept 线程
    // ============================================================
    [_lock lock];
    _listenFD = listenFD;
    _listeningPort = actualPort;
    _hostIP = [hostIP copy];
    _hostPort = hostPort;
    _localHostPort = 0;
    _mode = PortForwarderModeGuest;
    _running = YES;
    _stopping = NO;
    // 关键修复（P1-8）：代际自增，标识本次 start 周期
    // 用于解决快速 stop→start 时旧 accept 线程未及时退出、与新 accept 线程
    // 同时 accept 同一 listenFD（fd 数字可能被复用）导致重复 accept 的问题
    _acceptGeneration++;
    int myGen = _acceptGeneration;
    [_lock unlock];

    // 启动 accept 线程，传入当前代际值
    __weak typeof(self) weakSelf = self;
    _acceptThread = [[NSThread alloc] initWithBlock:^{
        [weakSelf guestAcceptLoopWithGeneration:myGen];
    }];
    _acceptThread.name = @"PortForwarder-GuestAccept";
    [_acceptThread start];

    NSLog(@"[PortForwarder] Guest mode started: 127.0.0.1:%u → %@:%u",
          actualPort, hostIP, hostPort);

    return YES;
}

#pragma mark - 启动房主模式

/// 启动房主模式
///
/// 完整流程：
///   1. 参数校验
///   2. 检查是否已在运行
///   3. 检查 ZeroTier framework 是否可用
///   4. 通过 ZeroTierBridge 创建 libzt 监听 socket
///   5. bind + listen（在 ZeroTier 虚拟网络中）
///   6. 启动 accept 线程
- (BOOL)startHostModeWithListenPort:(uint16_t)listenPort
                       localHostPort:(uint16_t)localHostPort {
    // ============================================================
    // 步骤 1：参数校验
    // ============================================================
    if (listenPort == 0) {
        NSLog(@"[PortForwarder] Host mode start failed: listenPort is 0");
        return NO;
    }

    if (localHostPort == 0) {
        NSLog(@"[PortForwarder] Host mode start failed: localHostPort is 0");
        return NO;
    }

    // ============================================================
    // 步骤 2：检查是否已在运行
    // ============================================================
    [_lock lock];
    if (_running) {
        [_lock unlock];
        NSLog(@"[PortForwarder] Host mode start failed: forwarder already running (mode=%ld, port %u)",
              (long)_mode, _listeningPort);
        return NO;
    }
    [_lock unlock];

    // ============================================================
    // 步骤 3：检查 ZeroTier framework 是否可用
    // ============================================================
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[PortForwarder] Host mode start failed: ZeroTier framework unavailable");
        return NO;
    }

    // ============================================================
    // 步骤 4：创建 libzt 监听 socket
    // ============================================================
    NSLog(@"[PortForwarder] Starting host mode: ZeroTier listening %u → local 127.0.0.1:%u",
          listenPort, localHostPort);

    int ztListenFD = [[ZeroTierBridge sharedInstance] createListenSocket];
    if (ztListenFD < 0) {
        NSLog(@"[PortForwarder] createListenSocket failed: fd=%d", ztListenFD);
        return NO;
    }

    // ============================================================
    // 步骤 5：bind + listen（在 ZeroTier 虚拟网络中）
    // ============================================================
    int bindResult = [[ZeroTierBridge sharedInstance] bindSocket:ztListenFD toPort:listenPort];
    if (bindResult != 0) {
        NSLog(@"[PortForwarder] bindSocket(%u) failed: result=%d", listenPort, bindResult);
        [[ZeroTierBridge sharedInstance] closeSocket:ztListenFD];
        return NO;
    }

    int listenResult = [[ZeroTierBridge sharedInstance] listenOnSocket:ztListenFD];
    if (listenResult != 0) {
        NSLog(@"[PortForwarder] listenOnSocket failed: result=%d", listenResult);
        [[ZeroTierBridge sharedInstance] closeSocket:ztListenFD];
        return NO;
    }

    NSLog(@"[PortForwarder] libzt listening succeeded: ZeroTier network port %u (fd=%d)", listenPort, ztListenFD);

    // ============================================================
    // 步骤 6：更新状态并启动 accept 线程
    // ============================================================
    [_lock lock];
    _listenFD = ztListenFD;
    _listeningPort = listenPort;
    _hostIP = nil;
    _hostPort = 0;
    _localHostPort = localHostPort;
    _mode = PortForwarderModeHost;
    _running = YES;
    _stopping = NO;
    // 代际自增，标识本次 start 周期（与房客模式相同的稳定性机制）
    _acceptGeneration++;
    int myGen = _acceptGeneration;
    [_lock unlock];

    // 启动 accept 线程，传入当前代际值
    __weak typeof(self) weakSelf = self;
    _acceptThread = [[NSThread alloc] initWithBlock:^{
        [weakSelf hostAcceptLoopWithGeneration:myGen];
    }];
    _acceptThread.name = @"PortForwarder-HostAccept";
    [_acceptThread start];

    NSLog(@"[PortForwarder] Host mode started: ZeroTier :%u → local 127.0.0.1:%u",
          listenPort, localHostPort);

    return YES;
}

#pragma mark - 房客模式 Accept 线程

/// 房客模式 Accept 线程主循环
///
/// 使用 POSIX select 检测监听 socket 是否可读（有新连接），
/// 这样可以在 stop 时通过关闭监听 socket 来唤醒 select，优雅退出。
///
/// 关键修复（P1-8）：接受代际参数。
/// 当快速 stop→start 时，旧 accept 线程可能未及时退出。由于 fd 数字可能被
/// 系统复用（旧 listenFD 关闭后，新 socket 可能拿到相同数字），旧线程会
/// 错误地接受新 listenFD 上的连接，造成重复 accept 与状态混乱。
/// 通过代际计数器识别旧线程并使其主动退出。
- (void)guestAcceptLoopWithGeneration:(int)myGen {
    NSLog(@"[PortForwarder] Guest mode Accept thread started (generation=%d)", myGen);

    while (YES) {
        @autoreleasepool {
            [_lock lock];
            int listenFD = _listenFD;
            BOOL stopping = _stopping;
            int currentGen = _acceptGeneration;
            [_lock unlock];

            // 关键修复（P1-8）：代际不匹配说明期间发生过 stop→start，
            // 当前 accept 线程属于上一周期，应立即退出，把 listenFD 让给新线程
            if (currentGen != myGen) {
                NSLog(@"[PortForwarder] Guest Accept thread: generation mismatch (my=%d, current=%d), exiting loop",
                      myGen, currentGen);
                break;
            }

            if (stopping || listenFD < 0) {
                NSLog(@"[PortForwarder] Guest Accept thread: received stop signal, exiting loop");
                break;
            }

            // 使用 select 等待监听 socket 可读（有新连接）
            // select 超时设为 1 秒，定期检查 _stopping 标志
            fd_set readSet;
            FD_ZERO(&readSet);
            FD_SET(listenFD, &readSet);

            struct timeval timeout;
            timeout.tv_sec = 1;
            timeout.tv_usec = 0;

            int selectResult = select(listenFD + 1, &readSet, NULL, NULL, &timeout);
            if (selectResult < 0) {
                if (errno == EINTR) {
                    // 被信号中断，重试
                    continue;
                }
                NSLog(@"[PortForwarder] select() failed: errno=%d (%s)", errno, strerror(errno));
                break;
            }

            if (selectResult == 0) {
                // 超时，没有新连接，继续循环
                continue;
            }

            // 有新连接
            if (FD_ISSET(listenFD, &readSet)) {
                struct sockaddr_in clientAddr;
                socklen_t clientAddrLen = sizeof(clientAddr);
                int clientFD = accept(listenFD, (struct sockaddr *)&clientAddr, &clientAddrLen);

                if (clientFD < 0) {
                    if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                        continue;
                    }
                    NSLog(@"[PortForwarder] accept() failed: errno=%d (%s)", errno, strerror(errno));

                    // 如果是 EBADF，说明监听 socket 已被关闭（stop 被调用）
                    if (errno == EBADF) {
                        break;
                    }
                    continue;
                }

                // 获取客户端 IP 和端口（用于日志）
                char clientIP[INET_ADDRSTRLEN] = {0};
                inet_ntop(AF_INET, &clientAddr.sin_addr, clientIP, sizeof(clientIP));
                uint16_t clientPort = ntohs(clientAddr.sin_port);
                NSLog(@"[PortForwarder] Guest mode new client connection: %s:%u (fd=%d)", clientIP, clientPort, clientFD);

                // 在新线程中处理客户端连接
                __weak typeof(self) weakSelf = self;
                NSThread *clientThread = [[NSThread alloc] initWithBlock:^{
                    [weakSelf handleGuestClient:clientFD];
                }];
                clientThread.name = [NSString stringWithFormat:@"PortForwarder-GuestClient-%d", clientFD];
                [clientThread start];
            }
        }
    }

    NSLog(@"[PortForwarder] Guest mode Accept thread exited");
}

#pragma mark - 房主模式 Accept 线程

/// 房主模式 Accept 线程主循环
///
/// 使用 zts_bsd_select 检测 libzt 监听 socket 是否可读（有新连接），
/// 这样可以在 stop 时通过关闭监听 socket 来唤醒 select，优雅退出。
///
/// 代际计数器机制与房客模式相同，防止快速 stop→start 时旧线程重复 accept。
- (void)hostAcceptLoopWithGeneration:(int)myGen {
    NSLog(@"[PortForwarder] Host mode Accept thread started (generation=%d)", myGen);

    while (YES) {
        @autoreleasepool {
            [_lock lock];
            int listenFD = _listenFD;
            BOOL stopping = _stopping;
            int currentGen = _acceptGeneration;
            [_lock unlock];

            // 代际不匹配说明期间发生过 stop→start，当前线程属于上一周期，应退出
            if (currentGen != myGen) {
                NSLog(@"[PortForwarder] Host Accept thread: generation mismatch (my=%d, current=%d), exiting loop",
                      myGen, currentGen);
                break;
            }

            if (stopping || listenFD < 0) {
                NSLog(@"[PortForwarder] Host Accept thread: received stop signal, exiting loop");
                break;
            }

            // 使用 zts_bsd_select 等待 libzt 监听 socket 可读（有新连接）
            // select 超时设为 1 秒，定期检查 _stopping 标志
            zts_fd_set readSet;
            ZTS_FD_ZERO(&readSet);
            ZTS_FD_SET(listenFD, &readSet);

            struct zts_timeval timeout;
            timeout.tv_sec = 1;
            timeout.tv_usec = 0;

            int selectResult = zts_bsd_select(listenFD + 1, &readSet, NULL, NULL, &timeout);
            if (selectResult < 0) {
                NSLog(@"[PortForwarder] zts_bsd_select() failed: result=%d", selectResult);
                // 如果是 EBADF 或服务错误，说明监听 socket 已被关闭（stop 被调用）
                break;
            }

            if (selectResult == 0) {
                // 超时，没有新连接，继续循环
                continue;
            }

            // 有新连接
            if (ZTS_FD_ISSET(listenFD, &readSet)) {
                int ztClientFD = [[ZeroTierBridge sharedInstance] acceptOnSocket:listenFD];

                if (ztClientFD < 0) {
                    // accept 失败，可能是暂时性错误或监听 socket 已关闭
                    NSLog(@"[PortForwarder] acceptOnSocket failed: fd=%d", ztClientFD);
                    continue;
                }

                NSLog(@"[PortForwarder] Host mode new connection via ZeroTier (ztClientFD=%d)", ztClientFD);

                // 在新线程中处理连接
                __weak typeof(self) weakSelf = self;
                NSThread *connThread = [[NSThread alloc] initWithBlock:^{
                    [weakSelf handleHostConnection:ztClientFD];
                }];
                connThread.name = [NSString stringWithFormat:@"PortForwarder-HostConn-%d", ztClientFD];
                [connThread start];
            }
        }
    }

    NSLog(@"[PortForwarder] Host mode Accept thread exited");
}

#pragma mark - 房客模式客户端处理

/// 房客模式：处理客户端连接
///
/// 流程：
///   1. 通过 ZeroTierBridge 创建 libzt socket
///   2. 连接到远程主机 hostIP:hostPort
///   3. 双向转发数据
///   4. 关闭连接
- (void)handleGuestClient:(int)clientFD {
    @autoreleasepool {
        [_lock lock];
        NSString *hostIP = [_hostIP copy];
        uint16_t hostPort = _hostPort;
        [_lock unlock];

        if (!hostIP.length) {
            NSLog(@"[PortForwarder] handleGuestClient: hostIP is empty, closing client connection");
            close(clientFD);
            return;
        }

        NSLog(@"[PortForwarder] Handling guest client connection fd=%d, forwarding to %@:%u", clientFD, hostIP, hostPort);

        // 对客户端 socket 设置 TCP_NODELAY（禁用 Nagle 算法）
        //
        // 关键性能优化：Minecraft 是实时交互游戏，玩家操作需要立即发送到服务器。
        // Nagle 算法会将小数据包合并发送以减少网络开销，但会增加延迟。
        // 对于 MC 这种实时游戏，延迟比带宽更重要，因此必须禁用 Nagle。
        int clientNoDelay = 1;
        setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &clientNoDelay, sizeof(clientNoDelay));

        // 对客户端 socket 设置 SO_KEEPALIVE（连接保活）
        //
        // 关键稳定性优化：MC 的 TCP 连接可能长时间无数据传输（如玩家挂机），
        // 中间的 NAT/防火墙可能会因超时而丢弃连接表项，导致连接"假死"。
        // SO_KEEPALIVE 让系统定期发送 keepalive 探测包，保持连接活跃。
        int clientKeepAlive = 1;
        setsockopt(clientFD, SOL_SOCKET, SO_KEEPALIVE, &clientKeepAlive, sizeof(clientKeepAlive));

        // 关键修复（P1-4）：客户端 socket 设置 SO_SNDTIMEO / SO_RCVTIMEO / SO_NOSIGPIPE
        //
        // 问题：原 writeAll 仅处理 EINTR 重试，无超时。当 MC 客户端接收缓冲区满
        // （主线程卡顿、大区块加载）时，write 会无限阻塞，导致转发线程泄漏。
        // 即使 stop() 调用 shutdown(clientFD, SHUT_RDWR)，由于线程卡在 write 而非 read，
        // shutdown 不一定能立即唤醒已阻塞的 write（取决于内核实现）。
        //
        // 修复：设置 30 秒发送/接收超时 + SO_NOSIGPIPE 防止 SIGPIPE 崩溃。
        // 超时后 writeAll 会返回 EAGAIN/EWOULDBLOCK，转发循环可主动退出。
        struct timeval ioTimeout;
        ioTimeout.tv_sec = 30;
        ioTimeout.tv_usec = 0;
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, sizeof(ioTimeout));
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &ioTimeout, sizeof(ioTimeout));
        int clientNoSigPipe = 1;
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &clientNoSigPipe, sizeof(clientNoSigPipe));

        // 关键修复（P2-11）：iOS 默认 keepalive 间隔 ~2 小时，无法及时检测半死连接。
        // 改为更激进的参数：空闲 30s 开始探测，每 10s 探测一次，3 次失败判定死亡。
        // TCP_KEEPALIVE 是 iOS 上 keep-alive 间隔的对应选项（macOS 用 TCP_KEEPALIVE，
        // Linux 用 TCP_KEEPIDLE，这里只编译 iOS，用 TCP_KEEPALIVE）。
        int keepIdle = 30;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, sizeof(keepIdle));
        int keepIntvl = 10;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPINTVL, &keepIntvl, sizeof(keepIntvl));
        int keepCnt = 3;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPCNT, &keepCnt, sizeof(keepCnt));

        // ============================================================
        // 步骤 1：创建 libzt socket
        // ============================================================
        // 使用 inet_pton 严格校验地址类型，避免误判
        BOOL isIPv6Target = (zts_inet_pton(ZTS_AF_INET6, [hostIP UTF8String], NULL) == 1);
        int socketFamily = isIPv6Target ? ZTS_AF_INET6 : ZTS_AF_INET;

        int ztFD = [[ZeroTierBridge sharedInstance] createTCPSocketForFamily:socketFamily];
        if (ztFD < 0) {
            NSLog(@"[PortForwarder] Creating ZeroTier socket(family=%d) failed: ztFD=%d", socketFamily, ztFD);
            close(clientFD);
            return;
        }

        // 对 libzt socket 也设置 TCP_NODELAY（降低 ZeroTier 虚拟网络的延迟）
        int ztNoDelay = 1;
        zts_bsd_setsockopt(ztFD, ZTS_IPPROTO_TCP, ZTS_TCP_NODELAY, &ztNoDelay, sizeof(ztNoDelay));

        // ============================================================
        // 步骤 2：连接到远程主机
        // ============================================================
        int connectResult = [[ZeroTierBridge sharedInstance] connectSocket:ztFD
                                                                    toHost:hostIP
                                                                      port:hostPort
                                                                   timeout:PORT_FORWARDER_CONNECT_TIMEOUT];
        if (connectResult != 0) {
            NSLog(@"[PortForwarder] Connecting to target via ZeroTier failed: result=%d, target=%@:%u",
                  connectResult, hostIP, hostPort);
            [[ZeroTierBridge sharedInstance] closeSocket:ztFD];
            close(clientFD);
            return;
        }

        NSLog(@"[PortForwarder] Connected to target via ZeroTier successfully: target=%@:%u, ztFD=%d",
              hostIP, hostPort, ztFD);

        // 将 fd 加入活跃列表（用于 stop 时 shutdown 唤醒阻塞的 read/recv）
        // 关键修复（P1-7）：connect 期间 stop 可能已被调用，stop 复制活跃列表时
        // 此连接尚未加入，导致 fd 漏网，stop 后仍继续转发，且永不清理。
        // 修复：加入活跃列表前检查 _running，若已停止则立即关闭 fd 并返回。
        [_lock lock];
        BOOL stillRunning = _running;
        if (stillRunning) {
            [_activePosixFDs addObject:@(clientFD)];
            [_activeZtFDs addObject:@(ztFD)];
        }
        [_lock unlock];

        if (!stillRunning) {
            NSLog(@"[PortForwarder] handleGuestClient: forwarder stopped, closing new connection clientFD=%d ztFD=%d",
                  clientFD, ztFD);
            [[ZeroTierBridge sharedInstance] closeSocket:ztFD];
            close(clientFD);
            return;
        }

        // ============================================================
        // 步骤 3：双向转发数据
        // ============================================================
        [self forwardDataBetweenPosixFD:clientFD ztFD:ztFD];

        // 从活跃列表中移除（转发已结束，fd 即将被关闭）
        [_lock lock];
        [_activePosixFDs removeObject:@(clientFD)];
        [_activeZtFDs removeObject:@(ztFD)];
        [_lock unlock];

        // ============================================================
        // 步骤 4：关闭连接
        // ============================================================
        NSLog(@"[PortForwarder] Guest forwarding ended, closing connection: clientFD=%d, ztFD=%d", clientFD, ztFD);
        [[ZeroTierBridge sharedInstance] closeSocket:ztFD];
        close(clientFD);
    }
}

#pragma mark - 房主模式连接处理

/// 房主模式：处理通过 ZeroTier 接受的连接
///
/// 流程：
///   1. 对 libzt 客户端 fd 设置 TCP_NODELAY
///   2. 创建本地 BSD socket
///   3. 连接到 127.0.0.1:localHostPort（MC LAN 端口）
///   4. 双向转发数据（libzt socket ↔ 本地 BSD socket）
///   5. 关闭连接
- (void)handleHostConnection:(int)ztClientFD {
    @autoreleasepool {
        [_lock lock];
        uint16_t localHostPort = _localHostPort;
        [_lock unlock];

        if (localHostPort == 0) {
            NSLog(@"[PortForwarder] handleHostConnection: localHostPort is 0, closing connection");
            [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
            return;
        }

        NSLog(@"[PortForwarder] Handling host connection ztClientFD=%d, forwarding to local 127.0.0.1:%u",
              ztClientFD, localHostPort);

        // 对 libzt 客户端 fd 设置 TCP_NODELAY（降低 ZeroTier 虚拟网络的延迟）
        int ztNoDelay = 1;
        zts_bsd_setsockopt(ztClientFD, ZTS_IPPROTO_TCP, ZTS_TCP_NODELAY, &ztNoDelay, sizeof(ztNoDelay));

        // ============================================================
        // 步骤 1：创建本地 BSD socket
        // ============================================================
        int localFD = socket(AF_INET, SOCK_STREAM, 0);
        if (localFD < 0) {
            NSLog(@"[PortForwarder] Creating local socket failed: errno=%d (%s)", errno, strerror(errno));
            [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
            return;
        }

        // 对本地 socket 设置 TCP_NODELAY（禁用 Nagle 算法，降低延迟）
        int localNoDelay = 1;
        setsockopt(localFD, IPPROTO_TCP, TCP_NODELAY, &localNoDelay, sizeof(localNoDelay));

        // 对本地 socket 设置 SO_KEEPALIVE（连接保活）
        int localKeepAlive = 1;
        setsockopt(localFD, SOL_SOCKET, SO_KEEPALIVE, &localKeepAlive, sizeof(localKeepAlive));

        // 设置 SO_SNDTIMEO / SO_RCVTIMEO / SO_NOSIGPIPE（与房客模式相同的稳定性机制）
        struct timeval ioTimeout;
        ioTimeout.tv_sec = 30;
        ioTimeout.tv_usec = 0;
        setsockopt(localFD, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, sizeof(ioTimeout));
        setsockopt(localFD, SOL_SOCKET, SO_RCVTIMEO, &ioTimeout, sizeof(ioTimeout));
        int localNoSigPipe = 1;
        setsockopt(localFD, SOL_SOCKET, SO_NOSIGPIPE, &localNoSigPipe, sizeof(localNoSigPipe));

        // 激进 keepalive 参数（与房客模式相同）
        int keepIdle = 30;
        setsockopt(localFD, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, sizeof(keepIdle));
        int keepIntvl = 10;
        setsockopt(localFD, IPPROTO_TCP, TCP_KEEPINTVL, &keepIntvl, sizeof(keepIntvl));
        int keepCnt = 3;
        setsockopt(localFD, IPPROTO_TCP, TCP_KEEPCNT, &keepCnt, sizeof(keepCnt));

        // ============================================================
        // 步骤 2：连接到本地 MC LAN 端口（非阻塞 connect + select 超时控制）
        // ============================================================
        // 关键修复：之前使用阻塞 connect()，SO_SNDTIMEO/SO_RCVTIMEO 不影响 connect()，
        // 若本地端口因异常（防火墙、系统状态异常等）导致 SYN 被丢弃，会永久阻塞，
        // 且 stop() 的 shutdown 不会唤醒正在 connect 中的 socket，导致连接处理线程泄漏。
        // 现改为非阻塞 connect + select 设置 5 秒超时，超时后关闭 fd 释放线程。
        struct sockaddr_in localAddr;
        memset(&localAddr, 0, sizeof(localAddr));
        localAddr.sin_family = AF_INET;
        localAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // 127.0.0.1
        localAddr.sin_port = htons(localHostPort);

        // 设置 socket 为非阻塞
        int flags = fcntl(localFD, F_GETFL, 0);
        if (flags < 0 || fcntl(localFD, F_SETFL, flags | O_NONBLOCK) < 0) {
            NSLog(@"[PortForwarder] Setting non-blocking failed: errno=%d (%s), falling back to blocking connect", errno, strerror(errno));
            // 退回阻塞 connect（loopback 通常立即返回，影响有限）
            int connectResult = connect(localFD, (struct sockaddr *)&localAddr, sizeof(localAddr));
            if (connectResult < 0) {
                NSLog(@"[PortForwarder] Connecting to local MC LAN port failed: 127.0.0.1:%u, errno=%d (%s)",
                      localHostPort, errno, strerror(errno));
                close(localFD);
                [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
                return;
            }
        } else {
            // 非阻塞 connect：通常立即返回 -1（EINPROGRESS）或 0（loopback 端口开放时）
            int connectResult = connect(localFD, (struct sockaddr *)&localAddr, sizeof(localAddr));
            if (connectResult < 0) {
                if (errno != EINPROGRESS) {
                    // 立即失败（如 ECONNREFUSED 表示端口未开放）
                    NSLog(@"[PortForwarder] Connecting to local MC LAN port failed: 127.0.0.1:%u, errno=%d (%s)",
                          localHostPort, errno, strerror(errno));
                    close(localFD);
                    [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
                    return;
                }
                // EINPROGRESS：等待可写（连接完成），使用 select 设置 5 秒超时
                fd_set writeSet;
                FD_ZERO(&writeSet);
                FD_SET(localFD, &writeSet);
                struct timeval connTimeout;
                connTimeout.tv_sec = 5;
                connTimeout.tv_usec = 0;
                int selRet = select(localFD + 1, NULL, &writeSet, NULL, &connTimeout);
                if (selRet <= 0) {
                    // selRet == 0 表示超时；selRet < 0 表示出错
                    NSLog(@"[PortForwarder] Connecting to local MC LAN port timeout/failed: 127.0.0.1:%u, selRet=%d, errno=%d (%s)",
                          localHostPort, selRet, errno, strerror(errno));
                    close(localFD);
                    [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
                    return;
                }
                // 检查 SO_ERROR 确认连接是否真正成功
                int sockErr = 0;
                socklen_t errLen = sizeof(sockErr);
                if (getsockopt(localFD, SOL_SOCKET, SO_ERROR, &sockErr, &errLen) < 0 || sockErr != 0) {
                    NSLog(@"[PortForwarder] Connecting to local MC LAN port failed (SO_ERROR=%d): 127.0.0.1:%u",
                          sockErr, localHostPort);
                    close(localFD);
                    [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
                    return;
                }
            }
            // 恢复阻塞模式（后续 forwardDataBetweenPosixFD 依赖阻塞 read/write 配合 SO_RCVTIMEO）
            (void)fcntl(localFD, F_SETFL, flags);
        }

        NSLog(@"[PortForwarder] Connected to local MC LAN port successfully: 127.0.0.1:%u, localFD=%d",
              localHostPort, localFD);

        // 将 fd 加入活跃列表（用于 stop 时 shutdown 唤醒阻塞的 read/recv）
        // 与房客模式相同的 P1-7 修复：检查 _running 防止 stop 后漏网
        [_lock lock];
        BOOL stillRunning = _running;
        if (stillRunning) {
            [_activePosixFDs addObject:@(localFD)];
            [_activeZtFDs addObject:@(ztClientFD)];
        }
        [_lock unlock];

        if (!stillRunning) {
            NSLog(@"[PortForwarder] handleHostConnection: forwarder stopped, closing new connection localFD=%d ztClientFD=%d",
                  localFD, ztClientFD);
            close(localFD);
            [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
            return;
        }

        // ============================================================
        // 步骤 3：双向转发数据
        // ============================================================
        [self forwardDataBetweenPosixFD:localFD ztFD:ztClientFD];

        // 从活跃列表中移除（转发已结束，fd 即将被关闭）
        [_lock lock];
        [_activePosixFDs removeObject:@(localFD)];
        [_activeZtFDs removeObject:@(ztClientFD)];
        [_lock unlock];

        // ============================================================
        // 步骤 4：关闭连接
        // ============================================================
        NSLog(@"[PortForwarder] Host forwarding ended, closing connection: localFD=%d, ztClientFD=%d",
              localFD, ztClientFD);
        [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
        close(localFD);
    }
}

#pragma mark - 双向数据转发

/// 双向转发数据
///
/// 在 POSIX socket 和 libzt socket 之间双向转发数据。
/// 使用 GCD 并发队列，两个方向同时转发。
/// 使用 atomic_bool 标志确保跨线程内存可见性。
///
/// 两种模式的数据流向：
///   房客模式：posixFD=客户端（MC），ztFD=远程（房主 ZeroTier）
///   房主模式：posixFD=本地（MC LAN），ztFD=客户端（房客 ZeroTier）
///
/// @param posixFD POSIX socket（系统 read/write）
/// @param ztFD libzt socket（ZeroTierBridge recvData/sendData）
- (void)forwardDataBetweenPosixFD:(int)posixFD
                             ztFD:(int)ztFD {
    // 使用 atomic_bool 替代 __block BOOL，确保跨线程内存可见性
    // （参考 SOCKS5Proxy 的实现，ARM64 弱内存模型需要原子操作提供内存屏障）
    __block atomic_bool posixClosed = ATOMIC_VAR_INIT(false);
    __block atomic_bool ztClosed = ATOMIC_VAR_INIT(false);

    // 创建并发队列用于双向转发
    dispatch_queue_t forwardQueue = dispatch_queue_create("com.angelaura.portforwarder.forward", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t group = dispatch_group_create();

    // ============================================================
    // 方向 1：posix → zt
    // 从 POSIX socket 读取数据（read），通过 libzt socket 发送（sendData）
    // ============================================================
    dispatch_group_async(group, forwardQueue, ^{
        uint8_t buffer[PORT_FORWARDER_BUFFER_SIZE];

        while (YES) {
            @autoreleasepool {
                // 检查对端是否已关闭（原子读，自带内存屏障）
                if (atomic_load(&ztClosed)) {
                    NSLog(@"[PortForwarder] posix→zt: peer closed, exiting forwarding");
                    break;
                }

                // 从 POSIX socket 读取数据（系统 read）
                ssize_t n = read(posixFD, buffer, sizeof(buffer));
                if (n <= 0) {
                    // n == 0：POSIX 端关闭连接
                    // n < 0：读取错误
                    NSLog(@"[PortForwarder] posix→zt ended: n=%zd, errno=%d", n, errno);

                    // 标记 POSIX 端已关闭（原子写，自带内存屏障）
                    atomic_store(&posixClosed, true);

                    // 关闭 zt 端的写端，通知 zt→posix 方向退出
                    // shutdown 会导致另一端的 recv 返回 0
                    [[ZeroTierBridge sharedInstance] shutdownSocket:ztFD how:SHUT_WR];
                    break;
                }

                // 通过 libzt socket 发送数据
                ssize_t sent = [[ZeroTierBridge sharedInstance] sendData:ztFD
                                                                  buffer:buffer
                                                                  length:(size_t)n];
                if (sent <= 0) {
                    NSLog(@"[PortForwarder] Sending to zt side failed: sent=%zd", sent);

                    // 标记 zt 端已关闭（原子写）
                    atomic_store(&ztClosed, true);

                    // 关闭 POSIX 端的写端
                    shutdown(posixFD, SHUT_WR);
                    break;
                }
            }
        }
    });

    // ============================================================
    // 方向 2：zt → posix
    // 从 libzt socket 接收数据（recvData），发送给 POSIX socket（writeAll）
    // ============================================================
    dispatch_group_async(group, forwardQueue, ^{
        uint8_t buffer[PORT_FORWARDER_BUFFER_SIZE];

        while (YES) {
            @autoreleasepool {
                // 检查 POSIX 端是否已关闭（原子读，自带内存屏障）
                if (atomic_load(&posixClosed)) {
                    NSLog(@"[PortForwarder] zt→posix: peer closed, exiting forwarding");
                    break;
                }

                // 通过 libzt socket 接收数据
                ssize_t n = [[ZeroTierBridge sharedInstance] recvData:ztFD
                                                                buffer:buffer
                                                                length:sizeof(buffer)];
                if (n <= 0) {
                    // n == 0：zt 端关闭连接
                    // n < 0：接收错误
                    NSLog(@"[PortForwarder] zt→posix ended: n=%zd", n);

                    // 标记 zt 端已关闭（原子写）
                    atomic_store(&ztClosed, true);

                    // 关闭 POSIX 端的写端，通知 posix→zt 方向退出
                    shutdown(posixFD, SHUT_WR);
                    break;
                }

                // 发送数据给 POSIX socket（系统 write）
                ssize_t sent = writeAll(posixFD, buffer, (size_t)n);
                if (sent <= 0) {
                    NSLog(@"[PortForwarder] Sending to POSIX side failed: sent=%zd", sent);

                    // 标记 POSIX 端已关闭（原子写）
                    atomic_store(&posixClosed, true);

                    // 关闭 zt 端的写端
                    [[ZeroTierBridge sharedInstance] shutdownSocket:ztFD how:SHUT_WR];
                    break;
                }
            }
        }
    });

    // 等待两个方向的转发都结束
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    NSLog(@"[PortForwarder] Bidirectional forwarding ended: posixFD=%d, ztFD=%d", posixFD, ztFD);
}

#pragma mark - 停止端口转发

/// 停止端口转发（统一停止房主模式和房客模式）
///
/// 流程：
///   1. 设置停止标志
///   2. 关闭监听 socket（唤醒 accept 线程的 select）
///      - 房客模式：POSIX close()
///      - 房主模式：ZeroTierBridge closeSocket:
///   3. shutdown 所有活跃的 POSIX/libzt fd（唤醒阻塞的 read/recv）
///   4. 清理状态
///
/// 关键稳定性优化：shutdown 活跃连接
///   如果不 shutdown，正在 forwardDataBetweenPosixFD:ztFD: 中阻塞的 read/recvData
///   不会返回，客户端线程会一直存在（线程泄漏）。shutdown(SHUT_RDWR) 会立即
///   唤醒所有阻塞在该 fd 上的 read/write，让客户端线程正常退出。
- (void)stop {
    BOOL isMainThread = [NSThread isMainThread];

    [_lock lock];
    if (!_running) {
        [_lock unlock];
        NSLog(@"[PortForwarder] stop: forwarder not running, skipping");
        return;
    }

    PortForwarderMode mode = _mode;
    uint16_t listeningPort = _listeningPort;

    NSLog(@"[PortForwarder] Stopping port forwarding (mode=%ld, port %u, isMainThread=%d)",
          (long)mode, listeningPort, isMainThread);

    _stopping = YES;
    _running = NO;
    int listenFD = _listenFD;
    _listenFD = -1;
    NSThread *acceptThread = _acceptThread;

    // 复制活跃 fd 列表（不阻塞太久）
    NSArray<NSNumber *> *posixFDs = [_activePosixFDs copy];
    NSArray<NSNumber *> *ztFDs = [_activeZtFDs copy];
    [_activePosixFDs removeAllObjects];
    [_activeZtFDs removeAllObjects];
    [_lock unlock];

    // 1. 关闭监听 socket，唤醒 accept 线程的 select
    if (listenFD >= 0) {
        if (mode == PortForwarderModeHost) {
            // 房主模式：libzt 监听 socket，通过 ZeroTierBridge 关闭
            [[ZeroTierBridge sharedInstance] closeSocket:listenFD];
        } else {
            // 房客模式：POSIX 监听 socket，通过系统 close 关闭
            close(listenFD);
        }
    }

    // 2. shutdown 所有活跃的 POSIX/libzt fd（唤醒阻塞的 read/recv）
    NSLog(@"[PortForwarder] Shutting down %lu POSIX connections and %lu libzt connections...",
          (unsigned long)posixFDs.count, (unsigned long)ztFDs.count);

    for (NSNumber *fdNum in posixFDs) {
        int fd = [fdNum intValue];
        if (fd >= 0) {
            // POSIX socket 使用系统 shutdown
            shutdown(fd, SHUT_RDWR);
        }
    }

    for (NSNumber *fdNum in ztFDs) {
        int fd = [fdNum intValue];
        if (fd >= 0) {
            // libzt socket 使用 ZeroTierBridge shutdown
            [[ZeroTierBridge sharedInstance] shutdownSocket:fd how:SHUT_RDWR];
        }
    }

    // 3. 清理状态（主线程立即返回，客户端线程在后台自行退出）
    [_lock lock];
    _acceptThread = nil;
    _listeningPort = 0;
    _hostIP = nil;
    _hostPort = 0;
    _localHostPort = 0;
    _mode = PortForwarderModeNone;
    _stopping = NO;
    [_lock unlock];

    NSLog(@"[PortForwarder] Port forwarding stopped");
}

@end
