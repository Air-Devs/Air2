//
//  A2InstallProgressDialog.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
//
//  A2InstallProgressDialog.m
//  Air2
//
//  严格对照 ZL2 的 TitleTaskFlowDialog / TaskFlowListColumn / InstallingTaskItem。
//  规格都写在头文件注释里，这里只补充实现层面的说明。
//

#import "A2InstallProgressDialog.h"
#import "A2Log.h"
#import "A2IndeterminateBar.h"
#import "A2TaskLogOutput.h"
#import "A2TaskLogCard.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

/// 步骤项 —— 对照 InstallingTaskItem
@interface A2ProgressTaskItem : UIView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIStackView *progressRow;
@property (nonatomic, strong) UIView *progressTrack;
@property (nonatomic, strong) UIView *progressFill;
@property (nonatomic, strong) A2IndeterminateBar *indeterminateBar;
@property (nonatomic, strong) UILabel *rateLabel;
@property (nonatomic, strong) UILabel *percentLabel;
@property (nonatomic, strong) NSLayoutConstraint *fillWidth;
@property (nonatomic, strong) NSLayoutConstraint *trackHeight;
@property (nonatomic, assign) A2ProgressStepStage stage;
@property (nonatomic, assign) double progressValue;
- (instancetype)initWithTitle:(NSString *)title;
- (void)applyStage:(A2ProgressStepStage)stage
           message:(nullable NSString *)message
          progress:(double)progress
              rate:(nullable NSString *)rate;
- (void)applyTheme;
@end

