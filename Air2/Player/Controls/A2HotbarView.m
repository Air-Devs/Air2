//
//  A2HotbarView.m
//  Air2
//
//  对照 ZL2：ui/control/Hotbar.kt
//    · 默认九格键：LwjglGlfwKeycode.GLFW_KEY_1..9（49~57）
//    · 双击 → SWAP_OFFHAND（默认 F / 70）
//    · 长按 → DROP（默认 Q / 81）
//    · 按下即 onClick(slotIndex)，滑动跨格实时切
//

#import "A2HotbarView.h"
#import "A2ControlLayout.h"
#import "A2ThemeManager.h"

@interface A2HotbarView ()
@property (nonatomic, strong) NSMutableArray<UIView *> *slotViews;
@property (nonatomic, strong) NSMutableArray<UILabel *> *slotLabels;

@property (nonatomic, assign, readwrite) NSInteger selectedSlot;

/// 当前这根手指的状态
@property (nonatomic, assign) BOOL touching;
@property (nonatomic, assign) CGPoint touchStart;
@property (nonatomic, assign) NSInteger touchSlot;
@property (nonatomic, assign) BOOL longPressFired;
@property (nonatomic, strong, nullable) NSTimer *longPressTimer;

/// 双击判定（对照 ZL2 的 lastSlot / doubleTapTimeout）
@property (nonatomic, assign) NSInteger lastTapSlot;
@property (nonatomic, assign) CFTimeInterval lastTapTime;
@end

@implementation A2HotbarView

- (instancetype)initWithWidget:(A2ControlWidget *)widget {
    self = [super initWithWidget:widget];
    if (!self) return nil;

    _selectedSlot = -1;
    _lastTapSlot = -1;
    _slotViews = [NSMutableArray array];
    _slotLabels = [NSMutableArray array];

    // 父类给按钮加的文字在这类控件里没意义
    self.titleLabel.hidden = YES;
    self.accessibilityLabel = @"快捷栏";

    NSInteger count = [self slotCount];
    for (NSInteger i = 0; i < count; i++) {
        UIView *cell = [[UIView alloc] initWithFrame:CGRectZero];
        cell.userInteractionEnabled = NO;
        cell.layer.borderWidth = 1;
        [self addSubview:cell];
        [_slotViews addObject:cell];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.text = [NSString stringWithFormat:@"%ld", (long)(i + 1)];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightMedium];
        label.userInteractionEnabled = NO;
        [cell addSubview:label];
        [_slotLabels addObject:label];
    }

    [self applyTheme];
    return self;
}

- (NSInteger)slotCount {
    NSInteger n = self.widget.hotbarSlotCount;
    if (n < 1) n = 9;
    return MIN(9, n);
}

- (NSString *)keyForSlot:(NSInteger)slot {
    NSArray<NSString *> *keys = self.widget.hotbarKeys;
    if (slot >= 0 && slot < (NSInteger)keys.count) {
        NSString *k = keys[slot];
        if (k.length) return k;
    }
    // 默认数字键 1~9
    return [NSString stringWithFormat:@"%ld", (long)(49 + slot)];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    NSInteger count = MAX(1, [self slotCount]);
    CGFloat w = self.bounds.size.width / count;
    CGFloat h = self.bounds.size.height;
    CGFloat inset = 1.5;

    for (NSInteger i = 0; i < (NSInteger)self.slotViews.count; i++) {
        UIView *cell = self.slotViews[i];
        cell.frame = CGRectMake(i * w + inset, inset, w - inset * 2, h - inset * 2);
        cell.layer.cornerRadius = MIN(cell.bounds.size.width, cell.bounds.size.height) * 0.14;
        cell.layer.cornerCurve = kCACornerCurveContinuous;

        UILabel *label = self.slotLabels[i];
        label.frame = cell.bounds;
        label.font = [UIFont monospacedDigitSystemFontOfSize:MAX(8, h * 0.32)
                                                       weight:UIFontWeightMedium];
    }
    [self applyTheme];
}

#pragma mark - 格子判定

- (NSInteger)slotAtPoint:(CGPoint)p {
    NSInteger count = MAX(1, [self slotCount]);
    CGFloat w = self.bounds.size.width / count;
    if (w <= 0) return -1;

    NSInteger index = (NSInteger)floor(p.x / w);
    if (index < 0) index = 0;
    if (index > count - 1) index = count - 1;
    return index;
}

