//
//  PortForwarder.h
//  Angel Aura Amethyst
//
//  TCP 端口转发器（支持房主模式和房客模式）
//
//  ============================================================================
//  设计说明
//  ============================================================================
//
//  本文件实现 TCP 端口转发器，支持两种模式，实现 iOS 与 PC/Mac/Android 的
//  多端联机：
//
//  1. 房客模式（Guest Mode）：
//     本地 BSD socket 监听 → 通过 libzt socket 转发到远程 ZeroTier IP
//     用于 iOS 房客连接房主（PC/Mac/Android/iOS）。
//     房客在 MC 中输入 127.0.0.1:localPort 即可连接到房主。
//
//  2. 房主模式（Host Mode，反向转发）：
//     ZeroTier 网络监听（libzt socket）→ 转发到本地 MC LAN 端口（BSD socket）
//     用于 iOS 房主接受 PC/Mac/Android/iOS 房客的连接。
//     房客在 MC 中直接连接房主的 ZeroTier IP:listenPort 即可进入游戏。
//
//  为什么需要端口转发而不是 SOCKS5 代理？
//
//  Minecraft 从 1.7.2 开始使用 Netty 作为网络库。Netty 的 NioSocketChannel
//  底层使用 java.nio.channels.SocketChannel，而 SocketChannel 不检查 Java 的
//  ProxySelector。这意味着 JVM 参数 -DsocksProxyHost/-DsocksProxyPort 对
//  Minecraft 的多人游戏连接无效（只对 java.net.Socket 有效，如登录认证等）。
//
//  因此，当房客在 MC 中输入房主的 ZeroTier IP（如 10.147.17.1:54321）时：
//    1. MC 的 Netty 创建 NioSocketChannel
//    2. NioSocketChannel 直接创建 SocketChannel
//    3. SocketChannel 尝试直接连接 10.147.17.1:54321
//    4. 系统没有 ZeroTier 网络接口（我们用的是进程内 libzt）
//    5. 系统无法路由到 10.147.17.1
//    6. 连接失败，显示"无法连接"
//
//  房客模式的端口转发方案：
//    1. 在本地监听一个 TCP 端口（如 127.0.0.1:25565）
//    2. 当 MC 连接到 127.0.0.1:25565 时，通过 libzt 的 socket API 连接到
//       房主的 ZeroTier IP:端口
//    3. 双向转发数据
//    4. 房客在 MC 中输入 127.0.0.1:25565 即可连接
//
//  房主模式的反向转发方案：
//    1. 通过 libzt 的 socket API 在 ZeroTier 网络中监听端口（如 0.0.0.0:25565）
//    2. 当房客通过 ZeroTier 网络连接到房主的 IP:25565 时，接受连接
//    3. 创建本地 BSD socket 连接到 127.0.0.1:localHostPort（MC LAN 端口）
//    4. 双向转发数据（libzt socket ↔ 本地 BSD socket）
//    5. 房客在 MC 中直接输入房主的 ZeroTier IP:25565 即可连接
//
//  架构说明：
//    房客模式：
//      - 监听 socket：系统 POSIX socket（socket/bind/listen/accept）
//      - 客户端 socket：系统 POSIX socket（accept 返回的 fd）
//      - 远程 socket：libzt socket（通过 ZeroTierBridge 创建）
//    房主模式：
//      - 监听 socket：libzt socket（通过 ZeroTierBridge 创建）
//      - 客户端 socket：libzt socket（acceptOnSocket: 返回的 fd）
//      - 本地 socket：系统 POSIX socket（连接到 127.0.0.1:localHostPort）
//    - 转发使用 GCD 并发队列，两个方向同时转发
//
//  与 ZeroTierBridge 的关系：
//    PortForwarder 依赖 ZeroTierBridge 提供的 socket 方法与 ZeroTier 虚拟网络通信。
//    ZeroTierBridge 必须已启动节点并加入网络后，PortForwarder 才能正常工作。
//
//  注意事项：
//    - PortForwarder 是单例模式（sharedForwarder）
//    - 同一时间只能运行一种模式（房主模式或房客模式），启动新模式前应先 stop 旧模式
//    - accept 循环在后台线程运行，避免阻塞主线程
//    - 数据转发线程使用 autorelease pool 和 atomic 操作确保线程安全
//
//  =============================================================================

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 端口转发器默认本地监听端口（Minecraft 默认服务器端口）
extern const uint16_t PortForwarderDefaultLocalPort;

