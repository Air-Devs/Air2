//
//  A2RelatedResourceCard.m
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

#import "A2RelatedResourceCard.h"
#import "A2ContentSource.h"
#import "A2RemoteImageView.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

@interface A2RelatedResourceCard ()
- (NSString *)formatCount:(long long)count;
@end

@implementation A2RelatedResourceCard {
    A2RemoteImageView *_iconView;
    UILabel *_titleLabel;
    UILabel *_metaLabel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = A2RadiusL;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 0.5;
    self.clipsToBounds = YES;

    _iconView = [[A2RemoteImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.cornerRadius = A2RadiusM;
    _iconView.contentMode = UIViewContentModeScaleAspectFill;
    _iconView.clipsToBounds = YES;
    [self addSubview:_iconView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [A2Typography subtitleCard];
    _titleLabel.numberOfLines = 2;
    [self addSubview:_titleLabel];

    _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metaLabel.font = [A2Typography caption];
    _metaLabel.numberOfLines = 1;
    _metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_metaLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceM],
        [_iconView.topAnchor constraintEqualToAnchor:self.topAnchor constant:A2SpaceM],
        [_iconView.widthAnchor constraintEqualToConstant:44],
        [_iconView.heightAnchor constraintEqualToConstant:44],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceM],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceM],
        [_titleLabel.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:A2SpaceS],

        [_metaLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_metaLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
        [_metaLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:A2SpaceXS],
        [_metaLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor
                                                          constant:-A2SpaceM],
    ]];

    // 卡片内部没有可点击控件，手势必须放行触摸，避免吞掉上层滚动。
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    tap.cancelsTouchesInView = NO;
    [self addGestureRecognizer:tap];

    [self applyTheme];
    return self;
}

- (void)handleTap {
    if (self.onTap) self.onTap();
}

- (void)configureWithItem:(A2ContentItem *)item {
    _titleLabel.text = item.title.length ? item.title : item.projectID;
    _metaLabel.text = item.downloadCount > 0
        ? [NSString stringWithFormat:@"%@ 次下载", [self formatCount:item.downloadCount]]
        : (item.author.length ? item.author : @"");
    _iconView.fallbackText = item.title.length ? [item.title substringToIndex:1] : nil;
    [_iconView setImageURL:item.iconURL placeholder:nil];
}

- (void)applyTheme {
    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;
    self.backgroundColor = scheme.cSurfaceContainerHigh;
    self.layer.borderColor = [scheme.cOutlineVariant colorWithAlphaComponent:0.6].CGColor;
    _titleLabel.textColor = scheme.cOnSurface;
    _metaLabel.textColor = scheme.cOnSurfaceVariant;
    [_iconView applyTheme];
}

- (NSString *)formatCount:(long long)count {
    if (count >= 1000000) return [NSString stringWithFormat:@"%.1fM", count / 1000000.0];
    if (count >= 1000) return [NSString stringWithFormat:@"%.1fk", count / 1000.0];
    return [NSString stringWithFormat:@"%lld", count];
}

@end
