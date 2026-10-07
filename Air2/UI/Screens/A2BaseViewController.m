//
//  A2BaseViewController.m
//  Air2
//

#import "A2BaseViewController.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2BackgroundView.h"

@interface A2BaseViewController ()
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIStackView *trailingStack;
@property (nonatomic, strong) A2BackgroundView *backgroundView;
@property (nonatomic, strong) UIScrollView *scrollViewInternal;
@property (nonatomic, strong) UIStackView *contentStackInternal;
@property (nonatomic, strong) UIView *plainContentViewInternal;
@property (nonatomic, assign) BOOL didSetupConstraints;
@property (nonatomic, strong) NSMapTable<UIButton *, void (^)(void)> *buttonActions;
@end

@implementation A2BaseViewController

#pragma mark - 生命周期

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _trailingButtons = [NSMutableArray array];
    _buttonActions = [NSMapTable strongToStrongObjectsMapTable];
    _usesScrollContent = YES;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    _backgroundView = [[A2BackgroundView alloc] initWithFrame:CGRectZero];
    _backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    _backgroundView.fadeRatio = 0;   // 二级页面是全屏内容，不需要右侧渐隐
    [self.view addSubview:_backgroundView];

    [self setupTopBar];

    if (_usesScrollContent) {
        [self setupScrollContent];
    } else {
        [self setupPlainContent];
    }

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

#pragma mark - 顶栏

- (void)setupTopBar {
    _topBar = [[UIView alloc] initWithFrame:CGRectZero];
    _topBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_topBar];

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    _backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _backButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_backButton setImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:cfg]
                 forState:UIControlStateNormal];
    [_backButton addTarget:self action:@selector(handleBack) forControlEvents:UIControlEventTouchUpInside];
    [_topBar addSubview:_backButton];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [_topBar addSubview:_titleLabel];

    _trailingStack = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    _trailingStack.translatesAutoresizingMaskIntoConstraints = NO;
    _trailingStack.axis = UILayoutConstraintAxisHorizontal;
    _trailingStack.spacing = A2SpaceXS;
    [_topBar addSubview:_trailingStack];
}

- (void)setPageTitle:(NSString *)pageTitle {
    _pageTitle = [pageTitle copy];
    _titleLabel.text = pageTitle;
}

- (void)setHidesTopBar:(BOOL)hidesTopBar {
    _hidesTopBar = hidesTopBar;
    _topBar.hidden = hidesTopBar;
}

- (void)setLeadingCustomView:(UIView *)leadingCustomView {
    if (_leadingCustomView) [_leadingCustomView removeFromSuperview];
    _leadingCustomView = leadingCustomView;
    if (!leadingCustomView) return;
    leadingCustomView.translatesAutoresizingMaskIntoConstraints = NO;
    [_topBar addSubview:leadingCustomView];
    [NSLayoutConstraint activateConstraints:@[
        [leadingCustomView.leadingAnchor constraintEqualToAnchor:_topBar.leadingAnchor constant:A2SpaceM],
        [leadingCustomView.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    ]];
}

- (UIButton *)addTrailingButtonWithSymbol:(NSString *)symbolName action:(void (^)(void))action {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:symbolName withConfiguration:cfg] forState:UIControlStateNormal];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [b.widthAnchor constraintEqualToConstant:A2MinTouchTarget],
        [b.heightAnchor constraintEqualToConstant:A2MinTouchTarget],
    ]];
    if (action) [_buttonActions setObject:[action copy] forKey:b];
    [b addTarget:self action:@selector(handleTrailingButton:) forControlEvents:UIControlEventTouchUpInside];
    [_trailingStack addArrangedSubview:b];
    [_trailingButtons addObject:b];
    return b;
}

- (void)handleTrailingButton:(UIButton *)sender {
    void (^action)(void) = [_buttonActions objectForKey:sender];
    if (action) action();
}

