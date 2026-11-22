//
//  A2ControlRenderer.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
//
//  A2ControlRenderer.m
//  Air2
//

#import "A2ControlRenderer.h"
#import "A2ControlStyle.h"
#import "A2ControlInput.h"
#import "A2JoystickView.h"
#import "A2HotbarView.h"
#import "A2GamepadView.h"
#import "A2GyroscopeView.h"
#import "A2ViewAreaView.h"
#import "A2ScrollWheelView.h"
#import "A2ThemeManager.h"
#import "A2Logger.h"
#import <math.h>

#pragma mark - 单个控件

// 类扩展必须在 @implementation 之前，且不能写在 @interface 内
@interface A2ControlButtonView ()
@property (nonatomic, strong, nullable) A2ControlStyle *style;
/// input 属性的存储（公开声明在 .h，为了给 hotbar/gamepad 等子类复用）
@property (nonatomic, strong, nullable) A2ControlInputDispatcher *inputStorage;
@end

@implementation A2ControlButtonView {
    UILabel *_label;
    BOOL _pressed;
    NSDictionary *_compatProperties;
}

- (instancetype)initWithWidget:(A2ControlWidget *)widget {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _widget = widget;

    self.isAccessibilityElement = YES;
    self.accessibilityLabel = widget.text;
    self.layer.cornerRadius = 8;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    // 触摸穿透：isPenetrable 的控件不拦截事件
    self.userInteractionEnabled = !widget.isPenetrable;

    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.textAlignment = NSTextAlignmentCenter;
    _label.userInteractionEnabled = NO;
    _label.adjustsFontSizeToFitWidth = YES;
    _label.minimumScaleFactor = 0.5;
    _label.text = widget.text;
    [self addSubview:_label];

    [NSLayoutConstraint activateConstraints:@[
        [_label.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_label.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:2],
        [_label.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-2],
    ]];

    [self buildCompatProperties];
    [self applyTheme];
    return self;
}

#pragma mark 输入出口

- (A2ControlInputDispatcher *)input {
    if (!self.inputStorage) {
        self.inputStorage = [A2ControlInputDispatcher dispatcherWithDelegate:self.inputDelegate];
    }
    return self.inputStorage;
}

- (void)setInput:(A2ControlInputDispatcher *)input {
    _inputStorage = input;
    input.delegate = self.inputDelegate;
}

- (void)setInputDelegate:(id<A2ControlInputDelegate>)inputDelegate {
    _inputDelegate = inputDelegate;
    // 渲染器注入的共享分发器要跟着换宿主
    self.inputStorage.delegate = inputDelegate;
}

/// 把 widget 转成 Air1 风格的属性字典。
/// SurfaceViewController 的 executebtn: 系列按 keycodes[i] 取键码。
- (void)buildCompatProperties {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];

    // keycodes：从 clickEvents 里取 SendKey 的键码
    NSMutableArray *codes = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        if (i < (NSInteger)self.widget.clickEvents.count) {
            A2ControlEvent *e = self.widget.clickEvents[i];
            [codes addObject:e.key.length ? @(e.key.integerValue) : @0];
        } else {
            [codes addObject:@0];
        }
    }
    d[@"keycodes"] = codes;
    d[@"isSwipeable"] = @(self.widget.isSwipple);
    d[@"isToggleable"] = @(self.widget.isToggleable);
    _compatProperties = [d copy];
}

- (NSDictionary *)properties {
    return _compatProperties ?: @{};
}

- (UILabel *)titleLabel {
    return _label;
}

- (BOOL)isToggleOn {
    return self.isOn;
}

- (void)setIsToggleOn:(BOOL)isToggleOn {
    self.on = isToggleOn;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _label.font = [UIFont systemFontOfSize:MAX(9, self.bounds.size.height * 0.34)
                                    weight:UIFontWeightMedium];
}

