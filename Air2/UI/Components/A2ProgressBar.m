//
//  A2ProgressBar.m
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
//  线性进度条 —— 进度 + 已下载/总量 + 实时速度。
//  头部带光晕，让进度推进有个明显的"亮头"。
//

#import "A2ProgressBar.h"
#import <math.h>
#import "A2ThemeManager.h"
#import "A2ColorScheme.h"
#import "A2Metrics.h"
#import "A2Typography.h"

/// 不确定态指示器占轨道的比例与滑动周期。
/// 周期 1.4s：足够看出「在动」，又不至于像加载动画那样抢注意力（动效克制）。
static const CGFloat A2ProgressBarIndeterminateSegmentRatio = 0.38;
static const NSTimeInterval A2ProgressBarIndeterminateDuration = 1.4;

#pragma mark - A2ProgressBar

@interface A2ProgressBar ()
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *fill;
@property (nonatomic, strong) UIView *glow;
@property (nonatomic, strong) UIView *indeterminateSegment;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *speedLabel;
@property (nonatomic, strong) NSLayoutConstraint *fillWidth;
/// 「文字行底部贴 self 底」与「轨道底部贴 self 底」两条互斥约束：
/// 默认前者（带文字），trackOnly 时切后者（只有轨道）。
@property (nonatomic, strong) NSLayoutConstraint *detailBottomToSelf;
@property (nonatomic, strong) NSLayoutConstraint *trackBottomToSelf;
/// 上一次给不确定态指示器算过的轨道宽度：宽度没变就不重启动画（否则每帧重排会抖）。
@property (nonatomic, assign) CGFloat lastIndeterminateTrackWidth;
@end

@implementation A2ProgressBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _progress = 0;

    _track = [[UIView alloc] initWithFrame:CGRectZero];
    _track.translatesAutoresizingMaskIntoConstraints = NO;
    _track.layer.cornerRadius = 3;
    _track.clipsToBounds = YES;
    [self addSubview:_track];

    _fill = [[UIView alloc] initWithFrame:CGRectZero];
    _fill.translatesAutoresizingMaskIntoConstraints = NO;
    [_track addSubview:_fill];

    // 不确定态：一段自己的指示器，用帧驱动来回滑（不参与自动布局，
    // 因为它的位置由动画决定，约束会在每次 layout 把它拽回去）。
    _indeterminateSegment = [[UIView alloc] initWithFrame:CGRectZero];
    _indeterminateSegment.layer.cornerRadius = 3;
    _indeterminateSegment.hidden = YES;
    [_track addSubview:_indeterminateSegment];

    // 进度条头部的光晕，让推进有个"亮头"
    _glow = [[UIView alloc] initWithFrame:CGRectZero];
    _glow.translatesAutoresizingMaskIntoConstraints = NO;
    _glow.layer.cornerRadius = 3;
    [_track addSubview:_glow];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.font = [A2Typography numeric];

    _speedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _speedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _speedLabel.font = [A2Typography numeric];
    _speedLabel.textAlignment = NSTextAlignmentRight;

    [self addSubview:_detailLabel];
    [self addSubview:_speedLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_track.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_track.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_track.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_track.heightAnchor constraintEqualToConstant:6],

        [_fill.topAnchor constraintEqualToAnchor:_track.topAnchor],
        [_fill.bottomAnchor constraintEqualToAnchor:_track.bottomAnchor],
        [_fill.leadingAnchor constraintEqualToAnchor:_track.leadingAnchor],

        [_glow.centerYAnchor constraintEqualToAnchor:_track.centerYAnchor],
        [_glow.widthAnchor constraintEqualToConstant:24],
        [_glow.heightAnchor constraintEqualToConstant:6],

        [_detailLabel.topAnchor constraintEqualToAnchor:_track.bottomAnchor constant:A2SpaceS],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],

        [_speedLabel.centerYAnchor constraintEqualToAnchor:_detailLabel.centerYAnchor],
        [_speedLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_speedLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_detailLabel.trailingAnchor constant:A2SpaceS],
    ]];

    _detailBottomToSelf = [_detailLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor];
    _trackBottomToSelf = [_track.bottomAnchor constraintEqualToAnchor:self.bottomAnchor];
    _detailBottomToSelf.active = YES;
    _trackBottomToSelf.active = NO;

    _fillWidth = [_fill.widthAnchor constraintEqualToConstant:0];
    _fillWidth.active = YES;

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

- (void)setDetailText:(NSString *)detailText {
    _detailText = [detailText copy];
    _detailLabel.text = detailText;
}

- (void)setSpeedText:(NSString *)speedText {
    _speedText = [speedText copy];
    _speedLabel.text = speedText;
}