- (void)handleBack {
    if (self.onBack) {
        self.onBack();
        return;
    }
    if (self.navigationController) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - 内容容器

- (void)setupScrollContent {
    _scrollViewInternal = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scrollViewInternal.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollViewInternal.showsVerticalScrollIndicator = NO;
    _scrollViewInternal.alwaysBounceVertical = YES;
    _scrollViewInternal.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_scrollViewInternal];

    _contentStackInternal = [[UIStackView alloc] initWithFrame:CGRectZero];
    _contentStackInternal.translatesAutoresizingMaskIntoConstraints = NO;
    _contentStackInternal.axis = UILayoutConstraintAxisVertical;
    _contentStackInternal.spacing = A2SpaceL;
    [_scrollViewInternal addSubview:_contentStackInternal];
}

- (void)setupPlainContent {
    _plainContentViewInternal = [[UIView alloc] initWithFrame:CGRectZero];
    _plainContentViewInternal.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_plainContentViewInternal];
}

- (UIScrollView *)scrollView {
    return _scrollViewInternal;
}

- (UIStackView *)contentStack {
    return _contentStackInternal;
}

- (UIView *)plainContentView {
    return _plainContentViewInternal;
}

- (void)addSection:(UIView *)section {
    if (_contentStackInternal) {
        [_contentStackInternal addArrangedSubview:section];
    }
}

#pragma mark - 约束

- (void)updateViewConstraints {
    if (_didSetupConstraints) {
        [super updateViewConstraints];
        return;
    }
    _didSetupConstraints = YES;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSMutableArray *constraints = [NSMutableArray array];

    [constraints addObjectsFromArray:@[
        [_backgroundView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_backgroundView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_backgroundView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_backgroundView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [_topBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_topBar.heightAnchor constraintEqualToConstant:A2TopBarHeight],

        [_backButton.leadingAnchor constraintEqualToAnchor:_topBar.leadingAnchor constant:A2SpaceS],
        [_backButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
        [_backButton.widthAnchor constraintEqualToConstant:A2MinTouchTarget],
        [_backButton.heightAnchor constraintEqualToConstant:A2MinTouchTarget],

        [_titleLabel.centerXAnchor constraintEqualToAnchor:_topBar.centerXAnchor],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
        [_titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_backButton.trailingAnchor constant:A2SpaceS],

        [_trailingStack.trailingAnchor constraintEqualToAnchor:_topBar.trailingAnchor constant:-A2SpaceM],
        [_trailingStack.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_trailingStack.leadingAnchor constant:-A2SpaceS],
    ]];

    UIView *contentBelow = _topBar;
    if (_scrollViewInternal) {
        [constraints addObjectsFromArray:@[
            [_scrollViewInternal.topAnchor constraintEqualToAnchor:contentBelow.bottomAnchor],
            [_scrollViewInternal.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [_scrollViewInternal.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [_scrollViewInternal.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

            [_contentStackInternal.topAnchor constraintEqualToAnchor:_scrollViewInternal.topAnchor constant:A2SpaceS],
            [_contentStackInternal.bottomAnchor constraintEqualToAnchor:_scrollViewInternal.bottomAnchor constant:-A2SpaceXXL],
            [_contentStackInternal.leadingAnchor constraintEqualToAnchor:_scrollViewInternal.leadingAnchor constant:A2PageMargin],
            [_contentStackInternal.trailingAnchor constraintEqualToAnchor:_scrollViewInternal.trailingAnchor constant:-A2PageMargin],
            [_contentStackInternal.widthAnchor constraintEqualToAnchor:_scrollViewInternal.widthAnchor constant:-A2PageMargin * 2],
        ]];
    } else if (_plainContentViewInternal) {
        [constraints addObjectsFromArray:@[
            [_plainContentViewInternal.topAnchor constraintEqualToAnchor:contentBelow.bottomAnchor],
            [_plainContentViewInternal.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [_plainContentViewInternal.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [_plainContentViewInternal.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        ]];
    }

    [NSLayoutConstraint activateConstraints:constraints];
    [super updateViewConstraints];
}

#pragma mark - 主题

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    _titleLabel.textColor = UIColor.whiteColor;
    _backButton.tintColor = UIColor.whiteColor;
    for (UIButton *b in _trailingButtons) {
        b.tintColor = UIColor.whiteColor;
    }
}

@end