#pragma mark 触摸

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) {
        [super touchesBegan:touches withEvent:event];
        return;
    }

    _pressed = YES;
    [self updatePressedAppearance];

    // Toggleable：按下即切换，不需要等松开。
    // 语义对齐 Air1 的 executebtn_up:：开 → 发 DOWN，关 → 发 UP，
    // 而不是每次点都发 DOWN（那样第二次点会把键永远按住）。
    if (self.widget.isToggleable) {
        BOOL willBeOn = !self.isOn;
        self.on = willBeOn;
        if (willBeOn) {
            [self fireEvents];
        } else {
            [self releaseAllEvents];
        }
        return;
    }

    [self fireEvents];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) return;

    // 摇杆：拖动时发送鼠标位移
    if (self.widget.type == A2ControlWidgetTypeJoystick) {
        UITouch *t = touches.anyObject;
        CGPoint prev = [t previousLocationInView:self];
        CGPoint cur = [t locationInView:self];
        CGPoint delta = CGPointMake((cur.x - prev.x) * 2.0,
                                    (cur.y - prev.y) * 2.0);
        [self.inputDelegate controlMoveMouse:delta];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) return;
    _pressed = NO;
    [self updatePressedAppearance];

    // 非开关式的按钮，松开时要释放按键（键盘 + 鼠标键都走引用计数）
    if (!self.widget.isToggleable) {
        [self releaseAllEvents];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _pressed = NO;
    [self updatePressedAppearance];
}

/// 把控件的事件翻译成输入意图。
/// 键盘 / 鼠标键 / 滚轮 / 启动器事件都经 A2ControlInputDispatcher 分类下发 ——
/// 这样「GLFW_MOUSE_BUTTON_LEFT」不会被当成键盘键丢掉（老实现的问题）。
- (void)fireEvents {
    for (A2ControlEvent *e in self.widget.clickEvents) {
        // 事件类型对齐 ZL2 的 ClickEvent.Type（六种）+ Air2 扩展的两种：
        switch (e.type) {
            case A2ControlEventTypeKey:
            case A2ControlEventTypeMouseButton:
            case A2ControlEventTypeScroll:
                if (e.key.length) [self.input pressEventKey:e.key];
                break;

            case A2ControlEventTypeLauncherEvent:
                [self.input launcherEvent:e.key];
                [self handleLauncherEvent:e.key];
                break;

            case A2ControlEventTypeSendText:
                // 文本发送要拉起输入法，由上层接管
                [self.inputDelegate controlToggleKeyboard];
                break;

            case A2ControlEventTypeSwitchLayer:
            case A2ControlEventTypeShowLayer:
            case A2ControlEventTypeHideLayer:
                // 层操作需要遍历所有控件，交给渲染器
                // （这里通过通知让 A2ControlRenderer 处理）
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"A2ControlLayerOperationNotification"
                                  object:self
                                userInfo:@{@"type": @(e.type), @"layer": e.key ?: @""}];
                break;

            default:
                break;
        }
    }
}

/// 释放本控件发出过的全部事件键（键盘 + 鼠标键 + 滚轮）
- (void)releaseAllEvents {
    for (A2ControlEvent *e in self.widget.clickEvents) {
        switch (e.type) {
            case A2ControlEventTypeKey:
            case A2ControlEventTypeMouseButton:
                if (e.key.length) [self.input releaseEventKey:e.key];
                break;
            default:
                // 滚轮 / 启动器事件没有「按住」概念
                break;
        }
    }
}

/// 启动器事件（对照 ZL2 的 LauncherEvent 枚举）
- (void)handleLauncherEvent:(NSString *)name {
    if ([name isEqualToString:@"toggle_gui"] || [name isEqualToString:@"ToggleGui"]) {
        [self.inputDelegate controlToggleGui];
    } else if ([name isEqualToString:@"toggle_keyboard"] || [name isEqualToString:@"ToggleKeyboard"]) {
        [self.inputDelegate controlToggleKeyboard];
    } else if ([name hasPrefix:@"mouse"]) {
        // 鼠标相关事件由 SurfaceViewController 处理
    }
}

#pragma mark 外观

