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
#import "A2JoystickView.h"
#import "A2ThemeManager.h"
#import "A2Logger.h"

#pragma mark - 单个控件

// 类扩展必须在 @implementation 之前，且不能写在 @interface 内
@interface A2ControlButtonView ()
@property (nonatomic, strong, nullable) A2ControlStyle *style;
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

    // Toggleable：按下即切换，不需要等松开
    if (self.widget.isToggleable) {
        self.on = !self.isOn;
        [self fireEvents];
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

    // 非开关式的按钮，松开时要释放按键
    if (!self.widget.isToggleable) {
        for (A2ControlEvent *e in self.widget.clickEvents) {
            if (e.type == A2ControlEventTypeKey && e.key.length) {
                [self.inputDelegate controlReleaseKey:e.key];
            }
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _pressed = NO;
    [self updatePressedAppearance];
}

/// 把控件的事件翻译成输入意图
- (void)fireEvents {
    for (A2ControlEvent *e in self.widget.clickEvents) {
        // 事件类型对齐 ZL2 的 ClickEvent.Type（六种）：
        //   key / launcher_event / switch_layer / show_layer / hide_layer / send_text
        switch (e.type) {
            case A2ControlEventTypeKey:
                if (e.key.length) [self.inputDelegate controlPressKey:e.key];
                break;

            case A2ControlEventTypeLauncherEvent:
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
            self.alpha = self->_pressed ? 0.55 : (self.isOn ? 0.9 : 0.75);
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
    self.alpha = self.isOn ? 0.9 : 0.75;
}

- (void)setOn:(BOOL)on {
    _on = on;
    [self updatePressedAppearance];
}

- (void)setEditing:(BOOL)editing {
    _editing = editing;
    self.userInteractionEnabled = YES;   // 编辑模式下永远可点（用于选中）
    self.layer.borderColor = editing
        ? A2ThemeManager.shared.scheme.cPrimary.CGColor
        : [A2ThemeManager.shared.scheme.cOutline colorWithAlphaComponent:0.5].CGColor;
    self.layer.borderWidth = editing ? 2 : 1;
}

@end

#pragma mark - 渲染器

@interface A2ControlRenderer ()
@property (nonatomic, strong, readwrite) A2ControlLayout *layout;
@property (nonatomic, strong) NSMutableArray<UIView *> *buttonViews;
@end

@implementation A2ControlRenderer

- (instancetype)initWithLayout:(A2ControlLayout *)layout {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _layout = layout;
    _buttonViews = [NSMutableArray array];
    _controlsOpacity = 1.0;
    self.backgroundColor = UIColor.clearColor;
    [self reload];
    return self;
}

- (void)reload {
    for (UIView *v in self.subviews) [v removeFromSuperview];
    [_buttonViews removeAllObjects];

    for (A2ControlWidget *w in self.layout.allWidgets) {
        UIView *v = nil;

        if (w.type == A2ControlWidgetTypeJoystick) {
            // 摇杆：独立的交互类（方向判定 + 死区）
            A2JoystickView *j = [[A2JoystickView alloc] initWithWidget:w];
            j.inputDelegate = self.inputDelegate;
            v = j;
        } else {
            A2ControlButtonView *b = [[A2ControlButtonView alloc] initWithWidget:w];
            // 样式：从 layout.buttonStyles 里按 buttonStyle 查
            if (w.buttonStyle.length) {
                NSDictionary *styleJSON = self.layout.buttonStyles[w.buttonStyle];
                if (styleJSON) b.style = [A2ControlStyle styleFromJSON:styleJSON];
            }
            v = b;
        }
        [self addSubview:v];
        [_buttonViews addObject:v];
    }

    // 编辑模式下加选中手势
    if (self.editing) {
        for (UIView *v in _buttonViews) {
            UITapGestureRecognizer *tap =
                [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
            [v addGestureRecognizer:tap];
        }
    }

    [self setNeedsLayout];
    [self applyTheme];
}

- (void)handleTap:(UITapGestureRecognizer *)g {
    UIView *v = g.view;
    A2ControlWidget *w = nil;
    if ([v isKindOfClass:A2ControlButtonView.class]) {
        w = ((A2ControlButtonView *)v).widget;
    } else if ([v isKindOfClass:A2JoystickView.class]) {
        w = ((A2JoystickView *)v).widget;
    }
    if (!w) return;

    self.selectedWidget = w;
    for (UIView *b in _buttonViews) {
        b.layer.borderWidth = (b == v) ? 2 : 1;
    }
    if (self.onSelectionChanged) self.onSelectionChanged(w);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;

    // 百分比坐标 → 实际像素
    for (UIView *v in _buttonViews) {
        A2ControlWidget *w = nil;
        if ([v isKindOfClass:A2ControlButtonView.class]) w = ((A2ControlButtonView *)v).widget;
        else if ([v isKindOfClass:A2JoystickView.class]) w = ((A2JoystickView *)v).widget;
        if (!w) continue;

        CGFloat x = s.width  * w.xPercent / 100.0;
        CGFloat y = s.height * w.yPercent / 100.0;
        CGFloat width  = s.width  * w.widthPercent / 100.0;
        CGFloat height = s.height * w.heightPercent / 100.0;

        // 尺寸为 0 的控件给个默认值，避免完全看不见
        if (width <= 0)  width  = MAX(48, s.height * 0.11);
        if (height <= 0) height = width;

        v.frame = CGRectMake(x, y, width, height);
        v.layer.cornerRadius = MIN(width, height) * 0.18;
    }
}

- (void)setInputDelegate:(id<A2ControlInputDelegate>)inputDelegate {
    _inputDelegate = inputDelegate;
    for (id v in _buttonViews) {
        if ([v respondsToSelector:@selector(setInputDelegate:)]) {
            [v setInputDelegate:inputDelegate];
        }
    }
}

- (void)setEditing:(BOOL)editing {
    _editing = editing;
    for (UIView *v in _buttonViews) {
        if ([v respondsToSelector:@selector(setEditing:)]) [(id)v setEditing:editing];
    }
    if (editing) [self reload];   // 重加手势
}

- (void)setControlsOpacity:(CGFloat)controlsOpacity {
    _controlsOpacity = MAX(0, MIN(1, controlsOpacity));
    for (UIView *v in _buttonViews) {
        v.alpha = _controlsOpacity;
    }
}

- (void)applyTheme {
    for (id v in _buttonViews) {
        if ([v respondsToSelector:@selector(applyTheme)]) [(id)v applyTheme];
    }
}

@end
