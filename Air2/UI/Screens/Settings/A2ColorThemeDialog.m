//
//  A2ColorThemeDialog.m
//  Air2
//

#import "A2ColorThemeDialog.h"
#import "A2ColorWheel.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2PrimaryButton.h"

/// 配色风格选项（名称与说明统一从 A2PaletteStyle 取，避免两处维护）
static NSArray<NSArray<NSString *> *> *A2PaletteStyleOptions(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger i = 0; i < 4; i++) {
        [out addObject:@[ A2PaletteStyleName((A2PaletteStyle)i),
                          A2PaletteStyleDescription((A2PaletteStyle)i) ]];
    }
    return out;
}

#pragma mark - 风格选项行

@interface A2StyleOptionRow : UIControl
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UIView *radioOuter;
@property (nonatomic, strong) UIView *radioInner;
@property (nonatomic, assign, getter=isSelected) BOOL selected;
@end

@implementation A2StyleOptionRow

- (instancetype)initWithTitle:(NSString *)title desc:(NSString *)desc {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = A2RadiusM;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    _radioOuter = [[UIView alloc] initWithFrame:CGRectZero];
    _radioOuter.translatesAutoresizingMaskIntoConstraints = NO;
    _radioOuter.layer.cornerRadius = 10;
    _radioOuter.layer.borderWidth = 2;
    _radioOuter.userInteractionEnabled = NO;

    _radioInner = [[UIView alloc] initWithFrame:CGRectZero];
    _radioInner.translatesAutoresizingMaskIntoConstraints = NO;
    _radioInner.layer.cornerRadius = 5;
    _radioInner.hidden = YES;
    [_radioOuter addSubview:_radioInner];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _nameLabel.text = title;

    _descLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _descLabel.font = [A2Typography caption];
    _descLabel.text = desc;
    _descLabel.numberOfLines = 1;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel, _descLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 1;

    [self addSubview:_radioOuter];
    [self addSubview:textStack];

    [NSLayoutConstraint activateConstraints:@[
        [_radioOuter.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceM],
        [_radioOuter.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_radioOuter.widthAnchor constraintEqualToConstant:20],
        [_radioOuter.heightAnchor constraintEqualToConstant:20],
        [_radioInner.centerXAnchor constraintEqualToAnchor:_radioOuter.centerXAnchor],
        [_radioInner.centerYAnchor constraintEqualToAnchor:_radioOuter.centerYAnchor],
        [_radioInner.widthAnchor constraintEqualToConstant:10],
        [_radioInner.heightAnchor constraintEqualToConstant:10],

        [textStack.leadingAnchor constraintEqualToAnchor:_radioOuter.trailingAnchor constant:A2SpaceM],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-A2SpaceM],
        [textStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:48],
    ]];

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    _radioInner.hidden = !selected;
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _radioOuter.layer.borderColor = (self.isSelected ? t.cPrimary : t.cOutline).CGColor;
    _radioInner.backgroundColor = t.cPrimary;
    _nameLabel.textColor = t.cOnSurface;
    _descLabel.textColor = t.cOnSurfaceVariant;
    self.backgroundColor = self.isSelected
        ? [t.cPrimaryContainer colorWithAlphaComponent:0.5]
        : UIColor.clearColor;
}

@end

#pragma mark - 弹窗

@interface A2ColorThemeDialog () <A2ColorWheelDelegate>
@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) A2ColorWheel *wheel;
@property (nonatomic, strong) UILabel *hexLabel;
@property (nonatomic, strong) NSMutableArray<A2StyleOptionRow *> *styleRows;

@property (nonatomic, strong, nullable) UIColor *seedColor;
@property (nonatomic, assign) A2PaletteStyle style;
@property (nonatomic, copy, nullable) void (^onComplete)(UIColor *, A2PaletteStyle);
@end

@implementation A2ColorThemeDialog

