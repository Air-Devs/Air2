//
//  A2ResourceVersionCell.m
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

#import "A2ResourceVersionCell.h"
#import "A2ContentSource.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

#pragma mark - 带内边距的标签

/// MD3 的小徽标需要左右留白，UILabel 默认贴着文字边，
/// 直接设圆角会显得字被切掉，所以统一包一层内边距。
@interface A2InsetLabel : UILabel
@property (nonatomic, assign) UIEdgeInsets textInsets;
@end

@implementation A2InsetLabel

- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, self.textInsets)];
}

- (CGSize)intrinsicContentSize {
    CGSize size = [super intrinsicContentSize];
    return CGSizeMake(size.width + self.textInsets.left + self.textInsets.right,
                      size.height + self.textInsets.top + self.textInsets.bottom);
}

@end

#pragma mark - 版本行

@implementation A2ResourceVersionCell {
    UIView *_container;
    UILabel *_versionLabel;
    UILabel *_metaLabel;
    A2InsetLabel *_badgeLabel;
    UIImageView *_trailingView;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _container = [[UIView alloc] initWithFrame:CGRectZero];
    _container.translatesAutoresizingMaskIntoConstraints = NO;
    _container.layer.cornerRadius = A2RadiusM;
    _container.layer.cornerCurve = kCACornerCurveContinuous;
    _container.layer.borderWidth = 0.5;
    [self.contentView addSubview:_container];

    _versionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionLabel.font = [A2Typography subtitleCard];
    _versionLabel.numberOfLines = 1;
    [_container addSubview:_versionLabel];

    _badgeLabel = [[A2InsetLabel alloc] initWithFrame:CGRectZero];
    _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _badgeLabel.font = [A2Typography caption];
    _badgeLabel.text = @"最新";
    _badgeLabel.textAlignment = NSTextAlignmentCenter;
    _badgeLabel.textInsets = UIEdgeInsetsMake(2, A2SpaceS, 2, A2SpaceS);
    _badgeLabel.layer.cornerRadius = A2RadiusS;
    _badgeLabel.layer.cornerCurve = kCACornerCurveContinuous;
    _badgeLabel.layer.masksToBounds = YES;
    [_container addSubview:_badgeLabel];

    _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metaLabel.font = [A2Typography caption];
    _metaLabel.numberOfLines = 1;
    _metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_container addSubview:_metaLabel];

    _trailingView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _trailingView.translatesAutoresizingMaskIntoConstraints = NO;
    _trailingView.contentMode = UIViewContentModeCenter;
    [_container addSubview:_trailingView];

    [NSLayoutConstraint activateConstraints:@[
        [_container.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                  constant:A2PageMargin],
        [_container.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                   constant:-A2PageMargin],
        [_container.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                             constant:A2SpaceXS],
        [_container.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                                constant:-A2SpaceXS],

        [_versionLabel.leadingAnchor constraintEqualToAnchor:_container.leadingAnchor
                                                    constant:A2SpaceL],
        [_versionLabel.topAnchor constraintEqualToAnchor:_container.topAnchor
                                                constant:A2SpaceM],
        [_badgeLabel.leadingAnchor constraintEqualToAnchor:_versionLabel.trailingAnchor
                                                  constant:A2SpaceS],
        [_badgeLabel.centerYAnchor constraintEqualToAnchor:_versionLabel.centerYAnchor],
        [_badgeLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_trailingView.leadingAnchor
                                                             constant:-A2SpaceS],

        [_metaLabel.leadingAnchor constraintEqualToAnchor:_versionLabel.leadingAnchor],
        [_metaLabel.topAnchor constraintEqualToAnchor:_versionLabel.bottomAnchor
                                             constant:A2SpaceXS / 2],
        [_metaLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_trailingView.leadingAnchor
                                                           constant:-A2SpaceS],

        [_trailingView.trailingAnchor constraintEqualToAnchor:_container.trailingAnchor
                                                     constant:-A2SpaceL],
        [_trailingView.centerYAnchor constraintEqualToAnchor:_container.centerYAnchor],
        [_trailingView.widthAnchor constraintEqualToConstant:20],
        [_trailingView.heightAnchor constraintEqualToConstant:20],
    ]];
    [self applyTheme];
    return self;
}

- (void)configureWithVersion:(A2ContentVersion *)version
                    sizeText:(NSString *)sizeText
                      latest:(BOOL)latest
                   installed:(BOOL)installed {
    _versionLabel.text = version.versionNumber;
    NSMutableArray<NSString *> *bits = [NSMutableArray array];
    if (version.loaders.count) [bits addObject:version.loaders.firstObject];
    if (sizeText.length) [bits addObject:sizeText];
    if (version.gameVersions.count) {
        [bits addObject:[version.gameVersions componentsJoinedByString:@", "]];
    }
    _metaLabel.text = [bits componentsJoinedByString:@" · "];
    _badgeLabel.hidden = !latest;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    NSString *symbol = installed ? @"checkmark.circle.fill" : @"chevron.right";
    _trailingView.image = [UIImage systemImageNamed:symbol withConfiguration:cfg];
    _trailingView.tintColor = installed
        ? A2ThemeManager.shared.scheme.cPrimary
        : A2ThemeManager.shared.scheme.cOnSurfaceVariant;
}

- (void)applyTheme {
    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;
    _container.backgroundColor = scheme.cSurfaceContainerLow;
    _container.layer.borderColor = [scheme.cOutlineVariant colorWithAlphaComponent:0.6].CGColor;
    _versionLabel.textColor = scheme.cOnSurface;
    _metaLabel.textColor = scheme.cOnSurfaceVariant;
    _badgeLabel.textColor = scheme.cOnSecondaryContainer;
    _badgeLabel.backgroundColor = scheme.cSecondaryContainer;
}

@end
