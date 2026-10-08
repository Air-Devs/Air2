//
//  A2RingProgress.m
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
//  环形进度 —— 单个任务的进度展示（如版本安装）。
//

#import "A2RingProgress.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"


#pragma mark - A2RingProgress

@interface A2RingProgress ()
@property (nonatomic, strong) CAShapeLayer *trackLayer;
@property (nonatomic, strong) CAShapeLayer *progressLayer;
@property (nonatomic, strong) UILabel *centerLabel;
@property (nonatomic, strong) UILabel *captionLabel;
@end

@implementation A2RingProgress

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _lineWidth = 6;
    _progress = 0;

    _trackLayer = [CAShapeLayer layer];
    _trackLayer.fillColor = UIColor.clearColor.CGColor;
    _trackLayer.lineWidth = _lineWidth;
    _trackLayer.lineCap = kCALineCapRound;
    [self.layer addSublayer:_trackLayer];

    _progressLayer = [CAShapeLayer layer];
    _progressLayer.fillColor = UIColor.clearColor.CGColor;
    _progressLayer.lineWidth = _lineWidth;
    _progressLayer.lineCap = kCALineCapRound;
    _progressLayer.strokeEnd = 0;
    // 从 12 点方向顺时针
    _progressLayer.transform = CATransform3DMakeRotation(-M_PI_2, 0, 0, 1);
    [self.layer addSublayer:_progressLayer];

    _centerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _centerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _centerLabel.font = [UIFont monospacedDigitSystemFontOfSize:20 weight:UIFontWeightSemibold];
    _centerLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_centerLabel];

    _captionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _captionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _captionLabel.font = [A2Typography caption];
    _captionLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_captionLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_centerLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_centerLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-6],
        [_captionLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_captionLabel.topAnchor constraintEqualToAnchor:_centerLabel.bottomAnchor constant:2],
    ]];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setLineWidth:(CGFloat)lineWidth {
    _lineWidth = lineWidth;
    _trackLayer.lineWidth = lineWidth;
    _progressLayer.lineWidth = lineWidth;
    [self setNeedsLayout];
}

- (void)setCenterText:(NSString *)centerText {
    _centerText = [centerText copy];
    _centerLabel.text = centerText;
}

- (void)setCaptionText:(NSString *)captionText {
    _captionText = [captionText copy];
    _captionLabel.text = captionText;
}

- (void)setProgress:(CGFloat)progress {
    [self setProgress:progress animated:NO];
}

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated {
    _progress = MAX(0, MIN(1, progress));
    if (animated) {
        // strokeEnd 是隐式动画属性，用 CATransaction 控制时长
        [CATransaction begin];
        [CATransaction setAnimationDuration:A2AnimDuration];
        [CATransaction setAnimationTimingFunction:
            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
        _progressLayer.strokeEnd = _progress;
        [CATransaction commit];
    } else {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _progressLayer.strokeEnd = _progress;
        [CATransaction commit];
    }
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _trackLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    _progressLayer.strokeColor = t.cPrimary.CGColor;
    _centerLabel.textColor = t.cOnSurface;
    _captionLabel.textColor = t.cOnSurfaceVariant;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(self.bounds.size.width / 2,
                                                                          self.bounds.size.height / 2)
                                                        radius:(MIN(self.bounds.size.width, self.bounds.size.height) - _lineWidth) / 2
                                                    startAngle:0
                                                      endAngle:M_PI * 2
                                                     clockwise:YES];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _trackLayer.path = path.CGPath;
    _progressLayer.path = path.CGPath;
    _trackLayer.frame = self.bounds;
    _progressLayer.frame = self.bounds;
    [CATransaction commit];
}

@end

