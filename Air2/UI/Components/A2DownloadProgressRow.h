//
//  A2DownloadProgressRow.h
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
//  一段下载进度的展示块（MD3 水平进度条 + 三行信息）。
//
//  形态（取自 ZL2 任务行已验证的信息层次，视觉按本仓 MD3 语义色重做）：
//
//      下载中                                    65%
//      ━━━━━━━━━━━━━━━━━━━━━━━━──────────────
//      12.4 MB / 45.0 MB            2.4 MB/s · 剩余 13 秒
//
//  三行分工：
//    · 上行：当前阶段（准备 / 下载 / 校验 / 完成）+ 右侧百分比
//    · 中行：进度条本体（总大小未知时切「不确定态」，轨道上来回滑动）
//    · 下行：已下/总量 + 平滑速度 + 剩余时间（数字全部等宽，跳变不抖）
//
//  只吃字符串与数值，不认识 A2DownloadTask —— 任务页的单行与「总进度」卡片
//  共用同一个展示块，口径不会分叉。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 进度块的语义色调。只表达含义，具体色值在 applyTheme 里按语义角色取。
typedef NS_ENUM(NSInteger, A2DownloadProgressTone) {
    A2DownloadProgressToneNeutral = 0,  ///< 未开始 / 已暂停 / 已取消：中性描边色
    A2DownloadProgressToneActive,       ///< 正在下载：primary
    A2DownloadProgressToneSuccess,      ///< 完成：success
    A2DownloadProgressToneError,        ///< 失败：error
};

@interface A2DownloadProgressRow : UIView

/// 当前阶段文字（准备 / 下载 / 校验 / 完成…）。
@property (nonatomic, copy, nullable) NSString *stageText;
/// 已下/总量，或总量未知时的「已下载 X」。
@property (nonatomic, copy, nullable) NSString *detailText;
/// 平滑后的速度文本，如 "2.4 MB/s"。
@property (nonatomic, copy, nullable) NSString *speedText;
/// 剩余时间文本，如 "剩余 13 秒"；nil 时整项隐藏（未知总量 / 速度为 0）。
@property (nonatomic, copy, nullable) NSString *remainingText;

/// 是否显示右侧百分比。NO = 总大小未知（chunked）：
/// 进度条切不确定态，不显示百分比、不显示剩余时间。
@property (nonatomic, assign) BOOL showsPercent;

@property (nonatomic, assign, readonly) CGFloat progress;

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
- (void)applyTone:(A2DownloadProgressTone)tone;
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
