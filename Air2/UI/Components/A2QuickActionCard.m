//
//  A2QuickActionCard.m
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

#import "A2QuickActionCard.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2QuickActionCard ()
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *label;
@end

@implementation A2QuickActionCard

- (instancetype)initWithTitle:(NSString *)title symbolName:(NSString *)symbolName {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _title = [title copy];
    _symbolName = [symbolName copy];
    [self setupContent];
    return self;
}

- (void)setupContent {
    self.cornerRadius = A2RadiusL;
    self.tappable = YES;
    self.contentInsets = UIEdgeInsetsMake(A2SpaceM, A2SpaceS, A2SpaceM, A2SpaceS);

    __weak typeof(self) weakSelf = self;
    self.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self.onSelect) self.onSelect();
    };

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightMedium];

    _iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:_symbolName withConfiguration:cfg]];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;

    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.text = _title;
    _label.font = [A2Typography caption];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.adjustsFontSizeToFitWidth = YES;
    _label.minimumScaleFactor = 0.8;

    [self.contentView addSubview:_iconView];
    [self.contentView addSubview:_label];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:A2SpaceS],
        [_iconView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:24],
        [_iconView.heightAnchor constraintEqualToConstant:24],

        [_label.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:A2SpaceS],
        [_label.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_label.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_label.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-A2SpaceS],
    ]];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    _label.text = title;
}

- (void)setSymbolName:(NSString *)symbolName {
    _symbolName = [symbolName copy];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightMedium];
    _iconView.image = [UIImage systemImageNamed:symbolName withConfiguration:cfg];
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _iconView.tintColor = A2ThemeManager.shared.scheme.cPrimary;
    _label.textColor = t.cOnSurface;
}

@end
