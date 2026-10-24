//
//  A2JVMRunningViewController.h
//  Air2
//
//  JVM 运行中界面 —— 对照 ZL2 的 JVMScreen.kt（282 行）。
//
//  ## 它和「启动遮罩」不是一回事
//
//  ZL2 的启动是三段：
//
//    1. **GameLaunchFlow**（启动编排）—— Task 列表 + 进度 + 日志
//       这一段在启动器进程里，用户看到的是任务清单。
//
//    2. **JVMScreen** —— JVM 已经起来了、游戏窗口还没出来
//       或者游戏刚起来但还没渲染。这个阶段：
//         · 全屏黑/透明
//         · 有个虚拟鼠标指针可以点
//         · 底部三个按钮：切键盘 / 看日志 / 强制关闭
//         · **没有进度条、没有版本号** —— 因为是「等」而不是「做」
//
//    3. **GameScreen** —— 游戏真正跑起来了
//       控件层 + 悬浮球 + 菜单 + FPS 浮层
//
//  ## 为什么这个阶段要独立
//
//  JVM 启动后要加载几万个类、初始化 OpenGL、生成世界，
//  这期间可能有 10-30 秒没有画面。如果直接进 GameScreen，
//  控件层会盖在黑色画面上，用户分不清是卡住还是加载中。
//
//  JVMScreen 提供的是「我知道在加载，而且我能操作」的反馈。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol A2JVMRunningDelegate <NSObject>
@optional
/// 点了「键盘」—— 拉起软键盘
- (void)jvmScreenDidRequestKeyboard;
/// 点了「强制关闭」—— 直接杀进程
- (void)jvmScreenDidRequestForceClose;
@end

@interface A2JVMRunningViewController : UIViewController

@property (nonatomic, weak, nullable) id<A2JVMRunningDelegate> delegate;

/// 日志面板是否展开
@property (nonatomic, assign, readonly, getter=isLogVisible) BOOL logVisible;
- (void)toggleLog;

/// 追加一行日志（JVM stdout/stderr 转发过来）
- (void)appendLogLine:(NSString *)line;

/// 游戏首帧出现 —— 淡出本界面，交给 GameScreen
- (void)dismissWhenGameReady:(nullable void (^)(void))completion;

/// 虚拟鼠标指针（可点、可拖）
@property (nonatomic, assign) CGPoint pointerPosition;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
