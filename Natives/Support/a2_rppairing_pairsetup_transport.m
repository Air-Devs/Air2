//
//  a2_rppairing_pairsetup_transport.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  [A2-RXPC] 传输实现：Network.framework 字节通道（建连 / 被接受）+ RemoteXPC 之上的 pair-setup 传输缝。
//

#import "a2_rppairing_pairsetup_transport.h"
#import "a2_remotexpc_framing.h"
#import "a2_log.h"

#import <Network/Network.h>

// ★协议一致性（条件）★：pair-setup 单提供缝定义（a2_rppairing_pairsetup.h）时，
// 本类额外声明遵守该协议。★不存在时本文件照样编译★（方法同签名，见下）。
#if __has_include("a2_rppairing_pairsetup.h")
#import "a2_rppairing_pairsetup.h"
@interface A2RPPairSetupRemoteXPCTransport () <A2RPPairSetupMessageTransport>
@end
#endif

#pragma mark - §2a 可用性（如实）

BOOL A2RPPairSetupUSBPathAvailable(NSString **reason) {
    // §2a 的链路是「宿主电脑」的角色：USB → usbmuxd → lockdownd → CoreDeviceProxy（公开规格 §2a）。
    // 在 iOS App 沙盒里：
    //   ① 无法充当 USB 主机 —— 没有 USB 主机控制器权限，也拿不到 usbmuxd 的 socket；
    //   ② 拿不到 lockdownd 的进程通道（那是 host 侧 daemon 的接口）；
    //   ③ 本仓目标是【设备内自配对】（回环：本机既是设备又是可配对宿主），USB 前提根本不存在。
    // ⇒ 如实回 NO，不假装支持、也不提供半成品实现。
    if (reason) {
        *reason = @"§2a 需宿主电脑角色（USB→usbmuxd→lockdownd→CoreDeviceProxy）："
                  @"iOS App 无 USB 主机权限、拿不到 usbmuxd/lockdownd 通道；"
                  @"且本仓目标是设备内回环自配对，USB 前提不存在 ⇒ 本仓如实不支持 §2a";
    }
    return NO;
}

#pragma mark - NWConnection 之上的同步字节通道

@interface A2RPNetworkByteStream ()
@property (nonatomic) nw_connection_t connection;
@property (nonatomic, strong, nullable) id endpoint;      // nw_endpoint_t（保活）
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) BOOL opened;
@property (nonatomic) BOOL closed;
@property (nonatomic, copy, nullable) NSString *peerDescription;
@end

@implementation A2RPNetworkByteStream

+ (instancetype)streamToEndpoint:(id)endpoint reason:(NSString **)reason {
    if (endpoint == nil) {
        if (reason) {
            *reason = @"端点为 nil";
        }
        return nil;
    }
    A2RPNetworkByteStream *s = [[A2RPNetworkByteStream alloc] init];
    s.endpoint = endpoint;
    s.queue = dispatch_queue_create("a2.rxpc.stream", DISPATCH_QUEUE_SERIAL);
    return s;
}

+ (instancetype)streamOverAcceptedConnection:(id)connection {
    A2RPNetworkByteStream *s = [[A2RPNetworkByteStream alloc] init];
    s.connection = (nw_connection_t)connection;
    s.queue = dispatch_queue_create("a2.rxpc.stream.accepted", DISPATCH_QUEUE_SERIAL);
    s.opened = YES;
    s.peerDescription = @"已被接受的连接（pairable-host 被系统连入）";
    return s;
}

