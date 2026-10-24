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
@property (nonatomic, strong) UIStackView *toolbar;
@property (nonatomic, assign) CGSize designSize;
@end

@implementation A2ControlsEditorViewController

- (void)a2_addKeyTapped {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"新建按键"
                                                              message:@"给它起个名字（之后点它两次即可绑定功能键）"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"例如：潜行 / 丢弃"; }];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *name = a.textFields.firstObject.text;
        [weakSelf.controls a2_addCustomControlWithTitle:name];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)a2_deleteTapped {
    [self.controls a2_removeSelectedControl];
}

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

    [self buildToolbar];

    // 设计尺寸 = 本机真实横屏尺寸（控件就是按这个坐标摆的）
    CGSize screen = UIScreen.mainScreen.bounds.size;
    _designSize = CGSizeMake(MAX(screen.width, screen.height), MIN(screen.width, screen.height));

    _canvas = [[UIView alloc] initWithFrame:CGRectZero];
    _canvas.translatesAutoresizingMaskIntoConstraints = NO;
    _canvas.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    _canvas.layer.cornerRadius = 16;
    _canvas.layer.cornerCurve = kCACornerCurveContinuous;
    _canvas.clipsToBounds = YES;
    [self.view addSubview:_canvas];
    // ★画布用手动 frame★ 之前的 canvasMaxH 把「高度锚点」和「Y 轴锚点」比，
    //   单位不兼容 ⇒ viewDidLoad 直接抛 NSInvalidArgumentException 崩溃。
    //   现在完全在 viewDidLayoutSubviews 里按可用区域算尺寸。
    _canvas.translatesAutoresizingMaskIntoConstraints = YES;

    // 控件层：按「设计尺寸」排布，再整体缩放塞进画布 ——
    // 这样控件之间的相对位置永远不变，也不需要因为画布大小而重排。
    _controls = [[A2GameControlsView alloc] initWithWindowHandle:0];
    _controls.translatesAutoresizingMaskIntoConstraints = YES;
    _controls.frame = CGRectMake(0, 0, _designSize.width, _designSize.height);
    [_canvas addSubview:_controls];
    [_controls a2_setEditing:YES];

    // 点画布空白 = 取消选中
    UITapGestureRecognizer *bg = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(a2_editorBackgroundTap:)];
    bg.cancelsTouchesInView = NO;
    [_canvas addGestureRecognizer:bg];

    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                                            style:UIBarButtonItemStyleDone
                                                           target:self
                                                           action:@selector(save)];
    self.navigationItem.rightBarButtonItem = done;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                          target:self
                                                                                          action:@selector(cancel)];
}

/// 把设计尺寸的控件层等比缩放并居中到画布（旋转/分屏也会重算）
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_controls == nil || _designSize.width <= 1) return;

    CGFloat top = self.view.safeAreaInsets.top + 8;
    CGFloat bottom = CGRectGetMinY(_toolbar.frame) - 10;
    CGFloat availW = CGRectGetWidth(self.view.bounds) - 20;
    CGFloat availH = MAX(60, bottom - top);
    if (availW <= 1) return;

    // 画布 = 设计尺寸的等比缩放，取能放下的最大比例
    CGFloat k = MIN(availW / _designSize.width, availH / _designSize.height);

    CGSize cs = CGSizeMake(_designSize.width * k, _designSize.height * k);
    _canvas.bounds = CGRectMake(0, 0, cs.width, cs.height);
    _canvas.center = CGPointMake(CGRectGetMidX(self.view.bounds), top + availH * 0.5);

    // 控件层按设计尺寸排布，整体缩放进画布
    _controls.transform = CGAffineTransformIdentity;
    _controls.frame = CGRectMake(0, 0, _designSize.width, _designSize.height);
    _controls.transform = CGAffineTransformMakeScale(k, k);
    _controls.center = CGPointMake(cs.width * 0.5, cs.height * 0.5);
}

- (void)buildToolbar {
    UIStackView *bar = [[UIStackView alloc] initWithFrame:CGRectZero];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.axis = UILayoutConstraintAxisHorizontal;
    bar.distribution = UIStackViewDistributionFillEqually;
    bar.spacing = 10;

    NSArray *titles = @[ @"导入", @"导出", @"＋按键", @"删除" ];
    NSArray *sels = @[ @"importFromClipboard", @"exportToClipboard", @"a2_addKeyTapped", @"a2_deleteTapped" ];
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
    _toolbar = bar;
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