- (void)updatePressedAppearance {
    // animateSwap 为真时用过渡动画，否则瞬变（对照 ZL2 的 animateSwap）
    BOOL animate = self.style ? self.style.animateSwap : YES;
    NSTimeInterval dur = animate ? 0.12 : 0;

    [UIView animateWithDuration:dur animations:^{
        if (self.style) {
            [self applyTheme];   // 样式里含 pressed 态的颜色/圆角/字号
        } else {
            CGFloat base = self->_pressed ? 0.55 : (self.isOn ? 0.9 : 0.75);
            self.alpha = base * MAX(0.02, self.widget.opacity);
        }
        self.transform = self->_pressed
            ? CGAffineTransformMakeScale(0.94, 0.94)
            : CGAffineTransformIdentity;
    }];
}

- (void)applyTheme {
    // 有样式就按样式画（ZL2 的 ButtonStyle：亮暗两套 + 按下态）
    if (self.style) {
        BOOL dark = (UITraitCollection.currentTraitCollection.userInterfaceStyle
                     == UIUserInterfaceStyleDark);
        [self.style applyToView:self darkMode:dark pressed:_pressed];
        // 样式里的 alpha 是"外观"的一部分，单控件 opacity 是"玩家设置"，两者相乘
        self.alpha = MAX(0.02, self.alpha * self.widget.opacity);
        _label.textColor = [self.style contentColorForDarkMode:dark pressed:_pressed];
        _label.font = [UIFont systemFontOfSize:[self.style fontSizeForDarkMode:dark pressed:_pressed]
                                        weight:UIFontWeightMedium];
        return;
    }

    // 没样式 → 用主题色兜底
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    self.backgroundColor = [t.cSurface colorWithAlphaComponent:0.55];
    self.layer.borderWidth = 1;
    self.layer.borderColor = [t.cOutline colorWithAlphaComponent:0.5].CGColor;
    _label.textColor = t.cOnSurface;
    self.alpha = (self.isOn ? 0.9 : 0.75) * MAX(0.02, self.widget.opacity);
}

- (void)setOn:(BOOL)on {
    _on = on;
    [self updatePressedAppearance];
}

- (void)setEditing:(BOOL)editing {
    _editing = editing;
    // 编辑模式下永远可点（用于选中）；退出编辑后恢复"穿透"语义，
    // 否则 TextBox 之类 isPenetrable 的控件会挡住在游戏里的触摸。
    self.userInteractionEnabled = editing ? YES : !self.widget.isPenetrable;
    self.layer.borderColor = editing
        ? A2ThemeManager.shared.scheme.cPrimary.CGColor
        : [A2ThemeManager.shared.scheme.cOutline colorWithAlphaComponent:0.5].CGColor;
    self.layer.borderWidth = editing ? 2 : 1;
}

@end

#pragma mark - 选中框

/// 编辑模式下的选中框：虚线边框 + 四角手柄。
/// 单独一层视图，不参与命中测试（否则会挡住被选中控件自己的拖动）。
@interface A2ControlSelectionView : UIView
@property (nonatomic, strong) UIColor *accentColor;
@end

@implementation A2ControlSelectionView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.userInteractionEnabled = NO;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}

- (void)setAccentColor:(UIColor *)accentColor {
    _accentColor = accentColor;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    UIColor *accent = self.accentColor ?: UIColor.systemBlueColor;
    [accent setStroke];

    // 虚线边框
    UIBezierPath *border = [UIBezierPath bezierPathWithRect:CGRectInset(rect, 1, 1)];
    border.lineWidth = 1.5;
    CGFloat dashes[] = {6, 4};
    [border setLineDash:dashes count:2 phase:0];
    [border stroke];

    // 四角手柄（实心小方块）
    CGFloat h = 8;
    CGRect corners[] = {
        CGRectMake(0, 0, h, h),
        CGRectMake(CGRectGetWidth(rect) - h, 0, h, h),
        CGRectMake(0, CGRectGetHeight(rect) - h, h, h),
        CGRectMake(CGRectGetWidth(rect) - h, CGRectGetHeight(rect) - h, h, h),
    };
    [accent setFill];
    for (int i = 0; i < 4; i++) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:corners[i] cornerRadius:2];
        [p fill];
    }
}

