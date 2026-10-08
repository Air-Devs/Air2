//
//  A2CurseForgeKeyPrompt.h
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
//  CurseForge Key 请求框 —— 三处共用唯一实现（设置行、下载中心切换、
//  下载列表切换）。调用方只传 host 与完成回调，不各写一份 alert。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2CurseForgeKeyPrompt : NSObject

/// 弹出输入框。保存并验证通过调 completion(YES)，取消/无效调 completion(NO)。
/// 无效 Key 不存（避免存坏 Key 后处处 403），调用方自行回退状态。
+ (void)promptFrom:(UIViewController *)host
        completion:(void (^)(BOOL saved))completion;

@end

NS_ASSUME_NONNULL_END
