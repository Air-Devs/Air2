//
//  A2SharedSession.h
//  Air2
//
//  共享的 NSURLSession —— 全 App 只有这一个。
//
//  ## 为什么必须共享
//
//  之前每个下载请求都 `[NSURLSession sessionWithConfiguration:...]` 新建一个
//  session，而 `HTTPMaximumConnectionsPerHost` 是【按 session】算的：
//
//    64 个并发下载 → 64 个 session → 每个允许 8 条连接
//                  → 理论上限 512 条连接
//
//  后果：
//    · 系统的连接池被打爆，出现大量超时/Socket 错误
//    · 每个 session 有自己的缓存与 Cookie 存储，内存翻倍
//    · 连接无法复用（每个 session 独立建连 → TLS 握手全重来）
//
//  共享一个 session 后：
//    · 连接池是全 App 统一的，8 条连接可以被 64 个请求轮流复用
//    · HTTP/2 多路复用真正生效（一个连接跑多个流）
//    · 系统能看到全局并发，不会因超限而静默排队
//
//  ## 并发上限怎么设
//
//  `HTTPMaximumConnectionsPerHost = 8` 是 iOS 的默认值，也是
//  HTTP/2 场景下的合理值 —— 因为 HTTP/2 的一条连接可以跑几十个流，
//  不需要很多条 TCP 连接。
//
//  真正的并发数由 `A2BatchDownloader` 的车道数控制（逻辑并发），
//  而不是 TCP 连接数。这两者要分开看：
//    · 逻辑并发 64 = 同时有 64 个文件在下载
//    · TCP 连接 8   = 这 64 个文件复用 8 条连接（HTTP/2 多路复用）
//
//  如果服务端是 HTTP/1.1（无多路复用），8 条连接确实会成为瓶颈 ——
//  那种情况提高到 16~24 更合适，但不能无限提高
//  （系统对单 host 的总连接数有硬限制）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2SharedSession : NSObject

/// 全 App 共享的下载 session
+ (NSURLSession *)shared;

/// 调整单 host 的最大连接数（HTTP/1.1 服务端可适当提高）
+ (void)setMaxConnectionsPerHost:(NSInteger)count;

/// 当前设置
+ (NSInteger)maxConnectionsPerHost;

@end

NS_ASSUME_NONNULL_END
