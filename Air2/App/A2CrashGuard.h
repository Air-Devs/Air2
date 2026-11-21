//
//  A2CrashGuard.h
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
//  崩溃兜底 —— 把异常信息写进统一日志（见 A2Log），便于在没有 Xcode 的
//  环境里定位闪退。崩溃发生在本次会话，所以它会被追加到 lastlog.txt；
//  下次启动轮转后即变成 lastlog.old.txt，用户可在「文件」App 里取走。
//
//  不另开崩溃文件：一个日志系统就够，多了只会让人不知道看哪个。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2CrashGuard : NSObject

/// 注册异常与信号处理器。应在 main() 最早期调用。
+ (void)install;

@end

NS_ASSUME_NONNULL_END
