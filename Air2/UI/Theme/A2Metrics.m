//
//  A2Metrics.m
//  Air2
//

#import "A2Metrics.h"

#pragma mark - 间距

const CGFloat A2SpaceXS  = 4;
const CGFloat A2SpaceS   = 8;
const CGFloat A2SpaceM   = 12;
const CGFloat A2SpaceL   = 16;
const CGFloat A2SpaceXL  = 24;
const CGFloat A2SpaceXXL = 32;

const CGFloat A2CardPadding       = 12;
const CGFloat A2CardSpacing       = 12;
const CGFloat A2PanelOuterPadding = 12;

/// 二级页面的左右边距用 16 —— 比操作区宽一点，
/// 因为页面内容没有卡片包裹，需要更多呼吸空间。
const CGFloat A2PageMargin        = 16;

const CGFloat A2ContentMaxWidth   = 680;

#pragma mark - 圆角

const CGFloat A2RadiusXS = 4;
const CGFloat A2RadiusS  = 8;
const CGFloat A2RadiusM  = 12;
const CGFloat A2RadiusL  = 16;
const CGFloat A2RadiusXL = 28;

#pragma mark - 高度

const CGFloat A2TopBarHeight   = 52;
const CGFloat A2ButtonHeight   = 52;
const CGFloat A2MinTouchTarget = 44;

#pragma mark - 头像

const CGFloat A2AvatarSizeLarge = 64;
const CGFloat A2AvatarSizeSmall = 48;

#pragma mark - 布局

/// 操作区 : 内容区 = 3 : 7。
/// 这个比例让左侧背景有足够的展示空间，右侧操作区不显臃肿。
const CGFloat A2PanelWidthRatio = 0.30;

/// 高度够时可以用更宽松的布局（多展示一块区域）
const CGFloat A2TallLayoutThreshold = 600;

#pragma mark - 动效

const NSTimeInterval A2AnimDuration     = 0.38;
const NSTimeInterval A2AnimDurationFast = 0.18;
const NSTimeInterval A2AnimDurationSlow = 0.6;
const NSTimeInterval A2AnimDurationCard = 0.42;

/// MD3 Expressive 的弹簧比标准 MD3 更有弹性，
/// damping 取 0.72（标准是 0.78），回弹更明显。
const CGFloat A2SpringDamping  = 0.78;
const CGFloat A2SpringVelocity = 0.35;

const NSTimeInterval A2CardStaggerDelay = 0.035;

#pragma mark - 动画器

UIViewPropertyAnimator *A2SpringAnimator(NSTimeInterval duration) {
    UISpringTimingParameters *params =
        [[UISpringTimingParameters alloc] initWithDampingRatio:A2SpringDamping
                                              initialVelocity:CGVectorMake(0, A2SpringVelocity)];
    return [[UIViewPropertyAnimator alloc] initWithDuration:duration timingParameters:params];
}

UIViewPropertyAnimator *A2StandardSpring(void) {
    return A2SpringAnimator(A2AnimDuration);
}

/// 更软的弹簧：damping 高、初速低，适合大面积元素（背景、抽屉）
UIViewPropertyAnimator *A2SoftSpring(NSTimeInterval duration) {
    UISpringTimingParameters *params =
        [[UISpringTimingParameters alloc] initWithDampingRatio:0.88
                                              initialVelocity:CGVectorMake(0, 0.1)];
    return [[UIViewPropertyAnimator alloc] initWithDuration:duration timingParameters:params];
}

/// MD3 Expressive 风格：回弹更强，用于「启动游戏」这类强调操作。
/// 系统自带的 damping 在 0.7 附近会明显「弹一下」，正是 expressive 的观感。
UIViewPropertyAnimator *A2ExpressiveSpring(NSTimeInterval duration) {
    UISpringTimingParameters *params =
        [[UISpringTimingParameters alloc] initWithDampingRatio:0.72
                                              initialVelocity:CGVectorMake(0, 0.5)];
    return [[UIViewPropertyAnimator alloc] initWithDuration:duration timingParameters:params];
}

#pragma mark - 卡片入场

/// 卡片依次入场：淡入 + 上浮 16pt，每个延迟 staggerDelay 依次启动。
///
/// UIViewPropertyAnimator 没有可写的 delay 属性（只有只读的查询属性），
/// 所以错峰必须靠 dispatch_after 实现。
UIViewPropertyAnimator *A2AnimateCardEntrance(NSArray<UIView *> *views,
                                              CGFloat staggerDelay,
                                              void (^completion)(void)) {
    if (views.count == 0) return nil;

    __block UIViewPropertyAnimator *firstAnimator = nil;

    for (NSUInteger i = 0; i < views.count; i++) {
        UIView *v = views[i];
        v.alpha = 0;
        v.transform = CGAffineTransformMakeTranslation(0, 16);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(i * staggerDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewPropertyAnimator *a = A2ExpressiveSpring(A2AnimDurationCard);
            [a addAnimations:^{
                v.alpha = 1;
                v.transform = CGAffineTransformIdentity;
            }];
            if (i == views.count - 1 && completion) {
                [a addCompletion:^(UIViewAnimatingPosition pos) { completion(); }];
            }
            [a startAnimation];

            if (i == 0) firstAnimator = a;
        });
    }

    return firstAnimator;
}
