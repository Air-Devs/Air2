//
//  A2DownloadTasksViewController.m
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
//  下载任务列表 —— 进行中 / 已完成两组，行内可暂停、继续、重试、取消。
//
//  展示口径（参照 ZalithLauncher2 任务行的信息层次，视觉按本仓 MD3 重做）：
//    · 每个任务一行：阶段（准备 / 下载 / 校验 / 完成）+ 百分比 + 进度条 +
//      已下/总量 + 平滑速度 + 剩余时间；
//    · 两个以上任务同时进行时，表格上方多一张「总进度」卡：
//      字节加权的总进度条 + 总速度 + 总剩余时间 —— 单任务时不重复展示；
//    · 总大小未知（chunked）时进度条切不确定态，只显示已下字节与速度，
//      不编一个假百分比，也不给剩余时间。
//
//  速度不在引擎里做平滑：引擎每秒报一次真实吞吐（块状采样），
//  这里用 A2DownloadSpeedMeter 对最近 3 秒做滑动平均，只影响「看起来稳不稳」，
//  下载逻辑一行未改。
//
//  数据全部来自 A2DownloadTaskCenter：订阅 A2DownloadTasksDidChangeNotification，
//  进度通知很频繁（中心已做节流），所以刷新分两条路：
//    · 任务集合的「结构」（顺序 + taskID）没变 —— 只就地重配可见行，不动整表，
//      避免进度每次跳动都整表 reload 造成闪屏；
//    · 结构变了（新增/移除/分组切换）—— 才 reloadData。
//
//  状态直接读引擎态 A2DownloadState（含 Cancelled），不复用 UI 侧的 A2TaskState
//  （后者没有 Cancelled），这样重试/取消按钮的可用性可以由状态精确决定，
//  也省掉一次有损映射。
//

#import "A2DownloadTasksViewController.h"
#import "A2DownloadTaskCenter.h"
#import "A2DownloadTask.h"
#import "A2ContentSource.h"
#import "A2GlassCard.h"
#import "A2DownloadProgressRow.h"
#import "A2DownloadSpeedMeter.h"
#import "A2DownloadProgressFormatter.h"
#import "A2RemoteImageView.h"
#import "A2ResourceBadge.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import "A2ThemeManager.h"
#import "A2Log.h"
#import "A2Toast.h"

static NSString *const kDownloadTaskCellID = @"A2DownloadTaskCell";

/// 任务行左侧资源图标边长。
static const CGFloat A2DownloadTaskIconSize = 44;

/// 分组：进行中 / 已完成
typedef NS_ENUM(NSInteger, A2DownloadTaskSection) {
    A2DownloadTaskSectionActive = 0,
    A2DownloadTaskSectionFinished,
    A2DownloadTaskSectionCount,
};

/// 行内操作。暂停与继续拆成两个动作，便于日志区分。
typedef NS_ENUM(NSInteger, A2DownloadRowAction) {
    A2DownloadRowActionPause = 0,
    A2DownloadRowActionResume,
    A2DownloadRowActionRetry,
    A2DownloadRowActionCancel,
};

#pragma mark - 文案与配色

/// 任务 → 当前阶段文字。
///
/// 阶段只能从「引擎暴露给 UI 的事实」里推，不编造：
///   · 还没有任何字节落地 → 准备中；
///   · 已知总量且字节已下齐、但完成回调未到 → 校验中（引擎此刻在算 SHA1）；
///   · 其余进行中 → 下载中。
/// 「解压」不在这里：解压属于安装器（安装进度页的 7 阶段清单），
/// 下载引擎只负责把文件落到磁盘。
static NSString *A2DownloadStageText(A2DownloadTask *task) {
    switch (task.state) {
        case A2DownloadStateRunning:
            if (task.totalBytes > 0 && task.downloadedBytes >= task.totalBytes) return @"校验中";
            if (task.downloadedBytes <= 0) return @"准备中";
            return @"下载中";
        case A2DownloadStatePaused:    return @"已暂停";
        case A2DownloadStateCompleted: return @"已完成";
        case A2DownloadStateFailed:    return @"失败";
        case A2DownloadStateCancelled: return @"已取消";
    }
    return @"";
}

