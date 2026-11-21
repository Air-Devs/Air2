//
//  A2JVMRunningViewController.m
//  Air2
//

#import "A2JVMRunningViewController.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

@interface A2JVMRunningViewController ()
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIView *buttonBar;
@property (nonatomic, strong) UIView *pointerDot;
@property (nonatomic, strong) UIStackView *buttonStack;
@property (nonatomic, assign, readwrite, getter=isLogVisible) BOOL logVisible;
@property (nonatomic, strong) NSMutableArray<NSString *> *logLines;
@end

@implementation A2JVMRunningViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _logLines = [NSMutableArray array];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // 全黑底 —— JVM 阶段没有画面，纯黑比毛玻璃更符合「等着」的语义
    self.view.backgroundColor = UIColor.blackColor;

    [self buildLogView];
    [self buildButtonBar];
    [self buildPointer];

    [self applyTheme];
}

#pragma mark - 构件

- (void)buildLogView {
    _logView = [[UITextView alloc] initWithFrame:CGRectZero];
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    _logView.editable = NO;
    _logView.selectable = YES;
    _logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.textContainerInset = UIEdgeInsetsMake(12, 14, 12, 14);
    _logView.layer.cornerRadius = A2RadiusL;
    _logView.layer.cornerCurve = kCACornerCurveContinuous;
    // 半透明 —— 与 ZL2 的 LogBox 一致，盖在画面上但不完全遮死
    _logView.alpha = 0;
    _logView.hidden = YES;
    [self.view addSubview:_logView];

    // 右下角留出按钮条的空间
    [NSLayoutConstraint activateConstraints:@[
        [_logView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                            constant:8],
        [_logView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_logView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_logView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                               constant:-64],
    ]];
}

- (void)buildButtonBar {
    // ZL2 的 ButtonsLayout：底部三按钮，右对齐
    _buttonStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _buttonStack.translatesAutoresizingMaskIntoConstraints = NO;
    _buttonStack.axis = UILayoutConstraintAxisHorizontal;
    _buttonStack.spacing = A2SpaceS;
    _buttonStack.alignment = UIStackViewAlignmentCenter;

    UIButton *kb = [self makeBarButton:@"键盘" symbol:@"keyboard.fill"
                                action:@selector(keyboardTapped)];
    UIButton *log = [self makeBarButton:@"日志" symbol:@"terminal.fill"
                                 action:@selector(logTapped)];
    UIButton *quit = [self makeBarButton:@"强制关闭" symbol:@"xmark.circle.fill"
                                  action:@selector(forceCloseTapped)];

    for (UIButton *b in @[kb, log, quit]) [_buttonStack addArrangedSubview:b];

    [self.view addSubview:_buttonStack];
    [NSLayoutConstraint activateConstraints:@[
        [_buttonStack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor
                                                     constant:-16],
        [_buttonStack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                  constant:-16],
    ]];
}

- (UIButton *)makeBarButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;

    [b setTitle:[@"  " stringByAppendingString:title] forState:UIControlStateNormal];
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
    b.layer.cornerRadius = 18;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    [b.heightAnchor constraintEqualToConstant:36].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildPointer {
    // 虚拟鼠标指针：ZL2 用 VirtualPointerLayout，这里用一个可拖的小圆点
    CGFloat d = 28;
    _pointerDot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, d, d)];
    _pointerDot.layer.cornerRadius = d / 2;
    _pointerDot.layer.borderWidth = 2;
    _pointerDot.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
    _pointerDot.hidden = YES;   // 没有外部鼠标时隐藏
    [self.view addSubview:_pointerDot];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pointerPanned:)];
    [_pointerDot addGestureRecognizer:pan];
}

- (void)pointerPanned:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    [g setTranslation:CGPointZero inView:self.view];
    CGPoint c = CGPointMake(_pointerDot.center.x + t.x, _pointerDot.center.y + t.y);
    _pointerDot.center = c;
    _pointerPosition = c;
}

- (void)setPointerPosition:(CGPoint)pointerPosition {
    _pointerPosition = pointerPosition;
    _pointerDot.center = pointerPosition;
}

#pragma mark - 动作

- (void)keyboardTapped {
    if ([self.delegate respondsToSelector:@selector(jvmScreenDidRequestKeyboard)]) {
        [self.delegate jvmScreenDidRequestKeyboard];
    }
}

- (void)logTapped {
    [self toggleLog];
}

- (void)forceCloseTapped {
    // ZL2 在这里弹「强制关闭」确认（ForceCloseDialog）。
    // 用 A2Dialog（MD3）而不是系统 UIAlertController。
    // 这里先直接回调，确认框由调用方决定要不要加。
    if ([self.delegate respondsToSelector:@selector(jvmScreenDidRequestForceClose)]) {
        [self.delegate jvmScreenDidRequestForceClose];
    }
}

#pragma mark - 日志

- (void)appendLogLine:(NSString *)line {
    if (line.length == 0) return;
    [_logLines addObject:line];
    // 只保留最近 500 行 —— 日志框不是完整日志文件，滚太久没意义还费内存
    if (_logLines.count > 500) {
        [_logLines removeObjectsInRange:NSMakeRange(0, _logLines.count - 500)];
    }
    _logView.text = [_logLines componentsJoinedByString:@"\n"];
    [_logView scrollRangeToVisible:NSMakeRange(_logView.text.length, 0)];
}

- (void)toggleLog {
    _logVisible = !_logVisible;
    _logView.hidden = NO;

    [UIView animateWithDuration:0.2 animations:^{
        self.logView.alpha = self.logVisible ? 0.88 : 0;
    } completion:^(BOOL finished) {
        if (!self.logVisible) self.logView.hidden = YES;
    }];
}

#pragma mark - 收尾

- (void)dismissWhenGameReady:(void (^)(void))completion {
    // 游戏首帧出现 → 淡出，交给 GameScreen（控件层 + 悬浮球）
    [UIView animateWithDuration:0.35 animations:^{
        self.view.alpha = 0;
    } completion:^(BOOL finished) {
        [self.view removeFromSuperview];
        [self removeFromParentViewController];
        if (completion) completion();
    }];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    _logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    _logView.textColor = [UIColor colorWithWhite:0.85 alpha:1];

    for (UIButton *b in _buttonStack.arrangedSubviews) {
        if (![b isKindOfClass:UIButton.class]) continue;
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.tintColor = UIColor.whiteColor;
    }

    _pointerDot.layer.borderColor = t.cPrimary.CGColor;
}

@end
