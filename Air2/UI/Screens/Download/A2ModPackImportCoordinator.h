//
//  A2ModPackImportCoordinator.h
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
//  整合包导入的前端流程编排（本地文件导入）。
//
//  流程与 ZL2 的本地导入一致：
//    免责提示 → 选文件 → 版本命名 → 进度 → 结果
//
//  为什么单独一个类：
//    下载列表页负责「搜索 / 筛选 / 分页」，导入是另一件事；
//    把五步弹窗流程塞进列表页会让它同时承担两组不相干的关注点。
//
//  边界：
//    只做弹窗编排与用户输入收集，真正的安装交给 Core 的 A2ModPackInstaller。
//    本场景允许使用系统文件选择器（游戏安装 / 整合包安装是明文例外）。
//    其余弹窗一律走自研 MD3 弹窗（A2AlertDialog / A2InputDialog / A2ProgressDialog）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2ModPackImportCoordinator : NSObject

/// 从 host 发起整个导入流程。host 不保留（弱引用），通常就是列表页自己。
- (void)startFrom:(UIViewController *)host;

@end

NS_ASSUME_NONNULL_END
