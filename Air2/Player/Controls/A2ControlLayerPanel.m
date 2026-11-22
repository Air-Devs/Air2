//
//  A2ControlLayerPanel.m
//  Air2
//
//  图层面板。交互对照 ZL2 的 control_editor/edit_layer/。
//

#import "A2ControlLayerPanel.h"
#import "A2ControlLayout.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Toast.h"
#import <objc/runtime.h>

#pragma mark - Rule

@implementation A2ControlLayerRule

+ (instancetype)ruleFromJSON:(NSDictionary *)json {
    A2ControlLayerRule *r = [A2ControlLayerRule new];
    if ([json[@"hideWhenGamepad"] boolValue])      r.hideWhen = A2HideLayerWhenGamepad;
    else if ([json[@"hideWhenMouse"] boolValue])   r.hideWhen = A2HideLayerWhenMouse;
    else if ([json[@"hideWhenJoystick"] boolValue]) r.hideWhen = A2HideLayerWhenJoystick;
    else                                            r.hideWhen = A2HideLayerWhenNever;
    return r;
}

- (NSDictionary *)toJSON {
    return @{
        @"hideWhenGamepad":  @(self.hideWhen == A2HideLayerWhenGamepad),
        @"hideWhenMouse":    @(self.hideWhen == A2HideLayerWhenMouse),
        @"hideWhenJoystick": @(self.hideWhen == A2HideLayerWhenJoystick),
    };
}

@end

#pragma mark - 关联键

static char kA2LayerPanelLayerKey;

#pragma mark - Panel

@interface A2ControlLayerPanel ()
@property (nonatomic, strong) NSMutableArray<A2ControlLayer *> *layers;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong, nullable) UILabel *hintLabel;
@end

@implementation A2ControlLayerPanel

- (instancetype)initWithLayers:(NSMutableArray<A2ControlLayer *> *)layers {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _layers = layers;
    [self build];
    [self reload];
    [self applyTheme];
    return self;
}

- (void)build {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = A2RadiusL;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;

    _hintLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _hintLabel.text = @"图层";
    _hintLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];

    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.translatesAutoresizingMaskIntoConstraints = NO;
    [add setTitle:@"＋ 新建层" forState:UIControlStateNormal];
    add.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    add.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    [add addTarget:self action:@selector(addLayer) forControlEvents:UIControlEventTouchUpInside];
    [add.heightAnchor constraintEqualToConstant:32].active = YES;

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.showsVerticalScrollIndicator = YES;

    _stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 4;
    [_scroll addSubview:_stack];

    [self addSubview:_hintLabel];
    [self addSubview:add];
    [self addSubview:_scroll];

    [NSLayoutConstraint activateConstraints:@[
        [_hintLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [_hintLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],

        [add.centerYAnchor constraintEqualToAnchor:_hintLabel.centerYAnchor],
        [add.leadingAnchor constraintGreaterThanOrEqualToAnchor:_hintLabel.trailingAnchor constant:8],
        [add.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],

        [_scroll.topAnchor constraintEqualToAnchor:_hintLabel.bottomAnchor constant:8],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [_scroll.heightAnchor constraintEqualToConstant:150],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],

        [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.trailingAnchor],
    ]];
}

