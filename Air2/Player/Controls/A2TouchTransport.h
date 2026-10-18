//
//  A2TouchTransport.h
//  Air2
//
//  触摸代理通信层 —— 替代 Air1 的 TouchControllerBridge。
//
//  ## 它是干什么的
//
//  TouchController 是一个独立进程（libproxy_server_ios.a），
//  负责在没有 JIT 的环境里把触摸事件转成 Minecraft 的输入。
//  SurfaceViewController 通过它把「按键事件」送出去：
//
//      [TouchControllerBridge sendToTransport:handle data:messageData];
//
//  ## 为什么用独立进程
//
//  Minecraft 的输入注入需要调用 LWJGL 的 JNI 接口，而触摸事件
//  在 UI 线程产生。跨进程能避免：
//    · UI 线程被 GL 调用阻塞
//    · 触摸事件的坐标系与游戏窗口不一致
//
//  ## 我们的实现
//
//  保留同样的 transport 语义（handle + 收发），但**不依赖
//  那套二进制**：用一个基于 socketpair 的轻量实现，
//  由玩家的输入层直接消费。
//
//  这样：
//    · SurfaceViewController 不需要改（接口一致）
//    · 控件系统（A2ControlRenderer）可以直接对接
//    · 不引入 18MB 的闭源静态库
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 触摸代理通道
@interface A2TouchTransport : NSObject
@property (nonatomic, readonly) long long handle;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) BOOL active;
@end

@interface A2TouchTransportManager : NSObject

+ (instancetype)shared;

/// 初始化（幂等）。返回 NO 表示当前环境不可用。
+ (BOOL)initializeTouchController;

/// 创建一条通道，返回 handle（0 表示失败）
+ (long long)createTransportWithName:(NSString *)name;

/// 从通道收数据。成功返回字节数，0 表示暂无数据，负数表示错误。
/// buffer 会被填充。
+ (int)receiveFromTransport:(long long)handle buffer:(NSMutableData *)buffer;

/// 向通道发数据
+ (BOOL)sendToTransport:(long long)handle data:(NSData *)data;

/// 销毁通道
+ (void)destroyTransport:(long long)handle;

/// 是否可用
+ (BOOL)isTouchControllerAvailable;

/// 订阅收到的数据（控件系统/输入层用这个拿事件）
@property (nonatomic, copy, nullable) void (^onReceive)(long long handle, NSData *data);

@end

NS_ASSUME_NONNULL_END
