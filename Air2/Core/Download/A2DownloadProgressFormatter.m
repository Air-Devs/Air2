//
//  A2DownloadProgressFormatter.m
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
//  下载进度文字口径的实现。
//

#import "A2DownloadProgressFormatter.h"
#import <math.h>

@implementation A2DownloadProgressFormatter

+ (NSString *)bytesText:(int64_t)bytes {
    if (bytes <= 0) return @"0 B";
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld B", bytes];

    // 只在 B/KB/MB/GB 四档之间进位：再往上（TB）现实里不可能出现下载文件。
    double value = (double)bytes / 1024.0;
    NSUInteger unit = 0;
    while (value >= 1024.0 && unit + 1 < 3) {
        value /= 1024.0;
        unit += 1;
    }
    if (unit == 0) return [NSString stringWithFormat:@"%.1f KB", value];
    if (unit == 1) return [NSString stringWithFormat:@"%.1f MB", value];
    // GB 档多给一位小数：几百 MB 与 1 GB 的差别在界面上要看得出来。
    return [NSString stringWithFormat:@"%.2f GB", value];
}

+ (NSString *)speedText:(double)bytesPerSecond {
    if (!(bytesPerSecond > 0)) return @"—";
    return [NSString stringWithFormat:@"%@/s", [self bytesText:(int64_t)bytesPerSecond]];
}

+ (NSString *)percentText:(double)progress {
    double clamped = MAX(0.0, MIN(1.0, progress));
    return [NSString stringWithFormat:@"%.0f%%", clamped * 100.0];
}

+ (NSString *)remainingTextWithBytes:(int64_t)remainingBytes speed:(double)bytesPerSecond {
    if (remainingBytes <= 0 || !(bytesPerSecond > 0)) return nil;

    double seconds = (double)remainingBytes / bytesPerSecond;
    if (!isfinite(seconds) || seconds <= 0) return nil;

    // 不足 1 秒也至少说「1 秒」：显示「0 秒」会让人以为卡住了。
    if (seconds < 60.0) {
        return [NSString stringWithFormat:@"剩余 %.0f 秒", MAX(1.0, seconds)];
    }
    if (seconds < 3600.0) {
        NSInteger minutes = (NSInteger)(seconds / 60.0);
        NSInteger rest = (NSInteger)(seconds - minutes * 60.0);
        if (rest <= 0) return [NSString stringWithFormat:@"剩余 %ld 分", (long)minutes];
        return [NSString stringWithFormat:@"剩余 %ld 分 %ld 秒", (long)minutes, (long)rest];
    }
    if (seconds < 86400.0) {
        NSInteger hours = (NSInteger)(seconds / 3600.0);
        NSInteger minutes = (NSInteger)((seconds - hours * 3600.0) / 60.0);
        if (minutes <= 0) return [NSString stringWithFormat:@"剩余 %ld 小时", (long)hours];
        return [NSString stringWithFormat:@"剩余 %ld 小时 %ld 分", (long)hours, (long)minutes];
    }
    NSInteger days = (NSInteger)(seconds / 86400.0);
    NSInteger hours = (NSInteger)((seconds - days * 86400.0) / 3600.0);
    if (hours <= 0) return [NSString stringWithFormat:@"剩余 %ld 天", (long)days];
    return [NSString stringWithFormat:@"剩余 %ld 天 %ld 小时", (long)days, (long)hours];
}

@end
