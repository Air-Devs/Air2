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

@implementation A2CurseForgeKeyPrompt

+ (void)promptFrom:(UIViewController *)host
        completion:(void (^)(BOOL))completion {
    void (^done)(BOOL) = ^(BOOL saved) {
        if (completion) completion(saved);
    };

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"CurseForge API Key"
                                            message:@"选中 CurseForge 需要 Key，可在 console.curseforge.com 免费申请"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"$2a$10$...";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        // Key 是凭据，输入时不显示明文
        tf.secureTextEntry = YES;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *a) {
        done(NO);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存并验证"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        NSString *key = alert.textFields.firstObject.text;
        if (key.length == 0) {
            [A2Toast show:@"Key 不能为空" inView:host.view];
            done(NO);
            return;
        }
        // 先暂存旧 Key：新 Key 无效时恢复，不把用户原有可用 Key洗掉。
        NSString *oldKey = [A2CurseForgeAPI shared].apiKey;
        [A2CurseForgeAPI setAPIKey:key];
        [A2Toast show:@"正在验证…" inView:host.view];
        [[A2CurseForgeAPI shared] validateKeyWithCompletion:^(BOOL valid, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (valid) {
                    [A2Toast show:@"已保存到钥匙串" inView:host.view];
                    done(YES);
                } else {
                    [A2CurseForgeAPI setAPIKey:oldKey];
                    [A2Toast show:(error.localizedDescription ?: @"Key 无效，未保存")
                           inView:host.view];
                    done(NO);
                }
            });
        }];
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

@end