/// 引擎态 → 进度块色调（具体色值由进度块按语义角色解析）。
static A2DownloadProgressTone A2DownloadProgressToneForState(A2DownloadState state) {
    switch (state) {
        case A2DownloadStateRunning:   return A2DownloadProgressToneActive;
        case A2DownloadStateCompleted: return A2DownloadProgressToneSuccess;
        case A2DownloadStateFailed:    return A2DownloadProgressToneError;
        case A2DownloadStatePaused:
        case A2DownloadStateCancelled: return A2DownloadProgressToneNeutral;
    }
    return A2DownloadProgressToneNeutral;
}

/// 单个任务的一行文字化结果：进度块只吃字符串，这里统一算出四个字段。
static void A2DownloadApplyTaskToProgressRow(A2DownloadProgressRow *row,
                                             A2DownloadTask *task,
                                             double smoothedSpeed) {
    BOOL hasKnownTotal = (task.totalBytes > 0);
    BOOL running = (task.state == A2DownloadStateRunning) && smoothedSpeed > 0;

    row.stageText = A2DownloadStageText(task);
    row.showsPercent = hasKnownTotal;

    if (hasKnownTotal) {
        row.detailText = [NSString stringWithFormat:@"%@ / %@",
                          [A2DownloadProgressFormatter bytesText:task.downloadedBytes],
                          [A2DownloadProgressFormatter bytesText:task.totalBytes]];
        row.remainingText = running
            ? [A2DownloadProgressFormatter remainingTextWithBytes:(task.totalBytes - task.downloadedBytes)
                                                            speed:smoothedSpeed]
            : nil;
    } else {
        // 总大小未知：只报已下字节，不报百分比、不报剩余时间。
        row.detailText = [NSString stringWithFormat:@"已下载 %@",
                          [A2DownloadProgressFormatter bytesText:task.downloadedBytes]];
        row.remainingText = nil;
    }

    row.speedText = running
        ? [A2DownloadProgressFormatter speedText:smoothedSpeed]
        : nil;

    // 不做动画：任务页 100ms 就刷新一次，逐帧弹簧只会让填充块一直在追目标，
    // 看起来反而「发黏」；进度本身每步变化很小，直接落位更干净（动效克制）。
    [row setProgress:(CGFloat)task.progress animated:NO];
    [row applyTone:A2DownloadProgressToneForState(task.state)];
}

/// 两个任务列表的「结构」是否一致：长度相同且逐项 taskID 相同。
/// 结构没变就只重配可见行，避免进度跳动时整表 reload 闪屏。
static BOOL A2DownloadTaskListSameStructure(NSArray<A2DownloadTask *> *a,
                                            NSArray<A2DownloadTask *> *b) {
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        if (![a[i].taskID isEqualToString:b[i].taskID]) return NO;
    }
    return YES;
}


/// 弹性占位：吸收水平方向的富余空间，用来把两侧内容顶到两端。
static UIView *A2DownloadFlexibleSpacer(void) {
    UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
    [spacer setContentCompressionResistancePriority:1 forAxis:UILayoutConstraintAxisHorizontal];
    return spacer;
}

/// 行内小胶囊按钮。
static UIButton *A2DownloadMakePillButton(NSString *title) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.font = [A2Typography button];
    button.layer.cornerRadius = A2RadiusS;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.contentEdgeInsets = UIEdgeInsetsMake(A2SpaceXS, A2SpaceM, A2SpaceXS, A2SpaceM);
    button.clipsToBounds = YES;
    [button setTitle:title forState:UIControlStateNormal];
    [button.heightAnchor constraintEqualToConstant:34].active = YES;
    return button;
}

#pragma mark - 任务单元格

@class A2DownloadTaskCell;

@protocol A2DownloadTaskCellDelegate <NSObject>
- (void)downloadTaskCell:(A2DownloadTaskCell *)cell
        didTriggerAction:(A2DownloadRowAction)action
               forTaskID:(NSString *)taskID;
@end

@interface A2DownloadTaskCell : UITableViewCell
@property (nonatomic, weak, nullable) id<A2DownloadTaskCellDelegate> delegate;
/// 配置一行。smoothedSpeed 是展示层滑动平均后的速度（bytes/s），
/// 非运行中的任务传 0 —— 速度与剩余时间会自动隐藏。
- (void)configureWithTask:(A2DownloadTask *)task smoothedSpeed:(double)smoothedSpeed;
- (void)applyTheme;
@end

