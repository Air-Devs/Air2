//
//  A2DownloadProgressRow.m
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
//  下载进度展示块的实现。见头文件的形态说明。
//

#import "A2DownloadProgressRow.h"
#import "A2ProgressBar.h"
#import "A2ThemeManager.h"
#import "A2ColorScheme.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2DownloadProgressRow ()

@property (nonatomic, strong) UILabel *stageLabel;
@property (nonatomic, strong) UILabel *percentLabel;
@property (nonatomic, strong) A2ProgressBar *bar;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *speedLabel;
@property (nonatomic, strong) UILabel *separatorLabel;
@property (nonatomic, strong) UILabel *remainingLabel;
@property (nonatomic, assign) A2DownloadProgressTone tone;
@property (nonatomic, assign) CGFloat progress;

@end

@implementation A2DownloadProgressRow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.translatesAutoresizingMaskIntoConstraints = NO;
    _tone = A2DownloadProgressToneNeutral;
    _progress = 0;
    _showsPercent = YES;

    _stageLabel = [self makeLabelWithFont:[A2Typography caption] alignment:NSTextAlignmentLeft];
    _percentLabel = [self makeLabelWithFont:[A2Typography numeric] alignment:NSTextAlignmentRight];

    _bar = [[A2ProgressBar alloc] initWithFrame:CGRectZero];
    _bar.translatesAutoresizingMaskIntoConstraints = NO;
    // 文字由本组件自己排（阶段 / 已下总量 / 速度 / 剩余时间），
    // 进度条只保留轨道那一条，避免它自带的空文字行撑出一段空白。
    _bar.trackOnly = YES;

    _detailLabel = [self makeLabelWithFont:[A2Typography numeric] alignment:NSTextAlignmentLeft];
    _speedLabel = [self makeLabelWithFont:[A2Typography numeric] alignment:NSTextAlignmentRight];
    _separatorLabel = [self makeLabelWithFont:[A2Typography numeric] alignment:NSTextAlignmentRight];
    _separatorLabel.text = @"·";
    _remainingLabel = [self makeLabelWithFont:[A2Typography numeric] alignment:NSTextAlignmentRight];
    // 首次配置前先藏起来：否则空白状态会留下一个孤零零的「·」。
    _speedLabel.hidden = YES;
    _separatorLabel.hidden = YES;
    _remainingLabel.hidden = YES;

    // 上行：阶段 + 百分比。百分比不参与压缩，阶段文字先截断。
    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[_stageLabel,
                                                                        _percentLabel]];
    topRow.translatesAutoresizingMaskIntoConstraints = NO;
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.spacing = A2SpaceS;
    topRow.alignment = UIStackViewAlignmentFirstBaseline;
    [_stageLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                forAxis:UILayoutConstraintAxisHorizontal];
    // 左侧文字吸收富余宽度，右侧的百分比才能贴到行尾（否则两段文字会挤在左边）。
    [_stageLabel setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];

    // 下行：已下/总量 + 右侧「速度 · 剩余」。右侧整组靠右，速度在最右。
    UIStackView *rightRow = [[UIStackView alloc] initWithArrangedSubviews:@[_speedLabel,
                                                                           _separatorLabel,
                                                                           _remainingLabel]];
    rightRow.translatesAutoresizingMaskIntoConstraints = NO;
    rightRow.axis = UILayoutConstraintAxisHorizontal;
    rightRow.spacing = A2SpaceXS;
    rightRow.alignment = UIStackViewAlignmentFirstBaseline;

    UIStackView *bottomRow = [[UIStackView alloc] initWithArrangedSubviews:@[_detailLabel,
                                                                            rightRow]];
    bottomRow.translatesAutoresizingMaskIntoConstraints = NO;
    bottomRow.axis = UILayoutConstraintAxisHorizontal;
    bottomRow.spacing = A2SpaceS;
    bottomRow.alignment = UIStackViewAlignmentFirstBaseline;
    [_detailLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                 forAxis:UILayoutConstraintAxisHorizontal];
    [_detailLabel setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[topRow, _bar, bottomRow]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceXS;
    stack.alignment = UIStackViewAlignmentFill;
    [stack setCustomSpacing:A2SpaceS afterView:_bar];
    [self addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
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

#pragma mark - 配置

- (UILabel *)makeLabelWithFont:(UIFont *)font alignment:(NSTextAlignment)alignment {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textAlignment = alignment;
    label.numberOfLines = 1;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return label;
}

- (void)setStageText:(NSString *)stageText {
    _stageText = [stageText copy];
    _stageLabel.text = stageText;
    _stageLabel.hidden = (stageText.length == 0);
}

- (void)setDetailText:(NSString *)detailText {
    _detailText = [detailText copy];
    _detailLabel.text = detailText;
    _detailLabel.hidden = (detailText.length == 0);
}

- (void)setSpeedText:(NSString *)speedText {
    _speedText = [speedText copy];
    _speedLabel.text = speedText;
    _speedLabel.hidden = (speedText.length == 0);
    [self updateSeparatorVisibility];
}

- (void)setRemainingText:(NSString *)remainingText {
    _remainingText = [remainingText copy];
    _remainingLabel.text = remainingText;
    _remainingLabel.hidden = (remainingText.length == 0);
    [self updateSeparatorVisibility];
}

- (void)setShowsPercent:(BOOL)showsPercent {
    _showsPercent = showsPercent;
    _percentLabel.hidden = !showsPercent;
    // 总大小未知时轨道上只有一个来回滑动的指示段 —— 没有分母就没有百分比。
    _bar.indeterminate = !showsPercent;
}

/// 速度与剩余时间之间的间隔点：只有两边都在时才显示，否则留下一个悬空的「·」。
- (void)updateSeparatorVisibility {
    BOOL both = (_speedLabel.hidden == NO && _remainingLabel.hidden == NO);
    _separatorLabel.hidden = !both;
}

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated {
    _progress = MAX(0, MIN(1, progress));
    [_bar setProgress:_progress animated:animated];
    _percentLabel.text = [NSString stringWithFormat:@"%.0f%%", _progress * 100.0];
}

- (void)applyTone:(A2DownloadProgressTone)tone {
    _tone = tone;
    [self applyTheme];
}

#pragma mark - 主题

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    UIColor *accent = t.cOnSurfaceVariant;
    switch (_tone) {
        case A2DownloadProgressToneActive:  accent = t.cPrimary; break;
        case A2DownloadProgressToneSuccess: accent = t.cSuccess; break;
        case A2DownloadProgressToneError:   accent = t.cError; break;
        case A2DownloadProgressToneNeutral: accent = t.cOnSurfaceVariant; break;
    }

    // 阶段文字带色调（它就是「这台机器现在在干什么」）；
    // 百分比用 onSurface 靠字号立住，速度/剩余/已下量退到 onSurfaceVariant。
    // 强调色只落在「状态」与进度条本身，避免一行里三种彩色抢注意力。
    _stageLabel.textColor = accent;
    _percentLabel.textColor = t.cOnSurface;
    _detailLabel.textColor = t.cOnSurfaceVariant;
    _speedLabel.textColor = t.cOnSurfaceVariant;
    _remainingLabel.textColor = t.cOnSurfaceVariant;
    _separatorLabel.textColor = t.cOutline;

    _bar.indicatorColor = accent;
    [_bar applyTheme];
}

@end
