//
//  A2SettingsViewController.m
//  Air2
//
//  设置页 —— 左侧分类导航 + 右侧内容。
//
//  结构对齐 ZL2 的 SettingsScreen，左侧导航用共用的 A2CategoryNavView。
//

#import "A2SettingsViewController.h"
#import "A2CategoryNavView.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

#import "A2SettingsSections.h"

@interface A2SettingsViewController ()
@property (nonatomic, strong) A2CategoryNavView *nav;
@property (nonatomic, strong) UIScrollView *contentScroll;
@property (nonatomic, strong) UIStackView *contentStack;
@end

@implementation A2SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.usesScrollContent = NO;
    self.pageTitle = @"设置";

    // 目前只有「外观」一个分类 —— 其余等对应功能实现后再加。
    // 见 A2SettingsSections.h 的说明。
    NSArray<A2NavCategory *> *cats = @[
        [A2NavCategory title:@"外观" symbol:@"paintpalette.fill"],
    ];

    __weak typeof(self) weakSelf = self;
    _nav = [[A2CategoryNavView alloc] initWithCategories:cats];
    _nav.onSelect = ^(NSInteger index) {
        __strong typeof(weakSelf) self = weakSelf;
        [self rebuildContentForIndex:index];
    };
    [self.plainContentView addSubview:_nav];

    _contentScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _contentScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _contentScroll.showsVerticalScrollIndicator = NO;
    _contentScroll.alwaysBounceVertical = YES;
    [self.plainContentView addSubview:_contentScroll];

    _contentStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    _contentStack.axis = UILayoutConstraintAxisVertical;
    _contentStack.spacing = A2SpaceXL;
    [_contentScroll addSubview:_contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [_nav.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_nav.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_nav.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                           constant:A2SpaceS],

        [_contentScroll.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_contentScroll.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_contentScroll.leadingAnchor constraintEqualToAnchor:_nav.trailingAnchor
                                                    constant:A2SpaceM],
        [_contentScroll.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],

        [_contentStack.topAnchor constraintEqualToAnchor:_contentScroll.topAnchor constant:A2SpaceS],
        [_contentStack.bottomAnchor constraintEqualToAnchor:_contentScroll.bottomAnchor
                                                   constant:-A2SpaceXXL],
        [_contentStack.leadingAnchor constraintEqualToAnchor:_contentScroll.leadingAnchor
                                                    constant:A2SpaceM],
        [_contentStack.trailingAnchor constraintEqualToAnchor:_contentScroll.trailingAnchor
                                                     constant:-A2SpaceXL],
    ]];

    [_nav selectIndex:0 animated:NO];
}

- (void)rebuildContentForIndex:(NSInteger)index {
    for (UIView *v in _contentStack.arrangedSubviews) {
        [_contentStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    if (index == 0) {
        [_contentStack addArrangedSubview:[A2AppearanceSettings buildWithHost:self]];
        [_contentStack addArrangedSubview:[A2AppearanceSettings buildSourceSectionWithHost:self]];
    }

    // 内容切换时淡入上浮
    _contentStack.alpha = 0;
    _contentStack.transform = CGAffineTransformMakeTranslation(0, 8);
    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationCard);
    [a addAnimations:^{
        self.contentStack.alpha = 1;
        self.contentStack.transform = CGAffineTransformIdentity;
    }];
    [a startAnimation];
}

@end