@interface A2DownloadTaskCell ()
@property (nonatomic, strong) A2GlassCard *card;
@property (nonatomic, strong) A2RemoteImageView *iconView;
@property (nonatomic, strong) A2ClassBadge *classBadge;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) A2DownloadProgressRow *progressRow;
@property (nonatomic, strong) UIStackView *actionRow;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, copy, nullable) NSString *taskID;
@property (nonatomic, assign) A2DownloadState rowState;
@property (nonatomic, assign) CGFloat rowProgress;
@end

@implementation A2DownloadTaskCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    self.card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    self.card.translatesAutoresizingMaskIntoConstraints = NO;
    self.card.cornerRadius = A2RadiusL;
    self.card.elevation = A2CardElevationLow;
    self.card.contentInsets = UIEdgeInsetsMake(A2SpaceM, A2SpaceM, A2SpaceM, A2SpaceM);
    [self.contentView addSubview:self.card];
    UIView *cv = self.card.contentView;

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [A2Typography titleCard];
    self.titleLabel.numberOfLines = 1;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    // 资源图标：与搜索页/详情页同一张图，走 A2RemoteImageView（自带缓存与首字母占位）。
    self.iconView = [[A2RemoteImageView alloc] initWithFrame:CGRectZero];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.cornerRadius = A2RadiusM;
    self.iconView.contentMode = UIViewContentModeScaleAspectFill;
    self.iconView.clipsToBounds = YES;

    // 资源类型徽标：复用资源卡片上的同一个组件（图标 + 名称），不另画一套。
    self.classBadge = [[A2ClassBadge alloc] initWithContentClass:A2ContentClassMod];
    self.classBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.classBadge.hidden = YES;

    // 资源版本（版本号 / 文件显示名）。
    self.versionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [A2Typography caption];
    self.versionLabel.numberOfLines = 1;
    self.versionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.versionLabel.hidden = YES;

    UIStackView *metaRow = [[UIStackView alloc] initWithArrangedSubviews:
                            @[self.classBadge, self.versionLabel, A2DownloadFlexibleSpacer()]];
    metaRow.translatesAutoresizingMaskIntoConstraints = NO;
    metaRow.axis = UILayoutConstraintAxisHorizontal;
    metaRow.spacing = A2SpaceS;
    metaRow.alignment = UIStackViewAlignmentCenter;

    // 标题单独占一行；状态（准备/下载/校验…）由下面的进度块统一承载，
    // 不在标题右侧再放一个「进行中」—— 同一件事说两遍。
    UIStackView *titleRow = [[UIStackView alloc] initWithArrangedSubviews:
                             @[self.titleLabel, A2DownloadFlexibleSpacer()]];
    titleRow.translatesAutoresizingMaskIntoConstraints = NO;
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.spacing = A2SpaceS;
    titleRow.alignment = UIStackViewAlignmentCenter;

    self.subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.font = [A2Typography subtitleCard];
    self.subtitleLabel.numberOfLines = 1;
    self.subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    // 进度块：阶段 + 百分比 / 进度条 / 已下总量 + 速度 + 剩余时间。
    self.progressRow = [[A2DownloadProgressRow alloc] initWithFrame:CGRectZero];

    self.errorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorLabel.font = [A2Typography caption];
    self.errorLabel.numberOfLines = 0;

    self.toggleButton = A2DownloadMakePillButton(@"暂停");
    [self.toggleButton addTarget:self action:@selector(handleToggle)
                forControlEvents:UIControlEventTouchUpInside];
    self.retryButton = A2DownloadMakePillButton(@"重试");
    [self.retryButton addTarget:self action:@selector(handleRetry)
               forControlEvents:UIControlEventTouchUpInside];
    self.cancelButton = A2DownloadMakePillButton(@"取消");
    [self.cancelButton addTarget:self action:@selector(handleCancel)
                forControlEvents:UIControlEventTouchUpInside];

    self.actionRow = [[UIStackView alloc] initWithArrangedSubviews:
                      @[self.toggleButton, self.retryButton, self.cancelButton]];
    self.actionRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionRow.axis = UILayoutConstraintAxisHorizontal;
    self.actionRow.spacing = A2SpaceS;
    self.actionRow.alignment = UIStackViewAlignmentCenter;

    UIStackView *contentStack = [[UIStackView alloc] initWithArrangedSubviews:
                                 @[titleRow, metaRow, self.subtitleLabel, self.progressRow,
                                   self.errorLabel, self.actionRow]];
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    contentStack.axis = UILayoutConstraintAxisVertical;
    contentStack.spacing = A2SpaceS;
    contentStack.alignment = UIStackViewAlignmentFill;

    // 图标在左、文字区在右：图标顶对齐，行高由文字区决定。
    UIStackView *bodyRow = [[UIStackView alloc] initWithArrangedSubviews:
                            @[self.iconView, contentStack]];
    bodyRow.translatesAutoresizingMaskIntoConstraints = NO;
    bodyRow.axis = UILayoutConstraintAxisHorizontal;
    bodyRow.spacing = A2SpaceM;
    bodyRow.alignment = UIStackViewAlignmentTop;
    [cv addSubview:bodyRow];

    [NSLayoutConstraint activateConstraints:@[
        [self.card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                              constant:-A2CardSpacing],

        [self.iconView.widthAnchor constraintEqualToConstant:A2DownloadTaskIconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:A2DownloadTaskIconSize],

        [bodyRow.topAnchor constraintEqualToAnchor:cv.topAnchor],
        [bodyRow.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor],
        [bodyRow.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
        [bodyRow.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
    ]];

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.taskID = nil;
    self.delegate = nil;
    // 复用时必须掐掉上一次的下载回调，否则上一张图会落到新行上。
    [self.iconView cancelLoading];
}

#pragma mark - 配置

- (void)configureWithTask:(A2DownloadTask *)task smoothedSpeed:(double)smoothedSpeed {
    self.taskID = task.taskID;
    self.rowState = task.state;
    self.rowProgress = (CGFloat)task.progress;

    self.titleLabel.text = task.title.length ? task.title : task.taskID;
    self.subtitleLabel.text = task.subtitle;
    self.subtitleLabel.hidden = (task.subtitle.length == 0);

    // 资源图标 / 类型 / 版本 —— 这三项就是「下载任务页过于简陋」缺的信息。
    // 先给首字母兜底再请求网络图：无图项目也不会留下空方块。
    self.iconView.fallbackText = task.title.length ? [task.title substringToIndex:1] : nil;
    [self.iconView setImageURL:task.iconURL placeholder:nil];

    if (task.resourceClass == A2DownloadResourceClassUnknown) {
        self.classBadge.hidden = YES;
    } else {
        self.classBadge.contentClass = (A2ContentClass)task.resourceClass;
        self.classBadge.hidden = NO;
    }

    self.versionLabel.text = task.resourceVersion;
    self.versionLabel.hidden = (task.resourceVersion.length == 0);

    BOOL showsError = (task.state == A2DownloadStateFailed && task.errorMessage.length > 0);
    self.errorLabel.text = task.errorMessage;
    self.errorLabel.hidden = !showsError;

    // 进度块：百分比 / 已下总量 / 平滑速度 / 剩余时间。
    // 阶段文字与色调都在 A2DownloadApplyTaskToProgressRow 里统一算，
    // 单任务行与「总进度」卡因此不会出现两种口径。
    A2DownloadApplyTaskToProgressRow(self.progressRow, task, smoothedSpeed);

    // 按钮矩阵：Running/Paused → 暂停或继续 + 取消；Failed/Cancelled → 重试；Completed → 无。
    BOOL active = (task.state == A2DownloadStateRunning || task.state == A2DownloadStatePaused);
    self.toggleButton.hidden = !active;
    [self.toggleButton setTitle:(task.state == A2DownloadStateRunning ? @"暂停" : @"继续")
                       forState:UIControlStateNormal];
    self.retryButton.hidden = !(task.state == A2DownloadStateFailed ||
                                task.state == A2DownloadStateCancelled);
    self.cancelButton.hidden = !active;
    self.actionRow.hidden = (self.toggleButton.hidden && self.retryButton.hidden &&
                             self.cancelButton.hidden);

    [self applyTheme];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 首帧布局完成后再补一次进度：配置时进度块的宽度还是 0，
    // 填充比例要按最终宽度重算才不会停在 0。
    [self.progressRow setProgress:self.rowProgress animated:NO];
}

#pragma mark - 交互

- (void)handleToggle {
    // 运行中 → 暂停；已暂停 → 继续。
    A2DownloadRowAction action = (self.rowState == A2DownloadStateRunning)
        ? A2DownloadRowActionPause : A2DownloadRowActionResume;
    [self notifyDelegateWithAction:action];
}

- (void)handleRetry {
    [self notifyDelegateWithAction:A2DownloadRowActionRetry];
}

- (void)handleCancel {
    [self notifyDelegateWithAction:A2DownloadRowActionCancel];
}

- (void)notifyDelegateWithAction:(A2DownloadRowAction)action {
    if (self.taskID.length == 0) return;
    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    [self.delegate downloadTaskCell:self didTriggerAction:action forTaskID:self.taskID];
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    [self.card applyTheme];

    self.titleLabel.textColor = t.cOnSurface;
    self.subtitleLabel.textColor = t.cOnSurfaceVariant;
    self.versionLabel.textColor = t.cOnSurfaceVariant;
    self.errorLabel.textColor = t.cError;
    [self.iconView applyTheme];
    [self.progressRow applyTheme];

    // 主操作（暂停/继续、重试）用主色实心；取消是次要操作，用中性容器色。
    for (UIButton *button in @[self.toggleButton, self.retryButton]) {
        button.backgroundColor = t.cPrimary;
        [button setTitleColor:t.cOnPrimary forState:UIControlStateNormal];
    }
    self.cancelButton.backgroundColor = t.cSurfaceContainerHigh;
    [self.cancelButton setTitleColor:t.cOnSurfaceVariant forState:UIControlStateNormal];
}

@end

#pragma mark - 任务列表页

@interface A2DownloadTasksViewController () <UITableViewDataSource, UITableViewDelegate,
                                             A2DownloadTaskCellDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, strong) NSArray<A2DownloadTask *> *activeTasks;
