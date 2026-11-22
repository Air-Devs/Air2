//
//  A2ControlInput.h
//  Air2
//
//  控件输入事件抽象 —— 对照 ZL2 的：
//    ui/control/event/Events.kt        （lwjglEvent / launcherEvent）
//    ui/control/event/KeyEventHandler.kt（按键引用计数，避免粘键）
//
//  ## 为什么要单独一层
//
//  Air2 原来每个控件视图直接调 `inputDelegate` 的 press/release：
//
//      [self.inputDelegate controlPressKey:e.key];
//
//  这有两个问题（在 ZL2 里都被专门处理过）：
//
//    1. **同一个键被两个控件同时按住**
//       比如默认布局里 W 既有摇杆方向键，也有独立的 W 按钮。
//       两个控件各自 press 一次、release 一次 —— 先松手的那次就会
//       把键提前释放，表现为「走着走着突然停住」。
//       ZL2 的 KeyEventHandler 用引用计数解决（#894 相关改动），这里照搬。
//
//    2. **鼠标键与键盘键混在一条通道**
//       ZL2 的 lwjglEvent 会看 isMouse 决定走
//       sendMouseButton 还是 sendKeyPress。
//       Air2 的 A2ControlInputDelegate 只有 controlPressKey:，
//       而 SurfaceViewController 的实现会把 code <= 0 直接丢弃 ——
//       于是 GLFW 的鼠标键 0/1/2 永远发不出去。
//
//  本层把这两种情况收敛掉：控件只要说「我按的是这个事件键」，
//  由 A2ControlInputDispatcher 判断它是键盘、鼠标还是滚轮，
//  并在宿主实现了扩展协议时走正确的通道；
//  宿主没实现时退回老的 controlPressKey:（保持行为不变，不会更糟）。
//
//  ## 与宿主的契约
//
//    A2ControlInputDelegate            必有（老协议，不动）
//    A2ControlAdvancedInput（本文件）  可选，宿主实现后鼠标/滚轮/绝对定位才可用
//
//  这样 SurfaceViewController 不改一行也能编译（要求 5）。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@protocol A2ControlInputDelegate;

#pragma mark - 事件键的分类

typedef NS_ENUM(NSInteger, A2ControlInputKind) {
    A2ControlInputKindKey = 0,     ///< 键盘按键
    A2ControlInputKindMouseButton, ///< 鼠标按键（0=左 1=右 2=中）
    A2ControlInputKindScroll,      ///< 滚轮（一次性）
    A2ControlInputKindLauncher,    ///< 启动器事件（切菜单/切输入法等）
    A2ControlInputKindUnknown,
};

#pragma mark - 扩展协议（全部 @optional）

/// 宿主（SurfaceViewController）实现这些方法后，鼠标键、滚轮、
/// 绝对坐标指针才能正确下发。不实现时本层退回 controlPressKey:。
@protocol A2ControlAdvancedInput <NSObject>
@optional
/// 鼠标按键：0=左 1=右 2=中（GLFW 语义）
- (void)controlPressMouseButton:(NSInteger)button;
- (void)controlReleaseMouseButton:(NSInteger)button;
/// 绝对坐标移动（ZL2 的 CLICK 鼠标模式语义）。坐标系与宿主自己的一致。
- (void)controlMoveMouseTo:(CGPoint)position;
/// 滚轮：dx/dy 以「格」为单位，向上为正
- (void)controlScrollByX:(CGFloat)dx y:(CGFloat)dy;
/// 陀螺仪开关（宿主可用来显示状态）
- (void)controlSetGyroscopeEnabled:(BOOL)enabled;
@end

#pragma mark - 事件键工具

/// 事件键的解析与规范化。
/// 支持三种写法（三家格式并存）：
///   "87" / "87.0"                    GLFW 键码数字（Air2/Air1 原生）
///   "GLFW_KEY_W" / "GLFW_MOUSE_BUTTON_LEFT"  ZL2 原生
///   "key.keyboard.space" / "key.mouse.left"  Minecraft 选项键名（FCL 互转时用到）
@interface A2ControlEventKey : NSObject