@end

#pragma mark - 渲染器

@interface A2ControlRenderer () <UIGestureRecognizerDelegate>
@property (nonatomic, strong, readwrite) A2ControlLayout *layout;
@property (nonatomic, strong, readwrite) A2ControlInputDispatcher *input;
@property (nonatomic, strong) NSMutableArray<UIView *> *buttonViews;
@property (nonatomic, strong) A2ControlSelectionView *selectionView;

/// 编辑手势（只在 editing 时挂上）
@property (nonatomic, strong, nullable) UIPanGestureRecognizer *editPan;
@property (nonatomic, strong, nullable) UIPinchGestureRecognizer *editPinch;

@property (nonatomic, weak, nullable) A2ControlWidget *dragWidget;
@property (nonatomic, assign) CGPoint dragStartPoint;
@property (nonatomic, assign) CGFloat dragStartX;
@property (nonatomic, assign) CGFloat dragStartY;

@property (nonatomic, weak, nullable) A2ControlWidget *pinchWidget;
@property (nonatomic, assign) CGFloat pinchStartWidth;
@property (nonatomic, assign) CGFloat pinchStartHeight;

// 私有方法声明（同上：避免调用先于定义时的告警）
- (void)installEditingGesturesIfNeeded;
- (UIView *)widgetViewAtPoint:(CGPoint)point;
- (CGRect)frameForWidget:(A2ControlWidget *)w;
- (CGFloat)snappedValue:(CGFloat)value;
@end

@implementation A2ControlRenderer

- (instancetype)initWithLayout:(A2ControlLayout *)layout {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _layout = layout;
    _buttonViews = [NSMutableArray array];
    _input = [A2ControlInputDispatcher new];
    _controlsOpacity = 1.0;
    _snapStep = 0.5;
    self.backgroundColor = UIColor.clearColor;

    _selectionView = [[A2ControlSelectionView alloc] initWithFrame:CGRectZero];
    _selectionView.hidden = YES;
    _selectionView.accentColor = A2ThemeManager.shared.scheme.cPrimary;

    [self reload];
    return self;
}

- (void)reload {
    // 拆视图前先把按住的键全放开 —— 否则重载布局会留下粘键
    [self.input releaseAll];
    for (UIView *v in self.subviews) [v removeFromSuperview];
    [_buttonViews removeAllObjects];
    self.dragWidget = nil;
    self.pinchWidget = nil;

    for (A2ControlWidget *w in self.layout.allWidgets) {
        UIView *v = [self makeViewForWidget:w];
        if (!v) continue;
        // 层顺序 = 数组顺序：先 add 的在底层。
        // 布局文件里 viewGroup/layer 的顺序是「后写的在上层」，
        // 这里 allWidgets 已按 layers 顺序展开，所以直接 add 即正确。
        [self addSubview:v];
        [_buttonViews addObject:v];
    }

    // 选中框永远在最上层
    [self addSubview:self.selectionView];

    [self setNeedsLayout];
    [self applyTheme];
    [self refreshSelectionOverlay];
}