+ (void)presentFrom:(UIViewController *)host
          seedColor:(UIColor *)seedColor
              style:(A2PaletteStyle)style
         onComplete:(void (^)(UIColor *, A2PaletteStyle))onComplete {

    A2ColorThemeDialog *vc = [[A2ColorThemeDialog alloc] init];
    vc.seedColor = seedColor ?: A2ThemeManager.shared.scheme.cPrimary;
    vc.style = style;
    vc.onComplete = onComplete;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [host presentViewController:vc animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    // 背景：半透明遮罩，点击可关闭
    _backdrop = [[UIView alloc] initWithFrame:CGRectZero];
    _backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    _backdrop.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismiss)];
    [_backdrop addGestureRecognizer:tap];
    [self.view addSubview:_backdrop];

    [self setupCard];

    [NSLayoutConstraint activateConstraints:@[
        [_backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (void)setupCard {
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.layer.cornerRadius = A2RadiusXL;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    [self.view addSubview:_card];

    // ---- 标题 ----
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    title.text = @"颜色主题";
    title.textAlignment = NSTextAlignmentCenter;

    // ---- 左列：配色风格 ----
    UILabel *styleTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    styleTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    styleTitle.text = @"配色风格";

    _styleRows = [NSMutableArray array];
    UIStackView *styleStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    styleStack.translatesAutoresizingMaskIntoConstraints = NO;
    styleStack.axis = UILayoutConstraintAxisVertical;
    styleStack.spacing = A2SpaceXS;

    NSArray<NSArray<NSString *> *> *options = A2PaletteStyleOptions();
    for (NSUInteger i = 0; i < options.count; i++) {
        A2StyleOptionRow *row = [[A2StyleOptionRow alloc] initWithTitle:options[i][0]
                                                                   desc:options[i][1]];
        row.tag = i;
        [row addTarget:self action:@selector(styleTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_styleRows addObject:row];
        [styleStack addArrangedSubview:row];
    }

    UIStackView *leftColumn = [[UIStackView alloc] initWithArrangedSubviews:@[styleTitle, styleStack]];
    leftColumn.translatesAutoresizingMaskIntoConstraints = NO;
    leftColumn.axis = UILayoutConstraintAxisVertical;
    leftColumn.spacing = A2SpaceM;
    leftColumn.alignment = UIStackViewAlignmentFill;

    // ---- 右列：大色盘 + 明度 + 色值 ----
    _wheel = [[A2ColorWheel alloc] initWithFrame:CGRectZero];
    _wheel.translatesAutoresizingMaskIntoConstraints = NO;
    _wheel.delegate = self;
    [_wheel setColor:_seedColor animated:NO];

    _hexLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _hexLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
    _hexLabel.textAlignment = NSTextAlignmentCenter;

    UIStackView *rightColumn = [[UIStackView alloc] initWithArrangedSubviews:@[_wheel, _hexLabel]];
    rightColumn.translatesAutoresizingMaskIntoConstraints = NO;
    rightColumn.axis = UILayoutConstraintAxisVertical;
    rightColumn.spacing = A2SpaceM;

    // ---- 分栏 ----
    UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.tag = 801;

    UIStackView *bodyStack = [[UIStackView alloc] initWithArrangedSubviews:@[leftColumn, rightColumn]];
    bodyStack.translatesAutoresizingMaskIntoConstraints = NO;
    bodyStack.axis = UILayoutConstraintAxisHorizontal;
    bodyStack.spacing = A2SpaceXL;
    bodyStack.alignment = UIStackViewAlignmentTop;

    // ---- 底部按钮 ----
    A2PrimaryButton *cancel = [[A2PrimaryButton alloc] initWithTitle:@"取消" style:A2ButtonStyleSecondary];
    [cancel addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];

    A2PrimaryButton *confirm = [[A2PrimaryButton alloc] initWithTitle:@"确认" style:A2ButtonStylePrimary];
    [confirm addTarget:self action:@selector(confirm) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[cancel, confirm]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.distribution = UIStackViewDistributionFillEqually;
    buttonRow.spacing = A2SpaceM;

    [_card addSubview:title];
    [_card addSubview:bodyStack];
    [_card addSubview:divider];
    [_card addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        // 卡片：居中，宽度自适应但不超屏宽 92%
        [_card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_card.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor
                                                   multiplier:0.92],
        [_card.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor
                                                   multiplier:0.92],

        [title.topAnchor constraintEqualToAnchor:_card.topAnchor constant:A2SpaceXL],
        [title.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceXL],
        [title.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceXL],

        [bodyStack.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:A2SpaceXL],
        [bodyStack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceXL],
        [bodyStack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceXL],

        // 左列固定 220，右列吃掉剩余
        [leftColumn.widthAnchor constraintEqualToConstant:220],
        [_wheel.widthAnchor constraintGreaterThanOrEqualToConstant:260],
        [_wheel.heightAnchor constraintEqualToConstant:200],

        [divider.topAnchor constraintEqualToAnchor:bodyStack.bottomAnchor constant:A2SpaceXL],
        [divider.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceXL],
        [divider.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceXL],
        [divider.heightAnchor constraintEqualToConstant:1],

        [buttonRow.topAnchor constraintEqualToAnchor:divider.bottomAnchor constant:A2SpaceL],
        [buttonRow.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceL],
        [buttonRow.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceL],
        [buttonRow.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-A2SpaceL],
        [buttonRow.heightAnchor constraintEqualToConstant:A2ButtonHeight],
    ]];

    [self refreshStyleSelection];
    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 交互

- (void)styleTapped:(A2StyleOptionRow *)sender {
    self.style = (A2PaletteStyle)sender.tag;
    [self refreshStyleSelection];

    UISelectionFeedbackGenerator *fb = [UISelectionFeedbackGenerator new];
    [fb selectionChanged];
}

- (void)refreshStyleSelection {
    for (A2StyleOptionRow *row in _styleRows) {
        row.selected = (row.tag == (NSInteger)self.style);
    }
}

- (void)dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)confirm {
    UIColor *c = _wheel.color;
    void (^cb)(UIColor *, A2PaletteStyle) = self.onComplete;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(c, self.style);
    }];
}

#pragma mark - A2ColorWheelDelegate

- (void)colorWheel:(A2ColorWheel *)wheel didChangeColor:(UIColor *)color {
    [self updateHexLabel:color];
}

- (void)colorWheel:(A2ColorWheel *)wheel didFinishWithColor:(UIColor *)color {
    [self updateHexLabel:color];
    UISelectionFeedbackGenerator *fb = [UISelectionFeedbackGenerator new];
    [fb selectionChanged];
}

- (void)updateHexLabel:(UIColor *)color {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    _hexLabel.text = [NSString stringWithFormat:@"#%02X%02X%02X",
                      (unsigned)(r * 255), (unsigned)(g * 255), (unsigned)(b * 255)];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _card.backgroundColor = t.cSurfaceContainerHigh;
    for (UILabel *l in _card.subviews) {
        if ([l isKindOfClass:UILabel.class]) l.textColor = t.cOnSurface;
    }
    for (UIView *v in _card.subviews) {
        if (v.tag == 801) v.backgroundColor = t.cOutlineVariant;
    }
    _hexLabel.textColor = t.cOnSurfaceVariant;
    [self updateHexLabel:_wheel.color];
}

@end