/// 分类。outCode 给出规范化后的 GLFW 键码（鼠标为 0~7，键盘为 32~348）。
+ (A2ControlInputKind)kindForRawKey:(nullable NSString *)raw
                            outCode:(nullable NSInteger *)outCode;

/// 规范化成「数字字符串」——控件运行时只认这个（老 API 兼容）。
/// 启动器事件原样返回事件名；无法识别的返回 nil。
+ (nullable NSString *)normalizedKey:(nullable NSString *)raw;

/// 鼠标键 → "0"/"1"/"2"
+ (nullable NSString *)keyForMouseButton:(NSInteger)button;

/// 是否是「点击即触发一次」的滚轮事件（ZL2 的 scroll_up.single）
+ (BOOL)isSingleScrollKey:(nullable NSString *)raw;
/// 滚轮方向：+1 上 / -1 下 / 0 不是滚轮
+ (NSInteger)scrollDirectionForRawKey:(nullable NSString *)raw;

/// GLFW 名称 ⇄ 数字键码（数字字符串进，数字字符串出）
+ (nullable NSString *)glfwNameForKeyCode:(NSInteger)code;
+ (nullable NSString *)keyCodeForGLFWName:(nullable NSString *)name;

@end

#pragma mark - 按键引用计数

/// 对照 ZL2 的 event/KeyEventHandler.kt。
/// 同一个键被多个控件按住时，只在「第一根手指按下」和「最后一根抬起」时
/// 真正下发 press / release。
@interface A2KeyStateKeeper : NSObject

/// 真正下发事件的宿主。weak —— 控件层不持有 VC。
@property (nonatomic, weak, nullable) id<A2ControlInputDelegate> delegate;

/// 是否还有任何键处于按下状态
@property (nonatomic, readonly) BOOL hasPressedKeys;
/// 当前按下的键（调试用）
@property (nonatomic, readonly) NSArray<NSString *> *pressedKeys;

/// 按下（计数 +1，只有 0→1 才下发）
- (void)pressKey:(nullable NSString *)key;
/// 抬起（计数 -1，只有 1→0 才下发）
- (void)releaseKey:(nullable NSString *)key;
/// 查询
- (BOOL)isPressed:(nullable NSString *)key;
/// 清空并逐个下发 release —— 视图离开屏幕时必须调用，否则粘键
- (void)releaseAll;

@end

#pragma mark - 分发器

/// 控件层的统一出口：分类 → 走键盘/鼠标/滚轮/启动器通道。
/// 每个渲染器持有一个实例，所有子视图共享（这样引用计数才有意义）。
@interface A2ControlInputDispatcher : NSObject

@property (nonatomic, weak, nullable) id<A2ControlInputDelegate> delegate;

/// 共享的按键引用计数表
@property (nonatomic, strong, readonly) A2KeyStateKeeper *keyState;

+ (instancetype)dispatcherWithDelegate:(nullable id<A2ControlInputDelegate>)delegate;

/// 按下/抬起一个「事件键」（键盘、鼠标键都可）
- (void)pressEventKey:(nullable NSString *)raw;
- (void)releaseEventKey:(nullable NSString *)raw;

/// 鼠标键
- (void)pressMouseButton:(NSInteger)button;
- (void)releaseMouseButton:(NSInteger)button;

/// 相对移动（老 API 的 delta 语义）
- (void)moveMouseBy:(CGPoint)delta;
/// 绝对移动（宿主实现了 controlMoveMouseTo: 时生效）
- (BOOL)moveMouseTo:(CGPoint)position;

/// 滚轮：以格为单位
- (void)scrollByX:(CGFloat)dx y:(CGFloat)dy;

/// 启动器事件（launcher.event.xxx）
- (void)launcherEvent:(nullable NSString *)name;

/// 全部释放（视图拆除时）
- (void)releaseAll;

@end

NS_ASSUME_NONNULL_END
