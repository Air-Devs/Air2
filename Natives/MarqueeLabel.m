//
//  MarqueeLabel.m
//
//  Copyright (C) 2011-2015 Charles Powell
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#import "MarqueeLabel.h"

@interface MarqueeLabel()

@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, assign) BOOL isScrolling;
@property (nonatomic, assign, readwrite) BOOL isPaused;
@property (nonatomic, assign) CGFloat scrollDuration;
@property (nonatomic, assign) CGFloat AwayFromHome;
@property (nonatomic, weak) UITapGestureRecognizer *tapRecognizer;

@end


@implementation MarqueeLabel

@dynamic text, font, textColor;

#pragma mark -
#pragma mark Initialization

- (id)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame rate:60.0 andFadeLength:10.0];
}

- (id)initWithFrame:(CGRect)frame rate:(CGFloat)rate andFadeLength:(CGFloat)fadeLength {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupWithRate:rate andFadeLength:fadeLength];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        [self setupWithRate:60.0 andFadeLength:10.0];
    }
    return self;
}

- (void)setupWithRate:(CGFloat)rate andFadeLength:(CGFloat)fadeLength {
    self.subLabel = [[UILabel alloc] initWithFrame:self.bounds];
    self.subLabel.tag = 700;
    self.subLabel.layer.anchorPoint = CGPointMake(0.0f, 0.0f);

    [self addSubview:self.subLabel];

    self.marqueeType = MLContinuous;
    self.clipsToBounds = YES;
    self.rate = rate;
    self.animationDelay = 1.0;
    self.fadeLength = fadeLength;
    self.leadingBuffer = 0.0f;
    self.trailingBuffer = 0.0f;
    self.isScrolling = NO;
    self.isPaused = NO;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(labelTapped:)];
    tap.numberOfTapsRequired = 1;
    [self addGestureRecognizer:tap];
    self.tapRecognizer = tap;
}

- (void)awakeFromNib {
    [super awakeFromNib];
    [self forwardPropertiesToSubLabel];
}


#pragma mark -
#pragma mark Marquee Animation


- (void)restartLabel {
    [self.subLabel.layer removeAllAnimations];
    self.isScrolling = NO;

    if ([self isLabelReadyForScroll]) {
        [self scrollContinuous];
    }
}

- (void)resetLabel {
    [self.subLabel.layer removeAllAnimations];
    self.subLabel.frame = self.bounds;
    self.isScrolling = NO;
}

- (void)pauseLabel {
    if (!self.isScrolling) {
        return;
    }

    self.isPaused = YES;

    // Pause animation
    CFTimeInterval pausedTime = [self.subLabel.layer convertTime:CACurrentMediaTime() fromLayer:nil];
    self.subLabel.layer.speed = 0.0;
    self.subLabel.layer.timeOffset = pausedTime;

    self.AwayFromHome = self.subLabel.layer.presentationLayer.position.x;
}

- (void)unpauseLabel {
    if (!self.isScrolling || !self.isPaused) {
        return;
    }

    // Unpause animation
    CALayer *sublayer = self.subLabel.layer;
    CFTimeInterval pausedTime = sublayer.timeOffset;
    sublayer.speed = 1.0;
    sublayer.timeOffset = 0.0;
    self.subLabel.layer.beginTime = 0.0;
    CFTimeInterval timeSincePause = [self.subLabel.layer convertTime:CACurrentMediaTime() fromLayer:nil] - pausedTime;
    self.subLabel.layer.beginTime = timeSincePause;

    self.isPaused = NO;
}

- (void)labelTapped:(UITapGestureRecognizer *)recognizer {
    if (self.isScrolling) {
        if (self.isPaused) {
            [self unpauseLabel];
        } else {
            [self pauseLabel];
        }
    }
}

- (BOOL)isLabelReadyForScroll {
    if (self.marqueeType == MLContinuous && self.subLabel.bounds.size.width <= self.bounds.size.width) {
        return NO;
    }

    return YES;
}

- (void)scrollContinuous {
    if (!self.isScrolling) {
        self.isScrolling = YES;
        self.subLabel.frame = CGRectMake(self.leadingBuffer, 0, self.subLabel.bounds.size.width, self.bounds.size.height);

        self.scrollDuration = (self.subLabel.bounds.size.width / self.rate);

        [UIView animateWithDuration:self.scrollDuration
                              delay:self.animationDelay
                            options:UIViewAnimationOptionCurveLinear | UIViewAnimationOptionRepeat
                         animations:^{
                             self.subLabel.frame = CGRectMake(-(self.subLabel.bounds.size.width + self.trailingBuffer), 0, self.subLabel.bounds.size.width, self.bounds.size.height);
                         }
                         completion:^(BOOL finished) {
                             if (finished) {
                                 self.isScrolling = NO;
                             }
                         }];
    }
}

- (void)didMoveToSuperview {
    if (self.superview) {
        [self restartLabel];
    } else {
        [self pauseLabel];
    }
}

- (void)willMoveToSuperview:(UIView *)newSuperview {
    if (!newSuperview) {
        [self pauseLabel];
    }
}

#pragma mark -
#pragma mark UILabel Property Forwarding

- (void)forwardPropertiesToSubLabel {
    self.subLabel.text = super.text;
    self.subLabel.font = super.font;
    self.subLabel.textColor = super.textColor;
    self.subLabel.backgroundColor = super.backgroundColor;
    self.subLabel.shadowColor = super.shadowColor;
    self.subLabel.shadowOffset = super.shadowOffset;
    self.subLabel.textAlignment = super.textAlignment;
    self.subLabel.attributedText = super.attributedText;
    self.subLabel.highlightedTextColor = super.highlightedTextColor;
    self.subLabel.highlighted = super.highlighted;
    self.subLabel.enabled = super.enabled;
    self.subLabel.numberOfLines = super.numberOfLines;
    self.subLabel.adjustsFontSizeToFitWidth = super.adjustsFontSizeToFitWidth;
    self.subLabel.minimumScaleFactor = super.minimumScaleFactor;
    self.subLabel.baselineAdjustment = super.baselineAdjustment;
}

- (void)setText:(NSString *)text {
    if (![text isEqualToString:super.text]) {
        super.text = text;
        self.subLabel.text = text;
        [self.subLabel sizeToFit];
        [self restartLabel];
    }
}

- (void)setFont:(UIFont *)font {
    if (![font isEqual:super.font]) {
        super.font = font;
        self.subLabel.font = font;
        [self.subLabel sizeToFit];
        [self restartLabel];
    }
}

- (void)setTextColor:(UIColor *)textColor {
    if (![textColor isEqual:super.textColor]) {
        super.textColor = textColor;
        self.subLabel.textColor = textColor;
    }
}

// ... Add forwarding for all other UILabel properties ...

@end
