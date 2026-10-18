//
//  SOCKS5Proxy.h
//  Angel Aura Amethyst
//
//  本地 SOCKS5 代理服务器
//
//  ============================================================================
//  设计说明
//  ============================================================================
//
//  本文件实现一个本地 SOCKS5 代理服务器，用于将 Minecraft 客户端的流量
//  通过 ZeroTier 虚拟网络转发到房主的游戏服务器。
//
//  工作流程：
//    1. 代理服务器监听 127.0.0.1:port（默认 1080）
//    2. Minecraft 客户端配置 SOCKS5 代理指向 127.0.0.1:port
//    3. 客户端连接到代理后，进行 SOCKS5 握手（RFC 1928）
//    4. 代理解析客户端请求的目标地址（房主的 ZeroTier IP + 端口）
//    5. 代理通过 ZeroTierBridge 创建 libzt socket 连接到目标
//    6. 代理在客户端 socket 和 ZeroTier socket 之间双向转发数据
//
//  架构说明：
//    - 监听 socket：使用系统 POSIX socket（socket/bind/listen/accept）
//    - 客户端 socket：系统 POSIX socket（accept 返回的 fd）
//    - 远程 socket：libzt socket（通过 ZeroTierBridge 创建）
//    - 这样设计是因为 ZeroTier 的 libzt socket 用于虚拟网络通信，
//      而本地监听只需要系统 socket 即可
//
//  SOCKS5 协议（RFC 1928）：
//    1. 握手阶段：
//       客户端 → 代理：VER(1) NMETHODS(1) METHODS(NMETHODS)
//       代理 → 客户端：VER(1) METHOD(1)
//    2. 请求阶段：
//       客户端 → 代理：VER(1) CMD(1) RSV(1) ATYP(1) DST.ADDR(?) DST.PORT(2)
//       代理 → 客户端：VER(1) REP(1) RSV(1) ATYP(1) BND.ADDR(?) BND.PORT(2)
//    3. 转发阶段：双向数据转发
//
//  与 ZeroTierBridge 的关系：
//    SOCKS5Proxy 依赖 ZeroTierBridge 提供的 socket 方法（createTCPSocket、
//    connectSocket:toHost:port:timeout:、sendData:buffer:length:、
//    recvData:buffer:length:、closeSocket:）与 ZeroTier 虚拟网络通信。
//    ZeroTierBridge 必须已启动节点并加入网络后，SOCKS5Proxy 才能正常工作。
//
//  ============================================================================

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// SOCKS5 代理默认监听端口
extern const uint16_t SOCKS5ProxyDefaultPort;

/// 客户端连接通知
/// userInfo: { @"clientIP": NSString, @"clientPort": NSNumber }
extern NSNotificationName const SOCKS5ProxyClientConnectedNotification;

/// 客户端断开通知
/// userInfo: { @"reason": NSString }
extern NSNotificationName const SOCKS5ProxyClientDisconnectedNotification;

/// 本地 SOCKS5 代理服务器
///
/// 单例模式，通过 +sharedProxy 获取全局唯一实例。
/// 代理服务器监听 127.0.0.1，将客户端流量通过 ZeroTier 虚拟网络转发到目标主机。
@interface SOCKS5Proxy : NSObject

/// 单例访问
+ (instancetype)sharedProxy;

/// 启动代理服务器
///
/// 创建 POSIX socket 监听 127.0.0.1:port，并在后台线程接受客户端连接。
/// 如果 port 为 0，则由系统自动分配可用端口（可通过 listeningPort 查询实际端口）。
///
/// 启动前会检查 ZeroTier framework 是否可用，如果 framework 不可用（stub 模式），
/// 则拒绝启动。
///
/// @param port 监听端口（0 表示自动分配）
/// @param error 错误输出（如果失败）
/// @return YES 如果启动成功
- (BOOL)startWithPort:(uint16_t)port
                error:(NSError **)error;

/// 停止代理服务器
///
/// 关闭监听 socket，停止接受新连接。
/// 已建立的客户端连接会继续处理直到完成，然后自动清理。
- (void)stop;

/// 代理服务器是否正在运行
/// @return YES 如果正在运行
- (BOOL)isRunning;

/// 当前监听端口
/// @return 监听端口（未运行时返回 0）
- (uint16_t)listeningPort;

@end

NS_ASSUME_NONNULL_END