- (void)reload {
    for (UIView *v in [_stack.arrangedSubviews copy]) {
        [_stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    for (NSUInteger i = 0; i < self.layers.count; i++) {
        A2ControlLayer *layer = self.layers[i];
        UIView *row = [self rowForLayer:layer index:i];
        [_stack addArrangedSubview:row];
    }
    [self applyTheme];
}

- (UIButton *)iconButton:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    [b.widthAnchor constraintEqualToConstant:30].active = YES;
    [b.heightAnchor constraintEqualToConstant:30].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIView *)rowForLayer:(A2ControlLayer *)layer index:(NSUInteger)index {
    UIControl *row = [[UIControl alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.layer.cornerRadius = A2RadiusS;
    row.layer.cornerCurve = kCACornerCurveContinuous;
    [row.heightAnchor constraintEqualToConstant:38].active = YES;
    row.tag = (NSInteger)index;
    [row addTarget:self action:@selector(selectRow:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(row, &kA2LayerPanelLayerKey, layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 显示/隐藏
    UIButton *eye = [self iconButton:(layer.visibleByDefault ? @"eye" : @"eye.slash")
                              action:@selector(toggleVisibility:)];
    objc_setAssociatedObject(eye, &kA2LayerPanelLayerKey, layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    name.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    name.text = [NSString stringWithFormat:@"%@（%lu）",
                 layer.name ?: layer.identifier,
                 (unsigned long)layer.widgets.count];
    name.userInteractionEnabled = NO;

    // 顺序：上/下。ZL2 里 layers 数组越靠后越在上层；
    // 这里用「上移 = 往后排（更上层）」的直觉，按钮标题用箭头上/下。
    UIButton *up = [self iconButton:@"arrow.up" action:@selector(moveLayerUp:)];
    objc_setAssociatedObject(up, &kA2LayerPanelLayerKey, layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    up.tag = (NSInteger)index;

    UIButton *down = [self iconButton:@"arrow.down" action:@selector(moveLayerDown:)];
    objc_setAssociatedObject(down, &kA2LayerPanelLayerKey, layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    down.tag = (NSInteger)index;

    UIButton *del = [self iconButton:@"trash" action:@selector(deleteLayer:)];
    objc_setAssociatedObject(del, &kA2LayerPanelLayerKey, layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[eye, name, up, down, del]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 4;
    [row addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:6],
        [stack.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-6],
        [stack.topAnchor constraintEqualToAnchor:row.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [name.widthAnchor constraintGreaterThanOrEqualToConstant:40],
    ]];

    // 选中高亮（编辑器记住当前层）
    if (self.selectedLayer == layer) {
        row.layer.borderWidth = 1.5;
    } else {
        row.layer.borderWidth = 0;
    }
    return row;
}

#pragma mark - 操作

- (void)selectRow:(UIControl *)row {
    A2ControlLayer *layer = objc_getAssociatedObject(row, &kA2LayerPanelLayerKey);
    if (![layer isKindOfClass:A2ControlLayer.class]) return;
    self.selectedLayer = layer;
    [self reload];
    if (self.onLayerSelected) self.onLayerSelected(layer);
}

- (void)toggleVisibility:(UIButton *)sender {
    A2ControlLayer *layer = objc_getAssociatedObject(sender, &kA2LayerPanelLayerKey);
    if (!layer) return;
    layer.visibleByDefault = !layer.visibleByDefault;
    [self reload];
    if (self.onLayersChanged) self.onLayersChanged();
}

- (void)moveLayerUp:(UIButton *)sender {
    A2ControlLayer *layer = objc_getAssociatedObject(sender, &kA2LayerPanelLayerKey);
    NSUInteger index = [self.layers indexOfObject:layer];
    if (index == NSNotFound || index + 1 >= self.layers.count) {
        [A2Toast show:@"已经在最上层" inView:self];
        return;
    }
    [self.layers exchangeObjectAtIndex:index withObjectAtIndex:index + 1];
    [self reload];
    if (self.onLayersChanged) self.onLayersChanged();
}

- (void)moveLayerDown:(UIButton *)sender {
    A2ControlLayer *layer = objc_getAssociatedObject(sender, &kA2LayerPanelLayerKey);
    NSUInteger index = [self.layers indexOfObject:layer];
    if (index == NSNotFound || index == 0) {
        [A2Toast show:@"已经在最下层" inView:self];
        return;
    }
    [self.layers exchangeObjectAtIndex:index withObjectAtIndex:index - 1];
    [self reload];
    if (self.onLayersChanged) self.onLayersChanged();
}

- (void)addLayer {
    if (self.layers.count >= 8) {
        [A2Toast show:@"最多 8 个层" inView:self];
        return;
    }

    A2ControlLayer *layer = [A2ControlLayer new];
    layer.identifier = [NSString stringWithFormat:@"layer%lu",
                        (unsigned long)(self.layers.count + 1)];
    layer.name = [NSString stringWithFormat:@"层 %lu", (unsigned long)(self.layers.count + 1)];
    layer.visibleByDefault = YES;
    [self.layers addObject:layer];

    self.selectedLayer = layer;
    [self reload];
    if (self.onLayersChanged) self.onLayersChanged();
    if (self.onLayerSelected) self.onLayerSelected(layer);
}

- (void)deleteLayer:(UIButton *)sender {
    A2ControlLayer *layer = objc_getAssociatedObject(sender, &kA2LayerPanelLayerKey);
    if (!layer) return;

    if (self.layers.count <= 1) {
        [A2Toast show:@"至少保留一个层" inView:self];
        return;
    }

    [self.layers removeObject:layer];
    if (self.selectedLayer == layer) self.selectedLayer = self.layers.firstObject;
    [self reload];
    if (self.onLayersChanged) self.onLayersChanged();
    if (self.onLayerSelected) self.onLayerSelected(self.selectedLayer);
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    self.backgroundColor = t.cSurfaceContainer;

    if (_hintLabel) _hintLabel.textColor = t.cOnSurface;

    for (UIView *row in _stack.arrangedSubviews) {
        row.backgroundColor = t.cSurfaceContainerHigh;
        if (self.selectedLayer && row.tag >= 0 &&
            (NSUInteger)row.tag < self.layers.count &&
            self.layers[(NSUInteger)row.tag] == self.selectedLayer) {
            row.layer.borderWidth = 1.5;
            row.layer.borderColor = t.cPrimary.CGColor;
        }
        for (UIView *sub in row.subviews) {
            [self applyThemeToView:sub scheme:t];
        }
    }
}

- (void)applyThemeToView:(UIView *)view scheme:(A2ColorScheme *)scheme {
    if ([view isKindOfClass:UILabel.class]) {
        ((UILabel *)view).textColor = scheme.cOnSurface;
    } else if ([view isKindOfClass:UIButton.class]) {
        ((UIButton *)view).tintColor = scheme.cPrimary;
    }
    for (UIView *sub in view.subviews) [self applyThemeToView:sub scheme:scheme];
}

@end
