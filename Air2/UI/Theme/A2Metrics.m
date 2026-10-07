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

const CGFloat A2RadiusS  = 10;
const CGFloat A2RadiusM  = 14;
const CGFloat A2RadiusL  = 18;
const CGFloat A2RadiusXL = 26;

const CGFloat A2TopBarHeight    = 44;
const CGFloat A2ButtonHeight    = 50;
const CGFloat A2CardTitleHeight = 44;
const CGFloat A2MinTouchTarget  = 44;

const NSTimeInterval A2AnimDuration     = 0.38;
const NSTimeInterval A2AnimDurationFast = 0.18;
const NSTimeInterval A2AnimDurationSlow = 0.55;

const CGFloat A2SpringDamping  = 0.78;
const CGFloat A2SpringVelocity = 0.35;

/// 生成弹簧动画器。iOS 的弹簧参数里 damping 越接近 1 越"稳"，
/// 我们取 0.78 让卡片展开有轻微回弹但不晃。
UIViewPropertyAnimator *A2SpringAnimator(NSTimeInterval duration) {
    if (@available(iOS 13.0, *)) {
        UISpringTimingParameters *params =
            [[UISpringTimingParameters alloc] initWithDampingRatio:A2SpringDamping
                                                  initialVelocity:CGVectorMake(0, A2SpringVelocity)];
        return [[UIViewPropertyAnimator alloc] initWithDuration:duration timingParameters:params];
    }
    return [[UIViewPropertyAnimator alloc] initWithDuration:duration
                                                      curve:UIViewAnimationCurveEaseOut
                                                 animations:nil];
}

UIViewPropertyAnimator *A2StandardSpring(void) {
    return A2SpringAnimator(A2AnimDuration);
}