@property (nonatomic, strong) NSArray<A2DownloadTask *> *finishedTasks;

/// 「总进度」卡：两个以上任务同时进行时出现在表格上方（字节加权）。
/// 单个任务时行内已经把话说全了，这张卡不出现 —— 不做重复信息。
@property (nonatomic, strong) A2GlassCard *summaryCard;
@property (nonatomic, strong) UILabel *summaryTitleLabel;
@property (nonatomic, strong) A2DownloadProgressRow *summaryRow;
/// taskID → 展示层滑动平均测速器（下载逻辑不参与，只平滑显示）。
@property (nonatomic, strong) NSMutableDictionary<NSString *, A2DownloadSpeedMeter *> *speedMeters;
/// taskID → 本次刷新的平滑速度（bytes/s）。
/// 一次刷新只采一次样，单任务行与总进度卡都读这份结果 —— 采样顺序与可见性都不影响数字。
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *smoothedSpeeds;
/// 表格上边依附谁：卡片可见 → 卡片；不可见 → 内容区顶部。
/// 隐藏视图仍占约束位，所以用两条互斥约束切换，而不是只藏卡片。
@property (nonatomic, strong) NSLayoutConstraint *tableTopToSummary;
@property (nonatomic, strong) NSLayoutConstraint *tableTopToContent;
@end

