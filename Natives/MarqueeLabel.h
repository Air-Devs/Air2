// MarqueeLabel.h
//
// Copyright (C) 2011-2015 Charles Powell
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import <UIKit/UIKit.h>

//! Project version number for MarqueeLabel.
FOUNDATION_EXPORT double MarqueeLabelVersionNumber;

//! Project version string for MarqueeLabel.
FOUNDATION_EXPORT const unsigned char MarqueeLabelVersionString[];

#if __has_feature(nullability) // Nullability Memes
#define MARQUEE_LABEL_NULLABLE_PROPERTY nullable
#define MARQUEE_LABEL_NONNULL_PROPERTY nonnull
#define MARQUEE_LABEL_NULLABLE __nullable
#define MARQUEE_LABEL_NONNULL __nonnull
#else
#define MARQUEE_LABEL_NULLABLE_PROPERTY
#define MARQUEE_LABEL_NONNULL_PROPERTY
#define MARQUEE_LABEL_NULLABLE
#define MARQUEE_LABEL_NONNULL
#endif

typedef NS_ENUM(NSUInteger, MarqueeType) {
    MLContinuous,      // Scrolls continuously, from right to left, repeating for the length of the label.
    MLRightLeft,       // Scrolls from right to left, and then resets to the right for the next scroll.
    MLLeftRight        // Scrolls from left to right, and then resets to the left for the next scroll.
};

IB_DESIGNABLE
@interface MarqueeLabel : UILabel

// Marquee Animation
@property (nonatomic, assign) IBInspectable MarqueeType marqueeType;
@property (nonatomic, assign) IBInspectable CGFloat rate;
@property (nonatomic, assign) IBInspectable CGFloat animationDelay;
@property (nonatomic, assign) IBInspectable CGFloat animationDuration;
@property (nonatomic, assign, readonly) BOOL isPaused;

// Fading
@property (nonatomic, assign) IBInspectable CGFloat fadeLength;
@property (nonatomic, assign) IBInspectable CGFloat leadingBuffer;
@property (nonatomic, assign) IBInspectable CGFloat trailingBuffer;

// Animation Control
- (void)pauseLabel;
- (void)unpauseLabel;
- (void)restartLabel;
- (void)resetLabel;
- (BOOL)isLabelReadyForScroll;

// UILabel Features
@property (MARQUEE_LABEL_NONNULL_PROPERTY, nonatomic, copy) NSString *text;
@property (MARQUEE_LABEL_NONNULL_PROPERTY, nonatomic, strong) UIFont *font;
@property (MARQUEE_LABEL_NONNULL_PROPERTY, nonatomic, strong) UIColor *textColor;

@end
