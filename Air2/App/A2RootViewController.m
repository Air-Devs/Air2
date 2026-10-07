//
//  A2RootViewController.m
//  Air2
//
//  根容器 —— 承载导航栈与全局浮层（任务抽屉）。
//  同时负责方向锁定，保证从启动器到游戏全程横屏。
//

#import "A2RootViewController.h"
#import "A2LauncherViewController.h"
#import "A2NavigationController.h"
#import "A2TaskDrawer.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

@interface A2RootViewController ()
@property (nonatomic, strong) A2NavigationController *nav;
@property (nonatomic, strong) A2LauncherViewController *launcher;
@property (nonatomic, strong) A2TaskDrawer *taskDrawer;
@property (nonatomic, strong) UIView *surfaceBackdrop;
@end

@implementation A2RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 主题的表面色作为最底层，卡片与背景浮在它上面
    self.view.backgroundColor = A2ThemeManager.shared.scheme.surface;

    _launcher = [[A2LauncherViewController alloc] init];
    _nav = [[A2NavigationController alloc] initWithRootViewController:_launcher];
    _nav.view.translatesAutoresizingMaskIntoConstraints = NO;
    _nav.view.backgroundColor = UIColor.clearColor;

    [self addChildViewController:_nav];
    [self.view addSubview:_nav.view];
    [NSLayoutConstraint activateConstraints:@[
        [_nav.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_nav.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_nav.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_nav.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
    [_nav didMoveToParentViewController:self];

    [self setupTaskDrawer];
    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 任务抽屉

- (void)setupTaskDrawer {
    _taskDrawer = [[A2TaskDrawer alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_taskDrawer];

    NSLayoutConstraint *height = [_taskDrawer.heightAnchor constraintEqualToConstant:56];
    _taskDrawer.heightConstraint = height;

    [NSLayoutConstraint activateConstraints:@[
        [_taskDrawer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_taskDrawer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_taskDrawer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        height,
    ]];

    // 无任务时收起在屏幕外
    _taskDrawer.alpha = 0;
    _taskDrawer.transform = CGAffineTransformMakeTranslation(0, 86);
}

#pragma mark - 主题

- (void)applyTheme {
    self.view.backgroundColor = A2ThemeManager.shared.scheme.surface;
}

#pragma mark - 方向与状态栏

/// 横屏下状态栏本来就不显示，直接隐藏，把空间还给内容
- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (BOOL)shouldAutorotate {
    return NO;
}

@end
