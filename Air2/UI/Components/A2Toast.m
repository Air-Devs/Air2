//
//  A2Toast.m
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

#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

static const NSTimeInterval kToastVisibleDuration = 1.4;
static const NSTimeInterval kToastFadeDuration = 0.22;

@implementation A2Toast

+ (void)show:(NSString *)message inView:(UIView *)view {
    if (message.length == 0 || !view) return;

    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    // 胶囊容器 + 内嵌标签，两者分开：
    // 原来是「一个 UILabel 兼当气泡」，没有内边距也没有宽度上限 ⇒ 文字贴着圆角
    // 切边，长文案（版本路径那种）直接顶出屏幕（用户批注：框短字多，字顶到头了）。
    UIView *bubble = [[UIView alloc] initWithFrame:CGRectZero];
    bubble.translatesAutoresizingMaskIntoConstraints = NO;
    bubble.userInteractionEnabled = NO;
    bubble.backgroundColor = t.cInverseSurface;
    bubble.layer.cornerRadius = 18;
    bubble.layer.cornerCurve = kCACornerCurveContinuous;
    bubble.clipsToBounds = YES;
    bubble.alpha = 0;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = message;
    label.font = [A2Typography caption];
    label.textColor = t.cInverseOnSurface;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;
    // 路径类文案中间截断，头尾都能看见（尾部的文件名才是关键）
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;

    [bubble addSubview:label];
    [view addSubview:bubble];

    [NSLayoutConstraint activateConstraints:@[
        [bubble.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [bubble.bottomAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.bottomAnchor constant:-40],
        // 宽度上限：再长的文案也不会超出屏幕
        [bubble.widthAnchor constraintLessThanOrEqualToAnchor:view.widthAnchor
                                                     constant:-A2PageMargin * 2],
        [bubble.widthAnchor constraintGreaterThanOrEqualToConstant:120],
        [bubble.heightAnchor constraintGreaterThanOrEqualToConstant:36],

        [label.topAnchor constraintEqualToAnchor:bubble.topAnchor constant:A2SpaceS],
        [label.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor constant:-A2SpaceS],
        [label.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:A2SpaceL],
        [label.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-A2SpaceL],
    ]];

    [UIView animateWithDuration:kToastFadeDuration animations:^{
        bubble.alpha = 1;
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kToastVisibleDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:kToastFadeDuration animations:^{
            bubble.alpha = 0;
        } completion:^(BOOL finished) {
            [bubble removeFromSuperview];
        }];
    });
}

@end
