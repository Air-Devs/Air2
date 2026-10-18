//
//  A2ControlRenderer.m
//  Air2
//

#import "A2ControlRenderer.h"
#import "A2ThemeManager.h"
#import "A2Logger.h"

#pragma mark - 单个控件

/// 一个可交互的控件视图
@interface A2ControlButtonView : UIView
@property (nonatomic, strong) A2ControlWidget *widget;
@property (nonatomic, weak, nullable) id<A2ControlInputDelegate> inputDelegate;
@property (nonatomic, assign) BOOL editing;
@property (nonatomic, assign, getter=isOn) BOOL on;   // Toggleable 的开关态
- (instancetype)initWithWidget:(A2ControlWidget *)widget;
- (void)applyTheme;
@end

@implementation A2ControlButtonView {
    UILabel *_label;
    BOOL _pressed;
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

    [self applyTheme];
    return self;
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
            if (e.type == A2ControlEventTypeSendKey && e.key.length) {
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
        switch (e.type) {
            case A2ControlEventTypeSendKey:
                if (e.key.length) [self.inputDelegate controlPressKey:e.key];
                break;
            case A2ControlEventTypeToggleGui:
                [self.inputDelegate controlToggleGui];
                break;
            case A2ControlEventTypeToggleKeyboard:
                [self.inputDelegate controlToggleKeyboard];
                break;
            case A2ControlEventTypeSendText:
                // 文本发送由上层处理（需要拉起输入法）
                [self.inputDelegate controlToggleKeyboard];
                break;
            default:
                break;
        }
    }
}

#pragma mark 外观

- (void)updatePressedAppearance {
    [UIView animateWithDuration:0.08 animations:^{
        self.alpha = self->_pressed ? 0.55 : (self.isOn ? 0.9 : 0.75);
        self.transform = self->_pressed
            ? CGAffineTransformMakeScale(0.94, 0.94)
            : CGAffineTransformIdentity;
    }];
}

- (void)applyTheme {
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
@property (nonatomic, strong) NSMutableArray<A2ControlButtonView *> *buttonViews;
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

    for (A2ControlWidget *w in self.layout.widgets) {
        A2ControlButtonView *v = [[A2ControlButtonView alloc] initWithWidget:w];
        v.inputDelegate = self.inputDelegate;
        v.editing = self.editing;
        [self addSubview:v];
        [_buttonViews addObject:v];
    }

    // 编辑模式下加选中手势
    if (self.editing) {
        for (A2ControlButtonView *v in _buttonViews) {
            UITapGestureRecognizer *tap =
                [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
            [v addGestureRecognizer:tap];
        }
    }

    [self setNeedsLayout];
    [self applyTheme];
}

- (void)handleTap:(UITapGestureRecognizer *)g {
    A2ControlButtonView *v = (A2ControlButtonView *)g.view;
    if (![v isKindOfClass:A2ControlButtonView.class]) return;

    self.selectedWidget = v.widget;
    for (A2ControlButtonView *b in _buttonViews) {
        b.layer.borderWidth = (b == v) ? 2 : 1;
    }
    if (self.onSelectionChanged) self.onSelectionChanged(v.widget);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;

    // 百分比坐标 → 实际像素
    for (A2ControlButtonView *v in _buttonViews) {
        A2ControlWidget *w = v.widget;
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
    for (A2ControlButtonView *v in _buttonViews) {
        v.inputDelegate = inputDelegate;
    }
}

- (void)setEditing:(BOOL)editing {
    _editing = editing;
    for (A2ControlButtonView *v in _buttonViews) v.editing = editing;
    if (editing) [self reload];   // 重加手势
}

- (void)setControlsOpacity:(CGFloat)controlsOpacity {
    _controlsOpacity = MAX(0, MIN(1, controlsOpacity));
    for (A2ControlButtonView *v in _buttonViews) {
        v.alpha = _controlsOpacity * (v.isOn ? 0.9 : 0.75);
    }
}

- (void)applyTheme {
    for (A2ControlButtonView *v in _buttonViews) [v applyTheme];
}

@end
