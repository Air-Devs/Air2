//
//  A2ControlsEditorViewController.m
//  Air2
//

#import "A2ControlsEditorViewController.h"
#import "A2GameControlsView.h"
#import "A2ControlLayoutIO.h"
#import "A2Log.h"
#import "A2Toast.h"

@interface A2ControlsEditorViewController ()
@property (nonatomic, strong) A2GameControlsView *controls;
@property (nonatomic, strong) UIView *canvas;
@end

@implementation A2ControlsEditorViewController

- (void)a2_editorBackgroundTap:(UITapGestureRecognizer *)g {
    [_controls a2_deselect];
}

+ (instancetype)editor {
    return [[self alloc] init];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"控件布局";
    self.view.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];

    // 画布：保持 16:9，模拟游戏画面区域（不连真实窗口：window=0 ⇒ 按键不会送到任何地方）
    _canvas = [[UIView alloc] initWithFrame:CGRectZero];
    _canvas.translatesAutoresizingMaskIntoConstraints = NO;
    _canvas.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    _canvas.layer.cornerRadius = 16;
    _canvas.layer.cornerCurve = kCACornerCurveContinuous;
    _canvas.clipsToBounds = YES;
    [self.view addSubview:_canvas];

    // ★按本机真实比例(横屏)★ 必须用 长边/短边：
    //   UIScreen 在竖屏态返回 402×874，直接用 w/h 会得到 0.46 ⇒ 画布被压成竖条，
    //   而控件仍按宽屏坐标摆 ⇒ 右侧一串跑到画布外("超出屏幕看不见")。
    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGFloat longSide  = MAX(screen.width, screen.height);
    CGFloat shortSide = MIN(screen.width, screen.height);
    CGFloat ratio = (shortSide > 0) ? (longSide / shortSide) : (16.0 / 9.0);
    if (ratio < 1.0 || ratio > 4.0) ratio = 16.0 / 9.0;   // 异常值兜底
    NSLayoutConstraint *aspect = [_canvas.widthAnchor constraintEqualToAnchor:_canvas.heightAnchor multiplier:ratio];
    aspect.priority = 999;


    // 高度上限用 750 优先级：让 aspect(999) 决定形状，屏幕不够高时才让位
    NSLayoutConstraint *maxH = [_canvas.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor multiplier:0.80];
    maxH.priority = 750;

    [NSLayoutConstraint activateConstraints:@[
        [_canvas.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_canvas.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-30],
        [_canvas.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.94],
        maxH,
        aspect,
    ]];

    _controls = [[A2GameControlsView alloc] initWithWindowHandle:0];
    _controls.translatesAutoresizingMaskIntoConstraints = NO;
    [_canvas addSubview:_controls];
    [NSLayoutConstraint activateConstraints:@[
        [_controls.leadingAnchor constraintEqualToAnchor:_canvas.leadingAnchor],
        [_controls.trailingAnchor constraintEqualToAnchor:_canvas.trailingAnchor],
        [_controls.topAnchor constraintEqualToAnchor:_canvas.topAnchor],
        [_controls.bottomAnchor constraintEqualToAnchor:_canvas.bottomAnchor],
    ]];
    [_controls a2_setEditing:YES];

    // 点画布空白 = 取消选中（控件本体的 tap 由 A2GameControlsView 自己处理）
    UITapGestureRecognizer *bg = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(a2_editorBackgroundTap:)];
    bg.cancelsTouchesInView = NO;
    [_canvas addGestureRecognizer:bg];

    [self buildToolbar];

    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                                            style:UIBarButtonItemStyleDone
                                                           target:self
                                                           action:@selector(save)];
    self.navigationItem.rightBarButtonItem = done;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                          target:self
                                                                                          action:@selector(cancel)];
}

- (void)buildToolbar {
    UIStackView *bar = [[UIStackView alloc] initWithFrame:CGRectZero];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.axis = UILayoutConstraintAxisHorizontal;
    bar.distribution = UIStackViewDistributionFillEqually;
    bar.spacing = 10;

    NSArray *titles = @[ @"导入", @"导出" ];
    NSArray *sels = @[ @"importFromClipboard", @"exportToClipboard" ];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        b.layer.cornerRadius = 12;
        b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        SEL sel = NSSelectorFromString(sels[i]);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
#pragma clang diagnostic pop
        [bar addArrangedSubview:b];
    }
    [self.view addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
        [bar.heightAnchor constraintEqualToConstant:46],
    ]];
}

- (void)save {
    [self.controls a2_saveLayoutNow];
    [A2Log log:@"[A2-CONTROLS] 布局已从设置页保存"];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)importFromClipboard {
    NSString *text = UIPasteboard.generalPasteboard.string;
    if (text.length == 0) {
        [A2Toast show:@"剪贴板为空" inView:self.view];
        return;
    }
    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:&err];
    if (json == nil) {
        [A2Toast show:@"不是合法 JSON" inView:self.view];
        return;
    }
    A2ControlLayoutFormat fmt = [A2ControlLayoutIO detectFormat:json];
    NSArray *controls = [A2ControlLayoutIO parseJSON:json format:fmt];
    if (controls.count == 0) {
        [A2Toast show:@"没有解析出控件" inView:self.view];
        return;
    }
    [self.controls a2_importControls:controls];
    [A2Toast show:[NSString stringWithFormat:@"已导入 %lu 项", (unsigned long) controls.count] inView:self.view];
}

- (void)exportToClipboard {
    NSArray *controls = [self.controls a2_exportControls];
    id json = [A2ControlLayoutIO exportControls:controls format:A2ControlLayoutFormatA2 name:@"默认"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:NULL];
    if (data == nil) return;
    UIPasteboard.generalPasteboard.string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [A2Toast show:[NSString stringWithFormat:@"已导出 %lu 项到剪贴板", (unsigned long) controls.count] inView:self.view];
}


@end
