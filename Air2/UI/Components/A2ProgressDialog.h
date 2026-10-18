//
//  A2ProgressDialog.h
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
//  MD3 进度弹窗 —— 环形总进度 + 阶段清单 + 取消。
//
//  对应 ZL2 的 TitleTaskFlowDialog：一个长流程在弹窗里展示「走到哪一步了」，
//  每步有 待执行 / 进行中 / 已完成 三态，并随时可取消。
//
//  与 A2DialogViewController 的差别：
//    · 默认禁止点遮罩关闭 —— 安装类流程不能误触中断
//    · 取消按钮走 onCancel 回调，由调用方负责真正中断任务
//

#import <UIKit/UIKit.h>
#import "A2DialogViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2ProgressDialog : A2DialogViewController

/// stageTitles 按流程顺序给出每一步的短名（如「解析整合包」）
- (instancetype)initWithTitle:(nullable NSString *)title stageTitles:(NSArray<NSString *> *)stageTitles;

/// 取消回调。点「取消」后触发，调用方负责停掉在途任务。
@property (nonatomic, copy, nullable) void (^onCancel)(void);

/// 更新进度。stage 为当前阶段下标；progress 为该阶段自身进度 0~1；
/// message 为这一瞬间在做什么（可空）。
- (void)updateStage:(NSInteger)stage progress:(CGFloat)progress message:(nullable NSString *)message;

@end

NS_ASSUME_NONNULL_END