@implementation A2DownloadTasksViewController

- (void)viewDidLoad {
    // 非滚动页：一个独立 tableView 铺满内容区。必须写在 super 之前。
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = @"下载任务";

    self.activeTasks = @[];
    self.finishedTasks = @[];
    self.speedMeters = [NSMutableDictionary dictionary];

    [self setupSummaryCard];
    [self setupTable];
    [self setupEmptyLabel];
    [self setupClearButton];
    [self applyTheme];
    [self reloadTasks];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleTasksChanged:)
                                              name:A2DownloadTasksDidChangeNotification
                                            object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 布局

/// 「总进度」卡。只在多任务时显示，内容与单任务行同一套词、同一套字号。
- (void)setupSummaryCard {
    self.summaryCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    self.summaryCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryCard.cornerRadius = A2RadiusL;
    self.summaryCard.elevation = A2CardElevationLow;
    self.summaryCard.contentInsets = UIEdgeInsetsMake(A2SpaceM, A2SpaceM, A2SpaceM, A2SpaceM);
    self.summaryCard.hidden = YES;

    self.summaryTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.summaryTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryTitleLabel.font = [A2Typography titleCard];
    self.summaryTitleLabel.text = @"总进度";

    self.summaryRow = [[A2DownloadProgressRow alloc] initWithFrame:CGRectZero];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[self.summaryTitleLabel, self.summaryRow]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceS;
    stack.alignment = UIStackViewAlignmentFill;

    [self.summaryCard.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.summaryCard.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.summaryCard.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.summaryCard.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.summaryCard.contentView.trailingAnchor],
    ]];

    [self.plainContentView addSubview:self.summaryCard];
    [NSLayoutConstraint activateConstraints:@[
        [self.summaryCard.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor
                                                  constant:A2SpaceM],
        [self.summaryCard.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                     constant:A2PageMargin],
        [self.summaryCard.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                      constant:-A2PageMargin],
    ]];
}

