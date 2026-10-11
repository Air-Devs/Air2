//
//  A2Trash.m
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
//  见头文件：不存在即成功（幂等删除），失败绝不降级成直接删除。
//

#import "A2Trash.h"

@implementation A2Trash

+ (BOOL)trashItemAtPath:(NSString *)path error:(NSError **)error {
    if (path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileNoSuchFileError
                                     userInfo:@{NSLocalizedDescriptionKey: @"路径为空"}];
        }
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    // 幂等：已经没了就是删完了，调用方不用区分“删掉”和“本来就没有”。
    if (![fm fileExistsAtPath:path]) return YES;
    NSURL *url = [NSURL fileURLWithPath:path];
    NSError *trashErr = nil;
    if ([fm trashItemAtURL:url resultingItemURL:NULL error:&trashErr]) return YES;
    if (error) *error = trashErr;
    return NO;
}

@end
