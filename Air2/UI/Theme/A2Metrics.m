//
//  A2Metrics.m
//  Air2
//

#import "A2Metrics.h"

const CGFloat A2SpaceXS  = 4;
const CGFloat A2SpaceS   = 8;
const CGFloat A2SpaceM   = 12;
const CGFloat A2SpaceL   = 16;
const CGFloat A2SpaceXL  = 24;
const CGFloat A2SpaceXXL = 32;

const CGFloat A2PageMargin = 16;

const CGFloat A2RadiusXS = 8;
const CGFloat A2RadiusS  = 12;
const CGFloat A2RadiusM  = 16;
const CGFloat A2RadiusL  = 20;
const CGFloat A2RadiusXL = 28;

const CGFloat A2TopBarHeight   = 52;
const CGFloat A2ButtonHeight   = 52;
const CGFloat A2MinTouchTarget = 44;
const CGFloat A2IconSize       = 24;

const CGFloat A2PanelPadding = 20;

/// 侧栏宽度：横屏下取屏宽的 38%，但不超过 400pt。
/// 上限是为了在 iPad 这类超宽设备上不至于让侧栏过宽、
/// 背景区反而显得空。
CGFloat A2SidePanelWidth(CGFloat screenWidth) {
    return MIN(400.0, screenWidth * 0.38);
}

const NSTimeInterval A2AnimDuration     = 0.38;
const NSTimeInterval A2AnimDurationFast = 0.18;
const NSTimeInterval A2AnimDurationSlow = 0.6;
const NSTimeInterval A2AnimDurationCard = 0.42;

const CGFloat A2SpringDamping  = 0.78;
const CGFloat A2SpringVelocity = 0.35;

const NSTimeInterval A2CardStaggerDelay = 0.035;

UIViewPropertyAnimator *A2SpringAnimator(NSTimeInterval duration) {
    UISpringTimingParameters *params =
        [[UISpringTimingParameters alloc] initWithDampingRatio:A2SpringDamping
                                              initialVelocity:CGVectorMake(0, A2SpringVelocity)];
    return [[UIViewPropertyAnimator alloc] initWithDuration:duration timingParameters:params];
}

UIViewPropertyAnimator *A2StandardSpring(void) {
    return A2SpringAnimator(A2AnimDuration);
}

/// 更软的弹簧：damping 更高、初速更低，适合大面积元素（背景、抽屉）
UIViewPropertyAnimator *A2SoftSpring(NSTimeInterval duration) {
    UISpringTimingParameters *params =
        [[UISpringTimingParameters alloc] initWithDampingRatio:0.88
                                              initialVelocity:CGVectorMake(0, 0.1)];
    return [[UIViewPropertyAnimator alloc] initWithDuration:duration timingParameters:params];
}

/// 卡片依次入场：淡入 + 上浮 16pt，每个延迟 staggerDelay 依次启动。
///
/// 注意 UIViewPropertyAnimator 没有可写的 delay 属性（只有只读的
/// `delay` 用于查询），所以错峰必须靠 dispatch_after 实现。
///
/// @param completion 最后一个动画结束时回调，可为 nil
/// @return 第一个卡片的动画器。调用方若要中途取消，可以持有它。
UIViewPropertyAnimator *A2AnimateCardEntrance(NSArray<UIView *> *views,
                                              CGFloat staggerDelay,
                                              void (^completion)(void)) {
    if (views.count == 0) return nil;

    __block UIViewPropertyAnimator *firstAnimator = nil;

    for (NSUInteger i = 0; i < views.count; i++) {
        UIView *v = views[i];

        // 设初始态：下方 16pt、透明
        v.alpha = 0;
        v.transform = CGAffineTransformMakeTranslation(0, 16);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(i * staggerDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationCard);
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