- (void)setupTable {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 128;
    self.tableView.contentInset = UIEdgeInsetsMake(A2SpaceS, 0, A2SpaceXXL, 0);
    [self.tableView registerClass:A2DownloadTaskCell.class forCellReuseIdentifier:kDownloadTaskCellID];
    [self.plainContentView addSubview:self.tableView];

    self.tableTopToContent = [self.tableView.topAnchor
                              constraintEqualToAnchor:self.plainContentView.topAnchor];
    self.tableTopToSummary = [self.tableView.topAnchor
                              constraintEqualToAnchor:self.summaryCard.bottomAnchor
                                           constant:A2SpaceM];
    self.tableTopToContent.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                     constant:A2PageMargin],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                      constant:-A2PageMargin],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
    ]];
}

- (void)setupEmptyLabel {
    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.font = [A2Typography caption];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.text = @"暂无下载任务";
    [self.plainContentView addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.plainContentView.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.plainContentView.centerYAnchor
                                                      constant:-40],
        [self.emptyLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.plainContentView.leadingAnchor
                                                                   constant:A2PageMargin],
        [self.emptyLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.plainContentView.trailingAnchor
                                                                 constant:-A2PageMargin],
    ]];
}

- (void)setupClearButton {
    __weak typeof(self) weakSelf = self;
    self.clearButton = [self addTrailingButtonWithSymbol:@"trash" action:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [A2Log log:@"download-task: 清空已结束任务 count=%lu",
            (unsigned long)self.finishedTasks.count];
        [[A2DownloadTaskCenter shared] clearFinishedTasks];
        [A2Toast show:@"已清空已完成任务" inView:self.view];
    }];
}

#pragma mark - 数据

- (void)handleTasksChanged:(NSNotification *)note {
    // 中心的通知本该在主线程，这里再兜一层，避免将来改动后 UI 在后台线程被刷新。
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleTasksChanged:note];
        });
        return;
    }
    [self reloadTasks];
}

- (void)reloadTasks {
    A2DownloadTaskCenter *center = [A2DownloadTaskCenter shared];
    NSArray<A2DownloadTask *> *active = [center activeTasks];
    NSArray<A2DownloadTask *> *finished = [center finishedTasks];

    BOOL structureSame = A2DownloadTaskListSameStructure(active, self.activeTasks) &&
                         A2DownloadTaskListSameStructure(finished, self.finishedTasks);

    self.activeTasks = active;
    self.finishedTasks = finished;

    [self pruneSpeedMeters];

    NSMutableArray<A2DownloadTask *> *all = [NSMutableArray arrayWithArray:active];
    [all addObjectsFromArray:finished];
    self.smoothedSpeeds = [self sampleSpeedsForTasks:all];

    if (structureSame) {
        [self refreshVisibleCells];
    } else {
        [self.tableView reloadData];
    }
    [self updateSummaryWithActiveTasks:active];
    [self updateEmptyState];
    [self updateClearButton];
}

#pragma mark - 速度平滑

/// 一次刷新里给每个任务采一次样（活跃的写窗口，其余清零并返回 0）。
- (NSDictionary<NSString *, NSNumber *> *)sampleSpeedsForTasks:(NSArray<A2DownloadTask *> *)tasks {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
    for (A2DownloadTask *task in tasks) {
        result[task.taskID] = @([self smoothedSpeedForTask:task at:now]);
    }
    return result;
}

