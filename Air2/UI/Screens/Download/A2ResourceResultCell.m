//
//  A2ResourceResultCell.m
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
//  A2ResourceResultCell.m
//  Air2
//

#import "A2ResourceResultCell.h"
#import "A2ContentSource.h"
#import "A2ResourceCard.h"
#import "A2DownloadManifest.h"
#import "A2DownloadFavorites.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

@implementation A2ResourceResultCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _card = [[A2ResourceCard alloc] initWithFrame:CGRectZero];
    [self.contentView addSubview:_card];

    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:3],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3],
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
    ]];
    return self;
}

- (void)configureWithItem:(A2ContentItem *)item {
    [_card configureWithItem:item];
    _card.installed = [A2DownloadManifest.shared isProjectInstalled:item.projectID];
    _card.favorite = [A2DownloadFavorites.shared isFavorite:item.projectID];
}

@end