/// 按控件类型造视图。
/// 摇杆/快捷栏/手柄/陀螺仪/视角区/滚轮各有自己的触摸逻辑；
/// 其余（Button / TextBox）走 A2ControlButtonView。
- (UIView *)makeViewForWidget:(A2ControlWidget *)w {
    UIView *v = nil;

    switch (w.type) {
        case A2ControlWidgetTypeJoystick: {
            A2JoystickView *j = [[A2JoystickView alloc] initWithWidget:w];
            v = j;
            break;
        }

        case A2ControlWidgetTypeHotbar: {
            A2HotbarView *h = [[A2HotbarView alloc] initWithWidget:w];
            v = h;
            break;
        }

        case A2ControlWidgetTypeGamepad: {
            A2GamepadView *g = [[A2GamepadView alloc] initWithWidget:w];
            v = g;
            break;
        }

        case A2ControlWidgetTypeGyroscope: {
            A2GyroscopeView *g = [[A2GyroscopeView alloc] initWithWidget:w];
            v = g;
            break;
        }

        case A2ControlWidgetTypeView: {
            A2ViewAreaView *a = [[A2ViewAreaView alloc] initWithWidget:w];
            v = a;
            break;
        }

        case A2ControlWidgetTypeScroll: {
            A2ScrollWheelView *a = [[A2ScrollWheelView alloc] initWithWidget:w];
            v = a;
            break;
        }

        case A2ControlWidgetTypeButton:
        case A2ControlWidgetTypeTextBox:
        default: {
            A2ControlButtonView *b = [[A2ControlButtonView alloc] initWithWidget:w];
            // 样式：从 layout.buttonStyles 里按 buttonStyle 查
            if (w.buttonStyle.length) {
                NSDictionary *styleJSON = self.layout.buttonStyles[w.buttonStyle];
                if (styleJSON) b.style = [A2ControlStyle styleFromJSON:styleJSON];
            }
            v = b;
            break;
        }
    }

    // 统一设置输入出口 / 编辑态
    if ([v respondsToSelector:@selector(setInput:)]) {
        [(id)v setInput:self.input];
    }
    if ([v respondsToSelector:@selector(setInputDelegate:)]) {
        [(id)v setInputDelegate:self.inputDelegate];
    }
    if ([v respondsToSelector:@selector(setEditing:)]) {
        [(id)v setEditing:self.editing];
    }
    // 编辑态下禁用控件自己的手势（摇杆/快捷栏的 pan 等），
    // 否则它们会和渲染器的拖动/缩放抢触摸。
    if (self.editing) {
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            g.enabled = NO;
        }
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [v addGestureRecognizer:tap];
    }

    return v;
}

#pragma mark 控件 ⇄ 视图

- (A2ControlWidget *)widgetForView:(UIView *)view {
    if ([view isKindOfClass:A2ControlButtonView.class]) {
        return ((A2ControlButtonView *)view).widget;
    }
    if ([view isKindOfClass:A2JoystickView.class]) {
        return ((A2JoystickView *)view).widget;
    }
    return nil;
}

- (UIView *)viewForWidget:(A2ControlWidget *)widget {
    if (!widget) return nil;
    for (UIView *v in self.buttonViews) {
        if ([self widgetForView:v] == widget) return v;
    }
    return nil;
}

- (CGRect)frameForWidget:(A2ControlWidget *)w {
    CGSize s = self.bounds.size;
    CGFloat x = s.width  * w.xPercent / 100.0;
    CGFloat y = s.height * w.yPercent / 100.0;
    CGFloat width  = s.width  * w.widthPercent / 100.0;
    CGFloat height = s.height * w.heightPercent / 100.0;

    // 尺寸为 0 的控件给个默认值，避免完全看不见（与 normalize 的兜底一致）
    if (width <= 0)  width  = MAX(48, s.height * 0.11);
    if (height <= 0) height = width;
    return CGRectMake(x, y, width, height);
}

- (void)layoutSubviews {
    [super layoutSubviews];

    for (UIView *v in self.buttonViews) {
        A2ControlWidget *w = [self widgetForView:v];
        if (!w) continue;

        v.frame = [self frameForWidget:w];
        v.alpha = w.opacity;
        CGFloat radius = MIN(CGRectGetWidth(v.bounds), CGRectGetHeight(v.bounds)) * 0.18;
        // 圆角优先用 ZL2 的 ButtonShape（四角），没给才用默认比例
        if (w.cornerTopStart > 0 || w.cornerTopEnd > 0 ||
            w.cornerBottomEnd > 0 || w.cornerBottomStart > 0) {
            CGFloat maxR = MIN(CGRectGetWidth(v.bounds), CGRectGetHeight(v.bounds)) / 2.0;
            radius = MIN(maxR, MAX(w.cornerTopStart, MAX(w.cornerTopEnd,
                       MAX(w.cornerBottomEnd, w.cornerBottomStart))) * 0.5);
        }
        v.layer.cornerRadius = radius;
    }

    [self refreshSelectionOverlay];
}

