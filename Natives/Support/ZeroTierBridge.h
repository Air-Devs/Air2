//
//  ZeroTierBridge.h
//  Angel Aura Amethyst
//
//  ZeroTier libzt C API 的 Objective-C 封装层（精简版）
//
//  设计说明：
//    本文件是 ZeroTier 官方 Apple Framework (zt.framework) 的 Objective-C 封装层，
//    参照 ShardLauncher-iOS 的简洁实现 + libzt 官方示例，仅保留必要功能：
//      - 节点启动/停止
//      - 网络加入/离开
//      - 地址查询
//      - 客户端/服务端 socket 操作（供 SOCKS5Proxy 与 PortForwarder 使用）
//      - 事件转发到主线程
//
//  已移除的复杂逻辑：
//    - Keychain 身份备份/恢复（改由 my.zerotier.com 重新授权新节点）
//    - 自动重连指数退避（改为回前台时一次性重试）
//    - 保活定时器（libzt 自带 NAT keepalive）
//    - Peer 连接模式/网络详情等冗余查询接口
//

#import <Foundation/Foundation.h>
#import "external/ZeroTierFramework/ios-example-app/zt.framework/Headers/ZeroTierSockets.h"

NS_ASSUME_NONNULL_BEGIN

// 前向声明：delegate 协议方法需要引用 ZeroTierBridge 类型
@class ZeroTierBridge;

/// ZeroTier 节点状态
typedef NS_ENUM(NSInteger, ZeroTierNodeStatus) {
    ZeroTierNodeStatusStopped = 0,  // 节点已停止（未启动或已关闭）
    ZeroTierNodeStatusStarting,     // 节点正在启动中（已调用 zts_node_start，等待 ONLINE 事件）
    ZeroTierNodeStatusOnline,       // 节点已上线（至少一个上游节点可达）
    ZeroTierNodeStatusOffline,      // 节点已离线（网络不可达）
};

/// ZeroTier 网络状态
typedef NS_ENUM(NSInteger, ZeroTierNetworkStatus) {
    ZeroTierNetworkStatusUnknown = 0,           // 状态未知（未加入或未收到事件）
    ZeroTierNetworkStatusRequestingConfig,      // 正在请求网络配置
    ZeroTierNetworkStatusOk,                    // 已成功加入网络（配置已就绪）
    ZeroTierNetworkStatusAccessDenied,          // 加入被拒绝（节点未授权）
    ZeroTierNetworkStatusNotFound,              // 网络不存在
    ZeroTierNetworkStatusClientTooOld,          // ZeroTier 客户端版本过旧
    ZeroTierNetworkStatusDown,                  // 网络控制器不可达
};

/// ZeroTierBridge 代理协议
///
/// 所有方法均为 @optional，所有回调方法都会在主线程调用。
@protocol ZeroTierBridgeDelegate <NSObject>
@optional

/// 节点已上线
- (void)zeroTierNodeOnlineWithID:(uint64_t)nodeID;

/// 节点已离线（网络不可达）
- (void)zeroTierNodeOffline;

/// 节点已关闭（zts_node_stop 完成）
- (void)zeroTierNodeDown;

/// 网络已就绪（已收到 IP 地址分配）
- (void)zeroTierNetworkReady:(uint64_t)networkID
                        ipv4:(nullable NSString *)ipv4
                        ipv6:(nullable NSString *)ipv6;

/// 网络不存在
- (void)zeroTierNetworkNotFound:(uint64_t)networkID;

/// 网络访问被拒绝（节点未授权）
- (void)zeroTierNetworkAccessDenied:(uint64_t)networkID;

/// ZeroTier 客户端版本过旧
- (void)zeroTierNetworkClientTooOld:(uint64_t)networkID;

/// 网络控制器不可达
- (void)zeroTierNetworkDown:(uint64_t)networkID;

@end

/// ZeroTier 桥接类（libzt C API 的 Objective-C 封装）
///
/// 单例模式，通过 +sharedInstance 获取全局唯一实例。
@interface ZeroTierBridge : NSObject