@implementation A2ProgressTaskItem

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    // ---- 图标 24dp（ZL2 的 Icon size(24.dp)）----
    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_iconView];

    // ---- 标题 labelLarge ----
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _titleLabel.text = title;
    _titleLabel.numberOfLines = 2;

    // ---- message labelMedium（top 4dp）----
    _messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _messageLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _messageLabel.numberOfLines = 2;
    _messageLabel.hidden = YES;

    // ---- 进度行：进度条(weight 1) + 速率 + 百分比 ----
    _progressTrack = [[UIView alloc] initWithFrame:CGRectZero];
    _progressTrack.translatesAutoresizingMaskIntoConstraints = NO;
    _progressTrack.layer.cornerRadius = 2;
    _progressTrack.clipsToBounds = YES;

    _progressFill = [[UIView alloc] initWithFrame:CGRectZero];
    _progressFill.translatesAutoresizingMaskIntoConstraints = NO;
    [_progressTrack addSubview:_progressFill];

    _indeterminateBar = [[A2IndeterminateBar alloc] initWithFrame:CGRectZero];
    _indeterminateBar.hidden = YES;

    _rateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _rateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _rateLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    _rateLabel.hidden = YES;

    _percentLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _percentLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];

    // 进度行三种形态（确定/不确定）用一个容器切换
    UIView *progressArea = [[UIView alloc] initWithFrame:CGRectZero];
    progressArea.translatesAutoresizingMaskIntoConstraints = NO;
    [progressArea addSubview:_progressTrack];
    [progressArea addSubview:_indeterminateBar];
    [progressArea addSubview:_rateLabel];
    [progressArea addSubview:_percentLabel];

    [NSLayoutConstraint activateConstraints:@[
        // 进度条占剩余宽度
        [_progressTrack.leadingAnchor constraintEqualToAnchor:progressArea.leadingAnchor],
        [_progressTrack.centerYAnchor constraintEqualToAnchor:progressArea.centerYAnchor],
        [_progressTrack.heightAnchor constraintEqualToConstant:4],
        [_progressTrack.trailingAnchor constraintEqualToAnchor:_rateLabel.leadingAnchor
                                                      constant:-8],

        [_indeterminateBar.leadingAnchor constraintEqualToAnchor:progressArea.leadingAnchor],
        [_indeterminateBar.trailingAnchor constraintEqualToAnchor:_progressTrack.trailingAnchor],
        [_indeterminateBar.centerYAnchor constraintEqualToAnchor:progressArea.centerYAnchor],

        [_rateLabel.centerYAnchor constraintEqualToAnchor:progressArea.centerYAnchor],
        [_percentLabel.leadingAnchor constraintEqualToAnchor:_rateLabel.trailingAnchor
                                                    constant:8],
        [_percentLabel.trailingAnchor constraintEqualToAnchor:progressArea.trailingAnchor],
        [_percentLabel.centerYAnchor constraintEqualToAnchor:progressArea.centerYAnchor],

        [progressArea.heightAnchor constraintEqualToConstant:20],
    ]];

    _fillWidth = [_progressFill.widthAnchor constraintEqualToConstant:0];
    _fillWidth.active = YES;

    // ---- 纵向结构 ----
    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:
                              @[_titleLabel, _messageLabel, progressArea]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 0;
    // message 上 4dp，进度行上 4dp（对应 ZL2 的 padding(top = 4.dp)）
    [textStack setCustomSpacing:4 afterView:_titleLabel];
    [textStack setCustomSpacing:4 afterView:_messageLabel];

    [self addSubview:textStack];

    [NSLayoutConstraint activateConstraints:@[
        // Row(间距 8, 垂直居中) —— 图标与内容间距 8dp
        [_iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:24],
        [_iconView.heightAnchor constraintEqualToConstant:24],

        [textStack.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor
                                                 constant:8],
        [textStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [textStack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [textStack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [_progressFill.topAnchor constraintEqualToAnchor:_progressTrack.topAnchor],
        [_progressFill.bottomAnchor constraintEqualToAnchor:_progressTrack.bottomAnchor],
        [_progressFill.leadingAnchor constraintEqualToAnchor:_progressTrack.leadingAnchor],
    ]];

    [self applyTheme];
    return self;
}

- (void)applyStage:(A2ProgressStepStage)stage
           message:(NSString *)message
          progress:(double)progress
              rate:(NSString *)rate {
    _stage = stage;
    _progressValue = progress;

    BOOL running = (stage == A2ProgressStepStageRunning);
    BOOL indeterminate = (progress < 0);

    _messageLabel.hidden = !(running && message.length > 0);
    _messageLabel.text = message;

    // 整块进度区只在 RUNNING 时可见
    _progressTrack.superview.hidden = !running;

    if (running) {
        if (indeterminate) {
            // 不确定进度：显示滑动条，隐藏百分比与确定进度条
            _progressTrack.hidden = YES;
            _indeterminateBar.hidden = NO;
            _percentLabel.hidden = YES;
            [_indeterminateBar startAnimating];
        } else {
            _progressTrack.hidden = NO;
            [_indeterminateBar stopAnimating];
            _indeterminateBar.hidden = YES;
            _percentLabel.hidden = NO;
            _percentLabel.text = [NSString stringWithFormat:@"%.0f%%", progress * 100];
        }

        _rateLabel.hidden = (rate.length == 0);
        _rateLabel.text = rate;
    } else {
        [_indeterminateBar stopAnimating];
        _rateLabel.hidden = YES;
        _percentLabel.hidden = YES;
    }

    [self applyTheme];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_stage != A2ProgressStepStageRunning || _progressValue < 0) return;

    CGFloat w = _progressTrack.bounds.size.width;
    if (w > 0) {
        _fillWidth.constant = w * MAX(0, MIN(1.0, _progressValue));
    }
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    // 图标按 stage 切换（ZL2：PREPARING 时钟 / RUNNING 下载 / COMPLETED 对勾）
    NSString *symbol = @"clock";
    switch (_stage) {
        case A2ProgressStepStagePreparing: symbol = @"clock"; break;
        case A2ProgressStepStageRunning:   symbol = @"arrow.down.to.line"; break;
        case A2ProgressStepStageCompleted: symbol = @"checkmark"; break;
    }

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:19
                                                       weight:UIImageSymbolWeightMedium];
    _iconView.image = [UIImage systemImageNamed:symbol withConfiguration:cfg];
    _iconView.tintColor = (self.stage == A2ProgressStepStageRunning)
        ? t.cPrimary
        : t.cOnSurface;

    _titleLabel.textColor = (self.stage == A2ProgressStepStagePreparing)
        ? t.cOnSurfaceVariant
        : t.cOnSurface;
    _messageLabel.textColor = t.cOnSurfaceVariant;
    _rateLabel.textColor = t.cOnSurfaceVariant;
    _percentLabel.textColor = t.cOnSurfaceVariant;

    _progressTrack.backgroundColor = [t.cPrimary colorWithAlphaComponent:0.15];
    _progressFill.backgroundColor = t.cPrimary;
}