- (BOOL)openStreamWithTimeout:(NSTimeInterval)timeout reason:(NSString **)reason error:(A2RemoteXPCErrorKind *)error {
    if (self.closed) {
        if (reason) {
            *reason = @"流已关闭";
        }
        if (error) { *error = A2RemoteXPCErrorCancelled; }
        return NO;
    }
    if (self.opened) {
        return YES;                             // 已被接受的连接：已就绪
    }
    if (self.connection == NULL) {
        if (self.endpoint == nil) {
            if (reason) {
                *reason = @"既没有端点也没有已接受的连接";
            }
            if (error) { *error = A2RemoteXPCErrorNotConnected; }
            return NO;
        }
        nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                                 NW_PARAMETERS_DEFAULT_CONFIGURATION);
        self.connection = nw_connection_create((nw_endpoint_t)self.endpoint, params);
        if (self.connection == NULL) {
            if (reason) {
                *reason = @"nw_connection_create 失败";
            }
            if (error) { *error = A2RemoteXPCErrorConnectFailed; }
            return NO;
        }
    }

    nw_connection_set_queue(self.connection, self.queue);
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block BOOL isReady = NO;
    __block BOOL isDead = NO;
    __block NSString *why = nil;
    nw_connection_set_state_changed_handler(self.connection, ^(nw_connection_state_t state, nw_error_t nwErr) {
        if (state == nw_connection_state_ready) {
            isReady = YES;
            dispatch_semaphore_signal(ready);
        } else if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
            isDead = YES;
            why = [NSString stringWithFormat:@"连接未就绪（state=%d, err=%d）",
                   (int)state, nwErr ? (int)nw_error_get_error_code(nwErr) : 0];
            dispatch_semaphore_signal(ready);
        }
    });
    nw_connection_start(self.connection);

    dispatch_time_t dl = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    dispatch_semaphore_wait(ready, dl);
    if (!isReady) {
        nw_connection_cancel(self.connection);
        self.connection = NULL;
        if (reason) {
            *reason = why ?: [NSString stringWithFormat:@"建连超时（%.1fs）", timeout];
        }
        if (error) {
            *error = isDead ? A2RemoteXPCErrorConnectFailed : A2RemoteXPCErrorConnectTimeout;
        }
        return NO;
    }
    self.opened = YES;
    nw_endpoint_t ep = (nw_endpoint_t)self.endpoint;
    const char *host = ep ? nw_endpoint_get_hostname(ep) : NULL;
    uint16_t port = ep ? nw_endpoint_get_port(ep) : 0;
    self.peerDescription = [NSString stringWithFormat:@"%s:%u", host ?: "?", (unsigned)port];
    return YES;
}

- (BOOL)writeBytes:(NSData *)bytes timeout:(NSTimeInterval)timeout reason:(NSString **)reason error:(A2RemoteXPCErrorKind *)error {
    if (!self.opened || self.connection == NULL) {
        if (reason) {
            *reason = @"流未就绪";
        }
        if (error) { *error = A2RemoteXPCErrorNotConnected; }
        return NO;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block nw_error_t sendErr = NULL;
    dispatch_data_t d = dispatch_data_create(bytes.bytes, bytes.length, self.queue,
                                             DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(self.connection, d, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
                       ^(nw_error_t e) {
        sendErr = e;
        dispatch_semaphore_signal(done);
    });
    dispatch_time_t dl = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    dispatch_semaphore_wait(done, dl);
    if (sendErr != NULL) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"写失败（err=%d）",
                       (int)nw_error_get_error_code(sendErr)];
        }
        if (error) { *error = A2RemoteXPCErrorSendFailed; }
        return NO;
    }
    return YES;
}

- (NSData *)readBytesWithTimeout:(NSTimeInterval)timeout reason:(NSString **)reason error:(A2RemoteXPCErrorKind *)error {
    if (!self.opened || self.connection == NULL) {
        if (reason) {
            *reason = @"流未就绪";
        }
        if (error) { *error = A2RemoteXPCErrorNotConnected; }
        return nil;
    }
    dispatch_semaphore_t got = dispatch_semaphore_create(0);
    __block NSData *chunk = nil;
    __block BOOL peerGone = NO;
    nw_connection_receive(self.connection, 1, 65536,
                          ^(dispatch_data_t content, nw_content_context_t ctx,
                            bool isComplete, nw_error_t e) {
        (void)ctx;
        (void)isComplete;
        if (e != NULL) {
            peerGone = YES;
        } else if (content != NULL) {
            // ★不依赖 dispatch_data ↔ NSData 桥接★：逐 region 拷出。
            NSMutableData *acc = [NSMutableData data];
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset,
                                               const void *buf, size_t size) {
                (void)region;
                (void)offset;
                [acc appendBytes:buf length:size];
                return true;
            });
            chunk = acc;
        }
        dispatch_semaphore_signal(got);
    });
    dispatch_time_t dl = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    dispatch_semaphore_wait(got, dl);
    if (chunk == nil) {
        if (peerGone) {
            if (reason) {
                *reason = @"对端关闭了连接";
            }
            if (error) { *error = A2RemoteXPCErrorPeerClosed; }
        } else {
            if (reason) {
                *reason = [NSString stringWithFormat:@"读超时（%.1fs）", timeout];
            }
            if (error) { *error = A2RemoteXPCErrorReceiveTimeout; }
        }
        return nil;
    }
    return chunk;
}

