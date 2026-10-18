//
//  A2ProgressDialog.m
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

#import "A2ProgressDialog.h"
#import "A2RingProgress.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

/// 环形进度直径：横屏 iPhone 高度有限，控制在 104 以内保证整窗不被压。
static const CGFloat A2ProgressRingSize = 104.0;
/// 阶段行图标边长
static const CGFloat A2ProgressStageIconSize = 18.0;

@interface A2ProgressDialog ()

@property (nonatomic, copy) NSArray<NSString *> *stageTitles;

@property (nonatomic, strong) A2RingProgress *ring;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *stageIcons;
@property (nonatomic, strong) NSMutableArray<UILabel *> *stageLabels;

@property (nonatomic, assign) NSInteger currentStage;
@property (nonatomic, assign) CGFloat currentStageProgress;

@end

@implementation A2ProgressDialog

- (instancetype)initWithTitle:(NSString *)title stageTitles:(NSArray<NSString *> *)stageTitles {
    self = [super init];
    if (self) {
        self.titleText = title;
        _stageTitles = [stageTitles copy] ?: @[];
        _stageIcons = [NSMutableArray array];
        _stageLabels = [NSMutableArray array];
        _currentStage = -1;
        // 安装类流程不允许误触中断，只能走「取消」按钮
        self.dismissOnBackdropTap = NO;
    }
    return self;
}

- (instancetype)init {
    return [self initWithTitle:nil stageTitles:@[]];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [self buildRing];
    [self buildMessageLabel];
    [self buildStageList];

    [self addButtonRowWithCancelTitle:@"取消导入"
                         cancelAction:nil
                         confirmTitle:nil
                        confirmAction:nil];

    [self applyTheme];
    [self refreshStages];
}

#pragma mark - 构建

- (void)buildRing {
    UIView *holder = [[UIView alloc] initWithFrame:CGRectZero];
    [self.contentStack addArrangedSubview:holder];

    A2RingProgress *ring = [[A2RingProgress alloc] initWithFrame:CGRectZero];
    ring.translatesAutoresizingMaskIntoConstraints = NO;
    ring.lineWidth = 6.0;
    [holder addSubview:ring];
    _ring = ring;

    [NSLayoutConstraint activateConstraints:@[
        [ring.centerXAnchor constraintEqualToAnchor:holder.centerXAnchor],
        [ring.topAnchor constraintEqualToAnchor:holder.topAnchor constant:A2SpaceS],
        [ring.bottomAnchor constraintEqualToAnchor:holder.bottomAnchor constant:-A2SpaceS],
        [ring.widthAnchor constraintEqualToConstant:A2ProgressRingSize],
        [ring.heightAnchor constraintEqualToConstant:A2ProgressRingSize],
    ]];
}

- (void)buildMessageLabel {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.numberOfLines = 2;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [A2Typography caption];
    label.hidden = YES;
    [self.contentStack addArrangedSubview:label];
    _messageLabel = label;
}

- (void)buildStageList {
    if (self.stageTitles.count == 0) {
        return;
    }

    UIStackView *list = [[UIStackView alloc] initWithFrame:CGRectZero];
    list.axis = UILayoutConstraintAxisVertical;
    list.alignment = UIStackViewAlignmentFill;
    list.spacing = A2SpaceS;

    for (NSString *rawTitle in self.stageTitles) {
        UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = A2SpaceS;

        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectZero];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [icon.widthAnchor constraintEqualToConstant:A2ProgressStageIconSize].active = YES;
        [icon.heightAnchor constraintEqualToConstant:A2ProgressStageIconSize].active = YES;
        [row addArrangedSubview:icon];
        [self.stageIcons addObject:icon];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.font = [A2Typography caption];
        label.text = rawTitle;
        [row addArrangedSubview:label];
        [self.stageLabels addObject:label];

        [list addArrangedSubview:row];
    }

    [self.contentStack addArrangedSubview:list];
}

#pragma mark - 进度

- (void)updateStage:(NSInteger)stage progress:(CGFloat)progress message:(NSString *)message {
    self.currentStage = stage;
    self.currentStageProgress = MAX(0.0, MIN(1.0, progress));

    NSInteger total = MAX((NSInteger)self.stageTitles.count, 1);
    CGFloat overall = ((CGFloat)stage + self.currentStageProgress) / (CGFloat)total;
    overall = MAX(0.0, MIN(1.0, overall));

    [self.ring setProgress:overall animated:YES];
    self.ring.centerText = [NSString stringWithFormat:@"%ld%%", (long)lround(overall * 100.0)];
    if (stage >= 0 && stage < (NSInteger)self.stageTitles.count) {
        self.ring.captionText = self.stageTitles[stage];
    }

    self.messageLabel.text = message;
    self.messageLabel.hidden = (message.length == 0);

    [self refreshStages];
}

- (void)refreshStages {
    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;

    for (NSUInteger i = 0; i < self.stageLabels.count; i++) {
        UIImageView *icon = self.stageIcons[i];
        UILabel *label = self.stageLabels[i];

        if ((NSInteger)i < self.currentStage) {
            icon.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
            icon.tintColor = scheme.cSuccess;
            label.textColor = scheme.cOnSurfaceVariant;
            label.font = [A2Typography caption];
        } else if ((NSInteger)i == self.currentStage) {
            icon.image = [UIImage systemImageNamed:@"circle.fill"];
            icon.tintColor = scheme.cPrimary;
            label.textColor = scheme.cOnSurface;
            label.font = [A2Typography subtitleCard];
        } else {
            icon.image = [UIImage systemImageNamed:@"circle"];
            icon.tintColor = scheme.cOutline;
            label.textColor = scheme.cOnSurfaceVariant;
            label.font = [A2Typography caption];
        }
    }
}

#pragma mark - 取消

- (void)cancelDialog {
    void (^cancelHandler)(void) = self.onCancel;
    [self dismissDialogWithCompletion:^{
        if (cancelHandler) {
            cancelHandler();
        }
    }];
}

#pragma mark - 主题

- (void)applyTheme {
    [super applyTheme];

    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;

    self.messageLabel.textColor = scheme.cOnSurfaceVariant;
    [self.ring applyTheme];
    [self refreshStages];
}

@end
