//
//  A2GameDirMigration.h
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
//  游戏根目录改名迁移：Documents/.minecraft → Documents/minecraft。
//
//  旧版把游戏数据放在隐藏目录 .minecraft，文件 App 里看不见；现在改成
//  可见的 minecraft。本类负责在老用户首次启动时把数据迁过去，只做文件
//  系统操作，不依赖 UIKit。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 游戏根目录一次性改名迁移。
 *
 * 幂等：每次启动调用即可，实际只在首次生效 —— 迁移完成后再调用只是几次
 * 廉价的路径判断，不会重复搬动数据。
 *
 * 处理规则（旧 = Documents/.minecraft，新 = Documents/minecraft）：
 *   · 只有旧目录     → 旧目录为空则删掉；否则改名成新目录（保数据）。
 *   · 只有新目录     → 不动。
 *   · 两者都存在     → 旧目录为空则删旧；否则新目录为空就删新再把旧改名过来，
 *                      两个都非空则按约定丢弃旧目录，保留新目录。
 */
@interface A2GameDirMigration : NSObject

/// 执行迁移（必要时）。请在启动流程的最早期调用，早于任何读取游戏目录的逻辑。
+ (void)migrateIfNeeded;

@end

NS_ASSUME_NONNULL_END
