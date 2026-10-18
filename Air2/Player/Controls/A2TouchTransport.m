//
//  A2TouchTransport.m
//  Air2
//

#import "A2TouchTransport.h"
#import "A2Logger.h"
#import <sys/socket.h>

@implementation A2TouchTransport
@end

@interface A2TouchTransportManager ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *channels;
@property (nonatomic, assign) long long nextHandle;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation A2TouchTransportManager

+ (instancetype)shared {
    static A2TouchTransportManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2TouchTransportManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _channels = [NSMutableDictionary dictionary];
    _nextHandle = 1;
    _lock = [[NSLock alloc] init];
    return self;
}

#pragma mark - 初始化

+ (BOOL)initializeTouchController {
    static BOOL ready = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 用 socketpair 做通道 —— 它是进程内双向管道，
        // 语义与 Air1 的 transport 一致（有 handle、可收发、可销毁），
        // 但不需要那个 18MB 的闭源静态库。
        //
        // 为什么不是 NSStream/NSPipe：socketpair 是 BSD 原语，
        // 没有 +0.5s 的 runloop 调度延迟，触摸事件不能有延迟。
        ready = YES;
        [A2Logger info:@"TouchTransport" message:@"通道管理器就绪（socketpair 模式）"];
    });
    return ready;
}

+ (BOOL)isTouchControllerAvailable {
    return YES;
}

#pragma mark - 通道生命周期

+ (long long)createTransportWithName:(NSString *)name {
    if (![self initializeTouchController]) return 0;

    A2TouchTransportManager *m = self.shared;

    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
        [A2Logger error:@"TouchTransport"
                message:[NSString stringWithFormat:@"socketpair 失败：%s", strerror(errno)]];
        return 0;
    }

    [m.lock lock];
    long long handle = m.nextHandle++;

    A2TouchTransport *ch = [A2TouchTransport new];
    ch->_handle = handle;
    ch->_name = [name copy];
    ch->_active = YES;

    // 存两个 fd（写入端 + 读取端）
    m.channels[@(handle)] = @{
        @"channel": ch,
        @"readFd": @(fds[0]),
        @"writeFd": @(fds[1]),
    };
    [m.lock unlock];

    [A2Logger info:@"TouchTransport"
           message:[NSString stringWithFormat:@"创建通道 %@（handle=%lld）", name, handle]];
    return handle;
}

+ (void)destroyTransport:(long long)handle {
    if (handle <= 0) return;
    A2TouchTransportManager *m = self.shared;

    [m.lock lock];
    NSDictionary *info = m.channels[@(handle)];
    [m.channels removeObjectForKey:@(handle)];
    [m.lock unlock];

    if (info) {
        close([info[@"readFd"] intValue]);
        close([info[@"writeFd"] intValue]);
        [A2Logger info:@"TouchTransport"
               message:[NSString stringWithFormat:@"销毁通道 %lld", handle]];
    }
}

#pragma mark - 收发

+ (BOOL)sendToTransport:(long long)handle data:(NSData *)data {
    if (handle <= 0 || data.length == 0) return NO;

    A2TouchTransportManager *m = self.shared;
    [m.lock lock];
    NSDictionary *info = m.channels[@(handle)];
    [m.lock unlock];
    if (!info) return NO;

    int fd = [info[@"writeFd"] intValue];
    // 非阻塞写 —— 满就丢，不能阻塞 UI 线程
    ssize_t n = send(fd, data.bytes, data.length, MSG_DONTWAIT | MSG_NOSIGNAL);
    return n == (ssize_t)data.length;
}

+ (int)receiveFromTransport:(long long)handle buffer:(NSMutableData *)buffer {
    if (handle <= 0 || !buffer) return -1;

    A2TouchTransportManager *m = self.shared;
    [m.lock lock];
    NSDictionary *info = m.channels[@(handle)];
    [m.lock unlock];
    if (!info) return -1;

    int fd = [info[@"readFd"] intValue];

    uint8_t tmp[4096];
    ssize_t n = recv(fd, tmp, sizeof(tmp), MSG_DONTWAIT);
    if (n > 0) {
        [buffer appendBytes:tmp length:(NSUInteger)n];

        A2TouchTransportManager *manager = (A2TouchTransportManager *)self.shared;
        if (manager.onReceive) {
            manager.onReceive(handle, [NSData dataWithBytes:tmp length:(NSUInteger)n]);
        }
    }
    return (int)MAX(0, n);
}

@end
