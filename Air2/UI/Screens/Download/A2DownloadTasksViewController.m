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
#import "A2GlassCard.h"
#import "A2ProgressBar.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import "A2ThemeManager.h"
#import "A2Log.h"
#import "A2Toast.h"

static NSString *const kDownloadTaskCellID = @"A2DownloadTaskCell";

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

/// 引擎态 → 状态文案。
static NSString *A2DownloadStateText(A2DownloadState state) {
    switch (state) {
        case A2DownloadStateRunning:   return @"进行中";
        case A2DownloadStatePaused:    return @"已暂停";
        case A2DownloadStateCompleted: return @"已完成";
        case A2DownloadStateFailed:    return @"失败";
        case A2DownloadStateCancelled: return @"已取消";
    }
    return @"";
}

/// 引擎态 → 状态文案的强调色。
static UIColor *A2DownloadStateColor(A2DownloadState state, A2ColorScheme *scheme) {
    switch (state) {
        case A2DownloadStateRunning:   return scheme.cPrimary;
        case A2DownloadStatePaused:    return scheme.cWarning;
        case A2DownloadStateCompleted: return scheme.cSuccess;
        case A2DownloadStateFailed:    return scheme.cError;
        case A2DownloadStateCancelled: return scheme.cOnSurfaceVariant;
    }
    return scheme.cOnSurfaceVariant;
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

/// 字节数 → 人类可读文本。
static NSString *A2DownloadFormatBytes(int64_t bytes) {
    if (bytes <= 0) return @"0 B";
    double value = (double)bytes;
    NSInteger unit = 0;
    while (value >= 1024.0 && unit < 3) {
        value /= 1024.0;
        unit += 1;
    }
    if (unit == 0) return [NSString stringWithFormat:@"%lld B", bytes];
    NSArray<NSString *> *names = @[@"B", @"KB", @"MB", @"GB"];
    return [NSString stringWithFormat:@"%.1f %@", value, names[(NSUInteger)unit]];
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
- (void)configureWithTask:(A2DownloadTask *)task;
- (void)applyTheme;
@end

@interface A2DownloadTaskCell ()
@property (nonatomic, strong) A2GlassCard *card;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) A2ProgressBar *bar;
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

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [A2Typography caption];
    self.statusLabel.numberOfLines = 1;

    UIStackView *titleRow = [[UIStackView alloc] initWithArrangedSubviews:
                             @[self.titleLabel, A2DownloadFlexibleSpacer(), self.statusLabel]];
    titleRow.translatesAutoresizingMaskIntoConstraints = NO;
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.spacing = A2SpaceS;
    titleRow.alignment = UIStackViewAlignmentCenter;

    self.subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.font = [A2Typography subtitleCard];
    self.subtitleLabel.numberOfLines = 1;
    self.subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    self.bar = [[A2ProgressBar alloc] initWithFrame:CGRectZero];
    self.bar.translatesAutoresizingMaskIntoConstraints = NO;

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
                                 @[titleRow, self.subtitleLabel, self.bar,
                                   self.errorLabel, self.actionRow]];
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    contentStack.axis = UILayoutConstraintAxisVertical;
    contentStack.spacing = A2SpaceS;
    contentStack.alignment = UIStackViewAlignmentFill;
    [cv addSubview:contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                              constant:-A2CardSpacing],

        [contentStack.topAnchor constraintEqualToAnchor:cv.topAnchor],
        [contentStack.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor],
        [contentStack.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
        [contentStack.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
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
}

#pragma mark - 配置

- (void)configureWithTask:(A2DownloadTask *)task {
    self.taskID = task.taskID;
    self.rowState = task.state;
    self.rowProgress = (CGFloat)task.progress;

    self.titleLabel.text = task.title.length ? task.title : task.taskID;
    self.statusLabel.text = A2DownloadStateText(task.state);
    self.subtitleLabel.text = task.subtitle;
    self.subtitleLabel.hidden = (task.subtitle.length == 0);

    BOOL showsError = (task.state == A2DownloadStateFailed && task.errorMessage.length > 0);
    self.errorLabel.text = task.errorMessage;
    self.errorLabel.hidden = !showsError;

    // 进度：总大小已知时展示「已下 / 总量」，否则只留进度条本体。
    if (task.totalBytes > 0) {
        self.bar.detailText = [NSString stringWithFormat:@"%@ / %@",
                               A2DownloadFormatBytes(task.downloadedBytes),
                               A2DownloadFormatBytes(task.totalBytes)];
    } else {
        self.bar.detailText = nil;
    }
    self.bar.speedText = task.speedText;
    [self.bar setProgress:self.rowProgress animated:NO];

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
    // 进度条的填充宽度按自身 bounds 计算；首帧布局完成后再补一次，避免配置时宽度还是 0。
    [self.bar setProgress:self.rowProgress animated:NO];
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
    self.errorLabel.textColor = t.cError;
    self.statusLabel.textColor = A2DownloadStateColor(self.rowState, t);
    [self.bar applyTheme];

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
@end

@implementation A2DownloadTasksViewController

- (void)viewDidLoad {
    // 非滚动页：一个独立 tableView 铺满内容区。必须写在 super 之前。
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = @"下载任务";

    self.activeTasks = @[];
    self.finishedTasks = @[];

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

- (void)setupTable {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 108;
    self.tableView.contentInset = UIEdgeInsetsMake(A2SpaceS, 0, A2SpaceXXL, 0);
    [self.tableView registerClass:A2DownloadTaskCell.class forCellReuseIdentifier:kDownloadTaskCellID];
    [self.plainContentView addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
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

    if (structureSame) {
        [self refreshVisibleCells];
    } else {
        [self.tableView reloadData];
    }
    [self updateEmptyState];
    [self updateClearButton];
}

/// 只重配可见行，进度跳动时不整表 reload。
- (void)refreshVisibleCells {
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        A2DownloadTask *task = [self taskAtIndexPath:indexPath];
        if (!task) continue;
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        if ([cell isKindOfClass:A2DownloadTaskCell.class]) {
            [(A2DownloadTaskCell *)cell configureWithTask:task];
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
    if (task) [cell configureWithTask:task];
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
