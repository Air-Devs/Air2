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
