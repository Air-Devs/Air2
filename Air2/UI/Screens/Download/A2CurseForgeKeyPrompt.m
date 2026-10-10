//
//  A2CurseForgeKeyPrompt.m
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
//  见头文件：输入框只管收 Key，是否有效由服务端说了算 ——
//  保存前调 validateKey 走一次真实请求，无效不存。Key 进钥匙串
//  （A2CurseForgeAPI 内部），本文件不碰存储。
//

#import "A2CurseForgeKeyPrompt.h"
#import "A2CurseForgeAPI.h"
#import "A2Toast.h"
#import "A2InputDialog.h"

@implementation A2CurseForgeKeyPrompt

+ (void)saveValidatedKey:(NSString *)key
             completion:(void (^)(BOOL, NSError *))completion {
    void (^done)(BOOL, NSError *) = ^(BOOL valid, NSError *err) {
        if ([NSThread isMainThread]) completion(valid, err);
        else dispatch_async(dispatch_get_main_queue(), ^{ completion(valid, err); });
    };
    if (key.length == 0) {
        done(NO, [NSError errorWithDomain:@"A2CurseForgeKey" code:1
                                 userInfo:@{NSLocalizedDescriptionKey: @"Key 不能为空"}]);
        return;
    }
    // 先暂存旧 Key：新 Key 无效时恢复，不把用户原有可用 Key 洗掉。
    NSString *oldKey = [A2CurseForgeAPI shared].apiKey;
    [A2CurseForgeAPI setAPIKey:key];
    [[A2CurseForgeAPI shared] validateKeyWithCompletion:^(BOOL valid, NSError *error) {
        if (valid) {
            done(YES, nil);
        } else {
            [A2CurseForgeAPI setAPIKey:oldKey];
            done(NO, error);
        }
    }];
}

+ (void)promptFrom:(UIViewController *)host
        completion:(void (^)(BOOL))completion {
    __weak UIViewController *weakHost = host;
    A2InputDialog *dlg = [A2InputDialog
        dialogWithTitle:@"CurseForge API Key"
                message:@"选中 CurseForge 需要 Key，可在 console.curseforge.com 免费申请"
                  label:@"API Key"
            initialText:nil];
    // Key 是凭据，输入时不显示明文
    dlg.secure = YES;
    dlg.keyboardType = UIKeyboardTypeASCIICapable;
    dlg.autocapitalizationType = UITextAutocapitalizationTypeNone;
    dlg.confirmTitle = @"保存并验证";
    // 验证要走一次真实请求，交给弹窗的异步提交流程（可停留、可报错）
    dlg.onCommit = ^(NSString *text, void (^done)(BOOL, NSString *)) {
        [self saveValidatedKey:text completion:^(BOOL valid, NSError *error) {
            if (valid) {
                done(YES, nil);
            } else {
                done(NO, error.localizedDescription ?: @"Key 无效，未保存");
            }
        }];
    };
    dlg.onFinish = ^(BOOL committed, NSString *text) {
        if (committed) [A2Toast show:@"已保存到钥匙串" inView:weakHost.view];
        if (completion) completion(committed);
    };
    [dlg presentFrom:host];
}

@end
