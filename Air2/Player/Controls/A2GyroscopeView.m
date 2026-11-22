//
//  A2GyroscopeView.m
//  Air2
//
//  对照 ZL2：ui/control/gyroscope/GyroscopeReader.kt
//    · 环形缓冲平滑（smoothingWindow）
//    · 阈值过滤（threshold）
//    · 灵敏度倍数（sensitivity）
//  实现换成 CoreMotion 的 CMMotionManager（见 .h 的平台差异说明）。
//

#import "A2GyroscopeView.h"
#import "A2ControlLayout.h"
#import "A2ThemeManager.h"
#import "A2Logger.h"
#import <CoreMotion/CoreMotion.h>

#pragma mark - Reader

@interface A2GyroscopeReader ()
@property (nonatomic, strong) CMMotionManager *motion;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *bufX;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *bufY;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *bufZ;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@end

@implementation A2GyroscopeReader

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _sensitivity = 1.0;
    _smoothingWindow = 4;
    _threshold = 0.02;
    _pixelsPerRadian = 400;
    _invertX = NO;
    _invertY = NO;
    _motion = [CMMotionManager new];
    _bufX = [NSMutableArray array];
    _bufY = [NSMutableArray array];
    _bufZ = [NSMutableArray array];
    return self;
}

+ (BOOL)isAvailable {
    CMMotionManager *m = [CMMotionManager new];
    return m.gyroAvailable;
}

/// 环形缓冲求均值（对照 ZL2 的 xTotal/yTotal/zTotal 累减法）
- (void)pushInto:(NSMutableArray<NSNumber *> *)buf value:(double)v {
    NSInteger window = MAX(1, self.smoothingWindow);
    [buf addObject:@(v)];
    while ((NSInteger)buf.count > window) {
        [buf removeObjectAtIndex:0];
    }
}

- (double)averageOf:(NSMutableArray<NSNumber *> *)buf {
    if (buf.count == 0) return 0;
    double sum = 0;
    for (NSNumber *n in buf) sum += n.doubleValue;
    return sum / (double)buf.count;
}

- (BOOL)start {
    if (self.running) return YES;
    if (!self.motion.gyroAvailable) {
        [A2Logger warning:@"A2Gyroscope"
                  message:@"本机没有陀螺仪，控件不启动采样"];
        return NO;
    }

    [self.bufX removeAllObjects];
    [self.bufY removeAllObjects];
    [self.bufZ removeAllObjects];

    self.motion.gyroUpdateInterval = 1.0 / 60.0;   // 与 SENSOR_DELAY_GAME 接近

    __weak typeof(self) weakSelf = self;
    // 用主队列：控件层与宿主都在主线程，省掉一次跨线程跳转，
    // 也避免在回调里做 UI/桥接调用时的线程问题。
    [self.motion startGyroUpdatesToQueue:NSOperationQueue.mainQueue
                            withHandler:^(CMGyroData *gyroData, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error || !gyroData) {
            if (error) {
                [A2Logger error:@"A2Gyroscope"
                        message:[NSString stringWithFormat:@"采样失败：%@", error.localizedDescription]];
            }
            return;
        }

        double x = gyroData.rotationRate.x;
        double y = gyroData.rotationRate.y;
        double z = gyroData.rotationRate.z;

        // ---- 平滑（ZL2 的 smoothing = true 默认走这条路）----
        if (self.smoothingWindow > 1) {
            [self pushInto:self.bufX value:x];
            [self pushInto:self.bufY value:y];
            [self pushInto:self.bufZ value:z];
            x = [self averageOf:self.bufX];
            y = [self averageOf:self.bufY];
            z = [self averageOf:self.bufZ];
        }

        // ---- 阈值过滤（避免微小抖动）----
        double sx = fabs(x) > self.threshold ? x : 0;
        double sy = fabs(y) > self.threshold ? y : 0;
        double sz = fabs(z) > self.threshold ? z : 0;

        // 轴映射：绕 z 轴旋转 = 左右转头 → 水平位移；
        //         绕 x 轴旋转 = 上下点头 → 垂直位移。
        // y（roll）用于倾斜但 MC 的视角没有 roll，忽略。
        const double dt = 1.0 / 60.0;
        double dx = -sz * dt * self.pixelsPerRadian * self.sensitivity;
        double dy =  sy * dt * self.pixelsPerRadian * self.sensitivity;
        if (self.invertX) dx = -dx;
        if (self.invertY) dy = -dy;

        if (fabs(dx) < 0.01 && fabs(dy) < 0.01) return;
        if (self.onDelta) self.onDelta(CGPointMake(dx, dy));
    }];

    self.running = YES;
    return YES;
}