#pragma mark - 触摸

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) {
        [super touchesBegan:touches withEvent:event];
        return;
    }

    UITouch *t = touches.anyObject;
    if (!t) return;

    self.touching = YES;
    self.longPressFired = NO;
    self.touchStart = [t locationInView:self];
    NSInteger slot = [self slotAtPoint:self.touchStart];
    self.touchSlot = slot;

    // 按下即选中（ZL2：碰到就视为点击，避免后续逻辑临时切物品栏导致不同步）
    [self selectSlot:slot];

    // 长按计时：默认 0.5s（ZL2 的 hotbarLongClickDelay）
    [self.longPressTimer invalidate];
    self.longPressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                           target:self
                                                         selector:@selector(longPressTick:)
                                                         userInfo:nil
                                                          repeats:NO];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing || !self.touching) return;

    UITouch *t = touches.anyObject;
    if (!t) return;
    CGPoint p = [t locationInView:self];

    // 位移超过阈值 → 取消长按（对照 ZL2 的 isMovedBeyondSlop）
    if (hypot(p.x - self.touchStart.x, p.y - self.touchStart.y) > 10.0) {
        [self.longPressTimer invalidate];
        self.longPressTimer = nil;
    }

    NSInteger slot = [self slotAtPoint:p];
    if (slot != self.touchSlot) {
        self.touchSlot = slot;
        [self selectSlot:slot];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) {
        [super touchesEnded:touches withEvent:event];
        return;
    }

    [self.longPressTimer invalidate];
    self.longPressTimer = nil;
    self.touching = NO;

    if (self.longPressFired) {
        self.longPressFired = NO;
        self.lastTapSlot = -1;   // 长按后清除双击记忆
        return;
    }

    // ---- 双击 = 切换副手 ----
    CFTimeInterval now = CACurrentMediaTime();
    BOOL sameSlot = (self.lastTapSlot == self.touchSlot);
    BOOL inTime = (now - self.lastTapTime) < 0.35;
    if (sameSlot && inTime) {
        NSString *swap = self.widget.hotbarSwapKey.length ? self.widget.hotbarSwapKey : @"70";
        [self sendSingleKey:swap];
        self.lastTapSlot = -1;
    } else {
        self.lastTapSlot = self.touchSlot;
        self.lastTapTime = now;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) {
        [super touchesCancelled:touches withEvent:event];
        return;
    }
    [self.longPressTimer invalidate];
    self.longPressTimer = nil;
    self.touching = NO;
    self.longPressFired = NO;
}

#pragma mark - 动作

- (void)longPressTick:(NSTimer *)timer {
    if (!self.touching) return;
    self.longPressFired = YES;
    // 长按 = 丢弃（ZL2 的 DROP，默认 Q）
    NSString *drop = self.widget.hotbarDropKey.length ? self.widget.hotbarDropKey : @"81";
    [self sendSingleKey:drop];
    [self flashSlot:self.touchSlot];
}

- (void)selectSlot:(NSInteger)slot {
    if (slot < 0) return;
    self.selectedSlot = slot;
    [self applyTheme];
    [self flashSlot:slot];

    [self sendSingleKey:[self keyForSlot:slot]];
    if (self.onSlotSelected) self.onSlotSelected(slot);
}

/// 「点一下」的按键：按下立刻抬起。
/// 这里不走引用计数（hotbar 的语义是瞬时切换，不是按住），
/// 但仍用 dispatcher，保证鼠标类事件能被正确分类。
- (void)sendSingleKey:(NSString *)key {
    if (key.length == 0) return;
    [self.input pressEventKey:key];
    [self.input releaseEventKey:key];
}

- (void)flashSlot:(NSInteger)slot {
    if (slot < 0 || slot >= (NSInteger)self.slotViews.count) return;
    UIView *cell = self.slotViews[slot];
    [UIView animateWithDuration:0.12 animations:^{
        cell.transform = CGAffineTransformMakeScale(0.9, 0.9);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.12 animations:^{
            cell.transform = CGAffineTransformIdentity;
        }];
    }];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    self.backgroundColor = UIColor.clearColor;
    self.layer.borderWidth = 0;

    for (NSInteger i = 0; i < (NSInteger)self.slotViews.count; i++) {
        UIView *cell = self.slotViews[i];
        BOOL selected = (i == self.selectedSlot);
        cell.backgroundColor = selected
            ? [t.cPrimary colorWithAlphaComponent:0.35]
            : [t.cSurface colorWithAlphaComponent:0.28];
        cell.layer.borderColor = (selected ? t.cPrimary
                                           : [t.cOutline colorWithAlphaComponent:0.5]).CGColor;
        cell.layer.borderWidth = selected ? 2 : 1;
        self.slotLabels[i].textColor = selected ? t.cOnSurface : [t.cOnSurface colorWithAlphaComponent:0.7];
    }
}

@end
