//
//  A2Dialog.m
//  Air2
//

#import "A2Dialog.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

#pragma mark - Action

@implementation A2DialogAction

+ (instancetype)actionWithTitle:(NSString *)title
                          style:(A2DialogActionStyle)style
                        handler:(void (^)(void))handler {
    A2DialogAction *a = [A2DialogAction new];
    a->_title = [title copy];
    a->_style = style;
    a->_handler = [handler copy];
    return a;
}

@end

#pragma mark - Dialog

@interface A2Dialog ()
@property (nonatomic, strong) UIView *scrim;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIStackView *actionStack;
@property (nonatomic, copy) NSArray<A2DialogAction *> *actions;
@end

@implementation A2Dialog

+ (instancetype)showInView:(UIView *)host
                     title:(NSString *)title
                   message:(NSString *)message
                   actions:(NSArray<A2DialogAction *> *)actions {
    return [self showInView:host title:title message:message
                contentView:nil actions:actions];
}

+ (instancetype)showInView:(UIView *)host
                     title:(NSString *)title
                   message:(NSString *)message
               contentView:(UIView *)contentView
                   actions:(NSArray<A2DialogAction *> *)actions {

    A2Dialog *d = [[A2Dialog alloc] initWithFrame:host.bounds];
    d.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    d.actions = actions ?: @[];
    [host addSubview:d];
    [d buildWithTitle:title message:message contentView:contentView];
    [d animateIn];
    return d;
}

#pragma mark - 构建

- (void)buildWithTitle:(NSString *)title
               message:(NSString *)message
           contentView:(UIView *)contentView {

    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    // ---- 遮罩 ----
    _scrim = [[UIView alloc] initWithFrame:self.bounds];
    _scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.32];
    [self addSubview:_scrim];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(scrimTapped:)];
    [_scrim addGestureRecognizer:tap];

    // ---- 卡片 ----
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    // MD3：圆角 28
    _card.layer.cornerRadius = A2RadiusXL;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.backgroundColor = t.cSurfaceContainerHigh;
    [self addSubview:_card];

    NSMutableArray<UIView *> *items = [NSMutableArray array];

    if (title.length) {
        UILabel *l = [self labelWithText:title
                                    font:[UIFont systemFontOfSize:24 weight:UIFontWeightSemibold]
                                   color:t.cOnSurface];
        l.numberOfLines = 0;
        [items addObject:l];
    }

    if (message.length) {
        UILabel *l = [self labelWithText:message
                                    font:[UIFont systemFontOfSize:14 weight:UIFontWeightRegular]
                                   color:t.cOnSurfaceVariant];
        l.numberOfLines = 0;
        [items addObject:l];
    }

    if (contentView) [items addObject:contentView];

    // ---- 动作区 ----
    _actionStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _actionStack.translatesAutoresizingMaskIntoConstraints = NO;
    _actionStack.axis = UILayoutConstraintAxisHorizontal;
    _actionStack.spacing = A2SpaceS;
    _actionStack.distribution = UIStackViewDistributionFillProportionally;
    _actionStack.alignment = UIStackViewAlignmentCenter;
    // MD3 的动作区右对齐
    _actionStack.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;

    for (A2DialogAction *a in self.actions) {
        UIButton *b = [self buttonForAction:a];
        [_actionStack addArrangedSubview:b];
    }
    [items addObject:_actionStack];

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:items];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = A2SpaceM;
    [_card addSubview:content];

    // ---- 约束 ----
    // MD3 Dialog 宽度：最小 280，最大 560；这里按屏幕比例给
    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_card.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_card.widthAnchor constraintGreaterThanOrEqualToConstant:320],
        [_card.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor multiplier:0.7],

        // 内边距 24
        [content.topAnchor constraintEqualToAnchor:_card.topAnchor constant:24],
        [content.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-24],
        [content.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:24],
        [content.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-24],
    ]];
}

- (UILabel *)labelWithText:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text = text;
    l.font = font;
    l.textColor = color;
    return l;
}

- (UIButton *)buttonForAction:(A2DialogAction *)action {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:action.title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
    [b.heightAnchor constraintEqualToConstant:40].active = YES;
    // MD3 按钮圆角 20（全圆角胶囊）
    b.layer.cornerRadius = 20;
    b.layer.cornerCurve = kCACornerCurveContinuous;

    switch (action.style) {
        case A2DialogActionStyleFilled:
            b.backgroundColor = t.cPrimary;
            [b setTitleColor:t.cOnPrimary forState:UIControlStateNormal];
            break;
        case A2DialogActionStyleDestructive:
            b.backgroundColor = UIColor.clearColor;
            [b setTitleColor:t.cError forState:UIControlStateNormal];
            break;
        default:
            b.backgroundColor = UIColor.clearColor;
            [b setTitleColor:t.cPrimary forState:UIControlStateNormal];
            break;
    }

    __weak typeof(self) weakSelf = self;
    [b addAction:[UIAction actionWithHandler:^(UIAction *a) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        void (^h)(void) = action.handler;
        [self dismiss];
        if (h) h();
    }] forControlEvents:UIControlEventTouchUpInside];

    return b;
}

- (void)scrimTapped:(UITapGestureRecognizer *)g {
    // MD3：点遮罩不关闭（避免误触），要显式点按钮。
    // 如果只有一个按钮且是「确定」类，也可以关；这里保守处理不关。
}

#pragma mark - 动画

- (void)animateIn {
    _card.transform = CGAffineTransformMakeScale(0.85, 0.85);
    self.alpha = 0;

    [UIView animateWithDuration:0.24
                          delay:0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.alpha = 1;
        self.card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)dismiss {
    [UIView animateWithDuration:0.16 animations:^{
        self.alpha = 0;
        self.card.transform = CGAffineTransformMakeScale(0.92, 0.92);
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
    }];
}

@end
