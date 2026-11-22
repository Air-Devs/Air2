//
//  A2ViewAreaView.m
//  Air2
//
//  实现见 .h。数学部分对照 ZL2 的 mouse/TouchInput.kt：
//    · 位移 = 当前点 - 上一点（不是 - 起点），这样手指按住不动时不会持续转
//    · 灵敏度 = cursorSensitivity / 100（ZL2 的 100 = 1:1）
//    · 点击模式（click）只在「位移小于 touchSlop」时算点击
//

#import "A2ViewAreaView.h"
#import "A2ControlLayout.h"
#import "A2ControlInput.h"
#import "A2ThemeManager.h"
#import <math.h>

/// 点击判定的位移容差（pt）。对照 Android 的 ViewConfiguration.touchSlop（8dp）
static const CGFloat kA2ViewAreaTouchSlop = 8.0;

@interface A2ViewAreaView ()
@property (nonatomic, strong) CAShapeLayer *borderLayer;
@property (nonatomic, strong) UIView *centerDot;
@property (nonatomic, assign) CGPoint lastPoint;
@property (nonatomic, assign) BOOL touching;
@property (nonatomic, assign) BOOL moved;
@property (nonatomic, assign) CGFloat movedDistance;
@end

@implementation A2ViewAreaView

// editing 声明在 .h 里，但父类 A2ControlButtonView 没有对应 ivar，
// 编译器不合成 _editing（编译报 use of undeclared identifier '_editing'），
// 这里显式合成。
@synthesize editing = _editing;

- (instancetype)initWithWidget:(A2ControlWidget *)widget {
    self = [super initWithWidget:widget];
    if (!self) return nil;

    // 视角区必须是「透明但能接触摸」的
    self.backgroundColor = UIColor.clearColor;
    self.alpha = MAX(0.02, widget.opacity);
    self.titleLabel.hidden = YES;
    self.userInteractionEnabled = YES;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"视角区";

    // 用虚线框提示范围；viewShowsBorder = NO 时（游戏内常见）隐藏
    _borderLayer = [CAShapeLayer layer];
    _borderLayer.fillColor = UIColor.clearColor.CGColor;
    _borderLayer.lineDashPattern = @[@6, @4];
    _borderLayer.lineWidth = 1;
    [self.layer addSublayer:_borderLayer];

    // 中心一个淡淡的小点，让玩家知道这块区域在哪儿（编辑器里尤其有用）
    _centerDot = [[UIView alloc] initWithFrame:CGRectZero];
    _centerDot.userInteractionEnabled = NO;
    _centerDot.layer.cornerRadius = 2;
    [self addSubview:_centerDot];

    [self applyTheme];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.borderLayer.frame = self.bounds;
    self.borderLayer.path = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                      cornerRadius:12].CGPath;

    CGFloat dot = 4;
    self.centerDot.frame = CGRectMake((CGRectGetWidth(self.bounds) - dot) / 2,
                                      (CGRectGetHeight(self.bounds) - dot) / 2,
                                      dot, dot);
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    BOOL showBorder = self.widget.viewShowsBorder;
    self.borderLayer.hidden = !showBorder;
    self.borderLayer.strokeColor = [t.cOutline colorWithAlphaComponent:0.45].CGColor;
    self.centerDot.backgroundColor = [t.cOutline colorWithAlphaComponent:0.35];
}

- (void)setEditing:(BOOL)editing {
    _editing = editing;
    self.userInteractionEnabled = YES;
    if (editing) {
        [self resetTouchState];
    }
}

- (void)resetTouchState {
    self.touching = NO;
    self.moved = NO;
    self.movedDistance = 0;
    self.lastPoint = CGPointZero;
}

#pragma mark - 触摸

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // 编辑模式：交给 A2ControlRenderer 的 pan/pinch 处理
    if (self.editing) return;

    UITouch *t = touches.anyObject;
    if (!t) return;
    self.touching = YES;
    self.moved = NO;
    self.movedDistance = 0;
    self.lastPoint = [t locationInView:self];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing || !self.touching) return;

    UITouch *t = touches.anyObject;
    if (!t) return;
    CGPoint point = [t locationInView:self];
    CGFloat dx = point.x - self.lastPoint.x;
    CGFloat dy = point.y - self.lastPoint.y;
    self.lastPoint = point;

    self.movedDistance += sqrt(dx * dx + dy * dy);
    if (self.movedDistance > kA2ViewAreaTouchSlop) self.moved = YES;

    // ZL2 的 slide 模式：位移直接下发；灵敏度 100 = 1:1
    CGFloat sensitivity = self.widget.mouseSensitivity / 100.0;
    if (!isfinite(sensitivity) || sensitivity <= 0) sensitivity = 1.0;
    sensitivity *= self.widget.viewScale;
    if (!isfinite(sensitivity) || sensitivity <= 0) sensitivity = 1.0;

    if (self.widget.mouseMode && ![self.widget.mouseMode isEqualToString:@"slide"]) {
        // click 模式不跟随移动，只等抬起判定
        return;
    }
    [self.input moveMouseBy:CGPointMake(dx * sensitivity, dy * sensitivity)];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) return;

    // click 模式 / 原地轻点：算一次左键单击
    if (!self.moved) {
        BOOL clickMode = (self.widget.mouseMode.length > 0 &&
                          ![self.widget.mouseMode isEqualToString:@"slide"]);
        if (clickMode) {
            [self.input pressMouseButton:0];
            [self.input releaseMouseButton:0];
        }
    }
    [self resetTouchState];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self resetTouchState];
}

@end
