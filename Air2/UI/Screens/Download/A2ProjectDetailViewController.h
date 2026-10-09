//
//  A2ProjectDetailViewController.h
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
//  资源项目详情 —— 头信息 + 版本列表 + 下载。
//  版本下载逻辑从列表页搬家至此（列表只负责搜与列，不再直弹下载）。
//

#import "A2BaseViewController.h"
#import "A2ContentSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2ProjectDetailViewController : A2BaseViewController

/// targetSubdir 由列表页按分类算好传进来（统一映射只留一处）。
- (instancetype)initWithProject:(A2ContentItem *)project
                  targetSubdir:(NSString *)targetSubdir;

@end

NS_ASSUME_NONNULL_END
