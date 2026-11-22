//
//  A2ScrollWheelView.m
//  Air2
//
//  实现见 .h。
//

#import "A2ScrollWheelView.h"
#import "A2ControlLayout.h"
#import "A2ControlInput.h"
#import "A2ThemeManager.h"
#import <math.h>
#import <stdlib.h>

/// 拖动累计到多少 pt 发一格（widget.scrollStep 是默认值，最小 4）
static const CGFloat kA2ScrollMinStep = 4.0;
/// 点击判定的位移容差
static const CGFloat kA2ScrollTouchSlop = 8.0;

@interface A2ScrollWheelView ()
@property (nonatomic, strong) UILabel *upLabel;
@property (nonatomic, strong) UILabel *downLabel;
@property (nonatomic, strong) UIView *thumb;

@property (nonatomic, assign) CGPoint lastPoint;
@property (nonatomic, assign) BOOL touching;
@property (nonatomic, assign) BOOL moved;
@property (nonatomic, assign) CGFloat movedDistance;
/// 未消费的滑动量（pt）。超过一格就发一次，余量留到下一次。
@property (nonatomic, assign) CGFloat accum;
@property (nonatomic, assign, readwrite) NSInteger lastDirection;
@end

@implementation A2ScrollWheelView

- (instancetype)initWithWidget:(A2ControlWidget *)widget {
    self = [super initWithWidget:widget];
    if (!self) return nil;

    self.titleLabel.hidden = YES;
    self.backgroundColor = UIColor.clearColor;
    self.alpha = MAX(0.05, widget.opacity);
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"滚轮";

    _upLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _upLabel.text = @"▲";
    _upLabel.textAlignment = NSTextAlignmentCenter;
    _upLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _upLabel.userInteractionEnabled = NO;
    [self addSubview:_upLabel];

    _downLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _downLabel.text = @"▼";
    _downLabel.textAlignment = NSTextAlignmentCenter;
    _downLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _downLabel.userInteractionEnabled = NO;
    [self addSubview:_downLabel];

    _thumb = [[UIView alloc] initWithFrame:CGRectZero];
    _thumb.userInteractionEnabled = NO;
    _thumb.layer.cornerRadius = 2;
    [self addSubview:_thumb];

    [NSLayoutConstraint activateConstraints:@[
        [_upLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:2],
        [_upLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_upLabel.heightAnchor constraintEqualToConstant:12],

        [_downLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-2],
        [_downLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_downLabel.heightAnchor constraintEqualToConstant:12],
    ]];

    [self applyTheme];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = MAX(4, CGRectGetWidth(self.bounds) * 0.34);
    self.thumb.frame = CGRectMake((CGRectGetWidth(self.bounds) - w) / 2,
                                  CGRectGetHeight(self.bounds) / 2 - 8,
                                  w, 16);
    self.layer.cornerRadius = MIN(CGRectGetWidth(self.bounds),
                                  CGRectGetHeight(self.bounds)) * 0.35;
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    self.backgroundColor = [t.cSurface colorWithAlphaComponent:0.45];
    self.layer.borderWidth = 1;
    self.layer.borderColor = [t.cOutline colorWithAlphaComponent:0.5].CGColor;
    self.layer.cornerRadius = MIN(CGRectGetWidth(self.bounds),
                                  CGRectGetHeight(self.bounds)) * 0.35;
    self.upLabel.textColor = t.cOnSurface;
    self.downLabel.textColor = t.cOnSurface;
    self.thumb.backgroundColor = [t.cOnSurface colorWithAlphaComponent:0.45];
}

- (void)setEditing:(BOOL)editing {
    _editing = editing;
    self.userInteractionEnabled = YES;
    if (editing) [self resetTouchState];
}

- (void)resetTouchState {
    self.touching = NO;
    self.moved = NO;
    self.movedDistance = 0;
    self.accum = 0;
    self.lastPoint = CGPointZero;
    self.lastDirection = 0;
    [self updateHighlight:0];
}

#pragma mark - 派发

- (CGFloat)stepLength {
    CGFloat step = self.widget.scrollStep;
    if (!isfinite(step) || step < kA2ScrollMinStep) step = 18;
    return step;
}

/// 发一格。direction：+1 上 / -1 下（已考虑反转）
- (void)emitTick:(NSInteger)direction {
    if (direction == 0) return;
    // 注意坐标约定：dispatcher 的 dy 向上为正（GLFW 滚轮语义）
    CGFloat dy = direction > 0 ? 1.0 : -1.0;
    CGFloat dx = 0;
    if (self.widget.scrollHorizontal) {
        // 横向滚轮在 iOS 上没有直接手势来源，先保留扩展位；
        // 竖向拖动时同时发一个水平分量会让 MC 的横向槽位移，
        // 所以默认关闭，只有显式开启才跟随手指的横向分量。
        dx = 0;
    }
    [self.input scrollByX:dx y:dy];
    self.lastDirection = direction;
    [self updateHighlight:direction];
}

- (void)updateHighlight:(NSInteger)direction {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    UIColor *normal = t.cOnSurface;
    UIColor *active = t.cPrimary;
    self.upLabel.textColor = direction > 0 ? active : normal;
    self.downLabel.textColor = direction < 0 ? active : normal;
}

#pragma mark - 触摸

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) return;
    UITouch *t = touches.anyObject;
    if (!t) return;

    self.touching = YES;
    self.moved = NO;
    self.movedDistance = 0;
    self.accum = 0;
    self.lastPoint = [t locationInView:self];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing || !self.touching) return;
    UITouch *t = touches.anyObject;
    if (!t) return;

    CGPoint point = [t locationInView:self];
    CGFloat dy = point.y - self.lastPoint.y;
    self.lastPoint = point;

    self.movedDistance += fabs(dy);
    if (self.movedDistance > kA2ScrollTouchSlop) self.moved = YES;

    // 「手指往上滑 = 往上滚」与系统滚动手感一致；
    // scrollInverted 打开时反过来（对应系统「自然滚动」）。
    CGFloat delta = -dy;              // 手指上滑 dy<0 → delta>0 → 滚轮上
    if (self.widget.scrollInverted) delta = -delta;
    self.accum += delta;

    CGFloat step = [self stepLength];
    NSInteger ticks = (NSInteger)(self.accum / step);
    if (ticks == 0) return;
    // 一次最多发 3 格，避免快速甩手时刷爆事件队列
    ticks = MAX(-3, MIN(3, ticks));
    NSInteger direction = ticks > 0 ? 1 : -1;
    for (NSInteger i = 0; i < labs(ticks); i++) {
        [self emitTick:direction];
    }
    self.accum -= ticks * step;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) return;

    // 原地点击：上半区滚上、下半区滚下（对照 ZL2 的 *_SINGLE 事件）
    if (!self.moved) {
        UITouch *t = touches.anyObject;
        CGPoint point = t ? [t locationInView:self] : CGPointZero;
        BOOL upper = point.y < CGRectGetHeight(self.bounds) / 2;
        [self emitTick:upper ? 1 : -1];
    }
    [self resetTouchState];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self resetTouchState];
}

@end