- (void)closeStream {
    if (self.closed) {
        return;
    }
    self.closed = YES;
    if (self.connection != NULL) {
        nw_connection_cancel(self.connection);
    }
}

@end

#pragma mark - 缝：RemoteXPC 之上的 pair-setup 传输

@interface A2RPPairSetupRemoteXPCTransport ()
@property (nonatomic, strong) A2RemoteXPCSession *session;
@property (nonatomic, copy) NSString *hostName;
@end

@implementation A2RPPairSetupRemoteXPCTransport

+ (instancetype)transportOverByteStream:(id<A2RPByteStream>)stream
                               hostName:(NSString *)hostName
                            wireVersion:(NSUInteger)wireVersion
                                timeout:(NSTimeInterval)timeout
                                 reason:(NSString **)reason
                                  error:(A2RemoteXPCErrorKind *)errorOut {
    if (stream == nil) {
        if (reason) {
            *reason = @"字节通道为 nil";
        }
        if (errorOut) { *errorOut = A2RemoteXPCErrorNotConnected; }
        return nil;
    }
    A2RemoteXPCSession *session =
        [[A2RemoteXPCSession alloc] initWithStream:stream
                               wireProtocolVersion:wireVersion
                                      originatedBy:@"host"];   // 本侧当 rppairing 的 host/控制器
    NSString *why = nil;
    A2RemoteXPCErrorKind err = A2RemoteXPCErrorNone;
    if (![session connectAndHandshakeWithTimeout:timeout reason:&why error:&err]) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"RemoteXPC 建连/握手失败（class=%@）：%@",
                       A2RemoteXPCErrorKindName(err), why ?: @"原因未记录"];
        }
        if (errorOut) { *errorOut = err; }
        return nil;
    }
    A2RPPairSetupRemoteXPCTransport *t = [[A2RPPairSetupRemoteXPCTransport alloc] init];
    t.session = session;
    t.hostName = [hostName copy] ?: @"air2-rppairing";
    A2RXPCLog([NSString stringWithFormat:@"传输就绪 路径=RemoteXPC(§2a/§2b) 角色=host 主机名=%@ wire=%lu",
               t.hostName, (unsigned long)wireVersion]);
    return t;
}

- (BOOL)awaitingUserConsentObserved {
    return self.session.observedAwaitingUserConsent;
}

- (BOOL)transportObservedAwaitingUserConsent {
    return self.session.observedAwaitingUserConsent;
}

- (NSData *)exchangePairingData:(NSData *)tlv
                           kind:(NSString *)kind
                       startNew:(BOOL)startNewSession
                         reason:(NSString **)reason {
    if (self.session == nil) {
        if (reason) {
            *reason = @"传输未就绪（会话为 nil）";
        }
        return nil;
    }
    A2RemoteXPCErrorKind err = A2RemoteXPCErrorNone;
    NSString *why = nil;
    NSData *out = [self.session exchangePairingData:tlv
                                               kind:kind
                                           startNew:startNewSession
                                             reason:&why
                                              error:&err];
    if (out == nil && reason) {
        *reason = [NSString stringWithFormat:@"交换失败（class=%@）：%@",
                   A2RemoteXPCErrorKindName(err), why ?: @"原因未记录"];
    }
    return out;
}

- (void)close {
    [self.session close];
}

@end