- (void)stop {
    if (!self.running) return;
    [self.motion stopGyroUpdates];
    self.running = NO;
    [self.bufX removeAllObjects];
    [self.bufY removeAllObjects];
    [self.bufZ removeAllObjects];
}

- (void)dealloc {
    [_motion stopGyroUpdates];
}

@end

#pragma mark - View

@interface A2GyroscopeView ()
@property (nonatomic, assign, readwrite, getter=isActive) BOOL active;
@end

@implementation A2GyroscopeView

- (instancetype)initWithWidget:(A2ControlWidget *)widget {
    self = [super initWithWidget:widget];
    if (!self) return nil;

    _active = NO;
    self.titleLabel.text = [self labelForState];
    self.accessibilityLabel = @"陀螺仪开关";

    // 采样器参数直接从 widget 带过来（布局里能配）
    _reader = [A2GyroscopeReader new];
    _reader.sensitivity = widget.gyroscopeSensitivity > 0 ? widget.gyroscopeSensitivity : 1.0;
    _reader.smoothingWindow = widget.gyroscopeSmoothingWindow > 0 ? widget.gyroscopeSmoothingWindow : 4;
    _reader.threshold = widget.gyroscopeThreshold > 0 ? widget.gyroscopeThreshold : 0.02;
    __weak typeof(self) weakSelf = self;
    _reader.onDelta = ^(CGPoint delta) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.active) return;
        [self.input moveMouseBy:delta];
    };

    if (widget.gyroscopeEnabled) {
        // 延到上屏后再启动，避免 init 里就吃电
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self) [self setActive:YES];
        });
    }

    [self applyTheme];
    return self;
}

- (NSString *)labelForState {
    if (![A2GyroscopeReader isAvailable]) return @"陀螺仪(无)";
    return self.active ? @"陀螺仪 开" : @"陀螺仪";
}

- (void)setActive:(BOOL)active {
    if (active && ![A2GyroscopeReader isAvailable]) {
        _active = NO;
    } else {
        _active = active;
    }

    if (_active) {
        BOOL ok = [self.reader start];
        if (!ok) _active = NO;
    } else {
        [self.reader stop];
    }

    self.on = _active;
    self.titleLabel.text = [self labelForState];
    [self applyTheme];

    // 宿主可能想显示状态（实现为可选，没实现就忽略）
    id<A2ControlInputDelegate> d = self.inputDelegate;
    if ([d respondsToSelector:@selector(controlSetGyroscopeEnabled:)]) {
        [(id<A2ControlAdvancedInput>)d controlSetGyroscopeEnabled:_active];
    }
}

#pragma mark - 触摸（开关式）

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) {
        [super touchesBegan:touches withEvent:event];
        return;
    }
    [self setActive:!self.active];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) {
        [super touchesEnded:touches withEvent:event];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) [super touchesCancelled:touches withEvent:event];
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
    // 离开屏幕必须停采样：不然陀螺仪会在后台一直跑
    if (!newWindow) [self setActive:NO];
}

- (void)dealloc {
    [_reader stop];
}

#pragma mark - 主题

- (void)applyTheme {
    [super applyTheme];

    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    if (![A2GyroscopeReader isAvailable]) {
        self.alpha = 0.45;
        self.layer.borderColor = [t.cOutline colorWithAlphaComponent:0.3].CGColor;
        self.titleLabel.textColor = [t.cOnSurface colorWithAlphaComponent:0.6];
        return;
    }

    self.alpha = self.active ? 1.0 : 0.8;
    self.layer.borderColor = (self.active ? t.cPrimary : t.cOutline).CGColor;
    self.layer.borderWidth = self.active ? 2 : 1;
    self.backgroundColor = self.active
        ? [t.cPrimary colorWithAlphaComponent:0.28]
        : [t.cSurface colorWithAlphaComponent:0.35];
    self.titleLabel.textColor = t.cOnSurface;
}

@end
