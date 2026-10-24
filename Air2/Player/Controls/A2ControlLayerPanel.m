//
//  A2ControlLayerPanel.m
//  Air2
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

#pragma mark - Panel

@interface A2ControlLayerPanel ()
@property (nonatomic, strong) NSMutableArray<A2ControlLayer *> *layers;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UIScrollView *scroll;
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

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"控件层";
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];

    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.translatesAutoresizingMaskIntoConstraints = NO;
    [add setTitle:@"＋ 新建层" forState:UIControlStateNormal];
    add.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    add.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [add addTarget:self action:@selector(addLayer) forControlEvents:UIControlEventTouchUpInside];
    [add.heightAnchor constraintEqualToConstant:32].active = YES;

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.showsVerticalScrollIndicator = NO;

    _stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 4;
    [_scroll addSubview:_stack];

    [self addSubview:title];
    [self addSubview:_scroll];
    [self addSubview:add];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],

        [_scroll.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [_scroll.heightAnchor constraintEqualToConstant:140],

        [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.trailingAnchor],

        [add.topAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:4],
        [add.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [add.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [add.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
    ]];
}

- (void)reload {
    for (UIView *v in [_stack.arrangedSubviews copy]) {
        [_stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    for (A2ControlLayer *layer in self.layers) {
        UIView *row = [self rowForLayer:layer];
        [_stack addArrangedSubview:row];
    }
}

- (UIView *)rowForLayer:(A2ControlLayer *)layer {
    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.layer.cornerRadius = A2RadiusS;
    row.layer.cornerCurve = kCACornerCurveContinuous;
    [row.heightAnchor constraintEqualToConstant:34].active = YES;

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    name.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    name.text = [NSString stringWithFormat:@"%@（%lu 个控件）",
                 layer.name ?: layer.identifier,
                 (unsigned long)layer.widgets.count];

    UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
    del.translatesAutoresizingMaskIntoConstraints = NO;
    [del setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal];
    [del.widthAnchor constraintEqualToConstant:28].active = YES;
    [del.heightAnchor constraintEqualToConstant:28].active = YES;
    objc_setAssociatedObject(del, "layer", layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [del addTarget:self action:@selector(deleteLayer:) forControlEvents:UIControlEventTouchUpInside];

    [row addSubview:name];
    [row addSubview:del];

    [NSLayoutConstraint activateConstraints:@[
        [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10],
        [name.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [name.trailingAnchor constraintLessThanOrEqualToAnchor:del.leadingAnchor constant:-6],
        [del.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-6],
        [del.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    return row;
}

#pragma mark - 操作

- (void)addLayer {
    // 保留至少一层
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

    [self reload];
    if (self.onLayersChanged) self.onLayersChanged();
}

- (void)deleteLayer:(UIButton *)sender {
    A2ControlLayer *layer = objc_getAssociatedObject(sender, "layer");
    if (!layer) return;

    if (self.layers.count <= 1) {
        [A2Toast show:@"至少保留一个层" inView:self];
        return;
    }

    [self.layers removeObject:layer];
    [self reload];
    if (self.onLayersChanged) self.onLayersChanged();
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    self.backgroundColor = t.cSurfaceContainer;

    for (UIView *v in self.subviews) {
        if ([v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length) {
            ((UILabel *)v).textColor = t.cOnSurface;
        }
    }

    for (UIView *row in _stack.arrangedSubviews) {
        row.backgroundColor = t.cSurfaceContainerHigh;
        for (UIView *sub in row.subviews) {
            if ([sub isKindOfClass:UILabel.class]) ((UILabel *)sub).textColor = t.cOnSurface;
            else if ([sub isKindOfClass:UIButton.class]) ((UIButton *)sub).tintColor = t.cError;
        }
    }
}

@end
