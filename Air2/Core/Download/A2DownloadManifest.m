//
//  A2DownloadManifest.m
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
//  见头文件：追加写 + 串行队列，读时验文件存在。
//  清单路径唯一出口在此文件内，调用方不拼路径。
//

#import "A2DownloadManifest.h"
#import "A2VersionIsolation.h"

@implementation A2DownloadManifest {
    dispatch_queue_t _queue;
}

+ (instancetype)shared {
    static A2DownloadManifest *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2DownloadManifest alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("dev.airdevs.air2.download-manifest", DISPATCH_QUEUE_SERIAL);
    return self;
}

#pragma mark - 路径（唯一出口）

- (NSString *)manifestPath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES).firstObject;
    // 与下载落盘根一致：Documents/.minecraft，下挂启动器私有数据。
    return [[[docs stringByAppendingPathComponent:@".minecraft"]
             stringByAppendingPathComponent:@".air_version"]
            stringByAppendingPathComponent:@"downloads.json"];
}

- (NSMutableArray<NSDictionary *> *)loadRecords {
    NSData *data = [NSData dataWithContentsOfFile:[self manifestPath]];
    if (!data) return [NSMutableArray array];
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if ([json isKindOfClass:NSArray.class]) return [(NSArray *)json mutableCopy];
    // 坏文件不崩：改名备份后从空开始，避免每次读写都失败。
    NSString *broken = [[self manifestPath] stringByAppendingString:@".broken"];
    [NSFileManager.defaultManager removeItemAtPath:broken error:nil];
    [NSFileManager.defaultManager moveItemAtPath:[self manifestPath] toPath:broken error:nil];
    return [NSMutableArray array];
}

- (void)saveRecords:(NSArray<NSDictionary *> *)records {
    NSString *path = [self manifestPath];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:records options:0 error:nil];
    if (data) [data writeToFile:path atomically:YES];
}

#pragma mark - 读写

- (void)recordDownloadWithProjectID:(NSString *)projectID
                          versionID:(NSString *)versionID
                           fileName:(NSString *)fileName
                             subdir:(NSString *)subdir {
    if (!projectID.length || !versionID.length || !fileName.length) return;
    dispatch_async(_queue, ^{
        NSMutableArray<NSDictionary *> *records = [self loadRecords];
        // 同项目同版本覆盖（重下即更新时间与文件名）。
        NSUInteger idx = [records indexOfObjectPassingTest:^BOOL(NSDictionary *r, NSUInteger i, BOOL *stop) {
            return [r[@"projectID"] isEqualToString:projectID] &&
                   [r[@"versionID"] isEqualToString:versionID];
        }];
        NSDictionary *entry = @{
            @"projectID": projectID,
            @"versionID": versionID,
            @"fileName": fileName,
            @"subdir": subdir ?: @"",
            @"downloadedAt": @([[NSDate date] timeIntervalSince1970]),
        };
        if (idx == NSNotFound) {
            [records addObject:entry];
        } else {
            records[idx] = entry;
        }
        [self saveRecords:records];
    });
}

- (BOOL)isProjectInstalled:(NSString *)projectID {
    if (!projectID.length) return NO;
    __block BOOL found = NO;
    dispatch_sync(_queue, ^{
        for (NSDictionary *r in [self loadRecords]) {
            if (![r[@"projectID"] isEqualToString:projectID]) continue;
            if ([self fileExistsForRecord:r]) { found = YES; break; }
        }
    });
    return found;
}

- (BOOL)isVersionInstalled:(NSString *)projectID versionID:(NSString *)versionID {
    if (!projectID.length || !versionID.length) return NO;
    __block BOOL found = NO;
    dispatch_sync(_queue, ^{
        for (NSDictionary *r in [self loadRecords]) {
            if (![r[@"projectID"] isEqualToString:projectID]) continue;
            if (![r[@"versionID"] isEqualToString:versionID]) continue;
            if ([self fileExistsForRecord:r]) { found = YES; break; }
        }
    });
    return found;
}

// 记录在但文件没了 → 视为未装（用户手删场景）。
- (BOOL)fileExistsForRecord:(NSDictionary *)r {
    NSString *fileName = r[@"fileName"];
    NSString *subdir = r[@"subdir"];
    if (![fileName isKindOfClass:NSString.class] || fileName.length == 0) return NO;
    if (![subdir isKindOfClass:NSString.class]) subdir = @"";
    // 拼路径走唯一出口，不手写 Documents 拼接。
    A2GamePath *p = [A2GamePath pathWithGameHome:A2GamePath.defaultGameHome];
    NSString *path = [[p.gameHome stringByAppendingPathComponent:subdir]
                      stringByAppendingPathComponent:fileName];
    return [NSFileManager.defaultManager fileExistsAtPath:path];
}

@end
