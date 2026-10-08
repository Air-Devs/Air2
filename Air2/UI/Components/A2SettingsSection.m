//
//  A2SettingsSection.m
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

#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"

/// ZL2 的 SettingsCardColumn 用 2dp 行间距
static const CGFloat kRowSpacing = 2;

@interface A2SettingsSection ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *footerLabel;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) NSMutableArray<A2SettingsRow *> *mutableRows;
@property (nonatomic, strong) NSMutableArray<UIView *> *customViews;
@end

@implementation A2SettingsSection

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _sectionTitle = [title copy];
    _mutableRows = [NSMutableArray array];
    _customViews = [NSMutableArray array];
    [self setup];
    return self;
}

- (void)setup {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _titleLabel.text = _sectionTitle;
    _titleLabel.hidden = (_sectionTitle.length == 0);

    _stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = kRowSpacing;

    _footerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _footerLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _footerLabel.numberOfLines = 0;
    _footerLabel.hidden = YES;

    [self addSubview:_titleLabel];
    [self addSubview:_stack];
    [self addSubview:_footerLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceL],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceL],

        [_stack.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:A2SpaceS],
        [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [_footerLabel.topAnchor constraintEqualToAnchor:_stack.bottomAnchor constant:A2SpaceS],
        [_footerLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceL],
        [_footerLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceL],
        [_footerLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
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

- (NSArray<A2SettingsRow *> *)rows {
    return [_mutableRows copy];
}

- (void)setSectionTitle:(NSString *)sectionTitle {
    _sectionTitle = [sectionTitle copy];
    _titleLabel.text = sectionTitle;
    _titleLabel.hidden = (sectionTitle.length == 0);
}

- (void)setFooterText:(NSString *)footerText {
    _footerText = [footerText copy];
    _footerLabel.text = footerText;
    _footerLabel.hidden = (footerText.length == 0);
}

- (void)addRow:(A2SettingsRow *)row {
    row.cardPosition = A2CardPositionMiddle;   // 先按中间处理，收尾时统一修正
    row.showsSeparator = YES;
    [_mutableRows addObject:row];
    [_stack addArrangedSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:_stack.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:_stack.trailingAnchor],
    ]];

    [self fixupPositions];
}

- (void)addCustomView:(UIView *)view {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [_customViews addObject:view];
    [_stack addArrangedSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:_stack.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:_stack.trailingAnchor],
    ]];
    [self fixupPositions];
}

/// 重新分配首/中/末位置。
///
/// 这是「一组行拼成一张卡」的关键：只有首行的上角与末行的下角
/// 用大圆角，中间各行的四角都是小圆角。行数变化时要重算。
- (void)fixupPositions {
    NSUInteger count = _mutableRows.count;
    if (count == 0) return;

    for (NSUInteger i = 0; i < count; i++) {
        A2SettingsRow *row = _mutableRows[i];
        if (count == 1) {
            row.cardPosition = A2CardPositionSingle;
            row.showsSeparator = NO;
        } else if (i == 0) {
            row.cardPosition = A2CardPositionTop;
            row.showsSeparator = YES;
        } else if (i == count - 1) {
            row.cardPosition = A2CardPositionBottom;
            row.showsSeparator = NO;
        } else {
            row.cardPosition = A2CardPositionMiddle;
            row.showsSeparator = YES;
        }
    }
}

- (void)applyTheme {
    // 分组标题在卡片外，用较低对比的色
    _titleLabel.textColor = [A2ThemeManager.shared.scheme.cOnSurfaceVariant
                             colorWithAlphaComponent:0.85];
    _footerLabel.textColor = [A2ThemeManager.shared.scheme.cOnSurfaceVariant
                              colorWithAlphaComponent:0.7];
}

@end
