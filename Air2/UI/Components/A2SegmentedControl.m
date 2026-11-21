//
//  A2SegmentedControl.m
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

#import "A2SegmentedControl.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

/// 胶囊总高 / 内部段高。差值就是选中高亮块四周的留白。
static const CGFloat kA2SegmentedHeight = 48;
static const CGFloat kA2SegmentedInset = 2;

@interface A2SegmentedControl ()
@property (nonatomic, strong) NSArray<UIButton *> *buttons;
@property (nonatomic, strong) UISelectionFeedbackGenerator *feedback;
@end

@implementation A2SegmentedControl

- (instancetype)initWithTitles:(NSArray<NSString *> *)titles {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _selectedIndex = 0;
    _feedback = [UISelectionFeedbackGenerator new];
    [self setupWithTitles:titles];
    return self;
}

- (void)setupWithTitles:(NSArray<NSString *> *)titles {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = kA2SegmentedHeight / 2;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 1;
    self.clipsToBounds = YES;

    NSMutableArray<UIButton *> *list = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        b.tag = (NSInteger)i;
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        b.layer.cornerRadius = (kA2SegmentedHeight - kA2SegmentedInset * 2) / 2;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        b.clipsToBounds = YES;
        [b addTarget:self action:@selector(handleTap:) forControlEvents:UIControlEventTouchUpInside];
        [list addObject:b];
    }
    _buttons = [list copy];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:_buttons];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = kA2SegmentedInset;
    [self addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintEqualToConstant:kA2SegmentedHeight],
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:kA2SegmentedInset],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-kA2SegmentedInset],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kA2SegmentedInset],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-kA2SegmentedInset],
    ]];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    if (selectedIndex < 0 || selectedIndex >= (NSInteger)_buttons.count) return;
    _selectedIndex = selectedIndex;
    [self applyTheme];
}

- (void)handleTap:(UIButton *)sender {
    if (sender.tag == _selectedIndex) return;
    [_feedback selectionChanged];
    self.selectedIndex = sender.tag;
    if (self.onSegmentChange) self.onSegmentChange(sender.tag);
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    self.layer.borderColor = t.cOutline.CGColor;
    self.backgroundColor = UIColor.clearColor;

    for (UIButton *b in _buttons) {
        BOOL selected = (b.tag == _selectedIndex);
        b.backgroundColor = selected ? t.cSecondaryContainer : UIColor.clearColor;
        [b setTitleColor:(selected ? t.cOnSecondaryContainer : t.cOnSurfaceVariant)
                forState:UIControlStateNormal];
    }
}

@end