@end

#pragma mark - 弹窗

@interface A2InstallProgressDialog ()
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIScrollView *stepScroll;
@property (nonatomic, strong) UIStackView *stepStack;
@property (nonatomic, strong) UIView *logContainer;
@property (nonatomic, strong) A2TaskLogCard *logCard;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) NSMutableArray<A2ProgressTaskItem *> *items;
@property (nonatomic, strong, nullable) A2TaskLogOutput *logOutput;
/// 步骤标题。可能在 viewDidLoad 之前就被 setSteps: 设进来 ——
/// 那时 _stepStack 还是 nil，必须暂存，等视图建好再真正生成行。
@property (nonatomic, copy, nullable) NSArray<NSString *> *pendingStepTitles;
- (void)applyStepTitles:(NSArray<NSString *> *)stepTitles;
- (NSArray<NSString *> *)nonEmptyTitles:(NSArray<NSString *> *)titles;
@end

@implementation A2InstallProgressDialog

- (instancetype)initWithLogOutput:(A2TaskLogOutput *)logOutput {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _logOutput = logOutput;
    _dialogTitle = @"安装游戏中";
    _items = [NSMutableArray array];
    // 模态：不允许下拉消失
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self buildCard];

    // ★视图建好之后再把暂存的步骤生成成行★
    //   之前调用方是「先 setSteps: 再 present」，而 setSteps: 里操作的是
    //   _stepStack —— 那时 viewDidLoad 还没跑，_stepStack 是 nil，
    //   addArrangedSubview: 全是空操作。结果弹窗里只有标题和一条
    //   占满宽度的「取消」按钮，用户看到的就是一个空的取消框。
    NSArray<NSString *> *titles = [self nonEmptyTitles:self.pendingStepTitles];
    if (titles.count > 0) {
        [self applyStepTitles:titles];
        self.pendingStepTitles = nil;
        [A2Log log:@"[A2-DL] 进度弹窗：viewDidLoad 后补建 %lu 个步骤行（此前会在空栈上 addArrangedSubview 丢光）",
                    (unsigned long)titles.count];
    } else {
        // 兜底：没有步骤也要有一行说明，绝不出现「只有取消按钮」的空弹窗
        [A2Log log:@"[A2-DL] 进度弹窗：没有任何有效步骤，兜底成一行说明，避免空壳弹窗"];
        [self applyStepTitles:@[self.dialogTitle.length ? self.dialogTitle : @"准备中…"]];
    }
    // 标题也兜住 —— 只有正文没有标题同样是「空壳」观感
    if (_titleLabel.text.length == 0) _titleLabel.text = @"安装游戏中";
}

/// 丢掉空串 / 纯空白的步骤标题。
/// 一个空标题会生成一条「有行高、没文字」的空白行 —— 在用户眼里
/// 和「弹窗里没内容、只剩取消按钮」是同一个观感，所以从源头滤掉。
- (NSArray<NSString *> *)nonEmptyTitles:(NSArray<NSString *> *)titles {
    if (titles.count == 0) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:titles.count];
    for (id t in titles) {
        if (![t isKindOfClass:NSString.class]) continue;
        NSString *s = [(NSString *)t stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length > 0) [out addObject:s];
    }
    return out;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 标题可能在 present 之前才被赋值（dialogTitle 是外部属性）
    if (self.dialogTitle.length > 0) _titleLabel.text = self.dialogTitle;
}

