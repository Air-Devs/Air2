//
//  A2VersionListViewController.m
//  Air2
//

#import "A2VersionListViewController.h"
#import "A2VersionSettingsViewController.h"
#import "A2GlassCard.h"
#import "A2VersionCard.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2VersionListViewController ()
@property (nonatomic, strong) UIView *segmentedWrap;
@property (nonatomic, strong) UISegmentedControl *sortSwitch;
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, NSString *> *> *versions;
@end

@implementation A2VersionListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"版本管理";

    [self addTrailingButtonWithSymbol:@"plus" action:^{
        [A2Toast show:@"安装新版本" inView:self.view];
    }];

    [self setupSortBar];
    [self loadVersions];
    [self buildList];
}

- (void)setupSortBar {
    _segmentedWrap = [[UIView alloc] initWithFrame:CGRectZero];
    _segmentedWrap.translatesAutoresizingMaskIntoConstraints = NO;

    _sortSwitch = [[UISegmentedControl alloc] initWithItems:@[@"最近游玩", @"名称", @"安装时间"]];
    _sortSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    _sortSwitch.selectedSegmentIndex = 0;
    [_sortSwitch addTarget:self action:@selector(sortChanged) forControlEvents:UIControlEventValueChanged];
    [_segmentedWrap addSubview:_sortSwitch];

    [NSLayoutConstraint activateConstraints:@[
        [_sortSwitch.topAnchor constraintEqualToAnchor:_segmentedWrap.topAnchor],
        [_sortSwitch.bottomAnchor constraintEqualToAnchor:_segmentedWrap.bottomAnchor],
        [_sortSwitch.leadingAnchor constraintEqualToAnchor:_segmentedWrap.leadingAnchor],
        [_sortSwitch.trailingAnchor constraintEqualToAnchor:_segmentedWrap.trailingAnchor],
    ]];

    [self addSection:_segmentedWrap];
}

- (void)sortChanged {
    UISelectionFeedbackGenerator *fb = [UISelectionFeedbackGenerator new];
    [fb selectionChanged];
    [self reloadListWithAnimation];
}

- (void)loadVersions {
    _versions = @[
        @{@"name": @"1.21.5-fabric",  @"meta": @"Fabric 0.16.10 · Java 21 · 隔离开启"},
        @{@"name": @"1.20.1-forge",   @"meta": @"Forge 47.2.0 · Java 17 · 隔离关闭"},
        @{@"name": @"1.21.5",         @"meta": @"原版 · Java 21"},
        @{@"name": @"1.7.10-forge",   @"meta": @"Forge 10.13.4.1614 · 旧版"},
    ];
}

- (void)buildList {
    for (NSDictionary<NSString *, NSString *> *v in _versions) {
        [self addSection:[self cardForVersion:v]];
    }
}

- (UIView *)cardForVersion:(NSDictionary<NSString *, NSString *> *)version {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.contentInsets = UIEdgeInsetsMake(A2SpaceL, A2SpaceL, A2SpaceL, A2SpaceL);

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    name.text = version[@"name"];
    name.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    name.textColor = t.cOnSurface;

    UILabel *meta = [[UILabel alloc] initWithFrame:CGRectZero];
    meta.translatesAutoresizingMaskIntoConstraints = NO;
    meta.text = version[@"meta"];
    meta.font = [A2Typography caption];
    meta.textColor = t.cOnSurfaceVariant;
    meta.numberOfLines = 1;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[name, meta]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 3;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];

    UIButton *launchBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    launchBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [launchBtn setImage:[UIImage systemImageNamed:@"play.circle.fill" withConfiguration:cfg]
               forState:UIControlStateNormal];
    launchBtn.tintColor = A2ThemeManager.shared.scheme.cPrimary;
    [launchBtn addAction:[UIAction actionWithHandler:^(UIAction *action) {
        [A2Toast show:[NSString stringWithFormat:@"启动 %@", version[@"name"]] inView:self.view];
    }] forControlEvents:UIControlEventTouchUpInside];

    UIButton *moreBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    moreBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [moreBtn setImage:[UIImage systemImageNamed:@"ellipsis.circle" withConfiguration:cfg]
             forState:UIControlStateNormal];
    moreBtn.tintColor = [UIColor colorWithWhite:1.0 alpha:0.66];
    [moreBtn addAction:[UIAction actionWithHandler:^(UIAction *action) {
        A2VersionSettingsViewController *vc =
            [[A2VersionSettingsViewController alloc] initWithVersionName:version[@"name"]];
        [self.navigationController pushViewController:vc animated:YES];
    }] forControlEvents:UIControlEventTouchUpInside];

    [card.contentView addSubview:textStack];
    [card.contentView addSubview:launchBtn];
    [card.contentView addSubview:moreBtn];

    [NSLayoutConstraint activateConstraints:@[
        [textStack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [textStack.centerYAnchor constraintEqualToAnchor:card.contentView.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:launchBtn.leadingAnchor constant:-A2SpaceS],
        [textStack.topAnchor constraintGreaterThanOrEqualToAnchor:card.contentView.topAnchor],

        [moreBtn.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [moreBtn.centerYAnchor constraintEqualToAnchor:card.contentView.centerYAnchor],
        [moreBtn.widthAnchor constraintEqualToConstant:34],
        [moreBtn.heightAnchor constraintEqualToConstant:34],

        [launchBtn.trailingAnchor constraintEqualToAnchor:moreBtn.leadingAnchor constant:-A2SpaceXS],
        [launchBtn.centerYAnchor constraintEqualToAnchor:card.contentView.centerYAnchor],
        [launchBtn.widthAnchor constraintEqualToConstant:34],
        [launchBtn.heightAnchor constraintEqualToConstant:34],
    ]];

    return card;
}

/// 排序切换时重建列表（带淡入动画）
- (void)reloadListWithAnimation {
    UIStackView *stack = self.contentStack;
    for (UIView *v in stack.arrangedSubviews) {
        if ([v isKindOfClass:A2GlassCard.class]) v.alpha = 0;
    }
    [self loadVersions];
    [UIView animateWithDuration:A2AnimDuration animations:^{
        for (UIView *v in stack.arrangedSubviews) v.alpha = 1;
    }];
}

@end