/// 某任务本次刷新的平滑速度（没有记录时按 0 处理）。
- (double)smoothedSpeedForTaskID:(NSString *)taskID {
    return [self.smoothedSpeeds[taskID] doubleValue];
}

/// 取（或建）某任务的展示测速器，写入本次采样并返回平滑速度（bytes/s）。
///
/// 只有运行中的任务参与采样：暂停 / 结束的任务清空窗口，恢复下载时从干净窗口
/// 重新测，不会把「暂停前的高速度」带进恢复后的第一次显示。
- (double)smoothedSpeedForTask:(A2DownloadTask *)task at:(NSTimeInterval)now {
    if (task.state != A2DownloadStateRunning) {
        [self.speedMeters[task.taskID] reset];
        return 0;
    }
    A2DownloadSpeedMeter *meter = self.speedMeters[task.taskID];
    if (!meter) {
        meter = [[A2DownloadSpeedMeter alloc] initWithWindow:3.0];
        self.speedMeters[task.taskID] = meter;
    }
    return [meter addSample:task.speed at:now];
}

/// 任务被移除（取消 / 清空）后，它的测速器也要跟着消失 —— 否则一直在字典里攒着。
- (void)pruneSpeedMeters {
    NSMutableSet<NSString *> *alive = [NSMutableSet set];
    for (A2DownloadTask *task in self.activeTasks) {
        [alive addObject:task.taskID];
    }
    for (NSString *taskID in self.speedMeters.allKeys) {
        if (![alive containsObject:taskID]) {
            [self.speedMeters removeObjectForKey:taskID];
        }
    }
}

#pragma mark - 总进度

/// 刷新「总进度」卡（字节加权）。
///
/// 加权口径：每个任务的 totalBytes 相加作分母、downloadedBytes 相加作分子；
/// 总大小未知（chunked）的任务只贡献已下字节（它有下载量、但没有可信分母），
/// 全部任务都未知总量时才退化成不确定态。
- (void)updateSummaryWithActiveTasks:(NSArray<A2DownloadTask *> *)tasks {
    // 单任务时行内已经把所有字段说全了：总进度卡只是重复信息。
    BOOL shows = (tasks.count >= 2);
    self.summaryCard.hidden = !shows;
    self.tableTopToSummary.active = shows;
    self.tableTopToContent.active = !shows;
    if (!shows) return;

    int64_t downloaded = 0;
    int64_t total = 0;
    BOOL hasKnownTotal = NO;
    double aggregateSpeed = 0;
    NSUInteger runningCount = 0;

    for (A2DownloadTask *task in tasks) {
        downloaded += MAX((int64_t)0, task.downloadedBytes);
        if (task.totalBytes > 0) {
            total += task.totalBytes;
            hasKnownTotal = YES;
        }
        aggregateSpeed += [self smoothedSpeedForTaskID:task.taskID];
        if (task.state == A2DownloadStateRunning) runningCount += 1;
    }

    BOOL allPaused = (runningCount == 0);
    double progress = (hasKnownTotal && total > 0) ? (double)downloaded / (double)total : 0;

    self.summaryTitleLabel.text = allPaused ? @"总进度 · 已全部暂停" : @"总进度";
    self.summaryRow.stageText = [NSString stringWithFormat:@"%lu 个任务",
                                 (unsigned long)tasks.count];
    self.summaryRow.showsPercent = hasKnownTotal;
    if (hasKnownTotal) {
        self.summaryRow.detailText = [NSString stringWithFormat:@"已下 %@ / %@",
                                      [A2DownloadProgressFormatter bytesText:downloaded],
                                      [A2DownloadProgressFormatter bytesText:total]];
        self.summaryRow.remainingText = allPaused
            ? nil
            : [A2DownloadProgressFormatter remainingTextWithBytes:(total - downloaded)
                                                            speed:aggregateSpeed];
    } else {
        self.summaryRow.detailText = [NSString stringWithFormat:@"已下载 %@",
                                      [A2DownloadProgressFormatter bytesText:downloaded]];
        self.summaryRow.remainingText = nil;
    }
    self.summaryRow.speedText = allPaused
        ? nil
        : [A2DownloadProgressFormatter speedText:aggregateSpeed];
    [self.summaryRow setProgress:(CGFloat)progress animated:NO];
    [self.summaryRow applyTone:(allPaused ? A2DownloadProgressToneNeutral
                                          : A2DownloadProgressToneActive)];
}