- (void)buildCard {
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    // ZL2: MaterialTheme.shapes.extraLarge（28）+ shadowElevation 6
    _card.layer.cornerRadius = A2RadiusXL;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.shadowColor = UIColor.blackColor.CGColor;
    _card.layer.shadowOpacity = 0.18;
    _card.layer.shadowRadius = 6;
    _card.layer.shadowOffset = CGSizeMake(0, 3);
    [self.view addSubview:_card];

    // 内容容器（圆角裁剪与阴影不能在同层）
    UIView *content = [[UIView alloc] initWithFrame:CGRectZero];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.layer.cornerRadius = A2RadiusXL;
    content.layer.cornerCurve = kCACornerCurveContinuous;
    content.clipsToBounds = YES;
    [_card addSubview:content];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.text = _dialogTitle;

    // 步骤列表（可滚动）
    _stepScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _stepScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _stepScroll.showsVerticalScrollIndicator = NO;
    _stepScroll.alwaysBounceHorizontal = NO;

    _stepStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stepStack.translatesAutoresizingMaskIntoConstraints = NO;
    _stepStack.axis = UILayoutConstraintAxisVertical;
    // ZL2: 步骤间距 16，每项额外 padding(vertical 6) → 合计 28 的视觉间距
    _stepStack.spacing = 16;
    [_stepScroll addSubview:_stepStack];

    // 取消按钮（fillMaxWidth）
    _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_cancelButton setTitle:@"取消" forState:UIControlStateNormal];
    _cancelButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _cancelButton.layer.cornerRadius = A2RadiusL;
    _cancelButton.layer.cornerCurve = kCACornerCurveContinuous;
    [_cancelButton addTarget:self action:@selector(cancelTapped)
            forControlEvents:UIControlEventTouchUpInside];

    [_card addSubview:content];
    [content addSubview:_titleLabel];
    [content addSubview:_stepScroll];
    [content addSubview:_cancelButton];

    // ---- 双列布局（有日志时）----
    if (_logOutput) {
        _logCard = [[A2TaskLogCard alloc] initWithFrame:CGRectZero];
        _logCard.logOutput = _logOutput;
        [content addSubview:_logCard];
    }

    CGFloat cardWidthRatio = _logOutput ? 0.8 : 0.0;

    NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray array];

    [cs addObjectsFromArray:@[
        [_card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_card.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor
                                                   multiplier:0.85],

        [content.topAnchor constraintEqualToAnchor:_card.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor],

        // padding 16（ZL2）
        [_titleLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],

        [_stepScroll.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:16],
        [_stepScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],

        [_stepStack.topAnchor constraintEqualToAnchor:_stepScroll.contentLayoutGuide.topAnchor
                                              constant:6],   // 每项 vertical padding 6
        [_stepStack.bottomAnchor constraintEqualToAnchor:_stepScroll.contentLayoutGuide.bottomAnchor
                                                 constant:-6],
        [_stepStack.leadingAnchor constraintEqualToAnchor:_stepScroll.contentLayoutGuide.leadingAnchor],
        [_stepStack.trailingAnchor constraintEqualToAnchor:_stepScroll.contentLayoutGuide.trailingAnchor],
        [_stepStack.widthAnchor constraintEqualToAnchor:_stepScroll.frameLayoutGuide.widthAnchor],

        // 步骤区最小高度 —— 否则内容为空时会被压成 0，
        // 整个弹窗只剩一个取消按钮（这就是「只显示一个大大的取消按钮」的原因）。
        [_stepScroll.heightAnchor constraintGreaterThanOrEqualToConstant:80],

        [_cancelButton.topAnchor constraintEqualToAnchor:_stepScroll.bottomAnchor constant:16],
        [_cancelButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
        [_cancelButton.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [_cancelButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [_cancelButton.heightAnchor constraintEqualToConstant:44],
    ]];

    // 宽度：有日志时 80%，否则自适应（给个上下限）
    if (_logOutput) {
        [cs addObject:[_card.widthAnchor constraintEqualToAnchor:self.view.widthAnchor
                                                      multiplier:cardWidthRatio]];
        // 左右分栏：步骤列 | 日志列
        CGFloat half = 0;
        (void)half;
        [cs addObjectsFromArray:@[
            [_logCard.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:16],
            [_logCard.bottomAnchor constraintEqualToAnchor:_cancelButton.topAnchor constant:-16],
            [_logCard.leadingAnchor constraintEqualToAnchor:_stepScroll.trailingAnchor constant:16],
            [_logCard.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
            [_logCard.widthAnchor constraintEqualToAnchor:_stepScroll.widthAnchor],
            [_stepScroll.bottomAnchor constraintEqualToAnchor:_cancelButton.topAnchor constant:-16],
        ]];
    } else {
        [cs addObjectsFromArray:@[
            [_card.widthAnchor constraintGreaterThanOrEqualToConstant:380],
            [_card.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor
                                                      multiplier:0.6],
            [_stepScroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                                       constant:-16],
            [_stepScroll.heightAnchor constraintLessThanOrEqualToConstant:320],
        ]];
    }

    [NSLayoutConstraint activateConstraints:cs];

    [self applyTheme];
    [self observeTheme];
}

- (void)observeTheme {
    __weak typeof(self) weakSelf = self;
    [NSNotificationCenter.defaultCenter addObserverForName:A2ThemeDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) self = weakSelf;
        [self applyTheme];
    }];
}

#pragma mark - 数据

- (void)setSteps:(NSArray<NSString *> *)stepTitles {
    // 空的步骤列表 = 一个没有任何内容的弹窗（只剩取消按钮）。
    // 这里直接兜底成一行「准备中…」，从结构上杜绝那种形态。
    NSArray<NSString *> *titles = (stepTitles.count > 0)
        ? stepTitles
        : @[self.dialogTitle.length ? self.dialogTitle : @"准备中…"];

    // 视图还没加载（调用方通常先 setSteps: 再 present）⇒ 先存起来
    if (!_stepStack) {
        self.pendingStepTitles = titles;
        return;
    }
    [self applyStepTitles:titles];
}

/// 真正把步骤生成成行。只在 _stepStack 存在之后调用。
- (void)applyStepTitles:(NSArray<NSString *> *)stepTitles {
    for (UIView *v in [_stepStack.arrangedSubviews copy]) {
        [_stepStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [_items removeAllObjects];

    for (NSString *title in stepTitles) {
        A2ProgressTaskItem *item = [[A2ProgressTaskItem alloc] initWithTitle:title];
        item.stage = A2ProgressStepStagePreparing;
        // 每项额外 padding(vertical 6)
        UIView *wrap = [[UIView alloc] initWithFrame:CGRectZero];
        wrap.translatesAutoresizingMaskIntoConstraints = NO;
        [wrap addSubview:item];
        [NSLayoutConstraint activateConstraints:@[
            [item.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:6],
            [item.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-6],
            [item.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor],
            [item.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor],
        ]];
        [_items addObject:item];
        [_stepStack addArrangedSubview:wrap];
    }
}

- (void)updateStepAtIndex:(NSInteger)index
                    stage:(A2ProgressStepStage)stage
                  message:(NSString *)message
                 progress:(double)progress
                     rate:(NSString *)rate {
    if (index < 0 || index >= (NSInteger)_items.count) return;
    [_items[index] applyStage:stage message:message progress:progress rate:rate];
}

#pragma mark - 动作

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onCancel) self.onCancel();
    }];
}

- (void)dismissWithCompletion:(void (^)(void))completion {
    [self dismissViewControllerAnimated:YES completion:completion];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    // ZL2: cardColor(false) + onCardColor()
    _card.subviews.firstObject.backgroundColor = t.cSurfaceContainerHigh;
    _titleLabel.textColor = t.cOnSurface;

    _cancelButton.backgroundColor = t.cPrimary;
    [_cancelButton setTitleColor:t.cOnPrimary forState:UIControlStateNormal];

    for (A2ProgressTaskItem *item in _items) [item applyTheme];
}

@end