- (void)refreshSelectionOverlay {
    if (!self.editing || !self.selectedWidget) {
        self.selectionView.hidden = YES;
        return;
    }
    UIView *v = [self viewForWidget:self.selectedWidget];
    if (!v) {
        self.selectionView.hidden = YES;
        return;
    }
    self.selectionView.hidden = NO;
    self.selectionView.frame = v.frame;
    self.selectionView.accentColor = A2ThemeManager.shared.scheme.cPrimary;
    [self bringSubviewToFront:self.selectionView];
}

- (void)setSelectedWidget:(A2ControlWidget *)selectedWidget {
    _selectedWidget = selectedWidget;
    [self refreshSelectionOverlay];
    if (self.onSelectionChanged) self.onSelectionChanged(selectedWidget);
}

- (void)handleTap:(UITapGestureRecognizer *)g {
    A2ControlWidget *w = [self widgetForView:g.view];
    if (!w) return;
    self.selectedWidget = w;
}

#pragma mark 编辑手势

- (void)setEditing:(BOOL)editing {
    if (_editing == editing) {
        // 即使状态相同也要保证手势在位（reload 后视图是新的）
        [self installEditingGesturesIfNeeded];
        return;
    }
    _editing = editing;

    if (editing) {
        [self installEditingGesturesIfNeeded];
    } else {
        self.dragWidget = nil;
        self.pinchWidget = nil;
        self.selectedWidget = nil;
        if (self.editPan) {
            [self removeGestureRecognizer:self.editPan];
            self.editPan = nil;
        }
        if (self.editPinch) {
            [self removeGestureRecognizer:self.editPinch];
            self.editPinch = nil;
        }
    }

    // 重建子视图：编辑态要禁用控件自身手势、加选中 tap
    [self reload];
}

- (void)installEditingGesturesIfNeeded {
    if (!self.editing) return;

    if (!self.editPan) {
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleEditPan:)];
        pan.maximumNumberOfTouches = 1;
        pan.delegate = self;
        [self addGestureRecognizer:pan];
        self.editPan = pan;
    }
    if (!self.editPinch) {
        UIPinchGestureRecognizer *pinch =
            [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handleEditPinch:)];
        pinch.delegate = self;
        [self addGestureRecognizer:pinch];
        self.editPinch = pinch;
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

/// 找到触摸点下最上层的控件视图。
/// 反序遍历 = 后加的在上面（与 UIKit 的 z 序一致）。
- (UIView *)widgetViewAtPoint:(CGPoint)point {
    for (UIView *v in [self.buttonViews reverseObjectEnumerator]) {
        if (v.hidden || v.alpha < 0.01) continue;
        if (CGRectContainsPoint(v.frame, point)) return v;
    }
    return nil;
}

- (CGFloat)snappedValue:(CGFloat)value {
    CGFloat step = self.snapStep;
    if (!isfinite(step) || step <= 0.01) return value;
    return round(value / step) * step;
}

