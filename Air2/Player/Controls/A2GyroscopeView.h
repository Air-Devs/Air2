//
//  A2GyroscopeView.h
//  Air2
//
//  陀螺仪控件（开关 + 采样）—— 对照 ZL2 的 ui/control/gyroscope/GyroscopeReader.kt。
//
//  ## ZL2 的参数（逐条对齐到 A2GyroscopeReader）
//
//    sampleRate        SENSOR_DELAY_GAME（≈50Hz）→ iOS 用 1/60s 的 CMMotionManager
//    smoothing         true → 环形缓冲求均值
//    smoothingWindow   4（采样点数）
//    threshold         0.02 rad/s，低于此值的抖动直接丢弃
//    sensitivity       1.0（倍数）
//
//  ## iOS 平台差异（重要，报告里也要写）
//
//    · Android 用 SensorManager 的 TYPE_GYROSCOPE；
//      iOS 用 CoreMotion 的 CMMotionManager.rotationRate。
//      两者的单位都是 rad/s，但**坐标轴朝向不同**（手机构造差异），
//      所以下面暴露了 invertX / invertY，默认值按「右手持机、屏幕朝自己」调过，
//      真机上如果方向反了，改这两个开关即可，不用动算法。
//    · Android 模拟器/无传感器设备有 isGyroscopeAvailable()；
//      iOS 对应 CMMotionManager.gyroAvailable。没有陀螺仪的设备上控件显示
//      「不可用」并且不启动采样。
//    · CoreMotion 的陀螺仪**不需要** Info.plist 权限声明
//      （NSMotionUsageDescription 是给「运动与健身」计步类接口的）。
//      但 Info.plist 不在本目录的改动范围内 —— 如果后续要接
//      CMMotionActivityManager 之类才需要加，这里不用。
//
//  ## 为什么不把采样放进视图里
//
//  采样与 UI 无关，编辑器预览/宿主也可能单独要（比如未来做「陀螺仪灵敏度」
//  滑块时能实时预览）。所以拆成 A2GyroscopeReader + A2GyroscopeView 两层。
//

#import <UIKit/UIKit.h>
#import "A2ControlRenderer.h"
#import "A2ControlInput.h"

NS_ASSUME_NONNULL_BEGIN

/// 陀螺仪采样器（CoreMotion）
@interface A2GyroscopeReader : NSObject

/// 设备是否有陀螺仪
+ (BOOL)isAvailable;

@property (nonatomic, assign) CGFloat sensitivity;         ///< 灵敏度倍数，默认 1
@property (nonatomic, assign) NSInteger smoothingWindow;   ///< 平滑窗口，默认 4
@property (nonatomic, assign) CGFloat threshold;           ///< 低通阈值 rad/s，默认 0.02
@property (nonatomic, assign) CGFloat pixelsPerRadian;     ///< 每弧度多少像素，默认 400

/// 轴方向修正（默认 dx 取 -z、dy 取 +x）
@property (nonatomic, assign) BOOL invertX;
@property (nonatomic, assign) BOOL invertY;

/// 每次采样的位移（主线程回调）
@property (nonatomic, copy, nullable) void (^onDelta)(CGPoint delta);

@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// 启动/停止（幂等）。没有陀螺仪时 start 返回 NO。
- (BOOL)start;
- (void)stop;

@end

#pragma mark - 控件视图

/// 陀螺仪开关控件：点一下开、再点一下关。
@interface A2GyroscopeView : A2ControlButtonView

@property (nonatomic, readonly, getter=isActive) BOOL active;

/// 采样器（可外部注入以共享，不注入时自建）
@property (nonatomic, strong, nullable) A2GyroscopeReader *reader;
/// 编辑模式（由 A2ControlRenderer 在布局编辑时置 YES）。
/// 编辑态下控件不派发游戏输入，只响应拖拽/缩放。
@property (nonatomic, assign) BOOL editing;


- (instancetype)initWithWidget:(A2ControlWidget *)widget;
- (void)applyTheme;

/// 外部开关（widget.gyroscopeEnabled 生效时用）
- (void)setActive:(BOOL)active;

@end

NS_ASSUME_NONNULL_END