/// 单例访问
+ (instancetype)sharedInstance;

/// 代理对象（弱引用，避免循环引用）
@property (nonatomic, weak, nullable) id<ZeroTierBridgeDelegate> delegate;

#pragma mark - 节点管理

/// 启动 ZeroTier 节点
/// @param homeDir 身份文件存储目录
/// @param error 错误输出（如果失败）
/// @return YES 如果启动请求已成功提交（不代表节点已上线）
- (BOOL)startNodeWithHomeDirectory:(NSString *)homeDir
                             error:(NSError **)error;

/// 停止 ZeroTier 节点，清理内部状态缓存
- (void)stopNode;

/// 节点是否在线
- (BOOL)isNodeOnline;

/// 获取节点 ID（节点未上线则返回 0）
- (uint64_t)nodeID;

/// 获取节点状态
- (ZeroTierNodeStatus)nodeStatus;

#pragma mark - 网络管理

/// 加入 ZeroTier 网络
- (BOOL)joinNetwork:(uint64_t)networkID error:(NSError **)error;

/// 离开 ZeroTier 网络
- (BOOL)leaveNetwork:(uint64_t)networkID;

/// 获取网络状态
- (ZeroTierNetworkStatus)networkStatus:(uint64_t)networkID;

/// 获取网络分配的 IPv4 地址（未分配则返回 nil）
- (nullable NSString *)ipv4AddressForNetwork:(uint64_t)networkID;

/// 获取网络分配的 IPv6 地址（未分配则返回 nil）
- (nullable NSString *)ipv6AddressForNetwork:(uint64_t)networkID;

#pragma mark - 框架检测与等待

/// 检测 zt.framework 是否可用（非 stub）
///
/// 首次调用通过 zts_node_start() 返回值检测，结果会缓存。
- (BOOL)isFrameworkAvailable;

/// 等待节点上线（通过信号量等待事件，超时返回 NO）
- (BOOL)waitForNodeOnlineWithTimeout:(NSTimeInterval)timeout;

/// 等待网络就绪（通过信号量等待事件，超时返回 NO）
- (BOOL)waitForNetworkReady:(uint64_t)networkID timeout:(NSTimeInterval)timeout;

#pragma mark - Socket 客户端操作（供 SOCKS5Proxy 和 PortForwarder 房客模式使用）

/// 创建 TCP socket（封装 zts_bsd_socket，IPv4）
- (int)createTCPSocket;

/// 创建 TCP socket（指定地址族）
- (int)createTCPSocketForFamily:(int)family;

/// 连接 socket 到目标主机
- (int)connectSocket:(int)fd
              toHost:(NSString *)host
                port:(uint16_t)port
             timeout:(NSTimeInterval)timeout;

/// 关闭 socket
- (int)closeSocket:(int)fd;

/// 关闭 socket 的读/写端
- (int)shutdownSocket:(int)fd how:(int)how;

/// 发送数据
- (ssize_t)sendData:(int)fd
             buffer:(const void *)buf
              length:(size_t)len;

/// 接收数据
- (ssize_t)recvData:(int)fd
             buffer:(void *)buf
              length:(size_t)len;

#pragma mark - Socket 服务端 API（供 PortForwarder 房主模式使用）

/// 创建 libzt TCP socket，返回 fd（< 0 表示失败）
- (int)createListenSocket;

/// 绑定到 0.0.0.0:port，返回 0 表示成功
- (int)bindSocket:(int)fd toPort:(uint16_t)port;

/// 监听（backlog=128），返回 0 表示成功
- (int)listenOnSocket:(int)fd;

/// 接受连接，返回 client fd（< 0 表示失败）
- (int)acceptOnSocket:(int)fd;

#pragma mark - 工具方法

/// 从十六进制字符串解析网络 ID（解析失败返回 0）
+ (uint64_t)parseNetworkIDFromString:(NSString *)networkIDStr;

/// 将网络 ID 格式化为 16 位小写十六进制字符串
+ (NSString *)formatNetworkID:(uint64_t)networkID;

@end

NS_ASSUME_NONNULL_END
