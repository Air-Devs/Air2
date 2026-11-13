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
//  本地整合包导入 —— 对照 ZL2 的 ModpackImportViewModel。
//
//  与「从平台下载整合包」的区别：这里用户手上已经有文件了
//  （网盘、群聊、别的设备导出的 .mrpack / .zip）。
//
//  为什么是协调器而不是一整页：
//    入口长在整合包搜索页的筛选面板里（对齐 ZL2 的 SearchModPackScreen），
//    流程本身只有几步。做成一整页要多走「进页面 / 退回来」两趟，
//    而弹窗能原地盖住列表、装完自动收起。
//
//  流程（全 MD3 弹窗，唯一的系统弹窗是文件选择器 —— 文件 App 无法自研）：
//    1. 免责 / 兼容性提示（A2AlertDialog）
//    2. 选文件（UIDocumentPickerViewController）
//    3. 探测格式并解析清单（Modrinth / CurseForge / MCBBS / MultiMC）
//    4. 清单摘要 + 版本命名（A2InputDialog）
//    5. 安装进度，可取消（A2InstallProgressDialog + A2ModPackInstaller）
//    6. 结果提示（A2AlertDialog）
//
//  持有关系：host 强持有本协调器，流程结束回调 onFinish 时把属性置 nil。
//  协调器只弱引用 host —— 不自己抓自己（那是全局可变单例，见反石山守则）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2ModPackImportCoordinator : NSObject

/// host 强持有本协调器，流程结束回调 onFinish 时置 nil。
- (instancetype)initWithHost:(UIViewController *)host;

/// 流程结束（成功 / 失败 / 取消）回调，主线程。调用方在这里放掉对协调器的持有。
@property (nonatomic, copy, nullable) void (^onFinish)(void);

/// 开始整条导入流程。同一 host 上正在跑时不要重复调用。
- (void)start;

@end

NS_ASSUME_NONNULL_END