/// 端口转发模式
typedef NS_ENUM(NSInteger, PortForwarderMode) {
    PortForwarderModeNone = 0,   ///< 未运行
    PortForwarderModeGuest,      ///< 房客模式：本地监听 → 转发到远程 ZeroTier IP
    PortForwarderModeHost,       ///< 房主模式：ZeroTier 网络监听 → 转发到本地 MC LAN 端口
};

/// TCP 端口转发器（支持房主模式和房客模式）
///
/// 单例模式，通过 +sharedForwarder 获取全局唯一实例。
/// 同一时间只能运行一种模式，启动新模式前应先 stop 旧模式。
@interface PortForwarder : NSObject

/// 单例访问
+ (instancetype)sharedForwarder;

#pragma mark - 房客模式

/// 启动房客模式：本地监听 → 转发到远程 ZeroTier IP
///
/// 创建 POSIX socket 监听 127.0.0.1:localPort，并在后台线程接受客户端连接。
/// 每个客户端连接后，通过 ZeroTierBridge 创建 libzt socket 连接到
/// hostIP:hostPort，然后双向转发数据。
///
/// 如果 localPort 为 0，则由系统自动分配可用端口。
/// 如果 localPort 被占用，会尝试 localPort+1 到 localPort+9。
///
/// @param localPort 本地监听端口（0 表示自动分配）
/// @param hostIP 远程主机地址（房主的 ZeroTier IP）
/// @param hostPort 远程端口（房主的 MC LAN 端口）
/// @return YES 表示启动成功，NO 表示失败
- (BOOL)startGuestModeWithLocalPort:(uint16_t)localPort
                              hostIP:(NSString *)hostIP
                            hostPort:(uint16_t)hostPort;

#pragma mark - 房主模式

/// 启动房主模式：ZeroTier 网络监听 → 转发到本地 MC LAN 端口
///
/// 通过 ZeroTierBridge 创建 libzt socket，在 ZeroTier 网络中监听
/// 0.0.0.0:listenPort，并在后台线程接受客户端连接。
/// 每个客户端连接后，创建本地 BSD socket 连接到 127.0.0.1:localHostPort，
/// 然后双向转发数据。
///
/// 房客（PC/Mac/Android/iOS）在 MC 中直接连接房主的 ZeroTier IP:listenPort
/// 即可进入游戏。
///
/// @param listenPort 在 ZeroTier 网络中监听的端口（通常为 25565）
/// @param localHostPort 本地 MC LAN 端口（MC 中"对局域网开放"后聊天框显示的端口号）
/// @return YES 表示启动成功，NO 表示失败
- (BOOL)startHostModeWithListenPort:(uint16_t)listenPort
                       localHostPort:(uint16_t)localHostPort;

#pragma mark - 停止

/// 停止端口转发（统一停止房主模式和房客模式）
///
/// 关闭监听 socket，停止接受新连接。
/// 已建立的客户端连接会继续处理直到完成，然后自动清理。
- (void)stop;

#pragma mark - 状态查询

/// 端口转发器是否正在运行
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// 当前运行模式
@property (nonatomic, readonly) PortForwarderMode mode;

/// 当前监听端口
///
/// 房客模式：本地 BSD socket 监听端口
/// 房主模式：ZeroTier 网络中 libzt socket 监听端口
@property (nonatomic, readonly) uint16_t listeningPort;

#pragma mark - 房客模式属性

/// 房客模式：当前转发的远程主机（房主的 ZeroTier IP）
@property (nonatomic, readonly, copy, nullable) NSString *hostIP;

/// 房客模式：当前转发的远程端口（房主的 MC LAN 端口）
@property (nonatomic, readonly) uint16_t hostPort;

#pragma mark - 房主模式属性

/// 房主模式：本地 MC LAN 端口（MC 中"对局域网开放"后聊天框显示的端口号）
@property (nonatomic, readonly) uint16_t localHostPort;

@end

NS_ASSUME_NONNULL_END
