//
//  A2DownloadTargetPicker.h
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
//  A2DownloadTargetPicker.h
//  Air2
//
//  下载目标选择 —— 对照 ZL2 的 DownloadDialog（_Download.Single.kt）。
//
//  下载资源（mod / 资源包 / 光影 / 存档）时要先确认：
//    · 装到哪个版本（可多选 —— 同一个 mod 想装到几个版本里）
//    · 有哪些前置依赖（有些 mod 需要前置，ZL2 会列出来让用户一起装）
//    · 依赖是否已装（已装的打勾标出，不重复下）
//
//  为什么要这一步：
//    直接下载有歧义 —— 用户装了多个版本时，不知道装进哪个。
//    ZL2 的做法是弹窗确认，并把依赖一并处理掉。
//

#import <UIKit/UIKit.h>
#import "A2ContentSource.h"
#import "A2VersionManager.h"

NS_ASSUME_NONNULL_BEGIN

/// 依赖项（对照 ZL2 的 DependencyEntry）
@interface A2DownloadDependency : NSObject
@property (nonatomic, copy) NSString *projectID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) A2ContentPlatform platform;
@property (nonatomic, assign) A2ContentClass contentClass;
/// 是否已安装
@property (nonatomic, assign) BOOL installed;
@end

@interface A2DownloadTargetPicker : NSObject

/// 弹出选择框。
///
/// @param host 呈现的宿主控制器
/// @param project 要下载的项目
/// @param contentClass 资源类别（决定目标目录）
/// @param dependencies 前置依赖（可为空）
/// @param onConfirm 确认回调：(选中的版本列表, 要一起下载的依赖)
+ (void)presentFrom:(UIViewController *)host
            project:(A2ContentItem *)project
       contentClass:(A2ContentClass)contentClass
       dependencies:(nullable NSArray<A2DownloadDependency *> *)dependencies
          onConfirm:(void (^)(NSArray<A2Version *> *versions,
                              NSArray<A2DownloadDependency *> *deps))onConfirm;

@end

NS_ASSUME_NONNULL_END
