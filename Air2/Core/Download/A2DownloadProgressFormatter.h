//
//  A2DownloadProgressFormatter.h
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
//  下载进度的文字口径 —— 字节 / 速度 / 百分比 / 剩余时间。
//
//  为什么收敛成一个类：以前同一句「12.4 MB / 45.0 MB」在任务页、抽屉、
//  安装页各拼一遍，单位进位、小数位、空格各不相同，看起来像三个应用。
//  这里给出唯一口径，界面只管拼。
//
//  纯 Foundation、无状态 —— Core 层，可单测。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2DownloadProgressFormatter : NSObject

/// 字节数 → "0 B" / "532 B" / "12.4 KB" / "45.0 MB" / "1.24 GB"。
/// 负数与 0 都按 "0 B" 处理（未知大小由调用方决定不显示，不要用 0 冒充未知）。
+ (NSString *)bytesText:(int64_t)bytes;

/// 速度 → "2.4 MB/s"；速度非正时返回 "—"（不显示「0 B/s」那种噪声）。
+ (NSString *)speedText:(double)bytesPerSecond;

/// 百分比 → "65%"。progress 会被夹到 0~1。
+ (NSString *)percentText:(double)progress;

/// 剩余时间 → "剩余 13 秒" / "剩余 2 分 10 秒" / "剩余 1 小时 5 分"。
/// 剩余字节非正（已完成）或速度非正（未知总量 / 已暂停）时返回 nil ——
/// 调用方据此隐藏这一项，而不是显示一个假的「剩余 0 秒」。
+ (nullable NSString *)remainingTextWithBytes:(int64_t)remainingBytes
                                        speed:(double)bytesPerSecond;

@end

NS_ASSUME_NONNULL_END
