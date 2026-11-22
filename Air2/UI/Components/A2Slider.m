//
//  A2Slider.m
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
//
//  A2Slider.m
//  Air2
//

#import "A2Slider.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

static const CGFloat kTrackHeight = 6;
static const CGFloat kThumbWidth = 3;
static const CGFloat kPillHeight = 36;

@interface A2Slider () {
    /// 已选部分的宽度约束
    NSLayoutConstraint *_fillWidth;
}
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *fill;
@property (nonatomic, strong) UIView *thumb;

// 数值胶囊
@property (nonatomic, strong) UIView *pill;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UIButton *minusButton;
@property (nonatomic, strong) UIButton *plusButton;

@property (nonatomic, strong) UISelectionFeedbackGenerator *feedback;
@property (nonatomic, assign) BOOL dragging;
@end

@implementation A2Slider

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self setup];
    return self;
}

- (void)setup {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _minimumValue = 0;
    _maximumValue = 100;
    _value = 0;
    _step = 1;
    _feedback = [UISelectionFeedbackGenerator new];

    // ---- 轨道 ----
    _track = [[UIView alloc] initWithFrame:CGRectZero];
    _track.translatesAutoresizingMaskIntoConstraints = NO;
    _track.layer.cornerRadius = kTrackHeight / 2;
    _track.clipsToBounds = YES;
    [self addSubview:_track];

    _fill = [[UIView alloc] initWithFrame:CGRectZero];
    _fill.translatesAutoresizingMaskIntoConstraints = NO;
    [_track addSubview:_fill];

    // 滑块：细长竖条（ZL2 就是这么做的，不是圆点）
    _thumb = [[UIView alloc] initWithFrame:CGRectZero];
    _thumb.translatesAutoresizingMaskIntoConstraints = NO;
    _thumb.layer.cornerRadius = kThumbWidth / 2;
    [self addSubview:_thumb];

    // ---- 数值胶囊 ----
    _pill = [[UIView alloc] initWithFrame:CGRectZero];
    _pill.translatesAutoresizingMaskIntoConstraints = NO;
    _pill.layer.cornerRadius = kPillHeight / 2;
    _pill.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_pill];

    _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    _valueLabel.textAlignment = NSTextAlignmentCenter;
    [_pill addSubview:_valueLabel];

    _minusButton = [self makeStepButton:@"chevron.left" action:@selector(stepDown)];
    _plusButton = [self makeStepButton:@"chevron.right" action:@selector(stepUp)];
    [_pill addSubview:_minusButton];
    [_pill addSubview:_plusButton];

    [NSLayoutConstraint activateConstraints:@[
        // 轨道：左侧留给滑杆，右侧留给胶囊
        [_track.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_track.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_track.heightAnchor constraintEqualToConstant:kTrackHeight],
        [_track.trailingAnchor constraintEqualToAnchor:_pill.leadingAnchor constant:-A2SpaceM],

        [_fill.topAnchor constraintEqualToAnchor:_track.topAnchor],
        [_fill.bottomAnchor constraintEqualToAnchor:_track.bottomAnchor],
        [_fill.leadingAnchor constraintEqualToAnchor:_track.leadingAnchor],

        [_pill.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_pill.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_pill.heightAnchor constraintEqualToConstant:kPillHeight],
        [_pill.widthAnchor constraintGreaterThanOrEqualToConstant:120],

        [_valueLabel.centerXAnchor constraintEqualToAnchor:_pill.centerXAnchor],
        [_valueLabel.centerYAnchor constraintEqualToAnchor:_pill.centerYAnchor],
        [_valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_minusButton.trailingAnchor
                                                               constant:4],
        [_valueLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_plusButton.leadingAnchor
                                                             constant:-4],

        [_minusButton.leadingAnchor constraintEqualToAnchor:_pill.leadingAnchor constant:6],
        [_minusButton.centerYAnchor constraintEqualToAnchor:_pill.centerYAnchor],
        [_minusButton.widthAnchor constraintEqualToConstant:24],
        [_minusButton.heightAnchor constraintEqualToConstant:24],

        [_plusButton.trailingAnchor constraintEqualToAnchor:_pill.trailingAnchor constant:-6],
        [_plusButton.centerYAnchor constraintEqualToAnchor:_pill.centerYAnchor],
        [_plusButton.widthAnchor constraintEqualToConstant:24],
        [_plusButton.heightAnchor constraintEqualToConstant:24],

        [self.heightAnchor constraintEqualToConstant:kPillHeight],
    ]];

    _fillWidth = [_fill.widthAnchor constraintEqualToConstant:0];
    _fillWidth.active = YES;

    // 滑动手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [_track addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [_track addGestureRecognizer:tap];
    _track.userInteractionEnabled = YES;

    [self applyTheme];
    [self updateUIAnimated:NO];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UIButton *)makeStepButton:(NSString *)symbol action:(SEL)action {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - 值

- (void)setMinimumValue:(CGFloat)minimumValue {
    _minimumValue = minimumValue;
    [self updateUIAnimated:NO];
}

- (void)setMaximumValue:(CGFloat)maximumValue {
    _maximumValue = maximumValue;
    [self updateUIAnimated:NO];
}

- (void)setValue:(CGFloat)value {
    [self setValue:value animated:NO];
}

- (void)setValue:(CGFloat)value animated:(BOOL)animated {
    _value = MAX(_minimumValue, MIN(_maximumValue, value));
    [self updateUIAnimated:animated];
}

- (void)setValueFormat:(NSString *)valueFormat {
    _valueFormat = [valueFormat copy];
    [self updateUIAnimated:NO];
}

- (NSString *)displayText {
    if (_valueFormat.length) {
        return [NSString stringWithFormat:_valueFormat, _value];
    }
    // 整数就不显示小数
    if (fabs(_value - round(_value)) < 0.001) {
        return [NSString stringWithFormat:@"%.0f", _value];
    }
    return [NSString stringWithFormat:@"%.1f", _value];
}

- (void)updateUIAnimated:(BOOL)animated {
    [self.superview layoutIfNeeded];

    CGFloat range = _maximumValue - _minimumValue;
    CGFloat ratio = (range > 0) ? ((_value - _minimumValue) / range) : 0;

    CGFloat trackWidth = _track.bounds.size.width;
    CGFloat targetWidth = trackWidth * ratio;

    _valueLabel.text = [self displayText];

    if (!animated) {
        _fillWidth.constant = targetWidth;
        [self layoutIfNeeded];
        [self positionThumb];
        return;
    }

    _fillWidth.constant = targetWidth;
    [UIView animateWithDuration:A2AnimDurationFast animations:^{
        [self layoutIfNeeded];
    }];
    [self positionThumb];
}

- (void)positionThumb {
    CGFloat trackWidth = _track.bounds.size.width;
    CGFloat range = _maximumValue - _minimumValue;
    CGFloat ratio = (range > 0) ? ((_value - _minimumValue) / range) : 0;
    CGFloat x = trackWidth * ratio;

    CGPoint center = [_track convertPoint:CGPointMake(x, _track.bounds.size.height / 2)
                                   toView:self];
    _thumb.center = center;
}

#pragma mark - 交互

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (_track.bounds.size.width <= 0) return;

    if (pan.state == UIGestureRecognizerStateBegan) {
        _dragging = YES;
        [_thumb setHidden:NO];
    }

    CGPoint p = [pan locationInView:_track];
    CGFloat ratio = MAX(0, MIN(1, p.x / _track.bounds.size.width));
    CGFloat newValue = _minimumValue + ratio * (_maximumValue - _minimumValue);

    // 按 step 吸附
    if (_step > 0) {
        newValue = round(newValue / _step) * _step;
    }

    if (fabs(newValue - _value) > 0.001) {
        _value = newValue;
        [self updateUIAnimated:NO];
        if (self.onValueChange) self.onValueChange(_value);
    }

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        _dragging = NO;
        [_feedback selectionChanged];
    }
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    if (_track.bounds.size.width <= 0) return;
    CGPoint p = [tap locationInView:_track];
    CGFloat ratio = MAX(0, MIN(1, p.x / _track.bounds.size.width));
    CGFloat newValue = _minimumValue + ratio * (_maximumValue - _minimumValue);
    if (_step > 0) newValue = round(newValue / _step) * _step;

    [self setValue:newValue animated:YES];
    [_feedback selectionChanged];
    if (self.onValueChange) self.onValueChange(_value);
}

- (void)stepUp {
    [self setValue:_value + _step animated:YES];
    [_feedback selectionChanged];
    if (self.onValueChange) self.onValueChange(_value);
}

- (void)stepDown {
    [self setValue:_value - _step animated:YES];
    [_feedback selectionChanged];
    if (self.onValueChange) self.onValueChange(_value);
}

#pragma mark - 布局与主题

- (void)layoutSubviews {
    [super layoutSubviews];
    _fillWidth.constant = _track.bounds.size.width *
        ((_maximumValue - _minimumValue) > 0
         ? ((_value - _minimumValue) / (_maximumValue - _minimumValue)) : 0);
    [self positionThumb];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    _track.backgroundColor = [t.cPrimary colorWithAlphaComponent:0.2];
    _fill.backgroundColor = t.cPrimary;
    _thumb.backgroundColor = t.cPrimary;

    // 数值胶囊：主色底，与滑杆呼应
    _pill.backgroundColor = t.cPrimary;
    _valueLabel.textColor = t.cOnPrimary;
    _minusButton.tintColor = t.cOnPrimary;
    _plusButton.tintColor = t.cOnPrimary;

    _valueLabel.text = [self displayText];
}

@end