/// 只重配可见行，进度跳动时不整表 reload。
- (void)refreshVisibleCells {
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        A2DownloadTask *task = [self taskAtIndexPath:indexPath];
        if (!task) continue;
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        if ([cell isKindOfClass:A2DownloadTaskCell.class]) {
            [(A2DownloadTaskCell *)cell configureWithTask:task
                                            smoothedSpeed:[self smoothedSpeedForTaskID:task.taskID]];
        }
    }
}

- (nullable A2DownloadTask *)taskAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == A2DownloadTaskSectionActive) {
        if (indexPath.row < (NSInteger)self.activeTasks.count) return self.activeTasks[indexPath.row];
    } else if (indexPath.section == A2DownloadTaskSectionFinished) {
        if (indexPath.row < (NSInteger)self.finishedTasks.count) return self.finishedTasks[indexPath.row];
    }
    return nil;
}

- (void)updateEmptyState {
    BOOL empty = (self.activeTasks.count == 0 && self.finishedTasks.count == 0);
    self.emptyLabel.hidden = !empty;
}

- (void)updateClearButton {
    BOOL hasFinished = (self.finishedTasks.count > 0);
    self.clearButton.enabled = hasFinished;
    self.clearButton.alpha = hasFinished ? 1.0 : 0.35;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return A2DownloadTaskSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == A2DownloadTaskSectionActive) return self.activeTasks.count;
    if (section == A2DownloadTaskSectionFinished) return self.finishedTasks.count;
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    A2DownloadTaskCell *cell =
        [tableView dequeueReusableCellWithIdentifier:kDownloadTaskCellID forIndexPath:indexPath];
    cell.delegate = self;
    A2DownloadTask *task = [self taskAtIndexPath:indexPath];
    if (task) {
        [cell configureWithTask:task smoothedSpeed:[self smoothedSpeedForTaskID:task.taskID]];
    }
    return cell;
}

#pragma mark - UITableViewDelegate

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if ([self tableView:tableView numberOfRowsInSection:section] == 0) return nil;

    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [A2Typography titleCard];
    label.textColor = A2ThemeManager.shared.scheme.cOnSurface;
    label.text = (section == A2DownloadTaskSectionActive) ? @"进行中" : @"已完成";
    [header addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor],
        [label.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return [self tableView:tableView numberOfRowsInSection:section] > 0 ? 36 : 0;
}

#pragma mark - A2DownloadTaskCellDelegate

- (void)downloadTaskCell:(A2DownloadTaskCell *)cell
        didTriggerAction:(A2DownloadRowAction)action
               forTaskID:(NSString *)taskID {
    A2DownloadTaskCenter *center = [A2DownloadTaskCenter shared];
    switch (action) {
        case A2DownloadRowActionPause:
            [A2Log log:@"download-task: 暂停 %@", taskID];
            [center togglePauseTaskWithID:taskID];
            break;
        case A2DownloadRowActionResume:
            [A2Log log:@"download-task: 继续 %@", taskID];
            [center togglePauseTaskWithID:taskID];
            break;
        case A2DownloadRowActionRetry:
            [A2Log log:@"download-task: 重试 %@", taskID];
            [center retryTaskWithID:taskID];
            break;
        case A2DownloadRowActionCancel:
            [A2Log log:@"download-task: 取消 %@", taskID];
            [center cancelTaskWithID:taskID];
            break;
    }
}

#pragma mark - 主题

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    [super applyTheme];
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    self.emptyLabel.textColor = t.cOnSurfaceVariant;
    self.summaryTitleLabel.textColor = t.cOnSurface;
    [self.summaryCard applyTheme];
    [self.summaryRow applyTheme];

    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        if ([cell isKindOfClass:A2DownloadTaskCell.class]) {
            [(A2DownloadTaskCell *)cell applyTheme];
        }
    }
    // 分组标题在 viewForHeader 里直接取色，重载一次让它们跟着换（主题切换是低频事件）。
    [self.tableView reloadData];
}

@end
