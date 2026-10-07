//
//  A2Toast.m
//  Air2
//

#import "A2Toast.h"
#import "A2Metrics.h"
#import "A2Typography.h"

static const NSTimeInterval kToastVisibleDuration = 1.4;
static const NSTimeInterval kToastFadeDuration = 0.22;

@implementation A2Toast

+ (void)show:(NSString *)message inView:(UIView *)view {
    if (message.length == 0 || !view) return;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = message;
    label.font = [A2Typography caption];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    label.textAlignment = NSTextAlignmentCenter;
    label.layer.cornerRadius = 18;
    label.layer.cornerCurve = kCACornerCurveContinuous;
    label.clipsToBounds = YES;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.alpha = 0;
    label.userInteractionEnabled = NO;

    [view addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [label.bottomAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.bottomAnchor constant:-40],
        [label.heightAnchor constraintEqualToConstant:36],
        [label.widthAnchor constraintGreaterThanOrEqualToConstant:120],
    ]];

    [UIView animateWithDuration:kToastFadeDuration animations:^{
        label.alpha = 1;
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kToastVisibleDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:kToastFadeDuration animations:^{
            label.alpha = 0;
        } completion:^(BOOL finished) {
            [label removeFromSuperview];
        }];
    });
}

@end
