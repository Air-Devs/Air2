//
//  A2DownloadTask.m
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
//  下载任务记录：只有取值与展示逻辑，不含状态推进。
//  状态推进（入队/暂停/重试/取消/完成）全部在 A2DownloadTaskCenter。
//

#import "A2DownloadTask+Internal.h"

@implementation A2DownloadTask

+ (instancetype)taskWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                    createdAt:(NSDate *)createdAt {
    A2DownloadTask *task = [[A2DownloadTask alloc] init];
    task.title = title;
    task.subtitle = subtitle;
    task.createdAt = createdAt;
    task.state = A2DownloadStateRunning;
    return task;
}

- (void)applyProgressDelta:(int64_t)deltaBytes totalBytes:(int64_t)totalBytes {
    // totalExpectedBytes 未知时引擎报 -1，此时保留已知的 totalBytes。
    if (totalBytes > 0) {
        self.totalBytes = totalBytes;
    }
    // 引擎在换源/断点失效时会报负 delta，直接累加即为真实进度回退。
    self.downloadedBytes += deltaBytes;
}

- (double)progress {
    if (self.totalBytes <= 0) return 0;
    double value = (double)self.downloadedBytes / (double)self.totalBytes;
    return MAX(0.0, MIN(1.0, value));
}

- (NSString *)speedText {
    if (self.speed <= 0) return nil;
    // 不用手写 MB 换算：NSByteCountFormatter 自带单位与有效位处理（Foundation，跨层安全）。
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    formatter.allowedUnits = NSByteCountFormatterUseKB | NSByteCountFormatterUseMB | NSByteCountFormatterUseGB;
    return [NSString stringWithFormat:@"%@/s", [formatter stringFromByteCount:(long long)self.speed]];
}

- (BOOL)isActive {
    return self.state == A2DownloadStateRunning || self.state == A2DownloadStatePaused;
}

@end