- (void)handleEditPan:(UIPanGestureRecognizer *)g {
    if (!self.editing) return;

    CGPoint point = [g locationInView:self];

    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            // 双指缩放进行中不要抢
            if (self.pinchWidget) return;
            UIView *v = [self widgetViewAtPoint:point];
            A2ControlWidget *w = [self widgetForView:v];
            if (!w) {
                self.dragWidget = nil;
                return;
            }
            self.selectedWidget = w;
            self.dragWidget = w;
            self.dragStartPoint = point;
            self.dragStartX = w.xPercent;
            self.dragStartY = w.yPercent;
            break;
        }

        case UIGestureRecognizerStateChanged: {
            A2ControlWidget *w = self.dragWidget;
            if (!w || CGSizeEqualToSize(self.bounds.size, CGSizeZero)) return;

            CGFloat dx = (point.x - self.dragStartPoint.x) / self.bounds.size.width * 100.0;
            CGFloat dy = (point.y - self.dragStartPoint.y) / self.bounds.size.height * 100.0;

            CGFloat newX = [self snappedValue:self.dragStartX + dx];
            CGFloat newY = [self snappedValue:self.dragStartY + dy];
            newX = MAX(0.0, MIN(100.0 - w.widthPercent, newX));
            newY = MAX(0.0, MIN(100.0 - w.heightPercent, newY));
            w.xPercent = newX;
            w.yPercent = newY;

            UIView *v = [self viewForWidget:w];
            if (v) v.frame = [self frameForWidget:w];
            [self refreshSelectionOverlay];
            if (self.onWidgetChanged) self.onWidgetChanged(w);
            break;
        }

        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            A2ControlWidget *w = self.dragWidget;
            self.dragWidget = nil;
            if (w && self.onWidgetCommitted) self.onWidgetCommitted(w);
            break;
        }

        default:
            break;
    }
}

- (void)handleEditPinch:(UIPinchGestureRecognizer *)g {
    if (!self.editing) return;

    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            A2ControlWidget *w = self.selectedWidget;
            if (!w) {
                CGPoint point = [g locationInView:self];
                w = [self widgetForView:[self widgetViewAtPoint:point]];
            }
            if (!w) return;
            self.selectedWidget = w;
            self.pinchWidget = w;
            self.pinchStartWidth = w.widthPercent;
            self.pinchStartHeight = w.heightPercent;
            break;
        }

        case UIGestureRecognizerStateChanged: {
            A2ControlWidget *w = self.pinchWidget;
            if (!w || g.numberOfTouches < 2) return;

            CGFloat scale = g.scale;
            if (!isfinite(scale) || scale <= 0.01) return;

            CGFloat newW = MAX(2.0, MIN(100.0, self.pinchStartWidth * scale));
            CGFloat newH = MAX(2.0, MIN(100.0, self.pinchStartHeight * scale));

            // 以控件中心为锚点缩放，避免右上角飞出去
            CGFloat centerX = w.xPercent + w.widthPercent / 2.0;
            CGFloat centerY = w.yPercent + w.heightPercent / 2.0;
            w.widthPercent = newW;
            w.heightPercent = newH;
            w.xPercent = MAX(0.0, MIN(100.0 - newW, centerX - newW / 2.0));
            w.yPercent = MAX(0.0, MIN(100.0 - newH, centerY - newH / 2.0));

            UIView *v = [self viewForWidget:w];
            if (v) v.frame = [self frameForWidget:w];
            [self refreshSelectionOverlay];
            if (self.onWidgetChanged) self.onWidgetChanged(w);
            break;
        }

        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            A2ControlWidget *w = self.pinchWidget;
            self.pinchWidget = nil;
            if (w && self.onWidgetCommitted) self.onWidgetCommitted(w);
            break;
        }

        default:
            break;
    }
}

#pragma mark 其余

- (void)setInputDelegate:(id<A2ControlInputDelegate>)inputDelegate {
    _inputDelegate = inputDelegate;
    self.input.delegate = inputDelegate;
    for (id v in self.buttonViews) {
        if ([v respondsToSelector:@selector(setInputDelegate:)]) {
            [v setInputDelegate:inputDelegate];
        }
    }
}

- (void)setControlsOpacity:(CGFloat)controlsOpacity {
    _controlsOpacity = MAX(0, MIN(1, controlsOpacity));
    // 整体透明度放在容器上，单控件 opacity 由 layoutSubviews 各自应用
    self.alpha = _controlsOpacity;
}

- (void)applyTheme {
    self.selectionView.accentColor = A2ThemeManager.shared.scheme.cPrimary;
    for (id v in self.buttonViews) {
        if ([v respondsToSelector:@selector(applyTheme)]) [(id)v applyTheme];
    }
    [self refreshSelectionOverlay];
}

@end