- (void)setIndeterminate:(BOOL)indeterminate {
    if (_indeterminate == indeterminate) return;
    _indeterminate = indeterminate;

    _fill.hidden = indeterminate;
    _glow.hidden = indeterminate;
    _indeterminateSegment.hidden = !indeterminate;

    if (indeterminate) {
        [self layoutIfNeeded];
        [self layoutIndeterminateSegment];
    } else {
        [_indeterminateSegment.layer removeAnimationForKey:@"a2.slide"];
        _lastIndeterminateTrackWidth = 0;
        [self updateGlowPosition];
    }
}

- (void)setIndicatorColor:(UIColor *)indicatorColor {
    _indicatorColor = indicatorColor;
    [self applyTheme];
}

- (void)setTrackOnly:(BOOL)trackOnly {
    if (_trackOnly == trackOnly) return;
    _trackOnly = trackOnly;
    _detailLabel.hidden = trackOnly;
    _speedLabel.hidden = trackOnly;
    _detailBottomToSelf.active = !trackOnly;
    _trackBottomToSelf.active = trackOnly;
}

- (void)setProgress:(CGFloat)progress {
    [self setProgress:progress animated:NO];
}

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated {
    _progress = MAX(0, MIN(1, progress));
    if (_indeterminate) return;   // 不确定态不表达比例，别让约束去拽填充块
    CGFloat target = self.bounds.size.width * _progress;
    if (!animated) {
        _fillWidth.constant = target;
        [self layoutIfNeeded];
        [self updateGlowPosition];
        return;
    }
    _fillWidth.constant = target;
    [UIView animateWithDuration:A2AnimDuration
                          delay:0
         usingSpringWithDamping:0.9
          initialSpringVelocity:0.2
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ [self layoutIfNeeded]; }
                     completion:nil];
    [self updateGlowPosition];
}

- (void)updateGlowPosition {
    CGFloat x = self.track.bounds.size.width * _progress;
    _glow.center = CGPointMake(x, _track.bounds.size.height / 2);
    _glow.alpha = (_progress > 0.01 && _progress < 0.99) ? 1.0 : 0.0;
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    // 轨道与填充都用语义色：以前轨道是「白色 13% 透明」，亮色主题下压在浅底上
    // 几乎看不见，且属于「视图层写死色值」。
    UIColor *accent = _indicatorColor ?: t.cPrimary;
    _track.backgroundColor = t.cSurfaceContainerHighest;
    _fill.backgroundColor = accent;
    _indeterminateSegment.backgroundColor = accent;
    _glow.backgroundColor = [accent colorWithAlphaComponent:0.55];
    _glow.layer.shadowColor = accent.CGColor;
    _glow.layer.shadowOpacity = 0.8;
    _glow.layer.shadowRadius = 6;
    _glow.layer.shadowOffset = CGSizeZero;
    _detailLabel.textColor = t.cOnSurfaceVariant;
    _speedLabel.textColor = accent;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!_indeterminate) {
        _fillWidth.constant = self.bounds.size.width * _progress;
    }
    [self updateGlowPosition];
    [self layoutIndeterminateSegment];
}

#pragma mark - 不确定态

/// 指示器占轨道 38%，从左侧完全移出滑到右侧完全移出，线性循环。
/// 只在轨道宽度变化时重启动画：progress 刷新很频繁（100ms），
/// 每帧 remove+add 动画会让指示器「定格重来」，看起来像卡顿。
- (void)layoutIndeterminateSegment {
    if (!_indeterminate) return;

    CGFloat trackWidth = _track.bounds.size.width;
    CGFloat trackHeight = _track.bounds.size.height;
    if (trackWidth <= 0 || trackHeight <= 0) return;

    if (fabs(trackWidth - _lastIndeterminateTrackWidth) < 0.5 &&
        [_indeterminateSegment.layer animationForKey:@"a2.slide"]) {
        return;
    }
    _lastIndeterminateTrackWidth = trackWidth;

    CGFloat segmentWidth = MAX(24.0, trackWidth * A2ProgressBarIndeterminateSegmentRatio);
    _indeterminateSegment.frame = CGRectMake(0, 0, segmentWidth, trackHeight);

    CALayer *layer = _indeterminateSegment.layer;
    [layer removeAnimationForKey:@"a2.slide"];
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"position.x"];
    slide.fromValue = @(-segmentWidth * 0.5);
    slide.toValue = @(trackWidth + segmentWidth * 0.5);
    slide.duration = A2ProgressBarIndeterminateDuration;
    slide.repeatCount = HUGE_VALF;
    slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [layer addAnimation:slide forKey:@"a2.slide"];
}

@end
