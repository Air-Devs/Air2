//
//  A2RootViewController.m
//  Air2
//

#import "A2RootViewController.h"
#import "A2HomeViewController.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

@interface A2RootViewController ()
@property (nonatomic, strong) A2HomeViewController *home;
@property (nonatomic, strong, nullable) UIViewController *current;
@end

@implementation A2RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    _home = [[A2HomeViewController alloc] init];
    [self addChildViewController:_home];
    _home.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_home.view];
    [NSLayoutConstraint activateConstraints:@[
        [_home.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_home.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_home.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_home.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
    [_home didMoveToParentViewController:self];
    _current = _home;

    // 状态栏跟随背景：深色渐变背景上要浅色文字
    [self setNeedsStatusBarAppearanceUpdate];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (BOOL)prefersStatusBarHidden {
    return NO;
}

@end
