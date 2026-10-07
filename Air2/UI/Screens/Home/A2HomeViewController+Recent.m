//
//  A2HomeViewController+Recent.m
//  Air2
//
//  「最近游玩」区块。单独拆出来是因为它将来要接 Core 层的版本列表，
//  逻辑量会随排序、过滤、持久化增长，混在主页文件里迟早超行数上限。
//

#import "A2HomeViewController_Internal.h"
#import "A2VersionCard.h"
#import "A2GlassCard.h"
#import "A2CardTitleBar.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@implementation A2HomeViewController (Recent)

- (void)setupRecentCard {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.contentInsets = UIEdgeInsetsZero;
    self.recentCard = card;

    A2CardTitleBar *title = [[A2CardTitleBar alloc] initWithTitle:@"最近游玩"];
    title.subtitle = @"左右滑动查看全部";

    UIScrollView *hScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    hScroll.translatesAutoresizingMaskIntoConstraints = NO;
    hScroll.showsHorizontalScrollIndicator = NO;

    UIStackView *hStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    hStack.translatesAutoresizingMaskIntoConstraints = NO;
    hStack.axis = UILayoutConstraintAxisHorizontal;
    hStack.spacing = A2SpaceS;
    [hScroll addSubview:hStack];

    // 示例数据，待接 Core 层
    NSArray<NSArray<NSString *> *> *samples = @[
        @[@"1.21.5", @"Fabric · 2 小时前"],
        @[@"1.20.1", @"Forge · 昨天"],
        @[@"1.21.5", @"原版 · 3 天前"],
    ];
    for (NSArray<NSString *> *s in samples) {
        A2VersionCard *vc = [[A2VersionCard alloc] initWithVersionName:s[0] meta:s[1]];
        [vc.widthAnchor constraintEqualToConstant:150].active = YES;
        [hStack addArrangedSubview:vc];
    }

    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:hScroll];

    [NSLayoutConstraint activateConstraints:@[
        [hScroll.topAnchor constraintEqualToAnchor:body.topAnchor constant:A2SpaceS],
        [hScroll.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-A2SpaceL],
        [hScroll.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:A2SpaceL],
        [hScroll.trailingAnchor constraintEqualToAnchor:body.trailingAnchor],

        [hStack.topAnchor constraintEqualToAnchor:hScroll.topAnchor],
        [hStack.bottomAnchor constraintEqualToAnchor:hScroll.bottomAnchor],
        [hStack.leadingAnchor constraintEqualToAnchor:hScroll.leadingAnchor],
        [hStack.trailingAnchor constraintEqualToAnchor:hScroll.trailingAnchor constant:-A2SpaceL],
        [hStack.heightAnchor constraintEqualToAnchor:hScroll.heightAnchor],
    ]];

    UIStackView *outer = [[UIStackView alloc] initWithArrangedSubviews:@[title, body]];
    outer.translatesAutoresizingMaskIntoConstraints = NO;
    outer.axis = UILayoutConstraintAxisVertical;
    outer.spacing = 0;
    [card.contentView addSubview:outer];

    [NSLayoutConstraint activateConstraints:@[
        [outer.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [outer.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [outer.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [outer.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [self.contentStack addArrangedSubview:card];
}

@end
