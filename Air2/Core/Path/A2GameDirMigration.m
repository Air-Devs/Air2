//
//  A2GameDirMigration.m
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
//  见头文件：旧目录 .minecraft → 新目录 minecraft 的一次性改名迁移。
//  目标路径走 A2GamePath 唯一出口，不在此处重写目录名。
//

#import "A2GameDirMigration.h"
#import "A2VersionIsolation.h"
#import "A2Log.h"

/// 旧游戏根目录名（隐藏的 .minecraft）。仅本迁移组件知道这个名字。
static NSString *const kLegacyGameHomeDirName = @".minecraft";

/// 目录是否为空（不存在也算空）。只看第一层，不递归统计。
/// 列目录失败时按非空处理：读不到不等于没有，误删不可逆，宁可不动。
static BOOL A2DirIsEmpty(NSString *path) {
    NSError *listErr = nil;
    NSArray<NSString *> *contents =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:&listErr];
    if (contents == nil) {
        [A2Log log:@"gamedir-migration: 列目录失败，按非空处理 %@（%@）",
                    path, listErr.localizedDescription ?: @"未知错误"];
        return NO;
    }
    return contents.count == 0;
}

@implementation A2GameDirMigration

+ (void)migrateIfNeeded {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES).firstObject;
    if (!docs.length) return;

    NSString *legacyPath = [docs stringByAppendingPathComponent:kLegacyGameHomeDirName];
    NSString *currentPath = A2GamePath.defaultGameHome;

    // 没有旧目录：无需迁移，也不去动新目录。
    if (![fm fileExistsAtPath:legacyPath]) return;

    // 旧目录是空的 → 直接删掉，不占位置也不改名。
    // 空目录删除失败不致命，但要记日志（否则下次启动静默重试，用户永远不知道）。
    if (A2DirIsEmpty(legacyPath)) {
        NSError *rmErr = nil;
        if ([fm removeItemAtPath:legacyPath error:&rmErr]) {
            [A2Log log:@"gamedir-migration: 删除空的旧目录 %@", legacyPath];
        } else {
            [A2Log log:@"gamedir-migration: 删除空旧目录失败 %@（%@），下次启动重试",
                        legacyPath, rmErr.localizedDescription ?: @"未知错误"];
        }
        return;
    }

    BOOL currentExists = [fm fileExistsAtPath:currentPath];

    // 新旧都在且新目录非空 → 冲突，两边都不动。
    // 绝不自动丢弃任一边：旧目录可能是老存档，新目录可能是新装的数据，
    // 程序无法判断哪边对用户更重要，删错不可逆。需用户手动处理。
    if (currentExists && !A2DirIsEmpty(currentPath)) {
        [A2Log log:@"gamedir-migration: 新旧目录都有内容，两边保留，需用户手动处理（旧 %@，新 %@）",
                    legacyPath, currentPath];
        return;
    }

    // 新目录不存在或为空 → 让路，把旧目录改名过来（保数据）。
    if (currentExists) {
        NSError *rmErr = nil;
        if (![fm removeItemAtPath:currentPath error:&rmErr]) {
            [A2Log log:@"gamedir-migration: 让路失败，空新目录删不掉 %@（%@），本次不动",
                        currentPath, rmErr.localizedDescription ?: @"未知错误"];
            return;
        }
        [A2Log log:@"gamedir-migration: 删除空的新目录 %@", currentPath];
    }

    NSError *err = nil;
    if ([fm moveItemAtPath:legacyPath toPath:currentPath error:&err]) {
        [A2Log log:@"gamedir-migration: 旧目录改名完成 %@ → %@", legacyPath, currentPath];
    } else {
        [A2Log log:@"gamedir-migration: 旧目录改名失败 %@",
                    err.localizedDescription ?: @"未知错误"];
    }
}

@end
